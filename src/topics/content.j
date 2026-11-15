# SPDX-License-Identifier: LGPL-3.0-only
# SPDX-FileCopyrightText: Copyright (C) 2026 mplx <mplx@jennifer-lang.dev>
# pragma-jennifer-version: >=0.26.0

# gemini - content: request builders and parts, generation settings
# (structured output, thinking, safety, a cache), `chat`, `countTokens` and
# the reply readers. Spliced into gemini.j via include.

/**
 * The finish reasons that mean the reply was stopped for its content, not
 * because it was done: `blockReason` reports them, `text` throws on them.
 */
export def const BLOCKED_FINISH_REASONS as list of string init [
    "SAFETY",
    "RECITATION",
    "LANGUAGE",
    "BLOCKLIST",
    "PROHIBITED_CONTENT",
    "SPII",
    "IMAGE_SAFETY",
    "IMAGE_PROHIBITED_CONTENT",
    "IMAGE_RECITATION"
];

/** The thinking levels `withThinkingLevel` takes; each model supports some of them. */
export def const THINKING_LEVELS as list of string init [
    "minimal",
    "low",
    "medium",
    "high",
    "xhigh"
];

/** The safety thresholds `withSafety` takes. */
export def const SAFETY_THRESHOLDS as list of string init [
    "BLOCK_NONE",
    "BLOCK_ONLY_HIGH",
    "BLOCK_MEDIUM_AND_ABOVE",
    "BLOCK_LOW_AND_ABOVE",
    "OFF"
];

# a MIME type
def const MIME_FORM as string init '^[a-z]+/[A-Za-z0-9.+_-]{1,100}$';

# a generationConfig field name
def const FIELD_FORM as string init '^[a-z][A-Za-z0-9]{0,63}$';

/**
 * The token counts of a reply (`usageMetadata`), 0 where the API sent none.
 * The first five fields are the same in the openai and anthropic decks.
 *
 * @field inputTokens {int} every prompt token, cached content included (`promptTokenCount`)
 * @field outputTokens {int} the answer (`candidatesTokenCount`), without the thinking
 * @field totalTokens {int} Google's `totalTokenCount`: input, output, thinking and tool results; when the API sent none, that sum
 * @field cachedTokens {int} the part of the prompt read from a cache (`cachedContentTokenCount`)
 * @field reasoningTokens {int} the thinking (`thoughtsTokenCount`)
 * @field toolUseTokens {int} the results of built-in tools (`toolUsePromptTokenCount`)
 */
export def struct Usage {
    inputTokens as int,
    outputTokens as int,
    totalTokens as int,
    cachedTokens as int,
    reasoningTokens as int,
    toolUseTokens as int
};

/**
 * A new generate-content request for a model, with no contents yet.
 *
 * The model is a field of the request, as in Google's
 * `GenerateContentRequest`, so one value carries everything a call needs:
 * `chat`, `countTokens`, `createCache` and `runTools` take it whole.
 * `chat` moves it into the URL.
 *
 * @param model {string} such as `gemini-3.8-flash` or `models/gemini-3.8-flash`
 * @return {json.Value} `{"model": "models/<id>", "contents": []}`
 * @throws {GeminiError} kind "gemini" when the model name is malformed
 * @example
 *   def req as json.Value init gemini.newRequest("gemini-3.8-flash");
 */
export func newRequest(model as string) {
    def name as string init modelName($model);
    return json.set(json.set(json.map(), "/model", $name), "/contents", json.list());
}

/**
 * Refuse a value that is not a generate-content request.
 *
 * @param req {json.Value} the request
 * @return {string} its model's resource name
 */
func requestModel(req as json.Value) {
    if (json.typeOf($req) != "map" or json.typeOf($req, "/model") != "string") {
        fail("a request is an object with a model: build it with newRequest");
    }
    return modelName(json.asString($req, "/model"));
}

/**
 * The request with a map at a pointer, created when absent.
 *
 * @param req {json.Value} the request
 * @param ptr {string} the pointer to a map
 * @return {json.Value} the request
 */
