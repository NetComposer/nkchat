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

%% @doc Call Object
%%
%% Direct calls
%% ------------
%
%% - create call (enters new state)
%% - call invite
%%      - adds session
%%      - creates media session
%%      - enters ringing
%%


-module(nkchat_media_call_obj).
-behavior(nkdomain_obj).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-export([create/2, hangup/2, hangup_async/2]).
-export([add_session/3, remove_session/2, get_info/1]).
-export([invite/5, stop_media/3, answer_media/5]).
-export([find_member_calls/2, find_calls_with_members/2]).
-export([send_candidate/3, set_status/3]).
-export([heartbeat/1]).
-export([find_calls/0, remove_calls/0]).
-export([object_info/0, object_es_mapping/0, object_parse/2, object_create/1,
         object_api_syntax/2, object_api_cmd/2, object_send_event/2,
         object_init/1, object_save/1, object_stop/2, object_sync_op/3, object_async_op/2,
         object_handle_info/2]).
-export([object_next_status_timer/1, object_check_active/1]).
-export([object_admin_info/0]).
-export_type([event/0, session_event/0, member_session_event/0]).

-include("nkchat.hrl").
-include_lib("nkdomain/include/nkdomain.hrl").
-include_lib("nkdomain/include/nkdomain_debug.hrl").
-include_lib("nkservice/include/nkservice.hrl").


-define(MAX_NEW_TIME, 5).
-define(MAX_RINGING_TIME, 15).
-define(MAX_CALL_TIME, 4*60*60).


%% ===================================================================
%% Types
%% ===================================================================


-type invite_opts() ::
#{
    sdp => binary(),
    trickle_ice => boolean(),
    ttl => integer(),
    audio => boolean(),
    video => boolean(),
    screen => boolean(),
    conversation_id => binary(),
    ttl => integer(),
    meta => map()
}.

-type accept_opts() ::
#{
    sdp => binary(),
    trickle_ice => boolean(),
    audio => boolean,
    video => boolean,
    screen => boolean
}.


-type call_type() :: direct | one2one | room.

-type call_status() :: new | ringing | in_call.

-type role() :: binary().

-type candidate() :: #sdp_candidate{}.

-type session_status() ::
    #{
        audio => boolean(),
        video => boolean(),
        screen => boolean()
    }.

-type create_opts() ::
    #{
        type => call_type(),
        parent_id => nkdomain:id(),
        created_by => nkdomain:id(),
        obj_name => nkdomain:obj_name(),
        conversation_id => nkdomain:obj_id(),
        name => binary()
    }.


-type event() :: session_event().


