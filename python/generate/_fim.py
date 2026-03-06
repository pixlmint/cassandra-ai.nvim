import random
from pathlib import Path

from fim.deps import Parser
from fim.types import CodeSpan, FIMExample, BM25Index, MIN_MIDDLE_WORDS
from ._spans_ast import extract_spans_ast, _find_deepest_containing
from ._spans_regex import extract_spans_regex
from ._spans_charlevel import generate_char_level_splits
from ._spans_devbehavior import (
    generate_incomplete_line_spans,
    generate_bracket_context_spans,
    generate_post_comment_spans,
    generate_doc_comment_spans,
)
from fim.crossfile import build_cross_file_context
from fim.bm25 import retrieve_bm25_context

# Target span category ratios (AST-FIM + SynthCoder papers)
TARGET_RATIOS = {"ast": 0.66, "dev": 0.22, "char": 0.12}


def _categorize(kind: str) -> str:
    if kind.startswith("ast_"):
        return "ast"
    if kind.startswith("dev_"):
        return "dev"
    return "char"


def rebalance_examples(examples: list[FIMExample]) -> list[FIMExample]:
    """Downsample overrepresented categories to match target ratios.

    Only downsamples — if a category is underrepresented, keep all of it
    and redistribute its shortfall proportionally to the others.
    """
    if not examples:
        return examples

    # Group by category
    buckets: dict[str, list[FIMExample]] = {"ast": [], "dev": [], "char": []}
    for ex in examples:
        buckets[_categorize(ex.span_kind)].append(ex)

    total = len(examples)

    # Compute raw targets
    raw_targets = {cat: int(total * ratio) for cat, ratio in TARGET_RATIOS.items()}

    # Find categories that are under target (keep all of them)
    # and redistribute their shortfall to over-target categories
    under = {cat: raw_targets[cat] - len(buckets[cat]) for cat in buckets if len(buckets[cat]) < raw_targets[cat]}
    shortfall = sum(max(0, v) for v in under.values())

    # Categories eligible for downsampling
    over_cats = [cat for cat in buckets if len(buckets[cat]) >= raw_targets[cat]]
    over_ratio_sum = sum(TARGET_RATIOS[cat] for cat in over_cats)

    # Distribute shortfall proportionally among over-target categories
    targets: dict[str, int] = {}
    for cat in buckets:
        if cat in under:
            targets[cat] = len(buckets[cat])  # keep all
        else:
            extra = int(shortfall * TARGET_RATIOS[cat] / over_ratio_sum) if over_ratio_sum > 0 else 0
            targets[cat] = raw_targets[cat] + extra

    # Downsample
    result = []
    for cat, items in buckets.items():
        if len(items) <= targets[cat]:
            result.extend(items)
        else:
            result.extend(random.sample(items, targets[cat]))

    return result


def _resolve_lang_config(lang_config):
    if lang_config is None:
        from fim.language import PHP
        return PHP
    return lang_config


def _make_example_from_byte_span(
    source_bytes: bytes,
    span: CodeSpan,
    rel_path: str,
    xf_context: str,
    max_total_chars: int,
    lines: list[str],
    min_words: int = MIN_MIDDLE_WORDS,
    max_middle_lines: int = 0,
) -> FIMExample | None:
    """Create a FIMExample from a span with byte offsets."""
    sb, eb = span.start_byte, span.end_byte
    prefix = source_bytes[:sb].decode("utf-8", errors="replace")
    middle = source_bytes[sb:eb].decode("utf-8", errors="replace")
    suffix = source_bytes[eb:].decode("utf-8", errors="replace")

    if not middle.strip() or len(middle.split()) < min_words:
        return None

    mid_lines = middle.count("\n") + 1
    if max_middle_lines > 0 and mid_lines > max_middle_lines:
        return None

    total = len(prefix) + len(middle) + len(suffix) + len(xf_context)
    if total > max_total_chars:
        # Budget for prefix+suffix after reserving space for middle and cross-file context
        remaining = max_total_chars - len(middle) - len(xf_context)
        if remaining > 0:
            ps_total = len(prefix) + len(suffix)
            if ps_total > remaining:
                # Proportional trim
                p_budget = int(remaining * len(prefix) / ps_total) if ps_total else remaining // 2
                s_budget = remaining - p_budget
                if len(prefix) > p_budget:
                    prefix = prefix[-p_budget:]
                if len(suffix) > s_budget:
                    suffix = suffix[:s_budget]

        total = len(prefix) + len(middle) + len(suffix) + len(xf_context)
        if total > max_total_chars:
            # Still over — drop cross-file context (least-local), then retry
            xf_context = ""
            remaining = max_total_chars - len(middle)
            if remaining <= 0:
                return None
            ps_total = len(prefix) + len(suffix)
            if ps_total > remaining:
                p_budget = int(remaining * len(prefix) / ps_total) if ps_total else remaining // 2
                s_budget = remaining - p_budget
                if len(prefix) > p_budget:
                    prefix = prefix[-p_budget:]
                if len(suffix) > s_budget:
                    suffix = suffix[:s_budget]
            total = len(prefix) + len(middle) + len(suffix)
            if total > max_total_chars:
                return None

    return FIMExample(
        filepath=rel_path,
        span_kind=span.kind,
        span_name=span.name,
        prefix=prefix,
        middle=middle,
        suffix=suffix,
        cross_file_context=xf_context,
        middle_lines=mid_lines,
        total_lines=len(lines),
        skip_quality_filters=span.skip_quality_filters,
    )


