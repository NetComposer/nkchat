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

-export([create/2]).
-export([add_info/2, add_member/3, remove_member/3]).
-export([add_session/4, set_session_active/4, remove_session/3, get_member_info/2]).
-export([get_status/1, set_status/2, set_closed/2]).
-export([get_info/1, get_messages/2, find_member_conversations/2,
         find_conversations_with_members/2, get_last_messages/1]).
-export([add_invite_op/4, perform_op/1]).
-export([message_event/2]).
-export([object_info/0, object_es_mapping/0, object_parse/2, object_create/1,
         object_api_syntax/2, object_api_cmd/2, object_send_event/2,
         object_init/1, object_save/1, object_sync_op/3, object_async_op/2,
         object_event/2, object_link_down/2]).
-export([object_admin_info/0]).
-export_type([event/0]).

-include("nkchat.hrl").
-include_lib("nkdomain/include/nkdomain.hrl").
-include_lib("nkdomain/include/nkdomain_debug.hrl").
-include_lib("nkservice/include/nkservice.hrl").

-define(MSG_CACHE_SIZE, 25).
-define(INVITE_TTL, 3*24*60*60).



%% ===================================================================
%% Types
%% ===================================================================


-type create_opts() ::
    #{
        parent_id => nkdomain:id(),
        created_by => nkdomain:id(),
        obj_name => nkdomain:obj_name(),
        type => binary(),
        obj_name_follows_members => boolean(),
        push_srv_id => atom() | binary(),
        status => status(),
        initial_member_ids => [binary()]
    }.

-type member_role() :: binary().

-type info() :: map().

-type event() ::
    {added_info, info()} |
    {message_created, nkdomain:obj()} |
    {message_updated, nkdomain:obj()} |
    {message_deleted, nkdomain:obj_id()} |
    {member_added, nkdomain:obj_id()} |
    {added_to_conversation, nkdomain:obj_id()} |        % Same but obj_id is for the member
    {member_removed, nkdomain:obj_id()} |
    {removed_from_conversation, nkdomain:obj_id()} |    % Same but obj_id is for the member
    {session_added, Member::nkdomain:obj_id(), SessId::nkdomain:obj_id()} |
    {session_removed, Member::nkdomain:obj_id(), SessId::nkdomain:obj_id()} |
    {status_updated, status()} |
    {is_closed_updated, boolean()}.


-type status() :: binary().


%% ===================================================================
%% Public
%% ===================================================================


%% @doc

-spec create(nkdomain:id(), create_opts()) ->
    {ok, ConfId::nkdomain:id(), pid()} | {error, term()}.

create(Domain, Opts) ->
    Core = maps:with([created_by, obj_name, name, parent_id], Opts),
    Conv = maps:with([type, status, obj_name_follows_members, push_srv_id, initial_member_ids], Opts),
    Obj = Core#{
        type => ?CHAT_CONVERSATION,
        domain_id => Domain,
        ?CHAT_CONVERSATION => Conv
    },
    case nkdomain_obj_make:create(Obj) of
        {ok, #obj_id_ext{obj_id=ConvId, pid=Pid}, []} ->
            {ok, ConvId, Pid};
        {error, Error} ->
            {error, Error}
    end.


%% @doc
add_info(Id, Info) when is_map(Info) ->
    nkdomain_obj:sync_op(Id, {?MODULE, add_info, Info}).


%% @doc Members will be changed for roles
-spec add_member(nkdomain:id(), nkdomain:id(), boolean()) ->
    {ok, nkdomain:obj_id()} | {error, term()}.

add_member(Id, Member, Silent) ->
    case nkdomain_lib:find(Member) of
        #obj_id_ext{type= ?DOMAIN_USER, obj_id=MemberId} ->
            case nkdomain_obj:sync_op(Id, {?MODULE, add_member, MemberId}) of
                {ok, ObjId} ->
                    case Silent of
                        false ->
                            Msg = #{
                                type => ?CHAT_MSG_TYPE_ADDED_MEMBER,
                                text => <<"member added">>,
                                created_by => <<"admin">>,
                                body => #{
                                    member_id => MemberId
                                }
                            },
                            case nkchat_message_obj:create(Id, Msg) of
                                {ok, _MsgId, _Pid} ->
                                    ok;
                                {error, Error2} ->
                                    lager:warning("could not add member_added msg to conversation ~s: ~p", [Id, Error2])
                            end;
                        true ->
                            ok
                    end,
                    {ok, ObjId};
                {error, Error} ->
                    {error, Error}
            end;
        {ok, _, _, _} ->
            {error, member_invalid};
        {error, object_not_found} ->
            {error, member_not_found};
        {error, Error} ->
            {error, Error}
    end.


%% @doc
-spec remove_member(nkdomain:id(), nkdomain:id(), boolean()) ->
    ok | {error, term()}.

remove_member(Id, Member, Silent) ->
    MemberId = case nkdomain_lib:find(Member) of
        #obj_id_ext{obj_id=ObjId} ->
            ObjId;
        _ ->
            Member
    end,
    case nkdomain_obj:sync_op(Id, {?MODULE, remove_member, MemberId}) of
        ok ->
            case Silent of
                false ->
                    Msg = #{
                        type => ?CHAT_MSG_TYPE_REMOVED_MEMBER,
                        text => <<"member removed">>,
                        created_by => <<"admin">>,
                        body => #{
                            member_id => MemberId
                        }
                    },
                    case nkchat_message_obj:create(Id, Msg) of
                        {ok, _MsgId, _Pid} ->
                            ok;
                        {error, Error2} ->
                            lager:warning("could not add member_removed msg to conversation ~s: ~p", [Id, Error2])
                    end;
                true ->
                    ok
                end;
        {error, Error} ->
            {error, Error}
    end.


