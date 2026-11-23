#!/usr/bin/env -S jennifer run
# SPDX-License-Identifier: LGPL-3.0-only
# SPDX-FileCopyrightText: Copyright (C) 2026 mplx <mplx@jennifer-lang.dev>
# pragma-jennifer-version: >=0.27.0

/**
 * Upload a file through the Files API, ask about it, and delete it:
 *
 *   GEMINI_API_KEY=... jennifer run examples/upload.j talk.mp3 audio/mpeg "Summarise this."
 *
 * GEMINI_BASE_URL points it at a proxy serving the same API.
 */

use fs;
use io;
use json;
use os;
use path;

import "../src/gemini.j" as gemini;

if (not os.hasEnv("GEMINI_API_KEY") or len(os.ARGS) < 4) {
    io.printf("usage: GEMINI_API_KEY=... jennifer run examples/upload.j FILE MIME-TYPE QUESTION\n");
    exit 0;
}
def c as gemini.Client init gemini.client(os.getEnv("GEMINI_API_KEY"));
if (os.hasEnv("GEMINI_BASE_URL")) {
    $c = gemini.withBaseUrl($c, os.getEnv("GEMINI_BASE_URL"));
}
def f as gemini.FileInfo init gemini.uploadFile(
    $c,
    fs.readBytes(os.ARGS[1]),
    os.ARGS[2],
    path.base(os.ARGS[1]));
io.printf("uploaded %s (%d bytes), %s\n", $f.name, $f.sizeBytes, $f.state);
$f = gemini.waitForFile($c, $f.name, 600000);
def req as json.Value init gemini.addParts(
    gemini.newRequest("gemini-3.8-flash"),
    "user",
    [gemini.filePart($f.mimeType, $f.uri), gemini.textPart(os.ARGS[3])]);
io.printf("%s\n", gemini.text(gemini.chat($c, $req)));
gemini.deleteFile($c, $f.name);
io.printf("deleted %s\n", $f.name);
