# SPDX-License-Identifier: LGPL-3.0-only
# SPDX-FileCopyrightText: Copyright (C) 2026 mplx <mplx@jennifer-lang.dev>
# pragma-jennifer-version: >=0.27.0

# gemini - embed: text embeddings, one (`embedContent`) or many
# (`batchEmbedContents`, in batches). Spliced into gemini.j via include.

/** The most texts `embedMany` sends in one `batchEmbedContents` request. */
export def const MAX_EMBED_BATCH as int init 100;

/**
 * One embed request's body.
 *
 * @param name {string} the model's resource name, or `""` to leave it out
 * @param text {string} the text
 * @param taskType {string} the task type, `""` for none
 * @param dimensions {int} the output size, 0 for the model's own
 * @return {json.Value} the body
 */
func embedBody(name as string, text as string, taskType as string, dimensions as int) {
    def m as map of string to json.Value init {};
    if ($name != "") {
        $m["model"] = json.decode(json.encode($name));
    }
    $m["content"] = json.map({"parts": json.list([textPart($text)])});
    if ($taskType != "") {
        $m["taskType"] = json.decode(json.encode($taskType));
    }
    if ($dimensions > 0) {
        $m["outputDimensionality"] = json.decode(convert.toString($dimensions));
    }
    return json.map($m);
}

/**
 * Refuse a malformed task type or size.
 *
 * @param taskType {string} the task type
 * @param dimensions {int} the size
 */
func checkEmbed(taskType as string, dimensions as int) {
    if ($taskType != "" and not regex.matches('^[A-Z]+(_[A-Z]+)*$', $taskType)) {
        fail("a task type is such as RETRIEVAL_QUERY or SEMANTIC_SIMILARITY, got " +
            shown($taskType));
    }
    if ($dimensions != 0) {
        checkRange($dimensions, 128, 3072, "the dimensions");
    }
}

/**
 * The numbers of an embedding.
 *
 * @param v {json.Value} the reply
 * @param ptr {string} the pointer to the `values` list
 * @param what {string} the request, for messages
 * @param ptrs {list of string} `/0`, `/1`, ... built once by the caller; reading by them saves building a pointer per number (a quarter of the time)
 * @return {list of float} the values
 */
func valuesAt(v as json.Value, ptr as string, what as string, ptrs as list of string) {
    if (json.typeOf($v, $ptr) != "list") {
        fail($what + ": the reply has no embedding at " + shown($ptr));
    }
    def values as json.Value init json.get($v, $ptr);
    def n as int init json.length($values);
    def out as list of float init [];
    if ($n <= len($ptrs)) {
        for (def i in 0..$n) {
            $out[] = json.asFloat($values, $ptrs[$i]);
        }
        return $out;
    }
    for (def i in 0..$n) {
        $out[] = json.asFloat($values, "/" + convert.toString($i));
    }
    return $out;
}

/**
 * The embedding of one text (`embedContent`).
 *
 * @param c {Client} the client
 * @param model {string} such as `gemini-embedding-001` or `gemini-embedding-2`
 * @param text {string} the text
 * @param taskType {string} `""`, or such as `RETRIEVAL_QUERY`, `RETRIEVAL_DOCUMENT`, `SEMANTIC_SIMILARITY`, `CLASSIFICATION`, `CLUSTERING` (`gemini-embedding-001`; `gemini-embedding-2` takes the task in the text instead)
 * @param dimensions {int} a smaller output size, 128 to 3072 (768 and 1536 recommended), 0 for the model's own (3072)
 * @return {list of float} the embedding
 * @throws {GeminiError} kind "gemini" when an argument is malformed or the API refuses
 * @example
 *   def v as list of float init gemini.embed($c, "gemini-embedding-001", "a cat", "SEMANTIC_SIMILARITY", 768);
 */
export func embed(
    c as Client,
    model as string,
    text as string,
    taskType as string,
    dimensions as int) {
    def name as string init modelName($model);
    checkEmbed($taskType, $dimensions);
    def what as string init "embedContent " + $name;
    def v as json.Value init apiRequest(
        $c,
        "POST",
        "/" + $name + ":embedContent",
        json.encode(embedBody("", $text, $taskType, $dimensions)),
        $what);
    return valuesAt($v, "/embedding/values", $what, []);
}

/**
 * The embeddings of many texts (`batchEmbedContents`, `MAX_EMBED_BATCH`
 * texts per request), in the texts' order.
 *
 * @param c {Client} the client
 * @param model {string} such as `gemini-embedding-001`
 * @param texts {list of string} the texts
 * @param taskType {string} as `embed`
 * @param dimensions {int} as `embed`
 * @return {list of list of float} one embedding per text
 * @throws {GeminiError} kind "gemini" when an argument is malformed, the API refuses, or a reply holds the wrong number of embeddings
 */
export func embedMany(
    c as Client,
    model as string,
    texts as list of string,
    taskType as string,
    dimensions as int) {
    def name as string init modelName($model);
    checkEmbed($taskType, $dimensions);
    def what as string init "batchEmbedContents " + $name;
    def out as list of list of float init [];
    def ptrs as list of string init [];
    def start as int init 0;
    while ($start < len($texts)) {
        def end as int init math.min($start + MAX_EMBED_BATCH, len($texts));
        def requests as list of json.Value init [];
        for (def i in $start..$end) {
            $requests[] = embedBody($name, $texts[$i], $taskType, $dimensions);
        }
        def body as json.Value init json.map({"requests": json.list($requests)});
        def v as json.Value init apiRequest(
            $c,
            "POST",
            "/" + $name + ":batchEmbedContents",
            json.encode($body),
            $what);
        if (json.typeOf($v, "/embeddings") != "list" or
            json.length($v, "/embeddings") != $end - $start) {
            fail(io.sprintf("%s: the reply does not hold %d embeddings", $what, $end - $start));
        }
        if (json.typeOf($v, "/embeddings/0/values") == "list") {
            for (def i in len($ptrs)..math.max(len($ptrs), json.length($v, "/embeddings/0/values"))) {
                $ptrs[] = "/" + convert.toString($i);
            }
        }
        for (def i in 0..$end - $start) {
            $out[] = valuesAt($v, "/embeddings/" + convert.toString($i) + "/values", $what, $ptrs);
        }
        $start = $end;
    }
    return $out;
}