%% @doc
-spec get_status(nkdomain:id()) ->
    {ConvId::nkdomain:obj_id(), DomainId::nkdomain:obj_id(), Status::status(), IsClosed::boolean()}.

get_status(Id) ->
    nkdomain_obj:sync_op(Id, {?MODULE, get_status}).


%% @doc
-spec set_status(nkdomain:id(), status()) ->
    ok | {error, term()}.

set_status(Id, Status) ->
    nkdomain_obj:sync_op(Id, {?MODULE, set_status, nklib_util:to_binary(Status)}).


%% @doc
-spec set_closed(nkdomain:id(), boolean()) ->
    ok | {error, term()}.

set_closed(Id, Closed) when is_boolean(Closed) ->
    nkdomain_obj:sync_op(Id, {?MODULE, set_closed, Closed}).


%% @private Called from nkchat_session_obj
%% Sessions receive notifications for every message, calling
-spec add_session(nkdomain:obj_id(), nkdomain:obj_id(), nkdomain:obj_id(), map()) ->
    {ok, pid()} | {error, term()}.

add_session(ConvId, MemberId, SessId, Meta) ->
    nkdomain_obj:sync_op(ConvId, {?MODULE, add_session, MemberId, SessId, Meta, self()}).


%% @private
set_session_active(ConvId, MemberId, SessId, Bool) when is_boolean(Bool)->
    nkdomain_obj:async_op(ConvId, {?MODULE, set_active, MemberId, SessId, Bool}).


%% @private Called from nkchat_session_obj
%% Sessions receive notifications for every message, calling
remove_session(ConvId, MemberId, SessId) ->
    nkdomain_obj:sync_op(ConvId, {?MODULE, remove_session, MemberId, SessId}).


%% @private
-spec get_member_info(nkdomain:obj_id(), nkdomain:obj_id()) ->
    {ok, map()} | {error, term()}.

get_member_info(ConvId, MemberId) ->
    nkdomain_obj:sync_op(ConvId, {?MODULE, get_member_info, MemberId}).


%% @private
get_info(Pid) ->
    nkdomain_obj:sync_op(Pid, {?MODULE, get_info}).


