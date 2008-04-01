-module (delirium).
-export ([ start/2,
           stop/1 ]).
-export ([ admit/0,
           condemn/0,
           condemn/1,
           detach/0,
           force_prune/0,
           heartbeat/0,
           heartbeat/1,
           immortalize/0,
           immortalize/1,
           immortalize_remote/0,
           immortalize_remote/1,
           is_detached/1,
           sanctify/0,
           sanctify/1 ]).

-ifdef (HAVE_APPINSPECT).
-behaviour (appinspect).
-export ([ inspect/0 ]).
-endif.

-include ("delirium.hrl").

%-=====================================================================-
%-                                Public                               -
%-=====================================================================-

%% @spec admit () -> { atomic, ok } | { aborted, Reason }
%% @doc Query for the current node to be admitted to the global schema.  If this
%% function fails then the current node must not join the global schema.
%% mnesia should not be started until after this routine says ok.
%% @end

admit () ->
  case remote_heartbeat (mnesia:system_info (db_nodes)) of
    failed ->
      case application:get_env (schemafinder, load_timeout_ms) of
        { ok, Val } when is_integer (Val) ->
          timer:sleep (Val),
          remote_heartbeat (mnesia:system_info (db_nodes));
        _ ->
          failed
      end;
    R ->
      R
  end.

%% @spec condemn () -> { atomic, ok } | { aborted, Reason }
%% @equiv condemn (node ())
%% @end

condemn () ->
  condemn (node ()).

%% @spec condemn (atom ()) -> { atomic, ok } | { aborted, Reason }
%% @doc Mark a node as dead.  It will be removed on the next delirium pass.
%% @end

