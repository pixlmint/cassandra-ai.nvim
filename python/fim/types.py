from dataclasses import dataclass, field, asdict

CHARS_PER_TOKEN = 3  # Empirically ~2.5-3.5 for code tokenizers (Qwen2.5-Coder, etc.)


@dataclass
class FIMConfig:
    """FIM special tokens per base model family."""
    prefix_tok: str
    suffix_tok: str
    middle_tok: str
    eot_tok: str = "<|endoftext|>"

    # PSM = prefix-suffix-middle (the standard FIM training order)
    def format_psm(self, prefix: str, middle: str, suffix: str) -> str:
        """Format a training example in PSM order (most common for training)."""
        return (
            f"{self.prefix_tok}{prefix}"
            f"{self.suffix_tok}{suffix}"
            f"{self.middle_tok}{middle}"
            f"{self.eot_tok}"
        )


FIM_CONFIGS = {
    "qwen2.5-coder": FIMConfig(
        prefix_tok="<|fim_prefix|>",
        suffix_tok="<|fim_suffix|>",
        middle_tok="<|fim_middle|>",
        eot_tok="<|endoftext|>",
    ),
    "granite-code": FIMConfig(
        prefix_tok="<fim_prefix>",
        suffix_tok="<fim_suffix>",
        middle_tok="<fim_middle>",
        eot_tok="<|endoftext|>",
    ),
    "codellama": FIMConfig(
        prefix_tok="<PRE>",
        suffix_tok="<SUF>",
        middle_tok="<MID>",
        eot_tok="</s>",
    ),
    "starcoder": FIMConfig(
        prefix_tok="<fim_prefix>",
        suffix_tok="<fim_suffix>",
        middle_tok="<fim_middle>",
        eot_tok="<|endoftext|>",
    ),
}


@dataclass
class CodeSpan:
    """A span of code that can be used as a FIM middle section."""
    kind: str          # "function", "method", "block", "expression", "line"
    start_line: int    # 0-indexed
    end_line: int      # 0-indexed, inclusive
    name: str = ""     # function/method name if applicable
    indent: int = 0    # indentation level
    start_byte: int = -1  # byte offset (when set, used instead of line numbers)
    end_byte: int = -1    # byte offset (when set, used instead of line numbers)
    skip_quality_filters: frozenset[str] = field(default_factory=frozenset)


