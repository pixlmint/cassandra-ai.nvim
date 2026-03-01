import argparse
import json
import random
import sys
import textwrap
from collections import Counter
from dataclasses import asdict
from pathlib import Path
from tqdm import tqdm

from fim.deps import HAS_TREE_SITTER, HAS_BM25, HAS_TRANSFORMERS, AutoTokenizer
from fim.types import FIMConfig, FIM_CONFIGS, FIMExample

TOKENIZER_NAMES = {
    "qwen2.5-coder": "Qwen/Qwen2.5-Coder-3B",
    "granite-code":  "ibm-granite/granite-3b-code-base",
    "codellama":     "codellama/CodeLlama-7b-hf",
    "starcoder":     "bigcode/starcoder2-3b",
}
from fim.discovery import find_files
from fim.language import get_language, registered_languages
from fim.bm25 import build_bm25_index
from ._fim import generate_fim_examples, rebalance_examples
from ._quality import print_dataset_stats, compute_complexity_score, filter_low_quality_examples


def build_argument_parser() -> argparse.ArgumentParser:
    """Build and return the CLI argument parser."""
    parser = argparse.ArgumentParser(
        description="Build FIM training dataset from source codebase for LoRA fine-tuning",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=textwrap.dedent("""\
            WORKFLOW:
              1. Generate dataset:
                   python generate.py /path/to/project -o dataset/

              2. Fine-tune with unsloth (recommended):
                   See https://github.com/unslothai/unsloth
                   Use the generated .jsonl with the "text" field.

              3. Validate with ollama_qual_bench.py against your test suite.

              4. Optionally: rejection sampling round 2 with your fine-tuned model.

            TIPS:
              - Start with --cross-file-context off, train, evaluate, then add it.
              - Use --tested-only for highest-confidence training data.
              - The --preview flag lets you inspect examples before committing.
              - For Qwen models, use --base-model qwen2.5-coder (the default).
        """),
    )
    parser.add_argument("project_root", type=Path,
                        help="Root directory of your project")
    parser.add_argument("--output", "-o", type=Path, default=Path("dataset"),
                        help="Output directory (default: dataset/)")
    parser.add_argument("--language", default="php",
                        help=f"Source language (default: php, available: {', '.join(registered_languages())})")
    parser.add_argument("--base-model", default="qwen2.5-coder",
                        choices=list(FIM_CONFIGS.keys()),
                        help="Base model family (determines FIM token format)")
    parser.add_argument("--cross-file-context", action="store_true",
                        help="Include cross-file context in prefix (Layer 2)")
    parser.add_argument("--include-path", type=Path, action="append", default=[],
                        metavar="DIR",
                        help="Extra directories to search for cross-file context "
                             "(e.g. paths on PHP's include_path). May be repeated.")
    parser.add_argument("--tested-only", action="store_true",
                        help="Only include files that have corresponding tests")
    parser.add_argument("--max-middle-lines", type=int, default=30,
                        help="Max lines in the middle section (default: 30)")
    parser.add_argument("--max-total-chars", type=int, default=8192,
                        help="Max total chars per example (default: 8192)")
    parser.add_argument("--max-seq-len", type=int, default=0,
                        help="Token budget for training (0=disabled). Truncates prefix/suffix "
                             "to fit; middle is never truncated. (suggested: 1536)")
    parser.add_argument("--tokenizer", type=str, default=None,
                        help="HuggingFace tokenizer name for accurate token counting. "
                             "Auto-populated from --base-model when transformers is installed. "
                             'Pass "" to disable and use character heuristic.')
    parser.add_argument("--val-split", type=float, default=0.1,
                        help="Validation split ratio (default: 0.1)")
    parser.add_argument("--seed", type=int, default=42,
                        help="Random seed (default: 42)")
    parser.add_argument("--preview", type=int, default=0, metavar="N",
                        help="Preview N examples and exit (don't write files)")
    # Phase 1: AST-FIM
    parser.add_argument("--ast-fim", action="store_true", default=None,
                        help="Use tree-sitter AST spans (default: auto-detect)")
    parser.add_argument("--no-ast-fim", action="store_false", dest="ast_fim",
                        help="Disable AST spans, use regex fallback")
    # Phase 3: BM25
    parser.add_argument("--bm25-context", action="store_true",
                        help="Enable BM25 cross-file retrieval")
    # Phase 4: Curriculum
    parser.add_argument("--curriculum", action="store_true",
                        help="Sort output by complexity (descending)")
    parser.add_argument("--curriculum-top-pct", type=int, default=100, metavar="N",
                        help="Keep only top N%% most complex examples (default: 100)")
    # Phase 5: Quality filter
    parser.add_argument("--quality-filter", action="store_true",
                        help="Apply heuristic quality filtering")
    parser.add_argument("--min-middle-chars", type=int, default=40,
                        help="Minimum middle section length in chars (default: 40)")
    # Span kind filtering
    span_group = parser.add_mutually_exclusive_group()
    span_group.add_argument('--only-spans', nargs='+', metavar='KIND',
                            help='Only include these span kinds')
    span_group.add_argument('--exclude-spans', nargs='+', metavar='KIND',
                            help='Exclude these span kinds')
    return parser


