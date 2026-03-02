#!/usr/bin/env python3
"""
filter_dataset.py — Filter samples from a FIM dataset by span_kind and/or token count.

Supports filtering by:
  - span_kind: include or exclude samples by their span_kind field
  - token count: remove oversized samples using a real tokenizer or char estimate

USAGE
=====
    # Include only specific span kinds
    python filter_dataset.py --dataset dataset/train.jsonl \\
        --include-span-kind ast_single_node ast_aligned_span --dry-run

    # Exclude char_random spans, then also filter by token count
    python filter_dataset.py --dataset dataset/train.jsonl \\
        --exclude-span-kind char_random --dry-run

    # Token count filter only (existing behavior)
    python filter_dataset.py --dataset dataset/train.jsonl --dry-run

    # Exact tokenizer filter
    python filter_dataset.py --dataset dataset/train.jsonl \\
        --output dataset/train_filtered.jsonl \\
        --tokenizer Qwen/Qwen2.5-Coder-3B
"""

import argparse
import json
import sys
from pathlib import Path


def load_dataset(path: Path) -> list[dict]:
    examples = []
    with open(path) as f:
        for i, line in enumerate(f):
            line = line.strip()
            if line:
                try:
                    examples.append((i + 1, json.loads(line)))
                except json.JSONDecodeError:
                    print(f"  Warning: skipping malformed line {i + 1}", file=sys.stderr)
    return examples


def filter_by_span_kind(examples, include=None, exclude=None):
    kept, removed = [], []
    for lineno, ex in examples:
        kind = ex.get("span_kind", "")
        if include is not None and kind not in include:
            removed.append((lineno, ex, kind))
        elif exclude is not None and kind in exclude:
            removed.append((lineno, ex, kind))
        else:
            kept.append((lineno, ex))
    return kept, removed


def filter_by_chars(examples: list[tuple[int, dict]], max_seq_len: int, chars_per_token: float):
    kept, removed = [], []
    for lineno, ex in examples:
        est_tok = len(ex.get("text", "")) / chars_per_token
        if est_tok > max_seq_len:
            removed.append((lineno, ex, int(est_tok)))
        else:
            kept.append(ex)
    return kept, removed


def filter_by_tokenizer(examples: list[tuple[int, dict]], tokenizer, max_seq_len: int):
    kept, removed = [], []
    total = len(examples)
    for i, (lineno, ex) in enumerate(examples):
        if (i + 1) % 500 == 0 or i + 1 == total:
            print(f"  Tokenizing... {i + 1}/{total}", end="\r", flush=True)
        tokens = tokenizer.encode(ex.get("text", ""), add_special_tokens=False)
        n_tok = len(tokens)
        if n_tok > max_seq_len:
            removed.append((lineno, ex, n_tok))
        else:
            kept.append(ex)
    print()  # newline after progress
    return kept, removed


def write_dataset(path: Path, examples: list[dict]):
    with open(path, "w") as f:
        for ex in examples:
            f.write(json.dumps(ex) + "\n")