def _split_byte_span_by_statements(
    source_bytes: bytes,
    span: CodeSpan,
    tree_root: "Node",
    max_middle_lines: int,
) -> list[CodeSpan]:
    """Split an oversized byte span into statement-grouped sub-spans.

    Finds the deepest AST node containing the span, drills into its body
    child (compound_statement / block / statement_block), and groups
    statement children into chunks of <= max_middle_lines each.

    Returns empty list if no statement children found (caller should
    use sliding window fallback).
    """
    containing = _find_deepest_containing(tree_root, span.start_byte, span.end_byte)

    # Drill into body child if present
    body_types = frozenset({"compound_statement", "block", "statement_block"})
    target = containing
    for child in containing.children:
        if child.type in body_types:
            target = child
            break

    # Collect statement children (skip punctuation/delimiters)
    skip_types = frozenset({
        "{", "}", "(", ")", "[", "]", ":", ";",
        "NEWLINE", "INDENT", "DEDENT", "comment",
    })
    statements = [c for c in target.children if c.type not in skip_types and c.type]
    if not statements:
        return []

    sub_spans: list[CodeSpan] = []
    group_start = statements[0].start_byte
    group_start_line = source_bytes[:group_start].count(b"\n")

    for stmt in statements:
        stmt_end_line = source_bytes[:stmt.end_byte].count(b"\n")
        group_lines = stmt_end_line - group_start_line + 1
        if group_lines > max_middle_lines and group_start != stmt.start_byte:
            # Finalize current group (exclude this statement)
            sub_spans.append(CodeSpan(
                kind=span.kind + "_split",
                start_line=group_start_line,
                end_line=source_bytes[:prev_end].count(b"\n"),
                name=span.name,
                start_byte=group_start,
                end_byte=prev_end,
                skip_quality_filters=span.skip_quality_filters,
            ))
            group_start = stmt.start_byte
            group_start_line = source_bytes[:group_start].count(b"\n")
        prev_end = stmt.end_byte

    # Finalize last group
    if group_start < statements[-1].end_byte:
        sub_spans.append(CodeSpan(
            kind=span.kind + "_split",
            start_line=group_start_line,
            end_line=source_bytes[:statements[-1].end_byte].count(b"\n"),
            name=span.name,
            start_byte=group_start,
            end_byte=statements[-1].end_byte,
            skip_quality_filters=span.skip_quality_filters,
        ))

    return sub_spans