func ensureMap(req as json.Value, ptr as string) {
    def t as string init json.typeOf($req, $ptr);
    if ($t == "map") {
        return $req;
    }
    if ($t != "missing" and $t != "null") {
        fail(shown($ptr) + " is a " + $t + ", not an object");
    }
    return json.set($req, $ptr, json.map());
}

/**
 * The request with a system instruction, replacing any earlier one.
 *
 * @param req {json.Value} the request
 * @param text {string} the instruction
 * @return {json.Value} the request
 * @example
 *   $req = gemini.withSystem($req, "Answer in one sentence.");
 */
export func withSystem(req as json.Value, text as string) {
    requestModel($req);
    return json.set(
        $req,
        "/systemInstruction",
        json.map({"parts": json.list([textPart($text)])}));
}

/**
 * A text part.
 *
 * @param text {string} the text
 * @return {json.Value} `{"text": ...}`
 */
export func textPart(text as string) {
    return json.map({"text": $text});
}

/**
 * Refuse a malformed MIME type.
 *
 * @param mimeType {string} the type
 */
func checkMime(mimeType as string) {
    if (not regex.matches(MIME_FORM, $mimeType)) {
        fail("a MIME type is type/subtype, such as image/png, got " + shown($mimeType));
    }
}

/**
 * A part carrying media inline, base64-encoded: an image, audio, video or
 * PDF. A request is at most 100 MB in all; larger media goes through
 * `uploadFile` and `filePart`.
 *
 * @param mimeType {string} such as `image/png` or `application/pdf`
 * @param data {bytes} the media
 * @return {json.Value} `{"inlineData": {"mimeType": ..., "data": <base64>}}`
 * @throws {GeminiError} kind "gemini" when the MIME type is malformed
 * @example
 *   $req = gemini.addParts($req, "user", [gemini.textPart("What is this?"), gemini.inlinePart("image/png", fs.readBytes("cat.png"))]);
 */
export func inlinePart(mimeType as string, data as bytes) {
    checkMime($mimeType);
    def inline as json.Value init json.map({
        "mimeType": $mimeType,
        "data": encoding.toText("base64", $data)
    });
    return json.map({"inlineData": $inline});
}

/**
 * A part referring to media by URI: a file `uploadFile` returned (its
 * `uri`), or another URI the API accepts.
 *
 * @param mimeType {string} the media's MIME type
 * @param uri {string} such as `https://generativelanguage.googleapis.com/v1beta/files/abc123`
 * @return {json.Value} `{"fileData": {"mimeType": ..., "fileUri": ...}}`
 * @throws {GeminiError} kind "gemini" when the MIME type is malformed or the URI is empty
 */
export func filePart(mimeType as string, uri as string) {
    checkMime($mimeType);
    if ($uri == "" or strings.contains($uri, " ")) {
        fail("a file URI is not empty and has no spaces, got " + shown($uri));
    }
    return json.map({"fileData": json.map({"mimeType": $mimeType, "fileUri": $uri})});
}

/**
 * The request with one more turn of parts.
 *
 * @param req {json.Value} the request
 * @param role {string} `user` or `model`
 * @param parts {list of json.Value} the parts, at least one
 * @return {json.Value} the request
 * @throws {GeminiError} kind "gemini" when the role is neither or there are no parts
 */
export func addParts(req as json.Value, role as string, parts as list of json.Value) {
    requestModel($req);
    if ($role != "user" and $role != "model") {
        fail("a role is user or model, got " + shown($role));
    }
    if (len($parts) == 0) {
        fail("a turn has at least one part");
    }
    def turn as json.Value init json.map({"role": $role, "parts": json.list($parts)});
    if (json.typeOf($req, "/contents") != "list") {
        $req = json.set($req, "/contents", json.list());
    }
    return json.append($req, "/contents", $turn);
}

/**
 * The request with one more text turn.
 *
 * @param req {json.Value} the request
 * @param role {string} `user` or `model`
 * @param text {string} the text
 * @return {json.Value} the request
 */
export func addText(req as json.Value, role as string, text as string) {
    return addParts($req, $role, [textPart($text)]);
}

/**
 * The request with one more user text turn.
 *
 * @param req {json.Value} the request
 * @param text {string} the text
 * @return {json.Value} the request
 * @example
 *   $req = gemini.addUserText($req, "Why is the sky blue?");
 */
