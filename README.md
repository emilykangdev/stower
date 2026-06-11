# Stower

Local-first AI recall over your own Apple data. Ask a question by voice or
text — "the ramen place Mom texted me about", "photos from the Tahoe trip" —
and Stower runs a hybrid full-text + embedding search across your Photos and
iMessages, entirely on-device, and hands back the matches with a short
summary. Nothing leaves your Mac.

> **Status: scaffolding.** Module structure, guardrails, and CI are in place;
> no runtime features yet. See [`PLAN.md`](PLAN.md) for the roadmap and current
> status.

## Architecture

Three library targets, one-directional dependency graph:

- **`StowerCore`** — source-agnostic search, indexing, embeddings, FTS5 store,
  voice pipeline, and the local-LLM wrapper. Knows nothing about its sources.
- **`StowerPhotos`** — PhotoKit + FastVLM caption adapter. Produces
  `IndexedItem` values for `StowerCore`.
- **`StowerMessages`** — `chat.db` reader + Contacts join. Produces
  `IndexedItem` values for `StowerCore`.

`StowerPhotos` and `StowerMessages` depend on `StowerCore`; nothing depends on
them, and they never import each other. This keeps the v3 Photos-only iOS app
from ever linking the Messages code. See [`Docs/`](Docs/) for per-subsystem
rationale.

## Quickstart

```bash
git clone https://github.com/emilykangdev/stower.git
cd stower

# Build and test (requires Swift 6.3.1+).
swift build
swift test

# Lint gate (requires: brew install swift-format swiftlint).
./Scripts/install-hooks.sh   # one-time: wire precheck.sh to pre-commit
./Scripts/precheck.sh
```

`swift test` uses Swift Testing and needs full Xcode locally; under Command
Line Tools only, run it through `./Scripts/precheck.sh`, which injects the
required framework flags automatically.

## Contributing

See [`CONTRIBUTING.md`](CONTRIBUTING.md) and [`AGENTS.md`](AGENTS.md) (agent rule
set, imported by `CLAUDE.md`).

## License

[FSL-1.1-MIT](LICENSE) (Functional Source License) — the source is public and
free to read, run, and modify for any purpose **except** building a competing
product. Each release automatically converts to the [MIT License](LICENSE) two
years after it ships.