%% Events sent to the sessions
-type session_event() ::
    {call_status, call_status()} |
    {session_added, SessId::nkdomain:obj_id(), User::nkdomain:obj_id(), #{}} |
    {session_removed, SessId::nkdomain:obj_id(), User::nkdomain:obj_id(), #{}} |
    {session_status, SessId::nkdomain:obj_id(), UserId::nkdomain:obj_id(), session_status()} |
    {call_hangup, Reason::nkservice:error(), Time::integer()}.


%% Events sent to a single member session
-type member_session_event() ::
    {media_ringing, MediaId::nkdomain:obj_id()} |
    {media_answered,  MediaId::nkdomain:obj_id(), Opts::accept_opts()} |
    {media_started, MediaId::nkdomain:obj_id()} |
    {media_stopped, MediaId::nkdomain:obj_id(), Reason::term()} |
    {new_candidate, candidate()}.



%% ===================================================================
%% Public
%% ===================================================================


%% @doc
-spec create(nkdomain:id(), create_opts()) ->
    {ok, CallId::nkdomain:id(), pid()} | {error, term()}.

create(Domain, #{type:=_}=Opts) ->
    Base = maps:with([parent_id, created_by, obj_name, name], Opts),
    CallObj = maps:with([type, conversation_id], Opts),
    Obj =Base#{
        type => ?MEDIA_CALL,
        domain_id => Domain,
        active => true,
        ?MEDIA_CALL => CallObj
    },
    case nkdomain_obj_make:create(Obj) of
        {ok, #obj_id_ext{obj_id=CallId, pid=Pid}, _} ->
            {ok, CallId, Pid};
        {error, Error} ->
            {error, Error}
    end.


%% @doc
-spec hangup(nkdomain:id(), nkservice:error()) ->
    ok | {error, term()}.

hangup(Id, Reason) ->
    nkdomain_obj:sync_op(Id, {?MODULE, hangup_call, Reason}).


%% @doc
-spec hangup_async(nkdomain:id(), nkservice:error()) ->
    ok | {error, term()}.

hangup_async(Id, Reason) ->
    nkdomain_obj:async_op(Id, {?MODULE, hangup_call, Reason}).


%% @doc Registers an user session
-spec add_session(nkdomain:id(), nkdomain:obj_id(), nkdomain:obj_id()) ->
    ok | {error, term()}.

add_session(Id, SessId, UserId) ->
    nkdomain_obj:sync_op(Id, {?MODULE, add_session, SessId, self(), UserId}).


%% @doc
-spec remove_session(nkdomain:id(), nkdomain:obj_id()) ->
    ok | {error, term()}.

remove_session(Id, SessId) ->
    nkdomain_obj:sync_op(Id, {?MODULE, remove_session, SessId}).


%% @private
get_info(Pid) ->
    nkdomain_obj:sync_op(any, Pid, {?MODULE, get_info}).

%% @doc Valid for direct calls, adds the session and starts the invite
-spec invite(nkdomain:id(), nkdomain:obj_id(), nkdomain:obj_id(), nkdomain:obj_id(), invite_opts()) ->
    ok | {error, term()}.

invite(Id, MediaId, SessId, UserId, InviteOpts) ->
    nkdomain_obj:sync_op(Id, {?MODULE, invite, MediaId, SessId, self(), UserId, InviteOpts}).


%% @doc Accepts a invitation notification in a direct call
-spec answer_media(nkdomain:id(), nkdomain:obj_id(), nkdoman:obj_id(), nkdomain:id(), accept_opts()) ->
    {ok, CallId::nkdomain:obj_id(), pid()} | {error, term()}.

answer_media(CallId, MediaId, SessId, UserId, AcceptOpts) ->
    nkdomain_obj:sync_op(CallId, {?MODULE, answer_media, MediaId, SessId, self(), UserId, AcceptOpts}).


%% @doc
stop_media(CallId, MediaId, Reason) ->
    nkdomain_obj:async_op(CallId, {?MODULE, stop_media, MediaId, Reason}).


%% @doc
heartbeat(CallId) ->
    nkdomain_obj:async_op(CallId, {?MODULE, heartbeat}).


%% @doc
find_member_calls(Domain, MemberId) ->
    case nkdomain_lib:find(Domain) of
        #obj_id_ext{type=?DOMAIN_DOMAIN, obj_id=DomainId} ->
            Filters = #{
                type => ?MEDIA_CALL,
                domain_id => DomainId,
                << ?MEDIA_CALL/binary, ".members.member_id">> => MemberId
            },
            Search2 = #{
                fields => [<<?MEDIA_CALL/binary, ".type">>],
                filters => Filters,
                size => 9999
            },
            case nkdomain:search(Search2) of
                {ok, _N, List, _Meta} ->
                    List2 = lists:map(
                        fun(#{<<"obj_id">>:=CallId, ?MEDIA_CALL:=#{<<"type">>:=Type}}) -> {CallId, Type} end,
                        List),
                    {ok, List2};
                {error, Error} ->
                    {error, Error}
            end;
        _ ->
            {error, domain_unknown}
    end.


%% @doc
find_calls_with_members(Domain, MemberIds) ->
    case nkdomain_lib:find(Domain) of
        #obj_id_ext{type=?DOMAIN_DOMAIN, obj_id=DomainId} ->
            Hash = get_members_hash(MemberIds),
            Filters = #{
                type => ?MEDIA_CALL,
                domain_id => DomainId,
                << ?MEDIA_CALL/binary, ".members_hash">> => Hash
            },
            Search2 = #{
                fields => [<<?MEDIA_CALL/binary, ".type">>],
                filters => Filters,
                size => 9999
            },
            case nkdomain:search(Search2) of
                {ok, _N, List, _Meta} ->
                    List2 = lists:map(
                        fun(#{<<"obj_id">>:=CallId, ?MEDIA_CALL:=#{<<"type">>:=Type}}) -> {CallId, Type} end,
                        List),
                    {ok, List2};
                {error, Error} ->
                    {error, Error}
            end;
        _ ->
            {error, domain_unknown}
    end.


%% @doc
-spec send_candidate(nkdomain:obj_id(), nkdomain:obj_id(), #sdp_candidate{}) ->
    ok | {error, term()}.

send_candidate(CallId, SessId, Candidate) ->
    nkdomain_obj:sync_op(CallId, {?MODULE, send_candidate, SessId, Candidate}).


%% @doc
-spec set_status(nkdomain:obj_id(), nkdomain:obj_id(), session_status()) ->
    ok | {error, term()}.

set_status(CallId, SessId, Status) ->
    nkdomain_obj:sync_op(CallId, {?MODULE, set_status, SessId, Status}).


find_calls() ->
    nkdomain:search(#{filters=>#{type=>?MEDIA_CALL}}).

remove_calls() ->
    nkdomain:delete_all_childs_type("/", ?MEDIA_CALL).


%% =================================================================
%% nkdomain_obj behaviour
%% ===================================================================


-record(member_session, {
    session_id :: nkdomain_obj:id(),
    user_id :: nkdomain:obj_id(),
    session_pid :: pid(),
    session_mon :: reference()
}).


-record(media_session, {
    type :: direct,
    status :: ringing | answered,
    media_id :: nkdomain_obj:id(),
    timer :: reference(),
    caller_session_id = <<>> :: nkdomain_obj:id(),
    caller_opts = #{} :: invite_opts(),
    caller_status = #{} :: session_status(),
    caller_candidates = [],
    callee_session_id = <<>> :: nkdomain_obj:id(),     % For other than 'direct' would be the MS
    callee_opts = #{} :: invite_opts(),
    callee_status = #{} :: session_status()
}).


-record(session, {
    type :: call_type(),
    status :: call_status(),
    message_id = <<>> :: nkdomain:obj_id(),
    roles :: #{MemberId::nkdomain:obj_id() => [role()]},
    members :: [#member_session{}],
    medias :: [#media_session{}]
}).



%% @private
object_info() ->
    #{
        type => ?MEDIA_CALL,
        stop_after_disabled => true,
        remove_after_stop => true
    }.

%% @doc
object_admin_info() ->
    #{
        class => session,
        weight => 2000,
        tree_id => <<"domain_tree_sessions_media.calls">>
    }.


%% @private
object_es_mapping() ->
    #{
        type => #{type => keyword},
        conversation_id => #{type => keyword},
        message_id => #{type => keyword},
        started_time => #{type => date},
        stopped_time => #{type => date},
        members_hash => #{type => keyword},
        members => #{
            type => object,
            dynamic => false,
            properties => #{
                member_id => #{type => keyword}
            }
        }
    }.


