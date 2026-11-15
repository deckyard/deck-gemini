# SPDX-License-Identifier: LGPL-3.0-only
# SPDX-FileCopyrightText: Copyright (C) 2026 mplx <mplx@jennifer-lang.dev>
# pragma-jennifer-version: >=0.26.0

# gemini - files: the Files API for media too large to inline. A resumable
# upload (start, then upload and finalize), get, list, delete, and waiting
# for a file to be processed. Spliced into gemini.j via include.

/** The largest file `uploadFile` sends, in bytes: Google's 2 GB. */
export def const MAX_FILE_BYTES as int init 2147483648;

/**
 * A file in the Files API. Google deletes it 48 hours after the upload.
 *
 * @field name {string} its resource name, `files/<id>`
 * @field displayName {string} the name given at upload
 * @field mimeType {string} its MIME type
 * @field sizeBytes {int} its size
 * @field uri {string} the URI to use in `filePart`
 * @field state {string} `PROCESSING`, `ACTIVE` (usable) or `FAILED`
 * @field createTime {string} when it was uploaded, RFC 3339
 * @field expirationTime {string} when Google deletes it, RFC 3339
 * @field sha256Hash {string} the hash of its bytes, base64
 * @field errorMessage {string} why processing failed, `""` otherwise
 */
export def struct FileInfo {
    name as string,
    displayName as string,
    mimeType as string,
    sizeBytes as int,
    uri as string,
    state as string,
    createTime as string,
    expirationTime as string,
    sha256Hash as string,
    errorMessage as string
};

/**
 * A file as the API describes it.
 *
 * @param v {json.Value} the File object
 * @return {FileInfo} the file
 */
func fileFrom(v as json.Value) {
    if (json.typeOf($v, "/name") != "string") {
        fail("the reply holds no file");
    }
    return FileInfo{
        name: textAt($v, "/name"),
        displayName: textAt($v, "/displayName"),
        mimeType: textAt($v, "/mimeType"),
        sizeBytes: intAt($v, "/sizeBytes"),
        uri: textAt($v, "/uri"),
        state: textAt($v, "/state"),
        createTime: textAt($v, "/createTime"),
        expirationTime: textAt($v, "/expirationTime"),
        sha256Hash: textAt($v, "/sha256Hash"),
        errorMessage: textAt($v, "/error/message")
    };
}

/**
 * The deadline of an upload's data step: `withUploadTimeout`, else 5
 * minutes plus 1 minute per 100 MB begun.
 *
 * @param c {Client} the client
 * @param size {int} the file's size in bytes
 * @return {int} milliseconds
 */
