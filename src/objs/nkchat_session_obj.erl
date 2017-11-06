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
-module(nkchat_session_obj).
-behavior(nkdomain_obj).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-export([start/3, get_conversations/1, get_conversation_info/2, launch_notifications/1]).
-export([set_active_conversation/2, deactivate_conversation/1, add_conversation/2, remove_conversation/2]).
-export([conversation_event/4, send_invitation/4, accept_invitation/2, reject_invitation/2, wakeup/1]).
-export([object_info/0, object_es_mapping/0, object_parse/2,
         object_api_syntax/2, object_api_cmd/2]).
-export([object_init/1, object_stop/2, object_send_event/2,
         object_sync_op/3, object_async_op/2, object_handle_info/2]).
-export([object_admin_info/0]).
-export([notify_fun/2, presence_fun/2]).

-export_type([meta/0, event/0]).

-include("nkchat.hrl").
-include_lib("nkdomain/include/nkdomain.hrl").
-include_lib("nkdomain/include/nkdomain_debug.hrl").
-include_lib("nkevent/include/nkevent.hrl").

-define(INACTIVITY_TIMER, 5*60).

%% ===================================================================
%% Types
%% ===================================================================


-type meta() ::
    #{
        user_id => nkdomain:obj_id()
    }.


-type event() ::
    {conversation_activated, ConvId::nkdomain:obj_id()} |
    {conversation_added, ConvId::nkdomain:obj_id()} |
    {conversation_removed, ConvId::nkdomain:obj_id()} |
    {conversation_updated, nkdomain:obj()} |
    {member_added, ConvId::nkdomain:obj_id(), IsActive::boolean(), MemberId::nkdomain:obj_id()} |
    {member_removed, ConvId::nkdomain:obj_id(), IsActive::boolean(), MemberId::nkdomain:obj_id()} |
    {message_created, nkdomain:obj()} |
    {message_updated, nkdomain:obj()} |
    {message_deleted, nkdomain:obj_id()} |
    {status_updated, nkchat_conversation_obj:status()} |
    {is_closed_updated, boolean()} |
    {unread_counter_updated, ConvId::nkdomain:obj_id(), integer()} |
    {invited_to_conversation, TokenId::binary(), UserId::binary(), ConvId::binary()} |
    {remove_notification, TokenId::binary(), Reason::term()}.


-type start_opts() :: #{
    session_link => {module(), pid()},
    session_events => [binary()]
}.


%% ===================================================================
%% Public
%% ===================================================================


%% @doc Creates a new session
-spec start(nkdomain:id(), nkdomain:id(), start_opts()) ->
    {ok, nkdomain:obj_id(), pid()} | {error, term()}.

