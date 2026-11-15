<!-- SPDX-License-Identifier: LGPL-3.0-only -->
<!-- SPDX-FileCopyrightText: Copyright (C) 2026 mplx <mplx@jennifer-lang.dev> -->

# @deckyard/gemini

A client for the [Google Gemini API](https://ai.google.dev/api) as Google
AI Studio serves it (`generativelanguage.googleapis.com/v1beta`), over raw
HTTPS. It generates content from text and media, with a system
instruction, function calling and a tool loop, structured output, thinking
and safety settings; counts tokens; makes embeddings; lists models;
uploads media through the Files API; and manages context caches. `call`
reaches every other endpoint.

- [Generating content](generating.md): requests, media, conversations,
  structured output, thinking, safety, token counts.
- [Function calling](tools.md): declarations, the tool loop, thought
  signatures, passing context to a handler.
- [Embeddings](embeddings.md): one text or many.
- [Files](files.md): uploading media too large to inline.
- [Context caching](caching.md): caching a long prefix once.
- [Cheatsheet](cheatsheet.md): every export.

The deck is one of three thin LLM clients (`openai`, `anthropic`,
`gemini`) with the same shape: `chat(client, request) -> json.Value` over
a request built with `json`, one error struct per vendor, and a tool loop
that runs each requested function through a `func` value. It does not hide
the vendor: requests and replies are Google's own JSON, so every field the
API knows can be set (`json.set`, `withConfig`) and read (`json.get`).
Google also serves an OpenAI-compatible endpoint (`.../v1beta/openai/`),
which the `openai` deck reaches by base URL; this deck is for what that
endpoint leaves out (files, caching, thought signatures, safety feedback).

## Conventions

Snippets assume this import:

```jennifer
import "@deckyard/gemini/" as gemini;
```

## The client

`client(apiKey)` takes an AI Studio API key, sent in the `x-goog-api-key`
header on every request, never in the URL (`?key=`) and never in an error
message: a server that echoes it has it replaced by `<api key>`. The
free tier needs no billing account; it answers over its rate limits with
`429 RESOURCE_EXHAUSTED`, which the client retries.

```jennifer
use os;
use json;
use io;

def c as gemini.Client init gemini.client(os.getEnv("GEMINI_API_KEY"));
$c = gemini.withTimeout($c, 600000);     # a long generation: 10 minutes
$c = gemini.withRetries($c, 5);
def req as json.Value init gemini.addUserText(gemini.newRequest("gemini-3.8-flash"), "Hello!");
io.printf("%s\n", gemini.text(gemini.chat($c, $req)));
```

| Setting | Default | Range |
|---|---|---|
| `withTimeout(c, ms)` | 300000 ms per attempt | 1000 to 3600000 |
| `withRetries(c, n)` | 3 retries of a 408, 409, 429 or 5xx, or a network failure before the request was sent | 0 to 10 |
| `withBackoff(c, ms)` | 1000 ms, doubled per retry, at most 30 s | 0 to 60000 |
| `withMaxBytes(c, most)` | 32 MiB per reply | 64 KiB to 1 GiB |
| `withBaseUrl(c, url)` | `https://generativelanguage.googleapis.com` | any http(s) URL |
| `withTls(c, tls)` | full certificate checks | `caCert`, `skipVerify` |
| `withPlainHttp(c)` | plain http only to this machine | |
| `withMaxToolInput(c, most)` | 1 MiB of arguments per tool call | 1024 to 1073741824 |
| `withUploadTimeout(c, ms)` | 5 min plus 1 min per 100 MB | 1000 to 86400000 |

A 408, 409, 429 or 5xx answer is retried, and so is a network failure
(kind `"net"`, a `net.NetError`) before the whole request was sent: a
refused connection, a failed lookup or TLS handshake, a reset while
sending (`sent` false). Once the request was sent in full nothing is sent
again, whatever the method: a reset or a close before or during the
answer (`sent` true) and an answer broken off mid-way (kind `"closed"`)
may come after the server acted on it. A retry waits what the
server asked for: the `retry-after-ms` header, else `retry-after` (seconds
or an HTTP date), or the `retryDelay` of a `google.rpc.RetryInfo` in the
error, whichever is longer. Otherwise it backs off from `withBackoff`,
with up to a quarter more at random. A server asking for more than a
minute (a daily quota) is not retried: the error's `retryAfterMs` says how
long, and its `limits` holds the rate-limit headers. Every method is
retried, `generateContent` too; Google bills only answered requests. An
upload's data step is the exception; it has its own deadline
(`withUploadTimeout`).

Every request has a deadline and every reply a cap; a request body is at
most 100 MB, Google's own limit (larger media goes through
[Files](files.md)). `withBaseUrl` points the client at a proxy or gateway
serving the same API; plain `http` is refused there unless the host is
this machine (`127.0.0.1`, `localhost`, `[::1]`) or `withPlainHttp` allows
it, since the key would cross the network in clear.

## Models

The model is part of the request: `newRequest("gemini-3.8-flash")` puts
`"model": "models/gemini-3.8-flash"` in it, as in Google's own
`GenerateContentRequest`, and `chat` moves it into the URL. One value then
carries everything a call needs, so `chat`, `countTokens`, `createCache`
and `runTools` take it whole, and a conversation is one value to keep.

