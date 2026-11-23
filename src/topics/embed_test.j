# SPDX-License-Identifier: LGPL-3.0-only
# SPDX-FileCopyrightText: Copyright (C) 2026 mplx <mplx@jennifer-lang.dev>
# pragma-jennifer-version: >=0.27.0

# gemini - white-box tests for the embed topic. Spliced into gemini_test.j
# via include.

/**
 * A batchEmbedContents reply with a number of three-value embeddings, the
 * first value the embedding's index.
 *
 * @param from {int} the first index
 * @param count {int} how many
 * @return {string} the reply
 */
func embeddingsReply(from as int, count as int) {
    def items as list of string init [];
    for (def i in $from..$from + $count) {
        $items[] = '{"values": [' + convert.toString($i) + ', 0.5, -0.25]}';
    }
    return '{"embeddings": [' + strings.join($items, ", ") + ']}';
}

func testEmbed() {
    def f as Fake init startFake({
        "POST /v1beta/models/gemini-embedding-001:embedContent": answer(
            200,
            '{"embedding": {"values": [0.013168523, -0.008711934, 0, 1]}}')
    });
    def c as Client init fakeClient($f);
    def v as list of float init embed(
        $c,
        "gemini-embedding-001",
        "What is the meaning of life?",
        "SEMANTIC_SIMILARITY",
        768);
    def plain as list of float init embed($c, "models/gemini-embedding-001", "x", "", 0);
    def seen as list of string init stopFake($f);
    testing.assertEqual($v, [0.013168523, -0.008711934, 0.0, 1.0]);
    testing.assertEqual(len($plain), 4);
    testing.assertEqual(
        json.encode(seenBody($seen[0])),
        '{"content":{"parts":[{"text":"What is the meaning of life?"}]},"taskType":"SEMANTIC_SIMILARITY","outputDimensionality":768}');
    testing.assertEqual(json.encode(seenBody($seen[1])), '{"content":{"parts":[{"text":"x"}]}}');
    try {
        embed($c, "gemini-embedding-001", "x", "semantic", 0);
        missed("task type");
    } catch (e) {
        testing.assertContains($e.message, "a task type is");
    }
    try {
        embed($c, "gemini-embedding-001", "x", "", -1);
        missed("dimensions");
    } catch (e) {
        testing.assertContains($e.message, "the dimensions must be 128 to 3072");
    }
    for (def bad in [1, 127, 3073, 65536]) {
        try {
            embed($c, "gemini-embedding-001", "x", "", $bad);
            missed("dimensions " + convert.toString($bad));
        } catch (e) {
            testing.assertEqual($e.kind, "gemini");
        }
    }
}

func testEmbedManyBatches() {
    def f as Fake init startFake({
        "POST /v1beta/models/gemini-embedding-001:batchEmbedContents": answer(
            200,
            embeddingsReply(0, 100)) + NEXT +
            answer(200, embeddingsReply(100, 50)) + NEXT + answer(200, embeddingsReply(0, 1))
    });
    def c as Client init fakeClient($f);
    def texts as list of string init [];
    for (def i in 0..150) {
        $texts[] = "text " + convert.toString($i);
    }
    def all as list of list of float init embedMany(
        $c,
        "gemini-embedding-001",
        $texts,
        "RETRIEVAL_DOCUMENT",
        0);
    testing.assertEqual(len($all), 150);
    testing.assertEqual($all[0], [0.0, 0.5, -0.25]);
    testing.assertEqual($all[149][0], 149.0);
    testing.assertEqual(len(embedMany($c, "gemini-embedding-001", [], "", 0)), 0);
    try {
        embedMany($c, "gemini-embedding-001", ["a", "b"], "", 0);
        missed("one embedding for two texts");
    } catch (e) {
        testing.assertContains($e.message, "does not hold 2 embeddings");
    }
    def seen as list of string init stopFake($f);
    testing.assertEqual(len($seen), 3);
    def first as json.Value init seenBody($seen[0]);
    testing.assertEqual(json.length($first, "/requests"), 100);
    testing.assertEqual(
        json.encode(json.get($first, "/requests/0")),
        '{"model":"models/gemini-embedding-001","content":{"parts":[{"text":"text 0"}]},"taskType":"RETRIEVAL_DOCUMENT"}');
    testing.assertEqual(json.length(seenBody($seen[1]), "/requests"), 50);
    testing.assertEqual(
        json.asString(seenBody($seen[1]), "/requests/49/content/parts/0/text"),
        "text 149");
}
