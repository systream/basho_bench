%% -------------------------------------------------------------------
%%
%% basho_bench: Benchmarking Suite
%%
%% Copyright (c) 2009-2015 Basho Techonologies
%%
%% This file is provided to you under the Apache License,
%% Version 2.0 (the "License"); you may not use this file
%% except in compliance with the License.  You may obtain
%% a copy of the License at
%%
%%   http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing,
%% software distributed under the License is distributed on an
%% "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
%% KIND, either express or implied.  See the License for the
%% specific language governing permissions and limitations
%% under the License.
%%
%% -------------------------------------------------------------------
%% @doc copy of the basho_bench_driver_riakclient. Uses the internal
%% node client for dt sets (for comparision to basho_bench_driver_bigset)
%% @end

-module(basho_bench_driver_riakclient_sets).

-export([new/1,
         run/4]).

-include("basho_bench.hrl").

-record(state, { client,
                 bucket,
                 last_key=undefined,
                 remove_set, %% The set name to perform a remove on
                 remove_ctx, %% The context of a get from `remove_set'
                 remove_value, %% a value from a get to `remove_set'
                 batch_size %% in batch inserts, how many at once
               }).

%% ====================================================================
%% API
%% ====================================================================

new(Id) ->
    %% Make sure the path is setup such that we can get at riak_client
    case code:which(bigset_client) of
        non_existing ->
            ?FAIL_MSG("~s requires bigset_client module to be available on code path.\n",
                      [?MODULE]);
        _ ->
            ok
    end,

    Nodes   = basho_bench_config:get(riakclient_nodes),
    Cookie  = basho_bench_config:get(riak_cookie, 'riak'),
    MyNode  = basho_bench_config:get(riakclient_mynode, [basho_bench, longnames]),
    Bucket  = basho_bench_config:get(riakclient_bucket, {<<"sets">>, <<"test">>}),
    BatchSize = basho_bench_config:get(riakclient_sets_batchsize, 1000),

    %% Try to spin up net_kernel
    case net_kernel:start(MyNode) of
        {ok, _} ->
            ?INFO("Net kernel started as ~p\n", [node()]);
        {error, {already_started, _}} ->
            ok;
        {error, Reason} ->
            ?FAIL_MSG("Failed to start net_kernel for ~p: ~p\n", [?MODULE, Reason])
    end,

    %% Initialize cookie for each of the nodes
    [true = erlang:set_cookie(N, Cookie) || N <- Nodes],

    %% Try to ping each of the nodes
    ping_each(Nodes),

    %% Choose the node using our ID as a modulus
    TargetNode = lists:nth((Id rem length(Nodes)+1), Nodes),
    ?INFO("Using target node ~p for worker ~p\n", [TargetNode, Id]),

    case riak:client_connect(TargetNode) of
        {error, Reason2} ->
            ?FAIL_MSG("Failed get a bigset_client to ~p: ~p\n", [TargetNode, Reason2]);
        {ok, Client} ->
            {ok, #state { client = Client, bucket=Bucket, batch_size=BatchSize }}
    end.

run(read, KeyGen, _ValueGen, State) ->
    Key = KeyGen(),
    #state{client=C, bucket=B} = State,
    case C:get(B, Key, []) of
        {ok, Res} ->
            {{Ctx, Values}, _Stats} = riak_kv_crdt:value(Res, riak_dt_orswot),
            RemoveVal = random_element(Values),
            %% Store the latest Ctx/State for a remove
            {ok, State#state{remove_set=Key, remove_ctx=Ctx, remove_value=RemoveVal}};
        {error, notfound} ->
            {ok, State};
        {error, Reason} ->
            {error, Reason, State}
    end;
run(insert, KeyGen, ValueGen, State) ->
    #state{client=C, bucket=B} = State,
    Member = ValueGen(),
    Set = KeyGen(),
    O = riak_kv_crdt:new(B, Set, riak_dt_orswot),
    Opp = riak_kv_crdt:operation(riak_dt_orswot, {add, Member}, undefined),
    Options1 = [{crdt_op, Opp}],
    case C:put(O, Options1) of
        ok ->
            {ok, State};
        {error, Reason} ->
            {error, Reason, State}
    end;
run(insert_pl, KeyGen, ValueGen, State) ->
    #state{client=C, bucket=B, last_key=LastKey0} = State,
    {Member, LastKey} = try
                            {ValueGen(), LastKey0}
                        catch
                            throw:{stop, empty_keygen} ->
                                ?DEBUG("Empty keygen, reset~n", []),
                                basho_bench_keygen:reset_sequential_int_state(),
                                {ValueGen(), undefined}
                        end,

    Set = case LastKey of
              undefined ->
                  Key = KeyGen(),
                  ?DEBUG("New set ~p~n", [Key]),
                  Key;
              Bin when is_binary(Bin) ->
                  Bin
          end,
    State2 = State#state{last_key=Set},

    O = riak_kv_crdt:new(B, Set, riak_dt_orswot),
    Opp = riak_kv_crdt:operation(riak_dt_orswot, {add, Member}, undefined),
    Options1 = [{crdt_op, Opp}],
    case C:put(O, Options1) of
        ok ->
            {ok, State2};
        {error, Reason} ->
            {error, Reason, State2}
    end;
run(batch_insert, KeyGen, ValueGen, State) ->
    #state{client=C, bucket=B, batch_size=BatchSize, last_key=LastKey0} = State,

    {Set, Members} = case {LastKey0, gen_members(BatchSize, ValueGen)} of
                         {_, []} ->
                             %% Exhausted value gen, new key
                             Key = KeyGen(),
                             ?DEBUG("New set ~p~n", [Key]),
                             basho_bench_keygen:reset_sequential_int_state(),
                             {Key, gen_members(BatchSize, ValueGen)};
                         {undefined, List} ->
                             %% We have no active set, so generate a
                             %% key. First run maybe
                             Key = KeyGen(),
                             ?DEBUG("New set ~p~n", [Key]),
                             {Key, List};
                         Else ->
                             Else
                     end,

    State2 = State#state{last_key=Set},

    O = riak_kv_crdt:new(B, Set, riak_dt_orswot),
    Opp = riak_kv_crdt:operation(riak_dt_orswot, {add_all, Members}, undefined),
    Options1 = [{crdt_op, Opp}],
    case C:put(O, Options1) of
        ok ->
            {ok, State2};
        {error, Reason} ->
            {error, Reason, State2}
    end;
run(remove, _KeyGen, _ValueGen, State) ->
    #state{client=C, remove_set=Key, remove_ctx=Ctx, remove_value=RemoveVal, bucket=B} = State,
    O = riak_kv_crdt:new(B, Key, riak_dt_orswot),
    Opp = riak_kv_crdt:operation(riak_dt_orswot, {remove, RemoveVal}, Ctx),
    Options1 = [{crdt_op, Opp}],
    case C:put(O, Options1) of
        ok ->
            {ok, State};
        {error, notfound} ->
            {ok, State};
        {error, Reason} ->
            {error, Reason, State}
    end.



%% ====================================================================
%% Internal functions
%% ====================================================================

%% @private generate as many elements as we can from the valgen, if it
%% exhausts, return the results we did get.
gen_members(BatchSize, ValueGen) ->
    accumulate_members(BatchSize, ValueGen, []).

%% @private generate as many elements as we can from the valgen, if it
%% exhausts, return the results we did get.
accumulate_members(0, _ValueGen, Acc) ->
    lists:reverse(Acc);
accumulate_members(BS, Gen, Acc) ->
    try
        accumulate_members(BS-1, Gen, [Gen() | Acc])
    catch throw:{stop, empty_keygen} ->
            ?DEBUG("ValGen exhausted~n", []),
            lists:reverse(Acc)
    end.

random_element(Vals) ->
    Nth = crypto:rand_uniform(1, length(Vals)),
    lists:nth(Nth, Vals).

ping_each([]) ->
    ok;
ping_each([Node | Rest]) ->
    case net_adm:ping(Node) of
        pong ->
            ping_each(Rest);
        pang ->
            ?FAIL_MSG("Failed to ping node ~p\n", [Node])
    end.
