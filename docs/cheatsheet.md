<!-- SPDX-License-Identifier: LGPL-3.0-only -->
<!-- SPDX-FileCopyrightText: Copyright (C) 2026 mplx <mplx@jennifer-lang.dev> -->

# gemini cheatsheet

Every export of `@deckyard/gemini`. Guides are listed in
[the introduction](index.md).

```jennifer
import "@deckyard/gemini/" as gemini;
```

A `c` argument is a `Client`; a `req` is a request (`json.Value`) from
`newRequest`; a `reply` is what `chat` returned. A request the API refused
throws `GeminiError` (kind `"gemini"`) with the HTTP `status`, Google's
`googleStatus` and the `ErrorInfo` `reason`; the deck's own refusals are
the same struct with `status` 0. `text` and `textJson` of a reply without an
answer throw `GeminiError` kind `"gemini.blocked"`, its `blockReason` the
reason. A cap is kind `"limit"`, a deadline `"timeout"`, a network failure
`"net"` (a `net.NetError`, passed on as it is), a connection closed
mid-answer `"closed"`, a cancelled task `"cancelled"`.

## Constants

| Constant | Value | Meaning |
|---|---|---|
| `VERSION` | `"0.1.0"` | this deck's version |
| `DEFAULT_BASE_URL` | `"https://generativelanguage.googleapis.com"` | Google AI Studio's server |
| `API_VERSION` | `"v1beta"` | the version every path is below |
| `DEFAULT_TIMEOUT_MS` | `300000` | the deadline of one request |
| `DEFAULT_RETRIES` | `3` | retries of a 408, 409, 429 or 5xx, or a network failure before the request was sent |
| `DEFAULT_BACKOFF_MS` | `1000` | the first retry's wait when the server names none |
| `DEFAULT_MAX_BYTES` | `33554432` | the largest reply |
| `MAX_RETRY_WAIT_MS` | `60000` | a server asking for a longer wait is not retried |
| `MAX_REQUEST_BYTES` | `100000000` | the largest JSON request |
| `DEFAULT_MAX_TOOL_INPUT` | `1048576` | the largest arguments of a call handed to a tool handler, as JSON |
| `MAX_PAGES` | `100` | the most pages a listing reads; together they are under the reply cap |
| `BLOCKED_FINISH_REASONS` | `["SAFETY", "RECITATION", "LANGUAGE", "BLOCKLIST", "PROHIBITED_CONTENT", "SPII", "IMAGE_SAFETY", "IMAGE_PROHIBITED_CONTENT", "IMAGE_RECITATION"]` | finish reasons that mean no full answer |
| `THINKING_LEVELS` | `["minimal", "low", "medium", "high", "xhigh"]` | what `withThinkingLevel` takes |
| `SAFETY_THRESHOLDS` | `["BLOCK_NONE", "BLOCK_ONLY_HIGH", "BLOCK_MEDIUM_AND_ABOVE", "BLOCK_LOW_AND_ABOVE", "OFF"]` | what `withSafety` takes |
| `MAX_TOOL_TURNS` | `100` | the most replies `runTools` asks for |
| `TOOL_MODES` | `["AUTO", "ANY", "NONE", "VALIDATED"]` | what `withToolMode` takes |
| `MAX_EMBED_BATCH` | `100` | texts per `batchEmbedContents` request |
| `MAX_FILE_BYTES` | `2000000000` | the largest upload, Google's 2 GB |
| `MAX_FILE_PAGES` | `1000` | the most pages `files` reads (100 files each) |
| `MAX_CACHE_TTL_SECONDS` | `31536000` | the longest cache TTL |

## The client

| Function | Returns | Does |
|---|---|---|
| `client(apiKey)` | `Client` | a client for Google AI Studio with an API key, sent in `x-goog-api-key` |
| `withBaseUrl(c, baseUrl)` | `Client` | another server serving the same API (a proxy, a fake) |
| `withTls(c, tls)` | `Client` | certificate options (`caCert`, `skipVerify`) |
| `withPlainHttp(c)` | `Client` | allow plain http to another machine |
| `withTimeout(c, ms)` | `Client` | the deadline of one attempt, 1000 to 3600000 ms |
| `withRetries(c, n)` | `Client` | retries of a 408, 409, 429 or 5xx, or a network failure before the request was sent (`NetError.sent` false), 0 to 10; nothing sent in full is sent again |
| `withBackoff(c, ms)` | `Client` | the first retry's wait when the server names none, 0 to 60000 ms |
| `withMaxBytes(c, most)` | `Client` | the largest reply, 65536 to 1073741824 bytes |
| `withMaxToolInput(c, most)` | `Client` | the largest arguments of a call the tool loop hands to a handler, 1024 to 1073741824 bytes as JSON; larger is answered with a `toolError` |
| `withUploadTimeout(c, ms)` | `Client` | the deadline of an upload's data step, 1000 to 86400000 ms (default 5 min plus 1 min per 100 MB) |
| `models(c)` | `list of ModelInfo` | every model the key may use, all pages |
| `model(c, name)` | `ModelInfo` | one model |
| `call(c, method, path, body)` | `json.Value` | any other request below `/v1beta`; a query goes in `path`, encoded by the caller |

