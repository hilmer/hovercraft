%%%-------------------------------------------------------------------
%%% File    : hovercraft.erl
%%% Author  : J Chris Anderson <jchris@couch.io>
%%% Description : Erlang CouchDB access.
%%%
%%% Created : 4 Apr 2009 by J Chris Anderson <jchris@couch.io>
%%% License : Apache 2.0
%%%-------------------------------------------------------------------
-module(hovercraft).
-vsn("0.1.6").

%% see README.md for usage information

%% Database API
-export([
    create_db/1,
    delete_db/1,
    open_db/1,
    db_info/1,
    open_doc/2, 
    save_doc/2,
    save_bulk/2,
    delete_doc/2,
    start_attachment/3,
    next_attachment_bytes/1,
    query_view/3,
    query_view/4,
    query_view/5
]).

% Hovercraft is designed to run inside the same beam process as CouchDB.
% It calls into CouchDB's database access functions, so it needs access
% to the disk. To hook it up, make sure hovercraft is in the Erlang load 
% path and ensure that the following line points to CouchDB's hrl file.
-include_lib("/home/sh/apache-couchdb-1.5.0/src/couchdb/couch_db.hrl").
-include_lib("/home/sh/apache-couchdb-1.5.0/src/couch_mrview/include/couch_mrview.hrl").

