# SPDX-License-Identifier: LGPL-3.0-only
# SPDX-FileCopyrightText: Copyright (C) 2026 mplx <mplx@jennifer-lang.dev>
# pragma-jennifer-version: >=0.26.0

# gemini - white-box tests for the content topic. Spliced into
# gemini_test.j via include.

# a reply with a thought summary, an answer in two parts and a signature,
# in the shape of the API reference's GenerateContentResponse
def const THOUGHTFUL as string init '{"candidates": [{"content": {"parts": [{"text": "The user wants a short answer.", "thought": true}, {"text": "Rayleigh scattering: "}, {"text": "blue light scatters most.", "thoughtSignature": "c2lnLW9uZQ=="}], "role": "model"}, "finishReason": "STOP", "index": 0, "safetyRatings": [{"category": "HARM_CATEGORY_HARASSMENT", "probability": "NEGLIGIBLE"}]}], "usageMetadata": {"promptTokenCount": 9, "candidatesTokenCount": 12, "totalTokenCount": 61, "thoughtsTokenCount": 40, "cachedContentTokenCount": 4, "toolUsePromptTokenCount": 0, "promptTokensDetails": [{"modality": "TEXT", "tokenCount": 9}]}, "modelVersion": "gemini-3.8-flash", "responseId": "mfoaaY3xLb2gz7IPs4WxyQ4"}';

# a prompt blocked before any candidate
def const BLOCKED as string init '{"promptFeedback": {"blockReason": "SAFETY", "safetyRatings": [{"category": "HARM_CATEGORY_DANGEROUS_CONTENT", "probability": "HIGH", "blocked": true}]}, "usageMetadata": {"promptTokenCount": 11, "totalTokenCount": 11}, "modelVersion": "gemini-3.8-flash"}';

# an answer stopped for recitation
def const RECITED as string init '{"candidates": [{"content": {"parts": [{"text": "It was the best of times, it was"}], "role": "model"}, "finishReason": "RECITATION", "index": 0, "citationMetadata": {"citationSources": [{"startIndex": 0, "endIndex": 32, "uri": "https://example.org/book"}]}}], "modelVersion": "gemini-3.8-flash"}';

func testRequestBuilders() {
    def req as json.Value init newRequest("gemini-3.8-flash");
    testing.assertEqual(json.encode($req), '{"model":"models/gemini-3.8-flash","contents":[]}');
    $req = withSystem($req, "Be brief.");
    $req = addUserText($req, "Hi");
    $req = addText($req, "model", "Hello.");
    def png as bytes;
    $png[] = 137;
    $png[] = 80;
    $png[] = 255;
    $req = addParts(
        $req,
        "user",
        [
            textPart("What is this?"),
            inlinePart("image/png", $png),
            filePart("video/mp4", "https://generativelanguage.googleapis.com/v1beta/files/abc123")
        ]);
    testing.assertEqual(
        json.encode(json.get($req, "/systemInstruction")),
        '{"parts":[{"text":"Be brief."}]}');
    testing.assertEqual(json.length($req, "/contents"), 3);
    testing.assertEqual(json.asString($req, "/contents/1/role"), "model");
    testing.assertEqual(
        json.encode(json.get($req, "/contents/2/parts/1")),
        '{"inlineData":{"mimeType":"image/png","data":"iVD/"}}');
    testing.assertEqual(
        json.encode(json.get($req, "/contents/2/parts/2")),
        '{"fileData":{"mimeType":"video/mp4","fileUri":"https://generativelanguage.googleapis.com/v1beta/files/abc123"}}');
    $req = withConfig($req, "temperature", json.decode("0.2"));
    $req = withConfig($req, "maxOutputTokens", json.decode("256"));
    testing.assertEqual(
        json.encode(json.get($req, "/generationConfig")),
        '{"temperature":0.2,"maxOutputTokens":256}');
    $req = withCachedContent($req, "abc123");
    testing.assertEqual(json.asString($req, "/cachedContent"), "cachedContents/abc123");
    for (def bad in ["system", "assistant", ""]) {
        try {
            addText($req, $bad, "x");
            missed($bad);
        } catch (e) {
            testing.assertContains($e.message, "a role is user or model");
        }
    }
    try {
        addParts($req, "user", []);
        missed("no parts");
    } catch (e) {
        testing.assertContains($e.message, "at least one part");
    }
    try {
        inlinePart("png", $png);
        missed("mime");
    } catch (e) {
        testing.assertContains($e.message, "a MIME type is");
    }
    try {
        filePart("video/mp4", "");
        missed("uri");
    } catch (e) {
        testing.assertContains($e.message, "a file URI is");
    }
    try {
        withConfig($req, "max_tokens", json.decode("1"));
        missed("snake case");
    } catch (e) {
        testing.assertContains($e.message, "camelCase");
    }
    try {
        addUserText(json.map(), "no model");
        missed("no model");
    } catch (e) {
        testing.assertContains($e.message, "build it with newRequest");
    }
}

