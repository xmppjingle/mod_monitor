%%-------------------------------------------------------------------
%% File        : mod_monitor.erl
%% Author      : Thiago Camargo <barata7@gmail.com>
%%             : Manuel Rubio <manuel@yuilop.com>
%% Description : Generic Erlang/Mnesia Throttle
%% Provides:
%%   * Throttle Function based on Max Requests for an Interval for
%%     an ID(node)
%%
%% Created : 16 Apr 2010 by Thiago Camargo <barata7@gmail.com>
%% Updated : 21 Dec 2012 by Manuel Rubio <manuel@yuilop.com>
%%-------------------------------------------------------------------
-module(mod_monitor).

-export([init/1, accept/3, soft_accept/3, reset/1, get_node/1]).

-define(WLIST_TABLE, mmwl).

-record(monitor, {id, counter, timestamp}).

-spec init( Whitelist :: list(binary()) ) -> ok.
%@doc Init the monitor. Adds the JIDs to the whitelist.
%@end
init(Whitelist) ->
    application:ensure_all_started(mnesia),
    mnesia:create_table(monitor,
                        [{attributes, record_info(fields, monitor)}]),
    prepare_whitelist(Whitelist).

-spec prepare_whitelist( L :: list(binary()) ) -> ok.
%@doc Prepare the whitelist. Adds the elements to the whitelist.
prepare_whitelist(L) ->
    case ets:info(?WLIST_TABLE) of
        undefined ->
            ets:new(?WLIST_TABLE, [named_table, public]);
        _ ->
            ets:delete_all_objects(?WLIST_TABLE)
    end,
    [ ets:insert(?WLIST_TABLE, {H,allowed}) || H <- L ],
    ok.

-spec is_white( K :: string() ) -> boolean().
%@doc Check if the param is whitelisted. Check if the passed param
%     is in the whitelist.
%@end
is_white(K) ->
    case ets:info(?WLIST_TABLE) of
        undefined ->
            true;
        _ ->
            [{K, allowed}] =:= ets:lookup(?WLIST_TABLE, K)
    end.

-spec accept( Id :: string(), Max :: integer(), Period :: integer() ) -> boolean().
%@doc Check if the packet can be accepted. It depends if ID is whitelisted,
%     and the Max packets can be accepted in the Period seconds. With cumulative counter if limit is exceeded. 
%@end
accept(Id, Max, Period) ->
    case is_white(Id) of
        true ->
            true;
        false ->
            N = get_node(Id),
            Counter = N#monitor.counter+1,
            D = (timer:now_diff(os:timestamp(), N#monitor.timestamp)) / 1000000,
            if 
                D > Period ->
                    NC = case Counter - Max * trunc(D / Period + 1) of
                        C when C < 0 -> 0;
                        C -> C
                    end,
                    mnesia:dirty_write(monitor, N#monitor{counter=NC, timestamp=os:timestamp()}),
                    NC =< Max;
                true ->
                    mnesia:dirty_write(monitor, N#monitor{counter=Counter, timestamp=os:timestamp()}),
                    Counter =< Max
            end
    end.

-spec soft_accept( Id :: string(), Max :: integer(), Period :: integer() ) -> boolean().
%@doc Check if the packet can be accepted. It depends if ID is whitelisted,
%     and the Max packets can be accepted in the Period seconds. If the packets exceeds the limit the counter is not updated.
%@end
soft_accept(Id, Max, Period) ->
    case is_white(Id) of
        true ->
            true;
        false ->
            N = get_node(Id),
            Counter = N#monitor.counter+1,
            D = (timer:now_diff(os:timestamp(), N#monitor.timestamp)) / 1000000,
            NewCounter = if 
                D > Period ->
                    NC = case Counter - Max * trunc(D / Period + 1) of
                        C when C < 0 -> 1;
                        C -> C
                    end,
                    NC;
                true -> 
                    Counter
            end,
            case NewCounter =< Max of
                true ->
                    mnesia:dirty_write(monitor, N#monitor{counter=NewCounter, timestamp=os:timestamp()}),
                    true;
                _ -> 
                    false
            end
    end.

-spec reset( Id :: string() ) -> boolean().
%@doc Resets a counter.
%@end
reset(Id) ->
    mnesia:dirty_write(monitor, #monitor{id=Id, counter=0, timestamp=os:timestamp()}).

-spec get_node( Id :: string() ) -> #monitor{}.
%@doc Get node information about monitor. If the node doesn't exists 
%     will be created.
%@end
get_node(Id) ->
    case catch mnesia:dirty_read(monitor, Id) of
        {'EXIT', _Reason} ->
            add_node(Id);
        [] -> 
            add_node(Id);
        [N|_] -> 
            N
    end.

-spec add_node( Id :: string() ) -> #monitor{}.
%@doc Add a node in the monitor. If the node exists will be reset.
%@end
add_node(Id) ->
    N = #monitor{id=Id, counter=0, timestamp=os:timestamp()},
    mnesia:dirty_write(monitor, N),
    N.