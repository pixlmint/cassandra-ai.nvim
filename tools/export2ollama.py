#!/usr/bin/env python3
"""
export_to_ollama.py — Merge LoRA adapter into base model, convert to GGUF,
and register with Ollama.

Takes the LoRA output from train_fim_lora.py and produces a ready-to-use
Ollama model.

PREREQUISITES
=============
    # Same env as training, plus llama.cpp for GGUF conversion:
    pip install llama-cpp-python

    # OR clone llama.cpp directly (more reliable for conversion):
    git clone https://github.com/ggerganov/llama.cpp
    cd llama.cpp && make -j

    # Ollama must be running for the final import step.

USAGE
=====
    # Basic: merge + convert + register with Ollama
    python export_to_ollama.py \
        --base-model unsloth/Qwen2.5-Coder-3B \
        --lora-adapter lora-output/lora-adapter \
        --quant q8_0

    # Just merge (skip GGUF conversion)
    python export_to_ollama.py \
        --base-model unsloth/Qwen2.5-Coder-3B \
        --lora-adapter lora-output/lora-adapter \
        --merge-only

    # Custom Ollama model name
    python export_to_ollama.py \
        --base-model unsloth/Qwen2.5-Coder-7B \
        --lora-adapter lora-output/lora-adapter \
        --quant q8_0 \
        --ollama-name mycompany-coder:7b-q8

FULL PIPELINE
=============
    # Option A: unsloth's built-in GGUF export (simplest)
    python export_to_ollama.py \
        --base-model unsloth/Qwen2.5-Coder-3B-bnb-4bit \
        --lora-adapter lora-output/lora-adapter \
        --method unsloth \
        --quant q8_0

    # Option B: manual merge → llama.cpp conversion (most control)
    python export_to_ollama.py \
        --base-model unsloth/Qwen2.5-Coder-3B \
        --lora-adapter lora-output/lora-adapter \
        --method manual \
        --llama-cpp-path /path/to/llama.cpp \
        --quant q8_0
"""

import argparse
import subprocess
import sys
from pathlib import Path


# ---------------------------------------------------------------------------
# Ollama Modelfile template
# ---------------------------------------------------------------------------
MODELFILE_TEMPLATE = """\
FROM {gguf_path}

# FIM template for Qwen2.5-Coder
TEMPLATE \"\"\"{{{{ if .Suffix }}}}<|fim_prefix|>{{{{ .Prompt }}}}<|fim_suffix|>{{{{ .Suffix }}}}<|fim_middle|>
{{{{- else }}}}{{{{ .Prompt }}}}
{{{{- end }}}}\"\"\"

PARAMETER stop "<|endoftext|>"
PARAMETER stop "<|fim_pad|>"
PARAMETER temperature 0

SYSTEM \"\"\"You are a helpful coding assistant.\"\"\"
"""

# Granite-code variant
MODELFILE_GRANITE = """\
FROM {gguf_path}

TEMPLATE \"\"\"{{{{ if .Suffix }}}}<fim_prefix>{{{{ .Prompt }}}}<fim_suffix>{{{{ .Suffix }}}}<fim_middle>
{{{{- else }}}}{{{{ .Prompt }}}}
{{{{- end }}}}\"\"\"

PARAMETER stop "<|endoftext|>"
PARAMETER temperature 0
"""


def detect_model_family(base_model: str) -> str:
    """Detect which model family for Modelfile template selection."""
    lower = base_model.lower()
    if "qwen" in lower:
        return "qwen"
    elif "granite" in lower:
        return "granite"
    elif "codellama" in lower or "code-llama" in lower:
        return "codellama"
    return "qwen"  # default


