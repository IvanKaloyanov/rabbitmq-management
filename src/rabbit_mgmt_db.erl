%%   The contents of this file are subject to the Mozilla Public License
%%   Version 1.1 (the "License"); you may not use this file except in
%%   compliance with the License. You may obtain a copy of the License at
%%   http://www.mozilla.org/MPL/
%%
%%   Software distributed under the License is distributed on an "AS IS"
%%   basis, WITHOUT WARRANTY OF ANY KIND, either express or implied. See the
%%   License for the specific language governing rights and limitations
%%   under the License.
%%
%%   The Original Code is RabbitMQ Management Console.
%%
%%   The Initial Developers of the Original Code are Rabbit Technologies Ltd.
%%
%%   Copyright (C) 2010 Rabbit Technologies Ltd.
%%
%%   All Rights Reserved.
%%
%%   Contributor(s): ______________________________________.
%%
-module(rabbit_mgmt_db).

-include_lib("rabbit_common/include/rabbit.hrl").

-behaviour(gen_event).

-export([start/0]).

-export([get_queues/1, get_connections/0, get_connection/1,
         get_overview/0, get_channels/0]).

-export([group_sum/2]).

-export([pget/2, add/2, rates/5]).

-export([init/1, handle_call/2, handle_event/2, handle_info/2,
         terminate/2, code_change/3]).

-record(state, {tables}).
-define(FINE_STATS_TYPES, [channel_queue_stats, channel_exchange_stats,
                           channel_queue_exchange_stats]).
-define(TABLES, [queue_stats, connection_stats, channel_stats] ++
            ?FINE_STATS_TYPES).

%% TODO can this be got rid of?
-define(FINE_STATS, [ack, deliver, deliver_no_ack, get, get_no_ack, publish]).


%%----------------------------------------------------------------------------

start() ->
    gen_event:add_sup_handler(rabbit_event, ?MODULE, []).

get_queues(Qs) ->
    gen_event:call(rabbit_event, ?MODULE, {get_queues, Qs}, infinity).

get_connections() ->
    gen_event:call(rabbit_event, ?MODULE, get_connections, infinity).

get_connection(Name) ->
    gen_event:call(rabbit_event, ?MODULE, {get_connection, Name}, infinity).

get_channels() ->
    gen_event:call(rabbit_event, ?MODULE, get_channels, infinity).

get_overview() ->
    gen_event:call(rabbit_event, ?MODULE, get_overview, infinity).

%%----------------------------------------------------------------------------

pget(Key, List) ->
    pget(Key, List, unknown).

pget(Key, List, Default) ->
    proplists:get_value(Key, List, Default).

id(Pid) when is_pid(Pid) -> rabbit_mgmt_format:pid(Pid);
id(List) -> rabbit_mgmt_format:pid(pget(pid, List)).

add(unknown, _) -> unknown;
add(_, unknown) -> unknown;
add(A, B)       -> A + B.

lookup_element(Table, Key) ->
    lookup_element(Table, Key, 2).

lookup_element(Table, Key, Pos) ->
    try ets:lookup_element(Table, Key, Pos)
    catch error:badarg -> []
    end.

name_to_id(Table, Name) ->
    case ets:match(Table, {{'$1', create}, '_', Name}) of
        []     -> none;
        [[Id]] -> Id
    end.

result_or_error([]) -> error;
result_or_error(S)  -> S.

%% TODO until we do rates properly (i.e. looking at a time series)
%% we have the problem that an object which stops emitting events will look
%% like its rate has stayed up. This might make time series more important.

rates(Stats, Timestamp, OldStats, OldTimestamp, Keys) ->
    Stats ++ lists:filter(
               fun (unknown) -> false;
                   (_)       -> true
               end,
               [rate(Stats, Timestamp, OldStats, OldTimestamp, Key) ||
                   Key <- Keys]).

rate(Stats, Timestamp, OldStats, OldTimestamp, Key) ->
    case OldTimestamp == [] orelse not proplists:is_defined(Key, OldStats) of
        true ->
            unknown;
        _ ->
            Diff = pget(Key, Stats) - pget(Key, OldStats),
            {list_to_atom(atom_to_list(Key) ++ "_rate"),
             Diff / (timer:now_diff(Timestamp, OldTimestamp) / 1000000)}
    end.

