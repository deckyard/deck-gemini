# SPDX-License-Identifier: LGPL-3.0-only
# SPDX-FileCopyrightText: Copyright (C) 2026 mplx <mplx@jennifer-lang.dev>
# pragma-jennifer-version: >=0.26.0

# gemini - white-box tests for the core topic, and the fake server the
# other overlays use. Spliced into gemini_test.j via include.

# the API key the tests use: not a real one
def const KEY as string init "AIzaFakeKeyForTests0123456789abcdefghij";

# what separates the answers a fake gives one request in turn
def const NEXT as string init "\n=====\n";

/**
 * A running fake Gemini server.
 *
 * @field srv {httpd.Server} the server
 * @field base {string} its base URL
 * @field t {task of list of string} the task serving it; its result is every request seen
 */
def struct Fake {
    srv as httpd.Server,
    base as string,
    t as task of list of string
};

/**
 * Mark a call that should have thrown.
 *
 * @param what {string} what got through
 * @throws {Error} always, kind "missed"
 */
func missed(what as string) {
    throw Error{kind: "missed", message: $what};
}

/**
 * Start a fake Gemini server. An answer is looked up by `METHOD path?query`,
 * then `METHOD path`; it is the status, a newline, header lines `Name:
 * value` (`$BASE` in a value is the fake's URL), an empty line and the body.
 * Several answers joined by NEXT are given in turn, the last one again
 * after that. A request with no answer gets a Google 404; an answer whose
 * status is `SLEEP` waits 3 seconds; a status after `SLOW ` (`SLOW 200`) is
 * answered after 1.5 seconds.
 *
 * @param answers {map of string to string} the answers
 * @return {Fake} the server
 */
func startFake(answers as map of string to string) {
    def srv as httpd.Server init httpd.listen("127.0.0.1:0");
    def base as string init "http://" + httpd.address($srv);
    def t as task of list of string init spawn {
        return serveFake($srv, $base, $answers);
    };
    return Fake{srv: $srv, base: $base, t: $t};
}

/**
 * A request's body for the record: its text, or `hex:` and its bytes when
 * it is not UTF-8.
 *
 * @param body {bytes} the body
 * @return {string} the record
 */
func bodyText(body as bytes) {
    try {
        return convert.stringFromBytes("utf-8", $body);
    } catch (e) {
        return "hex:" + encoding.toText("hex", $body);
    }
}

/**
 * Serve requests until the server shuts down.
 *
 * @param srv {httpd.Server} the server
 * @param base {string} its URL
 * @param answers {map of string to string} the answers
 * @return {list of string} each request as `METHOD path?query|header=value|...|body`, with the headers it records when sent
 */
func serveFake(srv as httpd.Server, base as string, answers as map of string to string) {
    def seen as list of string init [];
    def turns as map of string to int init {};
    while (true) {
        def req as httpd.Request;
        try {
            $req = httpd.accept($srv);
        } catch (e) {
            return $seen;
        }
        def target as string init httpd.path($req);
        if (httpd.rawQuery($req) != "") {
            $target = $target + "?" + httpd.rawQuery($req);
        }
        def key as string init httpd.method($req) + " " + $target;
        def line as list of string init [$key];
        for (def h in [
            "x-goog-api-key",
            "Content-Type",
            "X-Goog-Upload-Protocol",
            "X-Goog-Upload-Command",
            "X-Goog-Upload-Header-Content-Length",
            "X-Goog-Upload-Header-Content-Type",
            "X-Goog-Upload-Offset"
        ]) {
            if (httpd.header($req, $h) != "") {
                $line[] = $h + "=" + httpd.header($req, $h);
            }
        }
        $line[] = bodyText(httpd.body($req));
        $seen[] = strings.join($line, "|");
        def found as string init "";
        if (maps.has($answers, $key)) {
            $found = $key;
        } elseif (maps.has($answers, httpd.method($req) + " " + httpd.path($req))) {
            $found = httpd.method($req) + " " + httpd.path($req);
        }
        def spec as string init "404\nContent-Type: application/json\n\n" +
            '{"error": {"code": 404, "message": "no answer for this", "status": "NOT_FOUND"}}';
        if ($found != "") {
            def all as list of string init strings.split($answers[$found], NEXT);
            def n as int init 0;
            if (maps.has($turns, $found)) {
                $n = $turns[$found];
            }
            $turns[$found] = $n + 1;
            $spec = $all[math.min($n, len($all) - 1)];
        }
        def split as int init strings.indexOf($spec, "\n\n");
        def head as list of string init strings.split($spec[..$split], "\n");
        for (def h in $head[1..]) {
            def at as int init strings.indexOf($h, ": ");
            httpd.setHeader($req, $h[..$at], strings.replace($h[$at + 2..], "$BASE", $base));
        }
        if (strings.startsWith($head[0], "SLOW ")) {
            time.sleep(time.fromMilliseconds(1500));
            httpd.respond($req, convert.toInt($head[0][5..]), $spec[$split + 2..]);
        } elseif ($head[0] == "SLEEP") {
            time.sleep(time.fromMilliseconds(3000));
            httpd.respond($req, 200, '{}');
        } else {
            httpd.respond($req, convert.toInt($head[0]), $spec[$split + 2..]);
        }
    }
}

