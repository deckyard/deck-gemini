# SPDX-License-Identifier: LGPL-3.0-only
# SPDX-FileCopyrightText: Copyright (C) 2026 mplx <mplx@jennifer-lang.dev>
# pragma-jennifer-version: >=0.27.0

# gemini - tools: function declarations, the tool mode, reading function
# calls, sending results back, and the tool loop. Spliced into gemini.j via
# include.

/** The most model turns `runTools` takes. */
export def const MAX_TOOL_TURNS as int init 100;

/** The function-calling modes `withToolMode` takes. */
export def const TOOL_MODES as list of string init ["AUTO", "ANY", "NONE", "VALIDATED"];

# a function name: what the API accepts
def const FUNCTION_NAME as string init '^[A-Za-z_][A-Za-z0-9_.:-]{0,127}$';

/**
 * A function the model asked to call.
 *
 * @field id {string} the call's id, `""` when the model sent none (Gemini 3 and later always send one); its result carries it back
 * @field name {string} the function's name
 * @field input {json.Value} the arguments (the call's `args`), an object
 */
export def struct ToolCall {
    id as string,
    name as string,
    input as json.Value
};

/**
 * What `runTools` ended with.
 *
 * @field reply {json.Value} the last reply: the one that called no function (or was blocked: check `blockReason`), or with `stopped` "maxTurns" the last one that still called functions
 * @field request {json.Value} the request with every turn added, the last reply's included when it had an answer: add a user turn and `chat` or `runTools` it to go on; with `stopped` "maxTurns" it ends with the results of the last calls, so `chat` or `runTools` it as it is
 * @field turns {int} how many replies the loop asked for
 * @field calls {int} how many function calls the handler ran
 * @field usage {Usage} the token counts of every reply, summed
 * @field stopped {string} `""` when the model finished, `"maxTurns"` when the loop ran out of turns while the model still called functions
 */
export def struct ToolRun {
    reply as json.Value,
    request as json.Value,
    turns as int,
    calls as int,
    usage as Usage,
    stopped as string
};

/**
 * A tool to offer the model: a function declaration. Gemini has no strict
 * mode (`withStrict` in the openai and anthropic decks): its schemas are
 * an OpenAPI subset the model is steered by, and `withToolMode` with
 * `VALIDATED` is the closest it offers. Check arguments before acting on
 * them, with the `jsonschema` deck.
 *
 * @param name {string} the name the model calls it by: letters, digits, `_`, `.`, `:` and `-`, at most 128
 * @param description {string} what it does and when to use it; the model reads it
 * @param schema {json.Value} its parameters as a schema object (`type`, `properties`, `required`), JSON `null` for none
 * @return {json.Value} `{"name", "description", "parameters"}`
 * @throws {GeminiError} kind "gemini" when the name is malformed or the schema is neither an object nor null
 * @example
 *   def weather as json.Value init gemini.tool("getWeather", "The weather in a city now.",
 *       json.decode('{"type": "object", "properties": {"city": {"type": "string"}}, "required": ["city"]}'));
 */
export func tool(name as string, description as string, schema as json.Value) {
    if (not regex.matches(FUNCTION_NAME, $name)) {
        fail("a function name is letters, digits, _ . : and -, starting with a letter or _, at most 128, got " +
            shown($name));
    }
    def d as json.Value init json.map({"name": $name, "description": $description});
    def t as string init json.typeOf($schema);
    if ($t == "map") {
        return json.set($d, "/parameters", $schema);
    }
    if ($t != "null") {
        fail("the parameters of " + shown($name) + " are a " + $t + ", not an object");
    }
    return $d;
}

/**
 * The request offering one more tool. Every declaration goes into one
 * `tools[]` entry, `{"functionDeclarations": [...]}`, created when absent;
 * other tools (such as `{"googleSearch": {}}`) stay.
 *
 * @param req {json.Value} the request
 * @param decl {json.Value} from `tool`
 * @return {json.Value} the request
 * @throws {GeminiError} kind "gemini" when the tool is not an object with a name, or a tool of that name is offered already
 */
