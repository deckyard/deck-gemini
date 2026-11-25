# SPDX-License-Identifier: LGPL-3.0-only
# SPDX-FileCopyrightText: Copyright (C) 2026 mplx <mplx@jennifer-lang.dev>
# pragma-jennifer-version: >=0.28.0

# gemini - core: the client and its settings, the HTTP exchange with its
# deadline, cap and retries, errors, JSON readers, paging, `call` and the
# model list. Spliced into gemini.j via include.

/** Where Google AI Studio serves the Gemini API. */
export def const DEFAULT_BASE_URL as string init "https://generativelanguage.googleapis.com";

/** The API version every path is below. */
export def const API_VERSION as string init "v1beta";

/** How long one request may take, in milliseconds: 5 minutes, for long generations. */
export def const DEFAULT_TIMEOUT_MS as int init 300000;

/** How many times a 408, 409, 429 or 5xx answer, or a network failure before the request was sent, is retried. */
export def const DEFAULT_RETRIES as int init 3;

/** The wait before the first retry when the server names none, in milliseconds; it doubles per retry. */
export def const DEFAULT_BACKOFF_MS as int init 1000;

/** The largest reply read, in bytes: 32 MiB. */
export def const DEFAULT_MAX_BYTES as int init 33554432;

/** The longest wait a retry takes; a server asking for more is not retried, in milliseconds. */
export def const MAX_RETRY_WAIT_MS as int init 60000;

/** The largest JSON request sent, in bytes: Google's 100 MB; larger media goes through `uploadFile`. */
export def const MAX_REQUEST_BYTES as int init 100000000;

/** The most pages a listing reads. */
export def const MAX_PAGES as int init 100;

/** The largest arguments of one function call handed to a tool handler, in bytes as JSON: 1 MiB. */
export def const DEFAULT_MAX_TOOL_INPUT as int init 1048576;

# the longest wait an answer can name, in milliseconds: 1e12
def const MAX_NAMED_WAIT_MS as int init 1000000000000;

# the most rate-limit headers an error keeps
def const MAX_LIMIT_HEADERS as int init 32;

# what an error message never shows: control characters and the bidi controls
# that reorder a terminal line
def const UNSHOWN as string init '[\x00-\x1f\x7f-\x9f\x{061c}\x{200b}-\x{200f}\x{2028}-\x{202e}\x{2060}-\x{2069}\x{feff}]';

# an API key: printable ASCII without spaces, so it cannot break a header
def const KEY_FORM as string init '^[\x21-\x7e]+$';

# a model: `models/<id>`, `tunedModels/<id>` or a bare id
def const MODEL_FORM as string init '^((models|tunedModels)/)?[a-z0-9]([a-z0-9.-]{0,126}[a-z0-9])?$';

# a resource id below `files/` or `cachedContents/`
def const RESOURCE_ID as string init '^[a-z0-9]([a-z0-9-]{0,126}[a-z0-9])?$';

# the hosts plain http is allowed to without `withPlainHttp`
def const LOOPBACK as list of string init ["127.0.0.1", "localhost", "[::1]"];

/**
 * How to reach the Gemini API. Build it with `client`, change it with the
 * `with*` functions. It holds the API key: do not print it.
 *
 * @field apiKey {string} the key sent in `x-goog-api-key`
 * @field baseUrl {string} the server's URL without a trailing slash, the API version not included
 * @field tls {http.TlsOptions} certificate checks for an `https` URL
 * @field allowPlainHttp {bool} whether plain `http` to another machine is allowed (the key then crosses the network in clear)
 * @field timeoutMs {int} how long one request may take
 * @field retries {int} how many times a 408, 409, 429 or 5xx answer, or a network failure before the request was sent, is retried
 * @field backoffMs {int} the wait before the first retry when the server names none
 * @field maxBytes {int} the largest reply read
 * @field maxToolInput {int} the largest arguments of a function call the tool loop hands to a handler, in bytes as JSON
 * @field uploadTimeoutMs {int} the deadline of an upload's data step; 0 for 5 minutes plus 1 minute per 100 MB
 */
export def struct Client {
    apiKey as string,
    baseUrl as string,
    tls as http.TlsOptions,
    allowPlainHttp as bool,
    timeoutMs as int,
    retries as int,
    backoffMs as int,
    maxBytes as int,
    maxToolInput as int,
    uploadTimeoutMs as int
};

/**
 * A model as `models` lists it.
 *
 * @field name {string} the resource name, such as `models/gemini-3.8-flash`
 * @field displayName {string} the name for people
 * @field description {string} what it is for
 * @field version {string} its version
 * @field inputTokenLimit {int} the most input tokens
 * @field outputTokenLimit {int} the most output tokens
 * @field methods {list of string} the supported generation methods, such as `generateContent`, `countTokens`, `embedContent`, `createCachedContent`
 * @field thinking {bool} whether it thinks
 */
export def struct ModelInfo {
    name as string,
    displayName as string,
    description as string,
    version as string,
    inputTokenLimit as int,
    outputTokenLimit as int,
    methods as list of string,
    thinking as bool
};

