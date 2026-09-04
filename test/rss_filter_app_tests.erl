-module(rss_filter_app_tests).
-include_lib("eunit/include/eunit.hrl").

sanitize_keeps_valid_test() ->
    ?assertEqual("<a>&amp; &lt; &gt; &#39; &#x41;</a>",
                 rss_filter_app:sanitize_xml(<<"<a>&amp; &lt; &gt; &#39; &#x41;</a>">>)).

sanitize_escapes_bare_amp_test() ->
    ?assertEqual("A &amp; B", rss_filter_app:sanitize_xml(<<"A & B">>)).

sanitize_escapes_unknown_entity_test() ->
    ?assertEqual("x&amp;nbsp;y", rss_filter_app:sanitize_xml(<<"x&nbsp;y">>)).

scan_feed_survives_bad_entities_test() ->
    Feed = <<"<rss><channel>"
             "<item><title>Tom &nbsp; Jerry & Co</title>"
             "<link>http://x</link><description>d</description></item>"
             "</channel></rss>">>,
    {ok, Items} = rss_filter_app:scan_feed(Feed),
    ?assertEqual(1, length(Items)).

scan_feed_broken_xml_returns_error_test() ->
    ?assertMatch({error, _}, rss_filter_app:scan_feed(<<"<rss><item><title>unclosed">>)).
