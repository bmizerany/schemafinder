-module (schemafinder).
-export ([ start/0, stop/0 ]).
-behaviour (application).
-export ([ start/2, stop/1 ]).

%-=====================================================================-
%-                                Public                               -
%-=====================================================================-

start () ->
  application:start (schemafinder).

stop () ->
  application:stop (schemafinder).

%-=====================================================================-
%-                        application callbacks                        -
%-=====================================================================-

%% @hidden

start (_Type, _Args) ->
  { ok, ReuseSchema } = application:get_env (schemafinder, reuse_schema),
  { ok, NodeFinder } = application:get_env (schemafinder, node_finder),
  { ok, DiscoverDelay } = application:get_env (schemafinder, 
                                               discover_delay_ms),
  { ok, MaxExtraDbDelay } = application:get_env (schemafinder, 
                                                 max_extra_db_delay_sec),

  { ok, Group } = application:get_env (schemafinder, group),
  MyGroup = list_to_atom ("schemafinder_" ++ atom_to_list (Group)),

  NodeFinder:discover (),
  receive after DiscoverDelay -> ok end,
  global:sync (),
  pg2:create (MyGroup),

  case { mnesia:system_info (use_dir), ReuseSchema } of
    { false, _ } ->
      ok;
    { true, false } ->
      ok = delirium:detach ();
    { true, true } ->
      ok
  end,

  { ok, SoloStartup } = application:get_env (schemafinder, solo_startup),

  true = 
    case delirium:admit () of
      { atomic, ok } -> true;
      { aborted, badrpc } -> SoloStartup
    end,

  Sup = schemafindersup:start_link (MaxExtraDbDelay, MyGroup),
  delirium:sanctify (),
  Sup.

%% @hidden

stop (_State) ->
  { ok, SaveSchema } = application:get_env (schemafinder, save_schema),

  case SaveSchema of
    true ->     
      { atomic, ok } = delirium:immortalize_remote ();
    false ->
      ok = delirium:detach ()
  end.
