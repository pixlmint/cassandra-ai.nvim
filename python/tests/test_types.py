"""Tests for FIMConfig, FIMExample, and CodeSpan — documents the exact JSONL
format consumed by training frameworks."""

from fim.types import FIM_CONFIGS, CHARS_PER_TOKEN, CodeSpan
from tests.conftest import make_example


class TestFIMConfig:
    def test_format_psm_qwen(self, qwen_config):
        result = qwen_config.format_psm("PRE", "MID", "SUF")
        assert result == (
            "<|fim_prefix|>PRE"
            "<|fim_suffix|>SUF"
            "<|fim_middle|>MID"
            "<|endoftext|>"
        )

    def test_format_psm_codellama(self, codellama_config):
        result = codellama_config.format_psm("PRE", "MID", "SUF")
        assert result == "<PRE>PRE<SUF>SUF<MID>MID</s>"

    def test_psm_order_prefix_before_suffix_before_middle(self, qwen_config):
        """PSM = prefix-suffix-middle ordering in the output string."""
        result = qwen_config.format_psm("AAA", "CCC", "BBB")
        assert result.index("AAA") < result.index("BBB") < result.index("CCC")

    def test_all_configs_have_required_tokens(self):
        for name, cfg in FIM_CONFIGS.items():
            assert cfg.prefix_tok, f"{name} missing prefix_tok"
            assert cfg.suffix_tok, f"{name} missing suffix_tok"
            assert cfg.middle_tok, f"{name} missing middle_tok"
            assert cfg.eot_tok, f"{name} missing eot_tok"


class TestFIMExample:
    def test_to_training_format_structure(self, qwen_config):
        ex = make_example()
        result = ex.to_training_format(qwen_config)

        assert "text" in result
        assert "prefix" in result
        assert "middle" in result
        assert "suffix" in result
        assert "filepath" in result
        assert "span_kind" in result
        assert "span_name" in result
        assert "middle_lines" in result
        assert "complexity_score" in result

    def test_to_training_format_text_is_psm(self, qwen_config):
        ex = make_example(prefix="P", middle="M", suffix="S")
        result = ex.to_training_format(qwen_config)
        expected = qwen_config.format_psm("P", "M", "S")
        assert result["text"] == expected

    def test_cross_file_context_prepended_to_prefix(self, qwen_config):
        ctx = "// --- Dep.php ---\nclass Dep { ... }\n\n"
        ex = make_example(prefix="<?php\n", cross_file_context=ctx)
        result = ex.to_training_format(qwen_config)
        assert result["prefix"] == ctx + "<?php\n"
        assert result["text"].startswith("<|fim_prefix|>" + ctx)

    def test_middle_between_middle_tok_and_eot(self, qwen_config):
        ex = make_example(middle="return 42;")
        result = ex.to_training_format(qwen_config)
        text = result["text"]
        mid_start = text.index("<|fim_middle|>") + len("<|fim_middle|>")
        mid_end = text.index("<|endoftext|>")
        assert text[mid_start:mid_end] == "return 42;"

    def test_metadata_fields(self):
        ex = make_example(filepath="src/Foo.php", span_kind="block", span_name="loop")
        result = ex.to_training_format(FIM_CONFIGS["qwen2.5-coder"])
        assert result["filepath"] == "src/Foo.php"
        assert result["span_kind"] == "block"
        assert result["span_name"] == "loop"


class TestCodeSpan:
    def test_byte_offset_span(self):
        span = CodeSpan(
            kind="ast_single_node",
            start_line=5,
            end_line=10,
            name="myFunc",
            start_byte=100,
            end_byte=250,
        )
        assert span.start_byte == 100
        assert span.end_byte == 250
        assert span.kind == "ast_single_node"

    def test_line_offset_span(self):
        span = CodeSpan(kind="function_body", start_line=5, end_line=10, name="foo")
        assert span.start_byte == -1
        assert span.end_byte == -1

    def test_char_offset_span(self):
        """char_random spans store char offsets in start_line/end_line."""
        span = CodeSpan(kind="char_random", start_line=42, end_line=142)
        assert span.start_line == 42
        assert span.end_line == 142
        assert span.start_byte == -1


class TestTruncateToTokenBudget:
    """Token-aware truncation: middle is sacrosanct, prefix/suffix trimmed to fit."""

    def test_truncate_preserves_middle(self, qwen_config):
        """Middle section is never modified by truncation."""
        middle = "return $this->repo->findAll();\n"
        ex = make_example(prefix="A" * 5000, middle=middle, suffix="B" * 5000)
        truncated = ex.truncate_to_token_budget(qwen_config, max_seq_len=256)
        assert truncated.middle == middle

    def test_truncate_removes_cross_file_context_first(self, qwen_config):
        """Cross-file context (least local) is trimmed before local prefix."""
        cross = "X" * 3000
        prefix = "Y" * 200
        ex = make_example(prefix=prefix, middle="M", suffix="S", cross_file_context=cross)
        # Budget tight enough to force trimming cross-file but keep local prefix
        truncated = ex.truncate_to_token_budget(qwen_config, max_seq_len=256)
        # Local prefix should survive (it's nearest to cursor)
        assert truncated.prefix == prefix or prefix.endswith(truncated.prefix)
        # Cross-file context should be reduced or eliminated
        assert len(truncated.cross_file_context) < len(cross)

    def test_truncate_noop_when_within_budget(self, qwen_config):
        """Small examples that already fit are returned unchanged."""
        ex = make_example(prefix="pre", middle="mid", suffix="suf")
        truncated = ex.truncate_to_token_budget(qwen_config, max_seq_len=1536)
        assert truncated is ex  # Same object, no copy needed

    def test_truncate_suffix_trimmed_from_right(self, qwen_config):
        """Suffix is trimmed from the right, retaining content nearest to cursor."""
        suffix = "NEAR_CURSOR" + "Z" * 5000
        ex = make_example(prefix="P", middle="M", suffix=suffix)
        truncated = ex.truncate_to_token_budget(qwen_config, max_seq_len=256)
        assert truncated.suffix.startswith("NEAR_CURSOR")
        assert len(truncated.suffix) < len(suffix)

    def test_truncate_prefix_trimmed_from_left(self, qwen_config):
        """Prefix is trimmed from the left, retaining content nearest to cursor."""
        prefix = "Z" * 5000 + "NEAR_CURSOR"
        ex = make_example(prefix=prefix, middle="M", suffix="S")
        truncated = ex.truncate_to_token_budget(qwen_config, max_seq_len=256)
        assert truncated.prefix.endswith("NEAR_CURSOR")
        assert len(truncated.prefix) < len(prefix)

    def test_formatted_output_ends_with_middle_and_eot(self, qwen_config):
        """Critical invariant: formatted text always ends with <middle><eot>."""
        ex = make_example(prefix="A" * 5000, middle="completion_code();", suffix="B" * 5000)
        result = ex.to_training_format(qwen_config, max_seq_len=256)
        text = result["text"]
        expected_tail = f"{qwen_config.middle_tok}completion_code();{qwen_config.eot_tok}"
        assert text.endswith(expected_tail), f"text must end with middle+eot, got: ...{text[-80:]}"
