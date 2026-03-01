# Neovim Plugin

`cassandra-ai` is a Neovim plugin that provides AI-powered inline code completion using ghost text (virtual text extmarks). Named after the tragic Trojan priestess Cassandra. It's a general-purpose AI completion source adapted to REST APIs supporting remote code completion.

## Code Formatting

- **Indentation**: 2 spaces
- **Quote style**: Auto-prefer single quotes
- **Formatter**: `stylua` with config in `stylua.toml` (column width 1200)

## Architecture

### Completion Flow

1. User types in insert mode -> `CursorMovedI` autocmd fires
2. Debounce timer (150ms default) -> `suggest/init.lua:trigger()`
3. Generation counter increments (stale request detection)
4. Context extracted: `max_lines` before/after cursor via `nvim_buf_get_lines()`
5. Context providers gather additional context in parallel (with timeout)
6. Provider's `complete()` called with `lines_before`, `lines_after`, `additional_context`
7. Provider formats prompt via `prompt_formatters.lua`, makes async HTTP request via `requests.lua`
8. Response callback checks generation counter is still current (discards stale)
9. Post-processing: strips markdown code fences, removes overlapping context lines
10. Ghost text rendered as inline virtual text extmarks

### Key Design Patterns

**Generation counter** (`suggest/state.lua`): A monotonic counter incremented on each trigger. Every async callback checks `if my_gen ~= state.generation then return end` to discard responses from superseded requests.

**Provider interface**: All adapters inherit from `requests.lua` Service class, implement `:new(o, params)` and `:complete(lines_before, lines_after, cb, additional_context)`, return a `plenary.job` handle for cancellation.

**Context provider interface**: Providers in `context/` inherit from `base.lua` BaseContextProvider, implement `:get_context(params, callback)`, `:is_available()`. The context manager (`context/init.lua`) gathers from all providers in parallel with configurable timeout, then merges results.

**Config singleton**: `config.lua` stores state in a local `conf` table, dynamically loads adapters via `require('cassandra_ai.adapters.' .. provider_name)`, only reinitializes when provider changes. Configuration is now structured with nested `logging` and `telemetry` tables. The setup flow starts in `init.lua` which calls `config:setup()`, which in turn initializes the suggest module.

### Core Components

1. **Entry Point** (`init.lua`): Calls `config:setup()` which initializes suggest module and registers commands
2. **Suggestion Engine** (`suggest/`): Core ghost text engine split into submodules — `init.lua` (orchestrator + public API), `state.lua` (shared mutable state), `renderer.lua` (extmark rendering), `postprocess.lua` (text transforms), `validation.lua` (deferred validation), `pipeline.lua` (request dispatch)
3. **Configuration** (`config.lua`): Singleton config with dynamic provider loading
4. **Adapters** (`adapters/*.lua`): Provider implementations. Ollama has special model management (`get_model()` queries `/api/ps` for loaded models)
5. **Requests** (`requests.lua`): Base HTTP class using curl via `plenary.job`, writes JSON to temp files
6. **Prompt Formatters** (`prompt_formatters.lua`): FIM token strategies (`general_ai`, `ollama_code`, `santacoder`, `codestral`, `fim`, `chat`)
7. **Context Providers** (`context/`): LSP definitions, treesitter nodes, diagnostics, buffer content
8. **Commands** (`commands.lua`): `:Cassy` command tree with subcommands for context, log, config
9. **Logger** (`logger.lua`): File-based logging with threshold levels (can be disabled by setting level to nil)
10. **Telemetry** (`telemetry.lua`): Opt-in data collection to JSONL with async buffered writes

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