# ---------------------------------------------------------------------------
# Method A: unsloth native export
# ---------------------------------------------------------------------------
def find_llama_cpp_tools(llama_cpp_path: Path | None) -> tuple[Path | None, Path | None]:
    """Locate convert_hf_to_gguf.py and llama-quantize in a llama.cpp dir."""
    if llama_cpp_path is None:
        return None, None

    llama_cpp_path = llama_cpp_path.expanduser().resolve()

    # convert_hf_to_gguf.py — could be in root or alongside binaries
    converter = None
    for name in ["convert_hf_to_gguf.py"]:
        for candidate in [llama_cpp_path / name, llama_cpp_path / "scripts" / name]:
            if candidate.exists():
                converter = candidate
                break

    # llama-quantize — binary, might have .exe on Windows
    quantizer = None
    for name in ["llama-quantize", "llama-quantize.exe", "quantize", "quantize.exe"]:
        candidate = llama_cpp_path / name
        if candidate.exists():
            quantizer = candidate
            break

    return converter, quantizer


def export_unsloth(base_model: str, lora_path: Path, output_dir: Path,
                   quant: str, max_seq_len: int,
                   llama_cpp_path: Path | None = None) -> Path:
    """Merge LoRA with unsloth, then convert to GGUF with local llama.cpp.

    Pipeline:
      1. unsloth merges LoRA into base → saves f16 safetensors
      2. convert_hf_to_gguf.py → f16 GGUF
      3. llama-quantize → final quantized GGUF (skipped if target is f16)
    """
    try:
        from unsloth import FastLanguageModel
    except ImportError:
        print("ERROR: unsloth not installed.")
        sys.exit(1)

    # ------------------------------------------------------------------
    # Find llama.cpp tools
    # ------------------------------------------------------------------
    converter, quantizer = find_llama_cpp_tools(llama_cpp_path)

    if converter is None and llama_cpp_path is not None:
        # User pointed us at a binary release (no Python scripts).
        # Try to download just the converter script from GitHub.
        print(f"  convert_hf_to_gguf.py not found in {llama_cpp_path}")
        print(f"  Attempting to download it...")
        converter = _download_converter(llama_cpp_path)

    if converter is None:
        print("ERROR: Could not find convert_hf_to_gguf.py")
        print("  Your llama.cpp binary release doesn't include the Python converter.")
        print("  Fix: download it into your llama.cpp directory:")
        print()
        print(f"    cd {llama_cpp_path or '~/.local/bin'}")
        print(f"    curl -LO https://raw.githubusercontent.com/ggerganov/llama.cpp/master/convert_hf_to_gguf.py")
        print(f"    pip install gguf --break-system-packages")
        print()
        print(f"  Then re-run this script.")
        sys.exit(1)

    needs_quantize = quant not in ("f16", "fp16")
    if needs_quantize and quantizer is None:
        print(f"ERROR: llama-quantize not found in {llama_cpp_path}")
        print(f"  Contents: {[p.name for p in llama_cpp_path.iterdir()][:20]}")
        sys.exit(1)

    print(f"  Converter:  {converter}")
    if quantizer:
        print(f"  Quantizer:  {quantizer}")

    # ------------------------------------------------------------------
    # Step 1: Merge LoRA into base model (unsloth)
    # ------------------------------------------------------------------
    merged_dir = output_dir / "merged"
    merged_dir.mkdir(parents=True, exist_ok=True)

    print(f"\n  Loading LoRA adapter: {lora_path}")
    model, tokenizer = FastLanguageModel.from_pretrained(
        model_name=str(lora_path),
        max_seq_length=max_seq_len,
        dtype=None,
        load_in_4bit=True,
    )

    print(f"  Merging LoRA into base model → {merged_dir}")
    model.save_pretrained_merged(
        str(merged_dir),
        tokenizer,
        save_method="merged_16bit",
    )
    print(f"  Merge complete.")

    # ------------------------------------------------------------------
    # Step 2: Convert HF safetensors → f16 GGUF
    # ------------------------------------------------------------------
    gguf_dir = output_dir / "gguf"
    gguf_dir.mkdir(parents=True, exist_ok=True)

    f16_gguf = gguf_dir / "model-f16.gguf"
    print(f"\n  Converting to GGUF (f16)...")

    cmd = [sys.executable, str(converter), str(merged_dir),
           "--outfile", str(f16_gguf), "--outtype", "f16"]
    print(f"  $ {' '.join(cmd)}")
    result = subprocess.run(cmd, capture_output=True, text=True)
    if result.returncode != 0:
        print(f"  FAILED: {result.stderr[-1000:]}")
        sys.exit(1)

    size_mb = f16_gguf.stat().st_size / (1024 * 1024)
    print(f"  f16 GGUF: {f16_gguf} ({size_mb:.0f} MB)")

    if not needs_quantize:
        return f16_gguf

    # ------------------------------------------------------------------
    # Step 3: Quantize f16 GGUF → target quantization
    # ------------------------------------------------------------------
    final_gguf = gguf_dir / f"model-{quant}.gguf"
    print(f"\n  Quantizing f16 → {quant}...")

    # llama-quantize uses uppercase for some quant names
    quant_arg = quant.upper() if quant.startswith("q") else quant
    # But K_M variants need mixed case: Q4_K_M, Q5_K_M, Q8_0
    quant_arg = quant_arg.replace("_K_M", "_K_M")  # already correct after upper

    cmd = [str(quantizer), str(f16_gguf), str(final_gguf), quant_arg]
    print(f"  $ {' '.join(cmd)}")
    result = subprocess.run(cmd, capture_output=True, text=True)
    if result.returncode != 0:
        print(f"  FAILED: {result.stderr[-1000:]}")
        print(f"  (f16 GGUF still available at: {f16_gguf})")
        sys.exit(1)

    size_mb = final_gguf.stat().st_size / (1024 * 1024)
    print(f"  Quantized GGUF: {final_gguf} ({size_mb:.0f} MB)")

    # Clean up f16 intermediate (it's large)
    print(f"  Removing intermediate f16 GGUF...")
    f16_gguf.unlink()

    return final_gguf