func testStructuredOutputThinkingSafety() {
    def req as json.Value init newRequest("gemini-3.8-flash");
    def schema as json.Value init json.decode(
        '{"type": "object", "properties": {"city": {"type": "string"}, "population": {"type": "integer"}}, "required": ["city"]}');
    $req = withConfig($req, "responseSchema", json.decode('{"type": "STRING"}'));
    $req = withJsonSchema($req, $schema);
    testing.assertEqual(
        json.asString($req, "/generationConfig/responseMimeType"),
        "application/json");
    testing.assertFalse(json.has($req, "/generationConfig/responseSchema"));
    testing.assertEqual(json.get($req, "/generationConfig/responseJsonSchema"), $schema);
    # a level clears a budget and the other way round: the API refuses both
    $req = withThinkingBudget($req, 1024);
    $req = withThoughts($req, true);
    $req = withThinkingLevel($req, "High");
    testing.assertEqual(
        json.encode(json.get($req, "/generationConfig/thinkingConfig")),
        '{"includeThoughts":true,"thinkingLevel":"HIGH"}');
    $req = withThinkingBudget($req, -1);
    testing.assertEqual(
        json.encode(json.get($req, "/generationConfig/thinkingConfig")),
        '{"includeThoughts":true,"thinkingBudget":-1}');
    try {
        withThinkingLevel($req, "max");
        missed("level");
    } catch (e) {
        testing.assertContains($e.message, "a thinking level is");
    }
    try {
        withThinkingBudget($req, -2);
        missed("budget");
    } catch (e) {
        testing.assertContains($e.message, "the thinking budget must be -1 to 32768");
    }
    try {
        withThinkingBudget($req, 32769);
        missed("budget over 2.5 Pro's");
    } catch (e) {
        testing.assertEqual($e.kind, "gemini");
    }
    testing.assertEqual(
        json.asInt(
            withThinkingBudget($req, 32768),
            "/generationConfig/thinkingConfig/thinkingBudget"),
        32768);
    # the newer responseFormat and responseJsonSchema are not sent together
    def framed as json.Value init withConfig(
        $req,
        "responseFormat",
        json.decode('{"text": {"mimeType": "APPLICATION_JSON", "schema": {"type": "string"}}}'));
    def schemed as json.Value init withJsonSchema($framed, json.decode('{"type": "object"}'));
    testing.assertFalse(json.has($schemed, "/generationConfig/responseFormat"));
    testing.assertEqual(
        json.asString($schemed, "/generationConfig/responseMimeType"),
        "application/json");
    try {
        withJsonSchema($req, json.decode("[]"));
        missed("schema");
    } catch (e) {
        testing.assertContains($e.message, "a JSON Schema is an object");
    }
    $req = withSafety($req, "HARM_CATEGORY_HARASSMENT", "BLOCK_ONLY_HIGH");
    $req = withSafety($req, "HARM_CATEGORY_DANGEROUS_CONTENT", "BLOCK_LOW_AND_ABOVE");
    $req = withSafety($req, "HARM_CATEGORY_HARASSMENT", "OFF");
    testing.assertEqual(
        json.encode(json.get($req, "/safetySettings")),
        '[{"category":"HARM_CATEGORY_HARASSMENT","threshold":"OFF"},{"category":"HARM_CATEGORY_DANGEROUS_CONTENT","threshold":"BLOCK_LOW_AND_ABOVE"}]');
    try {
        withSafety($req, "harassment", "OFF");
        missed("category");
    } catch (e) {
        testing.assertContains($e.message, "a harm category is");
    }
    try {
        withSafety($req, "HARM_CATEGORY_HARASSMENT", "BLOCK_ALL");
        missed("threshold");
    } catch (e) {
        testing.assertContains($e.message, "a safety threshold is");
    }
}