/**
 * Every error of kind "gemini" or "gemini.blocked". Kind "gemini" is a
 * request the API refused (`status` is its HTTP status), or one this deck
 * refused or could not send (`status` 0). Kind "gemini.blocked" is `text`
 * or `textJson` of a reply without an answer: `status` 200, `blockReason`
 * the block or finish reason. Caps, deadlines, network failures, closed
 * connections and cancelled tasks keep their generic kinds ("limit",
 * "timeout", "net", "closed", "cancelled").
 *
 * @field kind {string} "gemini" or "gemini.blocked"
 * @field message {string} `gemini: <request>: <why> (HTTP <status> <googleStatus>)`; never the API key
 * @field status {int} the HTTP status (Google's `error.code`); 0 when no request was answered; 200 for a blocked reply
 * @field googleStatus {string} Google's error status name, such as `INVALID_ARGUMENT`, `PERMISSION_DENIED`, `NOT_FOUND`, `RESOURCE_EXHAUSTED`, `UNAVAILABLE`; `""` when there is none (always for a blocked reply)
 * @field reason {string} the `reason` of a `google.rpc.ErrorInfo` detail, such as `API_KEY_INVALID`; `PROMPT_BLOCKED` or `RESPONSE_BLOCKED` for a blocked reply; `""` when there is none
 * @field blockReason {string} for a blocked reply (kind "gemini.blocked") the prompt's `blockReason` or the finish reason, such as `SAFETY`, `RECITATION` or `PROHIBITED_CONTENT`; `""` otherwise
 * @field retryAfterMs {int} how long the server asked to wait (`retry-after-ms`, `retry-after` or `RetryInfo.retryDelay`), in milliseconds, at most 1e12; 0 when it named no wait
 * @field limits {map of string to string} the answer's rate-limit headers, names lower-cased (`x-ratelimit-*`, `retry-after`, `retry-after-ms`), at most 32, values cleaned; empty when it sent none or there was no answer
 */
export def struct GeminiError {
    kind as string,
    message as string,
    status as int,
    googleStatus as string,
    reason as string,
    blockReason as string,
    retryAfterMs as int,
    limits as map of string to string
};

/**
 * Throw a gemini error that no server answer carried.
 *
 * @param message {string} what went wrong, without the `gemini: ` prefix
 * @throws {GeminiError} kind "gemini", status 0, always
 */
func fail(message as string) {
    throw GeminiError{
        kind: "gemini",
        message: "gemini: " + $message,
        status: 0,
        googleStatus: "",
        reason: "",
        blockReason: "",
        retryAfterMs: 0,
        limits: {}
    };
}

/**
 * Throw a reached cap: kind "limit".
 *
 * @param message {string} what was over the cap, without the `gemini: ` prefix
 * @throws {Error} kind "limit", always
 */
func failLimit(message as string) {
    throw Error{kind: "limit", message: "gemini: " + $message};
}

/**
 * Server-controlled text made safe for a message: control and bidi
 * characters as `?`, at most a number of characters.
 *
 * @param s {string} the text
 * @param most {int} the most characters kept
 * @return {string} the text
 */
func cleaned(s as string, most as int) {
    def text as string init $s;
    if (len($text) > $most) {
        $text = $text[..$most] + "...";
    }
    return regex.replace(UNSHOWN, $text, "?");
}

/**
 * Text quoted for an error message.
 *
 * @param s {string} the text
 * @return {string} the text in double quotes, cleaned and cut at 200 characters
 */
func shown(s as string) {
    return "\"" + cleaned($s, 200) + "\"";
}

/**
 * Server text for a message, the API key blanked out should the server
 * echo it.
 *
 * @param c {Client} the client
 * @param s {string} the text
 * @param most {int} the most characters kept
 * @return {string} the text
 */
func redacted(c as Client, s as string, most as int) {
    def text as string init $s;
    if ($c.apiKey != "" and strings.contains($text, $c.apiKey)) {
        $text = strings.replace($text, $c.apiKey, "<api key>");
    }
    return cleaned($text, $most);
}

/**
 * Refuse an int outside a range.
 *
 * @param value {int} the value
 * @param low {int} the smallest allowed
 * @param high {int} the largest allowed
 * @param what {string} what the value is
 */
func checkRange(value as int, low as int, high as int, what as string) {
    if ($value < $low or $value > $high) {
        fail(io.sprintf("%s must be %d to %d, got %d", $what, $low, $high, $value));
    }
}

/**
 * A client for the Gemini API with an AI Studio API key, at
 * `DEFAULT_BASE_URL`, with the default deadline, retries and cap.
 *
 * @param apiKey {string} the key, such as `os.getEnv("GEMINI_API_KEY")`
 * @return {Client} the client
 * @throws {GeminiError} kind "gemini" when the key is empty or holds spaces or control characters
 * @example
 *   def c as gemini.Client init gemini.client(os.getEnv("GEMINI_API_KEY"));
 */
export func client(apiKey as string) {
    if (len($apiKey) > 1024 or not regex.matches(KEY_FORM, $apiKey)) {
        fail("an API key is 1 to 1024 printable characters without spaces");
    }
    return Client{
        apiKey: $apiKey,
        baseUrl: DEFAULT_BASE_URL,
        tls: http.TlsOptions{},
        allowPlainHttp: false,
        timeoutMs: DEFAULT_TIMEOUT_MS,
        retries: DEFAULT_RETRIES,
        backoffMs: DEFAULT_BACKOFF_MS,
        maxBytes: DEFAULT_MAX_BYTES,
        maxToolInput: DEFAULT_MAX_TOOL_INPUT,
        uploadTimeoutMs: 0
    };
}

/**
 * Refuse a base URL that is not absolute http(s) or has a query or
 * fragment.
 *
 * @param baseUrl {string} the URL, without a trailing slash
 * @return {regex.Match} the URL's parts: scheme, host, port
 */
