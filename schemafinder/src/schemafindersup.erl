%% @hidden

-module (schemafindersup).
-behaviour (supervisor).

-export ([ start_link/2, init/1 ]).

%-=====================================================================-
%-                                Public                               -
%-=====================================================================-

start_link (MaxExtraDbDelay, Group) ->
  supervisor:start_link (?MODULE, [ MaxExtraDbDelay, Group ]).

init ([ MaxExtraDbDelay, Group ]) ->
  { ok,
    { { one_for_one, 3, 10 },
        % mnesia
      [ { mnesia_sup,
          { mnesia_sup, start, [] },
          permanent,
          infinity,
          supervisor,
          [ mnesia_sup ] 
        },
        % schemafinder
        { schemafindersrv,
          { schemafindersrv, 
            start_link,
            [ MaxExtraDbDelay, Group ] },
          transient,
          10000,
          worker,
          [ schemafindersrv ]
        },
        % delirium
        { delirium,
          { delirium, start, [ void, void ] },
          permanent,
          infinity,
          supervisor,
          [ deliriumsup ] 
        } 
      ]
    }
  }.