/**
 * Stop a fake and return what it saw.
 *
 * @param f {Fake} the fake
 * @return {list of string} the requests
 */
func stopFake(f as Fake) {
    httpd.shutdown($f.srv);
    return task.wait($f.t);
}

/**
 * A client of a fake, retrying quickly.
 *
 * @param f {Fake} the fake
 * @return {Client} the client
 */
func fakeClient(f as Fake) {
    return withBackoff(withBaseUrl(client(KEY), $f.base), 1);
}

/**
 * A JSON answer.
 *
 * @param status {int} the status
 * @param body {string} the JSON
 * @return {string} the answer for `startFake`
 */
func answer(status as int, body as string) {
    return convert.toString($status) + "\nContent-Type: application/json\n\n" + $body;
}

/**
 * The body of a recorded request, decoded.
 *
 * @param seen {string} the record
 * @return {json.Value} its JSON body
 */
func seenBody(seen as string) {
    def parts as list of string init strings.split($seen, "|");
    return json.decode($parts[len($parts) - 1]);
}

func testClientAndSettings() {
    def c as Client init client(KEY);
    testing.assertEqual($c.baseUrl, DEFAULT_BASE_URL);
    testing.assertEqual($c.timeoutMs, DEFAULT_TIMEOUT_MS);
    testing.assertEqual($c.retries, DEFAULT_RETRIES);
    testing.assertEqual($c.maxBytes, DEFAULT_MAX_BYTES);
    for (def bad in ["", "two words", "line\nbreak"]) {
        try {
            client($bad);
            missed("key " + $bad);
        } catch (e) {
            testing.assertEqual($e.kind, "gemini");
            testing.assertContains($e.message, "an API key is");
        }
    }
    testing.assertEqual(
        withBaseUrl($c, "https://proxy.example.org/gemini/").baseUrl,
        "https://proxy.example.org/gemini");
    for (def bad in ["ftp://x", "https://x/?a=1", "x.org", "https://x:0", "https://x/a/../b"]) {
        try {
            withBaseUrl($c, $bad);
            missed($bad);
        } catch (e) {
            testing.assertContains($e.message, "a base URL is");
        }
    }
    testing.assertEqual(withTimeout($c, 5000).timeoutMs, 5000);
    testing.assertEqual(withRetries($c, 0).retries, 0);
    testing.assertEqual(withBackoff($c, 250).backoffMs, 250);
    testing.assertEqual(withMaxBytes($c, 65536).maxBytes, 65536);
    testing.assertFalse($c.tls.skipVerify);
    testing.assertTrue(withTls($c, http.TlsOptions{skipVerify: true}).tls.skipVerify);
    for (def bad in [999, 3600001]) {
        try {
            withTimeout($c, $bad);
            missed("timeout");
        } catch (e) {
            testing.assertContains($e.message, "the timeout must be 1000 to 3600000");
        }
    }
    try {
        withRetries($c, 11);
        missed("retries");
    } catch (e) {
        testing.assertContains($e.message, "the retries must be 0 to 10");
    }
    try {
        withMaxBytes($c, 1024);
        missed("cap");
    } catch (e) {
        testing.assertContains($e.message, "the largest reply must be");
    }
    try {
        withBackoff($c, -1);
        missed("backoff");
    } catch (e) {
        testing.assertContains($e.message, "the backoff must be");
    }
}

