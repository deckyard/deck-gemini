<!-- SPDX-License-Identifier: LGPL-3.0-only -->
<!-- SPDX-FileCopyrightText: Copyright (C) 2026 mplx <mplx@jennifer-lang.dev> -->

# Design

## Scope

The deck is a thin client for the Gemini™ API as Google™ AI Studio serves it
(`generativelanguage.googleapis.com/v1beta`, an API key in the
`x-goog-api-key` header). It covers `generateContent` with media, a system
instruction, function calling and a tool loop, structured output, thinking
and safety settings; `countTokens`; embeddings; the model list; the Files
API with its resumable upload; and context caching. `call` reaches any other
endpoint with the same deadline, cap and retries.

It is one of three LLM decks (`openai`, `anthropic`, `gemini`), one per
vendor API rather than one generic client: the wire formats differ in every
part a client touches (roles and `parts`, `systemInstruction`,
`functionCall` arguments as objects, thought signatures, Google's error
body), and a common layer would hide what each vendor does well. A
provider-neutral facade is planned as its own deck over the three.

Out of scope, on purpose:

- **Streaming** (`streamGenerateContent`): `http` cannot read a response
  incrementally yet.
- **Vertex AI™**: OAuth tokens, regional endpoints and Cloud Storage URIs
  make it a client variant for later; requests, replies and errors keep
  their shape there.
- **The Interactions API, the Live API, the Batch API and file search
  stores**: the plain HTTP ones are reachable with `call`.
- **Multimodal embeddings**: `embed` sends text; other parts go through
  `call`.
- **Google's OpenAI-compatible endpoint**: the `openai` deck reaches it by
  base URL; this deck exists for what that endpoint leaves out (files,
  caching, thought signatures, safety feedback).

## Decisions

- **Requests and replies are `json.Value`** in Google's own shape. Builders
  (`newRequest`, `withSystem`, `addUserText`, `addTools`, ...) and readers
  (`text`, `toolCalls`, `usage`, `blockReason`, ...) cover the common
  fields; `json.set` and `withConfig` reach the rest. Nothing the API knows
  is out of reach, and nothing is translated.
- **The model is part of the request**: `newRequest(model)` writes
  `"model": "models/<id>"`, as Google's `GenerateContentRequest` does, so one
  value carries a whole call (`chat`, `countTokens`, a cache, the tool loop)
  and a whole conversation. `chat` moves it into the path.
- **A shared surface with the openai and anthropic decks**, aligned in
  several rounds: `newRequest`, `withSystem`, `addUserText`, `addReply`,
  `tool` / `addTool` / `addTools`, `toolError`, `runTools` /
  `runToolsWith`, `ToolRun`, `ToolCall{id, name, input}`, the `Usage` core
  (`inputTokens` with the cache included, `outputTokens`, `totalTokens`,
  `cachedTokens`, `reasoningTokens`; gemini adds `toolUseTokens`),
  `call(c, method, path, body)` with the query in `path`, one retry rule,
  `withMaxToolInput`, and errors with `status`, `retryAfterMs` and `limits`.
  Gemini has no strict mode for function schemas, so there is no
  `withStrict`.
- **Tools**: every declaration goes into one `tools[]` entry with
  `functionDeclarations`; other tools such as `googleSearch` stay, and a
  repeated name is refused. A handler that throws ends the loop with its
  error unchanged; `toolError(message)` gives the model an error result to
  recover from instead. A call whose arguments encode to more than
  `withMaxToolInput` (1 MiB by default) is answered with a `toolError`
  without calling the handler.
- **The tool loop does not lose the conversation.** After `maxTurns`
  replies that still call functions it runs those calls, adds their
  results and returns with `ToolRun.stopped` set to `"maxTurns"`; the
  `request` it returns can be sent again as it is.
- **Thought signatures**: `addReply` and the loop add the model's turn
  exactly as received (thought parts and `thoughtSignature`s), then every
  `functionResponse` as one user turn in call order with its call `id`.
  That satisfies Google's two rules: the first parallel call's signature
  must come back, and all results follow all calls.
- **Structured output**: `withJsonSchema` sends `responseMimeType` and
  `responseJsonSchema`, the fields Google's SDKs send, and removes a
  `responseSchema` or the newer `responseFormat`, since they are not sent
  together.
- **Thinking**: `withThinkingLevel` (Gemini 3 and later, sent as the
  reference's uppercase enum) and `withThinkingBudget` (Gemini 2.5, -1 to
  32768) each clear the other, as the API refuses both together.
- **Safety is data.** A blocked prompt or a finish reason in
  `BLOCKED_FINISH_REASONS` is a 200 reply with ratings, citations and usage,
  so `chat` and `runTools` return it and `blockReason` names it. `text` and
  `textJson` throw kind `"gemini.blocked"` so that code skipping the check
  still learns of it. The openai and anthropic decks only report a refusal.
