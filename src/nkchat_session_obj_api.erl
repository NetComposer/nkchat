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
-module(nkchat_session_obj_api).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-export([cmd/4]).

-include("nkchat.hrl").

%% ===================================================================
%% API
%% ===================================================================


%% @doc
cmd('', find, Data, #{srv_id:=SrvId}=State) ->
    case get_user_id(Data, State) of
        {ok, UserId} ->
            case nkchat_session_obj:find(SrvId, UserId) of
                {ok, ObjId} ->
                    {ok, #{obj_id=>ObjId}, State};
                {error, Error} ->
                    {error, Error, State}
            end;
        Error ->
            Error
    end;

cmd('', create, Data, #{srv_id:=SrvId}=State) ->
    case get_user_id(Data, State) of
        {ok, UserId} ->
            case nkchat_session_obj:create(SrvId, UserId) of
                {ok, ObjId, _Path, _Pid} ->
                    cmd('', start, #{id=>ObjId}, State);
                {error, Error} ->
                    {error, Error, State}
            end;
        Error ->
            Error
    end;

cmd('', start, #{id:=Id}, #{srv_id:=SrvId}=State) ->
    case nkchat_session_obj:start(SrvId, Id, self()) of
        {ok, ObjId, Data} ->
            State2 = nkdomain_api_util:add_id(?CHAT_SESSION, ObjId, State),
            {ok, #{obj_id=>ObjId, data=>Data}, State2};
        {error, Error} ->
            {error, Error, State}
    end;

cmd('', stop, Data, #{srv_id:=SrvId}=State) ->
    case nkdomain_api_util:getid(?CHAT_SESSION, Data, State) of
        {ok, Id} ->
            Reply = nkchat_session_obj:stop(SrvId, Id),
            {ok, Reply, State};
        Error ->
            Error
    end;

cmd('', set_active_conversation, #{conversation_id:=ConvId}=Data, #{srv_id:=SrvId}=State) ->
    case nkdomain_api_util:getid(?CHAT_SESSION, Data, State) of
        {ok, Id} ->
            case nkchat_session_obj:set_active_conversation(SrvId, Id, ConvId) of
                ok ->
                    {ok, #{}, State};
                {error, Error} ->
                    {error, Error, State}
            end;
        Error ->
            Error
    end;

cmd('', add_conversation, #{conversation_id:=ConvId}=Data, #{srv_id:=SrvId}=State) ->
    case nkdomain_api_util:getid(?CHAT_SESSION, Data, State) of
        {ok, Id} ->
            case nkchat_session_obj:add_conversation(SrvId, Id, ConvId) of
                ok ->
                    {ok, #{}, State};
                {error, Error} ->
                    {error, Error, State}
            end;
        Error ->
            Error
    end;

cmd('', remove_conversation, #{conversation_id:=ConvId}=Data, #{srv_id:=SrvId}=State) ->
    case nkdomain_api_util:getid(?CHAT_SESSION, Data, State) of
        {ok, Id} ->
            case nkchat_session_obj:remove_conversation(SrvId, Id, ConvId) of
                ok ->
                    {ok, #{}, State};
                {error, Error} ->
                    {error, Error, State}
            end;
        Error ->
            Error
    end;

cmd(_Sub, _Cmd, _Data, State) ->
    {error, not_implemented, State}.



%% ===================================================================
%% Internal
%% ===================================================================


get_user_id(#{user_id:=UserId}, _State) ->
    {ok, UserId};
get_user_id(_, #{user_id:=UserId}) when UserId /= <<>> ->
    {ok, UserId};
get_user_id(_Data, State) ->
    {error, missing_user_id, State}.
