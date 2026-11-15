# SPDX-License-Identifier: LGPL-3.0-only
# SPDX-FileCopyrightText: Copyright (C) 2026 mplx <mplx@jennifer-lang.dev>
# pragma-jennifer-version: >=0.26.0

# gemini - white-box tests for the tools topic. Spliced into gemini_test.j
# via include.

# turn 1: two calls in parallel, the signature on the first only, after a
# thought summary
def const PARALLEL as string init '{"candidates": [{"content": {"role": "model", "parts": [{"text": "Two cities: call both.", "thought": true}, {"functionCall": {"id": "call-paris", "name": "getWeather", "args": {"city": "Paris"}}, "thoughtSignature": "c2lnLXBhcmFsbGVs"}, {"functionCall": {"id": "call-london", "name": "getWeather", "args": {"city": "London"}}}]}, "finishReason": "STOP", "index": 0}], "usageMetadata": {"promptTokenCount": 70, "candidatesTokenCount": 30, "thoughtsTokenCount": 25, "totalTokenCount": 125}, "modelVersion": "gemini-3.8-flash"}';

# turn 2: one call that depends on the results, with its own signature
def const SEQUENTIAL as string init '{"candidates": [{"content": {"role": "model", "parts": [{"functionCall": {"id": "call-convert", "name": "toFahrenheit", "args": {"celsius": 21}}, "thoughtSignature": "c2lnLXNlcXVlbnRpYWw="}]}, "finishReason": "STOP", "index": 0}], "modelVersion": "gemini-3.8-flash"}';

# turn 3: the answer
def const ANSWERED as string init '{"candidates": [{"content": {"role": "model", "parts": [{"text": "Paris and London are both 21 C (69.8 F).", "thoughtSignature": "c2lnLWZpbmFs"}]}, "finishReason": "STOP", "index": 0}], "modelVersion": "gemini-3.8-flash"}';

/**
 * The tools of the tests.
 *
 * @param name {string} the function
 * @param input {json.Value} its arguments
 * @return {json.Value} its result
 */
func weatherTool(name as string, input as json.Value) {
    if ($name == "getWeather") {
        return json.map({"city": json.asString($input, "/city"), "celsius": 21});
    }
    # not an object: sent as {"result": ...}
    return json.decode("69.8");
}

/**
 * The tools of the tests, with a context.
 *
 * @param name {string} the function
 * @param input {json.Value} its arguments
 * @param context {json.Value} the context
 * @return {json.Value} its result
 */
func unitTool(name as string, input as json.Value, context as json.Value) {
    return json.map({"unit": json.asString($context, "/unit"), "name": $name});
}

/**
 * A tool that fails.
 *
 * @param name {string} the function
 * @param input {json.Value} its arguments
 * @return {json.Value} never
 */
func brokenTool(name as string, input as json.Value) {
    throw Error{kind: "tool", message: "the weather station is down"};
}

/**
 * A request offering the weather tools.
 *
 * @return {json.Value} the request
 */
func weatherRequest() {
    def city as json.Value init json.decode(
        '{"type": "object", "properties": {"city": {"type": "string"}}, "required": ["city"]}');
    def tools as list of json.Value init [
        tool("getWeather", "The weather in a city now.", $city),
        tool(
            "toFahrenheit",
            "Celsius to Fahrenheit.",
            json.decode('{"type": "object", "properties": {"celsius": {"type": "number"}}}'))
    ];
    return addUserText(
        addTools(newRequest("gemini-3.8-flash"), $tools),
        "Weather in Paris and London, in F?");
}

