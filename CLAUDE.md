# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

`cassandra-ai` is a Neovim plugin that provides AI-powered inline code completion. Named after the tragic Trojan priestess Cassandra. It's a general-purpose AI completion source that can be easily adapted to any REST API supporting remote code completion.

## Code Formatting

- **Indentation**: 2 spaces
- **Quote style**: Auto-prefer single quotes

## Architecture

### Core Components

The plugin follows a provider-based architecture with these key layers:

1. **Entry Point** (`lua/cassandra_ai/init.lua`): Calls `inline.setup()` and registers commands
2. **Inline Completion** (`lua/cassandra_ai/inline.lua`): Core ghost text module using inline extmarks
3. **Configuration Layer** (`lua/cassandra_ai/config.lua`): Manages plugin settings and dynamically loads backend providers
4. **Backend Layer** (`lua/cassandra_ai/backends/*.lua`): Provider-specific implementations (OpenAI, Claude, Ollama, HuggingFace, Codestral, Tabby, OpenWebUI)
5. **Request Layer** (`lua/cassandra_ai/requests.lua`): Generic HTTP request handling using curl and plenary.job
6. **Prompt Formatters** (`lua/cassandra_ai/prompt_formatters.lua`): Provider-specific prompt formatting (FIM tokens, chat formatting, etc.)
7. **Context Provider Layer** (`lua/cassandra_ai/context/*.lua`): Extensible system for injecting additional context (LSP, Treesitter, RAG, etc.) into completion requests

### How Completion Works

1. User types in buffer -> `inline.lua` triggers after debounce
2. Generation counter pattern detects stale requests
3. Context is extracted: `max_lines` before/after cursor using `nvim_buf_get_lines()`
4. **[Optional]** Context providers gather additional context (LSP diagnostics, treesitter info, etc.)
5. Configured provider's `complete()` method is called with `lines_before`, `lines_after`, and optional `additional_context`
6. Provider formats the prompt using appropriate formatter (FIM tags, chat format, etc.)
7. Provider makes HTTP request via `requests.lua` (curl-based, async via plenary.job)
8. Provider parses response and extracts completion text
9. Ghost text is displayed as inline virtual text extmarks

### Provider Architecture

Each backend in `lua/cassandra_ai/backends/` follows this pattern:
- Inherits from `requests.lua` base class
- Implements `:new(o, params)` constructor with provider-specific defaults
- Implements `:complete(lines_before, lines_after, cb, additional_context)` method
- Returns plenary.job handle from `complete()` for cancellation support
- Handles API authentication via environment variables
- Formats prompts using functions from `prompt_formatters.lua` or custom logic
- Parses provider-specific response format and calls callback with completions array

Special cases:
- **Ollama**: Has model management logic (`configure_model()`) to detect loaded models and select appropriate one

### Context Provider Architecture

Context providers in `lua/cassandra_ai/context/` follow this pattern:
- Inherit from `base.lua` BaseContextProvider class
- Implement `:new(opts)` constructor with provider-specific defaults
- Implement `:get_context(params, callback)` for async context gathering
- Optionally implement `:get_context_sync(params)` for synchronous providers
- Implement `:is_available()` to check for dependencies (LSP, Treesitter, etc.)
- Return context in format `{ content = string, metadata = table }`

Built-in context providers:
- **Treesitter**: Extracts syntax tree context (parent nodes, current node type)
- **LSP**: Provides diagnostics, symbols, and hover information
- **Buffer**: Includes content from related open buffers

### Prompt Formatting Strategies

The plugin supports multiple prompt formatting strategies in `prompt_formatters.lua`. All formatters accept an optional `additional_context` parameter (4th argument) for context injection:

1. **general_ai**: For chat-based models (GPT, Claude) - uses system prompt with `<code_prefix>` and `<code_suffix>` tags
2. **ollama_code**: Uses `<PRE>`, `<SUF>`, `<MID>` tokens
3. **santacoder**: Uses `<fim-prefix>`, `<fim-suffix>`, `<fim-middle>` tokens
4. **codestral**: Uses `[SUFFIX]` and `[PREFIX]` markers
5. **fim**: For codegemma/qwen - returns `{prompt, suffix}` table for models with native FIM support

Signature: `formatter(lines_before, lines_after, opts, additional_context)`

### Configuration System

Configuration in `config.lua` uses a singleton pattern:
- Stores global config state in local `conf` table
- `setup()` dynamically loads backends from `lua/cassandra_ai/backends/` based on provider name
- Provider switching is detected and only reinitializes when provider changes

## Development

### Testing Changes

There is no formal test suite. To test changes:

## Dependencies

Runtime dependencies:
- [plenary.nvim](https://github.com/nvim-lua/plenary.nvim) - Lua utilities (async, job control)
- `curl` - for HTTP requests (not needed for Ollama)

## Common Patterns

### User Commands

The plugin provides debugging commands for context providers:
- `:CassandraAiContextList` - List all registered context providers
- `:CassandraAiContext <provider>` - Show context from a specific provider in a popup
- `:CassandraAiContextAll` - Show merged context from all providers in a popup

These commands are defined in `lua/cassandra_ai/commands.lua` and registered during plugin initialization.

### Autocmd Events

The plugin fires user autocmds for integration:
- `User CassandraAiRequestStarted` - when a completion request begins
- `User CassandraAiRequestComplete` - when a completion request finishes
- `User CassandraAiRequestFinished` - fired with response data after JSON parsing

### Error Handling

- Backends notify errors via `vim.notify()` with configurable logging (`log_errors` config option)
- Failed HTTP requests (non-zero exit codes) return error items to callback
- Missing API keys are detected at initialization and generate error notifications
