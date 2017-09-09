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

%% @doc Conversation Object Syntax
-module(nkchat_media_call_obj_syntax).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-export([syntax/2]).

-include("nkchat.hrl").


%% ===================================================================
%% Syntax
%% ===================================================================


%%%% @doc
syntax(<<"add_member">>, Syntax) ->
    Syntax#{
        id => binary,
        member_id => binary,
        '__mandatory' => [id, member_id]
    };

syntax(<<"remove_member">>, Syntax) ->
    Syntax#{
        id => binary,
        member_id => binary,
        '__mandatory' => [id, member_id]
    };

syntax(<<"find_member_calls">>, Syntax) ->
    Syntax#{
        domain_id => binary,
        member_id => binary
    };

syntax(<<"find_calls_with_members">>, Syntax) ->
    Syntax#{
        domain_id => binary,
        member_ids => {list, binary},
        '__mandatory' => [member_ids]
    };

syntax(<<"send_candidate">>, Syntax) ->
    Syntax#{
        id => binary,
        sdp_mid => binary,
        sdp_line_index => binary,
        candidate => binary,
        '__mandatory' => [id, sdp_mid, sdp_line_index, candidate]
    };

syntax(<<"send_candidate_end">>, Syntax) ->
    Syntax#{
        id => binary,
        '__mandatory' => [id]
    };

syntax(<<"set_status">>, Syntax) ->
    Syntax#{
        id => binary,
        audio => boolean,
        video => boolean,
        '__mandatory' => [id]
    };

syntax(Cmd, Syntax) ->
    nkdomain_obj_syntax:syntax(Cmd, ?CHAT_CONVERSATION, Syntax).