func testChatSendsAndReads() {
    def f as Fake init startFake({
        "POST /v1beta/models/gemini-3.8-flash:generateContent": answer(200, THOUGHTFUL),
        "POST /v1beta/models/gemini-3.8-flash:countTokens": answer(
            200,
            '{"totalTokens": 31, "promptTokensDetails": [{"modality": "TEXT", "tokenCount": 31}]}')
    });
    def c as Client init fakeClient($f);
    def req as json.Value init addUserText(
        withSystem(newRequest("gemini-3.8-flash"), "Be brief."),
        "Why is the sky blue?");
    $req = withThoughts($req, true);
    def reply as json.Value init chat($c, $req);
    def n as int init countTokens($c, $req);
    def seen as list of string init stopFake($f);
    testing.assertEqual(text($reply), "Rayleigh scattering: blue light scatters most.");
    testing.assertEqual(thoughts($reply), "The user wants a short answer.");
    testing.assertEqual(finishReason($reply), "STOP");
    testing.assertEqual(blockReason($reply), "");
    def u as Usage init usage($reply);
    testing.assertEqual($u.inputTokens, 9);
    testing.assertEqual($u.outputTokens, 12);
    testing.assertEqual($u.reasoningTokens, 40);
    testing.assertEqual($u.cachedTokens, 4);
    testing.assertEqual($u.totalTokens, 61);
    testing.assertEqual($n, 31);
    testing.assertTrue(strings.startsWith(
        $seen[0],
        "POST /v1beta/models/gemini-3.8-flash:generateContent|x-goog-api-key=" + KEY +
            "|Content-Type=application/json|"));
    # the model is in the path, not the body
    def sent as json.Value init seenBody($seen[0]);
    testing.assertFalse(json.has($sent, "/model"));
    testing.assertEqual(json.asString($sent, "/contents/0/parts/0/text"), "Why is the sky blue?");
    testing.assertTrue(json.asBool($sent, "/generationConfig/thinkingConfig/includeThoughts"));
    def counted as json.Value init seenBody($seen[1]);
    testing.assertEqual(
        json.asString($counted, "/generateContentRequest/model"),
        "models/gemini-3.8-flash");
    testing.assertEqual(
        json.asString($counted, "/generateContentRequest/systemInstruction/parts/0/text"),
        "Be brief.");
    # a conversation goes on with the reply as received, signature and all
    def next as json.Value init addUserText(addReply($req, $reply), "And at sunset?");
    testing.assertEqual(json.length($next, "/contents"), 3);
    testing.assertEqual(
        json.asString($next, "/contents/1/parts/2/thoughtSignature"),
        "c2lnLW9uZQ==");
    testing.assertTrue(json.asBool($next, "/contents/1/parts/0/thought"));
}

func testUsageTotalWhenAbsent() {
    def u as Usage init usage(json.decode(
        '{"usageMetadata": {"promptTokenCount": 9, "candidatesTokenCount": 12, "thoughtsTokenCount": 40, "toolUsePromptTokenCount": 3}}'));
    testing.assertEqual($u.inputTokens, 9);
    testing.assertEqual($u.toolUseTokens, 3);
    testing.assertEqual($u.totalTokens, 64);
    # a total the API sent is kept, even 0
    testing.assertEqual(
        usage(json.decode('{"usageMetadata": {"promptTokenCount": 9, "totalTokenCount": 0}}')).totalTokens,
        0);
    testing.assertEqual(usage(json.decode('{}')).totalTokens, 0);
}

