# SPDX-License-Identifier: LGPL-3.0-only
# SPDX-FileCopyrightText: Copyright (C) 2026 mplx <mplx@jennifer-lang.dev>
# pragma-jennifer-version: >=0.28.0
# pragma-jennifer-capability: net

/**
 * A client for the Google Gemini API as Google AI Studio serves it
 * (`generativelanguage.googleapis.com/v1beta`), over HTTPS with an API key
 * in the `x-goog-api-key` header: generate content from text and media,
 * with a system instruction, function calling and a tool loop, structured
 * output, thinking and safety settings; count tokens; embeddings; list
 * models; upload media through the Files API; context caching. `call`
 * reaches any other endpoint.
 *
 * Requests and replies are `json.Value` documents in Google's own shape,
 * so every field the API knows can be set and read. The builders
 * (`newRequest`, `addUserText`, `addTools`, ...) and readers (`text`,
 * `toolCalls`, `usage`, ...) cover the common ones. The model is part of the
 * request (`newRequest(model)`), as in Google's `GenerateContentRequest`.
 *
 * Every request has a deadline and a reply cap. 429 and 5xx answers are
 * retried with backoff, honouring `retry-after` and Google's
 * `RetryInfo.retryDelay`. A request the API refused throws `GeminiError`
 * (kind "gemini") with the HTTP `status`, Google's `googleStatus` (such as
 * `RESOURCE_EXHAUSTED`) and the `ErrorInfo` `reason`; a cap reached is kind
 * "limit", a deadline kind "timeout", a connection closed mid-answer kind
 * "closed", a cancelled task kind "cancelled". A blocked prompt or a reply
 * stopped for safety or recitation is data in the reply (`blockReason`);
 * `text` of such a reply throws `GeminiError` kind "gemini.blocked".
 *
 * | topic | covers |
 * | --- | --- |
 * | `core` | `Client`, settings, the exchange with retries, errors, `call`, models |
 * | `content` | request builders, parts, `chat`, `countTokens`, reply readers |
 * | `tools` | function declarations, `toolCalls`, `runTools` |
 * | `embed` | `embed`, `embedMany` |
 * | `files` | the Files API: resumable upload, get, list, delete, wait |
 * | `caches` | context caching: create, get, list, update the TTL, delete |
 *
 * @module gemini
 * @see https://ai.google.dev/api
 * @example
 *   def c as gemini.Client init gemini.client(os.getEnv("GEMINI_API_KEY"));
 *   def req as json.Value init gemini.addUserText(gemini.newRequest("gemini-3.8-flash"), "Hello!");
 *   io.printf("%s\n", gemini.text(gemini.chat($c, $req)));
 */
use convert;
use encoding;
use io;
use json;
use lists;
use maps;
use math;
use net;
use regex;
use strings;
use task;
use time;

import "http.j" as http;
import "uri.j" as uri;

include "topics/core.j";
include "topics/content.j";
include "topics/tools.j";
include "topics/embed.j";
include "topics/files.j";
include "topics/caches.j";
