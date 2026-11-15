#!/usr/bin/env bash
# SPDX-License-Identifier: LGPL-3.0-only
# SPDX-FileCopyrightText: Copyright (C) 2026 mplx <mplx@jennifer-lang.dev>
#
# gemini overrides the shared example runner.
#
# The examples call the Gemini API and need an API key (GEMINI_API_KEY),
# which CI does not have, so running them would only print their usage.
# CI checks that each one still parses against the current language and
# module surface; `jennifer lint` covers them too, in the test workflow, and
# reaches undefined calls. The suite tests every call against a loopback
# fake answering with the shapes of Google's documented replies.
set -euo pipefail
cd "$(dirname "$0")/.."
exec env EXAMPLES_SKIP_RUN=1 tools/check-examples-shared.sh