export func addUserText(req as json.Value, text as string) {
    return addParts($req, "user", [textPart($text)]);
}

/**
 * The request with the reply's answer added as the model's turn, exactly as
 * received: thought parts and their `thoughtSignature`s stay, which Gemini
 * 3 and later require back in a conversation that calls functions.
 *
 * @param req {json.Value} the request
 * @param reply {json.Value} a reply of `chat`
 * @return {json.Value} the request
 * @throws {GeminiError} kind "gemini" when the reply has no answer (a blocked prompt)
 */
export func addReply(req as json.Value, reply as json.Value) {
    requestModel($req);
    if (json.typeOf($reply, "/candidates/0/content/parts") != "list") {
        fail("the reply has no answer to add" + blockedText($reply));
    }
    def turn as json.Value init json.get($reply, "/candidates/0/content");
    if (json.typeOf($turn, "/role") != "string") {
        $turn = json.set($turn, "/role", "model");
    }
    if (json.typeOf($req, "/contents") != "list") {
        $req = json.set($req, "/contents", json.list());
    }
    return json.append($req, "/contents", $turn);
}

/**
 * The request with a `generationConfig` field set, such as `temperature`,
 * `maxOutputTokens`, `candidateCount`, `stopSequences`, `seed` or
 * `responseModalities`.
 *
 * @param req {json.Value} the request
 * @param name {string} the field, in camelCase
 * @param value {json.Value} its value
 * @return {json.Value} the request
 * @example
 *   $req = gemini.withConfig($req, "maxOutputTokens", json.decode("1024"));
 */
export func withConfig(req as json.Value, name as string, value as json.Value) {
    requestModel($req);
    if (not regex.matches(FIELD_FORM, $name)) {
        fail("a generationConfig field is a camelCase name, got " + shown($name));
    }
    $req = ensureMap($req, "/generationConfig");
    return json.set($req, "/generationConfig/" + $name, $value);
}

/**
 * The request asking for JSON that matches a JSON Schema: sets
 * `responseMimeType` to `application/json` and `responseJsonSchema`, the
 * fields Google's SDKs send, and removes a `responseSchema` or
 * `responseFormat` set before (the newer form of the same request; the two
 * are not sent together). Read the answer with `textJson`.
 *
 * @param req {json.Value} the request
 * @param schema {json.Value} the schema, a JSON Schema object (Google supports a subset and ignores the rest)
 * @return {json.Value} the request
 * @example
 *   $req = gemini.withJsonSchema($req, json.decode('{"type": "object", "properties": {"city": {"type": "string"}}, "required": ["city"]}'));
 */
export func withJsonSchema(req as json.Value, schema as json.Value) {
    if (json.typeOf($schema) != "map") {
        fail("a JSON Schema is an object");
    }
    $req = withConfig($req, "responseMimeType", json.decode('"application/json"'));
    for (def old in ["responseSchema", "responseFormat"]) {
        if (json.has($req, "/generationConfig/" + $old)) {
            $req = json.remove($req, "/generationConfig/" + $old);
        }
    }
    return json.set($req, "/generationConfig/responseJsonSchema", $schema);
}

/**
 * The request with a thinking level (Gemini 3 and later). Clears a
 * `thinkingBudget`: the API refuses both together. Gemini 2.5 takes only a
 * budget.
 *
 * @param req {json.Value} the request
 * @param level {string} one of `THINKING_LEVELS`, any case
 * @return {json.Value} the request
 * @throws {GeminiError} kind "gemini" when the level is not one of them
 */
export func withThinkingLevel(req as json.Value, level as string) {
    def l as string init strings.lower($level);
    if (not lists.contains(THINKING_LEVELS, $l)) {
        fail("a thinking level is minimal, low, medium, high or xhigh, got " + shown($level));
    }
    $req = thinkingConfig($req);
    if (json.has($req, "/generationConfig/thinkingConfig/thinkingBudget")) {
        $req = json.remove($req, "/generationConfig/thinkingConfig/thinkingBudget");
    }
    return json.set($req, "/generationConfig/thinkingConfig/thinkingLevel", strings.upper($l));
}