func uploadDeadline(c as Client, size as int) {
    if ($c.uploadTimeoutMs > 0) {
        return $c.uploadTimeoutMs;
    }
    return 300000 + 60000 * (($size + 99999999) // 100000000);
}

/**
 * Upload media to the Files API in Google's resumable protocol: a start
 * request (with the key) that returns an upload URL, then the bytes to that
 * URL in one `upload, finalize` step (without the key: the URL carries the
 * upload's id). The upload URL must be on the client's server. The start is
 * retried like any request; the data step is not, and has its own deadline
 * (`withUploadTimeout`; by default 5 minutes plus 1 minute per 100 MB). Videos and large PDFs
 * are processed after the upload: `waitForFile` until the state is
 * `ACTIVE`.
 *
 * @param c {Client} the client
 * @param data {bytes} the media, at most `MAX_FILE_BYTES`
 * @param mimeType {string} such as `video/mp4` or `application/pdf`
 * @param displayName {string} a name for people, at most 512 characters, `""` for none
 * @return {FileInfo} the file; use its `uri` in `filePart`
 * @throws {GeminiError} kind "gemini" when an argument is malformed, the API refuses, or the upload URL is missing or on another server
 * @throws {Error} kind "limit" when the media is over `MAX_FILE_BYTES`
 * @example
 *   def f as gemini.FileInfo init gemini.uploadFile($c, fs.readBytes("talk.mp3"), "audio/mpeg", "talk");
 *   $req = gemini.addParts($req, "user", [gemini.textPart("Summarise this."), gemini.filePart($f.mimeType, $f.uri)]);
 */
export func uploadFile(c as Client, data as bytes, mimeType as string, displayName as string) {
    checkMime($mimeType);
    if (len($displayName) > 512) {
        fail("a display name is at most 512 characters");
    }
    if (len($data) == 0) {
        fail("upload: the file is empty");
    }
    if (len($data) > MAX_FILE_BYTES) {
        failLimit(io.sprintf("upload: the file is over %d bytes", MAX_FILE_BYTES));
    }
    def what as string init "upload " + shown($displayName);
    def meta as json.Value init json.map();
    if ($displayName != "") {
        $meta = json.set($meta, "/displayName", $displayName);
    }
    def start as http.BytesResponse init send(
        $c,
        "POST",
        $c.baseUrl + "/upload/" + API_VERSION + "/files",
        {
            "X-Goog-Upload-Protocol": "resumable",
            "X-Goog-Upload-Command": "start",
            "X-Goog-Upload-Header-Content-Length": convert.toString(len($data)),
            "X-Goog-Upload-Header-Content-Type": $mimeType,
            "Content-Type": "application/json"
        },
        json.encode(json.map({"file": $meta})),
        $what);
    checkStatus($c, $start, $what);
    def url as string init "";
    if (maps.has($start.headers, "x-goog-upload-url")) {
        $url = strings.trim($start.headers["x-goog-upload-url"]);
    }
    def origin as regex.Match init regex.find('^https?://[^/]+', $c.baseUrl);
    if (not strings.startsWith($url, $origin.text + "/") or regex.matches('[\x00-\x20\x7f]', $url)) {
        fail($what + ": the server sent no upload URL on its own origin");
    }
    def r as http.BytesResponse init exchangeRaw(
        $c,
        "POST",
        $url,
        {"X-Goog-Upload-Offset": "0", "X-Goog-Upload-Command": "upload, finalize"},
        $data,
        uploadDeadline($c, len($data)),
        $what);
    checkStatus($c, $r, $what);
    def v as json.Value init jsonBody($r, $what);
    if (json.typeOf($v, "/file") != "map") {
        fail($what + ": the reply holds no file");
    }
    return fileFrom(json.get($v, "/file"));
}

/**
 * One file's metadata.
 *
 * @param c {Client} the client
 * @param name {string} `files/<id>` or the bare id
 * @return {FileInfo} the file
 * @throws {GeminiError} kind "gemini" when the name is malformed or the API refuses (404 once deleted or expired)
 */
export func file(c as Client, name as string) {
    def n as string init resourceName("files", $name);
    return fileFrom(apiRequest($c, "GET", "/" + $n, "", "file " + $n));
}

/**
 * Every file of the project, all pages.
 *
 * @param c {Client} the client
 * @return {list of FileInfo} the files
 * @throws {GeminiError} kind "gemini" when the API refuses
 * @throws {Error} kind "limit" after `MAX_PAGES` pages, or when they are over the reply cap together
 */
export func files(c as Client) {
    def out as list of FileInfo init [];
    for (def v in pages($c, "/files", "files", 100, "files")) {
        $out[] = fileFrom($v);
    }
    return $out;
}

/**
 * Delete a file.
 *
 * @param c {Client} the client
 * @param name {string} `files/<id>` or the bare id
 * @throws {GeminiError} kind "gemini" when the name is malformed or the API refuses (404 when it is gone)
 */
export func deleteFile(c as Client, name as string) {
    def n as string init resourceName("files", $name);
    apiRequest($c, "DELETE", "/" + $n, "", "delete " + $n);
}

/**
 * Wait until a file is processed, polling its state: every half second at
 * first, then less often, at most every 5 seconds.
 *
 * @param c {Client} the client
 * @param name {string} `files/<id>` or the bare id
 * @param timeoutMs {int} how long to wait, 1000 to 3600000 milliseconds
 * @return {FileInfo} the file, `ACTIVE`
 * @throws {GeminiError} kind "gemini" when processing failed (state `FAILED`) or the API refuses
 * @throws {Error} kind "timeout" when it is still processing after `timeoutMs`
 */
export func waitForFile(c as Client, name as string, timeoutMs as int) {
    checkRange($timeoutMs, 1000, 3600000, "the wait");
    def deadline as time.Time init time.add(time.now(), time.fromMilliseconds($timeoutMs));
    def pause as int init 500;
    while (true) {
        def f as FileInfo init file($c, $name);
        if ($f.state == "ACTIVE") {
            return $f;
        }
        if ($f.state == "FAILED") {
            fail("file " + $f.name + ": processing failed: " + redacted($c, $f.errorMessage, 300));
        }
        if (time.after(time.add(time.now(), time.fromMilliseconds($pause)), $deadline)) {
            throw Error{
                kind: "timeout",
                message: io.sprintf(
                    "gemini: file %s: still %s after %d ms",
                    $f.name,
                    cleaned($f.state, 32),
                    $timeoutMs)
            };
        }
        time.sleep(time.fromMilliseconds($pause));
        $pause = math.min($pause * 2, 5000);
    }
}