func testPlainHttpOnlyToLoopback() {
    def lan as Client init withBaseUrl(client(KEY), "http://gemini.lan:8080");
    try {
        models($lan);
        missed("plain http to the LAN");
    } catch (e) {
        testing.assertEqual($e.kind, "gemini");
        testing.assertContains($e.message, "would send the API key in clear");
        testing.assertFalse(strings.contains($e.message, KEY));
    }
    checkUrl(withPlainHttp($lan));
    checkUrl(withBaseUrl(client(KEY), "http://localhost:8080"));
    checkUrl(withBaseUrl(client(KEY), "http://[::1]:8080"));
}

func testNamesAndDurations() {
    testing.assertEqual(modelName("gemini-3.8-flash"), "models/gemini-3.8-flash");
    testing.assertEqual(modelName("models/gemini-embedding-001"), "models/gemini-embedding-001");
    testing.assertEqual(modelName("tunedModels/my-model-7"), "tunedModels/my-model-7");
    for (def bad in ["", "Gemini", "models/../x", "a b", "files/x", "gemini-3-"]) {
        try {
            modelName($bad);
            missed($bad);
        } catch (e) {
            testing.assertContains($e.message, "a model is an id");
        }
    }
    testing.assertEqual(resourceName("files", "abc-123"), "files/abc-123");
    testing.assertEqual(resourceName("files", "files/abc-123"), "files/abc-123");
    try {
        resourceName("files", "files/../x");
        missed("dots");
    } catch (e) {
        testing.assertContains($e.message, "a name is files/<id>");
    }
    testing.assertEqual(durationMs("37s"), 37000);
    testing.assertEqual(durationMs("0.250s"), 250);
    testing.assertEqual(durationMs("1.0000001s"), 1001);
    testing.assertEqual(durationMs("2m"), 0);
    testing.assertEqual(durationMs(""), 0);
}

func testModelsFollowPages() {
    def f as Fake init startFake({
        "GET /v1beta/models?pageSize=1000": answer(
            200,
            '{"models": [{"name": "models/gemini-3.8-flash", "version": "3.8", "displayName": "Gemini 3.8 Flash", "description": "Fast", "inputTokenLimit": 1048576, "outputTokenLimit": 65536, "supportedGenerationMethods": ["generateContent", "countTokens", "createCachedContent"], "thinking": true}], "nextPageToken": "tok/2="}'),
        "GET /v1beta/models?pageSize=1000&pageToken=tok%2F2%3D": answer(
            200,
            '{"models": [{"name": "models/gemini-embedding-001", "version": "001", "displayName": "Gemini Embedding 001", "inputTokenLimit": 2048, "outputTokenLimit": 1, "supportedGenerationMethods": ["embedContent", "countTextTokens"]}]}'),
        "GET /v1beta/models/gemini-3.8-flash": answer(
            200,
            '{"name": "models/gemini-3.8-flash", "version": "3.8", "inputTokenLimit": 1048576, "outputTokenLimit": 65536, "supportedGenerationMethods": ["generateContent"], "thinking": true}')
    });
    def c as Client init fakeClient($f);
    def all as list of ModelInfo init models($c);
    def one as ModelInfo init model($c, "gemini-3.8-flash");
    def seen as list of string init stopFake($f);
    testing.assertEqual(len($all), 2);
    testing.assertEqual($all[0].name, "models/gemini-3.8-flash");
    testing.assertEqual($all[0].inputTokenLimit, 1048576);
    testing.assertTrue($all[0].thinking);
    testing.assertEqual($all[0].methods, ["generateContent", "countTokens", "createCachedContent"]);
    testing.assertEqual($all[1].name, "models/gemini-embedding-001");
    testing.assertFalse($all[1].thinking);
    testing.assertEqual($one.outputTokenLimit, 65536);
    testing.assertEqual(len($seen), 3);
    testing.assertEqual($seen[0], "GET /v1beta/models?pageSize=1000|x-goog-api-key=" + KEY + "|");
    testing.assertTrue(strings.startsWith(
        $seen[1],
        "GET /v1beta/models?pageSize=1000&pageToken=tok%2F2%3D|"));
}

