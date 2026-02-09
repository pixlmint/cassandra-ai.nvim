# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

`cassandra-ai` is a Neovim plugin that provides AI-powered inline code completion using ghost text (virtual text extmarks). Named after the tragic Trojan priestess Cassandra. It's a general-purpose AI completion source adapted to REST APIs supporting remote code completion. Only the Ollama backend is actively maintained; all other backends (OpenAI, Claude, Codestral, HuggingFace, Tabby, OpenWebUI) are deprecated.

## Code Formatting

- **Indentation**: 2 spaces
- **Quote style**: Auto-prefer single quotes
- **Formatter**: `stylua` with config in `stylua.toml` (column width 1200)

## Commands

```bash
make format          # Format with stylua
make test            # Run all tests (mini.test)
make test_file FILE=tests/test_config.lua  # Run a single test file
make deps            # Clone test dependencies (plenary, mini.nvim, nvim-treesitter)
```

Tests use `mini.test` (not plenary busted). Test files follow the pattern `tests/test_*.lua`. The test harness runs headless nvim with `tests/minimal_init.lua`.

## Architecture

### Completion Flow

1. User types in insert mode -> `CursorMovedI` autocmd fires
2. Debounce timer (150ms default) -> `inline.lua:trigger()`
3. Generation counter increments (stale request detection)
4. Context extracted: `max_lines` before/after cursor via `nvim_buf_get_lines()`
5. Context providers gather additional context in parallel (with timeout)
6. Provider's `complete()` called with `lines_before`, `lines_after`, `additional_context`
7. Provider formats prompt via `prompt_formatters.lua`, makes async HTTP request via `requests.lua`
8. Response callback checks generation counter is still current (discards stale)
9. Post-processing: strips markdown code fences, removes overlapping context lines
10. Ghost text rendered as inline virtual text extmarks

### Key Design Patterns

**Generation counter** (`inline.lua`): A monotonic counter incremented on each trigger. Every async callback checks `if my_gen ~= generation then return end` to discard responses from superseded requests.

**Provider interface**: All backends inherit from `requests.lua` Service class, implement `:new(o, params)` and `:complete(lines_before, lines_after, cb, additional_context)`, return a `plenary.job` handle for cancellation.

**Context provider interface**: Providers in `context/` inherit from `base.lua` BaseContextProvider, implement `:get_context(params, callback)`, `:is_available()`. The context manager (`context/init.lua`) gathers from all providers in parallel with configurable timeout, then merges results.

**Config singleton**: `config.lua` stores state in a local `conf` table, dynamically loads backends via `require('cassandra_ai.backends.' .. provider_name)`, only reinitializes when provider changes.

### Core Components

1. **Entry Point** (`lua/cassandra_ai/init.lua`): Calls `inline.setup()` and registers commands
2. **Inline Completion** (`lua/cassandra_ai/inline.lua`): Core ghost text engine - trigger, render, accept/dismiss/navigate completions
3. **Configuration** (`lua/cassandra_ai/config.lua`): Singleton config with dynamic provider loading
4. **Backends** (`lua/cassandra_ai/backends/*.lua`): Provider implementations. Ollama has special model management (`get_model()` queries `/api/ps` for loaded models)
5. **Requests** (`lua/cassandra_ai/requests.lua`): Base HTTP class using curl via `plenary.job`, writes JSON to temp files
6. **Prompt Formatters** (`lua/cassandra_ai/prompt_formatters.lua`): FIM token strategies (`general_ai`, `ollama_code`, `santacoder`, `codestral`, `fim`)
7. **Context Providers** (`lua/cassandra_ai/context/`): LSP definitions, treesitter nodes, diagnostics, buffer content
8. **Commands** (`lua/cassandra_ai/commands.lua`): `:Cassy` command tree with subcommands for context, log, config
9. **Logger** (`lua/cassandra_ai/logger.lua`): File-based logging with threshold levels
10. **Telemetry** (`lua/cassandra_ai/telemetry.lua`): Opt-in data collection to JSONL with async buffered writes

### User Commands

- `:Cassy context <provider>` - Show context from a provider in a popup
- `:Cassy log` - Open log file
- `:Cassy config auto_trigger toggle|enable|disable` - Toggle auto completion
- `:Cassy config telemetry toggle|enable|disable` - Toggle telemetry
- `:Cassy config log_level TRACE|DEBUG|INFO|WARN|ERROR` - Set log level
- `:Cassy config model <name|auto>` - Override Ollama model

### Autocmd Events

- `User CassandraAiRequestStarted` - completion request begins
- `User CassandraAiRequestComplete` - completion request finishes
- `User CassandraAiRequestFinished` - fired with response data after JSON parsing

## Logging

Use `local logger = require('cassandra_ai.logger')` at the top of each module. Default level is WARN. Levels DEBUG+ also fire `vim.notify()`; TRACE only writes to file.

**Level usage:**
- **trace**: Control flow, function entry/exit, discarded results — `logger.trace('Ollama:complete() -> model=' .. model)`
- **debug**: State changes, successful operations — `logger.debug('provider loaded: ' .. name)`
- **info**: Completion lifecycle events — `logger.info('completion accepted (' .. n .. ' lines)')`
- **warn**: Recoverable problems, timeouts — `logger.warn('context: timed out after ' .. ms .. 'ms')`
- **error**: Operation failures — `logger.error('HTTP request failed: ' .. url .. ' exit_code=' .. code)`

Use `logger.fmt(level, fmt, ...)` for formatted messages. Always include identifiers (provider name, URL, generation number) and prefix with module context (`'Ollama:get_model() -> ...'`, `'context: ...'`).

## Dependencies

- [plenary.nvim](https://github.com/nvim-lua/plenary.nvim) - async job control
- `curl` - HTTP requests (not needed for Ollama local)
- Treesitter, LSP (optional) - for context providers
