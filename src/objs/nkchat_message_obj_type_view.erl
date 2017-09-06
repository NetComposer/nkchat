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

%% @doc User Object

-module(nkchat_message_obj_type_view).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-export([view/1, subview/2, table_data/2, element_updated/3]).

-include("nkchat.hrl").
-include_lib("nkadmin/include/nkadmin.hrl").
-include_lib("nkdomain/include/nkdomain.hrl").

-define(ID, <<"domain_detail_type_view__message">>).
-define(ID_SUBDOMAINS, <<"domain_detail_type_view__message__subdomains">>).


%% @doc
view(Session) ->
    table(#{is_subtable=>false}, Session).

%% @doc
subview(Opts, Session) ->
    table(Opts#{is_subtable=>true}, Session).


%% @doc
table(Opts, Session) ->
    Id = case Opts of
        #{table_id:=TableId} ->
%            <<?ID/binary, "__", TableId/binary>>;
            TableId;
        _ ->
            ?ID
    end,
    Spec = #{
        table_id => Id,
        is_subtable => maps:get(is_subtable, Opts),
        subdomains_id => ?ID_SUBDOMAINS,
        filters => [?ID_SUBDOMAINS],
        columns => [
            #{
                id => checkbox,
                type => checkbox
            },
            #{
                id => conversation,
                type => text,
                name => domain_column_conversation,
                sort => false,
                options => nkdomain_admin_util:get_agg(<<"parent_id">>, ?CHAT_MESSAGE, Session),
                is_html => true
            },
            #{
                id => created_time,
                type => date,
                name => domain_column_created_time,
                sort => true
            },
            #{
                id => created_by,
                type => text,
                name => domain_column_created_by,
                sort => false,
                options => nkdomain_admin_util:get_agg(<<"created_by">>, ?CHAT_MESSAGE, Session),
                is_html => true % Will allow us to return HTML inside the column data
            },
            #{
                id => text,
                type => text,
                name => domain_column_text,
                editor => text,
                fillspace => 2
            },
            #{
                id => file_id,
                type => text,
                name => domain_column_file_id,
                options => [#{id=><<>>, value=><<>>}, #{id=>with_attach, value=><<"With attach">>}],
                is_html => true
            }
        ],
        left_split => 1,
%        right_split => 2,
        on_click => [
%            #{
%                id => <<"fa-times">>,
%                type => disable
%            },
%            #{
%                id => <<"fa-check">>,
%                type => enable
%            },
%            #{
%                id => <<"fa-trash">>,
%                type => delete
%            }            
        ]
    },
    Spec2 = case Opts of
        #{header:=Header} ->
            Spec#{header => Header};
        _ ->
            Spec
    end,
    Table = #{
%        id => ?ID,
        id => Id,
        class => webix_ui,
        value => nkadmin_webix_datatable:datatable(Spec2, Session)
    },
    KeyData = #{data_fun => fun ?MODULE:table_data/2},
%    Session2 = nkadmin_util:set_key_data(?ID, KeyData, Session),
    Session2 = nkadmin_util:set_key_data(Id, KeyData, Session),
    {Table, Session2}.


