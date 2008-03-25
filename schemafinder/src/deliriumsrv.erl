%% @doc Dementia service.  Periodically prunes expired mnesia nodes.
%% @hidden
%% @end

-module (deliriumsrv).
-export ([ force_prune/0, start_link/2, start_link/3 ]).
-behaviour (gen_cron).
-export ([ init/1,
           handle_call/3,
           handle_cast/2,
           handle_info/2,
           handle_tick/2,
           terminate/2,
           code_change/3 ]).

-include ("delirium.hrl").

-define (is_timeout (X), (((X) =:= infinity) or
                          (is_integer (X) andalso (X > 0)))).

-oldrecord (state).

-record (state, { node_timeout }).
-record (statev2, { node_timeout, load_timeout }).

%-=====================================================================-
%-                                Public                               -
%-=====================================================================-

%% @spec force_prune () -> { ok, pid () } | { error, { prune_underway, pid () } }
%% @doc Force an immediate removal. 
%% The delirium server will periodically remove condemned or timed-out
%% nodes.  This function will force an immediate removal.
%% @end

force_prune () ->
  case gen_cron:force_run (?MODULE) of
    { underway, Pid } -> { error, { prune_underway, Pid } };
    R -> R
  end.

%% @spec start_link (integer (), integer ()) -> Reply
%% @doc Start the delirium server.
%% @end

start_link (CheckInterval, NodeTimeout) ->
  start_link (CheckInterval, NodeTimeout, infinity).

%% @spec start_link (integer (), timeout (), integer ()) -> Reply
%%   where
%%     timeout () = infinity | integer ()
%% @doc Start the delirium server.
%% @end

start_link (CheckInterval, 
            NodeTimeout,
            LoadTimeout) when is_integer (NodeTimeout), NodeTimeout > 0,
                              ?is_timeout (LoadTimeout) ->
  gen_cron:start_link ({ local, ?MODULE }, 
                       ?MODULE, 
                       CheckInterval,
                       [ NodeTimeout, LoadTimeout ],
                       []).

%-=====================================================================-
%-                          gen_cron callbacks                         -
%-=====================================================================-

%% @hidden

init ([ NodeTimeout, LoadTimeout ]) ->
  ensure_delirium_table (LoadTimeout),

  { ok, #statev2{ load_timeout = LoadTimeout, node_timeout = NodeTimeout } }.

%% @hidden

handle_call (_Request, _From, State) -> { noreply, State }.

%% @hidden

handle_cast (_Request, State) -> { noreply, State }.

%% @hidden

handle_info (_Msg, State) -> { noreply, State }.

%% @hidden

handle_tick (_Reason, State) ->
  { atomic, ok } = delirium:heartbeat (),
  expire_old_nodes (State#statev2.node_timeout).

%% @hidden

terminate (_Reason, _State) -> ok.

%% @hidden

code_change (_OldVsn, State = #state{}, _Extra) -> 
  { ok, #statev2{ load_timeout = infinity, 
                  node_timeout = State#state.node_timeout } };
code_change (_OldVsn, State = #statev2{}, _Extra) -> 
  { ok, State }.

%-=====================================================================-
%-                               Private                               -
%-=====================================================================-

bury (Node) ->
  mnesia:sync_transaction 
    (fun () -> mnesia:write (#delirium{ node = Node, status = buried }) end).

ensure_table (TableName, TabDef, LoadTimeout) ->
  case mnesia:create_table (TableName, TabDef) of
    { atomic, ok } -> true;
    { aborted, { already_exists, TableName } } -> false
  end,
  case mnesia:wait_for_tables ([ TableName ], LoadTimeout) of
    ok -> true;
    { timeout, _ } -> yes =:= mnesia:force_load_table (TableName)
  end.

ensure_table_copy (TableName, Node, CopyType) ->
  case mnesia:add_table_copy (TableName, Node, CopyType) of
    { atomic, ok } -> true;
    { aborted, { already_exists, TableName, Node } } -> false
  end.

ensure_delirium_table (LoadTimeout) ->
  ensure_table (delirium, 
                [ { type, set },
                  { disc_copies, mnesia:system_info (running_db_nodes) } ],
                LoadTimeout),
  ensure_table_copy (delirium, node (), disc_copies).

expire_old_nodes (NodeTimeout) ->
  global:set_lock ({ ?MODULE, self () }),

  try
    Now = erlang:now (),

    { atomic, KillMe } = 
      mnesia:sync_transaction 
        (fun () ->
           Nodes = 
             lists:filter 
               (fun (Node) ->
                  case { NodeTimeout, mnesia:read (delirium, Node, write) } of
                    { _, [] } -> 
                      true;
                    { _, [ #delirium{ status = S } ] } when (S =:= dead) or 
                                                            (S =:= buried) ->
                      true;
                    { X, [ #delirium{ status = Y } ] } when (X =:= infinity) or 
                                                            (Y =:= immortal) or
                                                            (Y =:= sanctified) ->
                      false;
                    { Timeout, [ #delirium{ status = Then } ] } ->
                      timer:now_diff (Now, Then) > Timeout
                  end
                end,
                mnesia:system_info (db_nodes) -- 
                mnesia:system_info (running_db_nodes)),
           lists:foreach (fun bury/1, Nodes),
           Nodes
         end),
  
    case KillMe of
      [] ->
        ok;
      _ ->
        { atomic, ok } = mnesia_schema:del_table_copies (schema, KillMe)
    end
  after
    global:del_lock ({ ?MODULE, self () })
  end.