def _split_byte_span_sliding_window(
    source_bytes: bytes,
    span: CodeSpan,
    max_middle_lines: int,
    stride: int = 0,
) -> list[CodeSpan]:
    """Split an oversized byte span using a sliding window over lines.

    Slides a max_middle_lines-sized window with 50% overlap (default stride)
    across the middle text, emitting each window as a sub-span.
    """
    if stride <= 0:
        stride = max(1, max_middle_lines // 2)

    middle = source_bytes[span.start_byte:span.end_byte]
    mid_lines = middle.split(b"\n")

    if len(mid_lines) <= max_middle_lines:
        return [span]

    # Compute byte offset of each line within the middle
    line_byte_offsets = []
    offset = 0
    for line in mid_lines:
        line_byte_offsets.append(offset)
        offset += len(line) + 1  # +1 for newline

    sub_spans: list[CodeSpan] = []
    i = 0
    while i < len(mid_lines):
        end_i = min(i + max_middle_lines, len(mid_lines))

        # Compute byte offsets relative to source
        window_start = span.start_byte + line_byte_offsets[i]
        if end_i < len(mid_lines):
            window_end = span.start_byte + line_byte_offsets[end_i] - 1  # exclude trailing newline
        else:
            window_end = span.end_byte

        if window_end > window_start:
            start_line = source_bytes[:window_start].count(b"\n")
            end_line = source_bytes[:window_end].count(b"\n")
            sub_spans.append(CodeSpan(
                kind=span.kind + "_window",
                start_line=start_line,
                end_line=end_line,
                name=span.name,
                start_byte=window_start,
                end_byte=window_end,
                skip_quality_filters=span.skip_quality_filters,
            ))

        if end_i >= len(mid_lines):
            break
        i += stride

    return sub_spans


def _make_example_from_line_span(
    source: str,
    span: CodeSpan,
    rel_path: str,
    xf_context: str,
    max_total_chars: int,
    max_middle_lines: int,
    min_middle_lines: int,
    lines: list[str],
) -> FIMExample | None:
    """Create a FIMExample from a span with line numbers."""
    span_lines = span.end_line - span.start_line + 1
    if span_lines < min_middle_lines or span_lines > max_middle_lines:
        return None

    prefix_lines = lines[:span.start_line]
    middle_lines_lst = lines[span.start_line:span.end_line + 1]
    suffix_lines = lines[span.end_line + 1:]

    prefix = "\n".join(prefix_lines)
    middle = "\n".join(middle_lines_lst)
    suffix = "\n".join(suffix_lines)

    if not middle.strip() or len(middle.split()) < MIN_MIDDLE_WORDS:
        return None

    total = len(prefix) + len(middle) + len(suffix) + len(xf_context)
    if total > max_total_chars:
        max_context_lines = 80
        if len(prefix_lines) > max_context_lines:
            prefix = "\n".join(prefix_lines[-max_context_lines:])
        if len(suffix_lines) > max_context_lines:
            suffix = "\n".join(suffix_lines[:max_context_lines])
        total = len(prefix) + len(middle) + len(suffix) + len(xf_context)
        if total > max_total_chars:
            return None

    return FIMExample(
        filepath=rel_path,
        span_kind=span.kind,
        span_name=span.name,
        prefix=prefix + "\n",
        middle=middle,
        suffix="\n" + suffix if suffix else "",
        cross_file_context=xf_context,
        middle_lines=span_lines,
        total_lines=len(lines),
    )


def generate_fim_examples(
    filepath: Path,
    source: str,
    root: Path,
    all_files: list[Path] | None = None,
    cross_file: bool = False,
    max_middle_lines: int = 30,
    min_middle_lines: int = 1,
    max_total_chars: int = 8192,
    use_ast: bool = True,
    bm25_index: BM25Index | None = None,
    lang_config=None,
    only_spans: set[str] | None = None,
    exclude_spans: set[str] | None = None,
) -> list[FIMExample]:
    """
    Generate FIM training examples from a single source file.

    Span distribution (per AST-FIM + SynthCoder papers):
      ~66% AST spans (single-node + aligned-span)
      ~22% developer behavior simulation spans
      ~10% random character-level spans

    When use_ast=False or tree-sitter unavailable, falls back to regex spans
    with char-level random splits.
    """
    lc = _resolve_lang_config(lang_config)
    lines = source.split("\n")
    examples = []

    rel_path = str(filepath.relative_to(root)) if root in filepath.parents else str(filepath)

    # Build cross-file context once per file
    xf_context = ""
    if cross_file and all_files:
        xf_context = build_cross_file_context(filepath, all_files, root, source, lang_config=lc)

    # Build BM25 context once per file (not per-span — the query is similar enough)
    bm25_file_ctx = ""
    if bm25_index is not None:
        file_query = source[:2000]
        bm25_file_ctx = retrieve_bm25_context(
            file_query, "", bm25_index, rel_path,
        )

    # Parse tree once for reuse across span generators
    tree_root = None
    if use_ast and lc.ts_language is not None:
        parser = Parser(lc.ts_language)
        tree = parser.parse(source.encode("utf-8"))
        tree_root = tree.root_node

    # --- Collect all spans ---
    all_spans: list[CodeSpan] = []

    if use_ast and lc.ts_language is not None:
        # AST spans (~66% — from extract_spans_ast which has its own count scaling)
        ast_spans = extract_spans_ast(source, lang_config=lc, max_middle_lines=max_middle_lines)
        all_spans.extend(ast_spans)

        # Developer behavior spans (~22%)
        all_spans.extend(generate_incomplete_line_spans(source, tree_root, lang_config=lc, max_middle_lines=max_middle_lines))
        all_spans.extend(generate_bracket_context_spans(source, tree_root, lang_config=lc))
        all_spans.extend(generate_post_comment_spans(source, tree_root, lang_config=lc, max_middle_lines=max_middle_lines))
        all_spans.extend(generate_doc_comment_spans(source, tree_root, lang_config=lc))
    else:
        # Regex fallback
        all_spans.extend(extract_spans_regex(source, lang_config=lc))

    # Random char-level spans (~10%)
    char_spans = generate_char_level_splits(source)
    all_spans.extend(char_spans)

    # --- Filter spans by kind ---
    if only_spans is not None:
        all_spans = [s for s in all_spans if s.kind in only_spans]
    elif exclude_spans is not None:
        all_spans = [s for s in all_spans if s.kind not in exclude_spans]

    # --- Convert spans to FIMExamples ---
    source_bytes = source.encode("utf-8")

    # Joint context budget: cap combined cross-file + BM25 context to 1024 tokens
    # to prevent context from overwhelming the prefix/suffix/middle content.
    from fim.types import CHARS_PER_TOKEN
    max_context_chars = 1024 * CHARS_PER_TOKEN

    def _attach_bm25_and_append(ex: FIMExample):
        if bm25_file_ctx:
            combined = bm25_file_ctx + ex.cross_file_context
            if len(combined) > max_context_chars:
                combined = combined[:max_context_chars]
            total = len(ex.prefix) + len(ex.middle) + len(ex.suffix) + len(combined)
            if total <= max_total_chars:
                ex.cross_file_context = combined
        elif len(ex.cross_file_context) > max_context_chars:
            ex.cross_file_context = ex.cross_file_context[:max_context_chars]
        examples.append(ex)

    for span in all_spans:
        if span.start_byte >= 0 and span.end_byte > span.start_byte:
            # Byte-offset spans (AST, dev-behavior)
            min_w = 1 if span.kind.startswith("dev_") else MIN_MIDDLE_WORDS
            middle = source_bytes[span.start_byte:span.end_byte]
            mid_lines = middle.count(b"\n") + 1

            if max_middle_lines > 0 and mid_lines > max_middle_lines:
                # Oversized span — try statement-aware split, then sliding window
                sub_spans: list[CodeSpan] = []
                if tree_root is not None:
                    sub_spans = _split_byte_span_by_statements(source_bytes, span, tree_root, max_middle_lines)
                if not sub_spans:
                    sub_spans = _split_byte_span_sliding_window(source_bytes, span, max_middle_lines)
                else:
                    # Statement split may produce sub-spans still exceeding the limit
                    # (e.g. a single large method inside a class); apply window fallback
                    expanded: list[CodeSpan] = []
                    for sub in sub_spans:
                        sub_mid = source_bytes[sub.start_byte:sub.end_byte]
                        if max_middle_lines > 0 and sub_mid.count(b"\n") + 1 > max_middle_lines:
                            expanded.extend(_split_byte_span_sliding_window(source_bytes, sub, max_middle_lines))
                        else:
                            expanded.append(sub)
                    sub_spans = expanded

                for sub in sub_spans:
                    sub_min_w = 1 if sub.kind.startswith("dev_") else MIN_MIDDLE_WORDS
                    ex = _make_example_from_byte_span(
                        source_bytes, sub, rel_path, xf_context, max_total_chars, lines,
                        min_words=sub_min_w, max_middle_lines=max_middle_lines,
                    )
                    if ex is not None:
                        _attach_bm25_and_append(ex)
            else:
                ex = _make_example_from_byte_span(
                    source_bytes, span, rel_path, xf_context, max_total_chars, lines,
                    min_words=min_w, max_middle_lines=max_middle_lines,
                )
                if ex is not None:
                    _attach_bm25_and_append(ex)

        elif span.kind == "char_random":
            # Char-level random spans (offsets stored in start_line/end_line as char offsets)
            # Convert char offsets to byte offsets for consistent handling
            char_start = span.start_line
            char_end = span.end_line
            byte_start = len(source[:char_start].encode("utf-8"))
            byte_end = len(source[:char_end].encode("utf-8"))
            fake_byte_span = CodeSpan(
                kind=span.kind, start_line=span.start_line, end_line=span.end_line,
                name=span.name, start_byte=byte_start, end_byte=byte_end,
            )
            ex = _make_example_from_byte_span(
                source_bytes, fake_byte_span, rel_path, xf_context, max_total_chars, lines,
                max_middle_lines=max_middle_lines,
            )
            if ex is not None:
                _attach_bm25_and_append(ex)
        else:
            # Line-level spans (regex fallback)
            ex = _make_example_from_line_span(
                source, span, rel_path, xf_context, max_total_chars,
                max_middle_lines, min_middle_lines, lines,
            )
            if ex is not None:
                _attach_bm25_and_append(ex)

    return examples