@dataclass
class FIMExample:
    """A single FIM training example."""
    filepath: str
    span_kind: str
    span_name: str
    prefix: str
    middle: str
    suffix: str
    cross_file_context: str = ""

    # Metadata for analysis
    complexity_score: float = 0.0
    middle_lines: int = 0
    total_lines: int = 0

    # Quality filter exclusions — set of check names to skip
    # Valid names: "repetition", "entropy", "comment_only", "length_ratio"
    skip_quality_filters: frozenset[str] = field(default_factory=frozenset)

    def truncate_to_token_budget(self, fim_config: FIMConfig, max_seq_len: int, tokenizer=None) -> 'FIMExample':
        """Return a copy truncated so the formatted output fits within max_seq_len tokens.

        Middle is sacrosanct — never trimmed. Cross-file context is removed first
        (least-local), then prefix is trimmed from the left, suffix from the right.

        When tokenizer is provided, uses real token counts instead of the
        CHARS_PER_TOKEN character-length heuristic.
        """
        if tokenizer is not None:
            return self._truncate_with_tokenizer(fim_config, max_seq_len, tokenizer)

        special_tokens_chars = sum(len(t) for t in (fim_config.prefix_tok, fim_config.suffix_tok, fim_config.middle_tok, fim_config.eot_tok))
        char_budget = max_seq_len * CHARS_PER_TOKEN - special_tokens_chars
        middle_chars = len(self.middle)

        # If middle alone exceeds the budget, return as-is (nothing we can do)
        if middle_chars >= char_budget:
            return FIMExample(
                filepath=self.filepath, span_kind=self.span_kind, span_name=self.span_name,
                prefix='', middle=self.middle, suffix='', cross_file_context='',
                complexity_score=self.complexity_score, middle_lines=self.middle_lines,
                total_lines=self.total_lines, skip_quality_filters=self.skip_quality_filters,
            )

        remaining = char_budget - middle_chars
        full_prefix = self.cross_file_context + self.prefix
        full_suffix = self.suffix

        total_context = len(full_prefix) + len(full_suffix)
        if total_context <= remaining:
            return self  # Already fits

        # Allocate remaining budget proportionally between prefix and suffix
        if total_context > 0:
            prefix_budget = int(remaining * len(full_prefix) / total_context)
            suffix_budget = remaining - prefix_budget
        else:
            prefix_budget = remaining // 2
            suffix_budget = remaining - prefix_budget

        # Trim prefix from the left (keeps code nearest to the cursor)
        if len(full_prefix) > prefix_budget:
            full_prefix = full_prefix[len(full_prefix) - prefix_budget:]

        # Trim suffix from the right (keeps code nearest to the cursor)
        if len(full_suffix) > suffix_budget:
            full_suffix = full_suffix[:suffix_budget]

        # Separate cross-file context back out: if full_prefix still starts with
        # cross-file content, preserve the split; otherwise it's all local prefix
        cross_file = ''
        prefix = full_prefix
        if self.cross_file_context and len(full_prefix) > len(self.prefix):
            # Some cross-file context survived
            cross_file = full_prefix[:len(full_prefix) - len(self.prefix)]
            prefix = self.prefix
        elif self.cross_file_context and len(full_prefix) <= len(self.prefix):
            # Cross-file context was fully trimmed
            cross_file = ''
            prefix = full_prefix

        return FIMExample(
            filepath=self.filepath, span_kind=self.span_kind, span_name=self.span_name,
            prefix=prefix, middle=self.middle, suffix=full_suffix, cross_file_context=cross_file,
            complexity_score=self.complexity_score, middle_lines=self.middle_lines,
            total_lines=self.total_lines, skip_quality_filters=self.skip_quality_filters,
        )

    def _truncate_with_tokenizer(self, fim_config: FIMConfig, max_seq_len: int, tokenizer) -> 'FIMExample':
        """Token-accurate truncation using a real tokenizer."""
        encode = lambda s: tokenizer.encode(s, add_special_tokens=False)

        # Each FIM special token is 1 token ID in the vocabulary
        special_token_count = 4  # prefix_tok, suffix_tok, middle_tok, eot_tok

        middle_tokens = len(encode(self.middle))

        # If middle + special tokens alone exceed budget, return degenerate
        if middle_tokens + special_token_count >= max_seq_len:
            return FIMExample(
                filepath=self.filepath, span_kind=self.span_kind, span_name=self.span_name,
                prefix='', middle=self.middle, suffix='', cross_file_context='',
                complexity_score=self.complexity_score, middle_lines=self.middle_lines,
                total_lines=self.total_lines, skip_quality_filters=self.skip_quality_filters,
            )

        remaining_budget = max_seq_len - special_token_count - middle_tokens

        full_prefix = self.cross_file_context + self.prefix
        full_suffix = self.suffix

        prefix_tokens = len(encode(full_prefix)) if full_prefix else 0
        suffix_tokens = len(encode(full_suffix)) if full_suffix else 0
        total_context_tokens = prefix_tokens + suffix_tokens

        if total_context_tokens <= remaining_budget:
            return self  # Already fits

        # Allocate budget proportionally
        if total_context_tokens > 0:
            prefix_token_budget = int(remaining_budget * prefix_tokens / total_context_tokens)
            suffix_token_budget = remaining_budget - prefix_token_budget
        else:
            prefix_token_budget = remaining_budget // 2
            suffix_token_budget = remaining_budget - prefix_token_budget

        # Iterative trim: estimate chars to cut, re-encode to verify (max 4 rounds)
        for _ in range(4):
            if prefix_tokens > prefix_token_budget and full_prefix:
                overflow = prefix_tokens - prefix_token_budget
                cpt = len(full_prefix) / prefix_tokens if prefix_tokens > 0 else 1
                chars_to_cut = max(1, int(overflow * cpt))
                full_prefix = full_prefix[chars_to_cut:]
                prefix_tokens = len(encode(full_prefix)) if full_prefix else 0

            if suffix_tokens > suffix_token_budget and full_suffix:
                overflow = suffix_tokens - suffix_token_budget
                cpt = len(full_suffix) / suffix_tokens if suffix_tokens > 0 else 1
                chars_to_cut = max(1, int(overflow * cpt))
                full_suffix = full_suffix[:len(full_suffix) - chars_to_cut]
                suffix_tokens = len(encode(full_suffix)) if full_suffix else 0

            if prefix_tokens + suffix_tokens <= remaining_budget:
                break

        # Separate cross-file context back out
        cross_file = ''
        prefix = full_prefix
        if self.cross_file_context and len(full_prefix) > len(self.prefix):
            cross_file = full_prefix[:len(full_prefix) - len(self.prefix)]
            prefix = self.prefix
        elif self.cross_file_context and len(full_prefix) <= len(self.prefix):
            cross_file = ''
            prefix = full_prefix

        return FIMExample(
            filepath=self.filepath, span_kind=self.span_kind, span_name=self.span_name,
            prefix=prefix, middle=self.middle, suffix=full_suffix, cross_file_context=cross_file,
            complexity_score=self.complexity_score, middle_lines=self.middle_lines,
            total_lines=self.total_lines, skip_quality_filters=self.skip_quality_filters,
        )

    def to_training_format(self, fim_config: FIMConfig, max_seq_len: int = 0, tokenizer=None) -> dict:
        """Convert to the JSONL format expected by training frameworks.

        When max_seq_len > 0, truncates prefix/suffix to fit within the token budget
        (middle is never truncated). When tokenizer is provided, uses real token
        counts instead of the CHARS_PER_TOKEN heuristic.
        """
        ex = self.truncate_to_token_budget(fim_config, max_seq_len, tokenizer=tokenizer) if max_seq_len > 0 else self
        full_prefix = ex.cross_file_context + ex.prefix
        formatted = fim_config.format_psm(full_prefix, ex.middle, ex.suffix)
        return {
            "text": formatted,
            # Also include structured version for frameworks that want it
            "prefix": full_prefix,
            "middle": ex.middle,
            "suffix": ex.suffix,
            # Metadata
            "filepath": ex.filepath,
            "span_kind": ex.span_kind,
            "span_name": ex.span_name,
            "middle_lines": ex.middle_lines,
            "complexity_score": ex.complexity_score,
        }


@dataclass
class BM25Index:
    """Pre-built BM25 index over code chunks from the entire repo."""
    bm25: object  # BM25Okapi instance
    chunks: list[str]           # the actual text chunks
    chunk_files: list[str]      # source filepath for each chunk


MIN_MIDDLE_WORDS = 3  # Minimum whitespace-delimited words in middle section
