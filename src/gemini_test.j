# SPDX-License-Identifier: LGPL-3.0-only
# SPDX-FileCopyrightText: Copyright (C) 2026 mplx <mplx@jennifer-lang.dev>
# pragma-jennifer-version: >=0.28.0

/**
 * White-box tests: jennifer test src/gemini_test.j
 *
 * No test needs an API key or the network. A fake on 127.0.0.1
 * (`startFake` in the core overlay) answers each request from a script and
 * records what it got; the answers follow the shapes of Google's API
 * reference and its documented examples. The topic overlays are fragments
 * spliced in here, not standalone suites.
 */
use binary;
use httpd;
use net;
use testing;

include "topics/core_test.j";
include "topics/content_test.j";
include "topics/tools_test.j";
include "topics/embed_test.j";
include "topics/files_test.j";
include "topics/caches_test.j";
