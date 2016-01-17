-module(sql_bridge_epgsql).
-behaviour(sql_bridge_adapter).
-include("compat.hrl").

-export([start/0,
		 connect/5,
		 query/3,
		 query/4,
 		 schema_db_column/0,
		 encode/1]).

start() ->
	application:start(poolboy),
	%application:start(epgsql),
	ok.

connect(DB, User, Pass, Host, Port) when is_atom(DB) ->
	WorkerArgs = [
		{database, atom_to_list(DB)},
		{hostname, Host},
		{username, User},
		{password, Pass},
		{port, Port}
	],
	sql_bridge_utils:start_poolboy_pool(DB, WorkerArgs, sql_bridge_epgsql_worker),
	ok.

query(Type, DB, Q) ->
	query(Type, DB, Q, []).

query(Type, DB, Q, ParamList) ->
	try query_catched(Type, DB, Q, ParamList)
	catch
		exit:{noproc, _} ->
			{error, no_pool}
	end.

query_catched(Type, DB, Q, ParamList) ->
	{Q2, ParamList2} = maybe_replace_tokens(Q, ParamList),
	ToRun = fun(Worker) ->
		%% calls sql_bridge_epgsql_worker:handle_call()
		gen_server:call(Worker, {equery, Q2, ParamList2})
	end,
	Res = sql_bridge_utils:with_poolboy_pool(DB, ToRun),
	{ok, format_result(Type, Res)}.
	
maybe_replace_tokens(Q, ParamList) ->
	case sql_bridge_utils:replacement_token() of
		postgres -> {Q, ParamList};
		mysql -> sql_bridge_utils:token_mysql_to_postgres(Q, ParamList)
	end.

format_result(UID, {ok, Count}) when UID=:=update;
									 UID=:=insert;
									 UID=:=delete ->
	Count;
format_result(tuple, {ok, _Columns, Rows}) ->
	format_tuples(Rows);
format_result(list, {ok, _Columns, Rows}) ->
	format_lists(Rows);
format_result(proplist, {ok, Columns, Rows}) ->
	format_proplists(Columns, Rows);
format_result(dict, {ok, Columns, Rows}) ->
	format_dicts(Columns, Rows);
format_result(map, {ok, Columns, Rows}) ->
	format_maps(Columns, Rows).

format_tuples(Rows) ->
	case sql_bridge_utils:stringify_binaries() of
		true ->
			[list_to_tuple(format_list(Row)) || Row <- Rows];
		false ->
			Rows
	end.

format_lists(Rows) ->
	case sql_bridge_utils:stringify_binaries() of
		true ->
			[format_list(Row) || Row <- Rows];
		false ->
			[tuple_to_list(Row) || Row <- Rows]
	end.

format_list(Row) when is_tuple(Row) ->
	Row2 = tuple_to_list(Row),
	[sql_bridge_stringify:maybe_string(V) || V <- Row2].

format_proplists(Columns, Rows) ->
	ColNames = extract_colnames(Columns),
	[make_proplist(ColNames, Row) || Row <- Rows].

format_dicts(Columns, Rows) ->
	ColNames = extract_colnames(Columns),
	[make_dict(ColNames, Row) || Row <- Rows].

make_dict(Cols, Row) when is_tuple(Row) ->
	make_dict(Cols, tuple_to_list(Row), dict:new()).

make_dict([], [], Dict) ->
	Dict;
make_dict([Col|Cols], [Val|Vals], Dict) ->
	Val2 = sql_bridge_stringify:maybe_string(Val),
	NewDict = dict:store(Col, Val2, Dict),
	make_dict(Cols, Vals, NewDict).

	
extract_colnames(Columns) ->
	[list_to_atom(binary_to_list(CN)) || {column, CN, _, _, _, _} <- Columns].


make_proplist(Columns, Row) when is_tuple(Row) ->
	make_proplist(Columns, tuple_to_list(Row));
make_proplist([Col|Cols], [Val|Vals]) ->
	Val2 = sql_bridge_stringify:maybe_string(Val),
	[{Col, Val2} | make_proplist(Cols, Vals)];
make_proplist([], []) ->
	[].

-ifdef(has_maps).
format_maps(Columns, Rows) ->
	ColNames = extract_colnames(Columns),
	[make_map(ColNames, Row) || Row <- Rows].

make_map(Cols, Row) ->
	make_map(Cols, tuple_to_list(Row), maps:new()).

make_map([], [], Map) ->
	Map;
make_map([Col|Cols],[Val|Vals], Map) ->
	Val2 = sql_bridge_stringify:maybe_string(Val),
	NewMap = maps:put(Col, Val2, Map),
	make_map(Cols, Vals, NewMap).

-else.
format_maps(_,_) ->
	throw(maps_not_supported).
-endif.

schema_db_column() ->
	"table_catalog".

encode(Val) ->
	Val.