## Requests

| Function | Returns | Does |
|---|---|---|
| `newRequest(model)` | `json.Value` | `{"model": "models/<id>", "contents": []}` |
| `withSystem(req, text)` | `json.Value` | the system instruction |
| `textPart(text)` | `json.Value` | a text part |
| `inlinePart(mimeType, data)` | `json.Value` | media in the request, base64 |
| `filePart(mimeType, uri)` | `json.Value` | media by URI (an uploaded file's `uri`) |
| `addParts(req, role, parts)` | `json.Value` | a turn of parts, role `user` or `model` |
| `addText(req, role, text)` | `json.Value` | a text turn |
| `addUserText(req, text)` | `json.Value` | a user text turn |
| `addReply(req, reply)` | `json.Value` | the reply's answer as the model's turn, signatures kept |
| `withConfig(req, name, value)` | `json.Value` | a `generationConfig` field |
| `withJsonSchema(req, schema)` | `json.Value` | JSON output matching a JSON Schema |
| `withThinkingLevel(req, level)` | `json.Value` | a thinking level; clears a budget |
| `withThinkingBudget(req, tokens)` | `json.Value` | a thinking budget, -1 to 32768; clears a level |
| `withThoughts(req, wanted)` | `json.Value` | ask for thought summaries |
| `withSafety(req, category, threshold)` | `json.Value` | a safety threshold for a harm category |
| `withCachedContent(req, name)` | `json.Value` | read the prefix from a cache |

## Generating and reading

| Function | Returns | Does |
|---|---|---|
| `chat(c, req)` | `json.Value` | `generateContent`: the reply as Google sent it |
| `countTokens(c, req)` | `int` | the tokens the request's input takes |
| `text(reply)` | `string` | the answer's text; throws `"gemini.blocked"` without an answer |
| `thoughts(reply)` | `string` | the thought summaries |
| `textJson(reply)` | `json.Value` | the answer parsed as JSON |
| `finishReason(reply)` | `string` | why the first candidate stopped |
| `blockReason(reply)` | `string` | why there is no full answer, `""` when there is one |
| `usage(reply)` | `Usage` | the token counts |

## Function calling

Gemini has no strict mode for tools, so there is no `withStrict` (the
openai and anthropic decks have one): its schemas are an OpenAPI subset
that steers the model, and `withToolMode(req, "VALIDATED", [])` is the
closest it offers. Check arguments before acting on them.

| Function | Returns | Does |
|---|---|---|
| `tool(name, description, schema)` | `json.Value` | a function declaration to offer |
| `addTool(req, decl)` | `json.Value` | offer one more, in the one `functionDeclarations` entry |
| `addTools(req, decls)` | `json.Value` | offer several more |
| `toolError(message)` | `json.Value` | `{"error": message}`, a failed call's result for the model |
| `withToolMode(req, mode, allowed)` | `json.Value` | the function-calling mode |
| `toolCalls(reply)` | `list of ToolCall` | the functions the answer calls, in order |
| `addToolResults(req, calls, results)` | `json.Value` | the results as one user turn, ids kept |
| `runTools(c, req, handler, maxTurns)` | `ToolRun` | the tool loop; `handler(name, input)` returns a `json.Value`; a throw ends it unchanged; out of turns it returns with `stopped` `"maxTurns"` |
| `runToolsWith(c, req, handler, context, maxTurns)` | `ToolRun` | the tool loop; `handler(name, input, context)` |

## Embeddings

| Function | Returns | Does |
|---|---|---|
| `embed(c, model, text, taskType, dimensions)` | `list of float` | one text's embedding; `dimensions` 128 to 3072, or 0 for the model's own |
| `embedMany(c, model, texts, taskType, dimensions)` | `list of list of float` | many, in batches of `MAX_EMBED_BATCH` |

## Files

| Function | Returns | Does |
|---|---|---|
| `uploadFile(c, data, mimeType, displayName)` | `FileInfo` | a resumable upload |
| `file(c, name)` | `FileInfo` | one file |
| `files(c)` | `list of FileInfo` | every file, all pages |
| `deleteFile(c, name)` | `null` | delete a file |
| `waitForFile(c, name, timeoutMs)` | `FileInfo` | poll until `ACTIVE` |

## Context caching

| Function | Returns | Does |
|---|---|---|
| `createCache(c, req, ttlSeconds, displayName)` | `CacheInfo` | cache a request's prefix |
| `cache(c, name)` | `CacheInfo` | one cache |
| `caches(c)` | `list of CacheInfo` | every cache, all pages |
| `updateCacheTtl(c, name, ttlSeconds)` | `CacheInfo` | a new TTL from now (`updateMask=ttl`) |
| `deleteCache(c, name)` | `null` | delete a cache |

## Structs

### `Client`

| Field | Meaning |
|---|---|
| `apiKey as string` | the key; do not print a client |
| `baseUrl as string` | the server, without the API version |
| `tls as http.TlsOptions` | certificate checks for https |
| `allowPlainHttp as bool` | plain http to another machine allowed |
| `timeoutMs as int` | the deadline of one attempt |
| `retries as int` | retries of a 408, 409, 429 or 5xx, or a network failure before the request was sent |
| `backoffMs as int` | the first retry's wait when the server names none |
| `maxBytes as int` | the largest reply |
| `maxToolInput as int` | the largest arguments handed to a tool handler, bytes as JSON |
| `uploadTimeoutMs as int` | the deadline of an upload's data step; 0 for 5 min plus 1 min per 100 MB |

### `GeminiError`

| Field | Meaning |
|---|---|
| `kind as string` | `"gemini"` or `"gemini.blocked"` |
| `message as string` | what happened, never the key |
| `status as int` | the HTTP status; 0 without an answer; 200 when blocked |
| `googleStatus as string` | Google's error status name (`RESOURCE_EXHAUSTED`, ...); `""` for a block |
| `blockReason as string` | for kind `"gemini.blocked"`, the block or finish reason (`SAFETY`, `RECITATION`, ...) |
| `reason as string` | the `ErrorInfo` reason (`API_KEY_INVALID`, ...), or `PROMPT_BLOCKED` / `RESPONSE_BLOCKED` |
| `retryAfterMs as int` | the wait the server asked for (`retry-after-ms`, `retry-after`, `RetryInfo`), at most 1e12, 0 when none |
| `limits as map of string to string` | the answer's rate-limit headers, names lower-cased (`x-ratelimit-*`, `retry-after`, `retry-after-ms`), at most 32 |

### `ModelInfo`

| Field | Meaning |
|---|---|
| `name as string` | `models/<id>` |
| `displayName as string` | the name for people |
| `description as string` | what it is for |
| `version as string` | its version |
| `inputTokenLimit as int` | the most input tokens |
| `outputTokenLimit as int` | the most output tokens |
| `methods as list of string` | the supported methods, such as `generateContent` |
| `thinking as bool` | whether it thinks |

### `Usage`

| Field | Meaning |
|---|---|
| `inputTokens as int` | the prompt, cache included (`promptTokenCount`) |
| `outputTokens as int` | the answer (`candidatesTokenCount`) |
| `totalTokens as int` | all of them (summed when the API sends none) |
| `cachedTokens as int` | the part read from a cache |
| `reasoningTokens as int` | the thinking (`thoughtsTokenCount`) |
| `toolUseTokens as int` | built-in tools' results |

### `ToolCall`

| Field | Meaning |
|---|---|
| `id as string` | the call's id, `""` when the model sent none |
| `name as string` | the function |
| `input as json.Value` | the arguments (`args`), an object |

### `ToolRun`

| Field | Meaning |
|---|---|
| `reply as json.Value` | the last reply |
| `request as json.Value` | the whole conversation, ready for the next turn (after `"maxTurns"`, with the last calls' results) |
| `turns as int` | the replies asked for |
| `calls as int` | the function calls the handler ran |
| `usage as Usage` | the token counts of every reply, summed |
| `stopped as string` | `""` when the model finished, `"maxTurns"` when the loop ran out of turns |

### `FileInfo`

| Field | Meaning |
|---|---|
| `name as string` | `files/<id>` |
| `displayName as string` | the name given at upload |
| `mimeType as string` | its MIME type |
| `sizeBytes as int` | its size |
| `uri as string` | for `filePart` |
| `state as string` | `PROCESSING`, `ACTIVE` or `FAILED` |
| `createTime as string` | when it was uploaded |
| `expirationTime as string` | when Google deletes it |
| `sha256Hash as string` | its hash, base64 |
| `errorMessage as string` | why processing failed |

### `CacheInfo`

| Field | Meaning |
|---|---|
| `name as string` | `cachedContents/<id>` |
| `displayName as string` | the name given at creation |
| `model as string` | `models/<id>` |
| `createTime as string` | when it was created |
| `updateTime as string` | when it was last updated |
| `expireTime as string` | when it expires |
| `totalTokens as int` | the tokens it holds |