start(DomainId, UserId, Opts) ->
    Obj = #{
        type => ?CHAT_SESSION,
        domain_id => DomainId,
        parent_id => UserId,
        created_by => UserId,
        active => true,
        ?CHAT_SESSION => #{}
    },
    Opts2 = maps:with([session_link, session_events], Opts),
    case nkdomain_obj_make:create(Obj, Opts2) of
        {ok, #obj_id_ext{obj_id=SessId, pid=Pid}, _} ->
            {ok, SessId, Pid};
        {error, Error} ->
            {error, Error}
    end.


%% @doc
launch_notifications(Id) ->
    nkdomain_obj:async_op(Id, {?MODULE, launch_notifications}).


%% @doc
add_conversation(Id, ConvId) ->
    case nkdomain_lib:load(ConvId) of
        #obj_id_ext{type = ?CHAT_CONVERSATION, obj_id=ConvId2} ->
            nkdomain_obj:sync_op(Id, {?MODULE, add_conv, ConvId2});
        {error, object_not_found} ->
            {error, conversation_not_found};
        {error, Error} ->
            {error, Error}
    end.


%% @doc
remove_conversation(Id, ConvId) ->
    case nkdomain_lib:find(ConvId) of
        #obj_id_ext{obj_id=ConvId2} ->
            nkdomain_obj:sync_op(Id, {?MODULE, rm_conv, ConvId2});
        {error, Error} ->
            {error, Error}
    end.


%% @doc
-spec get_conversations(nkdomain:id()) ->
    {ok, [nkdomain:obj_id()]} | {error, term()}.

get_conversations(Id) ->
    nkdomain_obj:sync_op(Id, {?MODULE, get_conversations}).


%% @doc
-spec get_conversation_info(nkdomain:id(), nkdomain:id()) ->
    {ok, map()} | {error, term()}.

get_conversation_info(Id, Conv) ->
    case nkdomain_lib:find(Conv) of
        #obj_id_ext{obj_id=ConvId} ->
            nkdomain_obj:sync_op(Id, {?MODULE, get_conversation_info, ConvId});
        {error, Error} ->
            {error, Error}
    end.


%% @doc
-spec set_active_conversation(nkdomain:id(), nkdomain:id()) ->
    {ok, map()} | {error, term()}.

set_active_conversation(Id, Conv) ->
    case nkdomain_lib:find(Conv) of
        #obj_id_ext{obj_id=ConvId} ->
            nkdomain_obj:sync_op(Id, {?MODULE, set_active_conv, ConvId});
        {error, Error} ->
            {error, Error}
    end.

%% @doc
-spec deactivate_conversation(nkdomain:id()) ->
    {ok, map()} | {error, term()}.

deactivate_conversation(Id) ->
    nkdomain_obj:sync_op(Id, {?MODULE, deactivate_conv}).

%% @doc Sends a invitation notification
-spec send_invitation(nkdomain:id(), nkdomain:id(), nkdomain:id(), integer()) ->
    {ok, TokenId::nkdomain:obj_id()} | {error, term()}.

send_invitation(SessId, MemberId, ConvId, TTL) ->
    nkdomain_obj:sync_op(SessId, {?MODULE, send_invitation, MemberId, ConvId, TTL}).


%% @doc Accepts a invitation notification
-spec accept_invitation(nkdomain:id(), nkdomain:id()) ->
    ok | {error, term()}.

accept_invitation(SessId, TokenId) ->
    case nkdomain_token_obj:consume_token(TokenId, accepted) of
        {ok, #{data:=Data}} ->
            nkdomain_obj:sync_op(SessId, {?MODULE, accept_invitation, Data});
        {error, Error} ->
            {error, Error}
    end.


%% @doc Rejects a invitation notification
-spec reject_invitation(nkdomain:id(), nkdomain:id()) ->
    ok | {error, term()}.

reject_invitation(_SessId, TokenId) ->
    case nkdomain_token_obj:consume_token(TokenId, rejected) of
        {ok, _Data} ->
            ok;
        {error, Error} ->
            {error, Error}
    end.


%% @doc
wakeup(Id) ->
    nkdomain_obj:async_op(Id, {?MODULE, wakeup}).


%% @doc Called from nkchat_conversation_obj
-spec conversation_event(pid(), nkdomain:obj_id(), meta(), term()) ->
    ok.

conversation_event(Pid, ConvId, _Meta, Event) ->
    nkdomain_obj:async_op(Pid, {?MODULE, conversation_event, ConvId, Event}).


%% @private To be called from nkdomain_user_obj
-spec notify_fun(pid(), nkdomain_user_obj:notify_msg()) ->
    any.

notify_fun(Pid, Notify) ->
    nkdomain_obj:async_op(Pid, {?MODULE, notify_fun, Notify}).


%% @private To be called from nkdomain_user_obj
-spec presence_fun(nkdomain:user_id(), [nkdomain_user_obj:session_presence()]) ->
    {ok, nkdomain_user_obj:user_presence()}.

presence_fun(_UserId, []) ->
    % lager:info("NKLOG Chat Presence down"),
    {ok, #{status=><<"offline">>}};

presence_fun(_UserId, List) ->
    Status = case lists:member(<<"online">>, List) of
        true ->
            <<"online">>;
        false ->
            case lists:member(<<"inactive">>, List) of
                true ->
                    <<"inactive">>;
                false ->
                    <<"offline">>
            end
    end,
    {ok, #{status=>Status}}.


%% ===================================================================
%% nkdomain_obj behaviour
%% ===================================================================

-record(session, {
    user_id :: nkdomain:obj_id(),
    conv_pids :: #{nkdomain:obj_id() => {Data::map(), pid()}},
    active_id :: undefined | nkdomain:obj_id(),
    user_is_active :: boolean(),
    timer :: reference()
}).



%% @private
object_info() ->
    #{
        type => ?CHAT_SESSION,
        stop_after_disabled => true,
        remove_after_stop => true
    }.


%% @doc
object_admin_info() ->
    #{
        class => session,
        weight => 2000,
        type_view_mod => nkchat_session_obj_type_view
    }.


%% @private
object_es_mapping() ->
    #{
    }.


%% @private
object_parse(_Mode, _Obj) ->
    #{
    }.


