# /// script
# requires-python = ">=3.10,<3.13"
# dependencies = [
#   "torch==2.4.1",
#   "transformers==4.44.2",
#   "coremltools==8.1",
#   "numpy>=1.23,<2.0",
#   "huggingface_hub==0.25.2",
# ]
# ///
"""Convert a Hugging Face sentence-embedding model to a batched Core ML package.

The Swift `StowerCoreMLEmbedder` is model-agnostic: pooling, query prefix, dims,
max tokens, special-token ids, and the pinned HF revision all travel WITH the
artifact in `manifest.json`. Swapping the embedding model is therefore:

    uv run Scripts/convert-embedding-model.py --model <hf-id>

and a re-embed — zero Swift changes.

The graph pools (CLS for BGE, mean for MiniLM) and L2-normalizes inside the
traced PyTorch module, so Swift only multiplies and reads. The input is a batched
int32 shape (RangeDim(1,64) x RangeDim(1,512)); a fixed batch dim would make
"batching" a loop of single predictions. A built-in parity check refuses to ship
an artifact whose Core ML output diverges from the PyTorch reference.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import shutil
import sys
import tempfile
from pathlib import Path

import coremltools as ct
import numpy as np
import torch
from huggingface_hub import HfApi, snapshot_download
from transformers import AutoModel, AutoTokenizer

MAX_TOKENS = 512
MAX_BATCH = 64
PARITY_THRESHOLD = 0.99
TOKENIZER_FILES = [
    "config.json",
    "tokenizer.json",
    "tokenizer_config.json",
    "special_tokens_map.json",
    "vocab.txt",
]


class EmbeddingModule(torch.nn.Module):
    """Wraps a HF encoder with pooling + L2 normalization inside the graph."""

    def __init__(self, model: torch.nn.Module, pooling: str) -> None:
        super().__init__()
        self.model = model
        self.pooling = pooling

    def forward(self, input_ids: torch.Tensor, attention_mask: torch.Tensor) -> torch.Tensor:
        token_type_ids = torch.zeros_like(input_ids)
        hidden = self.model(
            input_ids=input_ids,
            attention_mask=attention_mask,
            token_type_ids=token_type_ids,
        ).last_hidden_state
        if self.pooling == "cls":
            pooled = hidden[:, 0]
        else:
            mask = attention_mask.unsqueeze(-1).to(hidden.dtype)
            pooled = (hidden * mask).sum(dim=1) / mask.sum(dim=1).clamp(min=1e-9)
        return torch.nn.functional.normalize(pooled, p=2, dim=1)


def resolve_revision(model_id: str, revision: str | None) -> str:
    if revision:
        return revision
    info = HfApi().model_info(model_id)
    print(f"Resolved {model_id} main → {info.sha}")
    return info.sha


def defaults_for(model_id: str) -> tuple[str, str]:
    """Returns (pooling, query_prefix) inferred from the model family."""
    lowered = model_id.lower()
    if "bge" in lowered:
        return "cls", "Represent this sentence for searching relevant passages: "
    return "mean", ""


def trace_and_convert(module: EmbeddingModule, output: Path) -> Path:
    example_ids = torch.randint(5, 100, (2, 8), dtype=torch.int64)
    example_mask = torch.ones((2, 8), dtype=torch.int64)
    traced = torch.jit.trace(module.eval(), (example_ids, example_mask))
    sequence = ct.Shape(
        shape=(
            ct.RangeDim(lower_bound=1, upper_bound=MAX_BATCH, default=1),
            ct.RangeDim(lower_bound=1, upper_bound=MAX_TOKENS, default=8),
        )
    )
    mlmodel = ct.convert(
        traced,
        convert_to="mlprogram",
        inputs=[
            ct.TensorType(name="input_ids", shape=sequence, dtype=np.int32),
            ct.TensorType(name="attention_mask", shape=sequence, dtype=np.int32),
        ],
        outputs=[ct.TensorType(name="embeddings")],
        minimum_deployment_target=ct.target.macOS13,
    )
    package = output / "model.mlpackage"
    if package.exists():
        shutil.rmtree(package)
    mlmodel.save(str(package))
    return package


def run_parity_check(module: EmbeddingModule, mlmodel: ct.models.MLModel, vocab_size: int) -> None:
    print("Parity check (cosine vs PyTorch reference):")
    configs = [(1, 1), (1, 32), (1, 511), (1, 512), (4, 48)]
    rng = np.random.default_rng(0)
    for batch, length in configs:
        ids = rng.integers(5, vocab_size, size=(batch, length), dtype=np.int32)
        mask = np.ones((batch, length), dtype=np.int32)
        if batch > 1:
            mask[1:, length // 2:] = 0  # exercise padding
        with torch.no_grad():
            reference = module(torch.from_numpy(ids).long(), torch.from_numpy(mask).long()).numpy()
        predicted = mlmodel.predict({"input_ids": ids, "attention_mask": mask})["embeddings"]
        cosines = np.sum(reference * predicted, axis=1)
        worst = float(np.min(cosines))
        print(f"  batch={batch} len={length}: min cosine {worst:.5f}")
        if worst < PARITY_THRESHOLD:
            sys.exit(f"Parity failed at batch={batch} len={length}: {worst:.5f} < {PARITY_THRESHOLD}")


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def sha256_dir(root: Path) -> str:
    """Order-independent hash binding a manifest to one .mlpackage directory.

    Must stay byte-identical to `StowerCoreMLEmbedder.directoryFingerprint`.
    """
    entries = sorted(
        (path.relative_to(root).as_posix(), sha256_file(path))
        for path in root.rglob("*")
        if path.is_file()
    )
    digest = hashlib.sha256()
    for relative, file_hash in entries:
        digest.update(relative.encode("utf-8"))
        digest.update(b"\0")
        digest.update(file_hash.encode("ascii"))
        digest.update(b"\n")
    return digest.hexdigest()


def vendor_tokenizer(source: Path, output: Path) -> dict[str, str]:
    tokenizer_dir = output / "tokenizer"
    tokenizer_dir.mkdir(parents=True, exist_ok=True)
    hashes: dict[str, str] = {}
    for name in TOKENIZER_FILES:
        candidate = source / name
        if not candidate.exists():
            continue
        destination = tokenizer_dir / name
        shutil.copyfile(candidate, destination)
        hashes[name] = sha256_file(destination)
    for required in ("config.json", "tokenizer.json"):
        if required not in hashes:
            sys.exit(f"Model {source} is missing required tokenizer file {required}")
    return hashes


def link_default(output: Path) -> None:
    default_link = output.parent / "default"
    if default_link.is_symlink() or default_link.exists():
        default_link.unlink()
    default_link.symlink_to(output.name)
    print(f"Pointed {default_link} → {output.name}")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Convert an HF embedding model to Core ML.")
    parser.add_argument("--model", default="BAAI/bge-small-en-v1.5")
    parser.add_argument("--revision", default=None, help="Pinned commit sha (resolved if omitted).")
    parser.add_argument("--pooling", choices=["cls", "mean"], default=None)
    parser.add_argument("--query-prefix", default=None)
    parser.add_argument("--output", default=None, help="Model directory (defaults under app support).")
    return parser.parse_args()


def default_output(slug: str) -> Path:
    base = Path.home() / "Library/Application Support/Stower/Models"
    return base / slug


def main() -> None:
    args = parse_args()
    revision = resolve_revision(args.model, args.revision)
    base_fingerprint = f"{args.model}@{revision}"
    slug = base_fingerprint.replace("/", "_")
    pooling, prefix = defaults_for(args.model)
    pooling = args.pooling or pooling
    prefix = args.query_prefix if args.query_prefix is not None else prefix

    output = Path(args.output) if args.output else default_output(slug)
    output.parent.mkdir(parents=True, exist_ok=True)

    print(f"Downloading {args.model} @ {revision} …")
    source = Path(snapshot_download(args.model, revision=revision))
    tokenizer = AutoTokenizer.from_pretrained(source)
    encoder = AutoModel.from_pretrained(source).eval()
    module = EmbeddingModule(encoder, pooling)

    # Build and validate the whole model dir in a sibling staging dir, then swap it
    # into place only after parity AND the manifest succeed. A failed re-conversion
    # (e.g. parity exits non-zero) must never destroy a working model in `output`.
    staging = Path(tempfile.mkdtemp(prefix=".stower-convert-", dir=output.parent))
    try:
        package = trace_and_convert(module, staging)
        run_parity_check(module, ct.models.MLModel(str(package)), encoder.config.vocab_size)
        tokenizer_hashes = vendor_tokenizer(source, staging)
        package_sha = sha256_dir(package)
        # The fingerprint is BOTH the embedding cache key and the compiled-model cache
        # key on the Swift side. Fold pooling, query prefix, and the package hash into
        # it so re-converting the same revision with a different pooling/prefix yields
        # a new fingerprint — never reusing incompatible vectors or a stale .mlmodelc.
        config_digest = hashlib.sha256(
            f"{pooling}\0{prefix}\0{package_sha}".encode("utf-8")
        ).hexdigest()[:12]
        fingerprint = f"{base_fingerprint}+{config_digest}"
        manifest = {
            "model_id": args.model,
            "hf_revision": revision,
            "fingerprint": fingerprint,
            "dims": int(encoder.config.hidden_size),
            "pooling": pooling,
            "query_prefix": prefix,
            "max_tokens": MAX_TOKENS,
            "pad_token_id": int(tokenizer.pad_token_id),
            "cls_token_id": int(tokenizer.cls_token_id),
            "sep_token_id": int(tokenizer.sep_token_id),
            "input_ids_name": "input_ids",
            "attention_mask_name": "attention_mask",
            "output_name": "embeddings",
            "mlpackage": "model.mlpackage",
            "mlpackage_sha256": package_sha,
            "tokenizer_dir": "tokenizer",
            "tokenizer_files": tokenizer_hashes,
        }
        (staging / "manifest.json").write_text(json.dumps(manifest, indent=2, sort_keys=True))
        if output.exists():
            shutil.rmtree(output)
        shutil.move(str(staging), str(output))
    finally:
        if staging.exists():
            shutil.rmtree(staging, ignore_errors=True)
    if args.output is None:
        link_default(output)
    print(f"Wrote {output}/manifest.json ({manifest['dims']} dims, {pooling} pooling)")


if __name__ == "__main__":
    main()
