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

-export([create/2, update/2]).
-export([object_info/0, object_es_mapping/0, object_parse/2, object_create/1, object_event/2]).
-export([object_admin_info/0]).
-export([syntax_check_file/3]).

-include("nkchat.hrl").
-include_lib("nkdomain/include/nkdomain.hrl").
-include_lib("nkdomain/include/nkdomain_debug.hrl").


%% ===================================================================
%% Types
%% ===================================================================

-type message_type() :: binary().

-type layout() :: binary().

-type create_opts() ::
    #{
        text => binary(),                       % Mandatory
        created_by => nkdomain:obj_id(),
        type => message_type(),
        layout => layout(),
        body => map(),
        file_id => nkdomain:obj_id(),
        meta => map(),
        member_roles => [nkchat_conversation_obj:member_role()]
    }.

-type update_opts() ::
    #{
        text => binary(),
        type => message_type(),
        layout => layout(),
        body => map(),
        meta => map()
    }.


%% ===================================================================
%% Public
%% ===================================================================

-spec create(nkdomain:id(), create_opts()) ->
    {ok, MsgId::nkdomain:obj_id(), pid()} | {error, term()}.

create(Conv, Opts) ->
    case nkchat_conversation_obj:get_status(Conv) of
        {ConvId, DomainId, _Status, false} ->
            Msg = maps:with([text, type, layout, body, file_id, meta, member_roles], Opts),
            Obj = #{
                type => ?CHAT_MESSAGE,
                domain_id => DomainId,
                parent_id => ConvId,
                created_by => maps:get(created_by, Opts, <<"admin">>),
                ?CHAT_MESSAGE => Msg
            },
            lager:error("NKLOG OBJ ~p", [Obj]),
            case nkdomain_obj_make:create(Obj#{domain_id=>DomainId}) of
                {ok, #obj_id_ext{obj_id=MsgId, pid=MsgPid}, _Unknown} ->
                    {ok, MsgId, MsgPid};
                {error, Error} ->
                    {error, Error}
            end;
        {_, _, _, true} ->
            {error, converation_is_closed};
        {error, Error} ->
            {error, Error}
    end.


-spec update(nkdomain:id(), update_opts()) ->
    ok | {error, term()}.

update(MsgId, Opts) ->
    Msg = maps:with([text, file_id, body], Opts),
    case nkdomain:update(MsgId, #{?CHAT_MESSAGE => Msg}) of
        {ok, _} ->
            ok;
        {error, Error} ->
            {error, Error}
    end.



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
        type => #{type => keyword},
        layout => #{type => keyword},
        text => #{type => text},
        file_id => #{type => keyword},
        body => #{enabled => false},
        meta => #{enabled => false},
        member_roles => #{type => keyword}
    }.



%% @private
object_parse(update, _Obj) ->
    #{
        text => binary,
        layout => #{type => keyword},
        file_id => fun ?MODULE:syntax_check_file/3,
        body => map,
        meta => map
    };

object_parse(_Mode, Obj) ->
    Base = object_parse(update, Obj),
    Base#{
        type => binary,
        member_roles => #{type => keyword},
        '__defaults' => #{type => text},
        '__mandatory' => [text]
    }.



%% @doc
object_create(#{parent_id:=ConvId}=Obj) ->
    lager:error("NKLOG CREATE ~p", [Obj]),
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
