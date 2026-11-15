<!-- SPDX-License-Identifier: LGPL-3.0-only -->
<!-- SPDX-FileCopyrightText: Copyright (C) 2026 mplx <mplx@jennifer-lang.dev> -->

# Context caching

A long prefix used by many requests (a manual, a codebase, a video, the
same system instruction and tools) can be cached once; requests then name
the cache and are billed less for the cached tokens. Gemini 2.5 and later
also cache implicitly, without any of this; explicit caches work with
Gemini 2.5 and 3 models, not with Gemini 4.

```jennifer
import "@deckyard/gemini/" as gemini;
use fs;
use io;
use json;
use os;

def c as gemini.Client init gemini.client(os.getEnv("GEMINI_API_KEY"));
def docs as json.Value init gemini.newRequest("gemini-3.8-flash");
$docs = gemini.withSystem($docs, "You answer questions about the attached manual.");
$docs = gemini.addParts($docs, "user", [gemini.inlinePart("application/pdf", fs.readBytes("manual.pdf"))]);
def cache as gemini.CacheInfo init gemini.createCache($c, $docs, 3600, "manual");

def req as json.Value init gemini.withCachedContent(gemini.newRequest("gemini-3.8-flash"), $cache.name);
$req = gemini.addUserText($req, "What does chapter 2 say about maintenance?");
def reply as json.Value init gemini.chat($c, $req);
io.printf("%s\n(%d cached tokens)\n", gemini.text($reply), gemini.usage($reply).cachedTokens);
```

`createCache(c, req, ttlSeconds, displayName)` caches a request's model,
system instruction, contents, tools and tool config; its other fields
(`generationConfig`, safety settings) stay with each request. A request
using the cache carries only what follows and must name the same model.
The API refuses a cache below a minimum size (2048 to 4096 tokens, per
model) with a 400.

| Function | Does |
|---|---|
| `cache(c, name)` | one cache's metadata, with its `expireTime` and `totalTokens` |
| `caches(c)` | every cache of the project, all pages |
| `updateCacheTtl(c, name, ttlSeconds)` | a new TTL from now, the only change the API allows (sent with `updateMask=ttl`) |
| `deleteCache(c, name)` | delete it before it expires |

A cache costs storage per hour until it expires (one hour by default in
Google's SDKs; here the TTL is always given). A name is
`cachedContents/<id>` or the bare id.