export func addTool(req as json.Value, decl as json.Value) {
    return addTools($req, [$decl]);
}

/**
 * The request offering several more tools, in order, as `addTool` does.
 *
 * @param req {json.Value} the request
 * @param decls {list of json.Value} from `tool`
 * @return {json.Value} the request
 * @throws {GeminiError} kind "gemini" as `addTool`
 */
export func addTools(req as json.Value, decls as list of json.Value) {
    requestModel($req);
    if (json.typeOf($req, "/tools") != "list") {
        $req = json.set($req, "/tools", json.list());
    }
    def at as int init -1;
    for (def i in 0..json.length($req, "/tools")) {
        if (json.typeOf($req, "/tools/" + convert.toString($i) + "/functionDeclarations") == "list") {
            $at = $i;
            break;
        }
    }
    if ($at < 0) {
        $at = json.length($req, "/tools");
        $req = json.append($req, "/tools", json.map({"functionDeclarations": json.list()}));
    }
    def ptr as string init "/tools/" + convert.toString($at) + "/functionDeclarations";
    def names as list of string init [];
    for (def i in 0..json.length($req, $ptr)) {
        $names[] = textAt($req, $ptr + "/" + convert.toString($i) + "/name");
    }
    for (def d in $decls) {
        if (json.typeOf($d, "/name") != "string") {
            fail("a tool is an object with a name: build it with tool");
        }
        def name as string init json.asString($d, "/name");
        if (lists.contains($names, $name)) {
            fail("a tool named " + shown($name) + " is offered already");
        }
        $names[] = $name;
        $req = json.append($req, $ptr, $d);
    }
    return $req;
}

/**
 * A result telling the model its function call failed, for a handler to
 * return instead of throwing: the loop goes on and the model can try
 * something else. A handler that throws ends `runTools` with its error.
 *
 * @param message {string} what went wrong, for the model to read
 * @return {json.Value} `{"error": message}`, sent as the `functionResponse`'s `response`
 * @example
 *   return gemini.toolError("no such city: " + json.asString($input, "/city"));
 */
export func toolError(message as string) {
    return json.map({"error": $message});
}

/**
 * The request with a function-calling mode: `AUTO` (the model chooses),
 * `ANY` (it must call one), `NONE` (it may not), `VALIDATED` (calls or text,
 * schema-checked).
 *
 * @param req {json.Value} the request
 * @param mode {string} one of `TOOL_MODES`
 * @param allowed {list of string} with `ANY` or `VALIDATED`, the only functions it may call; empty for all
 * @return {json.Value} the request
 * @throws {GeminiError} kind "gemini" when the mode is not one of them
 */
export func withToolMode(req as json.Value, mode as string, allowed as list of string) {
    requestModel($req);
    if (not lists.contains(TOOL_MODES, $mode)) {
        fail("a tool mode is AUTO, ANY, NONE or VALIDATED, got " + shown($mode));
    }
    def config as json.Value init json.map({"mode": $mode});
    if (len($allowed) > 0) {
        $config = json.set($config, "/allowedFunctionNames", json.list($allowed));
    }
    return json.set($req, "/toolConfig", json.map({"functionCallingConfig": $config}));
}

/**
 * The functions the first candidate asks to call, in order: several when
 * the model calls them in parallel.
 *
 * @param reply {json.Value} a reply of `chat`
 * @return {list of ToolCall} the calls, empty when there are none
 * @throws {GeminiError} kind "gemini" when a call has no name
 */
export func toolCalls(reply as json.Value) {
    def calls as list of ToolCall init [];
    if (json.typeOf($reply, "/candidates/0/content/parts") != "list") {
        return $calls;
    }
    def parts as json.Value init json.get($reply, "/candidates/0/content/parts");
    for (def i in 0..json.length($parts)) {
        def p as string init "/" + convert.toString($i) + "/functionCall";
        if (json.typeOf($parts, $p) != "map") {
            continue;
        }
        def name as string init textAt($parts, $p + "/name");
        if ($name == "") {
            fail("a function call in the reply has no name");
        }
        def args as json.Value init json.map();
        if (json.typeOf($parts, $p + "/args") == "map") {
            $args = json.get($parts, $p + "/args");
        }
        $calls[] = ToolCall{id: textAt($parts, $p + "/id"), name: $name, input: $args};
    }
    return $calls;
}

