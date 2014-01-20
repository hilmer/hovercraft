%%%-------------------------------------------------------------------
%%% File    : hovercraft.erl
%%% Author  : J Chris Anderson <jchris@couch.io>
%%% Description : Erlang CouchDB access.
%%%
%%% Created : 4 Apr 2009 by J Chris Anderson <jchris@couch.io>
%%% License : Apache 2.0
%%%-------------------------------------------------------------------
-module(hovercraft_test).
-vsn("0.1.1").

%% see README.md for usage information

-export([all/0, all/1, lightning/0, lightning/1]).

-include_lib("/home/sh/apache-couchdb-1.5.0/src/couchdb/couch_db.hrl").
-include_lib("/home/sh/apache-couchdb-1.5.0/src/couch_mrview/include/couch_mrview.hrl").

-define(ADMIN_USER_CTX, {user_ctx, #user_ctx{roles=[<<"_admin">>]}}).


%%--------------------------------------------------------------------
%%% Tests : Public Test API
%%--------------------------------------------------------------------

all() ->
    all(<<"hovercraft-test">>).

all(DbName) ->
    ?LOG_INFO("Starting tests in ~p", [DbName]),
    should_create_db(DbName),
    should_link_to_db_server(DbName),
    should_get_db_info(DbName),
    should_save_and_open_doc(DbName),
    should_stream_attachment(DbName),
    should_query_views(DbName),
    should_error_on_missing_doc(DbName),
    should_save_bulk_docs(DbName),
    should_save_bulk_and_open_with_db(DbName),
    chain(),
    ok.

chain() ->
    DbName = <<"chain-test">>,
    TargetName = <<"chain-results-test">>,
    should_create_db(DbName),
    should_create_db(TargetName),
    % make ddoc
    DDocName = <<"view-test">>,
    {ok, {_Resp}} = hovercraft:save_doc(DbName, make_test_ddoc(DDocName)),
    % make docs
    {ok, _RevInfos} = make_test_docs(DbName, {[{<<"lorem">>, <<"Lorem ipsum dolor sit amet, consectetur adipisicing elit, sed do eiusmod tempor incididunt ut labore et dolore magna aliqua. Ut enim ad minim veniam, quis nostrud exercitation ullamco laboris nisi ut aliquip ex ea commodo consequat. Duis aute irure dolor in reprehenderit in voluptate velit esse cillum dolore eu fugiat nulla pariatur. Excepteur sint occaecat cupidatat non proident, sunt in culpa qui officia deserunt mollit anim id est laborum.">>}]}, 200),
    do_chain(DbName, <<"view-test">>, <<"letter-cloud">>, TargetName).

%% Performance Tests
lightning() ->
    lightning(1000).

lightning(BulkSize) ->
    lightning(BulkSize, 100000, <<"hovercraft-lightning">>).

lightning(BulkSize, NumDocs, DbName) ->
    hovercraft:delete_db(DbName),
    {ok, created} = hovercraft:create_db(DbName),
    {ok, Db} = hovercraft:open_db(DbName),
    Doc = {[{<<"foo">>, <<"bar">>}]},
    StartTime = now(),
    insert_in_batches(Db, NumDocs, BulkSize, Doc, 0),
    Duration = timer:now_diff(now(), StartTime) / 1000000,
    io:format("Inserted ~p docs in ~p seconds with batch size of ~p. (~p docs/sec)~n",
        [NumDocs, Duration, BulkSize, NumDocs / Duration]).


%%--------------------------------------------------------------------
%%% Tests : Test Cases
%%--------------------------------------------------------------------

should_create_db(DbName) ->
    hovercraft:delete_db(DbName),
    {ok, created} = hovercraft:create_db(DbName),
    {ok, _DbInfo} = hovercraft:db_info(DbName).

should_link_to_db_server(DbName) ->
    {ok, DbInfo} = hovercraft:db_info(DbName),
    DbName = proplists:get_value(db_name, DbInfo).

should_get_db_info(DbName) ->
    {ok, DbInfo} = hovercraft:db_info(DbName),
    DbName = proplists:get_value(db_name, DbInfo),
    0 = proplists:get_value(doc_count, DbInfo),
    0 = proplists:get_value(update_seq, DbInfo).

should_save_and_open_doc(DbName) ->
    Doc = {[{<<"foo">>, <<"bar">>}]},
    {ok, {Resp}} = hovercraft:save_doc(DbName, Doc),
    DocId = proplists:get_value(id, Resp),
    {ok, {Props}} = hovercraft:open_doc(DbName, DocId),
    <<"bar">> = proplists:get_value(<<"foo">>, Props).

should_error_on_missing_doc(DbName) ->
    try hovercraft:open_doc(DbName, <<"not a doc">>)
    catch
        throw:{not_found,missing} ->
             ok
    end.

should_save_bulk_docs(DbName) ->
    Docs = [{[{<<"foo">>, <<Seq:8>>}]} || Seq <- lists:seq(1, 100)],
    {ok, RevInfos} = hovercraft:save_bulk(DbName, Docs),
    L = lists:foldl(fun({[{ok,true},{id,DocId},{rev,Rev}]}, Acc) ->
                            {ok, {Doc}} = hovercraft:open_doc(DbName, DocId),
                            [_Id, {<<"_rev">>, Rev}, {<<"foo">>, <<Value:8>>}] = Doc,
                            Rev = proplists:get_value(<<"_rev">>, Doc),
                            Value = Acc + 1,
                            Acc + 1
                    end, 0, RevInfos),
    L = 100.

should_save_bulk_and_open_with_db(DbName) ->
    {ok, Db} = hovercraft:open_db(DbName),
    Docs = [{[{<<"foo">>, <<Seq:8>>}]} || Seq <- lists:seq(1, 100)],
    {ok, RevInfos} = hovercraft:save_bulk(Db, Docs),
    L = lists:foldl(fun({[{ok,true},{id,DocId},{rev,Rev}]}, Acc) ->
                            {ok, {Doc}} = hovercraft:open_doc(DbName, DocId),
                            [_Id, {<<"_rev">>, Rev}, {<<"foo">>, <<Value:8>>}] = Doc,
                            Rev = proplists:get_value(<<"_rev">>, Doc),
                            Value = Acc + 1,
                            Acc + 1
                    end, 0, RevInfos),
    L = 100.

should_stream_attachment(DbName) ->
    % setup
    AName = <<"test.txt">>,
    ABytes = list_to_binary(string:chars($a, 10*1024, "")),
    Doc = {[{<<"foo">>, <<"bar">>},
        {<<"_attachments">>, {[{AName, {[
            {<<"content_type">>, <<"text/plain">>},
            {<<"data">>, base64:encode(ABytes)}
        ]}}]}}
    ]},
    {ok, {Resp}} = hovercraft:save_doc(DbName, Doc),
    DocId = proplists:get_value(id, Resp),
    % stream attachment
    {ok, Pid} = hovercraft:start_attachment(DbName, DocId, AName),
    {ok, Attachment} = get_full_attachment(Pid, []),
    ABytes = Attachment,
    ok.

should_query_views(DbName) ->
    % make ddoc
    DDocName = <<"view-test">>,
    {ok, {_Resp}} = hovercraft:save_doc(DbName, make_test_ddoc(DDocName)),
    % make docs
    {ok, _RevInfos} = make_test_docs(DbName, {[{<<"hovercraft">>, <<"views rule">>}]}, 20),
    ?LOG_INFO("Query map view ", []),
    should_query_map_view(DbName, DDocName),
    ?LOG_INFO("Query reduce view ", []),
    should_query_reduce_view(DbName, DDocName),
    ?LOG_INFO("Query all docs view ", []),
    should_query_all_docs_view(DbName).

should_query_all_docs_view(DbName) ->
    {ok, {RowCount, Offset, Rows}} = hovercraft:query_view(DbName, undefined, <<"_all_docs">>),
    23 = length(Rows),
    RowCount = length(Rows),
    0 = Offset,
    % assert we got every row
    ?LOG_INFO("Got all documents ~p ", [RowCount]),
    RowCount = lists:foldl(fun([{id,RDocId},{key,_DocKey}, {value,_RValue}], Acc) -> 
                                   {ok, {DocProps}} = hovercraft:open_doc(DbName,RDocId),
                                   _RKey = proplists:get_value(<<"_rev">>, DocProps),
                                   Acc + 1
                           end, 0, Rows).


should_query_map_view(DbName, DDocName) ->
    % use the default query arguments and row collector function
    {ok, {RowCount, Offset, Rows}} = 
        hovercraft:query_view(DbName, DDocName, <<"basic">>),
    % assert rows is the right length
    20 = length(Rows),
    RowCount = length(Rows),
    0 = Offset,
    % assert we got every row
    RowCount = lists:foldl(fun([{id,RDocId},{key,_DocKey}, {value,_RValue}], Acc) -> 
                                   {ok, {DocProps}} = hovercraft:open_doc(DbName, RDocId),
                                   _RKey = proplists:get_value(<<"_rev">>, DocProps),
                                   Acc + 1
                           end, 0, Rows).

should_query_reduce_view(DbName, DDocName) ->
    {ok, [Result]} =
        hovercraft:query_view(DbName, DDocName, <<"reduce-sum">>),
    {null, 20} = Result,
    {ok, Results} =
        hovercraft:query_view(DbName, DDocName, <<"reduce-sum">>, #mrargs{
            group_level = exact
        }),
    [{_,20}] = Results.


%%--------------------------------------------------------------------
%%% Helper Functions
%%--------------------------------------------------------------------

get_full_attachment(Pid, Acc) ->
    Val = hovercraft:next_attachment_bytes(Pid),
    case Val of
        {ok, done} ->
            {ok, list_to_binary(lists:reverse(Acc))};
        {ok, Bin} ->
            get_full_attachment(Pid, [Bin|Acc])
    end.

make_test_ddoc(DesignName) ->
    {[
        {<<"_id">>, <<"_design/", DesignName/binary>>},
        {<<"views">>, {[
            {<<"basic">>,
                {[
                    {<<"map">>,
<<"function(doc) { if(doc.hovercraft == 'views rule') emit(doc._rev, 1) }">>}
                ]}
            },{<<"reduce-sum">>,
                {[
                    {<<"map">>,
<<"function(doc) { if(doc.hovercraft == 'views rule') emit(doc._rev, 1) }">>},
                    {<<"reduce">>,
                    <<"function(ks,vs,co){ return sum(vs)}">>}
                ]}
            },{<<"letter-cloud">>,
                {[
                    {<<"map">>,
                    <<"function(doc){if (doc.lorem) {
                        for (var i=0; i < doc.lorem.length; i++) {
                          var c = doc.lorem[i];
                          emit(c,1)
                        };
                    }}">>},
                    {<<"reduce">>,
                        <<"_count">>}
                ]}
            }
        ]}}
    ]}.

