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

-export([create/3, add_member/3, remove_member/3, add_session/4, remove_session/3]).
-export([get_messages/3, get_member_conversations/3]).
-export([message_event/2, get_sess_info/1]).
-export([object_get_info/0, object_mapping/0, object_parse/3,
         object_api_syntax/3, object_api_allow/4, object_api_cmd/4, object_send_event/2,
         object_init/1, object_start/1,  object_restore/1, object_sync_op/3, object_async_op/2,
         object_event/2]).
-export([object_admin_tree/4]).
-export_type([event/0, subtype/0]).

-include("nkchat.hrl").
-include_lib("nkdomain/include/nkdomain.hrl").
-include_lib("nkdomain/include/nkdomain_debug.hrl").
-include_lib("nkservice/include/nkservice.hrl").


%% ===================================================================
%% Types
%% ===================================================================



-type event() ::
    {message_created, nkdomain:obj()} |
    {message_updated, nkdomain:obj()} |
    {message_deleted, nkdomain:obj_id()} |
    {member_added, nkdomain:obj_id()} |
    {added_to_conversation, nkdomain:obj_id()} |        % Same but obj_id is for the member
    {member_removed, nkdomain:obj_id()} |
    {removed_from_conversation, nkdomain:obj_id()} |    % Same but obj_id is for the member
    {session_added, Member::nkdomain:obj_id(), SessId::nkdomain:obj_id()} |
    {session_removed, Member::nkdomain:obj_id(), SessId::nkdomain:obj_id()}.


-type subtype() :: channel | private | one2one.


%% ===================================================================
%% Public
%% ===================================================================

%% @doc
-spec create(nkservice:id(), nkdomain:name(), nkdomain:obj()) ->
    {ok, nkdomain_obj_lib:make_and_create_reply(), pid()} | {error, term()}.

create(Srv, Name, Obj) ->
    Obj2 = Obj#{?CHAT_CONVERSATION => #{members => []}},
    nkdomain_obj_lib:make_and_create(Srv, Name, Obj2, #{}).


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
remove_session(ConvId, MemberId, SessId) ->
    nkdomain_obj:sync_op(ConvId, {?MODULE, remove_session, MemberId, SessId}).


%% @doc
get_member_conversations(Srv, Domain, MemberId) ->
    case nkdomain_obj_lib:find(Srv, Domain) of
        #obj_id_ext{srv_id=SrvId, path=DomainPath} ->
            Filters = #{
                type => ?CHAT_CONVERSATION,
                path => <<"childs_of:", DomainPath/binary>>,
                << ?CHAT_CONVERSATION/binary, ".members.member_id">> => MemberId
            },
            Search2 = #{
                sort => [#{"name.keyword" => #{order => asc}}],
                fields => [created_time, description, name, path, subtype, <<?CHAT_CONVERSATION/binary, ".members.member_id">>],
                filters => Filters,
                size => 9999
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


%% @private
get_sess_info(ConvId) ->
     nkdomain_obj:sync_op(ConvId, {?MODULE, get_session_info}).



%% =================================================================
%% nkdomain_obj behaviour
%% ===================================================================

-record(?MODULE, {
    members2 = #{} :: [{MemberId::nkdomain:obj_id(), map()}],
%%    sessions = #{} :: #{SessId::nkdomain:obj_id() => {UserId::nkdomain:obj_id(), Meta::map()}},
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
                sessions => #{
                    type => object,
                    dynamic => false,
                    properties => #{
                        session_id => #{type => keyword},
                        session_meta => #{
                            type => object,
                            enabled => false
                        }
                    }
                }
            }
        }
    }.


%% @private
object_parse(_SrvId, update, _Obj) ->
    #{};

object_parse(_SrvId, load, _Obj) ->
    #{
        members =>
            {list,
                #{
                    member_id => binary,
                    added_time => integer,
                    sessions =>
                        {list,
                            #{
                                session_id => binary,
                                session_meta => map,
                                '__mandatory' => [session_id]
                            }
                        },
                    '__mandatory' => [member_id]
                }
            }
    }.



%% @private
object_send_event(Event, Session) ->
    nkchat_conversation_obj_events:event(Event, Session).