- **Retries** are the deck's own loop: a 408, 409, 429 or 5xx answer, and a
  network failure before the whole request was sent (a `net.NetError` with
  `sent` false: refused, unreachable, a failed lookup or handshake, a reset
  while writing). Once a request was sent in full it is never sent again,
  whatever the method, since the server may have acted on it. Every method
  is retried otherwise, `generateContent` too (Google bills only answered
  requests). The wait is `retry-after-ms`, else `retry-after` (seconds or
  an HTTP date), or `RetryInfo.retryDelay`, whichever is longer; a wait
  over `MAX_RETRY_WAIT_MS` (a daily quota) is not taken and the error
  carries it.
- **Uploads** follow Google's resumable protocol: a start request with the
  key, then one `upload, finalize` request of the raw bytes to the
  `x-goog-upload-url`, without the key. The data step is not retried and
  has its own deadline (`withUploadTimeout`; by default 5 minutes plus 1
  minute per 100 MB).
- **Context caches**: `updateCacheTtl` sends `updateMask=ttl`, the only
  field the API lets change.

## Errors

One struct, `GeminiError{kind, message, status, googleStatus, reason,
blockReason, retryAfterMs, limits}`, serves two kinds:

- `"gemini"`: a request the API refused (`status` its HTTP status,
  `googleStatus` Google's `error.status`, `reason` the `ErrorInfo` reason),
  or one the deck refused or whose answer was malformed (`status` 0).
- `"gemini.blocked"`: `text` or `textJson` of a reply without an answer;
  `status` 200, `blockReason` the block or finish reason, `reason`
  `PROMPT_BLOCKED` or `RESPONSE_BLOCKED`, `googleStatus` empty.

`retryAfterMs` is the wait the server named (0 when none, at most 1e12);
`limits` holds the answer's rate-limit headers with lower-case names, at
most 32. Generic kinds pass through unchanged: `"limit"` (the reply cap,
the 100 MB request, page caps, `json`'s decoder caps), `"timeout"`, `"net"`
(the `net.NetError` from `http`, with `reason`, `sent` and `replied`),
`"closed"` (an answer broken off mid-way) and `"cancelled"`. Callers match
the kind and read the fields; no code matches a message.

## Security and limits

- The API key travels only in `x-goog-api-key`: never in a URL, and never
  in a message (a server that echoes it has it replaced by `<api key>`).
  Keys, model names, resource ids, MIME types, `call` paths and queries are
  checked against strict forms before anything is sent, so caller input
  cannot inject a path segment, a query, a fragment or a header.
- Plain `http` is refused unless the host is this machine or
  `withPlainHttp` allows it; `withTls` takes a private CA. No request
  follows a redirect.
- The upload URL the server sends must be on the client's own origin, so a
  hostile or broken server cannot send the bytes elsewhere.
- Every attempt has a deadline (`withTimeout`, 5 minutes by default) and
  every reply a cap (`withMaxBytes`, `DEFAULT_MAX_BYTES` 32 MiB). A JSON
  request is at most `MAX_REQUEST_BYTES` (Google's 100 MB), a file at most
  `MAX_FILE_BYTES` (2 GB).
- Listings stop after `MAX_PAGES` pages (`MAX_FILE_PAGES` for files), and
  all pages of one listing together stay under the reply cap. The tool loop
  stops at `MAX_TOOL_TURNS`. Server text in a message is cleaned of
  control and bidi characters and cut short.
- Hostile replies were tried: oversized and endless bodies, slow drips,
  a negative `Content-Length`, a redirect to another host, a gzip body,
  endless page tokens, a huge `retry-after`, an upload URL on another host.
  Each ends with `"limit"`, `"timeout"`, `"net"` or `"gemini"`.

## Testing and validation

The suite runs offline against loopback fakes written in Jennifer: an
`httpd` fake that replays answers in the shapes of Google's API reference
and records what it got (key, upload headers, body), and a raw `net` fake
for connections that are refused, closed before any byte, reset with
`net.abort` before the request was read or after part of an answer, or
broken off mid-answer. The examples were run against a local fake. No
fixture came from a live call: no API key was available, and one live call
remains to be made. The vendor reference was checked on 2026-11-14 and 15
(generate-content, structured output, thinking, thought signatures, files,
caching, embeddings, the model list).

## Known limitations and open questions

- A file is uploaded from memory, about three times its size at peak, until
  `http` streams request bodies.
- `embedMany` returns every vector at once, and a `list of float` costs
  several hundred bytes per number, so a large corpus is embedded in
  slices.
- `updateCacheTtl`'s `updateMask` and `embedContent`'s request body could
  not be checked against a live server; the reference pages give no
  example.
- `uploadFile` takes the media as `bytes`; there is no upload from a path.

## Dependencies on the interpreter

- A thrown module struct keeping its identity (M28.56), so a caught
  `GeminiError` can be declared as such.
- Transport errors as `net.NetError` with `sent` and `replied` (M28.65),
  which the retry rule is keyed on, and `net.abort` for the tests (M28.71).
- `json`'s decoder caps throwing `"limit"` (M28.68).
- Later: streaming responses (M30.9), bulk number reads from `json`
  (M29.8), streaming request bodies (M30.10) and a smaller `Value`
  (M29.11) would lift the limitations above.