def discover_files(args, lang_config) -> tuple[list[Path], list[Path]]:
    """Discover source files and build the context pool. Returns (source_files, context_pool)."""
    source_files = find_files(args.project_root, lang_config, tested_only=args.tested_only)
    print(f"Found {len(source_files)} {lang_config.name} source files")

    if not source_files:
        print("No files found. Check your project root and filters.")
        sys.exit(1)

    # Discover files in --include-path dirs (used for cross-file context only)
    include_path_files: list[Path] = []
    for inc_dir in args.include_path:
        inc_files = find_files(inc_dir, lang_config)
        print(f"Include path {inc_dir}: {len(inc_files)} {lang_config.name} files")
        include_path_files.extend(inc_files)

    # Combined pool for cross-file context lookups
    context_pool = source_files + include_path_files
    return source_files, context_pool


def build_optional_bm25(args, context_pool):
    """Build BM25 index if requested. Returns index or None."""
    if not args.bm25_context:
        return None
    if not HAS_BM25:
        print("WARNING: rank-bm25 not installed, skipping BM25 context")
        return None
    print("Building BM25 index...")
    bm25_index = build_bm25_index(context_pool, args.project_root)
    if bm25_index:
        print(f"  Indexed {len(bm25_index.chunks)} chunks from {len(set(bm25_index.chunk_files))} files")
    return bm25_index


def generate_all_examples(args, source_files, context_pool, bm25_index, use_ast, lang_config):
    """Run the per-file generation loop. Returns (all_examples, file_complexity)."""
    file_complexity: dict[str, float] = {}
    all_examples = []

    for filepath in tqdm(source_files):
        try:
            source = filepath.read_text(encoding="utf-8", errors="replace")
        except Exception as e:
            print(f"  Skipping {filepath}: {e}")
            continue

        # Skip very small files
        if len(source.split("\n")) < 10:
            continue

        # Compute complexity score for the file
        rel_path = str(filepath.relative_to(args.project_root)) if args.project_root in filepath.parents else str(filepath)
        score = compute_complexity_score(source, lang_config=lang_config)
        file_complexity[rel_path] = score

        examples = generate_fim_examples(
            filepath=filepath,
            source=source,
            root=args.project_root,
            all_files=context_pool if args.cross_file_context else None,
            cross_file=args.cross_file_context,
            max_middle_lines=args.max_middle_lines,
            max_total_chars=args.max_total_chars,
            use_ast=use_ast,
            bm25_index=bm25_index,
            lang_config=lang_config,
            only_spans=set(args.only_spans) if args.only_spans else None,
            exclude_spans=set(args.exclude_spans) if args.exclude_spans else None,
        )

        # Assign complexity scores
        for ex in examples:
            ex.complexity_score = file_complexity.get(ex.filepath, 0.0)

        all_examples.extend(examples)

    return all_examples, file_complexity


