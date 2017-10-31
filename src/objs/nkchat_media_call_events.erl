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

-module(nkchat_media_call_events).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-export([event/2]).

-include("nkchat.hrl").
-include_lib("nkdomain/include/nkdomain.hrl").

%% ===================================================================
%% Types
%% ===================================================================


%% ===================================================================
%% Public
%% ===================================================================


%% @private
event({call_status, Status}, State) ->
    {event, {call_status, #{status=>Status}}, State};

event({session_added, SessId, MemberId, _Data}, State) ->
    {event, {session_added, #{member_id=>MemberId, session_id=>SessId}}, State};

event({session_removed, SessId, MemberId, _Data}, State) ->
    {event, {session_removed, #{member_id=>MemberId, session_id=>SessId}}, State};

event({session_status, SessId, UserId, Status}, State) ->
    {event, {session_status, #{session_id=>SessId, user_id=>UserId, status=>Status}}, State};

event({call_hangup, Reason, Time},State) ->
    {event, {call_hangup, #{reason=>Reason, duration=>Time}}, State};

event(_Event, State) ->
    {ok, State}.





