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

%% @doc Session Object API
-module(nkchat_session_obj_cmd).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-export([cmd/2]).

-include("nkchat.hrl").
-include_lib("nkdomain/include/nkdomain.hrl").
-include_lib("nkevent/include/nkevent.hrl").
-include_lib("nkservice/include/nkservice.hrl").


-define(SESSION_DEF_EVENT_TYPES, [
    <<"unloaded">>,
    <<"conversation_added">>,
    <<"conversation_removed">>,
    <<"conversation_updated">>,
    <<"member_added">>,
    <<"member_removed">>,
    <<"message_created">>,
    <<"message_udpdated">>,
    <<"message_deleted">>,
    <<"unread_counter_updated">>
]).


%% ===================================================================
%% API
%% ===================================================================


%% @doc
cmd(<<"start">>, #nkreq{session_module=nkapi_server}=Req) ->
    #nkreq{data=Data, session_pid=Pid, user_id=UserId} = Req,
    case nkdomain_api_util:get_id(?DOMAIN_DOMAIN, domain_id, Data, Req) of
        {ok, DomainId} ->
            Opts = #{
                %nkapi_server_pid =>Pid,
                session_events => maps:get(session_events, Data, []),
                session_link => {nkapi_server, Pid}
            },
            case nkchat_session_obj:start(DomainId, UserId, Opts) of
                {ok, SessId, _Pid} ->
                    Req2 = nkdomain_api_util:add_id(?CHAT_SESSION, SessId, Req),
                    {ok, #{obj_id=>SessId}, Req2};
                {error, Error} ->
                    {error, Error}
            end;
        {error, Error} ->
            {error, Error}
    end;

cmd(<<"stop">>, #nkreq{data=Data, user_state=_UserState}=Req) ->
    case nkdomain_api_util:get_id(?CHAT_SESSION, Data, Req) of
        {ok, SessId} ->
            case nkdomain:unload(SessId, user_stop) of
                ok ->
                    {ok, #{}};
                {error, Error} ->
                    {error, Error}
            end;
        {error, Error} ->
            {error, Error}
    end;

cmd(<<"launch_notifications">>, #nkreq{data=Data}=Req) ->
    case nkdomain_api_util:get_id(?CHAT_SESSION, Data, Req) of
        {ok, Id} ->
            nkchat_session_obj:launch_notifications(Id);
        {error, Error} ->
            {error, Error}
    end;

cmd(<<"get_conversations">>, #nkreq{data=Data}=Req) ->
    case nkdomain_api_util:get_id(?CHAT_SESSION, Data, Req) of
        {ok, Id} ->
            case nkchat_session_obj:get_conversations(Id) of
                {ok, List} ->
                    {ok, #{conversation_ids=>List}};
                {error, Error} ->
                    {error, Error}
            end;
        {error, Error} ->
            {error, Error}
    end;

cmd(<<"get_conversation_info">>, #nkreq{data=#{conversation_id:=ConvId}=Data}=Req) ->
    case nkdomain_api_util:get_id(?CHAT_SESSION, Data, Req) of
        {ok, Id} ->
            case nkchat_session_obj:get_conversation_info(Id, ConvId) of
                {ok, Data2} ->
                    {ok, Data2};
                {error, Error} ->
                    {error, Error}
            end;
        {error, Error} ->
            {error, Error}
    end;

cmd(<<"set_active_conversation">>, #nkreq{data=#{conversation_id:=ConvId}=Data}=Req) ->
    case nkdomain_api_util:get_id(?CHAT_SESSION, Data, Req) of
        {ok, Id} ->
            case nkchat_session_obj:set_active_conversation(Id, ConvId) of
                ok ->
                    {ok, #{}};
                {error, Error} ->
                    {error, Error}
            end;
        {error, Error} ->
            {error, Error}
    end;

cmd(<<"deactivate_conversation">>, #nkreq{data=Data}=Req) ->
    case nkdomain_api_util:get_id(?CHAT_SESSION, Data, Req) of
        {ok, Id} ->
            case nkchat_session_obj:deactivate_conversation(Id) of
                ok ->
                    {ok, #{}};
                {error, Error} ->
                    {error, Error}
            end;
        {error, Error} ->
            {error, Error}
    end;

cmd(<<"add_conversation">>, #nkreq{data=#{conversation_id:=ConvId}=Data}=Req) ->
    case nkdomain_api_util:get_id(?CHAT_SESSION, Data, Req) of
        {ok, Id} ->
            case nkchat_session_obj:add_conversation(Id, ConvId) of
                {ok, ObjId} ->
                    {ok, #{conversation_id=>ObjId}};
                {error, Error} ->
                    {error, Error}
            end;
        {error, Error} ->
            {error, Error}
    end;

cmd(<<"remove_conversation">>, #nkreq{data=#{conversation_id:=ConvId}=Data}=Req) ->
    case nkdomain_api_util:get_id(?CHAT_SESSION, Data, Req) of
        {ok, Id} ->
            case nkchat_session_obj:remove_conversation(Id, ConvId) of
                ok ->
                    {ok, #{}};
                {error, Error} ->
                    {error, Error}
            end;
        {error, Error} ->
            {error, Error}
    end;

cmd(<<"send_invitation">>, #nkreq{data=#{member_id:=MemberId, conversation_id:=ConvId}=Data}=Req) ->
    case nkdomain_api_util:get_id(?CHAT_SESSION, Data, Req) of
        {ok, Id} ->
            TTL = maps:get(ttl, Data, 0),
            case nkchat_session_obj:send_invitation(Id, MemberId, ConvId, TTL) of
                {ok, TokenId} ->
                    {ok, #{<<"token">> => TokenId}};
                {error, Error} ->
                    {error, Error}
            end;
        {error, Error} ->
            {error, Error}
    end;

cmd(<<"accept_invitation">>, #nkreq{data=#{token:=TokenId}=Data}=Req) ->
    case nkdomain_api_util:get_id(?CHAT_SESSION, Data, Req) of
        {ok, Id} ->
            nkchat_session_obj:accept_invitation(Id, TokenId);
        {error, Error} ->
            {error, Error}
    end;

cmd(<<"reject_invitation">>, #nkreq{data=#{token:=TokenId}=Data}=Req) ->
    case nkdomain_api_util:get_id(?CHAT_SESSION, Data, Req) of
        {ok, Id} ->
            nkchat_session_obj:reject_invitation(Id, TokenId);
        {error, Error} ->
            {error, Error}
    end;

cmd(<<"wakeup">>, #nkreq{data=Data}=Req) ->
    case nkdomain_api_util:get_id(?CHAT_SESSION, Data, Req) of
        {ok, Id} ->
            nkchat_session_obj:wakeup(Id);
        {error, Error} ->
            {error, Error}
    end;

cmd(Cmd, Req) ->
    nkdomain_obj_cmd:cmd(Cmd, ?CHAT_SESSION, Req).



%% ===================================================================
%% Internal
%% ===================================================================
