
-module(
nkchat_sample).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-compile([export_all]).

-define(WS, "ws://127.0.0.1:9202/api/ws").
%%-define(WS, "wss://v1.netc.io/netcomp/chat/v00/nkapi/ws").
%%-define(HTTP, "http://127.0.0.1:10201/chat").

-include_lib("nkchat.hrl").
-include_lib("nkapi/include/nkapi.hrl").


p() ->
    Obj = #{
        type=>'conversation',
        obj_id=>a,
        parent_id=>a,
        path=>a,
        created_time=>1,
        <<"conversation">> => #{
            members => [
                #{
                    member_id => a,
                    added_time => "1",
                    sessions => [
                        #{
                            session_id => s1,
                            session_meta => #{a=>1}
                        },
                        #{
                            session_id => s2,
                            session_meta => #{a=>1}
                        }
                    ]
                },
                #{
                    member_id => b,
                    added_time => "2",
                    sessions => [
                        #{
                            session_id => s3,
                            session_meta => #{a=>1}
                        },
                        #{
                            session_id => s4,
                            session_meta => #{a=>1}
                        }
                    ]
                }


            ]
        }
    },
    root:object_parse(root, load, <<"conversation">>, Obj).



login() ->
    nkdomain_sample:login("/chattest/users/u1", "1234").



domain_find_convs() ->
    cmd(domain, find_all_childs, #{type=>?CHAT_CONVERSATION, sort=>[type, path]}).


init() ->
    {ok, _} = nkdomain_sample:user_create("/chattest", u1, s1, "n1@s1"),
    {ok, _} = nkdomain_sample:user_create("/chattest", u2, s2, "n2@s2"),
    {ok, _} = nkdomain_sample:user_create("/chattest", u3, s3, "n3@s3"),
    {ok, _} = conv_create("/chattest", c1, "C1"),
    {ok, _} = conv_create("/chattest", c2, "C2"),
    {ok, _} = cmd(?CHAT_CONVERSATION, wait_for_save, #{id=> "/chattest/conversations/c1"}),
    {ok, _} = cmd(?CHAT_CONVERSATION, wait_for_save, #{id=> "/chattest/conversations/c2"}),

    {ok, _} = conv_add_member("/chattest/conversations/c1", "/chattest/users/u1"),
    {ok, _} = conv_add_member("/chattest/conversations/c1", "/chattest/users/u2"),
    {ok, _} = conv_add_member("/chattest/conversations/c2", "/chattest/users/u1"),
    {ok, _} = conv_add_member("/chattest/conversations/c2", "/chattest/users/u3").



conv_user_subs(UserId) ->
    cmd(event, subscribe, #{class=>domain, subclass=>conversation, type=>added_to_conversation, obj_id=>UserId}).


conv_subs() ->
    {ok, _, UserId, _, _} = nkdomain:find("/chattest/users/u1"),
    cmd(event, subscribe, #{class=>domain, subclass=>conversation, obj_id=>UserId}).


conv_create(Domain, Name, Desc) ->
    cmd(?CHAT_CONVERSATION, create, #{name=>Name, subtype=>private, description=>Desc, domain=>Domain}).

conv_get() ->
    cmd(?CHAT_CONVERSATION, get, #{}).

conv_get(Id) ->
    cmd(?CHAT_CONVERSATION, get, #{id=>Id}).

conv_get_member_conversations() ->
    cmd(?CHAT_CONVERSATION, get_member_conversations, #{}).

conv_get_member_conversations(MemberId) ->
    cmd(?CHAT_CONVERSATION, get_member_conversations, #{member_id=>MemberId}).

conv_add_member(Id, Member) ->
    cmd(?CHAT_CONVERSATION, add_member, #{id=>Id, member_id=>Member}).

conv_remove_member(Id, Member) ->
    cmd(?CHAT_CONVERSATION, remove_member, #{id=>Id, member_id=>Member}).

conv_delete(Id) ->
    cmd(?CHAT_CONVERSATION, delete, #{id=>Id}).

conv_get_messages(Id) ->
    conv_get_messages(Id, #{}).

conv_get_messages(Id, Spec) ->
    cmd(?CHAT_CONVERSATION, get_messages, Spec#{id=>Id}).



message_create(ConvId, Msg) ->
    cmd(?CHAT_MESSAGE, create, #{conversation_id=>ConvId, ?CHAT_MESSAGE=>#{text=>Msg}}).

message_get(MsgId) ->
     cmd(?CHAT_MESSAGE, get, #{id=>MsgId}).

message_update(MsgId, Msg) ->
    cmd(?CHAT_MESSAGE, update, #{id=>MsgId, ?CHAT_MESSAGE=>#{text=>Msg}}).

message_delete(MsgId) ->
    cmd(?CHAT_MESSAGE, delete, #{id=>MsgId}).



session_find() ->
    cmd(?CHAT_SESSION, find, #{}).

session_find(UserId) ->
    cmd(?CHAT_SESSION, find, #{user_id=>UserId}).

session_create() ->
    cmd(?CHAT_SESSION, create, #{}).

session_create(UserId) ->
    cmd(?CHAT_SESSION, create, #{user_id=>UserId}).

session_start(SessId) ->
    cmd(?CHAT_SESSION, start, #{id=>SessId}).

session_get() ->
    cmd(?CHAT_SESSION, get, #{}).

session_get(SessId) ->
    cmd(?CHAT_SESSION, get, #{id=>SessId}).

session_stop() ->
    cmd(?CHAT_SESSION, stop, #{}).

session_delete(Id) ->
    cmd(?CHAT_SESSION, delete, #{id=>Id}).

session_set_active(ConvId) ->
    cmd(?CHAT_SESSION, set_active_conversation, #{conversation_id=>ConvId}).

session_add_conversation(ConvId) ->
    cmd(?CHAT_SESSION, add_conversation, #{conversation_id=>ConvId}).

session_remove_conversation(ConvId) ->
    cmd(?CHAT_SESSION, remove_conversation, #{conversation_id=>ConvId}).

session_get_all_conversations() ->
    cmd(?CHAT_SESSION, get_all_conversations, #{}).

session_get_conversation(ConvId) ->
    cmd(?CHAT_SESSION, get_conversation, #{conversation_id=>ConvId}).



%% ===================================================================
%% Client fun
%% ===================================================================



%% Test calling with class=test, cmd=op1, op2, data=#{nim=>1}
cmd(Class, Cmd, Data) ->
    Pid = nkdomain_sample:get_client(),
    cmd(Pid, Class, Cmd, Data).

cmd(Pid, Class, Cmd, Data) ->
    nkapi_client:cmd(Pid, Class, <<>>, Cmd, Data).



