#!/usr/bin/env python3
"""Validate a generated FIM dataset for common issues that cause garbage model output."""

import json
import sys
import re
from collections import Counter
from pathlib import Path

# Qwen2.5-Coder FIM tokens
FIM_PREFIX = "<|fim_prefix|>"
FIM_SUFFIX = "<|fim_suffix|>"
FIM_MIDDLE = "<|fim_middle|>"
EOT = "<|endoftext|>"

def validate_file(path: Path, max_examples: int = 0):
    issues = Counter()
    total = 0
    middle_lens = []
    prefix_lens = []
    suffix_lens = []
    text_lens = []
    span_kinds = Counter()

    with open(path) as f:
        for line_no, line in enumerate(f, 1):
            if max_examples and total >= max_examples:
                break
            total += 1
            try:
                ex = json.loads(line)
            except json.JSONDecodeError:
                issues["json_parse_error"] += 1
                continue

            text = ex.get("text", "")
            middle = ex.get("middle", "")
            prefix = ex.get("prefix", "")
            suffix = ex.get("suffix", "")
            span_kind = ex.get("span_kind", "unknown")
            span_kinds[span_kind] += 1

            middle_lens.append(len(middle))
            prefix_lens.append(len(prefix))
            suffix_lens.append(len(suffix))
            text_lens.append(len(text))

            # Check 1: All 4 special tokens present in text
            for tok_name, tok in [("fim_prefix", FIM_PREFIX), ("fim_suffix", FIM_SUFFIX),
                                   ("fim_middle", FIM_MIDDLE), ("eot", EOT)]:
                if tok not in text:
                    issues[f"missing_{tok_name}"] += 1
                    if issues[f"missing_{tok_name}"] <= 3:
                        print(f"  Line {line_no}: missing {tok_name} in text field")

            # Check 2: Correct token order (PSM format)
            positions = {}
            for tok_name, tok in [("P", FIM_PREFIX), ("S", FIM_SUFFIX), ("M", FIM_MIDDLE), ("E", EOT)]:
                pos = text.find(tok)
                if pos >= 0:
                    positions[tok_name] = pos
            if len(positions) == 4:
                order = sorted(positions, key=positions.get)
                expected = ["P", "S", "M", "E"]
                if order != expected:
                    issues["wrong_token_order"] += 1
                    if issues["wrong_token_order"] <= 3:
                        print(f"  Line {line_no}: wrong token order: {''.join(order)} (expected PSME)")

            # Check 3: text field matches format_psm(prefix, middle, suffix)
            expected_text = f"{FIM_PREFIX}{prefix}{FIM_SUFFIX}{suffix}{FIM_MIDDLE}{middle}{EOT}"
            if text != expected_text:
                issues["text_mismatch"] += 1
                if issues["text_mismatch"] <= 3:
                    # Find where they differ
                    for i, (a, b) in enumerate(zip(text, expected_text)):
                        if a != b:
                            print(f"  Line {line_no}: text mismatch at char {i}: "
                                  f"got {repr(text[max(0,i-20):i+20])}")
                            break
                    else:
                        if len(text) != len(expected_text):
                            print(f"  Line {line_no}: text length mismatch: "
                                  f"{len(text)} vs {len(expected_text)}")

            # Check 4: Empty/trivial middle
            if not middle.strip():
                issues["empty_middle"] += 1
            elif len(middle.strip()) < 5:
                issues["trivial_middle"] += 1

            # Check 5: Middle contains special FIM tokens (corruption)
            for tok in [FIM_PREFIX, FIM_SUFFIX, FIM_MIDDLE, EOT]:
                if tok in middle:
                    issues["special_tok_in_middle"] += 1
                    if issues["special_tok_in_middle"] <= 3:
                        print(f"  Line {line_no}: special token {tok} found inside middle!")
                    break

            # Check 6: Prefix contains special FIM tokens (corruption)
            for tok in [FIM_PREFIX, FIM_SUFFIX, FIM_MIDDLE, EOT]:
                if tok in prefix:
                    issues["special_tok_in_prefix"] += 1
                    if issues["special_tok_in_prefix"] <= 3:
                        print(f"  Line {line_no}: special token {tok} found inside prefix!")
                    break

            # Check 7: Replacement chars (bad UTF-8 decoding)
            if "\ufffd" in middle or "\ufffd" in prefix or "\ufffd" in suffix:
                issues["replacement_chars"] += 1
                if issues["replacement_chars"] <= 3:
                    print(f"  Line {line_no}: contains U+FFFD replacement character")

            # Check 8: EOT not at end of text
            if text and not text.endswith(EOT):
                issues["eot_not_at_end"] += 1
                if issues["eot_not_at_end"] <= 3:
                    print(f"  Line {line_no}: text doesn't end with EOT, ends with: {repr(text[-30:])}")

            # Check 9: Multiple occurrences of special tokens
            for tok_name, tok in [("fim_prefix", FIM_PREFIX), ("fim_suffix", FIM_SUFFIX),
                                   ("fim_middle", FIM_MIDDLE), ("eot", EOT)]:
                count = text.count(tok)
                if count > 1:
                    issues[f"duplicate_{tok_name}"] += 1
                    if issues[f"duplicate_{tok_name}"] <= 3:
                        print(f"  Line {line_no}: {tok_name} appears {count} times in text")

    # Summary
    print(f"\n{'='*60}")
    print(f"Dataset: {path}")
    print(f"Total examples: {total}")
    print(f"\nSpan kinds:")
    for kind, count in span_kinds.most_common():
        print(f"  {kind}: {count} ({100*count/total:.1f}%)")

    print(f"\nMiddle length: min={min(middle_lens)}, max={max(middle_lens)}, "
          f"mean={sum(middle_lens)/len(middle_lens):.0f}, "
          f"median={sorted(middle_lens)[len(middle_lens)//2]}")
    print(f"Prefix length: min={min(prefix_lens)}, max={max(prefix_lens)}, "
          f"mean={sum(prefix_lens)/len(prefix_lens):.0f}")
    print(f"Suffix length: min={min(suffix_lens)}, max={max(suffix_lens)}, "
          f"mean={sum(suffix_lens)/len(suffix_lens):.0f}")
    print(f"Text length:   min={min(text_lens)}, max={max(text_lens)}, "
          f"mean={sum(text_lens)/len(text_lens):.0f}")

    # Middle length distribution
    brackets = [0, 10, 20, 40, 100, 200, 500, 1000, 5000, 999999]
    print(f"\nMiddle length distribution:")
    for i in range(len(brackets)-1):
        lo, hi = brackets[i], brackets[i+1]
        count = sum(1 for m in middle_lens if lo <= m < hi)
        if count > 0:
            bar = "#" * (count * 40 // total)
            print(f"  {lo:>5}-{hi:>5}: {count:>5} ({100*count/total:5.1f}%) {bar}")

    if issues:
        print(f"\nISSUES FOUND:")
        for issue, count in issues.most_common():
            pct = 100 * count / total
            severity = "CRITICAL" if pct > 5 else "WARNING" if pct > 1 else "minor"
            print(f"  [{severity}] {issue}: {count} ({pct:.1f}%)")
    else:
        print(f"\nNo issues found - dataset format looks clean.")

    return issues


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print(f"Usage: {sys.argv[0]} <dataset.jsonl> [max_examples]")
        sys.exit(1)

    path = Path(sys.argv[1])
    max_ex = int(sys.argv[2]) if len(sys.argv) > 2 else 0
    issues = validate_file(path, max_ex)
    sys.exit(1 if issues else 0)
