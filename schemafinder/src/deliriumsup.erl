%% @hidden

-module (deliriumsup).
-behaviour (supervisor).

-export ([ start_link/2, start_link/3, init/1 ]).

%-=====================================================================-
%-                                Public                               -
%-=====================================================================-

start_link (CheckInterval, NodeTimeout) ->
  start_link (CheckInterval, NodeTimeout, infinity).
start_link (CheckInterval, NodeTimeout, LoadTimeout) ->
  supervisor:start_link (?MODULE,
                         [ CheckInterval, NodeTimeout, LoadTimeout ]).

%-=====================================================================-
%-                         supervisor callbacks                        -
%-=====================================================================-

init ([ CheckInterval, NodeTimeout ]) ->
  init ([ CheckInterval, NodeTimeout, infinity ]);
init ([ CheckInterval, NodeTimeout, LoadTimeout ]) ->
  { ok,
    { { one_for_one, 3, 10 },
      [ { deliriumsrv,
          { deliriumsrv, start_link, [ CheckInterval, 
                                       NodeTimeout,
                                       LoadTimeout ] },
          permanent,
          5000,
          worker,
          [ deliriumsrv ]
        }
      ]
    }
  }.