func testToolsAndModes() {
    def d as json.Value init tool("now", "The time.", json.decode("null"));
    testing.assertEqual(json.encode($d), '{"name":"now","description":"The time."}');
    for (def bad in ["", "9lives", "a b", strings.repeat("x", 129)]) {
        try {
            tool($bad, "", json.decode("null"));
            missed($bad);
        } catch (e) {
            testing.assertContains($e.message, "a function name is");
        }
    }
    try {
        tool("f", "", json.decode('"string"'));
        missed("parameters");
    } catch (e) {
        testing.assertContains($e.message, "are a string, not an object");
    }
    # every declaration goes into one functionDeclarations entry; other tools stay
    def req as json.Value init json.set(
        newRequest("gemini-3.8-flash"),
        "/tools",
        json.decode('[{"googleSearch": {}}]'));
    $req = addTool($req, $d);
    $req = addTools(
        $req,
        [tool("later", "", json.decode("null")), tool("soon", "", json.decode("null"))]);
    testing.assertEqual(
        json.encode(json.get($req, "/tools")),
        '[{"googleSearch":{}},{"functionDeclarations":[{"name":"now","description":"The time."},{"name":"later","description":""},{"name":"soon","description":""}]}]');
    testing.assertEqual(
        json.encode(json.get(addTool(newRequest("gemini-3.8-flash"), $d), "/tools")),
        '[{"functionDeclarations":[{"name":"now","description":"The time."}]}]');
    testing.assertEqual(addTools($req, []), $req);
    try {
        addTool($req, $d);
        missed("twice");
    } catch (e) {
        testing.assertContains($e.message, "a tool named \"now\" is offered already");
    }
    try {
        addTools($req, [tool("fine", "", json.decode("null")), json.map()]);
        missed("no name");
    } catch (e) {
        testing.assertContains($e.message, "build it with tool");
    }
    $req = withToolMode($req, "ANY", ["now"]);
    testing.assertEqual(
        json.encode(json.get($req, "/toolConfig")),
        '{"functionCallingConfig":{"mode":"ANY","allowedFunctionNames":["now"]}}');
    testing.assertEqual(
        json.encode(json.get(withToolMode($req, "AUTO", []), "/toolConfig")),
        '{"functionCallingConfig":{"mode":"AUTO"}}');
    try {
        withToolMode($req, "auto", []);
        missed("mode");
    } catch (e) {
        testing.assertContains($e.message, "a tool mode is");
    }
}

func testToolCallsAndResults() {
    def calls as list of ToolCall init toolCalls(json.decode(PARALLEL));
    testing.assertEqual(len($calls), 2);
    testing.assertEqual($calls[0].id, "call-paris");
    testing.assertEqual($calls[0].name, "getWeather");
    testing.assertEqual(json.asString($calls[1].input, "/city"), "London");
    testing.assertEqual(len(toolCalls(json.decode(ANSWERED))), 0);
    # a call without args or id (Gemini 2.5)
    def old as list of ToolCall init toolCalls(json.decode(
        '{"candidates": [{"content": {"role": "model", "parts": [{"functionCall": {"name": "now"}}]}}]}'));
    testing.assertEqual($old[0].id, "");
    testing.assertEqual(json.encode($old[0].input), '{}');
    def req as json.Value init addToolResults(
        newRequest("gemini-3.8-flash"),
        $old,
        [json.decode('"12:00"')]);
    testing.assertEqual(
        json.encode(json.get($req, "/contents/0")),
        '{"role":"user","parts":[{"functionResponse":{"name":"now","response":{"result":"12:00"}}}]}');
    # an error result is an object, sent as the response unwrapped
    testing.assertEqual(json.encode(toolError("no clock")), '{"error":"no clock"}');
    testing.assertEqual(
        json.encode(json.get(
            addToolResults($req, $old, [toolError("no clock")]),
            "/contents/1/parts/0")),
        '{"functionResponse":{"name":"now","response":{"error":"no clock"}}}');
    try {
        addToolResults($req, $calls, [json.map()]);
        missed("lengths");
    } catch (e) {
        testing.assertContains($e.message, "2 calls but 1 results");
    }
    try {
        toolCalls(json.decode('{"candidates": [{"content": {"parts": [{"functionCall": {"args": {}}}]}}]}'));
        missed("no name");
    } catch (e) {
        testing.assertContains($e.message, "has no name");
    }
}