/**
 * A `functionResponse` part.
 *
 * @param call {ToolCall} the call answered
 * @param result {json.Value} the result; anything but an object is sent as `{"result": ...}`
 * @return {json.Value} the part
 */
func responsePart(call as ToolCall, result as json.Value) {
    def body as json.Value init $result;
    if (json.typeOf($body) != "map") {
        $body = json.map({"result": $result});
    }
    def fr as json.Value init json.map();
    if ($call.id != "") {
        $fr = json.set($fr, "/id", $call.id);
    }
    $fr = json.set($fr, "/name", $call.name);
    $fr = json.set($fr, "/response", $body);
    return json.map({"functionResponse": $fr});
}

/**
 * The request with the results of function calls as one user turn, in the
 * calls' order, each with its call's id. Add the reply that made the calls
 * first (`addReply`): the API wants every call of a turn, then every
 * result.
 *
 * @param req {json.Value} the request
 * @param calls {list of ToolCall} the calls, from `toolCalls`
 * @param results {list of json.Value} one result per call; an object is sent as is, anything else as `{"result": ...}`
 * @return {json.Value} the request
 * @throws {GeminiError} kind "gemini" when the lists differ in length or are empty
 */
export func addToolResults(
    req as json.Value,
    calls as list of ToolCall,
    results as list of json.Value) {
    if (len($calls) != len($results)) {
        fail(io.sprintf("%d calls but %d results", len($calls), len($results)));
    }
    def parts as list of json.Value init [];
    for (def i in 0..len($calls)) {
        $parts[] = responsePart($calls[$i], $results[$i]);
    }
    return addParts($req, "user", $parts);
}

/**
 * The tool loop: send the request; while the answer calls functions, run
 * each through the handler, add the model's turn as received (with its
 * thought signatures) and every result after it, and send again. It ends
 * at an answer without calls, or a blocked one, or after `maxTurns`
 * replies (`stopped` "maxTurns", the conversation kept). A call whose
 * arguments are over the client's `withMaxToolInput` is answered with a
 * `toolError` without calling the handler.
 *
 * Jennifer has no closures, so the handler is a top-level function and
 * sees only its arguments and the program's top-level names; for other
 * context use `runToolsWith`. A handler that throws ends the loop with its
 * error, unchanged; to let the model recover, return `toolError(message)`
 * instead.
 *
 * @param c {Client} the client
 * @param req {json.Value} the request, with the functions offered (`addTools`)
 * @param handler {func} `func(name as string, input as json.Value)` returning a `json.Value`: the result of calling `name` with `input`
 * @param maxTurns {int} the most replies to ask for, 1 to `MAX_TOOL_TURNS`
 * @return {ToolRun} the last reply, the whole conversation, the turns, calls, summed usage and why it stopped (`stopped` "maxTurns" when the model still called functions after `maxTurns` replies; their results are in `request`)
 * @throws {GeminiError} kind "gemini" when the API refuses a request
 * @example
 *   func tool(name as string, input as json.Value) {
 *       return json.map({"celsius": 21});
 *   }
 *   def run as gemini.ToolRun init gemini.runTools($c, $req, tool, 8);
 *   io.printf("%s\n", gemini.text($run.reply));
 */
export func runTools(c as Client, req as json.Value, handler as func, maxTurns as int) {
    def none as json.Value;
    return toolLoop($c, $req, $handler, false, $none, $maxTurns);
}

