# SPDX-License-Identifier: LGPL-3.0-only
# SPDX-FileCopyrightText: Copyright (C) 2026 mplx <mplx@jennifer-lang.dev>
# pragma-jennifer-version: >=0.26.0

# gemini - white-box tests for the caches topic. Spliced into gemini_test.j
# via include.

# a CachedContent as the API reference describes it
def const CACHED as string init '{"name": "cachedContents/4d2kd477o3pg", "model": "models/gemini-3.8-flash", "displayName": "manual", "createTime": "2026-11-14T10:00:00.000000Z", "updateTime": "2026-11-14T10:00:00.000000Z", "expireTime": "2026-11-14T10:05:00.000000Z", "usageMetadata": {"totalTokenCount": 43130}}';

func testCacheLifecycle() {
    def renewed as string init strings.replace(CACHED, "10:05:00", "10:10:00");
    def f as Fake init startFake({
        "POST /v1beta/cachedContents": answer(200, CACHED),
        "GET /v1beta/cachedContents/4d2kd477o3pg": answer(200, CACHED),
        "GET /v1beta/cachedContents?pageSize=1000": answer(
            200,
            '{"cachedContents": [' + CACHED + ']}'),
        "PATCH /v1beta/cachedContents/4d2kd477o3pg": answer(200, $renewed),
        "DELETE /v1beta/cachedContents/4d2kd477o3pg": answer(200, '{}'),
        "POST /v1beta/models/gemini-3.8-flash:generateContent": answer(
            200,
            '{"candidates": [{"content": {"role": "model", "parts": [{"text": "Chapter 2 is about caching."}]}, "finishReason": "STOP"}], "usageMetadata": {"promptTokenCount": 43140, "cachedContentTokenCount": 43130, "candidatesTokenCount": 7, "totalTokenCount": 43147}}')
    });
    def c as Client init fakeClient($f);
    def docs as json.Value init withSystem(
        newRequest("gemini-3.8-flash"),
        "You answer questions about the manual.");
    $docs = addParts(
        $docs,
        "user",
        [inlinePart("text/plain", convert.bytesFromString("utf-8", "the manual"))]);
    $docs = withConfig($docs, "temperature", json.decode("0.5"));
    def made as CacheInfo init createCache($c, $docs, 300, "manual");
    def got as CacheInfo init cache($c, "cachedContents/4d2kd477o3pg");
    def all as list of CacheInfo init caches($c);
    def later as CacheInfo init updateCacheTtl($c, $made.name, 600);
    def req as json.Value init addUserText(
        withCachedContent(newRequest("gemini-3.8-flash"), $made.name),
        "What does chapter 2 say?");
    def reply as json.Value init chat($c, $req);
    deleteCache($c, "4d2kd477o3pg");
    def seen as list of string init stopFake($f);
    testing.assertEqual($made.name, "cachedContents/4d2kd477o3pg");
    testing.assertEqual($made.totalTokens, 43130);
    testing.assertEqual($made.model, "models/gemini-3.8-flash");
    testing.assertEqual($got.expireTime, "2026-11-14T10:05:00.000000Z");
    testing.assertEqual(len($all), 1);
    testing.assertEqual($later.expireTime, "2026-11-14T10:10:00.000000Z");
    testing.assertEqual(usage($reply).cachedTokens, 43130);
    testing.assertEqual(len($seen), 6);
    # create: the model, the name, the request's prefix, the TTL; no generationConfig
    def created as json.Value init seenBody($seen[0]);
    testing.assertEqual(
        json.keys($created),
        ["model", "displayName", "systemInstruction", "contents", "ttl"]);
    testing.assertEqual(json.asString($created, "/ttl"), "300s");
    testing.assertEqual(
        json.asString($created, "/contents/0/parts/0/inlineData/data"),
        "dGhlIG1hbnVhbA==");
    testing.assertEqual(
        $seen[3],
        "PATCH /v1beta/cachedContents/4d2kd477o3pg?updateMask=ttl|x-goog-api-key=" + KEY +
            '|Content-Type=application/json|{"ttl":"600s"}');
    testing.assertEqual(
        json.asString(seenBody($seen[4]), "/cachedContent"),
        "cachedContents/4d2kd477o3pg");
    testing.assertEqual(
        $seen[5],
        "DELETE /v1beta/cachedContents/4d2kd477o3pg|x-goog-api-key=" + KEY + "|");
    for (def bad in [0, MAX_CACHE_TTL_SECONDS + 1]) {
        try {
            updateCacheTtl($c, $made.name, $bad);
            missed("ttl");
        } catch (e) {
            testing.assertContains($e.message, "the TTL in seconds must be");
        }
    }
    try {
        createCache($c, $docs, 60, strings.repeat("n", 129));
        missed("name");
    } catch (e) {
        testing.assertContains($e.message, "at most 128");
    }
    try {
        cache($c, "cachedContents/A B");
        missed("id");
    } catch (e) {
        testing.assertContains($e.message, "a name is cachedContents/<id>");
    }
}
