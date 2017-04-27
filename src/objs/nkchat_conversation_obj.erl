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

%% @doc Conversation Object
%% Messages having this conversation call message_event/2, and this object
%% will send events message_created, deleted, updated.
%%
%% You can add and remove members (and stores member creation date)
%% You can attach sessions to existing members, with any metadata
%% All sessions events are forwarded to the session in object_event/2

-module(nkchat_conversation_obj).
-behavior(nkdomain_obj).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-export([create/4, add_member/3, remove_member/3, add_session/4, remove_session/2]).
-export([get_messages/3, get_member_conversations/3]).
-export([message_event/2]).
-export([object_get_info/0, object_mapping/0, object_syntax/1,
         object_api_syntax/3, object_api_allow/4, object_api_cmd/4, object_send_event/2,
         object_init/1, object_start/1,  object_restore/1, object_sync_op/3, object_async_op/2,
         object_event/2]).
-export_type([events/0]).

-include("nkchat.hrl").
-include_lib("nkdomain/include/nkdomain.hrl").
-include_lib("nkdomain/include/nkdomain_debug.hrl").
-include_lib("nkservice/include/nkservice.hrl").


%% ===================================================================
%% Types
%% ===================================================================



-type events() ::
    {message_created, nkdomain:obj()} |
    {message_updated, nkdomain:obj()} |
    {message_deleted, nkdomain:obj_id()} |
    {added_member, nkdomain:obj_id()} |
    {added_to_conversation, nkdomain:obj_id()} |        % Same but obj_id is for the member
    {removed_member, nkdomain:obj_id()} |
    {removed_from_conversation, nkdomain:obj_id()} |    % Same but obj_id is for the member
    {added_session, Member::nkdomain:obj_id(), SessId::nkdomain:obj_id()} |
    {removed_session, Member::nkdomain:obj_id(), SessId::nkdomain:obj_id()}.



%% ===================================================================
%% Public
%% ===================================================================

%% @doc
%% Data must follow object's syntax
-spec create(nkservice:id(), nkdomain:id(), nkdomain:name(), binary()) ->
    {ok, nkdomain:obj_id(), nkdomain:path(), pid()} | {error, term()}.

create(Srv, Domain, Name, Desc) ->
    Opts = #{
        name => Name,
        description => Desc,
        type_obj => #{members => []}
    },
    nkdomain_obj_lib:make_and_create(Srv, Domain, ?CHAT_CONVERSATION, Opts).


%% @doc Members will be changed for roles

-spec add_member(nkservice:id(), nkdomain:id(), nkdomain:id()) ->
    {ok, nkdomain:obj_id()} | {error, term()}.

add_member(Srv, Id, MemberId) ->
    sync_op(Srv, Id, {?MODULE, add_member, MemberId}).


%% @doc
-spec remove_member(nkservice:id(), nkdomain:id(), nkdomain:id()) ->
    ok | {error, term()}.

remove_member(Srv, Id, MemberId) ->
    sync_op(Srv, Id, {?MODULE, remove_member, MemberId}).


%% @private Called from nkchat_session_obj
%% Sessions receive notifications for every message, calling

add_session(ConvId, MemberId, SessId, Meta) ->
    nkdomain_obj:sync_op(ConvId, {?MODULE, add_session, MemberId, SessId, Meta}).


%% @private Called from nkchat_session_obj
%% Sessions receive notifications for every message, calling

remove_session(ConvId, SessId) ->
    nkdomain_obj:sync_op(ConvId, {?MODULE, remove_session, SessId}).


