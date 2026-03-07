#!/usr/bin/env python3
"""
train_fim_lora.py — Fine-tune a LoRA adapter for FIM code completion using unsloth.

This takes the JSONL dataset from fim_dataset_builder.py and trains a LoRA
adapter on top of a Qwen2.5-Coder base model.

PREREQUISITES
=============
    # GPU required. unsloth supports NVIDIA (CUDA) and AMD (ROCm).
    # Minimum: 8GB VRAM for 3B, 16GB for 7B (with 4-bit quantized base).

    # Install unsloth (pick ONE based on your setup):
    # CUDA 12.1+
    pip install "unsloth[colab-new] @ git+https://github.com/unslothai/unsloth.git"
    pip install --no-deps xformers trl peft accelerate bitsandbytes triton

    # OR for a clean conda env:
    conda create -n lora python=3.11
    conda activate lora
    pip install "unsloth[colab-new] @ git+https://github.com/unslothai/unsloth.git"
    pip install --no-deps xformers trl peft accelerate bitsandbytes triton

USAGE
=====
    # Basic training (3B model, fast iteration)
    python train_fim_lora.py \
        --base-model unsloth/Qwen2.5-Coder-3B-bnb-4bit \
        --dataset dataset/train.jsonl \
        --val-dataset dataset/val.jsonl \
        --output lora-output/

    # 7B model, more epochs
    python train_fim_lora.py \
        --base-model unsloth/Qwen2.5-Coder-7B-bnb-4bit \
        --dataset dataset/train.jsonl \
        --val-dataset dataset/val.jsonl \
        --output lora-output/ \
        --epochs 3

    # Resume from checkpoint
    python train_fim_lora.py \
        --base-model unsloth/Qwen2.5-Coder-7B-bnb-4bit \
        --dataset dataset/train.jsonl \
        --output lora-output/ \
        --resume lora-output/checkpoint-500
"""

import argparse
import json
import os
import sys
import textwrap
from pathlib import Path


