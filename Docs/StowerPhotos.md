# StowerPhotos

## Why

The Photos data-source adapter. Enumerates the photo library via PhotoKit,
runs an on-device caption pipeline (FastVLM over MLX) plus Vision OCR, and
emits `StowerIndexedItem` values for `StowerCore` to index. It owns everything that
is Photos-specific so `StowerCore` stays source-agnostic.

This module is the one the v3 iOS Photos-only app links (alongside
`StowerCore`). It must never import `StowerMessages` — if it ever does, the
iOS binary would pull in the Messages code, which is the exact split this
architecture exists to prevent.

## Public API surface (planned — not yet implemented)

- PhotoKit enumerator that walks the library and yields assets.
- FastVLM caption job runner (MLX-backed). See `tmp/research/` for the
  exemplar repos and the FastVLM/mlx-swift references.
- Vision OCR pass for text-in-image.
- Mapping layer producing `StowerIndexedItem` values.

## Constraints

- Do not read or write face-identity tables in `Photos.sqlite` (ZPERSON,
  ZDETECTEDFACE). Use PhotoKit + FastVLM captions. (Out of scope for v1.)
- PhotoKit authorization requires the
  `com.apple.security.personal-information.photos-library` entitlement on the
  eventual app target — meaningful even without App Sandbox.
- `mlx-swift` and FastVLM are NOT dependencies in the v0 scaffold. Add them
  when the caption pipeline is actually implemented.

## Open questions

- Caption model size/quantization tradeoff on M-series hardware. Defer until
  measured.
- Incremental re-indexing strategy when the library changes. Defer.

## See also

- Plan: `PLAN.md`
- Apple data-access constraints (PhotoKit on macOS, Section 1):
  `tmp/research/2026-05-12-apple-data-access.md`
- Exemplar Swift repos: `tmp/research/2026-05-12-swift-exemplar-repos.md`
- Photos indexer brief: `tmp/briefs/2026-05-12-photos-ai-indexer.md`
