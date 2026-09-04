%%%-------------------------------------------------------------------
%%% @doc RSS feed search agent.
%%%
%%% Reads a list of RSS feed URLs from rss_config.json, fetches each
%%% feed, and returns items whose title, link or description matches
%%% the search query.
%%%
%%% Deduplication by URL is handled upstream by the Emquest pipeline.
%%%
%%% === Capability cascade ===
%%%
%%%   base_capabilities/0 extends em_filter:base_capabilities().
%%%   Site-specific filters extend rss_filter_app:base_capabilities():
%%%
%%% rss_config.json format:
%%%   { "rss_feeds": ["https://example.com/feed.rss", ...] }
%%%
%%% Handler contract: handle/2 (Body, Memory) -> {RawList, Memory}.
%%% @end
%%%-------------------------------------------------------------------
-module(rss_filter_app).

-include_lib("xmerl/include/xmerl.hrl").

-export([handle/2, base_capabilities/0, sanitize_xml/1, scan_feed/1]).

%%====================================================================
%% Capability cascade
%%====================================================================

-spec base_capabilities() -> [binary()].
base_capabilities() ->
    em_filter:base_capabilities() ++ [<<"rss">>, <<"feeds">>, <<"news">>].

%%====================================================================
%% Agent handler
%%====================================================================

handle(Body, Memory) when is_binary(Body) ->
    {generate_embryo_list(Body), Memory};
handle(_Body, Memory) ->
    {[], Memory}.

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
            Value   = binary_to_list(maps:get(<<"value">>, Map,
                          maps:get(<<"query">>, Map, <<"">>))),
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
            case scan_feed(Body) of
                {ok, Items} ->
                    process_feed_items(Items, Query, Start, Timeout, Acc);
                {error, _} ->
                    Acc
            end;
        _ ->
            Acc
    end.

%%--------------------------------------------------------------------
%% XML parsing (robust to real-world feeds)
%%--------------------------------------------------------------------

%% @doc Escape any `&' that does not start a valid XML entity or character
%% reference, so feeds carrying bare ampersands or undeclared HTML entities
%% (e.g. `&nbsp;') do not blow up xmerl with error_scanning_entity_ref.
-spec sanitize_xml(binary() | string()) -> string().
sanitize_xml(Bin) when is_binary(Bin) -> sanitize_xml(binary_to_list(Bin));
sanitize_xml(S) when is_list(S) ->
    re:replace(S,
               "&(?!(?:#[0-9]+|#x[0-9a-fA-F]+|amp|lt|gt|quot|apos);)",
               "\\&amp;",
               [global, {return, list}]).

%% @doc Parse a feed body into its `item' elements, sanitising first and
%% never crashing: any scan failure yields `{error, parse_failed}'.
-spec scan_feed(binary() | string()) -> {ok, list()} | {error, term()}.
scan_feed(Body) ->
    try xmerl_scan:string(sanitize_xml(Body)) of
        {Doc, _} -> {ok, xmerl_xpath:string("//item", Doc)}
    catch
        Class:Reason ->
            logger:warning("[rss_filter] feed parse failed: ~p:~p", [Class, Reason]),
            {error, parse_failed}
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