%% @private Send events to my sessions
object_event(Event, #obj_session{srv_id=SrvId, obj_id=ConvId}=Session) ->
    case session_event_filter(Event) of
        true ->
            lists:foreach(
                fun({MemberId, Member}) ->
                    case maps:get(sessions, Member, []) of
                        [] ->
                            ?LLOG(notice, "event with no sessions for ~s: ~p", [MemberId, Event], Session);
                        Sessions ->
                            lists:foreach(
                                fun(#{session_id:=SessId}=SessData) ->
                                    Meta = maps:get(session_meta, SessData, #{}),
                                    nkchat_session_obj:conversation_event(SrvId, SessId, MemberId, ConvId, Event, Meta)
                                end,
                                Sessions)
                    end
                end,
                maps:to_list(get_members(Session))
            ),
            {ok, Session};
        false ->
            {ok, Session}
    end.


%% @private
session_event_filter(Event) ->
    case Event of
        {message_created, _} -> true;
        {message_updated, _} -> true;
        {message_deleted, _} -> true;
        {member_added, _} -> true;
        {member_removed, _} -> true;
        _ -> lager:debug("EV Other: ~p", [Event]), false
    end.


%% @private
object_api_syntax(Sub, Cmd, Syntax) ->
    nkchat_conversation_obj_syntax:api(Sub, Cmd, Syntax).


%% @private
object_api_allow(_Sub, _Cmd, _Data, State) ->
    {true, State}.


%% @private
object_api_cmd(Sub, Cmd, Req, State) ->
    nkchat_conversation_obj_api:cmd(Sub, Cmd, Req, State).


%% @private
%% We initialize soon in case of early terminate
object_init(Session) ->
    {ok, Session#obj_session{data=#?MODULE{}}}.


%% @private When the object is loaded, we make our cache
object_start(#obj_session{obj=Obj}=Session) ->
    #{?CHAT_CONVERSATION := #{members := MemberList}} = Obj,
    % It should not take a lot of memory, it is a copy
    Members = maps:from_list([{Id, M} || #{member_id:=Id} = M <- MemberList]),
    Data = #?MODULE{members2 = Members},
    {ok, Session#obj_session{data=Data}}.


%% @private Prepare the object for saving
object_restore(#obj_session{obj=Obj}=Session) ->
    Members = get_members(Session),
    Obj2 = ?ADD_TO_OBJ(?CHAT_CONVERSATION, #{members=>maps:values(Members)}, Obj),
    {ok, Session#obj_session{obj = Obj2}}.


%% @private
object_sync_op({?MODULE, add_member, Id}, _From, Session) ->
    case add_member(Id, Session) of
        {ok, MemberId, Session2} ->
            Session3 = do_event({member_added, MemberId}, Session2),
            Session4 = do_event({added_to_conversation, MemberId}, Session3),
            {reply_and_save, {ok, MemberId}, Session4};
        {error, Error} ->
            {reply, {error, Error}, Session}
    end;

object_sync_op({?MODULE, remove_member, Id}, _From, Session) ->
    Members1 = get_members(Session),
    case rm_member(Id, Session) of
        {ok, MemberId, Session2} ->
            Members2 = get_members(Session2),
            Session3 = do_event({member_removed, MemberId}, set_members(Members1, Session2)),
            Session4 = do_event({removed_from_conversation, MemberId}, Session3),
            {reply_and_save, ok, set_members(Members2, Session4)};
        {error, Error} ->
            {reply, {error, Error}, Session}
    end;

object_sync_op({?MODULE, add_session, MemberId, SessId, Meta}, _From, Session) ->
    case do_add_session(MemberId, SessId, Meta, Session) of
        {ok, Session2} ->
            Session3 = do_event({session_added, MemberId, SessId}, Session2),
            {reply_and_save, ok, Session3};
        {error, Error} ->
            {reply, {error, Error}, Session}
    end;

object_sync_op({?MODULE, remove_session, UserId, SessId}, _From, Session) ->
    case do_rm_session(UserId, SessId, Session) of
        {ok, MemberId, Session2} ->
            Session3 = do_event({session_removed, MemberId, SessId}, Session2),
            {reply_and_save, ok, Session3};
        {error, Error} ->
            {reply, {error, Error}, Session}
    end;

object_sync_op({?MODULE, get_session_info}, _From, #obj_session{obj_id=ObjId}=Session) ->
    #obj_session{is_enabled=Enabled, path=Path, obj=Obj} = Session,
    Name = maps:get(name, Obj, <<>>),
    MemberIds = maps:keys(get_members(Session)),
    Reply = #{
        obj_id => ObjId,
        name => Name,
        path => Path,
        created_by => maps:get(created_by, Obj, <<>>),
        subtype => maps:get(subtype, Obj, <<>>),
        description => maps:get(description, Obj, <<>>),
        is_enabled => Enabled,
        member_ids => MemberIds
    },
    {reply, {ok, Reply}, Session};

object_sync_op(_Op, _From, _Session) ->
    continue.


%% @private
object_async_op(_Op, _Session) ->
    continue.


%% @doc
object_admin_tree(resources, _Num, Data, Acc) ->
    nkadmin_menu:add_tree_entry(menu_resources_chat_conversations, menuSimple, Data, Acc);

object_admin_tree(_Category, _Num, _Data, Acc) ->
    Acc.



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
    case maps:find(Id, Members) of
        {ok, Member} ->
            {true, Id, Member, Members};
        error ->
            case nkdomain_obj_lib:find(SrvId, Id) of
                #obj_id_ext{obj_id=ObjId} ->
                    case maps:find(ObjId, Members) of
                        {ok, Member} ->
                            {true, ObjId, Member, Members};
                        error ->
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
                sessions => []
            },
            Members2 = Members#{MemberId => Member},
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
        {true, MemberId, _Member, Members} ->
            Members2 = maps:remove(MemberId, Members),
            {ok, MemberId, set_members(Members2, Session)};
        {false, _, _} ->
            {error, member_not_found};
        {error, Error} ->
            {error, Error}
    end.


%% @private
do_add_session(Id, SessionId, Meta, Session) ->
    case find_member(Id, Session) of
        {true, MemberId, Member, Members} ->
            Sessions1 = maps:get(sessions, Member, []),
            SessionIds = [maps:get(session_id, S) || S <- Sessions1],
            case lists:member(SessionId, SessionIds) of
                false ->
                    SessionObj = #{session_id=>SessionId, session_meta=>Meta},
                    Sessions2 = [SessionObj|Sessions1],
                    Member2 = Member#{sessions=>Sessions2},
                    Members2 = Members#{MemberId => Member2},
                    {ok, set_members(Members2, Session)};
                true ->
                    % It will not set is_dirty
                    {ok, Session}
            end;
        {false, _, _} ->
            {error, member_not_found};
        {error, Error} ->
            {error, Error}
    end.


%% @private
do_rm_session(Id, SessionId, Session) ->
    case find_member(Id, Session) of
        {true, MemberId, Member, Members} ->
            Sessions1 = maps:get(sessions, Member, []),
            Sessions2 = [{maps:get(session_id, S), S} || S <- Sessions1],
            case lists:keytake(SessionId, 1, Sessions2) of
                {value, _, Sessions3} ->
                    Sessions4 = [S || {_, S} <-Sessions3],
                    Member2 = Member#{sessions=>Sessions4},
                    Members2 = Members#{MemberId => Member2},
                    {ok, MemberId, set_members(Members2, Session)};
                false ->
                    {error, session_not_found}
            end;
        {false, _, _} ->
            {error, session_not_found}
    end.


%% @private
get_members(#obj_session{data=#?MODULE{members2=Members}}) ->
    Members.

%% @private
set_members(Members, #obj_session{data=Data}=Session) ->
    Data2 = Data#?MODULE{members2=Members},
    Session#obj_session{data=Data2, is_dirty=true}.


%% @private
add_user(SrvId, UserId, Data) ->
    case nkdomain_user_obj:get_name(SrvId, UserId) of
        {ok, User} -> Data#{user=>User#{obj_id=>UserId}};
        {error, _} -> Data#{user=>#{}}
    end.

%% @private
do_event(Event, Session) ->
    nkdomain_obj_util:event(Event, Session).


