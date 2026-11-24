<!-- SPDX-License-Identifier: LGPL-3.0-only -->
<!-- SPDX-FileCopyrightText: Copyright (C) 2026 mplx <mplx@jennifer-lang.dev> -->

# Generating content

`chat(c, req)` sends a request to `models/<model>:generateContent` and
returns Google™'s `GenerateContentResponse` as it came, a `json.Value`. The
builders below write the request; anything they do not cover is set with
`json.set` or `withConfig`.

## A request

```jennifer
import "@deckyard/gemini/" as gemini;
use io;
use json;
use os;

def c as gemini.Client init gemini.client(os.getEnv("GEMINI_API_KEY"));
def req as json.Value init gemini.newRequest("gemini-3.8-flash");
$req = gemini.withSystem($req, "You are a terse physics tutor.");
$req = gemini.addUserText($req, "Why is the sky blue?");
def reply as json.Value init gemini.chat($c, $req);
io.printf("%s\n", gemini.text($reply));
```

A request is a JSON object: `model`, `contents` (the turns, each with a
`role` of `user` or `model` and a list of `parts`), and optionally
`systemInstruction`, `tools`, `toolConfig`, `safetySettings`,
`generationConfig` and `cachedContent`. The builders return the new
value; thread it (`$req = gemini.addUserText($req, ...)`).

| Builder | Writes |
|---|---|
| `newRequest(model)` | `{"model": "models/<id>", "contents": []}` |
| `withSystem(req, text)` | `systemInstruction` |
| `addUserText(req, text)`, `addText(req, role, text)` | a text turn |
| `addParts(req, role, parts)` | a turn of several parts |
| `addReply(req, reply)` | the reply's answer as the model's turn, as received |
| `withConfig(req, name, value)` | any `generationConfig` field |

## Media

Parts are `json.Value`s: `textPart(text)`, `inlinePart(mimeType, data)`
for media sent in the request (base64), and `filePart(mimeType, uri)` for
media uploaded through [Files](files.md) or reachable by URI. Inline media
counts toward the 100 MB a request may take.

```jennifer
use fs;

def photo as bytes init fs.readBytes("cat.jpg");
$req = gemini.addParts(gemini.newRequest("gemini-3.8-flash"), "user", [
    gemini.textPart("What breed is this cat?"),
    gemini.inlinePart("image/jpeg", $photo)
]);
```

## Reading a reply

| Reader | Returns |
|---|---|
| `text(reply)` | the answer's text parts, joined; thought summaries left out |
| `thoughts(reply)` | the thought summaries (`withThoughts`) |
| `textJson(reply)` | the answer parsed as JSON (structured output) |
| `toolCalls(reply)` | the functions the model calls ([Function calling](tools.md)) |
| `finishReason(reply)` | `STOP`, `MAX_TOKENS`, `SAFETY`, `RECITATION`, ... |
| `blockReason(reply)` | why there is no full answer, `""` when there is one |
| `usage(reply)` | `Usage`: input, output, total, cached, reasoning (thinking) and tool tokens |

The readers look at the first candidate; with `candidateCount` above 1,
read `/candidates/<n>` with `json.get`.

## Conversations

A conversation is the request with every turn in it. `addReply` adds the
model's answer exactly as it came, thought parts and `thoughtSignature`s
included (Gemini™ 3 and later want them back), then the next user turn
follows:

```jennifer
$req = gemini.addReply($req, $reply);
$req = gemini.addUserText($req, "And why are sunsets red?");
$reply = gemini.chat($c, $req);
```

## Structured output

`withJsonSchema(req, schema)` asks for JSON matching a JSON Schema: it
sets `responseMimeType` to `application/json` and `responseJsonSchema`.
Google supports a subset of JSON Schema (types, `properties`, `required`,
`enum`, `items`, ...) and ignores the rest. `textJson` reads the answer:

```jennifer
def schema as json.Value init json.decode('{"type": "object", "properties": {"city": {"type": "string"}, "population": {"type": "integer"}}, "required": ["city", "population"]}');
$req = gemini.withJsonSchema(gemini.addUserText(gemini.newRequest("gemini-3.8-flash"), "The largest city in Austria?"), $schema);
def v as json.Value init gemini.textJson(gemini.chat($c, $req));
io.printf("%s: %d\n", json.asString($v, "/city"), json.asInt($v, "/population"));
```

A `MAX_TOKENS` finish cuts the JSON short; `textJson` then throws kind
`"gemini"`. `withJsonSchema` sends the fields Google's SDKs send. The
reference also has a newer form, `responseFormat` (`{"text": {"mimeType":
"APPLICATION_JSON", "schema": ...}}`, used by its REST examples), and the
older `responseSchema` (an OpenAPI-style schema); either can be set with
`withConfig`, and `withJsonSchema` removes both, as they are not sent
together.

## Thinking

Gemini models think before they answer; `generationConfig.thinkingConfig`
steers it:

- `withThinkingLevel(req, level)`: `minimal`, `low`, `medium`, `high` or
  `xhigh` (`THINKING_LEVELS`), for Gemini 3 and later. Each model takes
  some of them (`xhigh` only `gemini-4-hydrogen`); Gemini 4 models cannot
  turn thinking off.
- `withThinkingBudget(req, tokens)`: a token budget, for Gemini 2.5: `-1`
  dynamic, `0` off where the model allows, else up to its maximum (24576
  on 2.5 Flash, 32768 on 2.5 Pro; the deck takes -1 to 32768). Later models map it to the nearest
  level with a warning.
- `withThoughts(req, true)`: return thought summaries, read with
  `thoughts(reply)`.

The API refuses a level and a budget together (400), so each setter
clears the other. Thinking counts toward `maxOutputTokens`; its tokens are
`usage(reply).reasoningTokens`.

## Safety

`withSafety(req, category, threshold)` sets the threshold for one harm
category (`HARM_CATEGORY_HARASSMENT`, `HARM_CATEGORY_HATE_SPEECH`,
`HARM_CATEGORY_SEXUALLY_EXPLICIT`, `HARM_CATEGORY_DANGEROUS_CONTENT`,
`HARM_CATEGORY_CIVIC_INTEGRITY`) to one of `SAFETY_THRESHOLDS`.

A prompt the filters block comes back with no candidates and a
`promptFeedback.blockReason` (`SAFETY`, `BLOCKLIST`, `PROHIBITED_CONTENT`,
`IMAGE_SAFETY`, `OTHER`); an answer the filters stop has a
`finishReason` such as `SAFETY` or `RECITATION` and may hold a partial
text. Both are 200 answers with data a caller may want (ratings,
citations, usage), so `chat` returns them, and the deck makes them
impossible to miss instead of throwing:

```jennifer
def reply as json.Value init gemini.chat($c, $req);
def why as string init gemini.blockReason($reply);
if ($why != "") {
    io.printf("no answer: %s\n", $why);
    io.printf("%s\n", json.encode(json.get($reply, "/promptFeedback")));
} else {
    io.printf("%s\n", gemini.text($reply));
}
```

Code that skips the check still learns of it: `text` and `textJson` throw
`GeminiError` kind `"gemini.blocked"`, `status` 200, `blockReason` the
reason (`googleStatus` `""`), `reason` `PROMPT_BLOCKED` or
`RESPONSE_BLOCKED`. `addReply` refuses a reply without
an answer.

## Counting tokens

`countTokens(c, req)` counts what the request's input would take, its
system instruction, tools and cache included, without generating. After a
call, `usage(reply)` has the real counts.

```jennifer
io.printf("%d tokens\n", gemini.countTokens($c, $req));
```
