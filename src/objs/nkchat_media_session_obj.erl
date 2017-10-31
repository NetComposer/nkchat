%% -------------------------------------------------------------------
%%
%% Copyright (c) 2017 Carlos Gonzalez Florido.  All Rights Reserved.
%%
%% This file is provided to you under the Apache License,
%% Version 2.0 (the "License"); you may not use this file
%% except in compliance with the License.  You may obtain
%% a copy of the License at
%%
%%   http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing,
%% software distributed under the License is distributed on an
%% "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
%% KIND, either express or implied.  See the License for the
%% specific language governing permissions and limitations
%% under the License.
%%
%% -------------------------------------------------------------------

%% @doc State Object

%% Invite - Caller side
%% --------------------
%%
%% - API calls invite/3 to start a new 'direct' call. It should be in no active call.
%% - It creates a call with type 'direct' and call nkchat_media_call_obj:invite/5 that
%%     - adds a member to the call
%%     - creates and launches "invite token" to the callee
%%     - starts a new media session
%% - We get the media session id and store the call info at the session
%% - The call sends the media_ringing event and we wait for the answer
%%     - if the call stops, it will send media_stopped event and call_hangup
%%     - if the call fails, it is detected and the same
%%     - if we call cancel_invite, we call stop_media and media_stopped will be received
%%     - if the calling timeout fires, the same
%%     - if the call is answered, we will receive media_answered event
%%
%% Callee side
%% -----------
%%
%% - Callee receives the invite token through the notify_fun and sends invite event
%% - If reject_invite is called, and the token is still valid, the media session is stopped
%%     - caller received media_stopped
%%     - no event is received
%% - If accept_invite is called, and the token is valid


-module(nkchat_media_session_obj).
-behavior(nkdomain_obj).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-export([start/3, get_call_info/1, launch_notifications/1]).
-export([invite/3, cancel_invite/1, accept_invite/3, reject_invite/1]).
-export([object_info/0, object_es_mapping/0, object_parse/2,
         object_api_syntax/2, object_api_cmd/2]).
-export([object_init/1, object_stop/2, object_send_event/2,
         object_sync_op/3, object_async_op/2]).
-export([object_admin_info/0, object_handle_info/2]).
-export([call_event/3, notify_fun/2]).

-export_type([event/0]).

-include("nkchat.hrl").
-include_lib("nkdomain/include/nkdomain.hrl").
-include_lib("nkdomain/include/nkdomain_debug.hrl").
-include_lib("nkevent/include/nkevent.hrl").

-define(DEFAULT_INVITE_TTL, 3*60).     % Secs



%% ===================================================================
%% Types
%% ===================================================================