-define(ADMIN_USER_CTX, {user_ctx, #user_ctx{roles=[<<"_admin">>]}}).

%%====================================================================
%% API
%%====================================================================
%%--------------------------------------------------------------------
%% Function: create_db(DbName) -> {ok,created} | {error,Error}
%% DbName is always a binary: <<"mydb">>
%% Description: Creates the database.
%%--------------------------------------------------------------------

create_db(DbName) ->
    create_db(DbName, []).

create_db(DbName, Options) ->
    case couch_server:create(DbName, Options) of
    {ok, Db} ->
        couch_db:close(Db),
        {ok, created};
    Error ->
        {error, Error}
    end.

%%--------------------------------------------------------------------
%% Function: delete_db(DbName) -> {ok,deleted} | {error,Error}
%% Description: Deletes the database.
%%--------------------------------------------------------------------
delete_db(DbName) ->
    delete_db(DbName,  [?ADMIN_USER_CTX]).
    
delete_db(DbName, Options) ->
    case couch_server:delete(DbName, Options) of
    ok ->
        {ok, deleted};
    Error ->
        {error, Error}
    end.

%%--------------------------------------------------------------------
%% Function: open_db(DbName) -> {ok,Db} | {error,Error}
%% Description: Opens the database.
%% Only use this if you are doing bulk operations and know what you are doing.
%%--------------------------------------------------------------------
open_db(DbName) ->
    couch_db:open(DbName, [?ADMIN_USER_CTX]).

%%--------------------------------------------------------------------
%% Function: db_info(DbName) -> {ok,Db} | {error,Error}
%% Description: Gets the db_info as a proplist
%%--------------------------------------------------------------------
db_info(DbName) ->
    {ok, Db} = open_db(DbName),
    couch_db:get_db_info(Db).

%%--------------------------------------------------------------------
%% Function: open_doc(DbName, DocId) -> {ok,Doc} | {error,Error}
%% Description: Gets the eJSON form of the Document
%%--------------------------------------------------------------------
open_doc(DbName, DocId) ->
    {ok, Db} = open_db(DbName),
    CouchDoc = couch_httpd_db:couch_doc_open(Db, DocId, nil, []),
    Doc = couch_doc:to_json_obj(CouchDoc, []),
    {ok, Doc}.
        
%%--------------------------------------------------------------------
%% Function: save_doc(DbName, Doc) -> {ok, EJsonInfo} | {error,Error}
%% Description: Saves the doc in the database, returns the id and rev
%%--------------------------------------------------------------------
save_doc(#db{}=Db, Doc) ->
    CouchDoc = ejson_to_couch_doc(Doc),
    {ok, Rev} = couch_db:update_doc(Db, CouchDoc, []),
    {ok, {[{id, CouchDoc#doc.id}, {rev, couch_doc:rev_to_str(Rev)}]}};
save_doc(DbName, Docs) ->
    {ok, Db} = open_db(DbName),
    save_doc(Db, Docs).

%%--------------------------------------------------------------------
%% Function: save_bulk(DbName, Docs) -> {ok, EJsonInfo} | {error,Error}
%% Description: Saves the docs the database, returns the ids and revs
%%--------------------------------------------------------------------
save_bulk(#db{}=Db, Docs) ->
    CouchDocs = [ejson_to_couch_doc(EJsonDoc) || EJsonDoc <- Docs],
    {ok, Results} = couch_db:update_docs(Db, CouchDocs),
    {ok, lists:zipwith(fun couch_httpd_db:update_doc_result_to_json/2,
        CouchDocs, Results)};
save_bulk(DbName, Docs) ->
    {ok, Db} = open_db(DbName),
    save_bulk(Db, Docs).
    

%%--------------------------------------------------------------------
%% Function: delete_doc(DbName, DocId) -> {ok, {DocId, RevString}} | {error,Error}
%% Description: Deletes the doc
%%--------------------------------------------------------------------
delete_doc(DbName, {DocProps}) ->
    save_doc(DbName, {[{<<"_deleted">>, true}|DocProps]}).


%%--------------------------------------------------------------------
%% Function: start_attachment(DbName, DocId, AName) -> {ok, Pid} | {error,Error}
%% Description: Starts a process to use for fetching attachment bytes
%%--------------------------------------------------------------------
start_attachment(DbName, DocId, AName) -> 
    Pid = spawn_link(fun() -> 
            attachment_streamer(DbName, DocId, AName)
        end),
    {ok, Pid}.

%%--------------------------------------------------------------------
%% Function: next_attachment_bytes(Pid) -> {ok, done} | {error,Error}
%% Description: Fetch attachment bytes
%%--------------------------------------------------------------------
next_attachment_bytes(Pid) ->
    Pid ! {next_attachment_bytes, self()},
    receive
        {attachment_done, Pid} ->
            {ok, done};
        {attachment_bytes, Pid, {Bin, Length}} ->
           {Length, _Reason} = {size(Bin), "assert Bin length match"},
           {ok, Bin}
    end.

query_view(DbName, DesignName, ViewName) ->
    query_view(DbName, DesignName, ViewName, #mrargs{}).
   
query_view(DbName, DesignName, ViewName, #mrargs{}=QueryArgs) ->
    % provide a default row collector fun
    % don't use this on big data it will balloon in memory
    RowCollectorFun = fun hovercraft_cb/2,
    query_view(DbName, DesignName, ViewName, RowCollectorFun, QueryArgs);

query_view(DbName, DesignName, ViewName, ViewFoldFun) ->
    query_view(DbName, DesignName, ViewName, ViewFoldFun, #mrargs{}).

% special case for special all_docs view
query_view(DbName, undefined, <<"_all_docs">>, _ViewFoldFun, #mrargs{
            limit = Limit,
            skip = SkipCount,
            stale = _Stale,
            direction = Dir,
            group_level = _GroupLevel,
            start_key = StartKey,
            start_key_docid = StartDocId,
            end_key = EndKey,
            end_key_docid = EndDocId,
            inclusive_end = Inclusive
        }=QueryArgs) ->
    {ok, Db} = open_db(DbName),
    Acc = {0, 0, []},
    couch_mrview:query_all_docs(Db, QueryArgs#mrargs{reduce=false}, fun hovercraft_cb/2, Acc);

    
query_view(DbName, DesignName, ViewName, ViewFoldFun, #mrargs{
            limit = Limit,
            skip = SkipCount,
            stale = Stale,
            direction = Dir,
            group_level = GroupLevel,
            start_key = StartKey,
            start_key_docid = StartDocId
        }=QueryArgs) ->


    {ok, Db} = open_db(DbName),
    % get view reference
    DesignId = <<"_design/", DesignName/binary>>,

    {ok, {Type, View}, Sig, Args3} = couch_mrview_util:get_view(Db,DesignId,ViewName,QueryArgs),

    Acc = {0, 0, []},
    case Type of 
        map ->
            couch_mrview:query_view(Db, DesignId, ViewName, Args3#mrargs{reduce=false}, ViewFoldFun, Acc);
        red ->
            case couch_mrview:query_view(Db, DesignId, ViewName, Args3#mrargs{reduce=QueryArgs#mrargs.reduce}, ViewFoldFun, Acc) of
                {ok,{_,_,[[{key,Key},{value,Value}]]}} ->
                    case QueryArgs#mrargs.group_level of
                        exact -> {ok,[{Key,Value}]};
                        _ -> {ok,[{null,Value}]}
                    end;
                {ok,{_,_,Rows}} -> {ok,Rows}
            end
    end.

    

%%--------------------------------------------------------------------
%%% Internal functions
%%--------------------------------------------------------------------

hovercraft_cb({meta, Meta}, {RowCount, OffSet, Rows}) -> 
   {ok, {RowCount, case couch_util:get_value(offset, Meta) of
                       undefined -> OffSet;
                       New_Offset -> New_Offset
                   end, Rows}};
hovercraft_cb({row, Row}, {RowCount, OffSet,  Rows}) -> {ok, {RowCount+1,OffSet,[Row | Rows]}};
hovercraft_cb(complete, {RowCount, OffSet, Rows}) -> {ok, {RowCount,OffSet,lists:reverse(Rows)}}.

ejson_to_couch_doc({DocProps}) ->
    Doc = case proplists:get_value(<<"_id">>, DocProps) of
        undefined ->
            DocId = couch_uuids:new(),
            {[{<<"_id">>, DocId}|DocProps]};
        _DocId ->
            {DocProps}
    end,
    couch_doc:from_json_obj(Doc).

start_map_view_fold_fun(_Req, _Etag, _RowCount, Offset, _Acc, _UpdateSeq) ->
    {ok, nil, {Offset, []}}.

make_map_row_fold_fun(ViewFoldFun) ->
    fun(_Resp, _Db, {{Key, DocId}, Value}, _IncludeDocs, {Offset, Acc}) ->
        {Go, NewAcc} = ViewFoldFun({{Key, DocId}, Value}, Acc),
        {Go, {Offset, NewAcc}}
    end.

make_include_docs_row_fold_fun() ->
    fun(_Resp, Db, Doc, IncludeDocs, {Offset, Acc}) ->
        D = couch_httpd_view:view_row_obj(Db, Doc, IncludeDocs),
        {ok, {Offset, [D | Acc]}}
    end.

start_reduce_view_fold_fun(_Req, _Etag, _Acc0, _UpdateSeq) ->
    {ok, nil, []}.

make_reduce_row_fold_fun(ViewFoldFun) ->
    fun(_Resp, {Key, Value}, Acc) ->
        {Go, NewAcc} = ViewFoldFun({Key, Value}, Acc),
        {Go, NewAcc}
    end.


attachment_streamer(DbName, DocId, AName) ->
    {ok, Db} = open_db(DbName),
    case couch_db:open_doc(Db, DocId, []) of
    {ok, #doc{atts=Attachments}=_Doc} ->
        case [A || A <- Attachments, A#att.name == AName] of
        [] ->
            throw({not_found, "Document is missing attachment"});
        [Rec] when is_record(Rec, att) ->
            Me = self(),
            couch_doc:att_foldl_decode(Rec,
                fun(Bins, []) ->
                    BinSegment = list_to_binary(Bins),
                    receive
                        {next_attachment_bytes, From} ->
                            From ! {attachment_bytes, Me, {BinSegment, size(BinSegment)}}
                    end,
                    {ok, []}
                end,
                []
            ),            
            receive
                {next_attachment_bytes, From} ->
                    From ! {attachment_done, Me}
            end
        end;
    _Else ->
        throw({not_found, "Document not found"})
    end.


