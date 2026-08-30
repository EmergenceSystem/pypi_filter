%%%-------------------------------------------------------------------
%%% @doc PyPI Python package search agent.
%%%
%%% Looks up a Python package by name on PyPI and returns its
%%% metadata as an embryo. Accepts an exact package name or a
%%% search query (tries the query as a package name directly).
%%%
%%% Deduplication by URL is handled upstream by the Emquest pipeline.
%%%
%%% === Capability cascade ===
%%%
%%%   base_capabilities/0 extends em_filter:base_capabilities().
%%%
%%% Handler contract: handle/2 (Body, Memory) -> {RawList, Memory}.
%%% @end
%%%-------------------------------------------------------------------
-module(pypi_filter_app).
-behaviour(application).

-export([start/2, stop/1]).
-export([handle/2, base_capabilities/0]).

-define(PACKAGE_URL, "https://pypi.org/pypi/~s/json").

%%====================================================================
%% Capability cascade
%%====================================================================

-spec base_capabilities() -> [binary()].
base_capabilities() ->
    em_filter:base_capabilities() ++ [<<"pypi">>, <<"python">>,
                                      <<"packages">>, <<"pip">>].

%%====================================================================
%% Application behaviour
%%====================================================================

start(_Type, _Args) ->
    case pypi_filter_sup:start_link() of
        {ok, Pid} ->
            ok = start_pop_and_http(),
            {ok, Pid};
        Error ->
            Error
    end.

stop(_State) ->
    catch cowboy:stop_listener(pypi_filter_query_listener),
    catch em_pop_sup:stop_node(pypi_filter),
    ok.

%%====================================================================
%% Internal
%%====================================================================

start_pop_and_http() ->
    PopPort   = application:get_env(pypi_filter, pop_port,   9548),
    QueryPort = application:get_env(pypi_filter, query_port, 9549),
    Seeds     = application:get_env(pypi_filter, pop_seeds,  []),
    Vec = em_filter_vec:from_capabilities(base_capabilities()),
    catch em_pop_sup:stop_node(pypi_filter),
    catch cowboy:stop_listener(pypi_filter_query_listener),
    {ok, PopPid} = em_pop_sup:start_node(pypi_filter, #{
        port            => PopPort,
        query_port      => QueryPort,
        vector          => Vec,
        max_peers       => 100,
        gossip_interval => 5_000
    }),
    lists:foreach(
        fun({H, P}) -> catch em_pop_node:add_peer(PopPid, H, P) end,
        Seeds),
    Dispatch = cowboy_router:compile([
        {'_', [{"/agent/query", em_filter_http,
                #{server => pypi_filter_server}}]}
    ]),
    {ok, _} = cowboy:start_clear(pypi_filter_query_listener,
                                  [{port, QueryPort}],
                                  #{env => #{dispatch => Dispatch}}),
    logger:notice("[pypi_filter] gossip port ~w  query port ~w",
                  [PopPort, QueryPort]),
    ok.

%%====================================================================
%% Agent handler
%%====================================================================

handle(Body, Memory) when is_binary(Body) ->
    {generate_embryo_list(Body), Memory};
handle(_Body, Memory) ->
    {[], Memory}.

%%====================================================================
%% Package lookup
%%====================================================================

generate_embryo_list(JsonBinary) ->
    {Name, Timeout} = extract_params(JsonBinary),
    fetch_package(Name, Timeout).

extract_params(JsonBinary) ->
    try json:decode(JsonBinary) of
        Map when is_map(Map) ->
            Name    = binary_to_list(maps:get(<<"value">>, Map,
                          maps:get(<<"query">>, Map,
                          maps:get(<<"name">>, Map, <<"">>)))),
            Timeout = case maps:get(<<"timeout">>, Map, undefined) of
                undefined            -> 10;
                T when is_integer(T) -> T;
                T when is_binary(T)  -> binary_to_integer(T)
            end,
            {Name, Timeout};
        _ ->
            {binary_to_list(JsonBinary), 10}
    catch
        _:_ -> {binary_to_list(JsonBinary), 10}
    end.

fetch_package("", _) -> [];
fetch_package(Name, Timeout) ->
    Url = lists:flatten(io_lib:format(?PACKAGE_URL, [Name])),
    case httpc:request(get, {Url, []},
                       [{timeout, Timeout * 1000},
                        {ssl, [{verify, verify_none}]}],
                       [{body_format, binary}]) of
        {ok, {{_, 200, _}, _, Body}} ->
            parse_package(Body);
        _ ->
            []
    end.

parse_package(JsonBin) ->
    try json:decode(JsonBin) of
        #{<<"info">> := Info} when is_map(Info) ->
            [build_embryo(Info)];
        _ ->
            []
    catch
        _:_ -> []
    end.

build_embryo(Info) ->
    Name    = maps:get(<<"name">>,        Info, <<"">>),
    Version = maps:get(<<"version">>,     Info, <<"">>),
    Summary = maps:get(<<"summary">>,     Info, <<"">>),
    Home    = maps:get(<<"home_page">>,   Info, null),
    Url     = lists:flatten(io_lib:format(
        "https://pypi.org/project/~s/", [binary_to_list(Name)])),
    Resume  = format_resume(Summary, Version),
    #{
        <<"properties">> => #{
            <<"url">>       => list_to_binary(Url),
            <<"resume">>    => Resume,
            <<"title">>     => Name,
            <<"version">>   => Version,
            <<"homepage">>  => if Home =:= null -> <<"">>;
                                  is_binary(Home) -> Home end,
            <<"source">>    => <<"pypi.org">>
        }
    }.

format_resume(Summary, Version) ->
    S = if is_binary(Summary) -> binary_to_list(Summary); true -> "" end,
    V = if is_binary(Version) -> binary_to_list(Version); true -> "" end,
    case {S, V} of
        {"", ""}  -> <<"">>;
        {S2, ""}  -> list_to_binary(S2);
        {"", V2}  -> list_to_binary("v" ++ V2);
        {S2, V2}  -> list_to_binary(S2 ++ " (v" ++ V2 ++ ")")
    end.