sum(Table, Keys) ->
    lists:foldl(fun (Stats, Acc) ->
                        [{Key, Val + pget(Key, Stats, 0)} || {Key, Val} <- Acc]
                end,
                [{Key, 0} || Key <- Keys],
                [Value || {_Key, Value, _TS} <- ets:tab2list(Table)]).

group_sum(GroupBy, List) ->
    lists:foldl(fun ({Ids, New}, Acc) ->
                        Id = {GroupBy, pget(GroupBy, Ids)},
                        dict:update(Id, fun(Cur) -> gs_update(Cur, New) end,
                                    New, Acc)
                end,
                dict:new(),
                [I || I <- List]).

gs_update(Cur, New) ->
    [{Key, Val + pget(Key, Cur, 0)} || {Key, Val} <- New].

%%----------------------------------------------------------------------------

augment(Items, Funs, Tables) ->
    Augmentations = [augment(K, Items, Fun, Tables) || {K, Fun} <- Funs],
    [A || A <- Augmentations, A =/= unknown] ++ Items.

augment(K, Items, Fun, Tables) ->
    Id = pget(K, Items),
    case Id of
        unknown -> unknown;
        _       -> {list_to_atom(atom_to_list(K) ++ "_details"),
                    Fun(Id, Tables)}
    end.

%% augment_channel_pid(Pid, Tables) ->
%%     Ch = lookup_element(
%%            orddict:fetch(channel_stats, Tables),
%%            {Pid, create}),
%%     Conn = lookup_element(
%%              orddict:fetch(connection_stats, Tables),
%%              {pget(connection, Ch), create}),
%%     [{number, pget(number, Ch)},
%%      {connection_name, pget(name, Conn)},
%%      {peer_address, pget(peer_address, Conn)},
%%      {peer_port, pget(peer_port, Conn)}].

augment_connection_pid(Pid, Tables) ->
    Conn = lookup_element(
             orddict:fetch(connection_stats, Tables),
             {Pid, create}),
    [{peer_address, pget(peer_address, Conn)},
     {peer_port, pget(peer_port, Conn)},
     {name, pget(name, Conn)}].

%% augment_queue_pid(Pid, Tables) ->
%%     Q = lookup_element(
%%           orddict:fetch(queue_stats, Tables), NB  this won't work any more
%%           {Pid, create}),
%%     [{name, pget(name, Q)},
%%      {vhost, pget(vhost, Q)}].

augment_msg_stats(Stats, Tables) ->
    [augment_msg_stats_items(Props, Tables) || Props <- Stats].

augment_msg_stats_items(Props, Tables) ->
    augment(Props, [{connection, fun augment_connection_pid/2}], Tables).

%%----------------------------------------------------------------------------

%% TODO some sort of generalised query mechanism for the coarse stats?

init([]) ->
    {ok, #state{tables =
                    orddict:from_list(
                      [{Key, ets:new(anon, [private])} || Key <- ?TABLES])}}.