%% @doc
find_member_conversations(Domain, MemberId) ->
    case nkdomain_lib:find(Domain) of
        #obj_id_ext{type=?DOMAIN_DOMAIN, obj_id=DomainId} ->
            Filters = #{
                type => ?CHAT_CONVERSATION,
                domain_id => DomainId,
                << ?CHAT_CONVERSATION/binary, ".members.member_id">> => MemberId
            },
            Search2 = #{
                fields => [<<?CHAT_CONVERSATION/binary, ".type">>],
                filters => Filters,
                size => 9999
            },
            case nkdomain:search(Search2) of
                {ok, _N, List, _Meta} ->
                    List2 = lists:map(
                        fun(#{<<"obj_id">>:=ConvId, ?CHAT_CONVERSATION:=#{<<"type">>:=Type}}) -> {ConvId, Type} end,
                        List),
                    {ok, List2};
                {error, Error} ->
                    {error, Error}
            end;
        _ ->
            {error, domain_unknown}
    end.


%% @doc
find_conversations_with_members(Domain, MemberIds) ->
    case nkdomain_lib:find(Domain) of
        #obj_id_ext{type=?DOMAIN_DOMAIN, obj_id=DomainId} ->
            Hash = make_members_hash(MemberIds),
            Filters = #{
                type => ?CHAT_CONVERSATION,
                domain_id => DomainId,
                << ?CHAT_CONVERSATION/binary, ".members_hash">> => Hash
            },
            Search2 = #{
                fields => [<<?CHAT_CONVERSATION/binary, ".type">>],
                filters => Filters,
                size => 9999
            },
            case nkdomain:search(Search2) of
                {ok, N, List, _Meta} ->
                    List2 = lists:map(
                        fun(#{<<"obj_id">>:=ConvId, ?CHAT_CONVERSATION:=#{<<"type">>:=Type}}) -> {ConvId, Type} end,
                        List),
                    {ok, N, List2};
                {error, Error} ->
                    {error, Error}
            end;
        _ ->
            {error, domain_unknown}
    end.


%% @doc
get_messages(Id, Spec) ->
    case nkdomain_lib:load(Id) of
        #obj_id_ext{obj_id=ConvId} ->
            Search1 = case Spec of
                #{start_date:=_, end_date:=_} ->
                    #{};
                #{start_date:=_} ->
                    maps:with([size], Spec);
                #{end_date:=_} ->
                    maps:with([size], Spec);
                _ ->
                    maps:with([from, size], Spec)
            end,
            Filters1 = #{
                type => ?CHAT_MESSAGE,
                parent_id => ConvId
            },
            CreatedFilterList = case Spec of
                #{start_date:=Date1, end_date:=Date2, inclusive:=Inc} when Inc == true ->
                    Order = desc,
                    ["<", nklib_util:to_binary(Date1), "-", nklib_util:to_binary(Date2), ">"];
                #{start_date:=Date1, end_date:=Date2} ->
                    Order = desc,
                    ["<<", nklib_util:to_binary(Date1), "-", nklib_util:to_binary(Date2), ">>"];
                #{start_date:=Date, inclusive:=Inc} when Inc == true ->
                    Order = asc,
                    [">=", nklib_util:to_binary(Date)];
                #{start_date:=Date} ->
                    Order = asc,
                    [">", nklib_util:to_binary(Date)];
                #{end_date:=Date, inclusive:=Inc} when Inc == true ->
                    Order = desc,
                    ["<=", nklib_util:to_binary(Date)];
                #{end_date:=Date} ->
                    Order = desc,
                    ["<", nklib_util:to_binary(Date)];
                _ ->
                    Order = desc,
                    []
            end,
            Filters2 = case CreatedFilterList of
                [] ->
                    Filters1;
                _ ->
                    Filters1#{created_time => list_to_binary(CreatedFilterList)}
            end,
            Search2 = Search1#{
                sort => [#{created_time => #{order => Order}}],
                fields => [created_time, ?CHAT_MESSAGE, created_by],
                filters => Filters2
            },
            case nkdomain:search(Search2) of
                {ok, N, List, _Meta} ->
                    List2 = case Order of
                        asc ->
                            lists:reverse(List);
                        desc ->
                            List
                    end,
                    {ok, #{total=>N, data=>List2}};
                {error, Error} ->
                    {error, Error}
            end;
        {error, object_not_found} ->
            {error, conversation_not_found};
        {error, Error} ->
            {error, Error}
    end.


%% @doc
get_last_messages(Id) ->
    nkdomain_obj:sync_op(Id, {?MODULE, get_last_messages}).


%% @private Called from nkchat_message_obj
%% The message object generates an event that inserts into the conversation object
%% and it sends it as if it were an own message
%% Is is captured at object_event/2 and sent to the sessions in send_to_sessions/3
message_event(ConvId, Event) ->
    Event2 = case Event of
        {created, Msg} ->
            {message_created, Msg};
        {deleted, MsgId} ->
            {message_deleted, MsgId};
        {updated, Msg} ->
            {message_updated, Msg};
        _ ->
            ignore
    end,
    case Event2 of
        ignore ->
            ok;
        _ ->
            nkdomain_obj:async_op(ConvId, {send_event, Event2})
    end.


%% @doc Adds info on a token to invite an user
-spec add_invite_op(nkdomain:id(), nkdomain:id(), nkdomain:id(), map()) ->
    {ok, ConvId::nkdomain:obj_id(), MemberId::nkdomain:obj_id(), UserId::nkdomain:obj_id(), map()} | {error, term()}.

add_invite_op(Conv, UserId, Member, Base) ->
    nkdomain_obj:sync_op(Conv, {?MODULE, add_invite_op, UserId, Member, Base}).


%% @doc
perform_op(#{?CHAT_CONVERSATION:=#{<<"add_member_op">>:=Op}}) ->
    #{
        <<"conversation_id">> := ConvId,
        <<"member_id">> := MemberId,
        <<"user_id">> := _UserId
    } = Op,
    case add_member(ConvId, MemberId, false) of
        {ok, _MemberId} ->
            ok;
        {error, Error} ->
            {error, Error}
    end;

perform_op(_Data) ->
    {error, operation_token_invalid}.


%% =================================================================
%% nkdomain_obj behaviour
%% ===================================================================

-record(chat_session, {
    session_id :: nkdomain:obj_id(),
    meta :: map(),
    pid ::pid(),
    is_active :: boolean()
}).

-record(member, {
    member_id :: nkdomain:obj_id(),
    added_time :: nkdomain:timestamp(),
    roles :: [member_role()],
    last_active_time = 0:: nkdomain:timestamp(),
    last_seen_msg_time = 0 :: nkdomain:timestamp(),
    unread_count = -1 :: integer(),
    sessions = [] :: [#chat_session{}]
}).

-record(session, {
    name :: binary(),
    type :: binary(),
    members :: [#member{}],
    status :: status(),
    is_closed :: boolean(),
    total_messages :: integer(),
    messages :: [{Time::integer(), MsgId::nkdomain:obj_id(), Msg::map()}],
    obj_name_follows_members :: boolean(),
    push_srv_id :: binary()
}).


%% @private
object_info() ->
    #{
        type => ?CHAT_CONVERSATION,
        default_ttl => 5*60*1000,
        dont_create_childs_on_disabled => true,
        dont_update_on_disabled => true
    }.

%% @doc
object_admin_info() ->
    #{
        class => resource,
        weight => 2000,
        type_view_mod => nkchat_conversation_obj_type_view
    }.


%% @private
object_es_mapping() ->
    #{
        type => #{type => keyword},
        status => #{type => keyword},
        is_closed => #{type => boolean},
        members => #{
            type => object,
            dynamic => false,
            properties => #{
                member_id => #{type => keyword},
                added_time => #{type => date},
                member_roles => #{type => keyword},
                last_active_time => #{type => date},
                last_seen_message_time => #{type => date}
            }
        },
        info => #{enabled => false},
        members_hash => #{type => keyword},
        obj_name_follows_members => #{type => boolean},
        push_srv_id => #{type => keyword}
    }.


%% @private
object_parse(update, _Obj) ->
    #{};

object_parse(_Mode, _Obj) ->
    #{
        type => binary,
        status => binary,
        is_closed => boolean,                          % No new members or messages
        members =>
            {list,
                 #{
                     member_id => binary,
                     added_time => integer,
                     member_roles => {list, binary},
                     last_active_time => integer,
                     last_seen_message_time => integer,
                     '__mandatory' => [member_id, added_time, last_active_time, last_seen_message_time]
                 }
            },
        info => {list, map},
        members_hash => binary,
        obj_name_follows_members => boolean,
        push_srv_id => binary,
        initial_member_ids => {list, binary},
        '__defaults' => #{type => <<"private">>, info => [], members => []}
    }.


