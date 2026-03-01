# cassandra-ai

AI-powered code completion ecosystem: a Neovim plugin for inline ghost-text completions, a FIM dataset generator for LoRA fine-tuning, and supporting tools.

## Workspace Structure

```
lua/cassandra_ai/   Neovim plugin (Lua) — has its own CLAUDE.md
python/             FIM dataset generator + context server (Python) — has its own CLAUDE.md
viewer/             Dataset viewer/curation tool (Vue 3 + Express) — has its own CLAUDE.md
tools/              Standalone Python scripts (analysis, export, training)
after/, doc/        Neovim ftplugin and help docs
tests/              Neovim plugin tests (Lua)
```

## Commands

```bash
# Lua (Neovim plugin)
stylua lua/                              # format Lua code

# Python
make test                                # run Python tests (pytest)
venv/bin/python -m generate /path --preview 5   # dry-run dataset generation
make serve                               # start FIM context server

# Viewer
cd viewer && npm run dev                 # dev server (Express + Vite HMR)
```

## Conventions

- **Lua**: 2-space indent, single quotes, `stylua` formatter (see `stylua.toml`)
- **Python**: venv at `./venv`, private modules use `_` prefix, public API in `fim/`
- **Cross-component**: the `python/` FIM server provides context to the Neovim plugin via JSON-RPC over stdin/stdout