Model names change often; list what the key may use with `models`:

```jennifer
for (def m in gemini.models($c)) {
    io.printf("%s in %d out %d %v\n", $m.name, $m.inputTokenLimit, $m.outputTokenLimit, $m.methods);
}
```

In November 2026 Google lists, among others, `gemini-4-carbon`,
`gemini-4-argon`, `gemini-4-hydrogen`, `gemini-3.8-flash`,
`gemini-3.6-flash`, `gemini-3.5-flash-lite` and `gemini-3.1-flash-lite`
for generation, and `gemini-embedding-2` (multimodal) and
`gemini-embedding-001` (text, with task types) for embeddings. The
`gemini-2.5-flash` and `gemini-2.5-pro` are deprecated (from 1 December
2026 their requests go to `gemini-3.5-flash-lite` and `gemini-3.8-flash`). Aliases such as `gemini-flash-latest`
follow the newest model.

## Errors

| Kind | Struct | When |
|---|---|---|
| `"gemini"` | `GeminiError` | the API refused a request (`status` its HTTP status), or the deck refused an argument or the answer was malformed (`status` 0) |
| `"gemini.blocked"` | `GeminiError` | `text` or `textJson` of a reply without an answer: a blocked prompt or an answer stopped for its content |
| `"limit"` | `Error` | a reply over the cap, a request over 100 MB, more pages than `MAX_PAGES` or pages over the reply cap together (a tool loop out of turns is not one: it returns with `stopped` `"maxTurns"`) |
| `"timeout"` | `Error` | no answer within the deadline, a file still processing |
| `"net"` | `net.NetError` | the network failed: `reason` `refused`, `reset`, `unreachable`, `dns`, `tls`, `closed` or `other`, `sent` and `replied` say how far the exchange got; passed on as it is |
| `"closed"` | `Error` | the server closed the connection mid-answer |
| `"cancelled"` | `Error` | the task running the call was cancelled |

`GeminiError` carries Google's error: `status` (the HTTP status, as in
the openai and anthropic decks), `googleStatus` (`INVALID_ARGUMENT`, `PERMISSION_DENIED`, `NOT_FOUND`,
`RESOURCE_EXHAUSTED`, `INTERNAL`, `UNAVAILABLE`, ...), `reason` (the
`reason` of a `google.rpc.ErrorInfo`, such as `API_KEY_INVALID`) and
`retryAfterMs`, and `limits`, the answer's rate-limit headers with
lower-case names (`x-ratelimit-*`, `retry-after`, `retry-after-ms`;
Google's API sends few of them). Match the kind, then read the fields; never match the
message:

```jennifer
try {
    $reply = gemini.chat($c, $req);
} catch (e) {
    if ($e.kind != "gemini") {
        throw $e;
    }
    def g as gemini.GeminiError init $e;
    if ($g.googleStatus == "RESOURCE_EXHAUSTED") {
        io.printf("over quota; wait %d ms\n", $g.retryAfterMs);
    } elseif ($g.reason == "API_KEY_INVALID") {
        io.printf("check GEMINI_API_KEY\n");
    } else {
        throw $e;
    }
}
```

A blocked prompt (`promptFeedback.blockReason`) or an answer stopped with
`SAFETY`, `RECITATION` or another finish reason in
`BLOCKED_FINISH_REASONS` is **data, not an error**: the API answered 200,
and the reply holds what a caller needs to decide (the safety ratings,
citations, the token usage, a partial answer). `chat` returns it and
`blockReason(reply)` names it. It cannot pass unseen: `text` and
`textJson` throw `GeminiError` kind `"gemini.blocked"` with `status` 200,
`blockReason` the reason (`googleStatus` stays `""`, as no Google error
came) and `reason` `PROMPT_BLOCKED` or `RESPONSE_BLOCKED`. See
[Generating content](generating.md#safety).

## Out of v1

- **Streaming** (`streamGenerateContent`, server-sent events). `http`
  cannot read a response incrementally yet; M30.9 adds that and an `sse`
  module, after which streaming is an addition here.
- **The Interactions API** (`/v1beta/interactions`), Google's newer
  stateful interface, the Live API (WebSockets), the Batch API and file
  search stores. `call` reaches the plain HTTP ones.
- **Vertex AI.** The same models through Google Cloud need another
  configuration: an OAuth bearer token instead of the key (a service
  account's, through `oauthext.googleServiceAccount` with the
  `cloud-platform` scope, refreshed before it expires), regional endpoints
  (`https://<region>-aiplatform.googleapis.com/v1/projects/<project>/locations/<region>/publishers/google/models/<model>:generateContent`),
  `cachedContents` under the project and location, and media from Cloud
  Storage (`gs://` URIs in `fileData`) instead of the Files API. Requests,
  replies and errors keep their shape, so it is a client variant (an auth
  mode and a path builder), planned for later.
- **Multimodal embeddings** of `gemini-embedding-2` (images, audio, video):
  `embed` sends text; send other parts with `call`.