%% @doc
object_create(#{?CHAT_CONVERSATION:=Conv} = Obj) ->
    Members = maps:get(initial_member_ids, Conv, []),
    case check_members(Members, []) of
        {ok, MemberIds} ->
            Conv2 = Conv#{
                members => [],
                initial_member_ids => MemberIds
            },
            Obj2 = ?ADD_TO_OBJ(?CHAT_CONVERSATION, Conv2, Obj),
            Obj3 = case Conv2 of
                #{obj_name_follows_members:=true} ->
                    ObjName = make_obj_name(make_members_hash(MemberIds)),
                    ?ADD_TO_OBJ(obj_name, ObjName, Obj2);
                _ ->
                    Obj2
            end,
            nkdomain_obj_make:create(Obj3);
        {error, Error} ->
            {error, Error}
    end.


%% @private
object_send_event(Event, State) ->
    nkchat_conversation_obj_events:event(Event, State).


%% @private
object_api_syntax(Cmd, Syntax) ->
    nkchat_conversation_obj_syntax:syntax(Cmd, Syntax).


%% @private
object_api_cmd(Cmd, Req) ->
    nkchat_conversation_obj_cmd:cmd(Cmd, Req).


% @private When the object is loaded, we make our cache
object_init(#obj_state{id=Id, obj=Obj}=State) ->
    #obj_id_ext{obj_id=ConvId} = Id,
    #{obj_name:=ObjName, ?CHAT_CONVERSATION := #{members:=MemberList, type:=Type}=Conv} = Obj,
    Members = lists:map(
        fun(Data) ->
            #{
                member_id := MemberId,
                added_time := AddedTime,
                last_active_time := LastActiveTime,
                last_seen_message_time := LastSeenTime
            } = Data,
            #member{
                member_id = MemberId,
                added_time = AddedTime,
                roles = maps:get(member_roles, Data, []),
                last_active_time= LastActiveTime,
                last_seen_msg_time = LastSeenTime
            }
        end,
        MemberList),
    case read_messages(ConvId, State) of
        {ok, Total, Msgs} ->
            Msgs2 = lists:map(
                fun(#{<<"obj_id">>:=MsgId, <<"created_time">>:=Time}=Msg) -> {Time, MsgId, Msg} end,
                Msgs),
            Session = #session{
                name = maps:get(name, Obj, ObjName),
                type = Type,
                status = maps:get(status, Conv, <<>>),
                is_closed = maps:get(is_closed, Conv, false),
                members = Members,
                total_messages = Total,
                messages = Msgs2,
                push_srv_id = maps:get(push_srv_id, Conv, <<>>),
                obj_name_follows_members = maps:get(obj_name_follows_members, Conv, false)
            },
            State2 = State#obj_state{session=Session},
            case maps:take(initial_member_ids, Conv) of
                error ->
                    {ok, State2};
                {MemberIds, Conv2} when Members == [] ->
                    Obj2 = ?ADD_TO_OBJ(?CHAT_CONVERSATION, Conv2, Obj),
                    State3 = State2#obj_state{obj=Obj2, is_dirty=true},
                    % Store generated users
                    nkdomain_obj:async_op(self(), save),
                    load_initial_members(MemberIds, State3)
            end;
        {error, Error} ->
            {error, Error}
    end.


%% @private Prepare the object for saving
object_save(#obj_state{obj=Obj, session=Session}=State) ->
    #session{
        members = Members,
        is_closed = IsClosed,
        status = Status
    } = Session,
    MemberList= lists:map(
        fun(Member) ->
            #member{
                member_id = MemberId,
                added_time = Time,
                roles = Roles,
                last_active_time = ActiveTime,
                last_seen_msg_time = MsgTime
            } = Member,
            #{
                member_id => MemberId,
                added_time => Time,
                member_roles => Roles,
                last_active_time => ActiveTime,
                last_seen_message_time => MsgTime
            }
        end,
        Members),
    #{?CHAT_CONVERSATION:=Conv1} = Obj,
    Conv2 = Conv1#{
        members => MemberList,
        is_closed => IsClosed,
        status => Status
    },
    Obj2 = ?ADD_TO_OBJ(?CHAT_CONVERSATION, Conv2, Obj),
    {ok, State#obj_state{obj = Obj2}}.


%% @private
object_sync_op({?MODULE, get_info}, _From, State) ->
    #obj_state{obj=#{?CHAT_CONVERSATION:=ChatConv}=Obj, session=Session} = State,
    #session{status=Status, is_closed=IsClosed} = Session,
    #{type:=Type, members:=Members} = ChatConv,
    Data = #{
        name => maps:get(name, Obj, <<>>),
        description => maps:get(description, Obj, <<>>),
        type => Type,
        is_closed => IsClosed,
        status => Status,
        members => Members,
        info => maps:get(info, ChatConv, [])
    },
    {reply, {ok, Data}, State};

%% @private
object_sync_op({?MODULE, get_status}, _From, State) ->
    #obj_state{domain_id=DomainId, id=#obj_id_ext{obj_id=ConvId}, session=Session} = State,
    #session{is_closed=IsClosed, status=Status} = Session,
    {reply, {ConvId, DomainId, Status, IsClosed}, State};

