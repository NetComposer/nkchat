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
%% ------------------------------------------------------------------

%% @doc Message Object API
-module(nkchat_message_obj_api).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-export([cmd/4]).

-include("nkchat.hrl").

%% ===================================================================
%% API
%% ===================================================================

%% @doc
cmd('', create, #{conversation_id:=ConvId, ?CHAT_MESSAGE_ATOM:=Msg}, #{srv_id:=SrvId, user_id:=UserId}=State) ->
    case nkchat_message_obj:create(SrvId, ConvId, UserId, Msg) of
        {ok, ObjId, Path, _Pid} ->
            {ok, #{obj_id=>ObjId, path=>Path}, State};
        {error, Error} ->
            {error, Error, State}
    end;

cmd(Sub, Cmd, Data, State) ->
    nkdomain_obj_api:api(Sub, Cmd, Data, ?CHAT_MESSAGE, State).