func testToolLoopKeepsSignaturesAndOrder() {
    def f as Fake init startFake({
        "POST /v1beta/models/gemini-3.8-flash:generateContent": answer(200, PARALLEL) + NEXT +
            answer(200, SEQUENTIAL) + NEXT + answer(200, ANSWERED)
    });
    def run as ToolRun init runTools(fakeClient($f), weatherRequest(), weatherTool, 8);
    def seen as list of string init stopFake($f);
    testing.assertEqual($run.turns, 3);
    testing.assertEqual($run.calls, 3);
    # only the first reply sent usage: the sum is its counts
    testing.assertEqual($run.usage.inputTokens, 70);
    testing.assertEqual($run.usage.reasoningTokens, 25);
    testing.assertEqual($run.usage.totalTokens, 125);
    testing.assertEqual(text($run.reply), "Paris and London are both 21 C (69.8 F).");
    testing.assertEqual(len($seen), 3);
    # the second request: the user's, the model's turn as received (thought,
    # both calls, the signature on the first), then both results in order
    def second as json.Value init seenBody($seen[1]);
    testing.assertEqual(json.length($second, "/contents"), 3);
    testing.assertEqual(
        json.get($second, "/contents/1"),
        json.get(json.decode(PARALLEL), "/candidates/0/content"));
    testing.assertEqual(
        json.encode(json.get($second, "/contents/2")),
        '{"role":"user","parts":[{"functionResponse":{"id":"call-paris","name":"getWeather","response":{"city":"Paris","celsius":21}}},{"functionResponse":{"id":"call-london","name":"getWeather","response":{"city":"London","celsius":21}}}]}');
    testing.assertTrue(json.has($second, "/tools/0/functionDeclarations/1"));
    # the third: everything before, the sequential call with its signature,
    # its result wrapped
    def third as json.Value init seenBody($seen[2]);
    testing.assertEqual(json.length($third, "/contents"), 5);
    testing.assertEqual(
        json.asString($third, "/contents/1/parts/1/thoughtSignature"),
        "c2lnLXBhcmFsbGVs");
    testing.assertEqual(
        json.asString($third, "/contents/3/parts/0/thoughtSignature"),
        "c2lnLXNlcXVlbnRpYWw=");
    testing.assertEqual(
        json.encode(json.get($third, "/contents/4/parts/0")),
        '{"functionResponse":{"id":"call-convert","name":"toFahrenheit","response":{"result":69.8}}}');
    # the run's request goes on: it ends with the answer
    testing.assertEqual(json.length($run.request, "/contents"), 6);
    testing.assertEqual(
        json.asString($run.request, "/contents/5/parts/0/thoughtSignature"),
        "c2lnLWZpbmFs");
}