def _download_converter(target_dir: Path) -> Path | None:
    """Download convert_hf_to_gguf.py from llama.cpp GitHub."""
    import urllib.request
    url = "https://raw.githubusercontent.com/ggerganov/llama.cpp/master/convert_hf_to_gguf.py"
    dest = target_dir / "convert_hf_to_gguf.py"
    try:
        urllib.request.urlretrieve(url, dest)
        print(f"  Downloaded: {dest}")
        # Also need the gguf Python package
        subprocess.run([sys.executable, "-m", "pip", "install", "gguf", "-q"],
                       capture_output=True)
        return dest
    except Exception as e:
        print(f"  Download failed: {e}")
        return None


# ---------------------------------------------------------------------------
# Method B: manual merge + llama.cpp conversion
# ---------------------------------------------------------------------------
def export_manual(base_model: str, lora_path: Path, output_dir: Path,
                  quant: str, max_seq_len: int, llama_cpp_path: Path | None) -> Path:
    """Merge LoRA into base, save full model, then convert with llama.cpp."""
    print("Using manual merge + llama.cpp conversion...")

    try:
        from unsloth import FastLanguageModel
    except ImportError:
        print("ERROR: unsloth not installed.")
        sys.exit(1)

    # Load LoRA adapter directly — unsloth reads adapter_config.json
    # which contains the base model reference, so it loads both in one step.
    print(f"  Loading LoRA adapter: {lora_path}")
    model, tokenizer = FastLanguageModel.from_pretrained(
        model_name=str(lora_path),
        max_seq_length=max_seq_len,
        dtype=None,
        load_in_4bit=True,
    )

    # Merge LoRA weights into base model
    merged_dir = output_dir / "merged"
    merged_dir.mkdir(parents=True, exist_ok=True)

    print(f"  Merging LoRA into base model...")
    model.save_pretrained_merged(
        str(merged_dir),
        tokenizer,
        save_method="merged_16bit",  # full precision merge
    )
    print(f"  Merged model saved: {merged_dir}")

    # Step 2: Convert to GGUF with llama.cpp
    if llama_cpp_path is None:
        # Try to find llama.cpp in common locations
        candidates = [
            Path.home() / "llama.cpp",
            Path("/opt/llama.cpp"),
            Path("./llama.cpp"),
        ]
        for c in candidates:
            if (c / "convert_hf_to_gguf.py").exists():
                llama_cpp_path = c
                break

    if llama_cpp_path is None or not (llama_cpp_path / "convert_hf_to_gguf.py").exists():
        print()
        print("ERROR: llama.cpp not found. Either:")
        print("  1. Install it:  git clone https://github.com/ggerganov/llama.cpp && cd llama.cpp && make -j")
        print(f"  2. Pass --llama-cpp-path /path/to/llama.cpp")
        print(f"  3. Use --method unsloth instead (auto-downloads llama.cpp)")
        print()
        print(f"  Your merged model is saved at: {merged_dir}")
        print(f"  You can manually convert later with:")
        print(f"    python llama.cpp/convert_hf_to_gguf.py {merged_dir} --outfile model.gguf --outtype {quant}")
        sys.exit(1)

    gguf_dir = output_dir / "gguf"
    gguf_dir.mkdir(parents=True, exist_ok=True)
    gguf_path = gguf_dir / f"model-{quant}.gguf"

    convert_script = llama_cpp_path / "convert_hf_to_gguf.py"
    print(f"  Converting to GGUF ({quant})...")

    cmd = [
        sys.executable, str(convert_script),
        str(merged_dir),
        "--outfile", str(gguf_path),
        "--outtype", quant,
    ]
    result = subprocess.run(cmd, capture_output=True, text=True)
    if result.returncode != 0:
        print(f"  Conversion failed: {result.stderr[-500:]}")
        sys.exit(1)

    size_mb = gguf_path.stat().st_size / (1024 * 1024)
    print(f"  Generated: {gguf_path} ({size_mb:.0f} MB)")
    return gguf_path


