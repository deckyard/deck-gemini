# @deckyard/gemini

[![test](https://github.com/deckyard/deck-gemini/actions/workflows/test.yml/badge.svg)](https://github.com/deckyard/deck-gemini/actions/workflows/test.yml)
[![Documentation](https://img.shields.io/badge/docs-github%20pages-blue)](https://deckyard.github.io/deck-gemini/)
[![release](https://img.shields.io/github/v/release/deckyard/deck-gemini)](https://github.com/deckyard/deck-gemini/releases/latest)

A client for the Google™ Gemini™ API as Google AI Studio serves it, for
[Jennifer](https://jennifer-lang.dev/) programs: generate content from text
and media with a system instruction, function calling and a tool loop that
keeps thought signatures, structured output, thinking and safety settings;
count tokens; embeddings; model listing; the Files API for large media;
context caching. Requests and replies are Google's own JSON, every request
has a deadline and a reply cap, and rate limits are retried with backoff.

**[Documentation](https://deckyard.github.io/deck-gemini/)**

## Install

```sh
jvc add @deckyard/gemini
```

This vendors the deck to `vendor/@deckyard/gemini/`. Without `jvc`, unpack
the `src/` subtree of a release archive (`deckyard-gemini-<version>.tar.gz`)
there.

## Usage

```jennifer
import "@deckyard/gemini/" as gemini;
use io;
use json;
use os;

def c as gemini.Client init gemini.client(os.getEnv("GEMINI_API_KEY"));
def req as json.Value init gemini.newRequest("gemini-3.8-flash");
$req = gemini.withSystem($req, "Answer in one sentence.");
$req = gemini.addUserText($req, "Why is the sky blue?");
io.printf("%s\n", gemini.text(gemini.chat($c, $req)));
```

A key comes from [Google AI Studio](https://aistudio.google.com/apikey);
the free tier needs no billing account. The examples in `examples/` (a
conversation, a tool loop, a file upload) read it from `GEMINI_API_KEY`.

## Requirements

Jennifer 0.27.0 or newer, the default binary: the deck opens network
connections (capability `net`), so it does not load on `jennifer-tiny`.
No streaming yet (it waits for streaming `http`); no Vertex AI™ yet.

## Development

```sh
tools/check-all.sh                   # the full gate, as CI runs it
jennifer test src/gemini_test.j      # the test overlay, against a loopback fake
tools/check-docs.sh                  # docs against the code
tools/pack.sh dist                   # build the release archive
```

## Trademarks

Google™, Gemini™ and Vertex AI™ are trademarks of Google LLC. Other product
and company names may be trademarks of their respective owners. They are
used only to identify the products this deck works with. This deck is an
independent project, not affiliated with, sponsored or endorsed by Google
LLC.

## Licence

LGPL-3.0-only, see [LICENSE](LICENSE). Copyright (C) 2026 mplx &lt;mplx@jennifer-lang.dev&gt;.