func checkUrlForm(baseUrl as string) {
    def m as regex.Match init regex.find(
        '^(https?)://(\[[0-9A-Fa-f:.]+\]|[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)*)(:([0-9]{1,5}))?(/[A-Za-z0-9._~-]+)*$',
        $baseUrl);
    if ($m.start < 0 or regex.matches('/\.+(/|$)', $baseUrl) or
        ($m.groups[6] != "" and
        (convert.toInt($m.groups[6]) < 1 or convert.toInt($m.groups[6]) > 65535))) {
        fail("a base URL is http(s)://host[:port][/path], port 1 to 65535, the path plain segments, got " +
            shown($baseUrl));
    }
    return $m;
}

/**
 * Refuse a base URL `checkUrlForm` refuses, or plain http to another
 * machine without `allowPlainHttp`.
 *
 * @param c {Client} the client
 */
func checkUrl(c as Client) {
    def m as regex.Match init checkUrlForm($c.baseUrl);
    if ($m.groups[0] == "http" and not $c.allowPlainHttp and
        not lists.contains(LOOPBACK, strings.lower($m.groups[1]))) {
        fail("plain http to " + shown($m.groups[1]) +
            " would send the API key in clear: use https, or withPlainHttp");
    }
}

/**
 * The client talking to another server that serves the same API: a proxy
 * or gateway, or a fake in tests. The API version is appended to it
 * (`<base>/v1beta/...`, uploads to `<base>/upload/v1beta/files`). Plain
 * `http` is refused when a request is sent unless the host is this machine
 * or `withPlainHttp` allows it.
 *
 * @param c {Client} the client
 * @param baseUrl {string} the URL, such as `https://gemini-proxy.example.org` or `http://127.0.0.1:8080`
 * @return {Client} the client
 * @throws {GeminiError} kind "gemini" when the URL is not an absolute http(s) URL without query or fragment
 */
export func withBaseUrl(c as Client, baseUrl as string) {
    def base as string init $baseUrl;
    while (strings.endsWith($base, "/")) {
        $base = $base[..len($base) - 1];
    }
    checkUrlForm($base);
    $c.baseUrl = $base;
    return $c;
}

/**
 * The client allowed to use plain `http` to another machine. The API key
 * crosses the network in clear.
 *
 * @param c {Client} the client
 * @return {Client} the client
 */
export func withPlainHttp(c as Client) {
    $c.allowPlainHttp = true;
    return $c;
}

/**
 * The client with certificate options for `https`: `caCert` to trust a
 * private CA (a corporate proxy that re-signs traffic), `skipVerify` as a
 * last resort.
 *
 * @param c {Client} the client
 * @param tls {http.TlsOptions} the options
 * @return {Client} the client
 */
export func withTls(c as Client, tls as http.TlsOptions) {
    $c.tls = $tls;
    return $c;
}

/**
 * The client with another deadline for each request (each attempt, when
 * retried).
 *
 * @param c {Client} the client
 * @param ms {int} 1000 to 3600000 milliseconds
 * @return {Client} the client
 */
export func withTimeout(c as Client, ms as int) {
    checkRange($ms, 1000, 3600000, "the timeout");
    $c.timeoutMs = $ms;
    return $c;
}

/**
 * The client retrying another number of times: a 408, 409, 429 or 5xx
 * answer, and a network failure (kind "net") before the whole request was
 * sent (a refused connection, a failed lookup or handshake, a reset while
 * sending). Every method is retried, a `generateContent` too (Google bills
 * only answered requests), but no request that was sent in full and then
 * failed is sent again. An upload's data step is not retried.
 *
 * @param c {Client} the client
 * @param n {int} 0 (no retries) to 10
 * @return {Client} the client
 */
export func withRetries(c as Client, n as int) {
    checkRange($n, 0, 10, "the retries");
    $c.retries = $n;
    return $c;
}

/**
 * The client with another wait before the first retry, used when the
 * server names none; it doubles per retry (at most 30 seconds) plus up to
 * a quarter at random.
 *
 * @param c {Client} the client
 * @param ms {int} 0 to 60000 milliseconds
 * @return {Client} the client
 */
export func withBackoff(c as Client, ms as int) {
    checkRange($ms, 0, 60000, "the backoff");
    $c.backoffMs = $ms;
    return $c;
}

/**
 * The client with another cap on replies.
 *
 * @param c {Client} the client
 * @param most {int} 65536 to 1073741824 bytes
 * @return {Client} the client
 */
export func withMaxBytes(c as Client, most as int) {
    checkRange($most, 65536, 1073741824, "the largest reply");
    $c.maxBytes = $most;
    return $c;
}

/**
 * The client handing at most this many bytes of arguments (as JSON) to a
 * tool handler. The tool loop answers a larger call with a `toolError`
 * for the model, without calling the handler.
 *
 * @param c {Client} the client
 * @param most {int} 1024 to 1073741824 bytes
 * @return {Client} the client
 */
export func withMaxToolInput(c as Client, most as int) {
    checkRange($most, 1024, 1073741824, "the largest tool input");
    $c.maxToolInput = $most;
    return $c;
}

/**
 * The client with another deadline for an upload's data step (`uploadFile`).
 * By default it is 5 minutes plus 1 minute per 100 MB of the file.
 *
 * @param c {Client} the client
 * @param ms {int} 1000 to 86400000 milliseconds
 * @return {Client} the client
 */
export func withUploadTimeout(c as Client, ms as int) {
    checkRange($ms, 1000, 86400000, "the upload timeout");
    $c.uploadTimeoutMs = $ms;
    return $c;
}

