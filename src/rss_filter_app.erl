%%%-------------------------------------------------------------------
%%% @doc RSS feed search filter.
%%%
%%% Reads a list of RSS feed URLs from rss_config.json, fetches each
%%% feed, and returns items whose title, link or description matches
%%% the search query.
%%%
%%% rss_config.json format:
%%%   { "rss_feeds": ["https://example.com/feed.rss", ...] }
%%% @end
%%%-------------------------------------------------------------------
-module(rss_filter_app).
-behaviour(application).

-include_lib("xmerl/include/xmerl.hrl").

-export([start/2, stop/1]).
-export([handle/1]).

%%====================================================================
%% Application behaviour
%%====================================================================

start(_StartType, _StartArgs) ->
    em_filter:start_filter(rss_filter, ?MODULE).

stop(_State) ->
    em_filter:stop_filter(rss_filter).

%%====================================================================
%% Filter handler — returns a list of embryo maps
%%====================================================================

handle(Body) when is_binary(Body) ->
    generate_embryo_list(Body);
handle(_) ->
    [].

%%====================================================================
%% Search and processing
%%====================================================================

generate_embryo_list(JsonBinary) ->
    {Value, Timeout} = extract_params(JsonBinary),
    Feeds     = read_rss_config(),
    StartTime = erlang:system_time(millisecond),
    search_feeds(Feeds, string:lowercase(Value), StartTime, Timeout * 1000, []).

extract_params(JsonBinary) ->
    try json:decode(JsonBinary) of
        Map when is_map(Map) ->
            Value   = binary_to_list(maps:get(<<"value">>,   Map, <<"">>)),
            Timeout = case maps:get(<<"timeout">>, Map, undefined) of
                undefined            -> 10;
                T when is_integer(T) -> T;
                T when is_binary(T)  -> binary_to_integer(T)
            end,
            {Value, Timeout};
        _ ->
            {binary_to_list(JsonBinary), 10}
    catch
        _:_ -> {binary_to_list(JsonBinary), 10}
    end.

%%--------------------------------------------------------------------
%% Config
%%--------------------------------------------------------------------

read_rss_config() ->
    case file:read_file("rss_config.json") of
        {ok, Bin} ->
            try json:decode(Bin) of
                #{<<"rss_feeds">> := Feeds} when is_list(Feeds) -> Feeds;
                _ -> []
            catch _:_ -> [] end;
        _ -> []
    end.

%%--------------------------------------------------------------------
%% Feed iteration
%%--------------------------------------------------------------------

search_feeds([], _Query, _Start, _Timeout, Acc) ->
    lists:reverse(Acc);
search_feeds([FeedUrl | Rest], Query, Start, Timeout, Acc) ->
    case erlang:system_time(millisecond) - Start >= Timeout of
        true  -> lists:reverse(Acc);
        false ->
            NewAcc = fetch_and_filter_feed(FeedUrl, Query, Start, Timeout, Acc),
            search_feeds(Rest, Query, Start, Timeout, NewAcc)
    end.

fetch_and_filter_feed(FeedUrl, Query, Start, Timeout, Acc) ->
    Url = binary_to_list(FeedUrl),
    case httpc:request(get, {Url, []}, [{timeout, 5000}], [{body_format, binary}]) of
        {ok, {{_, 200, _}, _, Body}} ->
            case xmerl_scan:string(binary_to_list(Body)) of
                {Doc, _} ->
                    Items = xmerl_xpath:string("//item", Doc),
                    process_feed_items(Items, Query, Start, Timeout, Acc);
                _ ->
                    Acc
            end;
        _ ->
            Acc
    end.

%%--------------------------------------------------------------------
%% Item processing
%%--------------------------------------------------------------------

process_feed_items([], _Query, _Start, _Timeout, Acc) ->
    Acc;
process_feed_items([Item | Rest], Query, Start, Timeout, Acc) ->
    case erlang:system_time(millisecond) - Start >= Timeout of
        true  -> Acc;
        false ->
            NewAcc = case process_item(Item, Query) of
                {ok, Embryo} -> [Embryo | Acc];
                skip         -> Acc
            end,
            process_feed_items(Rest, Query, Start, Timeout, NewAcc)
    end.

process_item(Item, Query) ->
    Title = xml_text(xmerl_xpath:string("./title/text()",       Item)),
    Link  = xml_text(xmerl_xpath:string("./link/text()",        Item)),
    Desc  = xml_text(xmerl_xpath:string("./description/text()", Item)),
    Matches =
        string:str(string:lowercase(Title), Query) > 0 orelse
        string:str(string:lowercase(Link),  Query) > 0 orelse
        string:str(string:lowercase(Desc),  Query) > 0,
    case Matches of
        true ->
            {ok, #{
                <<"properties">> => #{
                    <<"url">>    => list_to_binary(Link),
                    <<"resume">> => unicode:characters_to_binary(Desc)
                }
            }};
        false ->
            skip
    end.

xml_text([#xmlText{value = V} | _]) -> V;
xml_text(_)                          -> "".
