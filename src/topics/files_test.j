# SPDX-License-Identifier: LGPL-3.0-only
# SPDX-FileCopyrightText: Copyright (C) 2026 mplx <mplx@jennifer-lang.dev>
# pragma-jennifer-version: >=0.27.0

# gemini - white-box tests for the files topic. Spliced into gemini_test.j
# via include.

# a File as the API reference describes it
def const UPLOADED as string init '{"name": "files/abc-123", "displayName": "talk", "mimeType": "audio/mpeg", "sizeBytes": "4", "createTime": "2026-11-14T10:00:00.000000Z", "updateTime": "2026-11-14T10:00:00.000000Z", "expirationTime": "2026-11-16T10:00:00.000000Z", "sha256Hash": "ZmFrZS1oYXNo", "uri": "https://generativelanguage.googleapis.com/v1beta/files/abc-123", "state": "ACTIVE", "source": "UPLOADED"}';

func testUploadFollowsTheResumableProtocol() {
    def f as Fake init startFake({
        "POST /upload/v1beta/files": "200\nX-Goog-Upload-Status: active\nX-Goog-Upload-Url: $BASE/upload/v1beta/files?upload_id=ADPycdu-xyz&upload_protocol=resumable\nX-Goog-Upload-Chunk-Granularity: 8388608\nContent-Type: text/plain\n\n",
        "POST /upload/v1beta/files?upload_id=ADPycdu-xyz&upload_protocol=resumable": answer(
            200,
            '{"file": ' + UPLOADED + '}')
    });
    def data as bytes;
    for (def b in [0, 255, 10, 65]) {
        $data[] = $b;
    }
    def info as FileInfo init uploadFile(fakeClient($f), $data, "audio/mpeg", "talk");
    def seen as list of string init stopFake($f);
    testing.assertEqual($info.name, "files/abc-123");
    testing.assertEqual($info.sizeBytes, 4);
    testing.assertEqual($info.state, "ACTIVE");
    testing.assertEqual(
        $info.uri,
        "https://generativelanguage.googleapis.com/v1beta/files/abc-123");
    testing.assertEqual($info.expirationTime, "2026-11-16T10:00:00.000000Z");
    testing.assertEqual(len($seen), 2);
    # start: the key, the protocol headers, the metadata
    testing.assertEqual(
        $seen[0],
        "POST /upload/v1beta/files|x-goog-api-key=" + KEY +
            "|Content-Type=application/json|X-Goog-Upload-Protocol=resumable|X-Goog-Upload-Command=start" +
            "|X-Goog-Upload-Header-Content-Length=4|X-Goog-Upload-Header-Content-Type=audio/mpeg" +
            '|{"file":{"displayName":"talk"}}');
    # upload and finalize: the bytes as they are, no key
    testing.assertEqual(
        $seen[1],
        "POST /upload/v1beta/files?upload_id=ADPycdu-xyz&upload_protocol=resumable" +
            "|X-Goog-Upload-Command=upload, finalize|X-Goog-Upload-Offset=0|hex:00ff0a41");
    def part as json.Value init filePart($info.mimeType, $info.uri);
    testing.assertEqual(json.asString($part, "/fileData/fileUri"), $info.uri);
}

func testUploadRefusals() {
    def f as Fake init startFake({
        "POST /upload/v1beta/files": "200\nX-Goog-Upload-Url: https://elsewhere.example.org/upload?upload_id=1\n\n"
    });
    def c as Client init fakeClient($f);
    def one as bytes;
    $one[] = 1;
    try {
        uploadFile($c, $one, "image/png", "");
        missed("another origin");
    } catch (e) {
        testing.assertContains($e.message, "no upload URL on its own origin");
    }
    def empty as bytes;
    try {
        uploadFile($c, $empty, "image/png", "");
        missed("empty");
    } catch (e) {
        testing.assertContains($e.message, "the file is empty");
    }
    try {
        uploadFile($c, $one, "png", "");
        missed("mime");
    } catch (e) {
        testing.assertContains($e.message, "a MIME type is");
    }
    try {
        uploadFile($c, $one, "image/png", strings.replicate("n", 513));
        missed("name");
    } catch (e) {
        testing.assertContains($e.message, "at most 512");
    }
    def seen as list of string init stopFake($f);
    testing.assertEqual(len($seen), 1);
    testing.assertEqual(
        $seen[0],
        "POST /upload/v1beta/files|x-goog-api-key=" + KEY +
            "|Content-Type=application/json|X-Goog-Upload-Protocol=resumable|X-Goog-Upload-Command=start" +
            '|X-Goog-Upload-Header-Content-Length=1|X-Goog-Upload-Header-Content-Type=image/png|{"file":{}}');
}