/**
 * The URL of an API path.
 *
 * @param c {Client} the client
 * @param path {string} the path below the API version, starting with `/`
 * @return {string} the URL
 */
func apiUrl(c as Client, path as string) {
    return $c.baseUrl + "/" + API_VERSION + $path;
}

/**
 * A model's resource name.
 *
 * @param model {string} `gemini-3.8-flash`, `models/gemini-3.8-flash` or `tunedModels/<id>`
 * @return {string} the name with its collection, such as `models/gemini-3.8-flash`
 */
func modelName(model as string) {
    if (not regex.matches(MODEL_FORM, $model)) {
        fail("a model is an id such as gemini-3.8-flash, optionally after models/ or tunedModels/, got " +
            shown($model));
    }
    if (strings.contains($model, "/")) {
        return $model;
    }
    return "models/" + $model;
}

/**
 * A resource's name in a collection.
 *
 * @param collection {string} `files` or `cachedContents`
 * @param name {string} `<collection>/<id>` or the bare id
 * @return {string} `<collection>/<id>`
 */
func resourceName(collection as string, name as string) {
    def id as string init $name;
    if (strings.startsWith($id, $collection + "/")) {
        $id = $id[len($collection) + 1..];
    }
    if (not regex.matches(RESOURCE_ID, $id)) {
        fail("a name is " + $collection + "/<id>, the id lowercase letters, digits and -, got " +
            shown($name));
    }
    return $collection + "/" + $id;
}

/**
 * One try at a request: its answer, or why none came.
 *
 * @field response {http.BytesResponse} the answer, any status; empty when `failure` is set
 * @field failure {string} why no answer was read, `""` when one was
 * @field closed {bool} whether the server closed the connection mid-answer (kind "closed")
 * @field dropped {bool} whether the network failed before the whole request was sent (a `net.NetError` with `sent` false): the one failure worth another try
 * @field isNet {bool} whether the failure is a `net.NetError`, passed on as it is
 * @field netError {net.NetError} that error, when `isNet`
 */
def struct Attempt {
    response as http.BytesResponse,
    failure as string,
    closed as bool,
    dropped as bool,
    isNet as bool,
    netError as net.NetError
};

/**
 * Send one request within a deadline: no retries, any status. A
 * connection that failed is returned as a failure, not thrown.
 *
 * @param c {Client} the client
 * @param method {string} the HTTP method
 * @param url {string} the URL
 * @param headers {map of string to string} the headers, without the key
 * @param body {string} a text body, `""` for none
 * @param raw {bytes} a binary body, sent instead of `body` when `isRaw`
 * @param isRaw {bool} whether to send `raw`
 * @param withKey {bool} whether to send the API key
 * @param timeoutMs {int} the deadline
 * @param what {string} the request, for messages
 * @return {Attempt} the answer or the failure
 * @throws {Error} kind "timeout", "limit" or "cancelled" as they come
 */
func attempt(
    c as Client,
    method as string,
    url as string,
    headers as map of string to string,
    body as string,
    raw as bytes,
    isRaw as bool,
    withKey as bool,
    timeoutMs as int,
    what as string) {
    checkUrl($c);
    def sent as map of string to string init $headers;
    if ($withKey) {
        if (len($c.apiKey) > 1024 or not regex.matches(KEY_FORM, $c.apiKey)) {
            fail("the client's API key was changed to something that is not a key");
        }
        $sent["x-goog-api-key"] = $c.apiKey;
    }
    def maxBytes as int init $c.maxBytes;
    def tls as http.TlsOptions init $c.tls;
    def t as task of http.BytesResponse init spawn {
        if ($isRaw) {
            return http.sendBytes(
                $method,
                $url,
                $sent,
                $raw,
                httpOptions($timeoutMs, $maxBytes, $tls));
        }
        return http.sendBytes(
            $method,
            $url,
            $sent,
            encoding.encode("utf-8", $body),
            httpOptions($timeoutMs, $maxBytes, $tls));
    };
    def none as http.BytesResponse;
    def noNet as net.NetError;
    try {
        return Attempt{
            response: task.waitTimeout($t, $timeoutMs),
            failure: "",
            closed: false,
            dropped: false,
            isNet: false,
            netError: $noNet
        };
    } catch (e) {
        if ($e.kind == "cancelled") {
            task.cancel($t);
            task.discard($t);
            throw $e;
        }
        if ($e.kind == "timeout") {
            task.cancel($t);
            task.discard($t);
            throw Error{
                kind: "timeout",
                message: io.sprintf("gemini: %s: no answer within %d ms", $what, $timeoutMs)
            };
        }
        if ($e.kind == "limit") {
            failLimit(io.sprintf("%s: the reply is over %d bytes", $what, $maxBytes));
        }
        if ($e.kind == "closed") {
            return Attempt{
                response: $none,
                failure: $what + ": the server closed the connection: " +
                    redacted($c, $e.message, 300),
                closed: true,
                dropped: false,
                isNet: false,
                netError: $noNet
            };
        }
        if ($e.kind == "net") {
            # sent false: the server cannot have acted on it, so it is safe to
            # send again; after the whole request (a reset or a close before or
            # during the answer) it may have been carried out
            def ne as net.NetError init $e;
            return Attempt{
                response: $none,
                failure: $what + ": " + redacted($c, $ne.message, 300),
                closed: false,
                dropped: not $ne.sent,
                isNet: true,
                netError: $ne
            };
        }
        return Attempt{
            response: $none,
            failure: $what + ": cannot reach " + shown($c.baseUrl) + ": " +
                redacted($c, $e.message, 300),
            closed: false,
            dropped: false,
            isNet: false,
            netError: $noNet
        };
    }
}