%% @doc
get_member_conversations(Srv, Domain, MemberId) ->
    case nkdomain_obj_lib:find(Srv, Domain) of
        #obj_id_ext{srv_id=SrvId, path=DomainPath} ->
            Filters = #{
                type => ?CHAT_CONVERSATION,
                childs_of => DomainPath,
                << ?CHAT_CONVERSATION/binary, ".member_ids">> => MemberId
            },
            Search2 = #{
                sort => [#{created_time => #{order => desc}}],
                fields => [created_time, path, description, <<?CHAT_CONVERSATION/binary, ".member_ids">>],
                filters => Filters
            },
            case nkdomain_store:find(SrvId, Search2) of
                {ok, N, List, _Meta} ->
                    {ok, #{total=>N, data=>List}};
                {error, Error} ->
                    {error, Error}
            end;
        {error, object_not_found} ->
            {error, domain_unknown};
        {error, Error} ->
            {error, Error}
    end.


%% @doc
get_messages(Srv, Id, Spec) ->
    case nkdomain_obj_lib:load(Srv, Id, #{}) of
        #obj_id_ext{srv_id=SrvId, obj_id=ConvId} ->
            Search1 = maps:with([from, size], Spec),
            Filters1 = #{
                type => ?CHAT_MESSAGE,
                parent_id => ConvId
            },
            Filters2 = case Spec of
                #{start_date:=Date} ->
                    Filters1#{created_time => {Date, none}};
                _ ->
                    Filters1
            end,
            Search2 = Search1#{
                sort => [#{created_time => #{order => desc}}],
                fields => [created_time, ?CHAT_MESSAGE, created_by],
                filters => Filters2
            },
            case nkdomain_store:find(SrvId, Search2) of
                {ok, N, List, _Meta} ->
                    List2 = lists:map(
                        fun(#{<<"created_by">>:=MemberId}=D) -> add_user(SrvId, MemberId, D) end,
                        List),
                    {ok, #{total=>N, data=>List2}};
                {error, Error} ->
                    {error, Error}
            end;
        {error, object_not_found} ->
            {error, conversation_not_found};
        {error, Error} ->
            {error, Error}
    end.


%% @private Called from nkchat_message_obj
%% When an event is received a conversation-level is sent to the Erlang layer
%% Is is captured at object_event/2 and sent to the sessions in send_to_sessions/3
message_event(ConvId, Event) ->
    Event2 = case Event of
        {created, Msg} -> {message_created, Msg};
        {deleted, MsgId} -> {message_deleted, MsgId};
        {updated, Msg} -> {messaged_updated, Msg};
        _ -> ignore
    end,
    case Event2 of
        ignore ->
            ok;
        _ ->
            nkdomain_obj:send_event(ConvId, Event2)
    end.


%% =================================================================
%% nkdomain_obj behaviour
%% ===================================================================

-record(?MODULE, {
    members = [] :: [{nkdomain:obj_id(), map()}],
    sessions = #{} :: #{SessId::nkdomain:obj_id() => map()},
    meta = #{} :: map()
}).


%% @private
object_get_info() ->
    #{
        type => ?CHAT_CONVERSATION,
        min_first_time => 5*60*1000,
        dont_create_childs_on_disabled => true,
        dont_update_on_disabled => true
    }.


%% @private
object_mapping() ->
    #{
        members => #{
            type => object,
            dynamic => false,
            properties => #{
                member_id => #{type => keyword},
                added_time => #{type => date},
                session_ids => #{type => keyword}
            }
        }
    }.


%% @private
object_syntax(_) ->
    #{
        members => {list,
            {syntax, #{
                member_id => binary,
                added_time => integer,
                session_ids => {list, binary},
                '__mandatory' => [
                    <<?CHAT_CONVERSATION/binary, ".members.member_id">>
                ]
            }}}
    }.


%% @private
object_send_event(Event, Session) ->
    nkchat_conversation_obj_events:event(Event, Session).