handle_call({get_queues, Qs0}, State = #state{tables = Tables}) ->
    Table = orddict:fetch(queue_stats, Tables),
    Qs1 = [queue_to_list(Q) || Q <- Qs0],
    Qs2 = merge_created_stats(Qs1, Table),
    Qs3 = [augment(Q, [{owner_pid, fun augment_connection_pid/2}],
                   Tables) || Q <- Qs2],
    {ok, Qs3, State};

handle_call(get_connections, State = #state{tables = Tables}) ->
    Table = orddict:fetch(connection_stats, Tables),
    {ok, merge_created_stats(Table), State};

handle_call({get_connection, Name}, State = #state{tables = Tables}) ->
    Table = orddict:fetch(connection_stats, Tables),
    Id = name_to_id(Table, Name),
    {ok, result_or_error(lookup_element(Table, {Id, create}) ++
                             lookup_element(Table, {Id, stats})), State};

handle_call(get_channels, State = #state{tables = Tables}) ->
    Table = orddict:fetch(channel_stats, Tables),
    Stats = merge_created_stats(Table),
    FineQ = get_fine_stats(channel_queue_stats, channel, Tables),
    FineX = get_fine_stats(channel_exchange_stats, channel, Tables),
    {ok, augment_msg_stats(merge_fine_stats(Stats, [FineQ, FineX]), Tables),
     State};

handle_call(get_overview, State = #state{tables = Tables}) ->
    Table = orddict:fetch(connection_stats, Tables),
    {ok, sum(Table, [recv_oct, send_oct, recv_oct_rate, send_oct_rate]), State};

handle_call(_Request, State) ->
    {ok, not_understood, State}.

handle_event(#event{type = queue_stats, props = Stats, timestamp = Timestamp},
             State) ->
    handle_stats(
      queue_stats, Stats, Timestamp,
      [{fun rabbit_mgmt_format:table/1,[backing_queue_status]}],
      [], State);

handle_event(Event = #event{type = queue_deleted}, State) ->
    handle_deleted(queue_stats, Event, State);

handle_event(#event{type = connection_created, props = Stats}, State) ->
    Name = rabbit_mgmt_format:print(
             "~s:~w",
             [rabbit_mgmt_format:ip(pget(peer_address, Stats)),
              pget(peer_port, Stats)]),
    handle_created(
      connection_stats, [{name, Name}|Stats],
      [{fun rabbit_mgmt_format:ip/1,       [address, peer_address]},
       {fun rabbit_mgmt_format:pid/1,      [pid]},
       {fun rabbit_mgmt_format:protocol/1, [protocol]},
       {fun rabbit_mgmt_format:table/1,    [client_properties]}], State);

handle_event(#event{type = connection_stats, props = Stats,
                    timestamp = Timestamp},
             State) ->
    handle_stats(connection_stats, Stats, Timestamp, [], [recv_oct, send_oct],
                 State);

handle_event(Event = #event{type = connection_closed}, State) ->
    handle_deleted(connection_stats, Event, State);

handle_event(#event{type = channel_created, props = Stats}, State) ->
    handle_created(
      channel_stats, Stats,
      [{fun rabbit_mgmt_format:pid/1, [pid, connection]}], State);

handle_event(#event{type = channel_stats, props = Stats, timestamp = Timestamp},
             State) ->
    handle_stats(channel_stats, Stats, Timestamp, [], [], State),
    [handle_fine_stats(Type, Stats, Timestamp, State) ||
        Type <- ?FINE_STATS_TYPES],
    {ok, State};

handle_event(Event = #event{type = channel_closed,
                            props = [{pid, Pid}]}, State) ->
    handle_deleted(channel_stats, Event, State),
    [delete_fine_stats(Type, id(Pid), State) ||
        Type <- ?FINE_STATS_TYPES],
    {ok, State};

handle_event(_Event, State) ->
%%    io:format("Got event ~p~n", [Event]),
    {ok, State}.

handle_info(_Info, State) ->
    {ok, State}.

terminate(_Arg, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%----------------------------------------------------------------------------

handle_created(TName, Stats, Funs, State = #state{tables = Tables}) ->
    Formatted = rabbit_mgmt_format:format(Stats, Funs),
    ets:insert(orddict:fetch(TName, Tables), {{id(Stats), create},
                                              Formatted,
                                              pget(name, Stats)}),
    {ok, State}.

handle_stats(TName, Stats0, Timestamp, Funs,
             RatesKeys, State = #state{tables = Tables}) ->
    Stats = lists:foldl(
              fun (K, StatsAcc) -> proplists:delete(K, StatsAcc) end,
              Stats0, ?FINE_STATS_TYPES),
    Table = orddict:fetch(TName, Tables),
    Id = {id(Stats), stats},
    OldStats = lookup_element(Table, Id),
    OldTimestamp = lookup_element(Table, Id, 3),
    Stats1 = rates(Stats, Timestamp, OldStats, OldTimestamp, RatesKeys),
    ets:insert(Table,
               {Id,
                proplists:delete(pid,
                                 rabbit_mgmt_format:format(Stats1, Funs)),
                Timestamp}),
    {ok, State}.

handle_deleted(TName, #event{props = [{pid, Pid}]},
               State = #state{tables = Tables}) ->
    Table = orddict:fetch(TName, Tables),
    ets:delete(Table, {id(Pid), create}),
    ets:delete(Table, {id(Pid), stats}),
    {ok, State}.

handle_fine_stats(Type, Props, Timestamp, State = #state{tables = Tables}) ->
    ChPid = id(Props),
    Table = orddict:fetch(Type, Tables),
    IdsStatsTS = [{Ids,
                   Stats,
                   lookup_element(Table, fine_stats_key(ChPid, Ids)),
                   lookup_element(Table, fine_stats_key(ChPid, Ids), 3)} ||
                     {Ids, Stats} <- pget(Type, Props)],
    delete_fine_stats(Type, ChPid, State),
    [handle_fine_stat(ChPid, Ids, Stats, Timestamp,
                      OldStats, OldTimestamp, Table) ||
        {Ids, Stats, OldStats, OldTimestamp} <- IdsStatsTS].

handle_fine_stat(ChPid, Ids, Stats, Timestamp,
                 OldStats, OldTimestamp,
                 Table) ->
    Id = fine_stats_key(ChPid, Ids),
    Res = rates(Stats, Timestamp, OldStats, OldTimestamp, ?FINE_STATS),
    ets:insert(Table, {Id, Res, Timestamp}).

delete_fine_stats(Type, ChPid, #state{tables = Tables}) ->
    Table = orddict:fetch(Type, Tables),
    ets:match_delete(Table, {{ChPid, '_'}, '_', '_'}),
    ets:match_delete(Table, {{ChPid, '_', '_'}, '_', '_'}).

fine_stats_key(ChPid, {QPid, X})              -> {ChPid, id(QPid), X};
fine_stats_key(ChPid, QPid) when is_pid(QPid) -> {ChPid, id(QPid)};
fine_stats_key(ChPid, X)                      -> {ChPid, X}.

merge_created_stats(Table) ->
    merge_created_stats(
      [Facts || {{_, create}, Facts, _Name} <- ets:tab2list(Table)],
      Table).

merge_created_stats(In, Table) ->
    [Facts ++ lookup_element(Table, {pget(pid, Facts), stats}) || Facts <- In].

get_fine_stats(Type, GroupBy, Tables) ->
    Table = orddict:fetch(Type, Tables),
    All = [{format_id(Id), Stats} ||
              {Id, Stats, _Timestamp} <- ets:tab2list(Table)],
    group_sum(GroupBy, All).

format_id({ChPid, #resource{name=XName, virtual_host=XVhost}}) ->
    [{channel, ChPid}, {exchange, [{name, XName}, {vhost, XVhost}]}];
format_id({ChPid, QPid}) ->
    [{channel, ChPid}, {queue, QPid}];
format_id({ChPid, QPid, #resource{name=XName, virtual_host=XVhost}}) ->
    [{channel, ChPid}, {queue, QPid},
     {exchange, [{name, XName}, {vhost, XVhost}]}].

merge_fine_stats(Stats, []) ->
    Stats;
merge_fine_stats(Stats, [Dict|Dicts]) ->
    merge_fine_stats(
      [merge_fine_stats0(Props, Dict) || Props <- Stats],
      Dicts).

merge_fine_stats0(Props, Dict) ->
    Id = pget(pid, Props),
    case dict:find({channel, Id}, Dict) of
        {ok, Stats} ->
            Stats0 = pget(message_stats, Props, []),
            [{message_stats, Stats0 ++ Stats}|
             proplists:delete(message_stats, Props)];
        error -> Props
    end.

queue_to_list(#amqqueue{name = Name, durable = Durable,
                        auto_delete = AutoDelete,
                        exclusive_owner = ExclusiveOwner,
                        arguments = Arguments,
                        pid = Pid }) ->
    rabbit_mgmt_format:format(
      [{durable, Durable},
       {name, Name},
       {auto_delete, AutoDelete},
       {owner_pid, ExclusiveOwner},
       {arguments, Arguments},
       {pid, Pid}],
      [{fun rabbit_mgmt_format:pid/1,      [pid, owner_pid]},
       {fun rabbit_mgmt_format:resource/1, [name]},
       {fun rabbit_mgmt_format:table/1,    [arguments]}]).
