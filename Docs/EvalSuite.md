# EvalSuite — 5-metric evaluation suite

Design anchor for the eval harness. **No implementation yet.** When built, it
runs against an `Evals/goldens.json` file and stores results in SQLite with
timestamps for regression tracking, failing (or warning) the build when any
metric drops more than a threshold.

## The five metrics

Grounded in primary literature (parent research, Part VIII). For a personal
photo + message index with VLM captions + CLIP embeddings:

| Metric | Addresses | Citation |
|---|---|---|
| Recall@5 | Retrieval correctness | [Chen et al. 2015](https://arxiv.org/abs/1504.00325) |
| MRR | Ranking quality | [Järvelin & Kekäläinen 2002](https://dl.acm.org/doi/10.1145/582415.582418) |
| CLIPScore | Caption–image fidelity | [Hessel et al. 2021](https://arxiv.org/abs/2104.08718) |
| CHAIR_i | Caption hallucination | [Rohrbach et al. 2018](https://arxiv.org/abs/1809.02156) |
| RAGAS Context Recall | End-to-end pipeline | [Es et al. 2024](https://arxiv.org/abs/2309.15217) |

### Why these five

- **Recall@5** — dominant cross-modal retrieval metric (COCO-Captions,
  Flickr30k). Order-unaware; R@5 is the most readable target for a small
  personal corpus.
- **MRR** — averages `1/rank` of the first correct result. Ideal when each
  query has exactly one ground-truth item, the natural shape of a personal
  golden set.
- **CLIPScore** — reference-free cosine similarity between CLIP image and
  caption embeddings, scaled to [0, 2.5]. Uniquely valuable here because we
  have no human reference captions; near-zero cost if CLIP embeddings are
  already computed for retrieval.
- **CHAIR_i** — fraction of hallucinated object mentions per instance.
  **Critical for this project:** a hallucinated "dog" in a caption causes false
  positives for dog queries, directly poisoning CLIP-based retrieval.
- **RAGAS Context Recall** — reference-free RAG metric; measures whether
  retrieval surfaces the right items for a query before any downstream
  generation.

NDCG and mAP are deliberately skipped for v1 — they need graded relevance or
exhaustive per-query annotation, neither of which a personal set justifies.

## Golden set

Curate 50–100 queries spanning time periods, people, places, and events.
Annotate each with exactly one gold item (enables MRR and Recall@5) and one
expected object set per item (enables CHAIR_i). Re-run before and after every
model or prompt change. Never use real Photos or Messages data in committed
fixtures (see `AGENTS.md`).

## See also

- Parent research: Part VIII, `/Users/emilykang/Documents/Projects/me/Research/signal-coding-swift-ai-guardrails-cited.md`
- LLM trace schema: `Docs/LocalLLMTrace.md`
