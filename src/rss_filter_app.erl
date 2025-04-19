%%%-------------------------------------------------------------------
%%% @doc This module handles the RSS filter application and acts as a Cowboy HTTP handler.
%%% It reads an RSS configuration, processes incoming HTTP requests, and filters RSS feeds based on the request body.
%%%
%%% @end
%%%-------------------------------------------------------------------

-module(rss_filter_app).
-behaviour(application).
-behaviour(cowboy_handler).

-include_lib("xmerl/include/xmerl.hrl").

%%%-------------------------------------------------------------------
%%% @doc Exported functions for the application and Cowboy handler behaviours.
%%%
%%% @end
%%%-------------------------------------------------------------------
-export([start/2, stop/1, init/2, terminate/3]).

%%%-------------------------------------------------------------------
%%% @doc Starts the application.
%%% Finds the port and starts the supervisor link for the RSS filter.
%%%
%%% @spec start(start_type(), start_args()) -> {ok, port()}
%%% @end
%%%-------------------------------------------------------------------
start(_StartType, _StartArgs) ->
    {ok, Port} = em_filter:find_port(),
    em_filter_sup:start_link(rss_filter, ?MODULE, Port).

%%%-------------------------------------------------------------------
%%% @doc Stops the application.
%%%
%%% @spec stop(state()) -> ok
%%% @end
%%%-------------------------------------------------------------------
stop(_State) ->
    ok.

%%%-------------------------------------------------------------------
%%% @doc Initializes the Cowboy handler.
%%% Reads the body of the incoming HTTP request, processes it, and generates a response.
%%%
%%% @spec init(cowboy_req:req(), state()) -> {ok, cowboy_req:req(), state()}
%%% @end
%%%-------------------------------------------------------------------
init(Req0, State) ->
    {ok, Body, Req} = cowboy_req:read_body(Req0),
    io:format("Received body: ~p~n", [Body]),
    EmbryoList = generate_embryo_list(Body),
    Response = #{embryo_list => EmbryoList},
    EncodedResponse = jsone:encode(Response),
    Req2 = cowboy_req:reply(200,
        #{<<"content-type">> => <<"application/json">>},
        EncodedResponse,
        Req
    ),
    {ok, Req2, State}.

%%%-------------------------------------------------------------------
%%% @doc Terminates the Cowboy handler.
%%%
%%% @spec terminate(reason(), cowboy_req:req(), state()) -> ok
%%% @end
%%%-------------------------------------------------------------------
terminate(_Reason, _Req, _State) ->
    ok.

%%%-------------------------------------------------------------------
%%% @doc Reads the RSS configuration from a JSON file.
%%%
%%% @spec read_rss_config() -> {ok, [binary()]}
%%% @end
%%%-------------------------------------------------------------------
read_rss_config() ->
    case file:read_file("rss_config.json") of
        {ok, Binary} ->
            case jsone:decode(Binary) of
                #{<<"rss_feeds">> := RssFeeds} when is_list(RssFeeds) ->
                    {ok, RssFeeds};
                _ ->
                    {ok, []}
            end;
        {error, Reason} ->
            io:format("Error reading RSS config: ~p~n", [Reason]),
            {ok, []}
    end.

%%%-------------------------------------------------------------------
%%% @doc Generates a list of embryos based on the JSON body of the request.
%%% Decodes the JSON body and initiates the search across RSS feeds.
%%%
%%% @spec generate_embryo_list(binary()) -> [map()]
%%% @end
%%%-------------------------------------------------------------------
generate_embryo_list(JsonBinary) ->
    case jsone:decode(JsonBinary, [{keys, atom}]) of
        Search when is_map(Search) ->
            Value = string:lowercase(binary_to_list(maps:get(value, Search, <<"">>))),
            Timeout = list_to_integer(binary_to_list(maps:get(timeout, Search, <<"10">>))),

            {ok, RssFeeds} = read_rss_config(),
            StartTime = erlang:system_time(millisecond),

            search_feeds(RssFeeds, Value, StartTime, Timeout * 1000, []);
        {error, Reason} ->
            io:format("Error decoding JSON: ~p~n", [Reason]),
            []
    end.

