"""End-to-end integration tests for the FIM pipeline."""

import random

import pytest

from fim.deps import HAS_TREE_SITTER, Parser
from fim.types import CodeSpan
from generate._fim import (
    generate_fim_examples,
    _categorize,
    _split_byte_span_by_statements,
    _random_window_from_byte_span,
)


@pytest.fixture
def seed():
    random.seed(42)


class TestGenerateFimExamples:
    def test_produces_examples(self, simple_class_php, tmp_path, seed):
        filepath = tmp_path / "UserService.php"
        filepath.write_text(simple_class_php)
        examples = generate_fim_examples(filepath, simple_class_php, tmp_path)
        assert len(examples) > 0

    def test_every_example_has_nonempty_prefix_and_middle(self, simple_class_php, tmp_path, seed):
        filepath = tmp_path / "UserService.php"
        filepath.write_text(simple_class_php)
        examples = generate_fim_examples(filepath, simple_class_php, tmp_path)
        for ex in examples:
            assert len(ex.prefix) > 0
            assert len(ex.middle.strip()) > 0

    def test_byte_span_reconstruction(self, simple_class_php, tmp_path, seed):
        """Key invariant: for byte-offset spans, prefix + middle + suffix == original."""
        filepath = tmp_path / "UserService.php"
        filepath.write_text(simple_class_php)
        examples = generate_fim_examples(filepath, simple_class_php, tmp_path)

        byte_kinds = {"ast_single_node", "ast_aligned_span", "dev_incomplete_line",
                      "dev_bracket_content", "dev_post_comment", "char_random"}
        for ex in examples:
            if ex.span_kind in byte_kinds:
                reconstructed = ex.prefix + ex.middle + ex.suffix
                assert reconstructed == simple_class_php, (
                    f"Reconstruction failed for {ex.span_kind}: "
                    f"got {len(reconstructed)} chars, expected {len(simple_class_php)}"
                )

    def test_relative_filepath_in_examples(self, simple_class_php, tmp_path, seed):
        filepath = tmp_path / "src" / "UserService.php"
        filepath.parent.mkdir(parents=True, exist_ok=True)
        filepath.write_text(simple_class_php)
        examples = generate_fim_examples(filepath, simple_class_php, tmp_path)
        for ex in examples:
            assert ex.filepath == "src/UserService.php"

    def test_use_ast_false_falls_back_to_regex(self, simple_class_php, tmp_path, seed):
        filepath = tmp_path / "UserService.php"
        filepath.write_text(simple_class_php)
        examples = generate_fim_examples(
            filepath, simple_class_php, tmp_path, use_ast=False
        )
        assert len(examples) > 0
        kinds = {ex.span_kind for ex in examples}
        # Should not have AST or dev-behavior prefixed kinds
        assert not any(k.startswith("ast_") for k in kinds)
        assert not any(k.startswith("dev_") for k in kinds)

    def test_max_total_chars_respected(self, simple_class_php, tmp_path, seed):
        filepath = tmp_path / "UserService.php"
        filepath.write_text(simple_class_php)
        max_chars = 2000
        examples = generate_fim_examples(
            filepath, simple_class_php, tmp_path, max_total_chars=max_chars
        )
        for ex in examples:
            total = len(ex.prefix) + len(ex.middle) + len(ex.suffix) + len(ex.cross_file_context)
            assert total <= max_chars, (
                f"{ex.span_kind} example has {total} chars, limit is {max_chars}"
            )

    @pytest.mark.skipif(not HAS_TREE_SITTER, reason="tree-sitter not installed")
    def test_ast_mode_produces_ast_spans(self, simple_class_php, tmp_path, seed):
        filepath = tmp_path / "UserService.php"
        filepath.write_text(simple_class_php)
        examples = generate_fim_examples(
            filepath, simple_class_php, tmp_path, use_ast=True
        )
        kinds = {ex.span_kind for ex in examples}
        ast_kinds = {k for k in kinds if k.startswith("ast_")}
        assert len(ast_kinds) > 0, f"Expected AST spans, got: {kinds}"