%% @private
object_parse(update, _Obj) ->
    #{};

object_parse(_Mode, _Obj) ->
    #{
        type => {atom, [direct, one2one, room]},
        conversation_id => binary,
        started_time => binary,
        stopped_time => binary,
        message_id => binary,
        members_hash => binary,
        members =>
            {list,
                 #{
                     member_id => binary,
                     '__mandatory' => [member_id]
                 }
            },
        '__defaults' => #{type => direct, members => []}
    }.


%% @doc
object_create(Obj) ->
    #{?MEDIA_CALL := Call} = Obj,
    Obj2 = Obj#{?MEDIA_CALL => Call#{members => []}},
    nkdomain_obj_make:create(Obj2).


%% @private
object_send_event(Event, State) ->
    nkchat_media_call_events:event(Event, State).


%% @private
object_api_syntax(Cmd, Syntax) ->
    nkchat_media_call_obj_syntax:syntax(Cmd, Syntax).


%% @private
object_api_cmd(Cmd, Req) ->
    nkchat_media_call_obj_cmd:cmd(Cmd, Req).


%% @private
%% Client must start a session or it will be destroyed after timeout
object_init(#obj_state{obj=Obj}=State) ->
    #{?MEDIA_CALL := #{type:=Type}=CallObj} = Obj,
    Session1 = #session{
        type = Type,
        roles = #{},
        members = [],
        medias = []
    },
    Session2 = case maps:find(conversation_id, CallObj) of
        {ok, ConvId} ->
            case create_chat_msg(ConvId, State) of
                {ok, MsgId} ->
                    Session1#session{message_id=MsgId};
                {error, Error} ->
                    ?LLOG(warning, "could not create msg at ~s: ~p", [ConvId, Error], State),
                    <<>>
            end;
        error ->
            Session1
    end,
    Obj2 = case CallObj of
        #{started_time:=_} ->
            Obj;
        _ ->
            CallObj2 = CallObj#{started_time=>nkdomain_util:timestamp()},
            ?ADD_TO_OBJ(?MEDIA_CALL, CallObj2, Obj)
    end,
    State2 = State#obj_state{session=Session2, obj=Obj2},
    State3 = update_call_status(new, State2),
    {ok, State3}.


