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

-module(nkchat_media_session_obj_events).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').
-export([event/2]).

-include("nkchat.hrl").
-include_lib("nkdomain/include/nkdomain.hrl").


%% ===================================================================
%% Public
%% ===================================================================


%% @private
event({call_created, CallId}, State) ->
    {event, {call_created, #{call_id=>CallId}}, State};

event({media_invite, MediaId, CallId, CallerId, Media}, State) ->
    {event, {media_invite, #{media_id=>MediaId, call_id=>CallId, caller_id=>CallerId, media=>Media}}, State};

event({media_invite_removed, MediaId, Reason}, State) ->
    {event, {media_invite_removed, #{media_id=>MediaId, reason=>Reason}}, State};

event({media_ringing, MediaId, CallId}, State) ->
    {event, {media_ringing, #{media_id=>MediaId, call_id=>CallId}}, State};

event({media_answered, MediaId, CallId, Opts}, State) ->
    {event, {media_answered, #{media_id=>MediaId, call_id=>CallId, media=>Opts}}, State};

event({media_started, MediaId, CallId}, State) ->
    {event, {media_started, #{media_id=>MediaId, call_id=>CallId}}, State};

event({media_stopped, MediaId, CallId, Reason}, State) ->
    {event, {media_stopped, #{media_id=>MediaId, call_id=>CallId, reason=>Reason}}, State};

event({new_candidate, CallId, #sdp_candidate{mid=MId, index=Index, candidate=Candidate}}, State) ->
    {event, {new_candidate, #{call_id=>CallId, sdp_mid=>MId, sdp_line_index=>Index, candidate=>Candidate}}, State};

event({session_status, SessId, UserId, CallId, Status}, State) ->
    {event, {session_status, #{call_id=>CallId, session_id=>SessId, user_id=>UserId, status=>Status}}, State};

event({session_started, SessId, CallId}, State) ->
    {event, {session_started, #{call_id=>CallId, session_id=>SessId}}, State};

event({session_removed, SessId, CallId}, State) ->
    {event, {session_removed, #{call_id=>CallId, session_id=>SessId}}, State};

event({call_hangup, CallId, Reason, Time}, State) ->
    {event, {call_hangup, #{call_id=>CallId, reason=>Reason, duration=>Time}}, State};

event(_Event, State) ->
    % lager:warning("NKLOG Media Event ~p", [_Event]),
    {ok, State}.