%% @doc
table_data(#{start:=Start, size:=Size, sort:=Sort, filter:=Filter}, Session) ->
    #admin_session{srv_id=SrvId, domain_id=DomainId} = Session,
    SortSpec = case Sort of
        {<<"conversation">>, Order} ->
            <<Order/binary, ":path">>;
        {Field, Order} when Field==<<"created_by">>; Field==<<"created_time">> ->
            <<Order/binary, $:, Field/binary>>;
        _ ->
            <<"desc:path">>
    end,
    %% Get the timezone_offset from the filter list and pass it to table_filter
    case table_filter(maps:to_list(Filter), Filter, #{type=>message}) of
        {ok, Filters} ->
            lager:warning("NKLOG Filters ~s", [nklib_json:encode_pretty(Filter)]),

            FindSpec = #{
                filters => Filters,
                fields => [<<"created_by">>, <<"created_time">>, <<"parent_id">>,
                           <<"domain_id">>, <<"message.text">>, <<"message.file_id">>],
                sort => SortSpec,
                from => Start,
                size => Size
            },
            Fun = case Filter of
                #{?ID_SUBDOMAINS := 0} -> search;
                _ -> search_all
            end,
            case nkdomain_domain_obj:Fun(SrvId, DomainId, FindSpec) of
                {ok, Total, List, _Meta} ->
                    Data = table_iter(List, Start+1, [], Session),
                    {ok, Total, Data};
                {error, Error} ->
                    {error, Error}
            end;
        {error, Error} ->
            {error, Error}
    end.


%% @private
table_filter([], _Filter, Acc) ->
    {ok, Acc};

table_filter([{_, <<>>}|Rest], Filter, Acc) ->
    table_filter(Rest, Filter, Acc);

table_filter([{<<"conversation">>, Data}|Rest], Filter, Acc) ->
    Acc2 = Acc#{<<"parent_id">> => Data},
    table_filter(Rest, Filter, Acc2);

table_filter([{<<"created_by">>, Data}|Rest], Filter, Acc) ->
    Acc2 = Acc#{<<"created_by">> => Data},
    table_filter(Rest, Filter, Acc2);

table_filter([{<<"created_time">>, Data}|Rest], Filter, Acc) ->
    case nkdomain_admin_util:table_filter_time(Data, Filter, Acc) of
        {ok, Acc2} ->
            table_filter(Rest, Filter, Acc2);
        {error, Error} ->
            {error, Error}
    end;

table_filter([{<<"text">>, Data}|Rest], Filter, Acc) ->
    Acc2 = Acc#{<<"message.text">> => Data},
    table_filter(Rest, Filter, Acc2);

table_filter([{<<"file_id">>, <<"with_attach">>}|Rest], Filter, Acc) ->
    Acc2 = Acc#{<<"message.file_id">> => <<"prefix:file">>},
    table_filter(Rest, Filter, Acc2);

table_filter([{<<"file_id">>, <<"false">>}|Rest], Filter, Acc) ->
    Acc2 = Acc#{<<"message.file_id">> => <<>>},
    table_filter(Rest, Filter, Acc2);

table_filter([_|Rest], Filter, Acc) ->
    table_filter(Rest, Filter, Acc).


%% @private
table_iter([], _Pos, Acc, _Session) ->
    lists:reverse(Acc);

table_iter([Entry|Rest], Pos, Acc, #admin_session{srv_id=SrvId}=Session) ->
    #{
        <<"obj_id">> := ObjId,
        <<"parent_id">> := ParentId,
        <<"created_time">> := CreatedTime
    } = Entry,
    Message = maps:get(<<"message">>, Entry, #{}),
    MessageText = maps:get(<<"text">>, Message, <<>>),
    MessageFileId = maps:get(<<"file_id">>, Message, <<>>),
    CreatedBy = maps:get(<<"created_by">>, Entry, <<>>),
    Enabled = maps:get(<<"enabled">>, Entry, true),
%    Css = case Enabled of
%        true -> <<"">>;
%        false -> <<"webix_cell_disabled">>
%    end,
    Conv = case nkdomain_lib:find(SrvId, ParentId) of
        #obj_id_ext{path=ConvPath} ->
            nkdomain_admin_util:obj_url(ParentId, ConvPath);
        _ ->
            <<>>
    end,
    User = case nkdomain:get_name(SrvId, CreatedBy) of
        {ok, #{name:=UserName}} ->
            nkdomain_admin_util:obj_url(CreatedBy, UserName);
        _ ->
            <<>>
    end,
    File = case MessageFileId of
        <<>> ->
            <<>>;
        _ ->
            case nkdomain:get_obj(SrvId, MessageFileId) of
                {ok, #{name:=FileName, ?DOMAIN_FILE:=FileObj}} ->
                    #{content_type:=CT, size:=Size} = FileObj,
                    FileTxt = <<FileName/binary, $(, CT/binary, ", ",
                                (nklib_util:to_binary(Size div 1024))/binary, "KB)">>,
                    nkdomain_admin_util:obj_url(MessageFileId, FileTxt);
                _ ->
                    <<>>
            end
    end,
    Data = #{
        checkbox => <<"0">>,
        pos => Pos,
        id => ObjId,
        conversation => Conv,
        created_time => CreatedTime,
        created_by => User,
        text => MessageText,
        file_id => File,
        enabled => Enabled
%        <<"$css">> => Css
    },
    table_iter(Rest, Pos+1, [Data|Acc], Session).

%% @private
element_updated(_ObjId, Value, _Session) ->
    #{
        <<"text">> := Text
    } = Value,
    Update = #{
        ?CHAT_MESSAGE => #{
            text => Text
        }
    },
    {ok, Update}.