%% @private Prepare the object for saving
object_save(#obj_state{obj=Obj, session=Session}=State) ->
    #session{type=Type, status=Status, members=Members} = Session,
    MemberList= lists:map(
        fun(#member_session{user_id = UserId}) ->
            #{
                member_id => UserId
            }
        end,
        Members),
    #{?MEDIA_CALL:=Call1} = Obj,
    Call2 = Call1#{type=>Type, status=>Status, members=>MemberList},
    Obj2 = ?ADD_TO_OBJ(?MEDIA_CALL, Call2, Obj),
    {ok, State#obj_state{obj = Obj2}}.


%% @private
object_stop(_Reason, State) ->
    {ok, do_hangup(object_stopped, State)}.


%% @private
object_sync_op({?MODULE, get_info}, _From, State) ->
    #obj_state{obj=Obj, session=Session} = State,
    #session{type=Type} = Session,
    Data = #{
        name => maps:get(name, Obj, <<>>),
        description => maps:get(description, Obj, <<>>),
        type => Type,
        members => expand_members(State)
    },
    {reply, {ok, Data}, State};


object_sync_op({?MODULE, add_session, SessId, Pid, UserId}, _From, State) ->
    State2 = add_member_session(SessId, Pid, UserId, State),
    {reply, ok, State2};

object_sync_op({?MODULE, remove_session, SessId}, _From, State) ->
    case rm_member_session(SessId, State) of
        {ok, State2} ->
            {reply, ok, State2};
        {error, Error} ->
            {reply, {error, Error}, State}
    end;

object_sync_op({?MODULE, invite, MediaId, SessId, Pid, UserId, InviteOpts}, _From, State) ->
    case get_type_status(State) of
        {direct, new} ->
            case State of
                #obj_state{session=#session{members=[], medias=[]}} ->
                    State2 = add_member_session(SessId, Pid, UserId, State),
                    case do_invite(MediaId, SessId, InviteOpts, State2) of
                        {ok, MediaId, State3} ->
                            State4 = update_call_status(ringing, State3),
                            {reply, ok, State4};
                        {error, Error} ->
                            {reply, {error, Error}, State2}
                    end;
                _ ->
                    {reply, {error, call_status_invalid}, State}
            end;
        _ ->
            {reply, {error, call_status_invalid}, State}
    end;

object_sync_op({?MODULE, answer_media, MediaId, CalleeSessId, CalleeSessPid, CalleeId, AcceptOpts}, _From, State) ->
    case get_media_session(MediaId, State) of
        #media_session{status=ringing, caller_session_id=CallerSessId, timer=Timer}=Media ->
            nklib_util:cancel_timer(Timer),
            State2 = add_member_session(CalleeSessId, CalleeSessPid, CalleeId, State),
            Media2 = Media#media_session{
                status = answered,
                timer = undefined,
                callee_session_id = CalleeSessId,
                callee_opts = AcceptOpts,
                caller_status = #{}
            },
            State3 = update_media_session(Media2, State2),
            do_member_session_event(CallerSessId, {media_answered, MediaId, AcceptOpts}, State3),
            do_member_session_event(CalleeSessId, {media_started, MediaId}, State3),
            State4 = send_stored_candidates(Media2, State3),
            State5 = update_call_status(in_call, State4),
            #obj_state{id=#obj_id_ext{obj_id=CallId}} = State5,
            {reply, {ok, CallId, self()}, State5};
        #media_session{} ->
            {reply, {error, media_already_answered}, State};
        not_found ->
            {reply, {error, media_not_found}, State}
    end;