%% @private
object_api_syntax(Cmd, Syntax) ->
    nkchat_session_obj_syntax:syntax(Cmd, Syntax).


%% @private
object_api_cmd(Cmd, Req) ->
    nkchat_session_obj_cmd:cmd(Cmd, Req).


%% @private
object_send_event(Event, State) ->
    nkchat_session_obj_events:event(Event, State).


%% @private When the object is loaded, we make our cache
object_init(#obj_state{id=Id, obj=Obj, domain_id=DomainId}=State) ->
    #obj_id_ext{obj_id=SessId} = Id,
    #{parent_id := UserId} = Obj,
    Session = #session{
        user_id = UserId,
        conv_pids = #{},
        user_is_active = true
    },
    State2 = State#obj_state{session=Session},
    ?LLOG(info, "start find conversations", [], State),
    {ok, Convs1} = nkchat_conversation_obj:find_member_conversations(DomainId, UserId),
    ?LLOG(info, "start adding conversations", [], State),
    State3 = lists:foldl(
        fun({ConvId, _Type}, Acc) ->
            case do_add_conv(ConvId, Acc) of
                {ok, Acc2} ->
                    Acc2;
                {error, Error} ->
                    ?LLOG(warning, "could not load conversation ~s: ~p", [ConvId, Error], State),
                    Acc
            end
        end,
        State2,
        Convs1),
    Opts = #{
        notify_fun => fun ?MODULE:notify_fun/2,
        presence_fun => fun ?MODULE:presence_fun/2,
        presence => <<"online">>
    },
    ok = nkdomain_user_obj:register_session(UserId, DomainId, ?CHAT_SESSION, SessId, Opts),
    State4 = nkdomain_obj_util:link_to_session_server(?MODULE, State3),
    ?LLOG(info, "start session ok", [], State),
    {ok, restart_timer(State4)}.


%% @private
object_stop(_Reason, State) ->
    {ok, nkdomain_obj_util:unlink_from_session_server(?MODULE, State)}.


%% @private
object_sync_op({?MODULE, get_conversations}, _From, #obj_state{session=Session}=State) ->
    #session{conv_pids=Convs} = Session,
    {reply, {ok, maps:keys(Convs)}, State};

object_sync_op({?MODULE, get_conversation_info, ConvId}, _From, #obj_state{session=Session}=State) ->
    #session{user_id=UserId} = Session,
    case get_conv_pid(ConvId, State) of
        {ok, Pid} ->
            case nkchat_conversation_obj:get_member_info(Pid, UserId) of
                {ok, Info} -> 
                    {reply, {ok, Info}, State};
                {error, Error} ->
                    {reply, {error, Error}, State}
            end;
        not_found ->
            {reply, {error, conversation_not_found}, State}
    end;

object_sync_op({?MODULE, set_active_conv, ConvId}, _From, State) ->
    State2 = set_user_active(State),
    case get_conv_pid(ConvId, State2) of
        {ok, _} ->
            {reply, ok, do_set_active_conv(ConvId, State2)};
        not_found ->
            {reply, {error, conversation_not_found}, State2}
    end;

object_sync_op({?MODULE, deactivate_conv}, _From, State) ->
    State2 = set_user_active(State),
    ConvId = undefined,
    {reply, ok, do_set_active_conv(ConvId, State2)};    

object_sync_op({?MODULE, add_conv, ConvId}, _From, State) ->
    case get_conv_pid(ConvId, State) of
        not_found ->
            case do_add_conv(ConvId, State) of
                {ok, State2} ->
                    ?DEBUG("added conversation ~s", [ConvId], State2),
                    State3 = do_event({conversation_added, ConvId}, State2),
                    {reply, {ok, ConvId}, State3};
                {error, Error} ->
                    {reply, {error, Error}, State}
            end;
        {ok, _} ->
            {reply, {error, conversation_is_already_present}, State}
    end;

object_sync_op({?MODULE, rm_conv, ConvId}, _From, State) ->
    case do_rm_conv(ConvId, State) of
        {ok, State2} ->
            ?DEBUG("removed conversation ~s", [ConvId], State2),
            {reply, ok, State2};
        {error, Error} ->
            {reply, {error, Error}, State}
    end;

object_sync_op({?MODULE, send_invitation, Member, Conv, TTL}, _From, State) ->
    #obj_state{domain_id=DomainId, parent_id=UserId, id=#obj_id_ext{obj_id=SessId}} = State,
    Reply = case nkchat_conversation_obj:add_invite_op(Conv, UserId, Member, #{}) of
        {ok, ConvId, MemberId, UserId, Op1} ->
            case nkdomain_user_obj:add_token_notification(MemberId, ?CHAT_SESSION, #{}, Op1) of
                {ok, MemberId, Op2} ->
                    Op3 = Op2#{
                        ?CHAT_SESSION => #{
                            <<"invited_to_conversation_op">> => #{
                                <<"session_id">> => SessId,
                                <<"conversation_id">> => ConvId,
                                <<"user_id">> => UserId,
                                <<"member_id">> => MemberId
                            }
                        }
                    },
                    TokenOpts = #{
                        parent_id => MemberId,
                        created_by => UserId,
                        subtype => <<"chat.invite">>,
                        ttl => TTL
                    },
                    case nkdomain_token_obj:create(DomainId, TokenOpts, Op3) of
                        {ok, TokenId, _Pid, _Secs} ->
                            {ok, TokenId};
                        {error, Error} ->
                            {error, Error}
                    end;
                {error, Error} ->
                    {error, Error}
            end;
        {error, Error} ->
            {error, Error}
    end,
    {reply, Reply, State};