%% @private Send every event to my sessions
object_event(Event, #obj_session{srv_id=SrvId, obj_id=ConvId, data=Data}=Session) ->
    #?MODULE{sessions=SessMetas1} = Data,
    SessMetas2 = maps:to_list(SessMetas1),
    nkchat_session_obj:conversation_event(SrvId, Event, ConvId, SessMetas2),
    {ok, Session}.


%% @private
object_api_syntax(Sub, Cmd, Syntax) ->
    nkchat_conversation_obj_syntax:api(Sub, Cmd, Syntax).


%% @private
object_api_allow(_Sub, _Cmd, _Data, State) ->
    {true, State}.


%% @private
object_api_cmd(Sub, Cmd, Data, State) ->
    nkchat_conversation_obj_api:cmd(Sub, Cmd, Data, State).


%% @private
object_init(Session) ->
    {ok, Session#obj_session{data=#?MODULE{}}}.


%% @private When the object is loaded, we make our cache
object_start(#obj_session{obj=Obj}=Session) ->
    #{?CHAT_CONVERSATION := #{members := MemberList}} = Obj,
    % It should not take a lot of memory, it is a copy
    Data = #?MODULE{
        members = [{Id, M} || #{member_id:=Id} = M <- MemberList]
    },
    {ok, Session#obj_session{data=Data}}.


%% @private Prepare the object for saving
object_restore(#obj_session{obj = Obj, data = #?MODULE{} = Data} = Session) ->
    #?MODULE{members = Members} = Data,
    Values = [M || {_, M} <- Members],
    Obj2 = ?ADD_TO_OBJ(?CHAT_CONVERSATION, #{members=>Values}, Obj),
    {ok, Session#obj_session{obj = Obj2}}.


%% @private
object_sync_op({?MODULE, add_member, Id}, _From, #obj_session{obj_id=ConvId}=Session) ->
    case add_member(Id, Session) of
        {ok, MemberId, Session2} ->
            Event1 = {added_member, MemberId},
            Session3 = nkdomain_obj_util:event(Event1, Session2),
            Event2 = {added_to_conversation, MemberId},
            Session4 = nkdomain_obj_util:event(Event2, Session3),
            {reply_and_save, {ok, MemberId}, Session4};
        {error, Error} ->
            {reply, {error, Error}, Session}
    end;

object_sync_op({?MODULE, remove_member, Id}, _From, Session) ->
    case rm_member(Id, Session) of
        {ok, MemberId, Session2} ->
            Event1 = {removed_member, MemberId},
            Session3 = nkdomain_obj_util:event(Event1, Session2),
            Event2 = {removed_from_conversation, MemberId},
            Session4 = nkdomain_obj_util:event(Event2, Session3),
            {reply_and_save, ok, Session4};
        {error, Error} ->
            {reply, {error, Error}, Session}
    end;

object_sync_op({?MODULE, add_session, MemberId, SessId, Meta}, _From, Session) ->
    case do_add_session(MemberId, SessId, Meta, Session) of
        {ok, Session2} ->
            Event = {added_session, MemberId, SessId},
            Session3 = nkdomain_obj_util:event(Event, Session2),
            {reply_and_save, ok, Session3};
        {error, Error} ->
            {reply, {error, Error}, Session}
    end;

object_sync_op({?MODULE, remove_session, SessId}, _From, Session) ->
    case do_rm_session(SessId, Session) of
        {ok, MemberId, Session2} ->
            Event = {removed_session, MemberId, SessId},
            Session3 = nkdomain_obj_util:event(Event, Session2),
            {reply_and_save, ok, Session3};
        {error, Error} ->
            {reply, {error, Error}, Session}
    end;

object_sync_op(_Op, _From, _Session) ->
    continue.


%% @private
object_async_op(_Op, _Session) ->
    continue.




%% ===================================================================
%% Internal
%% ===================================================================

%% @private
sync_op(Srv, Id, Op) ->
    nkdomain_obj_lib:sync_op(Srv, Id, ?CHAT_CONVERSATION, Op, conversation_not_found).


%%%% @private
%%async_op(Srv, Id, Op) ->
%%    nkdomain_obj_lib:async_op(Srv, Id, ?CHAT_CONVERSATION, Op, conversation_not_found).


%% @private
find_member(Id, #obj_session{srv_id=SrvId}=Session) ->
    Members = get_members(Session),
    case lists:keyfind(Id, 1, Members) of
        {_, Member} ->
            {true, Id, Member, Members};
        false ->
            case nkdomain_obj_lib:find(SrvId, Id) of
                #obj_id_ext{obj_id=ObjId} ->
                    case lists:keyfind(ObjId, 1, Members) of
                        {_, Member} ->
                            {true, ObjId, Member, Members};
                        false ->
                            {false, ObjId, Members}
                    end;
                {error, Error} ->
                    {error, Error}
            end
    end.


%% @private
add_member(Id, Session) ->
    case find_member(Id, Session) of
        {false, MemberId, Members} ->
            Member = #{
                member_id => MemberId,
                added_time => nklib_util:m_timestamp(),
                session_ids => []
            },
            Members2 = lists:keystore(MemberId, 1, Members, {MemberId, Member}),
            {ok, MemberId, set_members(Members2, Session)};
        {true, _, _, _} ->
            {error, member_already_present};
        {error, object_not_found} ->
            {error, member_not_found};
        {error, Error} ->
            {error, Error}
    end.


%% @private
rm_member(Id, Session) ->
    case find_member(Id, Session) of
        {true, MemberId, Member, Members} ->
            SessionIds = maps:get(session_ids, Member, []),
            #obj_session{data=#?MODULE{sessions=SessMetas}=Data} = Session,
            SessMetas2 = maps:without(SessionIds, SessMetas),
            Data2 = Data#?MODULE{sessions=SessMetas2},
            Members2 = lists:keydelete(MemberId, 1, Members),
            {ok, MemberId, set_members(Members2, Session#obj_session{data=Data2})};
        {false, _, _} ->
            {error, member_not_found};
        {error, Error} ->
            {error, Error}
    end.


%% @private
do_add_session(Id, SessionId, Meta, Session) ->
    case find_member(Id, Session) of
        {true, MemberId, Member, Members} ->
            SessionIds1 = maps:get(session_ids, Member, []),
            Session2 = case lists:member(SessionId, SessionIds1) of
                false ->
                    SessionIds2 = [SessionId|SessionIds1],
                    Member2 = Member#{session_ids=>SessionIds2},
                    Members2 = lists:keystore(MemberId, 1, Members, {MemberId, Member2}),
                    set_members(Members2, Session);
                true ->
                    % It will not set is_dirty
                    Session
            end,
            #obj_session{data=#?MODULE{sessions=SessMetas}=Data} = Session2,
            Meta2 = Meta#{member_id=>MemberId},
            SessMetas2 = SessMetas#{SessionId => Meta2},
            Data2 = Data#?MODULE{sessions=SessMetas2},
            {ok, Session2#obj_session{data=Data2}};
        {false, _, _} ->
            {error, member_not_found};
        {error, Error} ->
            {error, Error}
    end.


%% @private
do_rm_session(SessionId, Session) ->
    #obj_session{data=#?MODULE{sessions=SessMetas}=Data} = Session,
    case maps:find(SessionId, SessMetas) of
        {ok, #{member_id:=MemberId}} ->
            SessMetas2 = maps:remove(SessionId, SessMetas),
            Data2 = Data#?MODULE{sessions=SessMetas2},
            {true, MemberId, Member, Members} = find_member(MemberId, Session),
            SessionIds1 = maps:get(session_ids, Member, []),
            SessionIds2 = SessionIds1 -- [SessionId],
            Member2 = Member#{session_ids=>SessionIds2},
            Members2 = lists:keystore(MemberId, 1, Members, {MemberId, Member2}),
            {ok, MemberId, set_members(Members2, Session#obj_session{data=Data2})};
        error ->
            {error, session_not_found}
    end.


%% @private
get_members(#obj_session{data=#?MODULE{members=Members}}) ->
    Members.


%% @private
set_members(Members, #obj_session{data=#?MODULE{}=Data}=Session) ->
    Session#obj_session{data=Data#?MODULE{members=Members}, is_dirty=true}.


%%%% @private
%%send_to_sessions([], _Event, _Session) ->
%%    ok;
%%
%%send_to_sessions([{SessId, Meta}|Rest], Event, #obj_session{srv_id=SrvId, obj_id=ConvId}=Session) ->
%%    #obj_session{data=#?MODULE{sessions=SessMetas}} = Session,
%%    SessionIds1 = maps:get(session_ids, Member, []),
%%    SessionIds2 = [{Id, maps:get(Id, SessMetas, #{})} || Id <- SessionIds1],
%%    nkchat_session_obj:conversation_event(SrvId, ConvId, SessionIds2, Event),
%%    send_to_sessions(Rest, Event, Session).


%% @private
add_user(SrvId, UserId, Data) ->
    case nkdomain_user_obj:get_name(SrvId, UserId) of
        {ok, User} -> Data#{user=>User#{obj_id=>UserId}};
        {error, _} -> Data#{user=>#{}}
    end.



%%%% @private
%%send_event(Event, Push, #obj_session{data=Data}=Session) ->
%%    Members = get_members(Session),
%%    #?MODULE{sessions=Sessions} = Data,
%%    send_event_sessions(maps:to_list(Sessions), Event, Push, Session),
%%    case Push of
%%        with_push ->
%%            send_event_members(Members, Event, Sessions, Session);
%%        without_push ->
%%            ok
%%    end.


%%%% @private
%%send_event_sessions([], _Event, _Push, _Session) ->
%%    ok;
%%
%%send_event_sessions([{MemberId, Link}|Rest], Event, Push, #obj_session{srv_id=SrvId}=Session) ->
%%    case SrvId:object_session_event(Link, Event) of
%%        ok ->
%%            ok;
%%        {error, Error} ->
%%            ?LLOG(notice, "error sending message to session ~s: ~p", [MemberId, Error], Session),
%%            case Push of
%%                with_push ->
%%                    send_push(MemberId, Event, Session);
%%                without_push ->
%%                    ok
%%            end
%%    end,
%%    send_event_sessions(Rest, Event, Push, Session).
%%
%%
%%%% @private
%%send_event_members([], _Event, _Sessions, _Session) ->
%%    ok;
%%
%%send_event_members([MemberId|Rest], Event, Sessions, Session) ->
%%    case maps:is_key(MemberId, Sessions) of
%%        true ->
%%            ok;
%%        false ->
%%            send_push(MemberId, Event, Session)
%%    end,
%%    send_event_members(Rest, Event, Sessions, Session).
%%
%%
%%%% @private
%%send_push(MemberId, Event, #obj_session{srv_id=SrvId}) ->
%%    case SrvId:object_member_event(SrvId, MemberId, Event) of
%%        ok ->
%%            ok;
%%        {error, Error} ->
%%            ?LLOG(notice, "error sending push to ~s: ~p", [MemberId], Error)
%%    end.