func testFilesGetListDeleteWait() {
    def processing as string init strings.replace(UPLOADED, '"ACTIVE"', '"PROCESSING"');
    def failed as string init strings.replace(
        UPLOADED,
        '"state": "ACTIVE"',
        '"state": "FAILED", "error": {"code": 3, "message": "The video could not be decoded."}');
    def f as Fake init startFake({
        "GET /v1beta/files/abc-123": answer(200, $processing) + NEXT + answer(200, UPLOADED),
        "GET /v1beta/files/bad-1": answer(200, $failed),
        "GET /v1beta/files/slow-1": answer(200, $processing),
        "GET /v1beta/files?pageSize=100": answer(
            200,
            '{"files": [' + UPLOADED + '], "nextPageToken": "n2"}'),
        "GET /v1beta/files?pageSize=100&pageToken=n2": answer(
            200,
            '{"files": [' + $processing + ']}'),
        "DELETE /v1beta/files/abc-123": answer(200, '{}')
    });
    def c as Client init fakeClient($f);
    testing.assertEqual(file($c, "abc-123").state, "PROCESSING");
    testing.assertEqual(waitForFile($c, "files/abc-123", 10000).state, "ACTIVE");
    try {
        waitForFile($c, "bad-1", 10000);
        missed("failed");
    } catch (e) {
        testing.assertEqual($e.kind, "gemini");
        testing.assertContains($e.message, "processing failed: The video could not be decoded.");
    }
    try {
        waitForFile($c, "slow-1", 1000);
        missed("still processing");
    } catch (e) {
        testing.assertEqual($e.kind, "timeout");
        testing.assertContains($e.message, "still PROCESSING after 1000 ms");
    }
    def all as list of FileInfo init files($c);
    deleteFile($c, "abc-123");
    def seen as list of string init stopFake($f);
    testing.assertEqual(len($all), 2);
    testing.assertEqual($all[1].state, "PROCESSING");
    testing.assertEqual(
        $seen[len($seen) - 1],
        "DELETE /v1beta/files/abc-123|x-goog-api-key=" + KEY + "|");
    try {
        waitForFile($c, "abc-123", 10);
        missed("a short wait");
    } catch (e) {
        testing.assertContains($e.message, "the wait must be 1000 to 3600000");
    }
}

func testUploadHasItsOwnDeadline() {
    def f as Fake init startFake({
        "POST /upload/v1beta/files": "200\nX-Goog-Upload-Url: $BASE/upload/v1beta/files?upload_id=slow\n\n",
        "POST /upload/v1beta/files?upload_id=slow": "SLOW 1300 200\nContent-Type: application/json\n\n" +
            '{"file": ' + UPLOADED + '}'
    });
    def data as bytes init binary.make(4, 1);
    # the requests' deadline is 1 s; the data step takes 1.3 s and has 5 min
    def c as Client init withTimeout(fakeClient($f), 1000);
    testing.assertEqual(uploadFile($c, $data, "audio/mpeg", "talk").name, "files/abc-123");
    try {
        uploadFile(withUploadTimeout($c, 1000), $data, "audio/mpeg", "talk");
        missed("a slow upload");
    } catch (e) {
        testing.assertEqual($e.kind, "timeout");
    }
    stopFake($f);
    testing.assertEqual(uploadDeadline($c, 1), 360000);
    testing.assertEqual(uploadDeadline($c, 100000000), 360000);
    testing.assertEqual(uploadDeadline($c, 100000001), 420000);
    testing.assertEqual(uploadDeadline($c, MAX_FILE_BYTES), 300000 + 20 * 60000);
}

func testFilesReadMorePagesThanModels() {
    # 150 pages of one file each: past MAX_PAGES, within MAX_FILE_PAGES
    def page as string init answer(
        200,
        '{"files": [{"name": "files/f", "mimeType": "text/plain", "state": "ACTIVE"}], "nextPageToken": "more"}');
    def all as list of string init [];
    for (def i in 0..149) {
        $all[] = $page;
    }
    $all[] = answer(200, '{"files": [{"name": "files/last", "state": "ACTIVE"}]}');
    def f as Fake init startFake({"GET /v1beta/files": strings.join($all, NEXT)});
    def listed as list of FileInfo init files(fakeClient($f));
    stopFake($f);
    testing.assertEqual(len($listed), 150);
    testing.assertEqual($listed[149].name, "files/last");
    testing.assertEqual(MAX_FILE_PAGES, 1000);
    testing.assertEqual(MAX_FILE_BYTES, 2000000000);
}