def main():
    parser = argparse.ArgumentParser(
        description="Fine-tune a FIM LoRA adapter with unsloth",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument("--base-model", default="unsloth/Qwen2.5-Coder-3B-bnb-4bit",
                        help="Base model from HuggingFace (default: Qwen2.5-Coder-3B-bnb-4bit)")
    parser.add_argument("--dataset", required=True, type=Path,
                        help="Training JSONL from fim_dataset_builder.py")
    parser.add_argument("--val-dataset", type=Path, default=None,
                        help="Validation JSONL (optional but recommended)")
    parser.add_argument("--output", "-o", type=Path, default=Path("lora-output"),
                        help="Output directory for LoRA adapter and checkpoints")
    parser.add_argument("--epochs", type=int, default=2,
                        help="Number of training epochs (default: 2)")
    parser.add_argument("--batch-size", type=int, default=2,
                        help="Per-device batch size (default: 2). "
                             "OOM? Set to 1. 24GB+ GPU? Try 4 or 8.")
    parser.add_argument("--grad-accum", type=int, default=8,
                        help="Gradient accumulation steps (default: 8, "
                             "effective batch = batch_size × grad_accum = 16). "
                             "Increase when reducing batch-size to keep effective batch ~16-32.")
    parser.add_argument("--lr", type=float, default=2e-4,
                        help="Learning rate (default: 2e-4)")
    parser.add_argument("--max-seq-len", type=int, default=1536,
                        help="Maximum sequence length (default: 1536). "
                             "Reduce to 1024 if OOM. Use 2048+ only with 24GB+ VRAM.")
    parser.add_argument("--lora-rank", type=int, default=32,
                        help="LoRA rank (default: 32, higher = more capacity but slower)")
    parser.add_argument("--lora-alpha", type=int, default=32,
                        help="LoRA alpha (default: 32, typically equal to rank)")
    parser.add_argument("--resume", type=Path, default=None,
                        help="Resume from checkpoint directory")
    parser.add_argument("--save-steps", type=int, default=100,
                        help="Save checkpoint every N steps (default: 100)")
    parser.add_argument("--packing", action="store_true",
                        help="Enable example packing. Off by default for FIM training because "
                             "packing merges unrelated FIM examples, breaking sequence boundaries.")
    parser.add_argument("--sample-fraction", type=float, default=None,
                        help="Use only a fraction of training samples (e.g. 0.1 = 10%%)")
    parser.add_argument("--dry-run", action="store_true",
                        help="Print config and exit without training")
    args = parser.parse_args()

    # -----------------------------------------------------------------------
    # Print config
    # -----------------------------------------------------------------------
    print("=" * 60)
    print("FIM LoRA Fine-Tuning")
    print("=" * 60)
    print(f"  Base model:    {args.base_model}")
    print(f"  Dataset:       {args.dataset}")
    print(f"  Val dataset:   {args.val_dataset or 'none'}")
    print(f"  Output:        {args.output}")
    print(f"  Epochs:        {args.epochs}")
    print(f"  Batch size:    {args.batch_size} × {args.grad_accum} grad accum "
          f"= {args.batch_size * args.grad_accum} effective")
    print(f"  Learning rate: {args.lr}")
    print(f"  Max seq len:   {args.max_seq_len}")
    print(f"  LoRA rank:     {args.lora_rank}, alpha: {args.lora_alpha}")
    print()

    # Quick dataset check
    line_count = sum(1 for _ in open(args.dataset))
    effective_count = line_count
    if args.sample_fraction is not None:
        effective_count = max(1, int(line_count * args.sample_fraction))
        print(f"  Training examples: {effective_count} / {line_count} ({args.sample_fraction:.0%} sample)")
    else:
        print(f"  Training examples: {line_count}")
    if args.val_dataset:
        val_count = sum(1 for _ in open(args.val_dataset))
        print(f"  Validation examples: {val_count}")

    steps_per_epoch = effective_count // (args.batch_size * args.grad_accum)
    total_steps = steps_per_epoch * args.epochs
    print(f"  Steps/epoch:   ~{steps_per_epoch}")
    print(f"  Total steps:   ~{total_steps}")

    # VRAM estimate
    try:
        import torch
        if torch.cuda.is_available():
            vram_gb = torch.cuda.get_device_properties(0).total_memory / (1024**3)
            gpu_name = torch.cuda.get_device_name(0)
            print(f"\n  GPU:           {gpu_name} ({vram_gb:.1f} GB)")

            # Rough VRAM estimate: model + LoRA + optimizer + activations
            # 4-bit 3B ≈ 2GB, 7B ≈ 4GB base
            model_size = "7" if "7b" in args.base_model.lower() else "3"
            base_vram = 4.0 if model_size == "7" else 2.0
            # Activations scale with batch_size × seq_len
            act_vram = args.batch_size * args.max_seq_len * 0.0005  # rough heuristic
            est_vram = base_vram + 1.0 + act_vram  # +1 for optimizer states
            print(f"  Est. VRAM:     ~{est_vram:.1f} GB "
                  f"({'⚠ TIGHT' if est_vram > vram_gb * 0.85 else '✓ OK'} "
                  f"for {vram_gb:.0f} GB card)")
            if est_vram > vram_gb * 0.85:
                print(f"  💡 Try: --batch-size 1 --grad-accum {args.batch_size * args.grad_accum} "
                      f"--max-seq-len {min(args.max_seq_len, 1024)}")
    except ImportError:
        pass
    print()

    if args.dry_run:
        print("Dry run — exiting.")
        return

    # -----------------------------------------------------------------------
    # Import unsloth (done late so --help and --dry-run work without GPU)
    # -----------------------------------------------------------------------
    try:
        from unsloth import FastLanguageModel
    except ImportError:
        print("ERROR: unsloth not installed.")
        print("Install with:")
        print('  pip install "unsloth[colab-new] @ git+https://github.com/unslothai/unsloth.git"')
        print("  pip install --no-deps xformers trl peft accelerate bitsandbytes triton")
        sys.exit(1)

    from datasets import Dataset
    from trl import SFTTrainer
    from transformers import TrainingArguments

    # -----------------------------------------------------------------------
    # Load base model
    # -----------------------------------------------------------------------
    print(f"Loading base model: {args.base_model}")
    model, tokenizer = FastLanguageModel.from_pretrained(
        model_name=args.base_model,
        max_seq_length=args.max_seq_len,
        dtype=None,           # auto-detect (float16 on most GPUs)
        load_in_4bit=True,    # 4-bit quantized base for memory efficiency
    )

    # -----------------------------------------------------------------------
    # Add LoRA adapter
    # -----------------------------------------------------------------------
    print(f"Adding LoRA adapter (rank={args.lora_rank}, alpha={args.lora_alpha})")
    model = FastLanguageModel.get_peft_model(
        model,
        r=args.lora_rank,
        lora_alpha=args.lora_alpha,
        lora_dropout=0,         # 0 is optimal per unsloth docs
        target_modules=[
            "q_proj", "k_proj", "v_proj", "o_proj",  # attention
            "gate_proj", "up_proj", "down_proj",       # MLP
        ],
        bias="none",
        use_gradient_checkpointing="unsloth",  # 30% less VRAM
        random_state=42,
    )

    # Print trainable parameter count
    trainable = sum(p.numel() for p in model.parameters() if p.requires_grad)
    total = sum(p.numel() for p in model.parameters())
    print(f"  Trainable params: {trainable:,} / {total:,} "
          f"({100 * trainable / total:.2f}%)")

    # -----------------------------------------------------------------------
    # Load dataset
    # -----------------------------------------------------------------------
    print(f"Loading dataset...")

    def load_jsonl(path: Path) -> Dataset:
        examples = []
        with open(path) as f:
            for line in f:
                if line.strip():
                    obj = json.loads(line)
                    examples.append({"text": obj["text"]})
        return Dataset.from_list(examples)

    train_dataset = load_jsonl(args.dataset)
    val_dataset = load_jsonl(args.val_dataset) if args.val_dataset else None

    if args.sample_fraction is not None:
        full_size = len(train_dataset)
        n = max(1, int(full_size * args.sample_fraction))
        train_dataset = train_dataset.shuffle(seed=42).select(range(n))
        print(f"  Train: {n} / {full_size} examples "
              f"({args.sample_fraction:.0%} sample)")
    else:
        print(f"  Train: {len(train_dataset)} examples")
    if val_dataset:
        print(f"  Val:   {len(val_dataset)} examples")

    # Ensure tokenizer respects our sequence length limit.
    # Without this, SFTTrainer tokenizes at its own default (often 1024+)
    # and unsloth's late truncation causes dimension mismatches in the loss.
    tokenizer.model_max_length = args.max_seq_len
    tokenizer.truncation_side = "left"  # PSM format: middle+EOT is at the end, preserve it

    # -----------------------------------------------------------------------
    # Training arguments
    # -----------------------------------------------------------------------
    args.output.mkdir(parents=True, exist_ok=True)

    # Auto-detect bf16 support (Ampere+ GPUs)
    use_bf16 = False
    try:
        import torch
        if torch.cuda.is_available() and torch.cuda.get_device_capability()[0] >= 8:
            use_bf16 = True
    except ImportError:
        pass

    training_args = TrainingArguments(
        output_dir=str(args.output),
        num_train_epochs=args.epochs,
        per_device_train_batch_size=args.batch_size,
        gradient_accumulation_steps=args.grad_accum,
        learning_rate=args.lr,
        lr_scheduler_type="cosine",
        warmup_ratio=0.05,
        weight_decay=0.01,
        bf16=use_bf16,
        fp16=not use_bf16,
        logging_steps=10,
        save_steps=args.save_steps,
        save_total_limit=3,           # keep only last 3 checkpoints
        eval_strategy="steps" if val_dataset else "no",
        eval_steps=args.save_steps if val_dataset else None,
        seed=42,
        report_to="none",            # set to "wandb" if you want logging
        optim="adamw_8bit",          # 8-bit Adam for memory efficiency
    )

    # -----------------------------------------------------------------------
    # Train
    # -----------------------------------------------------------------------
    # Reduce CUDA memory fragmentation (helps avoid OOM on smaller GPUs)
    os.environ.setdefault("PYTORCH_CUDA_ALLOC_CONF", "expandable_segments:True")

    print(f"\nStarting training...")
    use_packing = args.packing
    if use_packing:
        print("  Note: packing enabled — FIM sequence boundaries will be merged")
        if args.max_seq_len < 768:
            print("  ⚠ Auto-disabling packing (max_seq_len < 768 causes dimension bugs)")
            use_packing = False

    trainer = SFTTrainer(
        model=model,
        tokenizer=tokenizer,
        train_dataset=train_dataset,
        eval_dataset=val_dataset,
        dataset_text_field="text",
        max_seq_length=args.max_seq_len,
        packing=use_packing,
        args=training_args,
    )

    if args.resume:
        print(f"  Resuming from {args.resume}")
        trainer.train(resume_from_checkpoint=str(args.resume))
    else:
        trainer.train()

    # -----------------------------------------------------------------------
    # Save LoRA adapter
    # -----------------------------------------------------------------------
    lora_dir = args.output / "lora-adapter"
    print(f"\nSaving LoRA adapter to {lora_dir}")
    model.save_pretrained(lora_dir)
    tokenizer.save_pretrained(lora_dir)

    # -----------------------------------------------------------------------
    # Print next steps
    # -----------------------------------------------------------------------
    print(f"\n{'=' * 60}")
    print(f"Training complete!")
    print(f"{'=' * 60}")
    print(f"  LoRA adapter saved: {lora_dir}")
    print()
    print(f"Next steps:")
    print(f"  1. Export to GGUF for Ollama:")
    print(f"       python export_to_ollama.py \\")
    print(f"           --base-model {args.base_model} \\")
    print(f"           --lora-adapter {lora_dir} \\")
    print(f"           --quant q8_0")
    print(f"  2. Or merge and push to HuggingFace:")
    print(f"       model.save_pretrained_merged('merged/', tokenizer)")


if __name__ == "__main__":
    main()