# ---------------------------------------------------------------------------
# Register with Ollama
# ---------------------------------------------------------------------------
def register_ollama(gguf_path: Path, model_name: str, model_family: str):
    """Create an Ollama Modelfile and register the model."""
    print(f"\nRegistering with Ollama as '{model_name}'...")

    # Write Modelfile
    modelfile_dir = gguf_path.parent
    modelfile_path = modelfile_dir / "Modelfile"

    if model_family == "granite":
        template = MODELFILE_GRANITE
    else:
        template = MODELFILE_TEMPLATE

    modelfile_content = template.format(gguf_path=str(gguf_path.resolve()))
    modelfile_path.write_text(modelfile_content)
    print(f"  Modelfile: {modelfile_path}")

    # Run ollama create
    cmd = ["ollama", "create", model_name, "-f", str(modelfile_path)]
    print(f"  Running: {' '.join(cmd)}")
    result = subprocess.run(cmd, capture_output=True, text=True)

    if result.returncode != 0:
        print(f"  ⚠ ollama create failed: {result.stderr}")
        print(f"  You can manually register with:")
        print(f"    ollama create {model_name} -f {modelfile_path}")
        return False

    print(f"  ✓ Model registered: {model_name}")
    return True


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
def main():
    parser = argparse.ArgumentParser(
        description="Export LoRA adapter to GGUF and register with Ollama",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument("--base-model", required=True,
                        help="Base model name (same as used in training)")
    parser.add_argument("--lora-adapter", required=True, type=Path,
                        help="Path to LoRA adapter directory from train_fim_lora.py")
    parser.add_argument("--output", "-o", type=Path, default=Path("export-output"),
                        help="Output directory (default: export-output/)")
    parser.add_argument("--method", choices=["unsloth", "manual"], default="unsloth",
                        help="Export method: 'unsloth' (auto, recommended) or "
                             "'manual' (uses llama.cpp directly)")
    parser.add_argument("--quant", default="q8_0",
                        choices=["q4_0", "q4_K_M", "q5_K_M", "q8_0", "f16", "fp16"],
                        help="Quantization for GGUF (default: q8_0)")
    parser.add_argument("--max-seq-len", type=int, default=2048,
                        help="Max sequence length (match training, default: 2048)")
    parser.add_argument("--ollama-name", default=None,
                        help="Ollama model name (default: auto-generated)")
    parser.add_argument("--llama-cpp-path", type=Path, default=None,
                        help="Path to llama.cpp directory containing llama-quantize "
                             "(and optionally convert_hf_to_gguf.py). "
                             "Example: ~/.local/bin/llama-cpp")
    parser.add_argument("--merge-only", action="store_true",
                        help="Only merge LoRA into base, don't convert to GGUF")
    parser.add_argument("--ollama-aliases", nargs="+", default=[],
                        help="Additional Ollama model names (aliases) to register")
    parser.add_argument("--skip-ollama", action="store_true",
                        help="Skip Ollama registration (just produce the GGUF)")
    args = parser.parse_args()

    args.output.mkdir(parents=True, exist_ok=True)
    family = detect_model_family(args.base_model)

    print("=" * 60)
    print("Export LoRA to GGUF → Ollama")
    print("=" * 60)
    print(f"  Base model:    {args.base_model}")
    print(f"  LoRA adapter:  {args.lora_adapter}")
    print(f"  Method:        {args.method}")
    print(f"  Quantization:  {args.quant}")
    print(f"  Model family:  {family}")
    print()

    # Export
    if args.method == "unsloth":
        gguf_path = export_unsloth(
            args.base_model, args.lora_adapter, args.output,
            args.quant, args.max_seq_len, args.llama_cpp_path,
        )
    else:
        gguf_path = export_manual(
            args.base_model, args.lora_adapter, args.output,
            args.quant, args.max_seq_len, args.llama_cpp_path,
        )

    # Register with Ollama
    if not args.skip_ollama:
        if args.ollama_name:
            model_name = args.ollama_name
        else:
            # Auto-generate: e.g. "mycompany-coder:3b-q8_0"
            base_short = args.base_model.split("/")[-1].lower()
            base_short = base_short.replace("bnb-4bit", "").rstrip("-")
            model_name = f"{base_short}-fim:{args.quant}"
        register_ollama(gguf_path, model_name, family)

        for alias in args.ollama_aliases:
            print(f"\nCreating alias '{alias}' → '{model_name}'...")
            result = subprocess.run(
                ["ollama", "cp", model_name, alias],
                capture_output=True, text=True,
            )
            if result.returncode != 0:
                print(f"  ⚠ ollama cp failed: {result.stderr}")
                print(f"  You can manually create with: ollama cp {model_name} {alias}")
            else:
                print(f"  ✓ Alias registered: {alias}")

        print(f"\n{'=' * 60}")
        print(f"Done! Test your model:")
        print(f"{'=' * 60}")
        print(f"  # Chat test:")
        print(f"  ollama run {model_name} 'Write a PHP function to validate an email'")
        print()
        print(f"  # FIM test (from API):")
        print(f"  curl http://localhost:11434/api/generate -d '{{")
        print(f'    "model": "{model_name}",')
        print(f'    "prompt": "<?php\\nfunction calculateTotal(array $items): float {{\\n",')
        print(f'    "suffix": "\\n    return $total;\\n}}"')
        print(f"  }}'")
        print()
        print(f"  # Use in your editor (Continue, Cody, etc.):")
        print(f"  # Set model to: {model_name}")
        print(f"  # Set endpoint to: http://localhost:11434")
    else:
        print(f"\nGGUF file ready: {gguf_path}")
        print(f"Register manually: ollama create <name> -f {gguf_path.parent / 'Modelfile'}")


if __name__ == "__main__":
    main()
