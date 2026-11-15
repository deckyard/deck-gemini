<!-- SPDX-License-Identifier: LGPL-3.0-only -->
<!-- SPDX-FileCopyrightText: Copyright (C) 2026 mplx <mplx@jennifer-lang.dev> -->

# Function calling

The model can ask the program to run functions. Declare them with a JSON
schema of their parameters (`tool`), offer them with `addTool` or
`addTools`, and either run
the loop yourself (`toolCalls`, `addReply`, `addToolResults`) or let
`runTools` do it.

## Declaring functions

```jennifer
import "@deckyard/gemini/" as gemini;
use io;
use json;
use os;

def city as json.Value init json.decode('{"type": "object", "properties": {"city": {"type": "string", "description": "a city name"}}, "required": ["city"]}');
def tools as list of json.Value init [
    gemini.tool("getWeather", "The weather in a city now.", $city),
    gemini.tool("now", "The current time, UTC.", json.decode("null"))
];
def req as json.Value init gemini.newRequest("gemini-3.8-flash");
$req = gemini.addTools($req, $tools);
$req = gemini.addUserText($req, "Is it warmer in Paris or in London?");
```

Every declaration goes into one `tools[]` entry, `{"functionDeclarations":
[...]}`; other tools there (such as `{"googleSearch": {}}`, set with
`json.set`) stay, and a second tool of the same name is refused. There is
no `withStrict`, unlike the openai and anthropic decks: Gemini has no
strict mode for function schemas (an OpenAPI subset that steers the
model); `withToolMode` with `VALIDATED` is the closest it offers.
`withToolMode(req, mode, allowed)` sets `toolConfig`: `AUTO` (the model
decides), `ANY` (it must call one, of `allowed` when given), `NONE`, or
`VALIDATED`.

## The tool loop

`runTools(c, req, handler, maxTurns)` sends the request; while the answer
calls functions, it runs each through the handler, adds the model's turn
and the results, and sends again, until an answer calls none (or is
blocked). The handler is a top-level function taking the function's name
and its arguments, returning the result as a `json.Value`:

```jennifer
func runTool(name as string, input as json.Value) {
    if ($name == "getWeather") {
        return json.map({"city": json.asString($input, "/city"), "celsius": 21});
    }
    if ($name == "now") {
        return json.decode('"12:00"');
    }
    return gemini.toolError("no such function: " + $name);
}

def run as gemini.ToolRun init gemini.runTools($c, $req, runTool, 10);
io.printf("%s\n(%d turns, %d calls, %d tokens)\n", gemini.text($run.reply), $run.turns, $run.calls, $run.usage.totalTokens);
$req = gemini.addUserText($run.request, "And in Rome?");
```

A result that is an object is sent as the `response`; anything else is
wrapped as `{"result": ...}`. A handler that throws ends the loop, and its
error reaches the caller unchanged; to let the model try something else,
return `toolError(message)` instead (`{"error": message}`).
`ToolRun.request` is the whole conversation, the last answer included,
ready for the next user turn; `calls` counts the function calls run and
`usage` sums every reply's token counts.

The loop does not throw when it runs out of turns. After `maxTurns`
replies that still call functions it runs those calls, adds their results
to `ToolRun.request` and returns with `stopped` set to `"maxTurns"` (`""`
when the model finished). Nothing is lost: `chat` or `runTools` the
request as it is to go on.

```jennifer
def run as gemini.ToolRun init gemini.runTools($c, $req, runTool, 4);
# at most three more rounds of 4 turns
for (def round in 0..3) {
    if ($run.stopped != "maxTurns") {
        break;
    }
    $run = gemini.runTools($c, $run.request, runTool, 4);
}
```

The model's arguments arrive parsed in the reply. A call whose arguments
are over the client's cap (`withMaxToolInput(c, bytes)`, measured as
JSON, 1 MiB by default) is not handed to the handler: the model gets
`toolError("the input is over <m> bytes; call the tool again with a
smaller input")` instead and can try again.

## Passing context to a handler

Jennifer has no closures, so a handler sees only its arguments and the
program's top-level names. Three ways to give it more:

- `runToolsWith(c, req, handler, context, maxTurns)` hands one `json.Value`
  to every call as a third argument: a user id, settings, a connection
  string. The handler cannot change it.

  ```jennifer
  func scopedTool(name as string, input as json.Value, context as json.Value) {
      return json.map({"user": json.asString($context, "/user"), "name": $name});
  }

  def run as gemini.ToolRun init gemini.runToolsWith($c, $req, scopedTool, json.map({"user": "ada"}), 10);
  ```

- A top-level `def` of the program the handler is written in: it may read
  and write it (the handler runs in the caller's task, one call at a
  time).
- A `kv.Store` for state shared with `spawn`ed tasks.

## Thought signatures and parallel calls

Gemini 3 and later return a `thoughtSignature` with a function call and
refuse the next request (400) when it is missing. With calls in parallel
only the first carries one; the API wants every call of a turn, then every
result, in that order. The loop (and `addReply` + `addToolResults`, doing
it by hand) keeps both rules: the model's turn goes back exactly as
received, with its thought parts and signatures, and the results follow as
one user turn, in the calls' order, each with its call's `id`.

```jennifer
def reply as json.Value init gemini.chat($c, $req);
def calls as list of gemini.ToolCall init gemini.toolCalls($reply);
if (len($calls) > 0) {
    def results as list of json.Value init [];
    for (def call in $calls) {
        $results[] = runTool($call.name, $call.input);
    }
    $req = gemini.addToolResults(gemini.addReply($req, $reply), $calls, $results);
    $reply = gemini.chat($c, $req);
}
```

Do not build model turns that call functions by hand: they have no
signature. Tool schemas are JSON Schemas, so the `jsonschema` deck can
check `input` before a handler acts on it.