%%%-------------------------------------------------------------------
%%% @doc Searches the RSS feeds for items matching the search criteria.
%%% Iterates over the RSS feeds, fetches the feed data, and processes the items.
%%%
%%% @spec search_feeds([binary()], binary(), integer(), integer(), [map()]) -> [map()]
%%% @end
%%%-------------------------------------------------------------------
search_feeds([], _SearchValue, _StartTime, _TimeoutMs, Acc) ->
    lists:reverse(Acc);
search_feeds([FeedUrl | Rest], SearchValue, StartTime, TimeoutMs, Acc) ->
    CurrentTime = erlang:system_time(millisecond),
    case CurrentTime - StartTime >= TimeoutMs of
        true ->
            lists:reverse(Acc);
        false ->
            case httpc:request(get, {binary_to_list(FeedUrl), []}, [{timeout, 5000}], [{body_format, binary}]) of
                {ok, {{_, 200, _}, _, Body}} ->
                    case xmerl_scan:string(binary_to_list(Body)) of
                        {RssDoc, _} ->
                            Items = xmerl_xpath:string("//item", RssDoc),
                            NewAcc = process_feed_items(Items, SearchValue, StartTime, TimeoutMs, Acc),
                            search_feeds(Rest, SearchValue, StartTime, TimeoutMs, NewAcc);
                        _ ->
                            io:format("Failed to parse RSS XML~n"),
                            search_feeds(Rest, SearchValue, StartTime, TimeoutMs, Acc)
                    end;
                {error, Reason} ->
                    io:format("Error fetching RSS feed: ~p~n", [Reason]),
                    search_feeds(Rest, SearchValue, StartTime, TimeoutMs, Acc)
            end
    end.

%%%-------------------------------------------------------------------
%%% @doc Processes individual RSS feed items.
%%% Checks if the items match the search criteria and adds them to the accumulator if they do.
%%%
%%% @spec process_feed_items([xml()], binary(), integer(), integer(), [map()]) -> [map()]
%%% @end
%%%-------------------------------------------------------------------
process_feed_items([], _SearchValue, _StartTime, _TimeoutMs, Acc) ->
    Acc;
process_feed_items([Item | Rest], SearchValue, StartTime, TimeoutMs, Acc) ->
    CurrentTime = erlang:system_time(millisecond),
    case CurrentTime - StartTime >= TimeoutMs of
        true ->
            Acc;
        false ->
            Title = extract_element_text(xmerl_xpath:string("./title/text()", Item)),
            Link = extract_element_text(xmerl_xpath:string("./link/text()", Item)),
            Description = extract_element_text(xmerl_xpath:string("./description/text()", Item)),

            LowerTitle = string:lowercase(Title),
            LowerLink = string:lowercase(Link),
            LowerDescription = string:lowercase(Description),

            NewAcc = case string:str(LowerTitle, SearchValue) > 0 orelse
                         string:str(LowerLink, SearchValue) > 0 orelse
                         string:str(LowerDescription, SearchValue) > 0 of
                true ->
                    Embryo = #{
                        properties => #{
                            <<"url">> => list_to_binary(Link),
                            <<"resume">> => unicode:characters_to_binary(Description)
                        }
                    },
                    [Embryo | Acc];
                false ->
                    Acc
            end,
            process_feed_items(Rest, SearchValue, StartTime, TimeoutMs, NewAcc)
    end.

%%%-------------------------------------------------------------------
%%% @doc Extracts text from XML elements.
%%%
%%% @spec extract_element_text([xml()]) -> binary()
%%% @end
%%%-------------------------------------------------------------------
extract_element_text([]) ->
    "";
extract_element_text([Element | _]) ->
    case Element of
        #xmlText{value = Value} ->
            Value;
        _ ->
            ""
    end.

