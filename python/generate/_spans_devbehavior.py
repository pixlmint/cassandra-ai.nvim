import random
import re

from fim.types import CodeSpan
from ._spans_ast import _find_deepest_containing


def _resolve_lang_config(lang_config):
    if lang_config is None:
        from fim.language import PHP
        return PHP
    return lang_config


def _truncate_node_to_statements(
    node: "Node",
    source_bytes: bytes,
    max_middle_lines: int,
) -> int:
    """Return a truncated end_byte for *node* capped by line budget.

    For function-like nodes (method_declaration, function_definition, etc.)
    this drills into the body child (compound_statement / block) and includes
    statement children until *max_middle_lines* is reached.  For other compound
    nodes it walks the immediate children directly.

    If the node has no meaningful children or is already small enough, the
    original ``node.end_byte`` is returned unchanged.
    """
    # Punctuation / delimiter types that aren't "statements"
    skip_types = frozenset({
        "{", "}", "(", ")", "[", "]", ":", ";",
        "NEWLINE", "INDENT", "DEDENT", "comment",
    })

    # For function-like nodes, drill into the body (compound_statement / block)
    # so we count actual statements rather than signature parts.
    body_types = frozenset({
        "compound_statement", "block", "statement_block",
    })
    target = node
    for child in node.children:
        if child.type in body_types:
            target = child
            break

    node_start_line = source_bytes[:node.start_byte].count(b"\n")
    last_end = node.start_byte

    for child in target.children:
        if child.type in skip_types or not child.type:
            # Still include the opening brace / signature in the span
            last_end = max(last_end, child.end_byte)
            continue
        child_end_line = source_bytes[:child.end_byte].count(b"\n")
        span_lines = child_end_line - node_start_line + 1
        if span_lines > max_middle_lines:
            break
        last_end = child.end_byte

    return last_end if last_end > node.start_byte else node.end_byte