condemn (Node) ->
  mnesia:sync_transaction 
    (fun () -> 
       case mnesia:read (delirium, Node, write) of
         [] ->
           mnesia:write (#delirium{ node = Node, status = dead });
         [ #delirium{ status = Status } ] when Status =/= buried ->
           mnesia:write (#delirium{ node = Node, status = dead })
       end
     end).

%% @spec detach () -> ok | exit (Reason)
%% @hidden
%% @doc Detach the current node from the global schema.  This involves 
%% stopping mnesia, having a remote node remove this node from the schema,
%% removing the mnesia directory, and sanctifying the node.
%% This function requires that mnesia is not running.

detach () ->
  no = mnesia:system_info (is_running),
  NodeList = mnesia:system_info (db_nodes),
  case is_remotely_detached (NodeList) of
    { ok, true } -> ok;
    { ok, false } ->
      ok = remote_detach (NodeList)
  end,
  ok = maybe_remove_schema_directory (),
  { atomic, ok } = remote_sanctify (NodeList),
  ok.

%% @spec force_prune () -> { ok, pid () } | { error, { prune_underway, pid () } }
%% @doc Force an immediate removal. 
%% The delirium server will periodically remove condemned or timed-out
%% nodes.  This function will force an immediate removal.
%% @end

force_prune () ->
  deliriumsrv:force_prune ().

%% @spec heartbeat () -> { atomic, ok } | { aborted, Reason }
%% @equiv heartbeat (node ())
%% @end

heartbeat () ->
  heartbeat (node ()).

%% @spec heartbeat (atom ()) -> { atomic, ok } | { aborted, Reason }
%% @doc Update the timestamp associated with a node, in order to avoid
%% automatic removal.
%% @end

heartbeat (Node) ->
  Now = now (),
  mnesia:sync_transaction 
    (fun () -> 
       case mnesia:read (delirium, Node, write) of
         [] ->
           mnesia:write (#delirium{ node = Node, status = Now });
         [ #delirium{ status = Status } ] when Status =/= buried ->
           mnesia:write (#delirium{ node = Node, status = Now })
       end
     end).

%% @spec immortalize () -> { atomic, ok } | { aborted, Reason }
%% @equiv immortalize (node ())
%% @end

immortalize () ->
  immortalize (node ()).

%% @spec immortalize (atom ()) -> { atomic, ok } | { aborted, Reason }
%% @doc Mark a node as immortal, so that it will not be removed until
%% heartbeat () or condemn () are called on it.  This is useful for when
%% a node is being taken down for planned but extensive maintainenance.
%% @end

immortalize (Node) ->
  mnesia:sync_transaction 
    (fun () -> 
       case mnesia:read (delirium, Node, write) of
         [] ->
           mnesia:write (#delirium{ node = Node, status = immortal });
         [ #delirium{ status = Status } ] when Status =/= buried ->
           mnesia:write (#delirium{ node = Node, status = immortal })
       end
     end).

%% @spec immortalize_remote () -> { atomic, ok } | { aborted, Reason }
%% @equiv immortalize_remote (node ())
%% @end

immortalize_remote () ->
  immortalize_remote (node ()).

%% @spec immortalize_remote (atom ()) -> { atomic, ok } | { aborted, Reason }
%% @doc Mark a node as immortal via another node.  Does not require
%% mnesia to be started.
%% @see immortalize/1
%% @end

immortalize_remote (Node) ->
  NodeList = mnesia:system_info (db_nodes),
  case remote (delirium, immortalize, [ Node ], NodeList) of
    failed -> { aborted, badrpc };
    trivial -> { atomic, ok };
    R -> R
  end.

%% @hidden

is_detached (Node) ->
  not lists:member (Node, mnesia:system_info (db_nodes)).

%% @spec sanctify () -> { atomic, ok } | { aborted, Reason }
%% @equiv sanctify (node ())
%% @end

sanctify () ->
  sanctify (node ()).

%% @spec sanctify (atom ()) -> { atomic, ok } | { aborted, Reason }
%% @doc Mark a node as sanctified. It will be allowed to join the schema
%% again.  This can only be called on buried nodes.
%% @end

sanctify (Node) ->
  mnesia:sync_transaction 
    (fun () -> 
       case mnesia:read (delirium, Node, write) of
         [] ->
           mnesia:write (#delirium{ node = Node, status = sanctified });
         [ #delirium{ status = Status } ] when Status =:= buried ->
           mnesia:write (#delirium{ node = Node, status = sanctified })
       end
     end).

-ifdef (HAVE_APPINSPECT).
%-=====================================================================-
%-                         appinspect callbacks                        -
%-=====================================================================-

inspect () ->
  [ { delirium,
      lists:flatten ([ mnesia:dirty_read ({ delirium, K })
		       || K <- mnesia:dirty_all_keys (delirium) ]) } ].  
-endif.

%-=====================================================================-
%-                        application callbacks                        -
%-=====================================================================-

%% @hidden

start (_Type, _Args) ->
  code:ensure_loaded (mnesia_schema),
  case erlang:function_exported (mnesia_schema, del_table_copies, 2) of
    true -> ok;
    false ->
      ok = code:unstick_dir (code:lib_dir (mnesia)),
      true = code:soft_purge (mnesia_dumper),
      true = code:soft_purge (mnesia_schema),
      case code:lib_dir (schemafinder) of
        { error, bad_name } -> % testing, hopefully
          { module, mnesia_dumper } = code:load_file (mnesia_dumper),
          { module, mnesia_schema } = code:load_file (mnesia_schema);
        Dir ->
          { module, mnesia_dumper } = 
            code:load_abs (Dir ++ "/ebin/mnesia_dumper"),
          { module, mnesia_schema } =
            code:load_abs (Dir ++ "/ebin/mnesia_schema")
      end,
      true = erlang:function_exported (mnesia_schema, del_table_copies, 2)
  end,

  { ok, CheckInterval } = application:get_env (schemafinder, check_interval_secs),
  { ok, NodeTimeout } = application:get_env (schemafinder, node_timeout_secs),
  { ok, LoadTimeout } = application:get_env (schemafinder, load_timeout_ms),

  deliriumsup:start_link (1000 * CheckInterval, 
                          1000000 * NodeTimeout,
                          LoadTimeout).

%% @hidden

stop (_State) ->
  ok.

%-=====================================================================-
%-                               Private                               -
%-=====================================================================-

is_remotely_detached (NodeList) ->
  case remote (delirium, is_detached, [ node () ], NodeList) of
    failed -> failed;
    trivial -> { ok, true };
    R -> { ok, R }
  end.

maybe_remove_schema_directory () ->
  Directory = mnesia:system_info (directory),
  Command = "rm -rf '" ++ shell_escape (Directory) ++ "'",
  os:cmd (Command),
  { error, enoent } = file:read_file_info (Directory),
  ok.

remote_condemn (NodeList) ->
  case remote (delirium, condemn, [ node () ], NodeList) of
    failed -> failed;
    trivial -> { atomic, ok };
    R -> R
  end.

remote_detach (NodeList) ->
  { atomic, ok } = remote_condemn (NodeList),
  case remote_force_prune (NodeList) of
    { ok, Pid } ->
      MRef = erlang:monitor (process, Pid),
      receive
        { 'DOWN', MRef, _, _, _ } -> ok
      end;
    { error, { prune_underway, Pid } } ->
      MRef = erlang:monitor (process, Pid),
      receive
        { 'DOWN', MRef, _, _, _ } -> ok
      end;
    ok ->
      ok
  end,
  { ok, true } = is_remotely_detached (NodeList),
  ok.

remote_force_prune (NodeList) ->
  case remote (delirium, force_prune, [], NodeList) of
    failed -> failed;
    trivial -> ok;
    E = { error, { prune_underway, _ } } -> E;
    R = { ok, _ } -> R
  end.

remote_heartbeat (NodeList) ->
  case remote (delirium, heartbeat, [ node () ], NodeList) of
    failed -> { aborted, badrpc };
    trivial -> { atomic, ok };
    R -> R
  end.

remote (_, _, _, [ Node ]) when Node =:= node () ->
  trivial;
remote (Mod, Func, Args, L) ->
  remote_nontrivial (Mod, Func, Args, L).

remote_nontrivial (_, _, _, []) ->
  failed;
remote_nontrivial (Mod, Func, Args, [ Node | Rest ]) when Node =:= node () ->
  remote_nontrivial (Mod, Func, Args, Rest);
remote_nontrivial (Mod, Func, Args, [ Node | Rest ]) ->
  case rpc:call (Node, Mod, Func, Args) of
    { badrpc, _ } -> 
      remote_nontrivial (Mod, Func, Args, Rest);
    { aborted, { node_not_running, Node } } -> 
      remote_nontrivial (Mod, Func, Args, Rest);
    { aborted, { no_exists, delirium } } ->
      remote_nontrivial (Mod, Func, Args, Rest);
    R -> 
      R
  end.

remote_sanctify (NodeList) ->
  case remote (delirium, sanctify, [ node () ], NodeList) of
    failed -> { aborted, badrpc };
    trivial -> { atomic, ok };
    R -> R
  end.

shell_escape (String) -> shell_escape (String, []).

shell_escape ([], Acc) -> lists:reverse (Acc);
shell_escape ([ $' | T ], Acc) -> shell_escape (T, [ $', $\\ | Acc ]);
shell_escape ([ $\\ | T ], Acc) -> shell_escape (T, [ $\\, $\\ | Acc ]);
shell_escape ([ H | T ], Acc) -> shell_escape (T, [ H | Acc ]).