func testRefusalIsGeminiError() {
    def f as Fake init startFake({
        "GET /v1beta/models/gemini-3.8-flash": answer(
            400,
            '{"error": {"code": 400, "message": "API key not valid: ' + KEY +
                '. Please pass a valid API key.", "status": "INVALID_ARGUMENT", "details": [{"@type": "type.googleapis.com/google.rpc.ErrorInfo", "reason": "API_KEY_INVALID", "domain": "googleapis.com", "metadata": {"service": "generativelanguage.googleapis.com"}}, {"@type": "type.googleapis.com/google.rpc.LocalizedMessage", "locale": "en-US", "message": "API key not valid."}]}}'),
        "GET /v1beta/models/gone": "502\nContent-Type: text/html\n\n<html>Bad Gateway</html>"
    });
    def c as Client init fakeClient($f);
    try {
        model($c, "gemini-3.8-flash");
        missed("a 400");
    } catch (e) {
        testing.assertEqual($e.kind, "gemini");
        def g as GeminiError init $e;
        testing.assertEqual($g.status, 400);
        testing.assertEqual($g.googleStatus, "INVALID_ARGUMENT");
        testing.assertEqual($g.reason, "API_KEY_INVALID");
        testing.assertEqual($g.retryAfterMs, 0);
        testing.assertContains(
            $g.message,
            "gemini: model \"gemini-3.8-flash\": API key not valid: <api key>.");
        testing.assertContains($g.message, "(HTTP 400 INVALID_ARGUMENT)");
        testing.assertFalse(strings.contains($g.message, KEY));
    }
    try {
        model(withRetries($c, 0), "gone");
        missed("a 502");
    } catch (e) {
        def g as GeminiError init $e;
        testing.assertEqual($g.status, 502);
        testing.assertEqual($g.googleStatus, "");
        testing.assertContains($g.message, "(HTTP 502)");
    }
    def seen as list of string init stopFake($f);
    # a 400 is not retried
    testing.assertEqual(len($seen), 2);
}

func testRetriesHonourRetryDelay() {
    def busy as string init answer(
        429,
        '{"error": {"code": 429, "message": "You exceeded your current quota.", "status": "RESOURCE_EXHAUSTED", "details": [{"@type": "type.googleapis.com/google.rpc.QuotaFailure", "violations": [{"quotaMetric": "generativelanguage.googleapis.com/generate_content_free_tier_requests", "quotaId": "GenerateRequestsPerMinutePerProjectPerModel-FreeTier"}]}, {"@type": "type.googleapis.com/google.rpc.Help", "links": [{"description": "Learn more", "url": "https://ai.google.dev/gemini-api/docs/rate-limits"}]}, {"@type": "type.googleapis.com/google.rpc.RetryInfo", "retryDelay": "0.300s"}]}}');
    def f as Fake init startFake({
        "GET /v1beta/models/gemini-3.8-flash": $busy + NEXT +
            answer(200, '{"name": "models/gemini-3.8-flash"}')
    });
    def started as time.Time init time.now();
    def m as ModelInfo init model(fakeClient($f), "gemini-3.8-flash");
    def took as int init time.milliseconds(time.sub(time.now(), $started));
    def seen as list of string init stopFake($f);
    testing.assertEqual($m.name, "models/gemini-3.8-flash");
    testing.assertEqual(len($seen), 2);
    testing.assertTrue($took >= 300);
}