def apply_postprocessing(args, all_examples):
    """Apply quality filtering, rebalancing, and curriculum sorting. Returns (examples, rejected_examples, rejected_by_kind)."""
    rejected_examples: list[FIMExample] = []
    rejected_by_kind: dict[str, int] = {}
    if args.quality_filter:
        all_examples, rejected_examples, rejected_by_kind = filter_low_quality_examples(
            all_examples, min_middle_chars=args.min_middle_chars,
        )

    # Rebalance globally after quality filtering (not per-file)
    all_examples = rebalance_examples(all_examples)

    if args.curriculum:
        all_examples.sort(key=lambda ex: ex.complexity_score, reverse=True)
        if args.curriculum_top_pct < 100:
            keep = max(1, len(all_examples) * args.curriculum_top_pct // 100)
            all_examples = all_examples[:keep]

    return all_examples, rejected_examples, rejected_by_kind


def preview_examples(examples, count, fim_config, max_seq_len=0, tokenizer=None):
    """Display a preview of generated examples."""
    print(f"\n{'=' * 60}")
    print(f"PREVIEW ({count} examples)")
    print(f"{'=' * 60}")
    for ex in random.sample(examples, min(count, len(examples))):
        if max_seq_len > 0:
            ex = ex.truncate_to_token_budget(fim_config, max_seq_len, tokenizer=tokenizer)
        formatted = fim_config.format_psm(
            ex.cross_file_context + ex.prefix, ex.middle, ex.suffix
        )
        print(f"\n--- {ex.filepath} [{ex.span_kind}: {ex.span_name}] "
              f"complexity={ex.complexity_score:.2f} ---")
        print(f"Middle ({ex.middle_lines} lines):")
        for line in ex.middle.split("\n")[:10]:
            print(f"  | {line}")
        if ex.middle_lines > 10:
            print(f"  | ... ({ex.middle_lines - 10} more lines)")
        print(f"Cross-file context: {'yes' if ex.cross_file_context else 'no'} "
              f"({len(ex.cross_file_context)} chars)")
        print(f"Total formatted length: {len(formatted)} chars")


def write_output(args, all_examples, fim_config, use_ast, rejected_examples, source_files, lang_config, rejected_by_kind=None, max_seq_len=0, tokenizer=None):
    """Split into train/val and write JSONL + metadata files. Also writes reject.jsonl if there are rejected examples."""
    # Shuffle and split (unless curriculum mode, which keeps the sort order)
    if not args.curriculum:
        random.shuffle(all_examples)
    val_size = int(len(all_examples) * args.val_split)
    val_examples = all_examples[:val_size]
    train_examples = all_examples[val_size:]

    print(f"\n  Train:    {len(train_examples)} examples")
    print(f"  Val:      {len(val_examples)} examples")
    if rejected_examples:
        print(f"  Rejected: {len(rejected_examples)} examples")

    # Write output
    args.output.mkdir(parents=True, exist_ok=True)

    train_path = args.output / "train.jsonl"
    val_path = args.output / "val.jsonl"
    reject_path = args.output / "reject.jsonl"

    for path, examples in [(train_path, train_examples), (val_path, val_examples)]:
        with open(path, "w") as f:
            for ex in examples:
                json.dump(ex.to_training_format(fim_config, max_seq_len=max_seq_len, tokenizer=tokenizer), f)
                f.write("\n")
        print(f"  Wrote {path} ({len(examples)} examples)")

    if rejected_examples:
        with open(reject_path, "w") as f:
            for ex in rejected_examples:
                json.dump(ex.to_training_format(fim_config, max_seq_len=max_seq_len, tokenizer=tokenizer), f)
                f.write("\n")
        print(f"  Wrote {reject_path} ({len(rejected_examples)} examples)")

    # Write metadata
    meta_path = args.output / "metadata.json"
    kinds = Counter(ex.span_kind for ex in train_examples + val_examples)
    complexity_scores = [ex.complexity_score for ex in train_examples + val_examples if ex.complexity_score > 0]
    meta = {
        "language": lang_config.name,
        "base_model": args.base_model,
        "fim_tokens": asdict(fim_config),
        "project_root": str(args.project_root),
        "cross_file_context": args.cross_file_context,
        "bm25_context": args.bm25_context,
        "ast_fim": use_ast and lang_config.ts_language is not None,
        "quality_filter": args.quality_filter,
        "min_middle_chars": args.min_middle_chars,
        "quality_filter_rejected": len(rejected_examples),
        "quality_filter_rejected_by_kind": rejected_by_kind or {},
        "curriculum": args.curriculum,
        "curriculum_top_pct": args.curriculum_top_pct,
        "tested_only": args.tested_only,
        "max_middle_lines": args.max_middle_lines,
        "max_total_chars": args.max_total_chars,
        "max_seq_len": max_seq_len,
        "tokenizer": getattr(tokenizer, 'name_or_path', None) if tokenizer else None,
        "train_examples": len(train_examples),
        "val_examples": len(val_examples),
        "total_files": len(source_files),
        "seed": args.seed,
        "span_type_distribution": dict(kinds.most_common()),
        "complexity_score_stats": {
            "min": min(complexity_scores) if complexity_scores else 0,
            "max": max(complexity_scores) if complexity_scores else 0,
            "mean": sum(complexity_scores) / len(complexity_scores) if complexity_scores else 0,
        },
    }
    with open(meta_path, "w") as f:
        json.dump(meta, f, indent=2)
    print(f"  Wrote {meta_path}")

    print(f"\nDone! Next steps:")
    print(f"  1. Inspect: head -5 {train_path}")
    print(f"  2. Fine-tune with unsloth or axolotl using the 'text' field")
    print(f"  3. Convert to GGUF and test in Ollama")
    print(f"  4. Validate with ollama_qual_bench.py (adapted for your tests)")


def main():
    parser = build_argument_parser()
    args = parser.parse_args()

    random.seed(args.seed)
    fim_config = FIM_CONFIGS[args.base_model]

    # Load tokenizer for accurate token counting
    tokenizer = None
    if args.max_seq_len > 0:
        # Resolve tokenizer name: explicit --tokenizer wins, else auto from --base-model
        tokenizer_name = args.tokenizer
        if tokenizer_name is None:
            tokenizer_name = TOKENIZER_NAMES.get(args.base_model)
        if tokenizer_name == "":
            tokenizer_name = None  # User explicitly disabled with --tokenizer ""

        if tokenizer_name and HAS_TRANSFORMERS:
            print(f"Loading tokenizer: {tokenizer_name}")
            tokenizer = AutoTokenizer.from_pretrained(tokenizer_name)
        elif tokenizer_name and not HAS_TRANSFORMERS:
            print("WARNING: transformers not installed — falling back to character-length "
                  "heuristic for token counting. Install with: pip install transformers")

    # Auto-lower max_total_chars when --max-seq-len is set and --max-total-chars wasn't explicit
    if args.max_seq_len > 0:
        auto_chars = args.max_seq_len * 4 + 1024
        if args.max_total_chars == 8192 and auto_chars < args.max_total_chars:
            args.max_total_chars = auto_chars
            print(f"Auto-lowered --max-total-chars to {auto_chars} (from --max-seq-len {args.max_seq_len})")

    # Resolve language config
    lang_config = get_language(args.language)

    # Resolve AST mode: auto-detect if not explicitly set
    use_ast = args.ast_fim if args.ast_fim is not None else (lang_config.ts_language is not None)

    print(f"Project root: {args.project_root}")
    print(f"Language:     {lang_config.name}")
    print(f"Base model:   {args.base_model}")
    print(f"AST-FIM:      {'enabled' if use_ast and lang_config.ts_language is not None else 'disabled (regex fallback)'}")
    print(f"BM25 context: {'enabled' if args.bm25_context else 'disabled'}")
    print(f"FIM tokens:   {fim_config.prefix_tok} / "
          f"{fim_config.suffix_tok} / {fim_config.middle_tok}")

    source_files, context_pool = discover_files(args, lang_config)
    bm25_index = build_optional_bm25(args, context_pool)
    all_examples, file_complexity = generate_all_examples(
        args, source_files, context_pool, bm25_index, use_ast, lang_config,
    )
    all_examples, rejected_examples, rejected_by_kind = apply_postprocessing(args, all_examples)

    print_dataset_stats(all_examples, rejected=len(rejected_examples), rejected_by_kind=rejected_by_kind)

    if args.preview > 0:
        preview_examples(all_examples, args.preview, fim_config, max_seq_len=args.max_seq_len, tokenizer=tokenizer)
        return

    write_output(args, all_examples, fim_config, use_ast, rejected_examples, source_files, lang_config, rejected_by_kind, max_seq_len=args.max_seq_len, tokenizer=tokenizer)
