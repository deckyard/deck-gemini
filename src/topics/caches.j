# SPDX-License-Identifier: LGPL-3.0-only
# SPDX-FileCopyrightText: Copyright (C) 2026 mplx <mplx@jennifer-lang.dev>
# pragma-jennifer-version: >=0.26.0

# gemini - caches: explicit context caching (`cachedContents`): create from
# a request, get, list, update the TTL, delete. Spliced into gemini.j via
# include.

/** The longest TTL `createCache` and `updateCacheTtl` take, in seconds: a year. */
export def const MAX_CACHE_TTL_SECONDS as int init 31536000;

/**
 * A context cache.
 *
 * @field name {string} its resource name, `cachedContents/<id>`; pass it to `withCachedContent`
 * @field displayName {string} the name given at creation
 * @field model {string} the model it is for, `models/<id>`
 * @field createTime {string} when it was created, RFC 3339
 * @field updateTime {string} when it was last updated, RFC 3339
 * @field expireTime {string} when it expires, RFC 3339
 * @field totalTokens {int} how many tokens it holds
 */
export def struct CacheInfo {
    name as string,
    displayName as string,
    model as string,
    createTime as string,
    updateTime as string,
    expireTime as string,
    totalTokens as int
};

/**
 * A cache as the API describes it.
 *
 * @param v {json.Value} the CachedContent object
 * @return {CacheInfo} the cache
 */
func cacheFrom(v as json.Value) {
    if (json.typeOf($v, "/name") != "string") {
        fail("the reply holds no cache");
    }
    return CacheInfo{
        name: textAt($v, "/name"),
        displayName: textAt($v, "/displayName"),
        model: textAt($v, "/model"),
        createTime: textAt($v, "/createTime"),
        updateTime: textAt($v, "/updateTime"),
        expireTime: textAt($v, "/expireTime"),
        totalTokens: intAt($v, "/usageMetadata/totalTokenCount")
    };
}

/**
 * A TTL as the API writes it.
 *
 * @param seconds {int} the TTL
 * @return {string} such as `300s`
 */
func ttlText(seconds as int) {
    checkRange($seconds, 1, MAX_CACHE_TTL_SECONDS, "the TTL in seconds");
    return convert.toString($seconds) + "s";
}

/**
 * Cache a request's prefix: its model, system instruction, contents, tools
 * and tool config (other fields are left out). Later requests for the same
 * model name it with `withCachedContent` and carry only what follows. The
 * API wants a minimum of tokens (thousands, per model) and supports
 * explicit caching on Gemini 2.5 and 3 models, not on Gemini 4.
 *
 * @param c {Client} the client
 * @param req {json.Value} the request whose prefix to cache, from `newRequest`
 * @param ttlSeconds {int} how long to keep it, 1 to `MAX_CACHE_TTL_SECONDS`
 * @param displayName {string} a name for people, at most 128 characters, `""` for none
 * @return {CacheInfo} the cache
 * @throws {GeminiError} kind "gemini" when an argument is malformed or the API refuses (too few tokens is a 400)
 * @example
 *   def cache as gemini.CacheInfo init gemini.createCache($c, $docs, 3600, "manual");
 *   def req as json.Value init gemini.addUserText(gemini.withCachedContent(gemini.newRequest("gemini-3.8-flash"), $cache.name), "What does chapter 2 say?");
 */
export func createCache(c as Client, req as json.Value, ttlSeconds as int, displayName as string) {
    def name as string init requestModel($req);
    if (len($displayName) > 128) {
        fail("a cache's display name is at most 128 characters");
    }
    def m as map of string to json.Value init {"model": json.decode(json.encode($name))};
    if ($displayName != "") {
        $m["displayName"] = json.decode(json.encode($displayName));
    }
    for (def key in ["systemInstruction", "contents", "tools", "toolConfig"]) {
        if (json.has($req, "/" + $key)) {
            $m[$key] = json.get($req, "/" + $key);
        }
    }
    $m["ttl"] = json.decode(json.encode(ttlText($ttlSeconds)));
    def v as json.Value init apiRequest(
        $c,
        "POST",
        "/cachedContents",
        json.encode(json.map($m)),
        "createCache " + $name);
    return cacheFrom($v);
}

/**
 * One cache's metadata.
 *
 * @param c {Client} the client
 * @param name {string} `cachedContents/<id>` or the bare id
 * @return {CacheInfo} the cache
 * @throws {GeminiError} kind "gemini" when the name is malformed or the API refuses (404 once expired)
 */
export func cache(c as Client, name as string) {
    def n as string init resourceName("cachedContents", $name);
    return cacheFrom(apiRequest($c, "GET", "/" + $n, "", "cache " + $n));
}

/**
 * Every cache of the project, all pages.
 *
 * @param c {Client} the client
 * @return {list of CacheInfo} the caches
 * @throws {GeminiError} kind "gemini" when the API refuses
 * @throws {Error} kind "limit" after `MAX_PAGES` pages, or when they are over the reply cap together
 */
export func caches(c as Client) {
    def out as list of CacheInfo init [];
    for (def v in pages($c, "/cachedContents", "cachedContents", 1000, MAX_PAGES, "caches")) {
        $out[] = cacheFrom($v);
    }
    return $out;
}

/**
 * Give a cache a new TTL from now; the only change the API allows. The
 * request names the field it changes (`updateMask=ttl`).
 *
 * @param c {Client} the client
 * @param name {string} `cachedContents/<id>` or the bare id
 * @param ttlSeconds {int} 1 to `MAX_CACHE_TTL_SECONDS`
 * @return {CacheInfo} the cache, with its new `expireTime`
 * @throws {GeminiError} kind "gemini" when an argument is malformed or the API refuses
 */
export func updateCacheTtl(c as Client, name as string, ttlSeconds as int) {
    def n as string init resourceName("cachedContents", $name);
    def body as json.Value init json.map({"ttl": ttlText($ttlSeconds)});
    return cacheFrom(apiRequest(
        $c,
        "PATCH",
        "/" + $n + "?updateMask=ttl",
        json.encode($body),
        "updateCacheTtl " + $n));
}

/**
 * Delete a cache before it expires.
 *
 * @param c {Client} the client
 * @param name {string} `cachedContents/<id>` or the bare id
 * @throws {GeminiError} kind "gemini" when the name is malformed or the API refuses
 */
export func deleteCache(c as Client, name as string) {
    def n as string init resourceName("cachedContents", $name);
    apiRequest($c, "DELETE", "/" + $n, "", "deleteCache " + $n);
}