func testRetriesHonourRetryAfter() {
    def f as Fake init startFake({
        "GET /v1beta/models/gemini-3.8-flash": "503\nRetry-After: 1\nContent-Type: application/json\n\n" +
            '{"error": {"code": 503, "message": "The model is overloaded. Please try again later.", "status": "UNAVAILABLE"}}' +
            NEXT + answer(200, '{"name": "models/gemini-3.8-flash"}')
    });
    def started as time.Time init time.now();
    model(fakeClient($f), "gemini-3.8-flash");
    def took as int init time.milliseconds(time.sub(time.now(), $started));
    testing.assertEqual(len(stopFake($f)), 2);
    testing.assertTrue($took >= 1000);
}

func testRetriesRunOut() {
    def f as Fake init startFake({
        "GET /v1beta/models/gemini-3.8-flash": answer(
            500,
            '{"error": {"code": 500, "message": "An internal error has occurred.", "status": "INTERNAL"}}'),
        "GET /v1beta/models/slow": answer(
            429,
            '{"error": {"code": 429, "message": "Quota exceeded.", "status": "RESOURCE_EXHAUSTED", "details": [{"@type": "type.googleapis.com/google.rpc.RetryInfo", "retryDelay": "3600s"}]}}')
    });
    def c as Client init withRetries(fakeClient($f), 2);
    try {
        model($c, "gemini-3.8-flash");
        missed("a 500");
    } catch (e) {
        def g as GeminiError init $e;
        testing.assertEqual($g.status, 500);
        testing.assertEqual($g.googleStatus, "INTERNAL");
    }
    # a wait over MAX_RETRY_WAIT_MS is not taken: the error says how long
    try {
        model($c, "slow");
        missed("a 429");
    } catch (e) {
        def g as GeminiError init $e;
        testing.assertEqual($g.googleStatus, "RESOURCE_EXHAUSTED");
        testing.assertEqual($g.retryAfterMs, 3600000);
    }
    def seen as list of string init stopFake($f);
    testing.assertEqual(len($seen), 4);
}

func testRetryAfterTooLongIsNotTaken() {
    # a retry-after past what a regex for a few digits reads still means
    # "not now": no retry, and the error names the wait
    def f as Fake init startFake({
        "GET /v1beta/models/gemini-3.8-flash": "429\nRetry-After: 1000000000\nContent-Type: application/json\n\n" +
            '{"error": {"code": 429, "message": "Quota exceeded.", "status": "RESOURCE_EXHAUSTED"}}'
    });
    try {
        model(withBackoff(fakeClient($f), 0), "gemini-3.8-flash");
        missed("a 429");
    } catch (e) {
        def g as GeminiError init $e;
        testing.assertEqual($g.status, 429);
        testing.assertTrue($g.retryAfterMs > MAX_RETRY_WAIT_MS);
    }
    testing.assertEqual(len(stopFake($f)), 1);
}

func testPagesShareTheCap() {
    # each page is under the cap, but endless pages of it are not read
    def page as string init '{"models": [{"name": "models/m", "description": "' +
        strings.repeat("x", 40000) + '"}], "nextPageToken": "more"}';
    def f as Fake init startFake({"GET /v1beta/models": answer(200, $page)});
    try {
        models(withMaxBytes(fakeClient($f), 65536));
        missed("pages over the cap");
    } catch (e) {
        testing.assertEqual($e.kind, "limit");
    }
    testing.assertEqual(len(stopFake($f)), 2);
}

/**
 * A fake that answers each connection with raw bytes and closes it.
 *
 * @field listener {net.Listener} the socket
 * @field base {string} its URL
 * @field t {task of int} the task serving it; its result is how many connections it took
 */
def struct RawFake {
    listener as net.Listener,
    base as string,
    t as task of int
};