func testToolLoopWithContextLimitAndErrors() {
    def f as Fake init startFake({
        "POST /v1beta/models/gemini-3.8-flash:generateContent": answer(200, SEQUENTIAL) + NEXT +
            answer(200, ANSWERED)
    });
    def c as Client init fakeClient($f);
    def run as ToolRun init runToolsWith(
        $c,
        weatherRequest(),
        unitTool,
        json.map({"unit": "kelvin"}),
        2);
    testing.assertEqual($run.turns, 2);
    def g as Fake init startFake({
        "POST /v1beta/models/gemini-3.8-flash:generateContent": answer(200, SEQUENTIAL) + NEXT +
            answer(200, BLOCKED)
    });
    def gc as Client init fakeClient($g);
    # out of turns: returned, not thrown, with the calls' results kept
    def short as ToolRun init runTools($gc, weatherRequest(), weatherTool, 1);
    testing.assertEqual($short.stopped, "maxTurns");
    testing.assertEqual($short.turns, 1);
    testing.assertEqual($short.calls, 1);
    testing.assertEqual(len(toolCalls($short.reply)), 1);
    testing.assertEqual(
        json.asString($short.request, "/contents/2/parts/0/functionResponse/name"),
        "toFahrenheit");
    testing.assertEqual($run.stopped, "");
    # a blocked reply ends the loop as data
    def blocked as ToolRun init runTools($gc, weatherRequest(), weatherTool, 5);
    testing.assertEqual(blockReason($blocked.reply), "SAFETY");
    testing.assertEqual($blocked.turns, 1);
    try {
        runTools($gc, weatherRequest(), weatherTool, 0);
        missed("no turns");
    } catch (e) {
        testing.assertContains($e.message, "the turns must be 1 to 100");
    }
    def seen as list of string init stopFake($f);
    stopFake($g);
    def sent as json.Value init seenBody($seen[1]);
    testing.assertEqual(
        json.encode(json.get($sent, "/contents/2/parts/0/functionResponse/response")),
        '{"unit":"kelvin","name":"toFahrenheit"}');
    def h as Fake init startFake({
        "POST /v1beta/models/gemini-3.8-flash:generateContent": answer(200, PARALLEL)
    });
    try {
        runTools(fakeClient($h), weatherRequest(), brokenTool, 3);
        missed("a broken tool");
    } catch (e) {
        # the handler's error reaches the caller unchanged
        testing.assertEqual($e.kind, "tool");
        testing.assertEqual($e.message, "the weather station is down");
    }
    testing.assertEqual(len(stopFake($h)), 1);
}

func testToolRunSumsUsage() {
    def f as Fake init startFake({
        "POST /v1beta/models/gemini-3.8-flash:generateContent": answer(200, PARALLEL) + NEXT +
            answer(200, THOUGHTFUL)
    });
    def run as ToolRun init runTools(fakeClient($f), weatherRequest(), weatherTool, 4);
    stopFake($f);
    testing.assertEqual($run.turns, 2);
    testing.assertEqual($run.calls, 2);
    testing.assertEqual($run.usage.inputTokens, 79);
    testing.assertEqual($run.usage.outputTokens, 42);
    testing.assertEqual($run.usage.reasoningTokens, 65);
    testing.assertEqual($run.usage.cachedTokens, 4);
    testing.assertEqual($run.usage.totalTokens, 186);
}

# the arguments of a call over a 1024-byte cap
def const OVERSIZED as string init '{"candidates": [{"content": {"role": "model", "parts": [{"functionCall": {"id": "call-big", "name": "getWeather", "args": {"city": "CITYHERE"}}, "thoughtSignature": "c2lnLWJpZw=="}]}, "finishReason": "STOP", "index": 0}]}';

func testToolInputCap() {
    def f as Fake init startFake({
        "POST /v1beta/models/gemini-3.8-flash:generateContent": answer(
            200,
            strings.replace(OVERSIZED, 'CITYHERE', strings.repeat("x", 2000))) + NEXT +
            answer(200, ANSWERED)
    });
    def c as Client init withMaxToolInput(fakeClient($f), 1024);
    def run as ToolRun init runTools($c, weatherRequest(), weatherTool, 4);
    def seen as list of string init stopFake($f);
    # the handler was not called; the model got an error to recover from
    testing.assertEqual($run.calls, 0);
    testing.assertEqual($run.turns, 2);
    def sent as json.Value init seenBody($seen[1]);
    testing.assertEqual(
        json.asString($sent, "/contents/2/parts/0/functionResponse/response/error"),
        "the input is over 1024 bytes; call the tool again with a smaller input");
    testing.assertEqual(client(KEY).maxToolInput, DEFAULT_MAX_TOOL_INPUT);
    try {
        withMaxToolInput($c, 1023);
        missed("a tiny cap");
    } catch (e) {
        testing.assertEqual($e.kind, "gemini");
    }
}
