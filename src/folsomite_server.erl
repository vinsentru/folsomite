%% Copyright (c) 2012 Campanja AB
%%
%% Licensed under the Apache License, Version 2.0 (the "License");
%% you may not use this file except in compliance with the License.
%% A copy of the license is included in the file LICENSE.
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License.

%%% periodically dump reports of folsom metrics to graphite
-module(folsomite_server).
-behaviour(gen_server).

%% management api
-export([start_link/0, finalize/0]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         code_change/3, terminate/2]).


-define(APP, folsomite).
-define(TIMER_MSG, '#flush').

-record(state, {flush_interval :: integer(),
                tags           :: list(atom()),
                node_key       :: string(),
                node_prefix    :: string(),
                timer_ref      :: reference()}).


%% management api
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, no_arg, []).

finalize() ->
    gen_server:call(?MODULE, finalize).

%% gen_server callbacks
init(no_arg) ->
    process_flag(trap_exit, true),
    FlushInterval = get_env(flush_interval),
    Tags = [folsomite|folsomite_zeta:get_tags()],
    Ref = erlang:start_timer(FlushInterval, self(), ?TIMER_MSG),
    State = #state{flush_interval = FlushInterval,
                   tags = Tags,
                   node_key = node_key(),
                   node_prefix = node_prefix(),
                   timer_ref = Ref},
    {ok, State}.

handle_call(finalize, _, State) ->
    do_finalize(State),
    {reply, ok, State};

handle_call(Call, _, State) ->
    unexpected(call, Call),
    {noreply, State}.

handle_cast(Cast, State) ->
    unexpected(cast, Cast),
    {noreply, State}.

handle_info({timeout, _R, ?TIMER_MSG},
            #state{timer_ref = _R, flush_interval = FlushInterval} = State) ->
    Ref = erlang:start_timer(FlushInterval, self(), ?TIMER_MSG),
    F = fun() -> send_stats(State) end,
    folsom_metrics:histogram_timed_update({?APP, send_stats}, F),
    {noreply, State#state{timer_ref = Ref}};
handle_info({'EXIT', _, _} = Exit, State) ->
    {stop, {exit, Exit}, State};
handle_info(Info, State) ->
    unexpected(info, Info),
    {noreply, State}.

terminate(shutdown, State) ->
    case application:get_env(finalize_on_shutdown) of
        {ok, true} ->
            do_finalize(State);
        _ ->
            ok
    end;

terminate(_, _) -> ok.

code_change(_, State, _) -> {ok, State}.


%% internal
get_stats() ->
    Memory = expand0(folsom_vm_metrics:get_memory(), [memory, vm]),
    Stats = expand0(folsom_vm_metrics:get_statistics(), [vm]),
    Procs = expand0([{processes, length(erlang:processes())}], [vm]),
    Metrics = folsom_metrics:get_metrics_info(),
    Memory ++ Stats ++ Procs ++ lists:flatmap(fun expand_metric/1, Metrics).


%% @doc Returns `[]' for unknown (skipped) metricts.
-spec expand_metric({Name, Opts}) -> [Metric] when
    Metric :: {K::string(), V::string()},
    Name :: term(),
    Opts :: [proplists:property()].
expand_metric({Name, Opts}) ->
    case proplists:get_value(type, Opts) of
            undefined -> [];
            histogram ->
                Stats = folsom_metrics:get_histogram_statistics(Name),
                M = proplists:delete(histogram, Stats),
                expand0(M, [Name]);
            Type ->
                case lists:member(Type,
                                  [counter, gauge, meter, spiral, meter_reader, duration]) of
                    true ->
                        M = folsom_metrics:get_metric_value(Name),
                        expand0(M, [Name]);
                    false -> []
                end
        end;
expand_metric(_) ->
    [].

expand0(M, NamePrefix) -> lists:flatten(expand(M, NamePrefix)).

expand({K, X}, NamePrefix) ->
    expand(X, [K | NamePrefix]);
expand([_|_] = Xs, NamePrefix) ->
    [expand(X, NamePrefix) || X <- Xs];
expand(X, NamePrefix) ->
    K = string:join(lists:map(fun stringify/1, lists:reverse(NamePrefix)), " "),
    [{K, X}].

send_stats(State) ->
    Metrics = get_stats(),
    Timestamp = num2str(unixtime()),
    Prefix = State#state.node_prefix,
    Tags = State#state.tags,
    Heartbeat =
        folsomite_zeta:host_event(Prefix, "heartbeat",1, [{tags, Tags}]),
    Events =
        [Heartbeat|
         [folsomite_zeta:host_event(Prefix, K, V, [{tags, [transient|Tags]}]) ||
          {K, V} <- Metrics]],
    zeta:sv_batch(Events),
    Message = [format1(State#state.node_key, M, Timestamp) || M <- Metrics],
    case folsomite_graphite_client_sup:get_client() of
        {ok, Socket} -> folsomite_graphite_client:send(Socket, Message);
        {error, _} = Error -> Error
    end.

format1(Base, {K, V}, Timestamp) ->
    ["folsomite.", Base, ".", space2dot(K), " ", stringify(V), " ", Timestamp, "\n"].

num2str(NN) -> lists:flatten(io_lib:format("~w",[NN])).
unixtime()  -> {Meg, S, _} = os:timestamp(), Meg*1000000 + S.


node_prefix() ->
    NodeList = atom_to_list(node()),
    [A, _] = string:tokens(NodeList, "@"),
    A.

node_key() ->
    NodeList = atom_to_list(node()),
    Opts = [global, {return, list}],
    re:replace(NodeList, "[\@\.]", "_", Opts).


stringify(X) when is_list(X) -> X;
stringify(X) when is_atom(X) -> atom_to_list(X);
stringify(X) when is_integer(X) -> integer_to_list(X);
stringify(X) when is_float(X) -> float_to_list(X);
stringify(X) when is_binary(X) -> binary_to_list(X);
stringify(X) when is_tuple(X) ->
    string:join([stringify(A) || A <- tuple_to_list(X)], " ").

space2dot(X) -> string:join(string:tokens(X, " "), ".").

get_env(Name) ->
    get_env(Name, undefined).

get_env(Name, Default) ->
    case application:get_env(?APP, Name) of
        {ok, Value} ->
            Value;
        undefined ->
            Default
    end.

unexpected(Type, Message) ->
    error_logger:info_msg(" unexpected ~p ~p~n", [Type, Message]).

do_finalize(#state{timer_ref = Ref} = State) ->
    erlang:cancel_timer(Ref),
    Prefix = State#state.node_prefix,
    Terminate = folsomite_zeta:host_event(Prefix, "heartbeat",
                                          1, [{tags, [terminate]}]),
    zeta:sv_batch([Terminate]).