object_sync_op({?MODULE, hangup_call, Reason}, _From, State) ->
    State2 = do_hangup(Reason, State),
    {stop, normal, ok, State2};

object_sync_op({?MODULE, send_candidate, SessId, Candidate}, _From, State) ->
    case get_media_session_session(SessId, State) of
        {caller, #media_session{callee_session_id=Remote, caller_candidates=Candidates}=MS} ->
            case Remote of
                <<>> ->
                    MS2 = MS#media_session{caller_candidates=[Candidate|Candidates]},
                    State2 = update_media_session(MS2, State),
                    {reply, ok, State2};
                _ ->
                    do_member_session_event(Remote, {new_candidate, Candidate}, State),
                    {reply, ok, State}
            end;
        {callee, #media_session{caller_session_id=Remote}} ->
            do_member_session_event(Remote, {new_candidate, Candidate}, State),
            {reply, ok, State};
        not_found ->
            {reply, {error, session_not_found}, State}
    end;

object_sync_op({?MODULE, set_status, SessId, Status}, _From, State) ->
    case get_member_session(SessId, State) of
        #member_session{user_id=UserId} ->
            case get_media_session_session(SessId, State) of
                 {caller, #media_session{caller_status=OldStatus}=Media} ->
                    NewStatus = maps:merge(OldStatus, Status),
                    Media2 = Media#media_session{caller_status=NewStatus},
                     State2 = update_media_session(Media2, State),
                    do_all_member_sessions_event({session_status, SessId, UserId, Status}, State),
                    {reply, ok, State2};
                {callee, #media_session{callee_status=OldStatus}=Media} ->
                    NewStatus = maps:merge(OldStatus, Status),
                    Media2 = Media#media_session{callee_status=NewStatus},
                    State2 = update_media_session(Media2, State),
                    do_all_member_sessions_event({session_status, SessId, UserId, Status}, State),
                    {reply, ok, State2};
                not_found ->
                    {reply, {error, session_not_found}, State}
            end;
        not_found ->
            {reply, {error, session_not_found}, State}
    end;

object_sync_op(_Op, _From, _State) ->
    continue.


%% @private
object_async_op({?MODULE, heartbeat}, State) ->
    State2 = case get_type_status(State) of
        {direct, in_call} ->
            update_call_status(in_call, State);
        _ ->
            State

    end,
    {noreply, State2};

object_async_op({?MODULE, stop_media, MediaId, Reason}, State) ->
    State2 = case get_media_session(MediaId, State) of
        #media_session{}=Media ->
            rm_media_session(Media, Reason, State);
        not_found ->
            State
    end,
    {noreply, State2};

object_async_op({?MODULE, hangup_call, Reason}, State) ->
    State2 = do_hangup(Reason, State),
    {stop, normal, State2};

object_async_op(_Op, _State) ->
    continue.


%% @private
object_handle_info({?MODULE, ringing_timeout, MediaId}, State) ->
    case get_media_session(MediaId, State) of
        #media_session{status=ringing}=Media ->
            State2 = rm_media_session(Media, ring_timeout, State),
            {noreply, State2};
        _ ->
            ?LLOG(notice, "received ringing_timeout for unknown media", [], State),
            {noreply, State}
    end;

object_handle_info({'DOWN', _Ref, process, Pid, _Reason}, State) ->
    #obj_state{session=#session{members=Members}} = State,
    case lists:keyfind(Pid, #member_session.session_pid, Members) of
        #member_session{session_id=SessId} ->
            State2 = rm_member_session(SessId, State),
            {noreply, State2};
        false ->
            continue
    end;

object_handle_info(_Info, _State) ->
    continue.


%% @doc
object_next_status_timer(#obj_state{session=#session{status=Status}}=State) ->
    ?LLOG(notice, "too long in '~s' status", [Status], State),
    hangup_async(self(), timeout),
    {ok, State}.


%% @private
object_check_active(_Id) ->
    lager:notice("NKLOG CALL Checked ~p", [_Id]),
    force_load.


%% ===================================================================
%% Internal
%% ===================================================================

%% @private
get_type_status(#obj_state{session=#session{type=Type, status=Status}}) ->
    {Type, Status}.


%% @doc
update_call_status(hangup, #obj_state{session=Session} = State) ->
    ?LLOG(info, "call is now in 'hangup' status", [], State),
    State2 = State#obj_state{session=Session#session{status=hangup}},
    update_chat_msg(State2);

update_call_status(Status, #obj_state{session=Session} = State) ->
    State2 = State#obj_state{session=Session#session{status=Status}},
    Time = case Status of
        new ->
            ?MAX_NEW_TIME;
        ringing ->
            ?MAX_RINGING_TIME;
        in_call ->
            ?MAX_CALL_TIME
    end,
    ?LLOG(info, "call is now in '~s' status (timeout:~p)", [Status, Time], State),
    State3 = nkdomain_obj_util:set_next_status_timer(Time*1000, State2),
    State4 = update_chat_msg(State3),
    do_all_member_sessions_event({call_status, Status}, State4).


%% @private
get_member_session(SessId, #obj_state{session=#session{members=Members}}) ->
    case lists:keyfind(SessId, #member_session.session_id, Members) of
        #member_session{}=Member ->
            Member;
        false ->
            not_found
    end.


%% @private
put_member_session(SessId, Member, #obj_state{session=#session{members=Members} = Session} = State) ->
    Members2 = lists:keystore(SessId, #member_session.session_id, Members, Member),
    Session2 = Session#session{members=Members2},
    State#obj_state{session=Session2}.


%% @private
add_member_session(SessId, Pid, UserId, State) ->
    case get_member_session(SessId, State) of
        #member_session{user_id=UserId, session_pid=Pid} ->
            State;
        not_found ->
            Member = #member_session{
                user_id = UserId,
                session_id = SessId,
                session_pid = Pid,
                session_mon = monitor(process, Pid)
            },
            State2 = put_member_session(SessId, Member, State),
            State3 = do_all_member_sessions_event({session_added, SessId, UserId, #{}}, State2),
            set_members_hash(State3)
    end.


%% @private
rm_member_session(SessId, #obj_state{session=Session} = State) ->
    #session{members=Members, medias=Medias} = Session,
    case lists:keytake(SessId, #member_session.session_id, Members) of
        {value, #member_session{user_id=UserId, session_mon=Mon}, Members2} ->
            demonitor(Mon),
            Session2 = Session#session{members=Members2},
            State2 = set_members_hash(State#obj_state{session=Session2}),
            State3 = do_all_member_sessions_event({session_removed, SessId, UserId, #{}}, State2),
            Medias = lists:filter(
                fun(#media_session{caller_session_id=Caller, callee_session_id=Callee}) ->
                    Caller==SessId orelse Callee==SessId
                end,
                Medias),
            % TODO: move to 'recover'
            State4 = rm_media_sessions(Medias, member_stopped, State3),
            {ok, State4};
        false ->
            {error, session_not_found}
    end.


%% @private
get_media_session(MediaId, #obj_state{session=#session{medias=Medias}}) ->
    case lists:keyfind(MediaId, #media_session.media_id, Medias) of
        #media_session{}=Media ->
            Media;
        false ->
            not_found
    end.


%% @private
get_media_session_session(SessId, #obj_state{session=#session{medias=Medias}}) ->
    case lists:keyfind(SessId, #media_session.caller_session_id, Medias) of
        #media_session{} = Media ->
            {caller, Media};
        false ->
            case lists:keyfind(SessId, #media_session.callee_session_id, Medias) of
                #media_session{} = Media ->
                    {callee, Media};
                false ->
                    not_found
            end
    end.


%% @private
update_media_session(#media_session{media_id=MediaId} = Media, #obj_state{session=Session} = State) ->
    #session{medias=Medias} = Session,
    Medias2 = lists:keystore(MediaId, #media_session.media_id, Medias, Media),
    Session2 = Session#session{medias=Medias2},
    State#obj_state{session=Session2}.


%% @private Removes a series of media sessions. If no one is remaining, stop
rm_media_sessions([], _Reason, State) ->
    State;

rm_media_sessions([#media_session{} = Media|Rest], Reason, State) ->
    State2 = rm_media_session(Media, Reason, State),
    rm_media_sessions(Rest, Reason, State2).


%% @private
rm_media_session(Media, Reason, #obj_state{session=Session} = State) ->
    #media_session{
        media_id = MediaId,
        caller_session_id = Caller,
        callee_session_id = Callee,
        timer = Timer
    } = Media,
    nklib_util:cancel_timer(Timer),
    #session{medias=Medias} = Session,
    do_member_session_event(Caller, {media_stopped, MediaId, Reason}, State),
    do_member_session_event(Callee, {media_stopped, MediaId, Reason}, State),
    Medias2 = lists:keydelete(MediaId, #media_session.media_id, Medias),
    case Medias2 of
        [] ->
            case get_type_status(State) of
                {direct, _} when length(Medias) < 2 ->
                    hangup_async(self(), no_remaining_medias);
                _ ->
                    ok
            end;
        _ ->
            ok
    end,
    Session2 = Session#session{medias=Medias2},
    State#obj_state{session=Session2}.


%% @private
do_invite(MediaId, SessId, InviteOpts, State) ->
    TTL = maps:get(ttl, InviteOpts, 30),
    Timer = erlang:send_after(1000*TTL, self(), {?MODULE, ringing_timeout, MediaId}),
    Media = #media_session{
        type = direct,
        status = ringing,
        media_id = MediaId,
        timer = Timer,
        caller_session_id = SessId,
        caller_opts = InviteOpts
    },
    State2 = update_media_session(Media, State),
    do_member_session_event(SessId, {media_ringing, MediaId}, State2),
    {ok, MediaId, State2}.


%% @private
do_hangup(Reason, State) ->
    case get_type_status(State) of
        {_, hangup} ->
            State;
        _ ->
            #obj_state{session=#session{medias=Medias}} = State,
            State2 = rm_media_sessions(Medias, call_hangup, State),
            Time = get_duration(State2),
            State3 = do_all_member_sessions_event({call_hangup, Reason, Time}, State2),
            update_call_status(hangup, State3)
    end.


%% @private
send_stored_candidates(#media_session{caller_candidates=[]}, State) ->
    State;

send_stored_candidates(Media, State) ->
    #media_session{callee_session_id=SessId, caller_candidates=Candidates} = Media,
    lists:foreach(
        fun(Candidate) -> do_member_session_event(SessId, {new_candidate, Candidate}, State) end,
        Candidates),
    Media2 = Media#media_session{caller_candidates=[]},
    update_media_session(Media2, State).


%% @private
do_member_session_event(Pid, Event, #obj_state{id=#obj_id_ext{obj_id=CallId}}) when is_pid(Pid) ->
    nkchat_media_session_obj:call_event(Pid, CallId, Event);

do_member_session_event(SessId, Event, State) ->
    case get_member_session(SessId, State) of
        #member_session{session_pid=Pid} when is_pid(Pid) ->
            do_member_session_event(Pid, Event, State);
        _ ->
            ok
    end.


%% @private
do_all_member_sessions_event(Event, State) ->
    #obj_state{session=#session{members=Members}} = State,
    State2 = do_all_member_sessions_event(Members, Event, State),
    do_event(Event, State2).


%% @private
do_all_member_sessions_event([], _Event, State) ->
    State;

do_all_member_sessions_event([#member_session{session_pid=Pid}|Rest], Event, #obj_state{} = State) ->
    do_member_session_event(Pid, Event, State),
    do_all_member_sessions_event(Rest, Event, State).


%% @private
do_event(Event, State) ->
    nkdomain_obj_util:event(Event, State).


%% @private
set_members_hash(#obj_state{obj=Obj, session=#session{members=Members}}=State) ->
    UserIds = [UserId || #member_session{user_id=UserId} <- Members],
    Hash = get_members_hash(UserIds),
    #{?MEDIA_CALL:=Call} = Obj,
    Call2 = Call#{members_hash=>Hash},
    Obj2 = ?ADD_TO_OBJ(?MEDIA_CALL, Call2, Obj),
    State#obj_state{obj=Obj2, is_dirty=true}.


%% @private
get_members_hash(MemberIds) ->
    MemberIds2 = lists:usort(MemberIds),
    base64:encode(crypto:hash(sha, erlang:term_to_binary(MemberIds2))).


%% @doc
expand_members(#obj_state{session=Session}) ->
    #session{members=Members} = Session,
    lists:map(
        fun(#member_session{user_id = MemberId}) ->
            #{
                member_id => MemberId
            }
        end,
        Members).


%% @private
create_chat_msg(ConvId, #obj_state{id=#obj_id_ext{obj_id=CallId}}) ->
    Msg = #{
        type => ?MEDIA_CALL,
        created_by => <<"admin">>,
        body => #{
            call_id => CallId,
            status => <<"ringing">>,
            member_ids => []
        },
        text => <<"Call ", CallId/binary, " created">>
    },
    case nkchat_message_obj:create(ConvId, Msg) of
        {ok, MsgId, _Pid} ->
            {ok, MsgId};
        {error, Error} ->
            {error, Error}
    end.


%% @private
update_chat_msg(#obj_state{session=#session{message_id = <<>>}}=State) ->
    State;

update_chat_msg(State) ->
    #obj_state{session=Session, id=#obj_id_ext{obj_id=CallId}} = State,
    #session{status=Status, members=Members, message_id=MsgId} = Session,
    Members2 = case Status of
        hangup ->
            [];
        _ ->
            [UserId || #member_session{user_id=UserId}<-Members]
    end,
    Status2 = nklib_util:to_binary(Status),
    Body1 = #{
        call_id => CallId,
        status => Status2,
        members => Members2,
        time => nkdomain_util:timestamp()
    },
    Body2 = case Status of
        hangup ->
            Body1#{duration => get_duration(State)};
        _ ->
            Body1
    end,
    Update = #{
        body => Body2,
        text => list_to_binary(["Call ", CallId, " status: ", Status2, " members: ", nklib_util:bjoin(Members2)])
    },
    case nkchat_message_obj:update(MsgId, Update) of
        ok ->
            ok;
        {error, Error} ->
            ?LLOG(warning, "could not update msg ~s: ~p", [MsgId, Error], State)
    end,
    State.


%% @private
get_duration(#obj_state{obj=#{?MEDIA_CALL:=#{started_time:=Start}}}) ->
    (nkdomain_util:timestamp() - Start) div 1000.