/**
 * Throw an attempt's failure: the `net.NetError` unchanged (kind "net", a
 * generic kind), kind "closed" when the server closed the connection
 * mid-answer, else kind "gemini" (status 0).
 *
 * @param a {Attempt} the attempt
 */
func failAttempt(a as Attempt) {
    if ($a.isNet) {
        def ne as net.NetError init $a.netError;
        throw $ne;
    }
    if ($a.closed) {
        throw Error{kind: "closed", message: "gemini: " + $a.failure};
    }
    fail($a.failure);
}

/**
 * Send one request within a deadline: no retries, any status.
 *
 * @param c {Client} the client
 * @param method {string} the HTTP method
 * @param url {string} the URL
 * @param headers {map of string to string} the headers, without the key
 * @param raw {bytes} the binary body
 * @param timeoutMs {int} the deadline
 * @param what {string} the request, for messages
 * @return {http.BytesResponse} the response
 */
func exchangeRaw(
    c as Client,
    method as string,
    url as string,
    headers as map of string to string,
    raw as bytes,
    timeoutMs as int,
    what as string) {
    def a as Attempt init attempt(
        $c,
        $method,
        $url,
        $headers,
        "",
        $raw,
        true,
        false,
        $timeoutMs,
        $what);
    if ($a.failure != "") {
        failAttempt($a);
    }
    return $a.response;
}

/**
 * Whether an answer's status is worth another try: 408, 409, 429 and 5xx.
 *
 * @param status {int} the status
 * @return {bool} whether to retry
 */
func retryable(status as int) {
    return $status == 408 or $status == 409 or $status == 429 or ($status >= 500 and $status <= 599);
}

/**
 * Send a request, retrying as the client allows: a 408, 409, 429 or 5xx
 * answer, and a `net.NetError` (kind "net") with `sent` false: refused,
 * unreachable, a failed lookup or handshake, a reset before the whole
 * request was written. Once the request was sent in full nothing is sent
 * again, whatever the method: a reset or close (`sent` true, `replied` true
 * or false) or an answer broken off mid-way (kind "closed") may come after
 * the server acted on it.
 *
 * @param c {Client} the client
 * @param method {string} the HTTP method
 * @param url {string} the URL
 * @param headers {map of string to string} the headers, without the key
 * @param body {string} a text body, `""` for none
 * @param what {string} the request, for messages
 * @return {http.BytesResponse} the last response, any status
 */
func send(
    c as Client,
    method as string,
    url as string,
    headers as map of string to string,
    body as string,
    what as string) {
    if (encoding.lenBytes($body) > MAX_REQUEST_BYTES) {
        failLimit(io.sprintf(
            "%s: the request is over %d bytes: upload large media with uploadFile",
            $what,
            MAX_REQUEST_BYTES));
    }
    def none as bytes;
    def tries as int init 0;
    while (true) {
        def a as Attempt init attempt(
            $c,
            $method,
            $url,
            $headers,
            $body,
            $none,
            false,
            true,
            $c.timeoutMs,
            $what);
        def wait as int init 0;
        if ($a.failure == "") {
            if ($tries >= $c.retries or not retryable($a.response.status)) {
                return $a.response;
            }
            $wait = retryWait($c, $a.response, $tries);
            if ($wait > MAX_RETRY_WAIT_MS) {
                return $a.response;
            }
        } else {
            if ($tries >= $c.retries or not $a.dropped) {
                failAttempt($a);
            }
            $wait = backoffWait($c, $tries);
        }
        if ($wait > 0) {
            time.sleep(time.fromMilliseconds($wait));
        }
        $tries = $tries + 1;
    }
}

/**
 * How long to wait before retrying an answer: what the server named, else
 * `backoffWait`.
 *
 * @param c {Client} the client
 * @param r {http.BytesResponse} the answer
 * @param attempt {int} the retries so far
 * @return {int} milliseconds
 */
func retryWait(c as Client, r as http.BytesResponse, attempt as int) {
    def named as int init namedWait($r);
    if ($named > 0) {
        return $named;
    }
    return backoffWait($c, $attempt);
}

/**
 * The client's backoff doubled per retry, at most 30 seconds, plus up to a
 * quarter at random.
 *
 * @param c {Client} the client
 * @param attempt {int} the retries so far
 * @return {int} milliseconds
 */
func backoffWait(c as Client, attempt as int) {
    def wait as int init $c.backoffMs;
    for (def i in 0..$attempt) {
        $wait = math.min($wait * 2, 30000);
    }
    return $wait + math.floor(math.rand() * convert.toFloat($wait) / 4.0);
}

/**
 * A count of digits as milliseconds, one unit being `scale` of them.
 *
 * @param digits {string} the header's value
 * @param scale {int} 1 for milliseconds, 1000 for seconds
 * @return {int} milliseconds, 0 when it is not a count; a count too long to read is the longest wait
 */
func countWait(digits as string, scale as int) {
    if (regex.matches('^[0-9]{1,9}$', $digits)) {
        return convert.toInt($digits) * $scale;
    }
    if (regex.matches('^[0-9]+$', $digits)) {
        # longer than any wait worth naming: kept as the longest, so the
        # request is not retried and the error says the server wants a wait
        return 999999999000;
    }
    return 0;
}