/**
 * Start a raw fake. Each connection reads one request and gets the next
 * reply as it is (`""`: closed at once, before any byte of an answer).
 *
 * @param replies {list of string} one reply per connection, in turn
 * @return {RawFake} the fake
 */
func startRawFake(replies as list of string) {
    def l as net.Listener init net.listen("127.0.0.1:0");
    def base as string init "http://" + net.address($l);
    def t as task of int init spawn {
        return serveRaw($l, $replies);
    };
    return RawFake{listener: $l, base: $base, t: $t};
}

/**
 * Serve a raw fake's connections.
 *
 * @param l {net.Listener} the socket
 * @param replies {list of string} the replies
 * @return {int} the connections taken
 */
func serveRaw(l as net.Listener, replies as list of string) {
    def n as int init 0;
    for (def reply in $replies) {
        def conn as net.Conn;
        try {
            $conn = net.accept($l);
        } catch (e) {
            return $n;
        }
        $n = $n + 1;
        # read the whole request, so closing sends a FIN, not a reset
        readRequest($conn);
        if ($reply != "") {
            net.writeBytes($conn, convert.bytesFromString("utf-8", $reply));
        }
        net.close($conn);
    }
    return $n;
}

/**
 * Read one HTTP request to its end: the head and `Content-Length` bytes.
 *
 * @param conn {net.Conn} the connection
 */
func readRequest(conn as net.Conn) {
    def got as bytes;
    def need as int init -1;
    def crlf as bytes init convert.bytesFromString("utf-8", "\r\n\r\n");
    while ($need < 0 or len($got) < $need) {
        def more as bytes init net.readBytes($conn, 65536);
        if (len($more) == 0) {
            return null;
        }
        $got = binary.concat($got, $more);
        def end as int init binary.indexOf($got, $crlf);
        if ($need >= 0 or $end < 0) {
            continue;
        }
        def head as string init strings.lower(convert.stringFromBytes("utf-8", $got[..$end]));
        def m as regex.Match init regex.find('content-length: *([0-9]+)', $head);
        $need = $end + 4;
        if ($m.start >= 0) {
            $need = $need + convert.toInt($m.groups[0]);
        }
    }
}

/**
 * After 200 ms, listen on an address and answer one connection.
 *
 * @param address {string} the address
 * @param reply {string} the answer
 * @return {int} the connections taken
 */
func serveLate(address as string, reply as string) {
    time.sleep(time.fromMilliseconds(200));
    def l as net.Listener init net.listen($address);
    def n as int init serveRaw($l, [$reply]);
    net.close($l);
    return $n;
}

/**
 * Stop a raw fake.
 *
 * @param f {RawFake} the fake
 * @return {int} the connections it took
 */
func stopRawFake(f as RawFake) {
    net.close($f.listener);
    return task.wait($f.t);
}

func testDroppedConnections() {
    def full as string init "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 35\r\n\r\n" +
        '{"name": "models/gemini-3.8-flash"}';
    def mid as string init "HTTP/1.1 200 OK\r\nContent-Length: 100\r\n\r\n" + '{';
    # refused (kind "runtime"): tried again, and the server is up by then
    def probe as net.Listener init net.listen("127.0.0.1:0");
    def address as string init net.address($probe);
    net.close($probe);
    def late as task of int init spawn {
        return serveLate($address, $full);
    };
    testing.assertEqual(
        model(withBaseUrl(withBackoff(client(KEY), 600), "http://" + $address), "gemini-3.8-flash").name,
        "models/gemini-3.8-flash");
    testing.assertEqual(task.wait($late), 1);
    # closed by the server before any byte (kind "http"): not tried again
    def shut as RawFake init startRawFake(["", $full]);
    try {
        model(withBaseUrl(withBackoff(client(KEY), 0), $shut.base), "gemini-3.8-flash");
        missed("a closed connection");
    } catch (err) {
        testing.assertEqual($err.kind, "gemini");
    }
    testing.assertEqual(stopRawFake($shut), 1);
    # a GET that broke off mid-answer: not sent again either
    def g as RawFake init startRawFake([$mid, $full]);
    try {
        model(withBaseUrl(withBackoff(client(KEY), 0), $g.base), "gemini-3.8-flash");
        missed("a broken GET");
    } catch (err) {
        testing.assertEqual($err.kind, "closed");
    }
    testing.assertEqual(stopRawFake($g), 1);
    # a POST that broke off mid-answer may have been carried out: not sent again
    def h as RawFake init startRawFake([$mid, $full]);
    try {
        chat(
            withBaseUrl(withBackoff(client(KEY), 0), $h.base),
            addUserText(newRequest("gemini-3.8-flash"), "hi"));
        missed("a broken POST");
    } catch (e) {
        testing.assertEqual($e.kind, "closed");
    }
    testing.assertEqual(stopRawFake($h), 1);
}

