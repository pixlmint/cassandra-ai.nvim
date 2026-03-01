#!/usr/bin/env python3
"""
analyze_dataset.py — Diagnose FIM dataset quality using the actual model tokenizer.

Tokenizes each sample with the target model's tokenizer and reports:
- Token count distribution (percentiles, histogram)
- Samples exceeding --max-seq-len and what gets truncated
- Cross-file context presence and size distribution
- FIM structure integrity (presence of special tokens)

USAGE
=====
    # Basic analysis
    python analyze_dataset.py --dataset dataset/train.jsonl

    # With actual tokenizer (requires transformers)
    python analyze_dataset.py --dataset dataset/train.jsonl \
        --tokenizer Qwen/Qwen2.5-Coder-3B

    # Check against a specific max sequence length
    python analyze_dataset.py --dataset dataset/train.jsonl \
        --tokenizer Qwen/Qwen2.5-Coder-3B \
        --max-seq-len 1536
"""

import argparse
import json
import sys
from collections import Counter
from pathlib import Path


def load_dataset(path: Path) -> list[dict]:
    examples = []
    with open(path) as f:
        for i, line in enumerate(f):
            line = line.strip()
            if line:
                try:
                    examples.append(json.loads(line))
                except json.JSONDecodeError:
                    print(f"  Warning: skipping malformed line {i + 1}", file=sys.stderr)
    return examples


def char_analysis(examples: list[dict], max_seq_len: int, chars_per_token: float):
    """Analyze dataset using character-level heuristics (no tokenizer needed)."""
    char_counts = []
    estimated_tokens = []
    over_limit = 0

    for ex in examples:
        text = ex.get("text", "")
        n_chars = len(text)
        char_counts.append(n_chars)
        est_tok = n_chars / chars_per_token
        estimated_tokens.append(est_tok)
        if max_seq_len > 0 and est_tok > max_seq_len:
            over_limit += 1

    char_counts.sort()
    estimated_tokens.sort()
    n = len(char_counts)

    def percentile(lst, p):
        idx = int(n * p / 100)
        return lst[min(idx, n - 1)]

    print(f"\n--- Character-level analysis (chars_per_token={chars_per_token}) ---")
    print(f"  Total examples: {n}")
    print(f"  Char count — min: {char_counts[0]}, median: {percentile(char_counts, 50)}, "
          f"p95: {percentile(char_counts, 95)}, max: {char_counts[-1]}")
    print(f"  Est. tokens — min: {estimated_tokens[0]:.0f}, median: {percentile(estimated_tokens, 50):.0f}, "
          f"p95: {percentile(estimated_tokens, 95):.0f}, max: {estimated_tokens[-1]:.0f}")
    if max_seq_len > 0:
        print(f"  Over {max_seq_len} tokens (estimated): {over_limit}/{n} ({100 * over_limit / n:.1f}%)")