object_sync_op({?MODULE, set_status, Status}, _From, #obj_state{session=Session}=State) ->
    case Session of
        #session{status=Status} ->
            {reply, ok, State};
        _ ->
            Session2 = Session#session{status=Status},
            State2 = State#obj_state{session=Session2},
            State3 = do_event({status_updated, Status}, State2),
            {reply_and_save, ok, State3}
    end;

object_sync_op({?MODULE, set_closed, Closed}, _From, #obj_state{session=Session}=State) ->
    case Session of
        #session{is_closed=Closed} ->
            {reply, ok, State};
        _ ->
            Session2 = Session#session{is_closed=Closed},
            State2 = State#obj_state{session=Session2},
            State3 = do_event({is_closed_updated, Closed}, State2),
            {reply_and_save, ok, State3}
    end;

object_sync_op({?MODULE, add_info, Info}, _From, State) ->
    #obj_state{obj=#{?CHAT_CONVERSATION:=ChatConv}=Obj} = State,
    Infos1 = maps:get(info, ChatConv, []),
    Infos2 = [Info|Infos1],
    ChatConv2 = ChatConv#{info=>Infos2},
    Obj2 = ?ADD_TO_OBJ(?CHAT_CONVERSATION, ChatConv2, Obj),
    State2 = State#obj_state{obj=Obj2},
    State3 = do_event({added_info, Info}, State2),
    {reply_and_save, ok, State3};

object_sync_op({?MODULE, is_closed}, _From, State) ->
    #obj_state{domain_id=DomainId, id=#obj_id_ext{obj_id=ConvId}, session=Session} = State,
    #session{is_closed=IsClosed} = Session,
    {reply, {IsClosed, ConvId, DomainId}, State};

object_sync_op({?MODULE, set_status, #{is_closed:=Closed}}, _From, #obj_state{session=Session}=State) ->
    case Session of
        #session{is_closed=Closed} ->
            {reply, ok, State};
        _ ->
            Session2 = Session#session{is_closed=true},
            State2 = State#obj_state{session=Session2},
            {reply_and_save, ok, State2}
    end;

object_sync_op({?MODULE, set_status, _Status}, _From, State) ->
    {reply, {error, unknown_status}, State};


object_sync_op({?MODULE, add_member, MemberId}, _From, State) ->
    case do_add_member(MemberId, State) of
        {ok, State2} ->
            {reply_and_save, {ok, MemberId}, State2};
        {error, Error} ->
            {reply, {error, Error}, State}
    end;

object_sync_op({?MODULE, remove_member, MemberId}, _From, State) ->
    case find_member(MemberId, State) of
        {true, _} ->
            State2 = do_event({member_removed, MemberId}, State),              % Using original state
            case do_remove_member(MemberId, State2) of
                {ok, State3} ->
                    State4 = do_event({removed_from_conversation, MemberId}, State3),
                    {reply_and_save, ok, State4};
                {error, Error} ->
                    % Can fail if obj_name_follows_members
                    {reply, {error, Error}, State2}
            end;
        false ->
            {reply, {error, member_not_found}, State}
    end;

object_sync_op({?MODULE, add_session, MemberId, SessId, Meta, Pid}, _From, State) ->
    case do_add_session(MemberId, SessId, Meta, Pid, State) of
        {ok, State2} ->
            State3 = do_event({session_added, MemberId, SessId}, State2),
            {reply, {ok, self()}, State3};
        {error, Error} ->
            {reply, {error, Error}, State}
    end;

object_sync_op({?MODULE, remove_session, UserId, SessId}, _From, State) ->
    case do_remove_session(UserId, SessId, State) of
        {ok, State2} ->
            {reply, ok, State2};
        {error, Error} ->
            {reply, {error, Error}, State}
    end;

object_sync_op({?MODULE, get_member_info, MemberId}, _From, State) ->
    case find_member(MemberId, State) of
        {true, Member} ->
            Info = do_get_member_info(Member, State),
            {reply, {ok, Info}, State};
        false ->
            {reply, {error, member_not_found}, State}
    end;

object_sync_op({?MODULE, get_last_messages}, _From, #obj_state{session=Session}=State) ->
    #session{total_messages=Total, messages=Messages} = Session,
    Messages2 = [M || {_Time, _Id, M} <- Messages],
    {reply, {ok, #{total=>Total, data=>Messages2}}, State};


object_sync_op({?MODULE, make_invite_token, UserId, Member, TTL}, From, State) ->
    #obj_state{id=#obj_id_ext{obj_id=ConvId}, domain_id=DomainId} = State,
    TTL2 = case TTL of
        0 -> ?INVITE_TTL;
        _ -> TTL
    end,
    case nkdomain_lib:find(Member) of
        #obj_id_ext{type=?DOMAIN_USER, obj_id=MemberId} ->
            Data = #{
                <<"op">> => <<"invite_member">>,
                <<"conversation_id">> => ConvId,
                <<"member_id">> => MemberId
            },
            % Since the parent is ours, it would block
            spawn_link(
                fun() ->
                    TokenOpts = #{
                        parent_id => ConvId,
                        created_by => UserId,
                        subtype => ?CHAT_CONVERSATION,
                        ttl => TTL2
                    },
                    Reply = case nkdomain_token_obj:create(DomainId, TokenOpts, Data) of
                        {ok, TokenId, _Pid, _Secs} ->
                            {ok, ConvId, TokenId, TTL2};
                        {error, Error} ->
                            {error, Error}
                    end,
                    gen_server:reply(From, Reply)
                end),
            {noreply, State};
        _ ->
            {reply, {error, member_invalid}, State}
    end;

object_sync_op({?MODULE, add_invite_op, User, Member, Base}, _From, State) ->
    %% TODO check permission
    #obj_state{id=#obj_id_ext{obj_id=ConvId}} = State,
    case nkdomain_lib:find(Member) of
        #obj_id_ext{obj_id=MemberId} ->
            case nkdomain_lib:find(User) of
                #obj_id_ext{obj_id=UserId} ->
                    ConvData1 = maps:get(?CHAT_CONVERSATION, Base, #{}),
                    ConvData2 = ConvData1#{
                        <<"add_member_op">> => #{
                            <<"conversation_id">> => ConvId,
                            <<"member_id">> => MemberId,
                            <<"user_id">> => UserId,
                            <<"date">> => nkdomain_util:timestamp()
                        }
                    },
                    Base2 = Base#{?CHAT_CONVERSATION => ConvData2},
                    {reply, {ok, ConvId, MemberId, UserId, Base2}, State};
                _ ->
                    {error, member_invalid}
            end;
        _ ->
            {error, user_invalid}
    end;

object_sync_op(_Op, _From, _State) ->
    continue.


%% @private
object_async_op({?MODULE, set_active, MemberId, SessId, Bool}, State) ->
    case find_member(MemberId, State) of
        {true, #member{sessions=ChatSessions}=Member} ->
            case lists:keytake(SessId, #chat_session.session_id, ChatSessions) of
                {value, #chat_session{}=ChatSession, ChatSessions2} ->
                    ChatSession2 = ChatSession#chat_session{is_active=Bool},
                    ChatSessions3 = [ChatSession2|ChatSessions2],
                    Member2 = Member#member{sessions=ChatSessions3},
                    Member3 = case Bool of
                        true ->
                            #obj_state{session=#session{messages=Msgs}} = State,
                            Time = case Msgs of
                                [{Time0, _, _}|_] -> Time0;
                                _ -> 0
                            end,
                            do_event_member_sessions(Member2, {counter_updated, 0}, State),
                            Member2#member{
                                last_active_time = nkdomain_util:timestamp(),
                                last_seen_msg_time = Time,
                                unread_count = 0
                            };
                        false ->
                            Member2
                    end,
                    {noreply, set_member(MemberId, Member3, State)};
                false ->
                    ?LLOG(warning, "set_active for unknown session", [], State),
                    {noreply, State}
            end;
        false ->
            ?LLOG(warning, "set_active for unknown member", [], State),
            {noreply, State}
    end;

object_async_op(_Op, _State) ->
    continue.


%% @private
object_link_down({usage, {?MODULE, session, MemberId, SessId, _Pid}}, State) ->
    case do_remove_session(MemberId, SessId, State) of
        {ok, State2} ->
            {ok, State2};
        {error, _} ->
            {ok, State}
    end;

object_link_down(_Link, State) ->
    {ok, State}.

%% @private Hook called before sending a event
object_event({message_created, Msg}, #obj_state{session=Session}=State) ->
    ?DEBUG("created message ~p", [Msg], State),
    #session{total_messages=Total, messages=Msgs} = Session,
    #{obj_id:=MsgId, created_time:=Time} = Msg,
    Msgs2 = [{Time, MsgId, Msg}|Msgs],
    Msgs3 = case length(Msgs2) >= ?MSG_CACHE_SIZE of
        true -> lists:sublist(Msgs2, ?MSG_CACHE_SIZE);
        false -> Msgs2
    end,
    Session2 = Session#session{
        total_messages = Total+1,
        messages = Msgs3
    },
    State2 = do_new_msg_event(Time, Msg, State#obj_state{session=Session2}),
    {ok, State2};

object_event({message_updated, Msg}, #obj_state{session=Session}=State) ->
    #session{messages=Msgs} = Session,
    #{obj_id:=MsgId, created_time:=Time} = Msg,
    Session2 = case lists:keymember(MsgId, 2, Msgs) of
        true ->
            Msgs2 = lists:keystore(MsgId, 2, Msgs, {Time, MsgId, Msg}),
            Session#session{messages=Msgs2};
        false ->
            Session
    end,
    State2 = do_event_all_sessions({message_updated, Msg}, State#obj_state{session=Session2}),
    {ok, State2};

object_event({message_deleted, MsgId}, #obj_state{session=Session}=State) ->
    #session{total_messages=Total, messages=Msgs} = Session,
    Session2 = case lists:keymember(MsgId, 2, Msgs) of
        true ->
            Msgs2 = lists:keydelete(MsgId, 2, Msgs),
            Session#session{messages=Msgs2};
        false ->
            Session
    end,
    Session3 = Session2#session{total_messages=Total-1},
    State2 = do_event_all_sessions({message_deleted, MsgId}, State#obj_state{session=Session3}),
    {ok, State2};

object_event({member_added, MemberId}, State) ->
    {ok, do_event_all_sessions({member_added, MemberId}, State)};

object_event({member_removed, MemberId}, State) ->
    {ok, do_event_all_sessions({member_removed, MemberId}, State)};

object_event({session_removed, MemberId, SessId}, State) ->
    {ok, do_event_all_sessions({session_removed, MemberId, SessId}, State)};

object_event({status_updated, Status}, State) ->
    {ok, do_event_all_sessions({status_updated, Status}, State)};

object_event({is_closed_updated, IsClosed}, State) ->
    {ok, do_event_all_sessions({is_closed_updated, IsClosed}, State)};

object_event({updated, _Update}, #obj_state{obj=#{?CHAT_CONVERSATION:=ChatConv}=Obj, session=Session} = State) ->
    #session{status=Status, is_closed=IsClosed} = Session,
    #{type:=Type, members:=Members} = ChatConv,
    Data = #{
        name => maps:get(name, Obj, <<>>),
        description => maps:get(description, Obj, <<>>),
        type => Type,
        is_closed => IsClosed,
        status => Status,
        members => Members,
        info => maps:get(info, ChatConv, [])
    },
    {ok, do_event_all_sessions({conversation_updated, Data}, State)};

object_event(_Event, State) ->
    {ok, State}.




%% ===================================================================
%% Internal
%% ===================================================================

%% @private
load_initial_members(MemberIds, #obj_state{session=#session{obj_name_follows_members=true}=Session}=State) ->
    State2 = State#obj_state{session=Session#session{obj_name_follows_members=false}},
    % We don't want to update obj_name, it is already calculated for the initial user list
    case do_add_members(MemberIds, State2) of
        {ok, #obj_state{session=Session3}=State3} ->
            % From now on we keep updating
            {ok, State3#obj_state{session=Session3#session{obj_name_follows_members=true}}};
        {error, Error} ->
            {error, Error}
    end;

load_initial_members(MemberIds, State) ->
    do_add_members(MemberIds, State).


%% @private
do_add_members([], State) ->
    {ok, State};

do_add_members([MemberId|Rest], State) ->
    case do_add_member(MemberId, State) of
        {ok, State2} ->
            do_add_members(Rest, State2);
        {error, Error} ->
            {error, Error}
    end.


%% @private
do_add_member(MemberId, State) ->
    case find_member(MemberId, State) of
        false ->
            Member = #member{
                member_id = MemberId,
                added_time = nkdomain_util:timestamp()
            },
            State2 = set_member(MemberId, Member, State),
            case set_obj_name_members(State2) of
                {ok, State3} ->
                    State4 = do_event({member_added, MemberId}, State3),
                    State5 = do_event({added_to_conversation, MemberId}, State4),
                    {ok, State5};
                {error, Error} ->
                    {error, Error}
            end;
        {true, _} ->
            {error, member_already_present}
    end.


%% @private
do_remove_member(MemberId, State) ->
    case find_member(MemberId, State) of
        {true, #member{sessions=Sessions}} ->
            State2 = rm_member(MemberId, State),
            case set_obj_name_members(State2) of
                {ok, State3} ->
                    State4 = do_remove_sessions(MemberId, Sessions, State3),
                    {ok, State4};
                {error, Error} ->
                    {error, Error}               % Old state
            end;
        false ->
            {error, member_not_found}
    end.


%% @private
do_add_session(MemberId, SessId, Meta, Pid, State) ->
    case find_member(MemberId, State) of
        {true, #member{sessions=Sessions}=Member} ->
            Session = #chat_session{session_id=SessId, meta=Meta, pid=Pid, is_active=false},
            Sessions2 = [Session|Sessions],
            Member2 = Member#member{sessions=Sessions2},
            Member3 = case Member2 of
                #member{last_seen_msg_time=Last, unread_count=-1} ->
                    Count = find_unread(Last, State),
                    do_event_member_sessions(Member2, {counter_updated, Count}, State),
                    Member2#member{unread_count=Count};
                #member{unread_count=Count} ->
                    do_event_member_sessions(Member2, {counter_updated, Count}, State),
                    Member2
            end,
            State3 = set_member(MemberId, Member3, State),
            State4 = nkdomain_obj:links_add(usage, {?MODULE, session, MemberId, SessId, Pid}, State3),
            {ok, State4};
        false ->
            {error, member_not_found}
    end.


%% @private
do_remove_session(MemberId, SessId, State) ->
    case find_member(MemberId, State) of
        {true, #member{sessions=Sessions1}=Member} ->
            case lists:keytake(SessId, #chat_session.session_id, Sessions1) of
                {value, #chat_session{pid=Pid}, Sessions2} ->
                    State2 = nkdomain_obj:links_remove(usage, {?MODULE, session, MemberId, SessId, Pid}, State),
                    State3 = do_event({session_removed, MemberId, SessId}, State2),
                    Member2 = Member#member{sessions=Sessions2},
                    {ok, set_member(MemberId, Member2, State3)};
                false ->
                    {error, session_not_found}
            end;
        false ->
            {error, session_not_found}
    end.


%% @private
do_remove_sessions(_MemberId, [], #obj_state{} = State) ->
    State;

do_remove_sessions(MemberId, [#chat_session{session_id=SessId}|Rest], State) ->
    case do_remove_session(MemberId, SessId, State) of
        {ok, State2} ->
            do_remove_sessions(MemberId, Rest, State2);
        {error, Error} ->
            lager:error("NKLOG do_remove_sessions ~p", [Error]),
            do_remove_sessions(MemberId, Rest, State)
    end.


%% @private
find_member(MemberId, State) ->
    Members = get_members(State),
    case lists:keyfind(MemberId, #member.member_id, Members) of
        #member{}=Member ->
            {true, Member};
        false ->
            false
    end.


%% @private
get_members(#obj_state{session=Session}) ->
    #session{members=Members} = Session,
    Members.


%% @private
set_members(Members, #obj_state{session=Session}=State) ->
    Session2 = Session#session{members=Members},
    State#obj_state{session=Session2, is_dirty=true}.


%% @private
set_member(MemberId, Member, State) ->
    Members1 = get_members(State),
    Members2 = lists:keystore(MemberId, #member.member_id, Members1, Member),
    set_members(Members2, State).


%% @private
rm_member(MemberId, State) ->
    Members1 = get_members(State),
    Members2 = lists:keydelete(MemberId, #member.member_id, Members1),
    set_members(Members2, State).



%% @private
do_event(Event, State) ->
    nkdomain_obj_util:event(Event, State).


%% @private
do_event_all_sessions(Event, State) ->
    Members = get_members(State),
    do_event_all_sessions(Members, Event, State).


%% @private
do_event_all_sessions([], _Event, State) ->
    State;

do_event_all_sessions([Member|Rest], Event, State) ->
    do_event_member_sessions(Member, Event, State),
    do_event_all_sessions(Rest, Event, State).


%% @private
do_event_member_sessions(#member{sessions=Sessions}, Event, State) ->
    do_event_sessions(Sessions, Event, State).


%% @private
do_event_sessions(Sessions, Event, #obj_state{id=Id}) when is_list(Sessions) ->
    #obj_id_ext{obj_id=ConvId} = Id,
    lists:foreach(
        fun(#chat_session{meta=Meta, pid=Pid}) ->
            nkchat_session_obj:conversation_event(Pid, ConvId, Meta, Event)
        end,
        Sessions).


%% @private
do_new_msg_event(Time, Msg, State) ->
    Members = get_members(State),
    do_new_msg_event(Members, Time, Msg, [], State).


%% @private
do_new_msg_event([], _Time, _Msg, Acc, State) ->
    set_members(Acc, State);

do_new_msg_event([Member|Rest], Time, Msg, Acc, State) ->
    #member{
        member_id = MemberId,
        unread_count = Count,
        sessions = Sessions
    } = Member,
    IsActive = lists:keymember(true, #chat_session.is_active, Sessions),
    Acc2 = case Sessions of
        [] ->
            Count2 = Count + 1,
            Member2 = Member#member{
                unread_count = Count2
            },
            #{?CHAT_MESSAGE:=#{text:=Txt}} = Msg,
            #obj_state{session=#session{name=Name}, id=#obj_id_ext{obj_id=ConvId}} = State,
            Push = #{
                type => ?CHAT_CONVERSATION,
                class => new_msg,
                conversation_name => Name,
                message_text => Txt,
                conversation_id => ConvId,
                unread_counter => Count2
            },
            send_push(MemberId, Push, State),
            [Member2|Acc];
        _ when IsActive ->
            Member2 = Member#member{
                last_seen_msg_time = Time,
                unread_count = 0
            },
            do_event_member_sessions(Member2, {message_created, Msg}, State),
            case Count of
                0 ->
                    ok;
                _ ->
                    do_event_member_sessions(Member2, {counter_updated, 0}, State)
            end,
            [Member2|Acc];
        _ ->
            Count2 = Count + 1,
            Member2 = Member#member{
                unread_count = Count2
            },
            do_event_member_sessions(Member2, {message_created, Msg}, State),
            do_event_member_sessions(Member2, {counter_updated, Count2}, State),
            [Member2|Acc]
    end,
    do_new_msg_event(Rest, Time, Msg, Acc2, State).



%% @private
read_messages(ConvId, _State) ->
    Search = #{
        filters => #{
            type => ?CHAT_MESSAGE,
            parent_id => ConvId
        },
        fields => [created_time, created_by, updated_time, ?CHAT_MESSAGE],
        sort => <<"desc:created_time">>,
        size => ?MSG_CACHE_SIZE
    },
    case nkdomain:search(Search) of
        {ok, 0, [], _Meta} ->
            {ok, 0, []};
        {ok, Total, Objs, _Meta} ->
            {ok, Total, Objs};
        {error, Error} ->
            {error, Error}
    end.


%% @private
find_unread(Time, #obj_state{id=Id}=State) ->
    #obj_id_ext{obj_id=ConvId} = Id,
    Search = #{
        filters => #{
            type => ?CHAT_MESSAGE,
            parent_id => ConvId,
            created_time => <<">", (integer_to_binary(Time))/binary>>
        },
        size => 0
    },
    case nkdomain:search(Search) of
        {ok, Num, [], _Meta} ->
            Num;
        {error, Error} ->
            ?LLOG(error, "error reading unread count: ~p", [Error], State),
            0
    end.


%% @private
set_obj_name_members(#obj_state{obj=#{?CHAT_CONVERSATION:=Conv}=Obj, session=Session}=State) ->
    #obj_state{session=#session{members=Members}} = State,
    MemberIds = [Id || #member{member_id=Id} <- Members],
    Hash = make_members_hash(MemberIds),
    Conv2 = Conv#{members_hash => Hash},
    Obj2 = ?ADD_TO_OBJ(?CHAT_CONVERSATION, Conv2, Obj),
    State2 = State#obj_state{obj=Obj2, is_dirty=true},
    case Session of
        #session{obj_name_follows_members=true} ->
            ObjName = make_obj_name(Hash),
            nkdomain_obj:do_update_name(ObjName, State2);
        _ ->
            {ok, State2}
    end.


%% @private
make_members_hash(MemberIds) ->
    MemberIds2 = lists:usort(MemberIds),
    nkdomain_util:name(base64:encode(crypto:hash(sha, erlang:term_to_binary(MemberIds2)))).


%% @private
make_obj_name(Hash) ->
    <<"mh-", Hash/binary>>.


%% @private
do_get_member_info(Member, State) ->
    #obj_state{obj=Obj, session=Session} = State,
    #session{total_messages=Total, messages=Msgs} = Session,
    LastMessage = case Msgs of
        [{_, _, Msg}|_] -> Msg;
        [] -> #{}
    end,
    #member{unread_count=Counter} = Member,
    #{
        path:=Path,
        parent_id:=ParentId,
        created_by:=CreatedBy,
        created_time:=CreatedTime,
        ?CHAT_CONVERSATION:=#{
            type:=Type,
            members:=Members,
            is_closed:=IsClosed,
            info:=Info,
            status:=Status
        }
    } = Obj,
    #{
        parent_id => ParentId,
        name => maps:get(name, Obj, <<>>),
        description => maps:get(description, Obj, <<>>),
        type => Type,
        created_by => CreatedBy,
        created_time => CreatedTime,
        info => Info,
        status => Status,
        is_closed => IsClosed,
        members => Members,
        path => Path,
        total_messages => Total,
        unread_counter => Counter,
        last_message => LastMessage
    }.


%% @private
send_push(MemberId, Push, #obj_state{session=#session{push_srv_id=SrvId}}) ->
    nkdomain_user_obj:send_push(MemberId, SrvId, Push).


%% @private
check_members([], Acc) ->
    {ok, Acc};

check_members([Member|Rest], Acc) ->
    case nkdomain_lib:find(Member) of
        #obj_id_ext{type=?DOMAIN_USER, obj_id=MemberId} ->
            check_members(Rest, [MemberId|Acc]);
        _ ->
            {error, member_not_found}
    end.