/**
 * The request with a thinking budget in tokens (Gemini 2.5; later models
 * map it to the nearest level). Clears a `thinkingLevel`: the API refuses
 * both together.
 *
 * @param req {json.Value} the request
 * @param tokens {int} -1 for dynamic, 0 to turn thinking off where the model allows, else up to 32768 (2.5 Pro's most; 2.5 Flash takes up to 24576)
 * @return {json.Value} the request
 */
export func withThinkingBudget(req as json.Value, tokens as int) {
    checkRange($tokens, -1, 32768, "the thinking budget");
    $req = thinkingConfig($req);
    if (json.has($req, "/generationConfig/thinkingConfig/thinkingLevel")) {
        $req = json.remove($req, "/generationConfig/thinkingConfig/thinkingLevel");
    }
    return json.set($req, "/generationConfig/thinkingConfig/thinkingBudget", $tokens);
}

/**
 * The request asking for thought summaries in the reply (parts marked
 * `"thought": true`, read with `thoughts`), or not.
 *
 * @param req {json.Value} the request
 * @param wanted {bool} whether to include them
 * @return {json.Value} the request
 */
export func withThoughts(req as json.Value, wanted as bool) {
    $req = thinkingConfig($req);
    return json.set($req, "/generationConfig/thinkingConfig/includeThoughts", $wanted);
}

/**
 * The request with `generationConfig.thinkingConfig` present.
 *
 * @param req {json.Value} the request
 * @return {json.Value} the request
 */
func thinkingConfig(req as json.Value) {
    requestModel($req);
    return ensureMap(ensureMap($req, "/generationConfig"), "/generationConfig/thinkingConfig");
}

/**
 * The request with a safety threshold for one harm category, replacing an
 * earlier one for it.
 *
 * @param req {json.Value} the request
 * @param category {string} such as `HARM_CATEGORY_HARASSMENT`, `HARM_CATEGORY_HATE_SPEECH`, `HARM_CATEGORY_SEXUALLY_EXPLICIT`, `HARM_CATEGORY_DANGEROUS_CONTENT`, `HARM_CATEGORY_CIVIC_INTEGRITY`
 * @param threshold {string} one of `SAFETY_THRESHOLDS`
 * @return {json.Value} the request
 * @throws {GeminiError} kind "gemini" when the category or threshold is malformed
 * @example
 *   $req = gemini.withSafety($req, "HARM_CATEGORY_DANGEROUS_CONTENT", "BLOCK_ONLY_HIGH");
 */
export func withSafety(req as json.Value, category as string, threshold as string) {
    requestModel($req);
    if (not regex.matches('^HARM_CATEGORY_[A-Z]+(_[A-Z]+)*$', $category)) {
        fail("a harm category is HARM_CATEGORY_<NAME>, got " + shown($category));
    }
    if (not lists.contains(SAFETY_THRESHOLDS, $threshold)) {
        fail("a safety threshold is " + strings.join(SAFETY_THRESHOLDS, ", ") + ", got " +
            shown($threshold));
    }
    def setting as json.Value init json.map({"category": $category, "threshold": $threshold});
    if (json.typeOf($req, "/safetySettings") != "list") {
        return json.set($req, "/safetySettings", json.list([$setting]));
    }
    for (def i in 0..json.length($req, "/safetySettings")) {
        def p as string init "/safetySettings/" + convert.toString($i);
        if (textAt($req, $p + "/category") == $category) {
            return json.set($req, $p, $setting);
        }
    }
    return json.append($req, "/safetySettings", $setting);
}

/**
 * The request reading its prefix from a context cache (`createCache`). The
 * cache holds the system instruction, tools and leading contents, so the
 * request carries only what follows; its model must be the cache's.
 *
 * @param req {json.Value} the request
 * @param name {string} `cachedContents/<id>` or the bare id
 * @return {json.Value} the request
 */
export func withCachedContent(req as json.Value, name as string) {
    requestModel($req);
    return json.set($req, "/cachedContent", resourceName("cachedContents", $name));
}