/**
 * The wait an answer names: its `retry-after-ms` header, else its
 * `retry-after` (seconds or an HTTP date), and the larger of that and a
 * `google.rpc.RetryInfo` `retryDelay` in its error body.
 *
 * @param r {http.BytesResponse} the answer
 * @return {int} milliseconds, 0 when it names none
 */
func namedWait(r as http.BytesResponse) {
    def wait as int init 0;
    if (maps.has($r.headers, "retry-after-ms")) {
        $wait = countWait(strings.trim($r.headers["retry-after-ms"]), 1);
    }
    if ($wait == 0 and maps.has($r.headers, "retry-after")) {
        def h as string init strings.trim($r.headers["retry-after"]);
        $wait = countWait($h, 1000);
        if ($wait == 0 and
            regex.matches(
            '^[A-Z][a-z]{2}, [0-9]{2} [A-Z][a-z]{2} [0-9]{4} [0-9]{2}:[0-9]{2}:[0-9]{2} GMT$',
            $h)) {
            try {
                def at as time.Time init time.parse($h, "%a, %d %b %Y %H:%M:%S GMT");
                $wait = math.max(0, time.unixMilliseconds($at) - time.unixMilliseconds(time.now()));
            } catch (e) {
                $wait = 0;
            }
        }
    }
    def delay as string init detailField(errorBody($r), "google.rpc.RetryInfo", "retryDelay");
    return math.min(math.max($wait, durationMs($delay)), MAX_NAMED_WAIT_MS);
}

/**
 * The rate-limit headers of an answer, names lower-cased: `x-ratelimit-*`,
 * `retry-after` and `retry-after-ms`, at most `MAX_LIMIT_HEADERS` of them.
 *
 * @param r {http.BytesResponse} the answer
 * @return {map of string to string} the headers, values cleaned and cut at 200 characters
 */
func rateLimits(r as http.BytesResponse) {
    def out as map of string to string init {};
    for (def k in lists.sort(maps.keys($r.headers))) {
        if (len($out) >= MAX_LIMIT_HEADERS) {
            break;
        }
        def name as string init strings.lower($k);
        if (strings.startsWith($name, "x-ratelimit-") or $name == "retry-after" or
            $name == "retry-after-ms") {
            $out[cleaned($name, 100)] = cleaned($r.headers[$k], 200);
        }
    }
    return $out;
}

/**
 * A field of the first detail of a type in a Google error body.
 *
 * @param v {json.Value} the error body
 * @param type {string} the end of the detail's `@type`, such as `google.rpc.ErrorInfo`
 * @param field {string} the field, such as `reason`
 * @return {string} its value, `""` when there is none
 */
func detailField(v as json.Value, type as string, field as string) {
    if (json.typeOf($v, "/error/details") != "list") {
        return "";
    }
    for (def i in 0..json.length($v, "/error/details")) {
        def p as string init "/error/details/" + convert.toString($i);
        if (json.typeOf($v, $p + "/@type") == "string" and
            strings.endsWith(json.asString($v, $p + "/@type"), "/" + $type) and
            json.typeOf($v, $p + "/" + $field) == "string") {
            return json.asString($v, $p + "/" + $field);
        }
    }
    return "";
}

/**
 * A protobuf duration in milliseconds, rounded up.
 *
 * @param s {string} such as `37s` or `0.250s`
 * @return {int} milliseconds, 0 when it is not a duration
 */
func durationMs(s as string) {
    def m as regex.Match init regex.find('^([0-9]{1,9})(\.([0-9]{1,9}))?s$', $s);
    if ($m.start < 0) {
        return 0;
    }
    def ms as int init convert.toInt($m.groups[0]) * 1000;
    if ($m.groups[2] != "") {
        def frac as string init ($m.groups[2] + "000000000")[..9];
        def ns as int init convert.toInt($frac);
        $ms = $ms + ($ns + 999999) // 1000000;
    }
    return $ms;
}

/**
 * The JSON body of an error answer.
 *
 * @param r {http.BytesResponse} the answer
 * @return {json.Value} the body, JSON `null` when it is not JSON
 */
func errorBody(r as http.BytesResponse) {
    def none as json.Value;
    if ($r.status >= 200 and $r.status <= 299) {
        return $none;
    }
    try {
        return json.decode(encoding.decode("utf-8", $r.body));
    } catch (e) {
        return $none;
    }
}

/**
 * Fail on a status that is not 2xx, with Google's error.
 *
 * @param c {Client} the client
 * @param r {http.BytesResponse} the answer
 * @param what {string} the request, for messages
 * @throws {GeminiError} kind "gemini" when the status is not 2xx
 */
func checkStatus(c as Client, r as http.BytesResponse, what as string) {
    if ($r.status >= 200 and $r.status <= 299) {
        return null;
    }
    def v as json.Value init errorBody($r);
    def why as string init $r.statusText;
    def status as string init "";
    def reason as string init "";
    if (json.typeOf($v, "/error") == "map") {
        if (json.typeOf($v, "/error/message") == "string") {
            $why = json.asString($v, "/error/message");
        }
        if (json.typeOf($v, "/error/status") == "string") {
            $status = json.asString($v, "/error/status");
        }
        $reason = detailField($v, "google.rpc.ErrorInfo", "reason");
    } elseif ($r.status == 404) {
        $why = "not found";
    }
    $status = cleaned($status, 64);
    $reason = cleaned($reason, 64);
    def tail as string init "HTTP " + convert.toString($r.status);
    if ($status != "") {
        $tail = $tail + " " + $status;
    }
    throw GeminiError{
        kind: "gemini",
        message: "gemini: " + $what + ": " + redacted($c, $why, 500) + " (" + $tail + ")",
        status: $r.status,
        googleStatus: $status,
        reason: $reason,
        blockReason: "",
        retryAfterMs: namedWait($r),
        limits: rateLimits($r)
    };
}