def main():
    parser = argparse.ArgumentParser(
        description="Remove oversized samples from a FIM JSONL dataset",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument("--dataset", required=True, type=Path, help="Input JSONL dataset file")
    parser.add_argument("--output", type=Path, default=None,
                        help="Output JSONL path. Defaults to <dataset>_filtered.jsonl alongside the input file.")

    span_group = parser.add_mutually_exclusive_group()
    span_group.add_argument("--include-span-kind", nargs="+", metavar="KIND",
                            help="Keep only samples whose span_kind is in this list")
    span_group.add_argument("--exclude-span-kind", nargs="+", metavar="KIND",
                            help="Remove samples whose span_kind is in this list")

    parser.add_argument("--tokenizer", type=str, default=None,
                        help="HuggingFace tokenizer name/path (e.g. Qwen/Qwen2.5-Coder-3B). "
                             "If omitted, uses character-level estimates.")
    parser.add_argument("--max-seq-len", type=int, default=1536,
                        help="Max sequence length threshold (default: 1536)")
    parser.add_argument("--chars-per-token", type=float, default=3.0,
                        help="Chars/token estimate for character-level mode (default: 3.0)")
    parser.add_argument("--dry-run", action="store_true",
                        help="Report what would be removed without writing any output file")
    parser.add_argument("--show-removed", type=int, default=10, metavar="N",
                        help="Print up to N removed sample line numbers (default: 10, 0 to suppress)")
    args = parser.parse_args()

    if not args.dataset.exists():
        print(f"ERROR: Dataset not found: {args.dataset}", file=sys.stderr)
        sys.exit(1)

    if args.output is None:
        args.output = args.dataset.with_stem(args.dataset.stem + "_filtered")

    print(f"Loading dataset: {args.dataset}")
    examples = load_dataset(args.dataset)
    n_total = len(examples)
    print(f"Loaded {n_total} examples")

    # --- Stage 1: span_kind filtering ---
    include_kinds = set(args.include_span_kind) if args.include_span_kind else None
    exclude_kinds = set(args.exclude_span_kind) if args.exclude_span_kind else None

    if include_kinds or exclude_kinds:
        if include_kinds:
            label = f"include span_kind: {', '.join(sorted(include_kinds))}"
        else:
            label = f"exclude span_kind: {', '.join(sorted(exclude_kinds))}"
        print(f"\nFiltering by {label}...")
        remaining, span_removed = filter_by_span_kind(examples, include=include_kinds, exclude=exclude_kinds)
        n_span_removed = len(span_removed)
        n_after_span = len(remaining)
        print(f"  Kept:    {n_after_span}  ({100 * n_after_span / n_total:.1f}%)")
        print(f"  Removed: {n_span_removed}  ({100 * n_span_removed / n_total:.1f}%)")
        if span_removed and args.show_removed > 0:
            from collections import Counter
            kind_counts = Counter(kind for _, _, kind in span_removed)
            print(f"  Removed by kind:")
            for kind, count in kind_counts.most_common():
                print(f"    {kind}: {count}")
    else:
        remaining = examples

    # --- Stage 2: token-count filtering ---
    if args.tokenizer:
        try:
            from transformers import AutoTokenizer
        except ImportError:
            print("\nERROR: transformers not installed. Install with:", file=sys.stderr)
            print("  pip install transformers", file=sys.stderr)
            sys.exit(1)
        print(f"\nLoading tokenizer: {args.tokenizer}")
        tokenizer = AutoTokenizer.from_pretrained(args.tokenizer, trust_remote_code=True)
        print(f"Filtering by exact token count (max {args.max_seq_len})...")
        kept, tok_removed = filter_by_tokenizer(remaining, tokenizer, args.max_seq_len)
        mode = f"tokenizer ({args.tokenizer})"
    else:
        print(f"\nFiltering by estimated token count "
              f"(max {args.max_seq_len}, chars_per_token={args.chars_per_token})...")
        kept, tok_removed = filter_by_chars(remaining, args.max_seq_len, args.chars_per_token)
        mode = f"char estimate (÷{args.chars_per_token})"

    n_remaining = len(remaining)
    n_tok_removed = len(tok_removed)
    n_kept = len(kept)

    print(f"\nToken filter results ({mode}):")
    print(f"  Input:   {n_remaining}")
    print(f"  Kept:    {n_kept}  ({100 * n_kept / n_remaining:.1f}%)" if n_remaining else f"  Kept:    0")
    print(f"  Removed: {n_tok_removed}  ({100 * n_tok_removed / n_remaining:.1f}%)" if n_remaining else f"  Removed: 0")

    if tok_removed and args.show_removed > 0:
        worst = sorted(tok_removed, key=lambda v: v[2], reverse=True)
        show = worst[: args.show_removed]
        print(f"\n  Longest removed samples (up to {args.show_removed}):")
        for lineno, _, tok_count in show:
            print(f"    line {lineno}: {tok_count} tokens (+{tok_count - args.max_seq_len} over limit)")

    # --- Summary ---
    print(f"\nFinal: {n_kept}/{n_total} examples kept ({100 * n_kept / n_total:.1f}%)")

    if args.dry_run:
        print("\nDry run — no output written.")
        return

    write_dataset(args.output, kept)
    print(f"\nWrote {n_kept} examples to: {args.output}")


if __name__ == "__main__":
    main()