def tokenizer_analysis(examples: list[dict], tokenizer, max_seq_len: int):
    """Analyze dataset using actual tokenizer."""
    token_counts = []
    over_limit = 0
    truncation_victims = []  # examples that would lose FIM structure

    # Detect FIM special tokens
    fim_middle_candidates = ["<|fim_middle|>", "<fim_middle>", "<MID>"]
    eot_candidates = ["<|endoftext|>", "</s>"]

    for i, ex in enumerate(examples):
        text = ex.get("text", "")
        tokens = tokenizer.encode(text, add_special_tokens=False)
        n_tok = len(tokens)
        token_counts.append(n_tok)

        if max_seq_len > 0 and n_tok > max_seq_len:
            over_limit += 1
            # Check what gets truncated with right-truncation
            truncated_right = tokenizer.decode(tokens[:max_seq_len])
            # Check what gets truncated with left-truncation
            truncated_left = tokenizer.decode(tokens[-max_seq_len:])

            has_middle_right = any(tok in truncated_right for tok in fim_middle_candidates)
            has_eot_right = any(tok in truncated_right for tok in eot_candidates)
            has_middle_left = any(tok in truncated_left for tok in fim_middle_candidates)
            has_eot_left = any(tok in truncated_left for tok in eot_candidates)

            truncation_victims.append({
                "index": i,
                "tokens": n_tok,
                "overflow": n_tok - max_seq_len,
                "right_trunc_keeps_middle": has_middle_right,
                "right_trunc_keeps_eot": has_eot_right,
                "left_trunc_keeps_middle": has_middle_left,
                "left_trunc_keeps_eot": has_eot_left,
            })

    token_counts.sort()
    n = len(token_counts)

    def percentile(lst, p):
        idx = int(n * p / 100)
        return lst[min(idx, n - 1)]

    print(f"\n--- Tokenizer analysis ({tokenizer.name_or_path}) ---")
    print(f"  Total examples: {n}")
    print(f"  Token count — min: {token_counts[0]}, median: {percentile(token_counts, 50)}, "
          f"p95: {percentile(token_counts, 95)}, max: {token_counts[-1]}")

    # Histogram
    buckets = [0, 256, 512, 768, 1024, 1536, 2048, 3072, 4096, float("inf")]
    hist = Counter()
    for tc in token_counts:
        for j in range(len(buckets) - 1):
            if buckets[j] <= tc < buckets[j + 1]:
                label = f"{buckets[j]}-{buckets[j+1] if buckets[j+1] != float('inf') else '+'}"
                hist[label] += 1
                break
    print(f"\n  Token count histogram:")
    for j in range(len(buckets) - 1):
        label = f"{buckets[j]}-{buckets[j+1] if buckets[j+1] != float('inf') else '+'}"
        count = hist.get(label, 0)
        bar = "#" * (count * 40 // n) if n > 0 else ""
        print(f"    {label:>10s}: {count:5d} ({100 * count / n:5.1f}%) {bar}")

    if max_seq_len > 0:
        print(f"\n  Over {max_seq_len} tokens: {over_limit}/{n} ({100 * over_limit / n:.1f}%)")

        if truncation_victims:
            # Analyze truncation impact
            right_loses_middle = sum(1 for v in truncation_victims if not v["right_trunc_keeps_middle"])
            right_loses_eot = sum(1 for v in truncation_victims if not v["right_trunc_keeps_eot"])
            left_loses_middle = sum(1 for v in truncation_victims if not v["left_trunc_keeps_middle"])
            left_loses_eot = sum(1 for v in truncation_victims if not v["left_trunc_keeps_eot"])

            print(f"\n  Truncation impact on {len(truncation_victims)} over-length samples:")
            print(f"    Right-truncation (old default):")
            print(f"      Loses <fim_middle>: {right_loses_middle}/{len(truncation_victims)}")
            print(f"      Loses <endoftext>:  {right_loses_eot}/{len(truncation_victims)}")
            print(f"    Left-truncation (new default):")
            print(f"      Loses <fim_middle>: {left_loses_middle}/{len(truncation_victims)}")
            print(f"      Loses <endoftext>:  {left_loses_eot}/{len(truncation_victims)}")

            # Show worst offenders
            worst = sorted(truncation_victims, key=lambda v: v["overflow"], reverse=True)[:5]
            print(f"\n  Top 5 longest samples:")
            for v in worst:
                print(f"    Example {v['index']}: {v['tokens']} tokens (+{v['overflow']} over limit)")


def context_analysis(examples: list[dict]):
    """Analyze cross-file context usage."""
    has_context = 0
    context_sizes = []

    # Check for cross-file context markers
    xf_markers = ["// --- cross-file context", "# --- cross-file context", "<!-- cross-file"]

    for ex in examples:
        text = ex.get("text", "")
        cross_file = ex.get("cross_file_context", "")

        # Try metadata field first, then scan text
        if cross_file:
            has_context += 1
            context_sizes.append(len(cross_file))
        elif any(m in text for m in xf_markers):
            has_context += 1

    n = len(examples)
    print(f"\n--- Cross-file context ---")
    print(f"  Examples with context: {has_context}/{n} ({100 * has_context / n:.1f}%)")
    if context_sizes:
        context_sizes.sort()
        print(f"  Context chars — min: {context_sizes[0]}, median: {context_sizes[len(context_sizes) // 2]}, "
              f"max: {context_sizes[-1]}")


def fim_structure_check(examples: list[dict]):
    """Check FIM token structure integrity."""
    fim_tokens = {
        "prefix": ["<|fim_prefix|>", "<fim_prefix>", "<PRE>"],
        "suffix": ["<|fim_suffix|>", "<fim_suffix>", "<SUF>"],
        "middle": ["<|fim_middle|>", "<fim_middle>", "<MID>"],
    }

    missing = Counter()
    n = len(examples)

    for ex in examples:
        text = ex.get("text", "")
        for role, candidates in fim_tokens.items():
            if not any(tok in text for tok in candidates):
                missing[role] += 1

    print(f"\n--- FIM structure check ---")
    for role in ["prefix", "suffix", "middle"]:
        count = missing.get(role, 0)
        if count > 0:
            print(f"  Missing {role} token: {count}/{n} ({100 * count / n:.1f}%)")
    if not missing:
        print(f"  All {n} examples have complete FIM token structure")


def main():
    parser = argparse.ArgumentParser(
        description="Analyze FIM dataset quality and token distribution",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument("--dataset", required=True, type=Path, help="JSONL dataset file")
    parser.add_argument("--tokenizer", type=str, default=None,
                        help="HuggingFace tokenizer name/path (e.g. Qwen/Qwen2.5-Coder-3B). "
                             "If omitted, uses character-level estimates only.")
    parser.add_argument("--max-seq-len", type=int, default=1536,
                        help="Max sequence length to check against (default: 1536)")
    parser.add_argument("--chars-per-token", type=float, default=3.0,
                        help="Chars/token estimate for character-level analysis (default: 3.0)")
    args = parser.parse_args()

    if not args.dataset.exists():
        print(f"ERROR: Dataset not found: {args.dataset}", file=sys.stderr)
        sys.exit(1)

    print(f"Loading dataset: {args.dataset}")
    examples = load_dataset(args.dataset)
    print(f"Loaded {len(examples)} examples")

    # Always run character-level and structural analyses
    char_analysis(examples, args.max_seq_len, args.chars_per_token)
    fim_structure_check(examples)
    context_analysis(examples)

    # Run tokenizer analysis if requested
    if args.tokenizer:
        try:
            from transformers import AutoTokenizer
        except ImportError:
            print("\nERROR: transformers not installed. Install with:", file=sys.stderr)
            print("  pip install transformers", file=sys.stderr)
            sys.exit(1)

        print(f"\nLoading tokenizer: {args.tokenizer}")
        tokenizer = AutoTokenizer.from_pretrained(args.tokenizer, trust_remote_code=True)
        tokenizer_analysis(examples, tokenizer, args.max_seq_len)

    print()


if __name__ == "__main__":
    main()