/**
 * `runTools` with a context handed to every handler call: what a closure
 * would capture (a database handle as JSON, a user id, settings). The
 * handler cannot change it; keep state that changes in a `kv.Store` or a
 * top-level variable of the program.
 *
 * @param c {Client} the client
 * @param req {json.Value} the request, with the functions offered
 * @param handler {func} `func(name as string, input as json.Value, context as json.Value)` returning a `json.Value`
 * @param context {json.Value} passed to every call
 * @param maxTurns {int} the most replies to ask for, 1 to `MAX_TOOL_TURNS`
 * @return {ToolRun} the last reply, the whole conversation, the turns, calls, summed usage and why it stopped (`stopped` "maxTurns" when the model still called functions after `maxTurns` replies; their results are in `request`)
 * @throws {GeminiError} kind "gemini" when the API refuses a request
 */
export func runToolsWith(
    c as Client,
    req as json.Value,
    handler as func,
    context as json.Value,
    maxTurns as int) {
    return toolLoop($c, $req, $handler, true, $context, $maxTurns);
}

/**
 * Two token counts added up.
 *
 * @param a {Usage} one
 * @param b {Usage} the other
 * @return {Usage} the sum
 */
func addUsage(a as Usage, b as Usage) {
    return Usage{
        inputTokens: $a.inputTokens + $b.inputTokens,
        outputTokens: $a.outputTokens + $b.outputTokens,
        totalTokens: $a.totalTokens + $b.totalTokens,
        cachedTokens: $a.cachedTokens + $b.cachedTokens,
        reasoningTokens: $a.reasoningTokens + $b.reasoningTokens,
        toolUseTokens: $a.toolUseTokens + $b.toolUseTokens
    };
}

/**
 * The tool loop of `runTools` and `runToolsWith`.
 *
 * @param c {Client} the client
 * @param req {json.Value} the request
 * @param handler {func} the handler
 * @param withContext {bool} whether the handler takes the context
 * @param context {json.Value} the context
 * @param maxTurns {int} the most replies
 * @return {ToolRun} the run
 */
func toolLoop(
    c as Client,
    req as json.Value,
    handler as func,
    withContext as bool,
    context as json.Value,
    maxTurns as int) {
    checkRange($maxTurns, 1, MAX_TOOL_TURNS, "the turns");
    requestModel($req);
    def ran as int init 0;
    def total as Usage init Usage{
        inputTokens: 0,
        outputTokens: 0,
        totalTokens: 0,
        cachedTokens: 0,
        reasoningTokens: 0,
        toolUseTokens: 0
    };
    for (def turn in 1..$maxTurns + 1) {
        def reply as json.Value init chat($c, $req);
        $total = addUsage($total, usage($reply));
        if (json.typeOf($reply, "/candidates/0/content/parts") != "list") {
            return ToolRun{
                reply: $reply,
                request: $req,
                turns: $turn,
                calls: $ran,
                usage: $total,
                stopped: ""
            };
        }
        $req = addReply($req, $reply);
        def calls as list of ToolCall init toolCalls($reply);
        if (len($calls) == 0 or blockReason($reply) != "") {
            return ToolRun{
                reply: $reply,
                request: $req,
                turns: $turn,
                calls: $ran,
                usage: $total,
                stopped: ""
            };
        }
        def results as list of json.Value init [];
        for (def call in $calls) {
            def size as int init encoding.lenBytes(json.encode($call.input));
            if ($size > $c.maxToolInput) {
                $results[] = toolError(io.sprintf(
                    "the input is over %d bytes; call the tool again with a smaller input",
                    $c.maxToolInput));
                continue;
            }
            def out as json.Value;
            if ($withContext) {
                $out = $handler($call.name, $call.input, $context);
            } else {
                $out = $handler($call.name, $call.input);
            }
            $results[] = $out;
            $ran = $ran + 1;
        }
        $req = addToolResults($req, $calls, $results);
        if ($turn == $maxTurns) {
            return ToolRun{
                reply: $reply,
                request: $req,
                turns: $turn,
                calls: $ran,
                usage: $total,
                stopped: "maxTurns"
            };
        }
    }
    fail("runTools: the loop ended without a reply");
}