/**
 * Generate content: send the request to `models/<model>:generateContent`
 * and return Google's reply as it came. A blocked prompt or an answer
 * stopped for safety or recitation is in the reply, not thrown: check
 * `blockReason`, or let `text` throw.
 *
 * @param c {Client} the client
 * @param req {json.Value} the request, from `newRequest`
 * @return {json.Value} the `GenerateContentResponse`: `candidates`, `promptFeedback`, `usageMetadata`, `modelVersion`, `responseId`
 * @throws {GeminiError} kind "gemini" when the request is malformed or the API refuses it
 * @throws {Error} kind "limit" when the request is over 100 MB or the reply over the cap; "timeout" past the deadline; "closed" when the server hung up
 * @example
 *   def reply as json.Value init gemini.chat($c, $req);
 *   io.printf("%s\n", gemini.text($reply));
 */
export func chat(c as Client, req as json.Value) {
    def name as string init requestModel($req);
    def what as string init "generateContent " + $name;
    def reply as json.Value init apiRequest(
        $c,
        "POST",
        "/" + $name + ":generateContent",
        json.encode(json.remove($req, "/model")),
        $what);
    if (json.typeOf($reply) != "map") {
        fail($what + ": the reply is a " + json.typeOf($reply) + ", not an object");
    }
    return $reply;
}

/**
 * How many tokens a request's input takes (`countTokens`), with its system
 * instruction, tools and cache.
 *
 * @param c {Client} the client
 * @param req {json.Value} the request, from `newRequest`
 * @return {int} the total
 * @throws {GeminiError} kind "gemini" when the request is malformed or the API refuses it
 */
export func countTokens(c as Client, req as json.Value) {
    def name as string init requestModel($req);
    def body as json.Value init json.map({"generateContentRequest": $req});
    def v as json.Value init apiRequest(
        $c,
        "POST",
        "/" + $name + ":countTokens",
        json.encode($body),
        "countTokens " + $name);
    return intAt($v, "/totalTokens");
}

/**
 * Why a reply has no full answer: the prompt's `blockReason`, else the
 * first candidate's finish reason when it is one of
 * `BLOCKED_FINISH_REASONS`.
 *
 * @param reply {json.Value} a reply of `chat`
 * @return {string} such as `SAFETY`, `PROHIBITED_CONTENT` or `RECITATION`; `""` when nothing was blocked
 */
export func blockReason(reply as json.Value) {
    def prompt as string init textAt($reply, "/promptFeedback/blockReason");
    if ($prompt != "") {
        return $prompt;
    }
    def finish as string init finishReason($reply);
    if (lists.contains(BLOCKED_FINISH_REASONS, $finish)) {
        return $finish;
    }
    return "";
}

/**
 * A reply's block, for a message.
 *
 * @param reply {json.Value} the reply
 * @return {string} `: the prompt was blocked (SAFETY)` and the like, or `""`
 */
func blockedText(reply as json.Value) {
    def prompt as string init textAt($reply, "/promptFeedback/blockReason");
    if ($prompt != "") {
        return ": the prompt was blocked (" + cleaned($prompt, 64) + ")";
    }
    def finish as string init finishReason($reply);
    if ($finish != "") {
        return ": it stopped with " + cleaned($finish, 64);
    }
    return "";
}

/**
 * Throw when a reply holds no full answer: its prompt was blocked, or its
 * first candidate stopped for its content.
 *
 * @param reply {json.Value} the reply
 * @throws {GeminiError} kind "gemini.blocked" when it was blocked
 */
func checkAnswered(reply as json.Value) {
    def prompt as string init textAt($reply, "/promptFeedback/blockReason");
    def finish as string init finishReason($reply);
    if ($prompt == "" and not lists.contains(BLOCKED_FINISH_REASONS, $finish)) {
        return null;
    }
    def status as string init $finish;
    def reason as string init "RESPONSE_BLOCKED";
    def message as string init "gemini: the answer was stopped (" + cleaned($finish, 64) + ")";
    if ($prompt != "") {
        $status = $prompt;
        $reason = "PROMPT_BLOCKED";
        $message = "gemini: the prompt was blocked (" + cleaned($prompt, 64) + ")";
    }
    def detail as string init textAt($reply, "/candidates/0/finishMessage");
    if ($detail != "") {
        $message = $message + ": " + cleaned($detail, 300);
    }
    throw GeminiError{
        kind: "gemini.blocked",
        message: $message,
        status: 200,
        googleStatus: cleaned($status, 64),
        reason: $reason,
        retryAfterMs: 0,
        limits: {}
    };
}

