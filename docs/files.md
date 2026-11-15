<!-- SPDX-License-Identifier: LGPL-3.0-only -->
<!-- SPDX-FileCopyrightText: Copyright (C) 2026 mplx <mplx@jennifer-lang.dev> -->

# Files

Media too large to inline (a request is at most 100 MB in all), or used in
several requests, goes through the Files API: upload it once, then refer
to it with `filePart`. A file is at most 2 GB, a project holds at most
20 GB, and Google deletes a file 48 hours after its upload.

```jennifer
import "@deckyard/gemini/" as gemini;
use fs;
use io;
use json;
use os;

def c as gemini.Client init gemini.client(os.getEnv("GEMINI_API_KEY"));
def f as gemini.FileInfo init gemini.uploadFile($c, fs.readBytes("talk.mp4"), "video/mp4", "talk");
$f = gemini.waitForFile($c, $f.name, 300000);
def req as json.Value init gemini.addParts(gemini.newRequest("gemini-3.8-flash"), "user", [
    gemini.filePart($f.mimeType, $f.uri),
    gemini.textPart("Summarise this talk in five bullet points.")
]);
io.printf("%s\n", gemini.text(gemini.chat($c, $req)));
gemini.deleteFile($c, $f.name);
```

## The upload

`uploadFile(c, data, mimeType, displayName)` follows Google's resumable
protocol in two requests:

1. `POST <base>/upload/v1beta/files` with the key and
   `X-Goog-Upload-Protocol: resumable`, `X-Goog-Upload-Command: start`,
   `X-Goog-Upload-Header-Content-Length` and
   `X-Goog-Upload-Header-Content-Type`, and `{"file": {"displayName"}}`
   as the body. The answer's `x-goog-upload-url` header is where the bytes
   go.
2. `POST <upload url>` with `X-Goog-Upload-Offset: 0`,
   `X-Goog-Upload-Command: upload, finalize` and the bytes as they are.
   The upload URL carries the upload's id, so the key is not sent again;
   the deck refuses an upload URL on another server than the client's.

The start is retried like any request. The data step is not: send the
file again after a failure. It has its own deadline, 5 minutes plus 1
minute per 100 MB begun (25 minutes for 2 GB), or what
`withUploadTimeout(c, ms)` sets; the client's `withTimeout` covers the
other requests. The whole file is held in memory until `http`
streams request bodies (M30.9).

## Processing, listing, deleting

A file may be `PROCESSING` for a while after its upload (video above
all) before it can be used. `waitForFile(c, name, timeoutMs)` polls until the
state is `ACTIVE` (every half second at first, at most every 5 s), throws
kind `"gemini"` on `FAILED` and kind `"timeout"` when the time is up.

| Function | Does |
|---|---|
| `file(c, name)` | one file's metadata |
| `files(c)` | every file of the project, all pages |
| `deleteFile(c, name)` | delete it before it expires |

`files` reads up to `MAX_FILE_PAGES` pages of 100 files (100,000 files);
all pages together stay under the client's reply cap. A name is
`files/<id>` or the bare id.
