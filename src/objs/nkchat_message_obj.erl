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

%% @doc Message Object
%%
%% Messages will always have the same domain_id as its conversation


-module(nkchat_message_obj).
-behavior(nkdomain_obj).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-export([create/3, create_by/4, update/2]).
-export([object_info/0, object_es_mapping/0, object_parse/2, object_create/1, object_event/2]).
-export([object_admin_info/0]).
-export([syntax_check_file/3]).

-include("nkchat.hrl").
-include_lib("nkdomain/include/nkdomain.hrl").
-include_lib("nkdomain/include/nkdomain_debug.hrl").


%% ===================================================================
%% Public
%% ===================================================================

create(DomainId, ConvId, Text) ->
    Obj = #{
        type => ?CHAT_MESSAGE,
        domain_id => DomainId,
        parent_id => ConvId,
        created_by => <<"admin">>,
        ?CHAT_MESSAGE => #{
            text => Text
        }
    },
    object_create(Obj).


create_by(DomainId, UserId, ConvId, Text) ->
    Obj = #{
        type => ?CHAT_MESSAGE,
        domain_id => DomainId,
        parent_id => ConvId,
        created_by => UserId,
        ?CHAT_MESSAGE => #{
            text => Text
        }
    },
    object_create(Obj).
        

update(MsgId, Text) ->
    nkdomain:update(MsgId, #{?CHAT_MESSAGE => #{text => Text}}).



%% ===================================================================
%% nkdomain_obj behaviour
%% ===================================================================


%% @private
object_info() ->
    #{
        type => ?CHAT_MESSAGE,
        dont_update_on_disabled => true,
        dont_delete_on_disabled => true,
        default_ttl => 5*60*1000
    }.


%% @doc
object_admin_info() ->
    #{
        class => resource,
        weight => 2001,
        type_view_mod => nkchat_message_obj_type_view
    }.


%% @private
object_es_mapping() ->
    #{
        vsn => #{type => keyword},
        text => #{type => text},
        file_id => #{type => keyword}
    }.



%% @private
object_parse(_Mode, _Obj) ->
    #{
        text => binary,
        file_id => fun ?MODULE:syntax_check_file/3,
        '__mandatory' => [text]
    }.



%% @doc
object_create(#{parent_id:=ConvId}=Obj) ->
    case nkdomain:get_domain_id(ConvId) of
        {ok, DomainId} ->
            nkdomain_obj_make:create(Obj#{domain_id=>DomainId});
        _ ->
            {error, {could_not_load_parent, ConvId}}
    end;

object_create(_Obj) ->
    {error, {missing_field, <<"parent_id">>}}.


%% @private
object_event(Event, #obj_state{id=#obj_id_ext{obj_id=ObjId}, obj=Obj}=State) ->
    #{parent_id:=ConvId} = Obj,
    case Event of
        created ->
            Msg = maps:with([obj_id, created_by, created_time, ?CHAT_MESSAGE], Obj),
            ok = nkchat_conversation_obj:message_event(ConvId, {created, Msg});
        deleted ->
            ok = nkchat_conversation_obj:message_event(ConvId, {deleted, ObjId});
        {updated, _} ->
            Msg = maps:with([obj_id, created_by, created_time, updated_time, ?CHAT_MESSAGE], Obj),
            ok = nkchat_conversation_obj:message_event(ConvId, {updated, Msg});
        _ ->
            ok
    end,
    {ok, State}.





%% ===================================================================
%% Internal
%% ===================================================================

syntax_check_file(file_id, File, _Ctx) ->
    case nkdomain_lib:find(File) of
        #obj_id_ext{type=?DOMAIN_FILE, obj_id=FileId} ->
            {ok, FileId};
        _ ->
            {error, {file_not_found, File}}
    end.
