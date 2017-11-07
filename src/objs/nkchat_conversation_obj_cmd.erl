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

%% @doc Conversation Object API
-module(nkchat_conversation_obj_cmd).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-export([cmd/2]).

-include("nkchat.hrl").
-include_lib("nkdomain/include/nkdomain.hrl").
-include_lib("nkservice/include/nkservice.hrl").


%% ===================================================================
%% API
%% ===================================================================

cmd(<<"add_member">>, #nkreq{data=#{id:=ConvId, member_id:=MemberId}=Data}) ->
    Opts = maps:with([silent], Data),
    case nkchat_conversation_obj:add_member(ConvId, MemberId, Opts) of
        {ok, MemberObjId} ->
            {ok, #{<<"member_id">>=>MemberObjId}};
        {error, Error} ->
            {error, Error}
    end;

cmd(<<"remove_member">>, #nkreq{data=#{id:=ConvId, member_id:=MemberId}=Data}) ->
    Opts = maps:with([silent], Data),
    case nkchat_conversation_obj:remove_member(ConvId, MemberId, Opts) of
        ok ->
            {ok, #{}};
        {error, Error} ->
            {error, Error}
    end;

%%cmd(<<"make_invite_token">>, #nkreq{data=#{id:=Conv, member_id:=MemberId}, srv_id=SrvId}=Req) ->
%%    {ok, DomainId} = nkdomain_api_util:get_id(?DOMAIN_DOMAIN, none, #{}, Req),
%%    {ok, UserId} = nkdomain_api_util:get_id(?DOMAIN_USER, none, #{}, Req),
%%    case nkchat_conversation_obj:make_invite_token(SrvId, Conv, DomainId, UserId, MemberId) of
%%        {ok, TokenId} ->
%%            {ok, #{<<"token">> => TokenId}};
%%        {error, Error} ->
%%            {error, Error}
%%    end;

%%cmd(<<"accept_invite_token">>, #nkreq{data=#{token:=Token}, srv_id=SrvId}) ->
%%    nkchat_conversation_obj:accept_token(SrvId, Token);
%%
%%cmd(<<"reject_invite_token">>, #nkreq{data=#{token:=Token}, srv_id=SrvId}) ->
%%    nkchat_conversation_obj:reject_token(SrvId, Token);

cmd(<<"find_member_conversations">>, #nkreq{data=Data}=Req) ->
    case nkdomain_api_util:get_id(?DOMAIN_DOMAIN, domain_id, Data, Req) of
        {ok, DomainId} ->
            case nkdomain_api_util:get_id(?DOMAIN_USER, member_id, Data, Req) of
                {ok, MemberId} ->
                    case nkchat_conversation_obj:find_member_conversations(DomainId, MemberId) of
                        {ok, List} ->
                            List2 = [#{<<"conversation_id">>=>ConvId, <<"type">>=>Type} || {ConvId, Type}<-List],
                            {ok, #{<<"data">>=>List2}};
                        {error, Error} ->
                            {error, Error}
                    end;
                _ ->
                    {error, user_unknown}
            end;
        {error, Error} ->
            {error, Error}
    end;

cmd(<<"find_conversations_with_members">>, #nkreq{data=Data}=Req) ->
    case nkdomain_api_util:get_id(?DOMAIN_DOMAIN, domain_id, Data, Req) of
        {ok, DomainId} ->
            #{member_ids:=MemberIds} = Data,
            case nkchat_conversation_obj:find_conversations_with_members(DomainId, MemberIds) of
                {ok, Total, List} ->
                    List2 = [#{<<"conversation_id">>=>ConvId, <<"type">>=>Type} || {ConvId, Type}<-List],
                    {ok, #{<<"total">> => Total, <<"data">>=>List2}};
                {error, Error} ->
                    {error, Error}
            end;
        {error, Error} ->
            {error, Error}
    end;

cmd(<<"get_messages">>, #nkreq{data=#{id:=ConvId}=Data}) ->
    case nkchat_conversation_obj:get_messages(ConvId, Data) of
        {ok, Reply} ->
            {ok, Reply};
        {error, Error} ->
            {error, Error}
    end;

cmd(<<"get_last_messages">>, #nkreq{data=#{id:=ConvId}}) ->
    case nkchat_conversation_obj:get_last_messages(ConvId) of
        {ok, Reply} ->
            {ok, Reply};
        {error, Error} ->
            {error, Error}
    end;

cmd(Cmd, Req) ->
    nkdomain_obj_cmd:cmd(Cmd, ?CHAT_CONVERSATION, Req).