-type event() ::
    % Own events
    {call_created, CallId::binary()} |
    {media_invite, MediaId::nkdomain:obj_id(), CallId::nkdomain:obj_id(), CallerId::nkdomain:obj_id(),
             InviteOpts::nkchat_media_call_obj:invite_opts()} |
    {media_invite_removed, MediaId::nkdomain:obj_id(), Reason::term()} |

    % Events from call
    {media_ringing, MediaId::nkdomain:obj_id(), CallId::nkdomain:obj_id()} |
    {media_answered,  MediaId::nkdomain:obj_id(), CallId::nkdomain:obj_id(), nkchat_media_call_obj:accept_opts()} |
    {media_started, MediaId::nkdomain:obj_id(), CallId::nkdomain:obj_id()} |
    {media_stopped, MediaId::nkdomain:obj_id(), CallId::nkdomain:obj_id(), Reason::term()} |
    {new_candidate, CallId::nkdomain:obj_id(), nkchat_media_call_obj:candidate()} |
    {session_status, SessId::nkdomain:obj_id(), UserId::nkdomain:obj_id(),
                     CallId::nkdomain:obj_id(), nkchat_media_call_obj:session_status()} |
    {call_status, CallId::nkdomain:obj_id(), nkchat_media_call_obj:call_status()} |
    {session_added, SessId::nkdomain:obj_id(), User::nkdomain:obj_id(), CallId::nkdomain:obj_id(), #{}} |
    {session_removed, SessId::nkdomain:obj_id(), User::nkdomain:obj_id(), CallId::nkdomain:obj_id(), #{}} |
    {call_hangup, Reason::nkservice:error(), CallId::nkdomain:obj_id(), Time::integer()}.



-type start_opts() :: #{
    session_link => {module(), pid()},
    session_events => [binary()]
}.


-type invite_opts() ::
    nkchat_media_call_obj:invite_opts() |
    #{call_name=>binary()}.


%% ===================================================================
%% Public
%% ===================================================================


%% @doc Creates a new session
-spec start(nkdomain:id(), nkdomain:id(), start_opts()) ->
    {ok, nkdomain:obj_id(), pid()} | {error, term()}.

start(DomainId, UserId, Opts) ->
    Obj = #{
        type => ?MEDIA_SESSION,
        domain_id => DomainId,
        parent_id => UserId,
        created_by => UserId,
        active => true,
        ?MEDIA_SESSION => #{}
    },
    Opts2 = maps:with([session_link, session_events], Opts),
    case nkdomain_obj_make:create(Obj, Opts2) of
        {ok, #obj_id_ext{obj_id=SessId, pid=Pid}, _} ->
            {ok, SessId, Pid};
        {error, Error} ->
            {error, Error}
    end.


%% @doc
-spec invite(nkdomain:id(), nkdomain:id(), invite_opts()) ->
    {ok, MediaId::nkdomain:obj_id()} | {error, term()}.

invite(Id, Callee, InviteOpts) ->
    case nkdomain_lib:load(Callee) of
        #obj_id_ext{type = ?DOMAIN_USER, obj_id=CalleeId} ->
            nkdomain_obj:sync_op(Id, {?MODULE, invite, CalleeId, InviteOpts});
        {error, object_not_found} ->
            {error, user_not_found};
        {error, Error} ->
            {error, Error}
    end.


%% @doc
cancel_invite(MediaId) ->
    case consume_token(MediaId, cancel_invite) of
        {ok, CallId} ->
            % We will receive the media_stopped event
            % If not for some reason (call down) we will detect the stop of the token process
            nkchat_media_call_obj:stop_media(CallId, MediaId, caller_cancelled);
        {error, Error} ->
            {error, Error}
    end.


%% @doc Accepts a invitation notification
-spec accept_invite(nkdomain:id(), nkdomain:id(),  nkchat_media_call_obj:accept_opts()) ->
    ok | {error, term()}.

accept_invite(SessId, MediaId, AcceptOpts) ->
    case consume_token(MediaId, accept_invite) of
        {ok, CallId} ->
            nkdomain_obj:sync_op(SessId, {?MODULE, accept_invite, MediaId, CallId, AcceptOpts});
        {error, Error} ->
            {error, Error}
    end.


%% @doc Rejects a invitation notification
-spec reject_invite(nkdomain:obj_id()) ->
    ok | {error, term()}.

reject_invite(MediaId) ->
    case consume_token(MediaId, reject_invite) of
        {ok, CallId} ->
            nkchat_media_call_obj:stop_media(CallId, MediaId, callee_rejected);
        {error, _} ->
            ok
    end.


%% @doc
launch_notifications(Id) ->
    nkdomain_obj:async_op(Id, {?MODULE, launch_notifications}).


%% @doc
-spec get_call_info(nkdomain:id()) ->
    {ok, [nkdomain:obj_id()]} | {error, term()}.

get_call_info(Id) ->
    nkdomain_obj:sync_op(Id, {?MODULE, get_call_info}).


%% @private To be called from nkmedia_call_obj
-spec call_event(pid(), nkdomain:obj_id(),
                 nkchat_media_call_obj:session_event() | nkchat_media_call_obj:member_session_event()) ->
    ok.

call_event(Pid, CallId, Event) ->
    nkdomain_obj:async_op(Pid, {?MODULE, call_event, CallId, Event}).


%% @private To be called from nkdomain_user_obj
-spec notify_fun(pid(), nkdomain_user_obj:notify_msg()) ->
    any.

notify_fun(Pid, Notify) ->
    nkdomain_obj:async_op(Pid, {?MODULE, notify_fun, Notify}).


%% @private To be called from nkdomain_user_obj
-spec presence_fun(nkdomain:user_id(), [nkdomain_user_obj:session_presence()]) ->
    {ok, nkdomain_user_obj:user_presence()}.

presence_fun(_UserId, []) ->
    {ok, #{status => <<"offline">>}};

presence_fun(_UserId, List) ->
    Status = case lists:member(<<"answered">>, List) of
        true ->
            <<"talking">>;
        false ->
            case lists:member(<<"ringing">>, List) of
                true ->
                    <<"ringing">>;
                false ->
                    <<"online">>
            end
    end,
    {ok, #{status=>Status}}.




%% ===================================================================
%% nkdomain_obj behaviour
%% ===================================================================


-record(media, {
    id :: nkdomain:obj_id(),
    status :: created | ringing_in | ringing_out | answered,
    call_id :: nkdomain:obj_id(),
    call_mon :: reference(),
    token_mon :: reference()
}).


-record(session, {
    medias = [] :: [#media{}],
    last_invite = 0 :: nkdomain:timestamp()
}).



%% @private
object_info() ->
    #{
        type => ?MEDIA_SESSION,
        stop_after_disabled => true,
        remove_after_stop => true
    }.


%% @doc
object_admin_info() ->
    #{
        class => session,
        weight => 2000,
        type_view_mod => nkchat_media_session_obj_type_view
    }.


%% @private
object_es_mapping() ->
    not_indexed.


%% @private
object_parse(_Mode, _Obj) ->
    #{}.


%% @private
object_api_syntax(Cmd, Syntax) ->
    nkchat_media_session_obj_syntax:syntax(Cmd, Syntax).


%% @private
object_api_cmd(Cmd, Req) ->
    nkchat_media_session_obj_cmd:cmd(Cmd, Req).


%% @private
object_send_event(Event, State) ->
    nkchat_media_session_obj_events:event(Event, State).


%% @private When the object is loaded, we make our cache
object_init(#obj_state{id=Id, parent_id=UserId, domain_id=DomainId}=State) ->
    #obj_id_ext{obj_id=SessId} = Id,
    Session = #session{},
    State2 = State#obj_state{session=Session},
    Opts = #{
        notify_fun => fun ?MODULE:notify_fun/2,
        presence_fun => fun ?MODULE:presence_fun/2,
        presence => <<"none">>
    },
    ok = nkdomain_user_obj:register_session(UserId, DomainId, ?MEDIA_SESSION, SessId, Opts),
    State4 = nkdomain_obj_util:link_to_session_server(?MODULE, State2),
    {ok, State4}.


%% @private
object_stop(_Reason, State) ->
    {ok, nkdomain_obj_util:unlink_from_session_server(?MODULE, State)}.


%% @private
object_sync_op({?MODULE, get_call_info}, _From, #obj_state{session=#session{medias=Medias}}=State) ->
    Calls = [
        #{media_id=>Id, status=>Status, call_id=>CallId} ||
        #media{id=Id, status=Status, call_id=CallId} <- Medias
    ],
    {reply, {ok, Calls}, State};

object_sync_op({?MODULE, invite, CalleeId, InviteOpts}, _From, #obj_state{session=Session}=State) ->
    #session{last_invite=LastInvite} = Session,
    Now = nkdomain_util:timestamp(),
    case (Now - LastInvite) > 2000 of
        true ->
            State2 = State#obj_state{session=Session#session{last_invite=Now}},
            case do_invite(CalleeId, InviteOpts, State2) of
                {ok, MediaId, State3} ->
                    {reply, {ok, MediaId}, State3};
                {error, Error} ->
                    {reply, {error, Error}, State}
            end;
        false ->
            {reply, {error, invite_not_allowed}, State}
    end;

object_sync_op({?MODULE, accept_invite, MediaId, CallId, Opts}, _From, State) ->
    #obj_state{id=#obj_id_ext{obj_id=SessId}, parent_id=UserId} = State,
    case nkchat_media_call_obj:answer_media(CallId, MediaId, SessId, UserId, Opts) of
        {ok, CallId, CallPid} ->
            Media2 = case do_get_media(MediaId, State) of
                {ok, #media{call_id=CallId, token_mon=Mon}=Media} ->
                    nklib_util:demonitor(Mon),
                    Media#media{status=answered};
                not_found ->
                    % We may have just started, but the call has been accepted any case
                    #media{
                        id = MediaId,
                        status = answered,
                        call_id = CallId,
                        call_mon = monitor(process, CallPid)
                    }
            end,
            State2 = do_update_media(Media2, State),
            {reply, ok, State2};
        {error, Error} ->
            {reply, {error, Error}, State}
    end;

object_sync_op(_Op, _From, _State) ->
    continue.


%% @private
object_async_op({?MODULE, call_event, CallId, Event}, State) ->
    State2 = do_call_event(Event, CallId, State),
    {noreply, State2};

object_async_op({?MODULE, launch_notifications}, State) ->
    #obj_state{id=#obj_id_ext{obj_id=SessId}, parent_id=UserId} = State,
    nkdomain_user_obj:launch_session_notifications(UserId, SessId),
    {noreply, State};

object_async_op({?MODULE, notify_fun, {token_created, MediaId, Msg}}, State) ->
    case read_invite_token(Msg) of
        {ok, CallId, CallerId, _CalleeId, InviteOpts} ->
            case nkdomain_lib:load(CallId) of
                #obj_id_ext{pid=CallPid} ->
                    Media = #media{
                        id = MediaId,
                        status = ringing_in,
                        call_id = CallId,
                        call_mon = monitor(process, CallPid)
                    },
                    State2 = do_update_media(Media, State),
                    State3 = do_event({media_invite, MediaId, CallId, CallerId, InviteOpts}, State2),
                    {noreply, State3};
                {error, object_not_found} ->
                    ?LLOG(notice, "cannot process incoming invite for call ~s: call not found", [CallId], State),
                    {noreply, State};
                {error, Error} ->
                    ?LLOG(notice, "cannot process incoming invite for call ~s: ~p", [CallId, Error], State),
                    {noreply, State}
            end;
        {error, Error} ->
            ?LLOG(warning, "invalid token ~s: ~p", [MediaId, Error], State),
            {noreply, State}
    end;

object_async_op({?MODULE, notify_fun, {token_removed, MediaId, Reason}}, State) ->
    State2 = do_event({media_invite_removed, MediaId, Reason}, State),
    {noreply, State2};

object_async_op(_Op, _State) ->
    continue.


%% @private
object_handle_info({'DOWN', Ref, process, _Pid, _Reason}, #obj_state{session=Session}=State) ->
    #session{medias=Medias} = Session,
    case lists:keyfind(Ref, #media.call_mon, Medias) of
        #media{id=MediaId, call_id=CallId} ->
            ?LLOG(notice, "call down ~s", [CallId], State),
            State2 = do_rm_media(MediaId, call_down, State),
            {noreply, State2};
        false ->
            case lists:keyfind(Ref, #media.token_mon, Medias) of
                #media{id=MediaId, call_id=CallId, status=ringing_out} ->
                    ?LLOG(notice, "token down ~s: ~p", [CallId], State),
                    % If we are monitoring the token, we are the caller
                    nkchat_media_call_obj:hangup_async(CallId, caller_token_down),
                    State2 = do_rm_media(MediaId, token_down, State),
                    {noreply, State2};
                #media{} ->
                    {noreply, State};
                false ->
                    continue
            end
    end;

object_handle_info(_Msg, _State) ->
    continue.



%% ===================================================================
%% Internal
%% ===================================================================

%% @private
consume_token(MediaId, Reason) ->
    case nkdomain_token_obj:consume_token(MediaId, Reason) of
        {ok, #{data:=Data}} ->
            case read_invite_token(Data) of
                {ok, CallId, _CallerId, _CalleeId, _Opts} ->
                    {ok, CallId};
                {error, _Error} ->
                    {error, token_invalid}
            end;
        {error, _Error} ->
            {error, token_invalid}
    end.


%% @private
do_invite(CalleeId, InviteOpts, State) ->
    #obj_state{domain_id=DomainId, parent_id=UserId, id=#obj_id_ext{obj_id=SessId}} = State,
    CallOpts1 = maps:with([conversation_id], InviteOpts),
    CallOpts2 = CallOpts1#{
        type => direct,
        parent_id => UserId,
        created_by => UserId
    },
    CallOpts3 = case InviteOpts of
        #{call_name:=Name} ->
            CallOpts2#{name=>Name};
        _ ->
            CallOpts2
    end,
    case nkchat_media_call_obj:create(DomainId, CallOpts3) of
        {ok, CallId, CallPid} ->
            case make_invite_token(CallId, CalleeId, InviteOpts, State) of
                {ok, MediaId, TokenPid, Secs} ->
                    State2 = do_event({call_created, CallId}, State),
                    Meta = maps:get(meta, InviteOpts, #{}),
                    InviteOpts2 = InviteOpts#{ttl => Secs+2, meta => Meta#{callee_id=>CalleeId}},
                    case nkchat_media_call_obj:invite(CallId, MediaId, SessId, UserId, InviteOpts2) of
                        ok ->
                            Media = #media{
                                id = MediaId,
                                status = created,
                                call_id = CallId,
                                call_mon = monitor(process, CallPid),
                                token_mon = monitor(process, TokenPid)
                            },
                            State3 = do_update_media(Media, State2),

                            {ok, MediaId, State3};
                        {error, Error} ->
                            consume_token(MediaId, call_failed),
                            ?LLOG(warning, "error sending invite: ~p", [Error], State),
                            nkchat_media_call_obj:hangup_async(CallPid, invite_error),
                            {error, Error}
                    end;
                {error, Error} ->
                    ?LLOG(warning, "error creating token: ~p", [Error], State),
                    {error, Error}
            end;
        {error, Error} ->
            ?LLOG(warning, "error creating call: ~p", [Error], State),
            {error, Error}
    end.


%% @private
update_presence(State) ->
    #obj_state{id=#obj_id_ext{obj_id=SessId}, parent_id=UserId, session=Session} = State,
    #session{medias=Medias} = Session,
    Statuses = [Status || #media{status=Status} <- Medias],
    Status = case lists:member(answered, Statuses) of
        true ->
            answered;
        false ->
            case lists:member(ringing_in, Statuses) of
                true ->
                    ringing;
                false ->
                    case lists:member(ringing_out, Statuses) of
                        true ->
                            ringing;
                        false ->
                            none
                    end
            end
    end,
    nkdomain_user_obj:update_presence(UserId, SessId, nklib_util:to_binary(Status)),
    State.


%% @private
do_get_media(MediaId, #obj_state{session=Session}) ->
    #session{medias=Medias} = Session,
    case lists:keyfind(MediaId, #media.id, Medias) of
        #media{}=Media ->
            {ok, Media};
        false ->
            not_found
    end.


%% @private
do_rm_media(MediaId, Reason, #obj_state{session=Session}=State) ->
    #session{medias=Medias} = Session,
    case lists:keytake(MediaId, #media.id, Medias) of
        {value, #media{call_id=CallId, call_mon=CallMon, token_mon=TokenMon}, Medias2} ->
            ?LLOG(info, "media ~s removed", [MediaId], State),
            nklib_util:demonitor(CallMon),
            nklib_util:demonitor(TokenMon),
            State2 = State#obj_state{session=Session#session{medias=Medias2}},
            State3 = do_event({media_stopped, MediaId, CallId, Reason}, State2),
            update_presence(State3);
        false ->
            State
    end.


%% @private
do_update_media(#media{id=MediaId, status=Status}=Media, #obj_state{session=Session}=State) ->
    case do_get_media(MediaId, State) of
        {ok, #media{status=OldStatus}} when Status /= OldStatus ->
            ?LLOG(info, "media ~s updated: ~s", [MediaId, Status], State);
        not_found ->
            ?LLOG(info, "media ~s created: ~s", [MediaId, Status], State);
        _ ->
            ok
    end,
    #session{medias=Medias} = Session,
    Medias2 = lists:keystore(MediaId, #media.id, Medias, Media),
    State2 = State#obj_state{session=Session#session{medias=Medias2}},
    update_presence(State2).


%% @private
do_call_event({media_ringing, MediaId}, CallId, State) ->
    case do_get_media(MediaId, State) of
        {ok, Media} ->
            State2 = do_update_media(Media#media{status=ringing_out}, State),
            do_event({media_ringing, MediaId, CallId}, State2);
        not_found ->
            ?LLOG(notice, "received media_ringing for unknown media", [], State),
            State
    end;

do_call_event({media_answered, MediaId, AcceptOpts}, CallId, State) ->
    case do_get_media(MediaId, State) of
        {ok, Media} ->
            State2 = do_update_media(Media#media{status=answered}, State),
            do_event({media_answered, MediaId, CallId, AcceptOpts}, State2);
        not_found ->
            ?LLOG(notice, "received media_answered for unknown media", [], State),
            State
    end;

do_call_event({media_started, MediaId}, CallId, State) ->
    case do_get_media(MediaId, State) of
        {ok, Media} ->
            State2 = do_update_media(Media#media{status=answered}, State),
            do_event({media_started, MediaId, CallId}, State2);
        not_found ->
            ?LLOG(error, "NO MEDIA: ~s, ~p", [MediaId, State#obj_state.session#session.medias], State),

            ?LLOG(notice, "received media_started for unknown media", [], State),
            State
    end;

do_call_event({media_stopped, MediaId, Reason}, _CallId, State) ->
    do_rm_media(MediaId, Reason, State);

do_call_event({new_candidate, Candidate}, CallId, State) ->
    do_event({new_candidate, CallId, Candidate}, State);

do_call_event({call_status, Status}, CallId, State) ->
    do_event({call_status, CallId, Status}, State);

do_call_event({session_added, SessId, MemberId, Data}, CallId, State) ->
    do_event({session_added, SessId, MemberId, CallId, Data}, State);

do_call_event({session_removed, SessId, MemberId, Data}, CallId, State) ->
    do_event({session_removed, SessId, MemberId, CallId, Data}, State);

do_call_event({session_status, SessId, UserId, Status}, CallId, State) ->
    do_event({session_status, SessId, UserId, CallId, Status}, State);

do_call_event({call_hangup, Reason, Time}, CallId, #obj_state{session=Session}=State) ->
    #session{medias=Medias} = Session,
    State2 = case lists:keyfind(CallId, #media.call_id, Medias) of
        #media{id=MediaId} ->
            do_rm_media(MediaId, Reason, State);
        _ ->
            State
    end,
    do_event({call_hangup, CallId, Reason, Time}, State2);

do_call_event(_Event, _CallId, State) ->
    lager:error("SESS EV2: ~p", [_Event]),
    State.


%% @private
do_event(Event, State) ->
    nkdomain_obj_util:event(Event, State).


%% @private
make_invite_token(CallId, CalleeId, InviteOpts, State) ->
    #obj_state{parent_id=UserId, domain_id=DomainId, id=#obj_id_ext{srv_id=SrvId}} = State,
    TokenData1 = gen_invite_token(CallId, UserId, CalleeId, InviteOpts),
    Push = make_invite_push(UserId, InviteOpts),
    Opts = #{srv_id=>SrvId, wakeup_push => Push},
    case nkdomain_user_obj:add_token_notification(CalleeId, ?MEDIA_SESSION, Opts, TokenData1) of
        {ok, _MemberId, TokenData2} ->
            TTL = case InviteOpts of
                #{ttl:=TTL0} when is_integer(TTL0), TTL0>0 ->
                    TTL0;
                _ ->
                    ?DEFAULT_INVITE_TTL
            end,
            TokenOpts = #{
                parent_id => CalleeId,
                created_by => UserId,
                subtype => <<"media.call">>,
                ttl => TTL
            },
            case nkdomain_token_obj:create(DomainId, TokenOpts, TokenData2) of
                {ok, MediaId, Pid, Secs} ->
                    {ok, MediaId, Pid, Secs};
                {error, Error} ->
                    {error, Error}
            end;
        {error, Error} ->
            {error, Error}
    end.


%% @private
gen_invite_token(CallId, CallerId, CalleeId, InviteOpts) ->
    #{
        ?MEDIA_SESSION =>
        #{
            <<"invite_op">> =>
            #{
                <<"call_id">> => CallId,
                <<"caller_id">> => CallerId,
                <<"callee_id">> => CalleeId,
                <<"invite_opts">> => InviteOpts
            }
        }
    }.

-compile(export_all).
%% @private
read_invite_token(Token) ->
    case Token of
        #{
            ?MEDIA_SESSION := #{
                <<"invite_op">> :=
                #{
                    <<"call_id">> := CallId,
                    <<"caller_id">> := CallerId,
                    <<"callee_id">> := CalleeId,
                    <<"invite_opts">> := InviteOpts
                }
            }
        } ->
            {ok, CallId, CallerId, CalleeId, InviteOpts};
        _ ->
            {error, invalid_token}
    end.


%% @private
make_invite_push(CallerId, InviteOpts) ->
    {ok, #{fullname:=FullName}} = nkdomain_user_obj:get_name(CallerId),
    #{
        type => ?MEDIA_SESSION,
        class => invite,
        media_id => <<>>,
        full_name => FullName,
        audio => maps:get(audio, InviteOpts, false),
        video => maps:get(video, InviteOpts, false),
        screen => maps:get(screen, InviteOpts, false),
        conversation_id => maps:get(conversation_id, InviteOpts, <<>>)
    }.