object_sync_op({?MODULE, accept_invitation, Data}, _From, State) ->
    Reply = nkchat_conversation_obj:perform_op(Data),
    {reply, Reply, State};

object_sync_op(_Op, _From, _State) ->
    continue.


%% @private
object_async_op({?MODULE, conversation_event, ConvId, Event}, State) ->
    case get_conv_pid(ConvId, State) of
        {ok, _} ->
            do_conversation_event(Event, ConvId, State);
        not_found ->
            ?LLOG(warning, "received event ~p for unknown conversation", [Event], State),
            {noreply, State}
    end;

object_async_op({?MODULE, notify_fun, {token_created, TokenId, Msg}}, State) ->
    case Msg of
        #{
            ?CHAT_SESSION := #{
                <<"invited_to_conversation_op">> := #{
                    <<"conversation_id">> := ConvId,
                    <<"user_id">> := UserId,
                    <<"member_id">> := _MemberId
                }
            }
        } ->
            State2 = do_event({invited_to_conversation, TokenId, UserId, ConvId}, State),
            {noreply, State2};
        _ ->
            ?LLOG(warning, "unexpected notify: ~p", [Msg], State),
            {noreply, State}
    end;

object_async_op({?MODULE, launch_notifications}, State) ->
    #obj_state{id=#obj_id_ext{obj_id=SessId}, parent_id=UserId} = State,
    nkdomain_user_obj:launch_session_notifications(UserId, SessId),
    {noreply, State};

object_async_op({?MODULE, wakeup}, State) ->
    {noreply, set_user_active(State)};

object_async_op({?MODULE, notify_fun, {token_removed, TokenId, Reason}}, State) ->
    State2 = do_event({remove_notification, TokenId, Reason}, State),
    {noreply, State2};

object_async_op(_Op, _State) ->
    continue.


%% @private
object_handle_info({?MODULE, inactivity}, State) ->
    State2 = set_user_active(false, State),
    {noreply, State2};

object_handle_info(_Msg, _State) ->
    continue.


%% ===================================================================
%% Internal
%% ===================================================================