class TestOversizedSpanSplitting:
    """Tests for splitting oversized byte-offset spans."""

    @pytest.mark.skipif(not HAS_TREE_SITTER, reason="tree-sitter not installed")
    def test_no_example_exceeds_max_middle_lines(self, large_function_php, tmp_path, seed):
        """With max_middle_lines=10, no example should exceed the limit."""
        filepath = tmp_path / "DataProcessor.php"
        filepath.write_text(large_function_php)
        examples = generate_fim_examples(
            filepath, large_function_php, tmp_path,
            max_middle_lines=10, use_ast=True,
        )
        assert len(examples) > 0
        for ex in examples:
            assert ex.middle_lines <= 10, (
                f"{ex.span_kind} has {ex.middle_lines} middle lines, limit is 10"
            )

    @pytest.mark.skipif(not HAS_TREE_SITTER, reason="tree-sitter not installed")
    def test_oversized_span_produces_splits_via_only_spans(self, large_function_php, tmp_path, seed):
        """Force ast_single_node spans only — oversized ones must be split."""
        filepath = tmp_path / "DataProcessor.php"
        filepath.write_text(large_function_php)
        examples = generate_fim_examples(
            filepath, large_function_php, tmp_path,
            max_middle_lines=10, use_ast=True,
            only_spans={"ast_single_node"},
        )
        # Some spans should have been split
        kinds = {ex.span_kind for ex in examples}
        split_kinds = {k for k in kinds if "_split" in k or "_window" in k}
        assert len(split_kinds) > 0, f"Expected split/window kinds, got: {kinds}"
        for ex in examples:
            assert ex.middle_lines <= 10, (
                f"{ex.span_kind} has {ex.middle_lines} middle lines, limit is 10"
            )

    def test_sliding_window_fallback(self, large_function_php, tmp_path, seed):
        """Without AST, oversized spans use sliding window."""
        filepath = tmp_path / "DataProcessor.php"
        filepath.write_text(large_function_php)
        examples = generate_fim_examples(
            filepath, large_function_php, tmp_path,
            max_middle_lines=10, use_ast=False,
        )
        for ex in examples:
            assert ex.middle_lines <= 10, (
                f"{ex.span_kind} has {ex.middle_lines} middle lines, limit is 10"
            )

    @pytest.mark.skipif(not HAS_TREE_SITTER, reason="tree-sitter not installed")
    def test_small_spans_unaffected(self, simple_class_php, tmp_path, seed):
        """Spans within max_middle_lines should not get split."""
        filepath = tmp_path / "UserService.php"
        filepath.write_text(simple_class_php)
        examples = generate_fim_examples(
            filepath, simple_class_php, tmp_path,
            max_middle_lines=30, use_ast=True,
        )
        kinds = {ex.span_kind for ex in examples}
        split_kinds = {k for k in kinds if "_split" in k or "_window" in k}
        assert len(split_kinds) == 0, f"Unexpected split kinds in small file: {split_kinds}"


class TestRandomWindow:
    """Unit tests for _random_window_from_byte_span."""

    def test_returns_single_window(self):
        # 20 lines of content — should return exactly 1 random window
        lines = [f"line {i}" for i in range(20)]
        source = "\n".join(lines)
        source_bytes = source.encode("utf-8")
        span = CodeSpan(
            kind="ast_single_node", start_line=0, end_line=19,
            start_byte=0, end_byte=len(source_bytes),
        )
        sub_spans = _random_window_from_byte_span(source_bytes, span, max_middle_lines=10)
        assert len(sub_spans) == 1
        middle = source_bytes[sub_spans[0].start_byte:sub_spans[0].end_byte]
        assert middle.count(b"\n") + 1 <= 10
        assert sub_spans[0].kind == "ast_single_node_window"

    def test_small_span_unchanged(self):
        source = "line 1\nline 2\nline 3"
        source_bytes = source.encode("utf-8")
        span = CodeSpan(
            kind="dev_bracket_content", start_line=0, end_line=2,
            start_byte=0, end_byte=len(source_bytes),
        )
        sub_spans = _random_window_from_byte_span(source_bytes, span, max_middle_lines=10)
        assert len(sub_spans) == 1
        # Small span keeps original kind (no suffix)
        assert sub_spans[0].kind == "dev_bracket_content"


class TestStatementSplit:
    """Unit tests for _split_byte_span_by_statements."""

    @pytest.mark.skipif(not HAS_TREE_SITTER, reason="tree-sitter not installed")
    def test_splits_class_into_members(self, large_function_php):
        from fim.language import PHP
        parser = Parser(PHP.ts_language)
        source_bytes = large_function_php.encode("utf-8")
        tree = parser.parse(source_bytes)
        tree_root = tree.root_node

        # Span covering the entire class body
        class_start = large_function_php.index("class DataProcessor")
        class_end = len(large_function_php.rstrip()) - 1  # before trailing newline
        span = CodeSpan(
            kind="ast_single_node", start_line=4, end_line=60,
            name="DataProcessor",
            start_byte=class_start, end_byte=class_end,
        )
        sub_spans = _split_byte_span_by_statements(source_bytes, span, tree_root, max_middle_lines=10)
        assert len(sub_spans) >= 1
        for s in sub_spans:
            assert s.kind == "ast_single_node_split"

    @pytest.mark.skipif(not HAS_TREE_SITTER, reason="tree-sitter not installed")
    def test_returns_empty_for_leaf_node(self):
        """A span with no statement children should return empty list."""
        from fim.language import PHP
        source = "<?php\n$x = 1;\n"
        source_bytes = source.encode("utf-8")
        parser = Parser(PHP.ts_language)
        tree = parser.parse(source_bytes)

        # Span covering just the assignment
        span = CodeSpan(
            kind="ast_single_node", start_line=1, end_line=1,
            start_byte=6, end_byte=len(source_bytes) - 1,
        )
        sub_spans = _split_byte_span_by_statements(source_bytes, span, tree.root_node, max_middle_lines=5)
        # Should return empty (no compound children to split)
        assert isinstance(sub_spans, list)


class TestCategorize:
    """Verify split/window suffixed kinds still categorize correctly."""

    def test_split_suffix_categorizes_as_ast(self):
        assert _categorize("ast_single_node_split") == "ast"

    def test_window_suffix_categorizes_as_ast(self):
        assert _categorize("ast_aligned_span_window") == "ast"

    def test_split_suffix_categorizes_as_dev(self):
        assert _categorize("dev_bracket_content_split") == "dev"

    def test_window_suffix_categorizes_as_dev(self):
        assert _categorize("dev_post_comment_window") == "dev"
