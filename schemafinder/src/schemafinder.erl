-module (schemafinder).
-export ([ start/0, stop/0 ]).
-behaviour (application).
-export ([ start/2, stop/1 ]).

-ifdef (HAVE_APPINSPECT).
-behaviour (appinspect).
-export ([ inspect/0 ]).
-endif.

%-=====================================================================-
%-                                Public                               -
%-=====================================================================-

start () ->
  combonodefinder:start (),
  n54etsbugfix:start (),
  application:start (schemafinder).

stop () ->
  application:stop (schemafinder).


-ifdef (HAVE_APPINSPECT).
%-=====================================================================-
%-                         appinspect callbacks                        -
%-=====================================================================-

inspect () ->
  [ { db_nodes, mnesia:system_info (db_nodes) },
    { running_db_nodes, mnesia:system_info (running_db_nodes) } ].

-endif.

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
  { ok, ForeignKeyBugFix } = application:get_env (schemafinder,
                                                  foreign_key_bugfix),
  { ok, NoTableLoaders } = application:get_env (schemafinder, no_table_loaders),

  application:set_env (mnesia, no_table_loaders, NoTableLoaders),

  case ForeignKeyBugFix of
    true ->
      error_logger:info_msg ("loading foreign key bugfix (true)~n", []),
      load_foreign_key_bugfix ();
    false ->
      ok;
    auto_detect ->
      maybe_load_foreign_key_bugfix ()
  end,

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

%-=====================================================================-
%-                               Private                               -
%-=====================================================================-

have_foreign_key_bug () ->
  { value, { attributes, Attr } } =
     lists:keysearch (attributes, 1, mnesia_frag:module_info ()),  

  case lists:keysearch (vsn, 1, Attr) of    
    { value, { vsn, [ "mnesia_4.3.5" ] } } ->
      true;
    _ ->
      false
  end.

load_foreign_key_bugfix () ->
  ok = code:unstick_dir (code:lib_dir (mnesia)),
  true = code:soft_purge (mnesia_frag),
  case code:lib_dir (schemafinder) of
    { error, bad_name } -> % testing, hopefully
      { module, mnesia_frag } = code:load_file (mnesia_frag);
    Dir ->
      { module, mnesia_frag } = code:load_abs (Dir ++ "/ebin/mnesia_frag")
  end.

maybe_load_foreign_key_bugfix () ->
  case have_foreign_key_bug () of
    true ->
      error_logger:info_msg ("foreign key bug detected, loading fix~n", []),
      load_foreign_key_bugfix ();
    false ->
      error_logger:info_msg ("foreign key bug not detected~n", [])
  end.
