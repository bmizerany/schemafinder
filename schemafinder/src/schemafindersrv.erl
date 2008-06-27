%% @doc Schema finder service.
%%
%% Join a schema defined at other currently known nodes.  Wait for
%% mnesia to incorporate all known (non-hidden) nodes.
%% @hidden
%% @end

-module (schemafindersrv).
-behaviour (gen_server).
-export ([ start_link/2 ]).
-export ([ init/1,
           handle_call/3,
           handle_cast/2,
           handle_info/2,
           terminate/2,
           code_change/3]).

-ifdef (MNESIA_EXT).
-define (if_mnesia_ext (X, Y), X).
-else.
-define (if_mnesia_ext (X, Y), Y).
-endif.

-record (state, {}).

%-=====================================================================-
%-                                Public                               -
%-=====================================================================-

start_link (MaxExtraDbDelay, Group) when is_integer (MaxExtraDbDelay),
                                         MaxExtraDbDelay > 0,
                                         is_atom (Group) ->
  gen_server:start_link ({ local, ?MODULE }, 
                         ?MODULE,
                         [ MaxExtraDbDelay, Group ],
                         []).

%-=====================================================================-
%-                         gen_server callbacks                        -
%-=====================================================================-

%% @hidden

init ([ MaxExtraDbDelay, Group ]) ->
  process_flag (trap_exit, true),

  ok = pg2:join (Group, self ()),

  Nodes = lists:usort ([ node (P) || P <- pg2:get_members (Group) ]),

  Extra = Nodes -- lists:sort (mnesia:system_info (db_nodes)),

  case Extra of
    [] -> ok;
    _ -> { ok, _ } = mnesia:change_config (extra_db_nodes, Extra)
  end,

  case fast_change_table_copy_type (schema, node (), disc_copies) of
    { atomic, ok } -> ok;
    { aborted, { already_exists, schema, _, disc_copies } } -> ok
  end,
  wait_for_extra_db_nodes (Extra, MaxExtraDbDelay),

  { ok, #state{} }.

%% @hidden

handle_call (_Request, _From, State) -> { noreply, State }.

%% @hidden

handle_cast (_Request, State) -> { noreply, State }.

%% @hidden

handle_info (_Msg, State) -> 
  { noreply, State }.

%% @hidden

terminate (_Reason, _State) ->
  ok.

%% @hidden

code_change (_OldVsn, State, _Extra) -> { ok, State }.

%-=====================================================================-
%-                               Private                               -
%-=====================================================================-

fast_change_table_copy_type (TableName, Node, CopyType) ->
  try { lists:member (Node, used_nodes (TableName)),
        lists:member (Node, used_nodes (TableName, CopyType)) } of
    { true, true } ->
      { aborted, { already_exists, TableName, Node, CopyType } };
    { true, false } ->
      mnesia:change_table_copy_type (TableName, Node, CopyType);
    { false, _ } ->
      { aborted, { no_exists, TableName, Node } }
  catch 
    _ : _ ->
      { aborted, { no_exists, TableName } }
  end.

used_nodes (TableName) ->
  lists:usort (used_nodes (TableName, ram_copies) ++
               used_nodes (TableName, disc_copies) ++
               ?if_mnesia_ext (used_nodes (TableName, external_copies),
                               []) ++
               used_nodes (TableName, disc_only_copies)).

used_nodes (TableName, CopyType) ->
  mnesia:table_info (TableName, CopyType).

wait_for_extra_db_nodes (_, 0) -> 
  failed;
wait_for_extra_db_nodes (Nodes, N) when N > 0 ->
  case Nodes -- mnesia:system_info (db_nodes) of
    [] -> ok;
    _ -> receive after 1000 -> ok end, wait_for_extra_db_nodes (Nodes, N - 1)
  end.
