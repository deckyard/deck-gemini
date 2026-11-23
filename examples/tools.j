#!/usr/bin/env -S jennifer run
# SPDX-License-Identifier: LGPL-3.0-only
# SPDX-FileCopyrightText: Copyright (C) 2026 mplx <mplx@jennifer-lang.dev>
# pragma-jennifer-version: >=0.27.0

/**
 * A tool loop: the model answers with the help of two local functions,
 * calling them as often as it needs:
 *
 *   GEMINI_API_KEY=... jennifer run examples/tools.j
 *
 * GEMINI_BASE_URL points it at a proxy serving the same API.
 */

use io;
use json;
use math;
use os;
use time;

import "../src/gemini.j" as gemini;

/**
 * Run a function the model asked for.
 *
 * @param name {string} the function
 * @param input {json.Value} its arguments
 * @return {json.Value} its result
 */
func runTool(name as string, input as json.Value) {
    io.printf("  [the model calls %s %s]\n", $name, json.encode($input));
    if ($name == "now") {
        return json.map({"utc": time.iso(time.inZone(time.now(), time.UTC))});
    }
    if ($name == "hypotenuse") {
        def a as float init json.asFloat($input, "/a");
        def b as float init json.asFloat($input, "/b");
        return json.map({"c": math.hypot($a, $b)});
    }
    return gemini.toolError("no such function: " + $name);
}

if (not os.hasEnv("GEMINI_API_KEY")) {
    io.printf("usage: GEMINI_API_KEY=... jennifer run examples/tools.j\n");
    exit 0;
}
def c as gemini.Client init gemini.client(os.getEnv("GEMINI_API_KEY"));
if (os.hasEnv("GEMINI_BASE_URL")) {
    $c = gemini.withBaseUrl($c, os.getEnv("GEMINI_BASE_URL"));
}
def sides as json.Value init json.decode(
    '{"type": "object", "properties": {"a": {"type": "number"}, "b": {"type": "number"}}, ' +
        '"required": ["a", "b"]}');
def tools as list of json.Value init [
    gemini.tool("now", "The current date and time in UTC.", json.decode("null")),
    gemini.tool("hypotenuse", "The hypotenuse of a right triangle with legs a and b.", $sides)
];
def req as json.Value init gemini.addTools(gemini.newRequest("gemini-3.8-flash"), $tools);
$req = gemini.addUserText(
    $req,
    "What day of the week is it, and how long is the diagonal of a 3 by 4 rectangle?");
def run as gemini.ToolRun init gemini.runTools($c, $req, runTool, 10);
if ($run.stopped == "maxTurns") {
    io.printf("(the model was still calling functions after %d turns)\n", $run.turns);
    exit 1;
}
io.printf(
    "%s\n(%d turns, %d calls, %d tokens)\n",
    gemini.text($run.reply),
    $run.turns,
    $run.calls,
    $run.usage.totalTokens);