/**
 * A response body as JSON.
 *
 * @param r {http.BytesResponse} the response
 * @param what {string} the request, for messages
 * @return {json.Value} the body, an empty object when empty
 */
func jsonBody(r as http.BytesResponse, what as string) {
    def text as string init "";
    try {
        $text = encoding.decode("utf-8", $r.body);
    } catch (e) {
        fail($what + ": the reply is not UTF-8");
    }
    if (strings.trim($text) == "") {
        return json.map();
    }
    try {
        return json.decode($text);
    } catch (e) {
        if ($e.kind == "limit") {
            # json's nesting and node caps: a generic kind, passed on
            throw $e;
        }
        fail($what + ": the reply is not JSON: " + shown($text));
    }
}

/**
 * Send an API request and read its JSON reply, failing on a status that is
 * not 2xx.
 *
 * @param c {Client} the client
 * @param method {string} the HTTP method
 * @param path {string} the path below the API version, with any query
 * @param body {string} a JSON body, `""` for none
 * @param what {string} the request, for messages
 * @return {json.Value} the reply, an empty object when it has no body
 */
func apiRequest(c as Client, method as string, path as string, body as string, what as string) {
    def headers as map of string to string init {"Accept": "application/json"};
    if ($body != "") {
        $headers["Content-Type"] = "application/json";
    }
    # the response goes straight into a parameter: a `def` would copy its body
    return replyJson($c, send($c, $method, apiUrl($c, $path), $headers, $body, $what), $what);
}

/**
 * An answer's JSON, failing on a status that is not 2xx.
 *
 * @param c {Client} the client
 * @param r {http.BytesResponse} the answer
 * @param what {string} the request, for messages
 * @return {json.Value} the reply, an empty object when it has no body
 */
func replyJson(c as Client, r as http.BytesResponse, what as string) {
    checkStatus($c, $r, $what);
    return jsonBody($r, $what);
}

/**
 * A string at a JSON pointer, `""` when absent or null.
 *
 * @param v {json.Value} the document
 * @param ptr {string} the pointer
 * @return {string} the string
 */
func textAt(v as json.Value, ptr as string) {
    def t as string init json.typeOf($v, $ptr);
    if ($t == "missing" or $t == "null") {
        return "";
    }
    if ($t != "string") {
        fail(shown($ptr) + " is a " + $t + ", not a string");
    }
    return json.asString($v, $ptr);
}

/**
 * An integer at a JSON pointer, 0 when absent or null. Google writes
 * 64-bit integers as strings of digits; those are read too.
 *
 * @param v {json.Value} the document
 * @param ptr {string} the pointer
 * @return {int} the number
 */
func intAt(v as json.Value, ptr as string) {
    def t as string init json.typeOf($v, $ptr);
    if ($t == "missing" or $t == "null") {
        return 0;
    }
    if ($t == "string" and regex.matches('^-?[0-9]{1,18}$', json.asString($v, $ptr))) {
        return convert.toInt(json.asString($v, $ptr));
    }
    if ($t != "int") {
        fail(shown($ptr) + " is a " + $t + ", not an integer");
    }
    return json.asInt($v, $ptr);
}

/**
 * A boolean at a JSON pointer, false when absent or null.
 *
 * @param v {json.Value} the document
 * @param ptr {string} the pointer
 * @return {bool} the value
 */
func boolAt(v as json.Value, ptr as string) {
    def t as string init json.typeOf($v, $ptr);
    if ($t == "missing" or $t == "null") {
        return false;
    }
    if ($t != "bool") {
        fail(shown($ptr) + " is a " + $t + ", not a boolean");
    }
    return json.asBool($v, $ptr);
}

/**
 * The strings of a JSON list, empty when absent or null.
 *
 * @param v {json.Value} the document
 * @param ptr {string} the pointer
 * @return {list of string} the strings
 */
func textsAt(v as json.Value, ptr as string) {
    def t as string init json.typeOf($v, $ptr);
    def out as list of string init [];
    if ($t == "missing" or $t == "null") {
        return $out;
    }
    if ($t != "list") {
        fail(shown($ptr) + " is a " + $t + ", not a list");
    }
    for (def i in 0..json.length($v, $ptr)) {
        $out[] = textAt($v, $ptr + "/" + convert.toString($i));
    }
    return $out;
}

/**
 * Every item of a paged listing, following `nextPageToken`.
 *
 * @param c {Client} the client
 * @param path {string} the collection's path, such as `/models`
 * @param key {string} the key of the items in each page, such as `models`
 * @param pageSize {int} the items asked for per page
 * @param most {int} the most pages read, such as `MAX_PAGES`
 * @param what {string} the request, for messages
 * @return {list of json.Value} the items
 * @throws {Error} kind "limit" after `most` pages, or when the pages together are over the reply cap
 */