/**
 * Forty rate-limit header lines for a fake answer.
 *
 * @return {string} the lines
 */
func manyLimits() {
    def lines as string init "";
    for (def i in 10..50) {
        $lines = $lines + "X-RateLimit-Extra-" + convert.toString($i) + ": 1\n";
    }
    return $lines;
}

func testRetryRules() {
    def ok as string init answer(200, '{"name": "models/gemini-3.8-flash"}');
    def f as Fake init startFake({
        "GET /v1beta/models/conflict": answer(
            409,
            '{"error": {"code": 409, "message": "Aborted.", "status": "ABORTED"}}') + NEXT + $ok,
        "GET /v1beta/models/overloaded": answer(529, '{}') + NEXT + $ok,
        "GET /v1beta/models/ms": "429\nRetry-After-Ms: 300\nRetry-After: 0\nContent-Type: application/json\n\n" +
            '{}' +
            NEXT + $ok,
        "GET /v1beta/models/far": "429\nRetry-After: Wed, 01 Jan 2200 00:00:00 GMT\n" +
            manyLimits() +
            "Content-Type: application/json\n\n" + '{}',
        "GET /v1beta/models/date": "429\nRetry-After: Fri, 01 Jan 2100 00:00:00 GMT\nX-RateLimit-Remaining-Requests: 0\nX-RateLimit-Limit-Requests: 60\nContent-Type: application/json\n\n" +
            '{"error": {"code": 429, "message": "Quota exceeded.", "status": "RESOURCE_EXHAUSTED"}}'
    });
    def c as Client init fakeClient($f);
    testing.assertEqual(model($c, "conflict").name, "models/gemini-3.8-flash");
    testing.assertEqual(model($c, "overloaded").name, "models/gemini-3.8-flash");
    def started as time.Time init time.now();
    model($c, "ms");
    testing.assertTrue(time.milliseconds(time.sub(time.now(), $started)) >= 300);
    # an HTTP date far ahead is a wait over a minute: not taken, but named
    try {
        model($c, "date");
        missed("a 429 until 2100");
    } catch (e) {
        def g as GeminiError init $e;
        testing.assertEqual($g.status, 429);
        testing.assertTrue($g.retryAfterMs > MAX_RETRY_WAIT_MS);
        testing.assertEqual($g.limits["x-ratelimit-remaining-requests"], "0");
        testing.assertEqual($g.limits["x-ratelimit-limit-requests"], "60");
        testing.assertEqual($g.limits["retry-after"], "Fri, 01 Jan 2100 00:00:00 GMT");
        testing.assertEqual(len($g.limits), 3);
    }
    # a wait is capped at 1e12 ms, the headers at 32
    try {
        model($c, "far");
        missed("a 429 until 2200");
    } catch (e) {
        def g as GeminiError init $e;
        testing.assertEqual($g.retryAfterMs, 1000000000000);
        testing.assertEqual(len($g.limits), 32);
    }
    testing.assertEqual(len(stopFake($f)), 8);
    try {
        model($c, "bad name");
        missed("a bad name");
    } catch (e) {
        def g as GeminiError init $e;
        testing.assertEqual(len($g.limits), 0);
    }
}

