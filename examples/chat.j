#!/usr/bin/env -S jennifer run
# SPDX-License-Identifier: LGPL-3.0-only
# SPDX-FileCopyrightText: Copyright (C) 2026 mplx <mplx@jennifer-lang.dev>
# pragma-jennifer-version: >=0.27.0

/**
 * Ask Gemini a question, then a follow-up, and show the token counts:
 *
 *   GEMINI_API_KEY=... jennifer run examples/chat.j "Why is the sky blue?"
 *
 * GEMINI_MODEL picks another model (default gemini-3.8-flash).
 *
 * GEMINI_BASE_URL points it at a proxy serving the same API.
 */

use io;
use json;
use os;

import "../src/gemini.j" as gemini;

if (not os.hasEnv("GEMINI_API_KEY") or len(os.ARGS) < 2) {
    io.printf("usage: GEMINI_API_KEY=... jennifer run examples/chat.j QUESTION\n");
    exit 0;
}
def model as string init "gemini-3.8-flash";
if (os.hasEnv("GEMINI_MODEL")) {
    $model = os.getEnv("GEMINI_MODEL");
}
def c as gemini.Client init gemini.client(os.getEnv("GEMINI_API_KEY"));
if (os.hasEnv("GEMINI_BASE_URL")) {
    $c = gemini.withBaseUrl($c, os.getEnv("GEMINI_BASE_URL"));
}
def req as json.Value init gemini.withSystem(
    gemini.newRequest($model),
    "Answer in at most three sentences.");
$req = gemini.withThinkingLevel(gemini.addUserText($req, os.ARGS[1]), "low");
def reply as json.Value init gemini.chat($c, $req);
if (gemini.blockReason($reply) != "") {
    io.printf("blocked: %s\n", gemini.blockReason($reply));
    exit 1;
}
io.printf("%s\n\n", gemini.text($reply));
$req = gemini.addUserText(gemini.addReply($req, $reply), "Now explain it to a five-year-old.");
$reply = gemini.chat($c, $req);
io.printf("%s\n", gemini.text($reply));
def u as gemini.Usage init gemini.usage($reply);
io.printf(
    "\n(%d prompt, %d thinking, %d answer tokens)\n",
    $u.inputTokens,
    $u.reasoningTokens,
    $u.outputTokens);