func pages(
    c as Client,
    path as string,
    key as string,
    pageSize as int,
    most as int,
    what as string) {
    def items as list of json.Value init [];
    def token as string init "";
    def read as int init 0;
    for (def n in 0..$most) {
        def query as string init "?pageSize=" + convert.toString($pageSize);
        if ($token != "") {
            $query = $query + "&pageToken=" + uri.encode($token);
        }
        def r as http.BytesResponse init send(
            $c,
            "GET",
            apiUrl($c, $path + $query),
            {"Accept": "application/json"},
            "",
            $what);
        # every page is under the reply cap; together they are too, so 100
        # pages cannot hold 100 times the cap
        $read = $read + len($r.body);
        if ($read > $c.maxBytes) {
            failLimit(io.sprintf("%s: the pages are over %d bytes together", $what, $c.maxBytes));
        }
        def page as json.Value init replyJson($c, $r, $what);
        def t as string init json.typeOf($page, "/" + $key);
        if ($t == "list") {
            for (def i in 0..json.length($page, "/" + $key)) {
                $items[] = json.get($page, "/" + $key + "/" + convert.toString($i));
            }
        } elseif ($t != "missing" and $t != "null") {
            fail($what + ": " + shown($key) + " is a " + $t + ", not a list");
        }
        $token = textAt($page, "/nextPageToken");
        if ($token == "") {
            return $items;
        }
    }
    failLimit(io.sprintf("%s: more than %d pages", $what, $most));
}

/**
 * A model as the API describes it.
 *
 * @param v {json.Value} the model object
 * @return {ModelInfo} the model
 */
func modelFrom(v as json.Value) {
    return ModelInfo{
        name: textAt($v, "/name"),
        displayName: textAt($v, "/displayName"),
        description: textAt($v, "/description"),
        version: textAt($v, "/version"),
        inputTokenLimit: intAt($v, "/inputTokenLimit"),
        outputTokenLimit: intAt($v, "/outputTokenLimit"),
        methods: textsAt($v, "/supportedGenerationMethods"),
        thinking: boolAt($v, "/thinking")
    };
}

/**
 * Every model the key may use, all pages.
 *
 * @param c {Client} the client
 * @return {list of ModelInfo} the models
 * @throws {GeminiError} kind "gemini" when the API refuses
 * @throws {Error} kind "limit" after `MAX_PAGES` pages, or when they are over the reply cap together
 * @example
 *   for (def m in gemini.models($c)) {
 *       io.printf("%s %d\n", $m.name, $m.inputTokenLimit);
 *   }
 */
export func models(c as Client) {
    def out as list of ModelInfo init [];
    for (def v in pages($c, "/models", "models", 1000, MAX_PAGES, "models")) {
        $out[] = modelFrom($v);
    }
    return $out;
}

/**
 * One model.
 *
 * @param c {Client} the client
 * @param name {string} such as `gemini-3.8-flash` or `models/gemini-3.8-flash`
 * @return {ModelInfo} the model
 * @throws {GeminiError} kind "gemini" when the name is malformed or the API refuses (404 for an unknown model)
 */
export func model(c as Client, name as string) {
    def path as string init modelName($name);
    return modelFrom(apiRequest($c, "GET", "/" + $path, "", "model " + shown($name)));
}

/**
 * Any other API request, retried and capped like the rest.
 *
 * @param c {Client} the client
 * @param method {string} `GET`, `POST`, `PATCH` or `DELETE`
 * @param path {string} the path below the API version, such as `/models/gemini-3.8-flash:batchGenerateContent` or `/batches/<id>`, with any query after `?`, its values percent-encoded by the caller (`uri.encode`)
 * @param body {json.Value} the body, JSON `null` for none
 * @return {json.Value} the reply, an empty object when it has no body
 * @throws {GeminiError} kind "gemini" when the method, path or query is malformed, or the API refuses
 * @example
 *   def ops as json.Value init gemini.call($c, "GET", "/batches?pageSize=10", json.decode("null"));
 */
export func call(c as Client, method as string, path as string, body as json.Value) {
    if (not lists.contains(["GET", "POST", "PATCH", "DELETE"], $method)) {
        fail("a method is GET, POST, PATCH or DELETE, got " + shown($method));
    }
    def at as int init strings.indexOf($path, "?");
    def segments as string init $path;
    def query as string init "";
    if ($at >= 0) {
        $segments = $path[..$at];
        $query = $path[$at + 1..];
    }
    if (not regex.matches('^(/[A-Za-z0-9_.:-]+)+$', $segments) or
        regex.matches('/\.+(/|:|$)', $segments)) {
        fail("a path is /segments of letters, digits and _.:-, got " + shown($path));
    }
    if ($at >= 0 and
        not regex.matches(
        '^[A-Za-z][A-Za-z0-9_.]*=([A-Za-z0-9._~-]|%[0-9A-Fa-f]{2})*(&[A-Za-z][A-Za-z0-9_.]*=([A-Za-z0-9._~-]|%[0-9A-Fa-f]{2})*)*$',
        $query)) {
        fail("a query is name=value pairs joined by &, each value percent-encoded, got " +
            shown($path));
    }
    def payload as string init "";
    if (json.typeOf($body) != "null") {
        $payload = json.encode($body);
    }
    return apiRequest($c, $method, $path, $payload, $method + " " + $segments);
}

# httpOptions is the http.Options a positional timeout, body cap and TLS
# setting stand for: a timeout of 0 means no idle timeout, as it did for the
# positional calls.
func httpOptions(timeoutMs as int, maxBytes as int, tls as http.TlsOptions) {
    def o as http.Options;
    $o.timeoutMs = $timeoutMs;
    if ($timeoutMs == 0) {
        $o.timeoutMs = math.MAX_INT;
    }
    $o.maxBytes = $maxBytes;
    def t as net.TLSOptions;
    $t.skipVerify = $tls.skipVerify;
    $t.caCert = $tls.caCert;
    $o.tlsOptions = $t;
    return $o;
}