def generate_incomplete_line_spans(
    source: str, tree: "Node | None" = None, lang_config=None,
    max_middle_lines: int = 30,
) -> list[CodeSpan]:
    """
    Generate spans simulating a developer typing mid-line (~15% of spans).
    Two sub-strategies: random intra-line and syntax-aware triggered.
    """
    lc = _resolve_lang_config(lang_config)
    lines = source.split("\n")
    source_bytes = source.encode("utf-8")
    spans = []
    target_count = max(1, len(lines) // 15)

    # Precompute byte offset of each line start for O(1) lookup
    byte_lines = source_bytes.split(b"\n")
    line_byte_starts = []
    pos = 0
    for bl in byte_lines:
        line_byte_starts.append(pos)
        pos += len(bl) + 1

    # Sub-strategy 1: Random intra-line (half)
    for _ in range(target_count // 2 + 1):
        candidates = [
            i for i, l in enumerate(lines)
            if l.strip() and not l.strip().startswith(("//", "/*", "*", "#"))
            and len(l.strip()) > 10
        ]
        if not candidates:
            break
        line_idx = random.choice(candidates)
        line = lines[line_idx]
        stripped = line.lstrip()
        indent_len = len(line) - len(stripped)

        if len(stripped) < 5:
            continue
        offset = random.randint(3, len(stripped) - 1)

        # Convert char position to byte offset within the line
        cut_byte = line_byte_starts[line_idx] + len(line[:indent_len + offset].encode("utf-8"))
        line_end_byte = line_byte_starts[line_idx] + len(byte_lines[line_idx])

        if line_end_byte - cut_byte < 3:
            continue

        spans.append(CodeSpan(
            kind="dev_incomplete_line",
            start_line=line_idx,
            end_line=line_idx,
            start_byte=cut_byte,
            end_byte=line_end_byte,
        ))

    # Sub-strategy 2: Syntax-aware triggered (half)
    trigger_tokens = lc.trigger_tokens
    for _ in range(target_count // 2 + 1):
        trigger_candidates = []
        for i, line in enumerate(lines):
            stripped = line.strip()
            if not stripped or stripped.startswith(("//", "/*", "*", "#")):
                continue
            for tok in trigger_tokens:
                pos = stripped.find(tok)
                if pos >= 0:
                    trigger_candidates.append((i, line, tok, pos))
                    break
        if not trigger_candidates:
            break

        line_idx, line, tok, tok_pos_in_stripped = random.choice(trigger_candidates)
        indent_len = len(line) - len(line.lstrip())
        cut_in_line = indent_len + tok_pos_in_stripped + len(tok)

        # Convert char position to byte offset
        cut_byte = line_byte_starts[line_idx] + len(line[:cut_in_line].encode("utf-8"))
        end_byte = line_byte_starts[line_idx] + len(byte_lines[line_idx])
        if tree:
            node = _find_deepest_containing(tree, cut_byte, cut_byte + 1)
            if node and node.end_byte > cut_byte:
                node_lines = source_bytes[cut_byte:node.end_byte].count(b"\n") + 1
                if node_lines > max_middle_lines:
                    end_byte = _truncate_node_to_statements(
                        node, source_bytes, max_middle_lines,
                    )
                else:
                    end_byte = node.end_byte

        if end_byte - cut_byte < 3:
            continue

        end_line = source_bytes[:end_byte].count(b"\n")
        spans.append(CodeSpan(
            kind="dev_incomplete_line",
            start_line=line_idx,
            end_line=end_line,
            start_byte=cut_byte,
            end_byte=end_byte,
        ))

    return spans


def generate_bracket_context_spans(
    source: str, tree: "Node | None" = None, lang_config=None
) -> list[CodeSpan]:
    """
    Generate spans for bracket/paren content (~5% of spans).
    Simulates IDE inserting matching brackets and developer filling in.
    """
    lc = _resolve_lang_config(lang_config)
    spans = []
    if not tree:
        return spans

    bracket_types = lc.ast_bracket_types

    bracket_nodes = []

    def _collect_bracket_nodes(node: "Node"):
        if node.type in bracket_types and node.child_count >= 2:
            inner_size = node.end_byte - node.start_byte
            if 3 < inner_size < 2000:
                bracket_nodes.append(node)
        for child in node.children:
            _collect_bracket_nodes(child)

    _collect_bracket_nodes(tree)
    if not bracket_nodes:
        return spans

    target_count = max(1, len(source.split("\n")) // 40)
    chosen = random.sample(bracket_nodes, min(target_count, len(bracket_nodes)))
    source_bytes = source.encode("utf-8")

    for node in chosen:
        first = node.children[0]
        last = node.children[-1]
        inner_start = first.end_byte
        inner_end = last.start_byte

        if inner_end - inner_start < 2:
            continue

        start_line = source_bytes[:inner_start].count(b"\n")
        end_line = source_bytes[:inner_end].count(b"\n")
        spans.append(CodeSpan(
            kind="dev_bracket_content",
            start_line=start_line,
            end_line=end_line,
            start_byte=inner_start,
            end_byte=inner_end,
        ))

    return spans


def generate_post_comment_spans(
    source: str, tree: "Node | None" = None, lang_config=None,
    max_middle_lines: int = 30,
) -> list[CodeSpan]:
    """
    Generate spans where middle = statement after a full-line comment (~3%).
    Teaches model to implement code from comment descriptions.

    For large nodes (e.g. a comment above a 200-line function), the span is
    truncated to the first N statements of the node body rather than masking
    the entire thing.
    """
    spans = []
    if not tree:
        return spans

    source_bytes = source.encode("utf-8")

    def _collect_comment_spans(node: "Node"):
        for i, child in enumerate(node.children):
            if child.type == "comment":
                comment_text = source_bytes[child.start_byte:child.end_byte].decode("utf-8", errors="replace")
                if comment_text.strip().startswith("//") or comment_text.strip().startswith("/*"):
                    if i + 1 < len(node.children):
                        next_sib = node.children[i + 1]
                        if next_sib.type != "comment" and next_sib.end_byte - next_sib.start_byte > 5:
                            start_line = next_sib.start_point[0]
                            end_byte = next_sib.end_byte
                            sib_lines = next_sib.end_point[0] - start_line + 1
                            if sib_lines > max_middle_lines:
                                end_byte = _truncate_node_to_statements(
                                    next_sib, source_bytes, max_middle_lines,
                                )
                            end_line = source_bytes[:end_byte].count(b"\n")
                            spans.append(CodeSpan(
                                kind="dev_post_comment",
                                start_line=start_line,
                                end_line=end_line,
                                start_byte=next_sib.start_byte,
                                end_byte=end_byte,
                            ))
            if child.child_count > 0:
                _collect_comment_spans(child)

    _collect_comment_spans(tree)

    target_count = max(1, len(source.split("\n")) // 60)
    if len(spans) > target_count:
        spans = random.sample(spans, target_count)

    return spans


def generate_doc_comment_spans(
    source: str, tree: "Node | None" = None, lang_config=None
) -> list[CodeSpan]:
    """
    Generate spans for doc comment completion (~sparse, like bracket spans).
    Two cases: new doc comment (prefix ends with opener) and update (split at @-tag).
    """
    lc = _resolve_lang_config(lang_config)
    spans = []
    if not tree:
        return spans

    openers = lc.doc_comment_openers
    if not openers:
        return spans

    source_bytes = source.encode("utf-8")
    func_types = lc.ast_function_types

    # Special handling for Python docstrings
    is_python = lc.name == "python"

    doc_nodes = []

    def _collect_doc_nodes(node: "Node"):
        if is_python:
            # Python docstrings: expression_statement > string as first child of a block inside function_definition
            if node.type == "expression_statement" and node.parent and node.parent.type == "block":
                grandparent = node.parent.parent
                if grandparent and grandparent.type in func_types:
                    # Must be the first statement in the block
                    block = node.parent
                    first_stmt = None
                    for child in block.children:
                        if child.type not in (":", "NEWLINE", "INDENT", "DEDENT", "comment"):
                            first_stmt = child
                            break
                    if first_stmt and first_stmt.id == node.id:
                        text = source_bytes[node.start_byte:node.end_byte].decode("utf-8", errors="replace").strip()
                        if any(text.startswith(op) for op in openers):
                            doc_nodes.append((node, grandparent))
        else:
            # C-family / block comment languages: comment node followed by function sibling
            if node.type == "comment" and node.parent:
                text = source_bytes[node.start_byte:node.end_byte].decode("utf-8", errors="replace").strip()
                if any(text.startswith(op) for op in openers):
                    # Find next sibling that is a function
                    siblings = node.parent.children
                    idx = None
                    for i, sib in enumerate(siblings):
                        if sib.id == node.id:
                            idx = i
                            break
                    if idx is not None:
                        for j in range(idx + 1, len(siblings)):
                            next_sib = siblings[j]
                            if next_sib.type in func_types:
                                doc_nodes.append((node, next_sib))
                                break
                            if next_sib.type != "comment":
                                break

        for child in node.children:
            _collect_doc_nodes(child)

    _collect_doc_nodes(tree)

    if not doc_nodes:
        return spans

    target_count = max(1, len(source.split("\n")) // 40)
    chosen = random.sample(doc_nodes, min(target_count, len(doc_nodes)))

    for doc_node, func_node in chosen:
        doc_text = source_bytes[doc_node.start_byte:doc_node.end_byte].decode("utf-8", errors="replace")
        doc_lines = doc_text.split("\n")

        # Decide Case A (new doc) vs Case B (update doc)
        # Find @-tag line indices for Case B
        tag_line_indices = []
        for i, line in enumerate(doc_lines):
            if i == 0:
                continue  # skip opener line
            if re.search(r"@\w+", line):
                tag_line_indices.append(i)

        use_case_b = tag_line_indices and random.random() < 0.4

        if use_case_b:
            # Case B: split at a random @-tag boundary
            split_line_idx = random.choice(tag_line_indices)
            prefix_lines = doc_lines[:split_line_idx]
            prefix_len = sum(len(l.encode("utf-8")) + 1 for l in prefix_lines)  # +1 for \n
            start_byte = doc_node.start_byte + prefix_len
        else:
            # Case A: new doc comment — start after the opener line
            first_line = doc_lines[0]
            start_byte = doc_node.start_byte + len(first_line.encode("utf-8")) + 1  # +1 for \n

        end_byte = doc_node.end_byte

        if end_byte <= start_byte:
            continue

        start_line = source_bytes[:start_byte].count(b"\n")
        end_line = source_bytes[:end_byte].count(b"\n")
        spans.append(CodeSpan(
            kind="dev_doc_comment",
            start_line=start_line,
            end_line=end_line,
            start_byte=start_byte,
            end_byte=end_byte,
            skip_quality_filters=frozenset({"comment_only"}),
        ))

    return spans
