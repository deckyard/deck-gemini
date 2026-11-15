<!-- SPDX-License-Identifier: LGPL-3.0-only -->
<!-- SPDX-FileCopyrightText: Copyright (C) 2026 mplx <mplx@jennifer-lang.dev> -->

# Embeddings

`embed` turns one text into a vector (`embedContent`); `embedMany` turns
many (`batchEmbedContents`, `MAX_EMBED_BATCH` texts per request), in
order.

```jennifer
import "@deckyard/gemini/" as gemini;
use io;
use linalg;
use os;

def c as gemini.Client init gemini.client(os.getEnv("GEMINI_API_KEY"));
def q as list of float init gemini.embed($c, "gemini-embedding-001", "How do cats purr?", "RETRIEVAL_QUERY", 768);
def docs as list of list of float init gemini.embedMany($c, "gemini-embedding-001",
    ["Purring comes from the larynx.", "Dogs bark."], "RETRIEVAL_DOCUMENT", 768);
for (def d in $docs) {
    io.printf("%f|prec=3\n", linalg.dot($q, linalg.normalize($d)));
}
```

- `taskType` tunes the vector for its use: `RETRIEVAL_QUERY`,
  `RETRIEVAL_DOCUMENT`, `SEMANTIC_SIMILARITY`, `CLASSIFICATION`,
  `CLUSTERING`, `QUESTION_ANSWERING`, `FACT_VERIFICATION`,
  `CODE_RETRIEVAL_QUERY`, or `""`. `gemini-embedding-001` takes it;
  `gemini-embedding-2` does not, and takes the task in the text instead
  (such as `task: classification | query: ...`).
- `dimensions` shortens the vector (`outputDimensionality`, 128 to 3072,
  768 or 1536 recommended); 0 keeps the model's own size (3072). A shortened vector is not
  normalised: normalise it before comparing by dot product.

`embedMany` returns every vector at once. A Jennifer `list of float`
takes several hundred bytes per number, so 1000 texts at 3072 dimensions
hold over a gigabyte: embed a large corpus in slices of a few hundred
texts (or ask for fewer `dimensions`) and store each slice before the next.

`gemini-embedding-2` also embeds images, audio, video and PDFs; send those
parts with `call` (`POST /models/gemini-embedding-2:embedContent`).