/**
 * The text parts of the first candidate, thought or not.
 *
 * @param reply {json.Value} the reply
 * @param thought {bool} whether to take the thought parts or the others
 * @return {string} their texts, joined
 */
func partTexts(reply as json.Value, thought as bool) {
    if (json.typeOf($reply, "/candidates/0/content/parts") != "list") {
        return "";
    }
    def parts as json.Value init json.get($reply, "/candidates/0/content/parts");
    def texts as list of string init [];
    for (def i in 0..json.length($parts)) {
        def p as json.Value init json.get($parts, "/" + convert.toString($i));
        if (json.typeOf($p, "/text") == "string" and boolAt($p, "/thought") == $thought) {
            $texts[] = json.asString($p, "/text");
        }
    }
    return strings.join($texts, "");
}

/**
 * The answer's text: the text parts of the first candidate, thought
 * summaries left out.
 *
 * @param reply {json.Value} a reply of `chat`
 * @return {string} the text, `""` when the answer is only function calls
 * @throws {GeminiError} kind "gemini.blocked" (status 200, `googleStatus` the reason) when the prompt was blocked or the answer stopped for its content (`blockReason`); kind "gemini" when there is no candidate
 * @example
 *   io.printf("%s\n", gemini.text($reply));
 */
export func text(reply as json.Value) {
    checkAnswered($reply);
    if (json.typeOf($reply, "/candidates/0") != "map") {
        fail("the reply has no candidate");
    }
    return partTexts($reply, false);
}

/**
 * The thought summaries of the first candidate (`withThoughts`).
 *
 * @param reply {json.Value} a reply of `chat`
 * @return {string} the summaries, `""` when there are none
 */
export func thoughts(reply as json.Value) {
    return partTexts($reply, true);
}

/**
 * The answer's text read as JSON, for a request made with
 * `withJsonSchema`.
 *
 * @param reply {json.Value} a reply of `chat`
 * @return {json.Value} the document
 * @throws {GeminiError} kind "gemini.blocked" as `text`; kind "gemini" when the text is not JSON (a `MAX_TOKENS` finish cuts it short)
 */
export func textJson(reply as json.Value) {
    def t as string init text($reply);
    try {
        return json.decode($t);
    } catch (e) {
        fail("the answer is not JSON (finish reason " + shown(finishReason($reply)) + "): " +
            shown($t));
    }
}

/**
 * Why the first candidate stopped.
 *
 * @param reply {json.Value} a reply of `chat`
 * @return {string} such as `STOP`, `MAX_TOKENS`, `SAFETY`, `RECITATION`, `MALFORMED_FUNCTION_CALL`; `""` without a candidate
 */
export func finishReason(reply as json.Value) {
    return textAt($reply, "/candidates/0/finishReason");
}

/**
 * The token counts of a reply.
 *
 * @param reply {json.Value} a reply of `chat`
 * @return {Usage} the counts
 */
export func usage(reply as json.Value) {
    def u as Usage init Usage{
        inputTokens: intAt($reply, "/usageMetadata/promptTokenCount"),
        outputTokens: intAt($reply, "/usageMetadata/candidatesTokenCount"),
        totalTokens: intAt($reply, "/usageMetadata/totalTokenCount"),
        cachedTokens: intAt($reply, "/usageMetadata/cachedContentTokenCount"),
        reasoningTokens: intAt($reply, "/usageMetadata/thoughtsTokenCount"),
        toolUseTokens: intAt($reply, "/usageMetadata/toolUsePromptTokenCount")
    };
    if (json.typeOf($reply, "/usageMetadata/totalTokenCount") == "missing") {
        # Google's total is the prompt, the answer, the thinking and tool results
        $u.totalTokens = $u.inputTokens + $u.outputTokens + $u.reasoningTokens + $u.toolUseTokens;
    }
    return $u;
}