%% @private
do_set_active_conv(ConvId, #obj_state{session=Session, id=#obj_id_ext{obj_id=SessId}}=State) ->
    #session{user_id=UserId, conv_pids=ConvPids} = Session,
    do_set_active_conv(maps:to_list(ConvPids), ConvId, UserId, SessId),
    Session2 = Session#session{active_id=ConvId},
    State#obj_state{session=Session2}.


%% @private
do_set_active_conv([], _ActiveId, _UserId, _SessId) ->
    ok;

do_set_active_conv([{ConvId, Pid}|Rest], ActiveId, UserId, SessId) ->
    Active = (ActiveId == ConvId),
    nkchat_conversation_obj:set_session_active(Pid, UserId, SessId, Active),
    do_set_active_conv(Rest, ActiveId, UserId, SessId).

%% @private
do_add_conv(ConvId, State) ->
    #obj_state{id=#obj_id_ext{obj_id=SessId}} = State,
    #obj_state{session=Session} = State,
    #session{user_id=UserId, conv_pids=Convs1} = Session,
    case nkchat_conversation_obj:add_session(ConvId, UserId, SessId, #{}) of
        {ok, Pid} ->
            monitor(process, Pid),
            Convs2 = Convs1#{ConvId => Pid},
            Session2 = Session#session{conv_pids=Convs2},
            {ok, State#obj_state{session=Session2}};
        {error, Error} ->
            {error, Error}
    end.


%% @private
do_rm_conv(ConvId, State) ->
    case get_conv_pid(ConvId, State) of
        {ok, Pid} ->
            #obj_state{id=#obj_id_ext{obj_id=SessId}} = State,
            #obj_state{session=Session} = State,
            #session{user_id=UserId, conv_pids=ConvPids1, active_id=ActiveId} = Session,
            nkchat_conversation_obj:remove_session(Pid, UserId, SessId),
            ConvPids2 = maps:remove(ConvId, ConvPids1),
            Session2 = Session#session{conv_pids=ConvPids2},
            Session3 = case ActiveId of
                ConvId ->
                    Session2#session{active_id=undefined};
                _ ->
                    Session2
            end,
            State2 = do_event({conversation_removed, ConvId}, State),
            {ok, State2#obj_state{session=Session3}};
        not_found ->
            {error, conversation_not_found}
    end.


%% @private
do_conversation_event({member_added, MemberId}, ConvId, State) ->
    {noreply, do_event({member_added, ConvId, MemberId}, State)};

do_conversation_event({member_removed, MemberId}, ConvId, #obj_state{session=Session}=State) ->
    State2 = case Session of
        #session{user_id=MemberId} ->
            {ok, S} = do_rm_conv(ConvId, State),
            S;
        _ ->
            State
    end,
    {noreply, do_event({member_removed, ConvId, MemberId}, State2)};

do_conversation_event({message_created, Msg}, ConvId, State) ->
    {noreply, do_event({message_created, ConvId, Msg}, State)};

do_conversation_event({message_updated, Msg}, ConvId, State) ->
    {noreply, do_event({message_updated, ConvId, Msg}, State)};

do_conversation_event({message_deleted, MsgId}, ConvId, State) ->
    {noreply, do_event({message_deleted, ConvId, MsgId}, State)};

do_conversation_event({status_updated, Status}, ConvId, State) ->
    {noreply, do_event({status_updated, ConvId, Status}, State)};

do_conversation_event({is_closed_updated, IsClosed}, ConvId, State) ->
    {noreply, do_event({is_closed_updated, ConvId, IsClosed}, State)};

do_conversation_event({conversation_updated, Conv}, ConvId, State) ->
    {noreply, do_event({conversation_updated, ConvId, Conv}, State)};
        
do_conversation_event({counter_updated, Counter}, ConvId, State) ->
    {noreply, do_event({unread_counter_updated, ConvId, Counter}, State)};

do_conversation_event({session_removed, _UserId, _SessId}, _ConvId, State) ->
    % ?LLOG(info, "unexpected conversation event: session_removed (~s, ~s, ~s)", [UserId, SessId, ConvId], State),
    {noreply, State};

do_conversation_event(_Event, _ConvId, State) ->
    ?LLOG(warning, "unexpected conversation event: ~p", [_Event], State),
    {noreply, State}.


%% @private
get_conv_pid(ConvId, #obj_state{session=Session}) ->
    #session{conv_pids=Convs} = Session,
    case maps:find(ConvId, Convs) of
        {ok, Pid} ->
            {ok, Pid};
        error ->
            not_found
    end.

%% @private
do_event(Event, State) ->
    nkdomain_obj_util:event(Event, State).



%% @private
set_user_active(State) ->
    set_user_active(true, State).


%% @private
set_user_active(Active, #obj_state{session=#session{user_is_active=Active}} = State) ->
    State;

set_user_active(Active, #obj_state{id=Id, parent_id=UserId, session=Session} = State) ->
    #obj_id_ext{obj_id=SessId} = Id,
    Presence = case Active of
        true -> <<"online">>;
        false -> <<"inactive">>
    end,
    nkdomain_user_obj:update_presence(UserId, SessId, Presence),
    Session2 = Session#session{user_is_active=Active},
    State2 = State#obj_state{session=Session2},
    case Active of
        true ->
            restart_timer(State2);
        false ->
            State2
    end.


%% @private
restart_timer(#obj_state{session=#session{timer=Timer}=Session}=State) ->
    nklib_util:cancel_timer(Timer),
    Timer2 = erlang:send_after(?INACTIVITY_TIMER*1000, self(), {?MODULE, inactivity}),
    Session2 = Session#session{timer=Timer2},
    State#obj_state{session=Session2}.