func testStructuredReply() {
    def reply as json.Value init json.decode(
        '{"candidates": [{"content": {"parts": [{"text": "{\"city\": \"Vienna\", \"population\": 2006134}"}], "role": "model"}, "finishReason": "STOP"}]}');
    def v as json.Value init textJson($reply);
    testing.assertEqual(json.asString($v, "/city"), "Vienna");
    testing.assertEqual(json.asInt($v, "/population"), 2006134);
    def cut as json.Value init json.decode(
        '{"candidates": [{"content": {"parts": [{"text": "{\"city\": \"Vie"}], "role": "model"}, "finishReason": "MAX_TOKENS"}]}');
    try {
        textJson($cut);
        missed("cut short");
    } catch (e) {
        testing.assertEqual($e.kind, "gemini");
        testing.assertContains($e.message, "the answer is not JSON (finish reason \"MAX_TOKENS\")");
    }
}

func testSafetyBlockIsDataUntilRead() {
    def f as Fake init startFake({
        "POST /v1beta/models/gemini-3.8-flash:generateContent": answer(200, BLOCKED) + NEXT +
            answer(200, RECITED)
    });
    def c as Client init fakeClient($f);
    def req as json.Value init addUserText(newRequest("gemini-3.8-flash"), "something unsafe");
    def blocked as json.Value init chat($c, $req);
    def recited as json.Value init chat($c, $req);
    stopFake($f);
    testing.assertEqual(blockReason($blocked), "SAFETY");
    testing.assertEqual(finishReason($blocked), "");
    testing.assertEqual(usage($blocked).inputTokens, 11);
    testing.assertEqual(thoughts($blocked), "");
    testing.assertEqual(len(toolCalls($blocked)), 0);
    try {
        text($blocked);
        missed("a blocked prompt");
    } catch (e) {
        testing.assertEqual($e.kind, "gemini.blocked");
        def g as GeminiError init $e;
        testing.assertEqual($g.status, 200);
        testing.assertEqual($g.googleStatus, "");
        testing.assertEqual($g.blockReason, "SAFETY");
        testing.assertEqual($g.reason, "PROMPT_BLOCKED");
        testing.assertContains($g.message, "the prompt was blocked (SAFETY)");
    }
    try {
        addReply($req, $blocked);
        missed("adding a blocked reply");
    } catch (e) {
        testing.assertContains(
            $e.message,
            "the reply has no answer to add: the prompt was blocked (SAFETY)");
    }
    testing.assertEqual(blockReason($recited), "RECITATION");
    try {
        text($recited);
        missed("a recitation");
    } catch (e) {
        def g as GeminiError init $e;
        testing.assertEqual($g.kind, "gemini.blocked");
        testing.assertEqual($g.googleStatus, "");
        testing.assertEqual($g.blockReason, "RECITATION");
        testing.assertEqual($g.reason, "RESPONSE_BLOCKED");
    }
    try {
        text(json.decode('{"candidates": []}'));
        missed("no candidate");
    } catch (e) {
        testing.assertEqual($e.kind, "gemini");
        testing.assertContains($e.message, "no candidate");
    }
}

func testRequestCap() {
    def c as Client init withBaseUrl(client(KEY), "http://127.0.0.1:9");
    def huge as bytes init binary.make(80000000, 65);
    def req as json.Value init addParts(
        newRequest("gemini-3.8-flash"),
        "user",
        [inlinePart("video/mp4", $huge)]);
    try {
        chat($c, $req);
        missed("over 100 MB");
    } catch (e) {
        testing.assertEqual($e.kind, "limit");
        testing.assertContains($e.message, "upload large media with uploadFile");
    }
}