make_test_docs(DbName, Doc, Count) ->
    Docs = [Doc || _Seq <- lists:seq(1, Count)],
    hovercraft:save_bulk(DbName, Docs).

do_chain(SourceDbName, SourceDDocName, SourceView, TargetDbName) ->
    {ok, Db} = hovercraft:open_db(TargetDbName),
    CopyToDbFun = 
        fun
            ({meta, Meta}, {RowCount, OffSet, Rows})->
                {ok, {RowCount, case couch_util:get_value(offset, Meta) of
                                    undefined -> OffSet;
                                    New_Offset -> New_Offset
                                end, Rows}};
            ({row, Row}, {RowCount, OffSet,  Rows}) when RowCount > 50 ->
                hovercraft:save_bulk(Db, [row_to_doc(Row)|Rows]),
                {ok, {0, OffSet,  []}};
            ({row, Row}, {RowCount, OffSet,  Rows}) ->
                {ok, {RowCount+1, OffSet,[row_to_doc(Row)|Rows]}};
            (complete, {RowCount, OffSet, Rows}) -> {ok, {RowCount,OffSet,lists:reverse(Rows)}}
        end,
    {ok, Acc1} = hovercraft:query_view(SourceDbName, SourceDDocName, SourceView, CopyToDbFun, #mrargs{
        group_level = exact
    }),
    hovercraft:save_bulk(Db, Acc1),
    ok.

row_to_doc([{key,Key}, {value,Value}]) ->
    {[
    {<<"key">>, Key},
    {<<"value">>,Value}
    ]}.

insert_in_batches(Db, NumDocs, BulkSize, Doc, StartId) when NumDocs > 0 ->
    LastId = insert_batch(Db, BulkSize, Doc, StartId),
    insert_in_batches(Db, NumDocs - BulkSize, BulkSize, Doc, LastId+1);
insert_in_batches(_, _, _, _, _) ->
    ok.

insert_batch(Db, BulkSize, Doc, StartId) ->
    {ok, Docs, LastId} = make_docs_list(Doc, BulkSize, [], StartId),
    {ok, _RevInfos} = hovercraft:save_bulk(Db, Docs),
    LastId.

make_docs_list({_DocProps}, 0, Docs, Id) ->
    {ok, Docs, Id};
make_docs_list({DocProps}, Size, Docs, Id) ->
    ThisDoc = {[{<<"_id">>, make_id_str(Id)}|DocProps]},
    make_docs_list({DocProps}, Size - 1, [ThisDoc|Docs], Id + 1).

make_id_str(Num) ->
    ?l2b(lists:flatten(io_lib:format("~10..0B", [Num]))).