func testCapAndDeadline() {
    def big as string init strings.repeat("x", 70000);
    def f as Fake init startFake({
        "GET /v1beta/models/big": answer(
            200,
            '{"name": "models/big", "description": "' + $big + '"}'),
        "GET /v1beta/models/slow": "SLEEP\n\n"
    });
    def c as Client init withMaxBytes(fakeClient($f), 65536);
    try {
        model($c, "big");
        missed("over the cap");
    } catch (e) {
        testing.assertEqual($e.kind, "limit");
        testing.assertContains($e.message, "the reply is over 65536 bytes");
    }
    try {
        model(withTimeout($c, 1000), "slow");
        missed("past the deadline");
    } catch (e) {
        testing.assertEqual($e.kind, "timeout");
        testing.assertContains($e.message, "no answer within 1000 ms");
    }
    stopFake($f);
}

func testUnreachable() {
    def srv as httpd.Server init httpd.listen("127.0.0.1:0");
    def base as string init "http://" + httpd.address($srv);
    httpd.shutdown($srv);
    try {
        # a refused connection is retried: no backoff here, to be quick
        models(withBackoff(withBaseUrl(client(KEY), $base), 0));
        missed("nobody listening");
    } catch (e) {
        testing.assertEqual($e.kind, "gemini");
        testing.assertContains($e.message, "cannot reach");
        testing.assertFalse(strings.contains($e.message, KEY));
    }
}

func testCall() {
    def f as Fake init startFake({
        "POST /v1beta/models/gemini-3.8-flash:batchGenerateContent": answer(
            200,
            '{"name": "batches/123", "metadata": {"state": "BATCH_STATE_PENDING"}}'),
        "DELETE /v1beta/batches/123": answer(200, ''),
        "GET /v1beta/batches": answer(200, '{}')
    });
    def c as Client init fakeClient($f);
    def body as json.Value init json.decode('{"batch": {"displayName": "nightly"}}');
    def v as json.Value init call(
        $c,
        "POST",
        "/models/gemini-3.8-flash:batchGenerateContent?alt=json",
        $body);
    def gone as json.Value init call($c, "DELETE", "/batches/123", json.decode("null"));
    def listed as json.Value init call(
        $c,
        "GET",
        "/batches?pageSize=10&pageToken=" + uri.encode("tok/2=") + "&filter=",
        json.decode("null"));
    def seen as list of string init stopFake($f);
    testing.assertEqual(json.asString($v, "/name"), "batches/123");
    testing.assertEqual(json.typeOf($gone), "map");
    testing.assertEqual(json.typeOf($listed), "map");
    testing.assertEqual(
        $seen[0],
        "POST /v1beta/models/gemini-3.8-flash:batchGenerateContent?alt=json|x-goog-api-key=" + KEY +
            '|Content-Type=application/json|{"batch":{"displayName":"nightly"}}');
    testing.assertEqual($seen[1], "DELETE /v1beta/batches/123|x-goog-api-key=" + KEY + "|");
    testing.assertEqual(
        $seen[2],
        "GET /v1beta/batches?pageSize=10&pageToken=tok%2F2%3D&filter=|x-goog-api-key=" + KEY + "|");
    for (def bad in [
        "/a/../b",
        "a",
        "/a b",
        "/x/..:y",
        "/x?",
        "/x?noequals",
        "/x?a=b c",
        "/x?a=b#frag",
        "/x?a=b/c",
        "/x?a=%zz",
        "/x?a=b&&c=d",
        "/x?=b",
        "/x?a=b\r\nX-Evil: 1",
        "/x?a=b?c=d"
    ]) {
        try {
            call($c, "GET", $bad, json.decode("null"));
            missed($bad);
        } catch (e) {
            testing.assertEqual($e.kind, "gemini");
            def g as GeminiError init $e;
            testing.assertEqual($g.status, 0);
        }
    }
    try {
        call($c, "PUT", "/x", json.decode("null"));
        missed("PUT");
    } catch (e) {
        testing.assertContains($e.message, "a method is");
    }
}
