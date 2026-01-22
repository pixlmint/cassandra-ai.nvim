# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

`cmp-ai` is a Neovim plugin that provides AI-powered code completion for [hrsh7th/nvim-cmp](https://github.com/hrsh7th/nvim-cmp). It's a general-purpose AI source that can be easily adapted to any REST API supporting remote code completion.

## Code Formatting

- **Indentation**: 2 spaces
- **Quote style**: Auto-prefer single quotes

## Architecture

### Core Components

The plugin follows a provider-based architecture with these key layers:

1. **Registration Layer** (`lua/cmp_ai/init.lua`): Registers the plugin as a cmp source
2. **Source Layer** (`lua/cmp_ai/source.lua`): Implements the nvim-cmp source interface, handles completion requests and response formatting
3. **Configuration Layer** (`lua/cmp_ai/config.lua`): Manages plugin settings and dynamically loads backend providers
4. **Backend Layer** (`lua/cmp_ai/backends/*.lua`): Provider-specific implementations (OpenAI, Claude, Ollama, HuggingFace, Codestral, Tabby, OpenWebUI)
5. **Request Layer** (`lua/cmp_ai/requests.lua`): Generic HTTP request handling using curl and plenary.job
6. **Prompt Formatters** (`lua/cmp_ai/prompt_formatters.lua`): Provider-specific prompt formatting (FIM tokens, chat formatting, etc.)

### How Completion Works

1. User types in buffer → `source.lua:complete()` is called by nvim-cmp
2. Source extracts context: `max_lines` before/after cursor using `nvim_buf_get_lines()`
3. Source calls configured provider's `complete()` method with `lines_before` and `lines_after`
4. Provider formats the prompt using appropriate formatter (FIM tags, chat format, etc.)
5. Provider makes HTTP request via `requests.lua` (curl-based, async via plenary.job)
6. Provider parses response and extracts completion text
7. Source formats completions as cmp items with documentation
8. nvim-cmp displays completions to user

### Provider Architecture

Each backend in `lua/cmp_ai/backends/` follows this pattern:
- Inherits from `requests.lua` base class
- Implements `:new(o, params)` constructor with provider-specific defaults
- Implements `:complete(lines_before, lines_after, cb)` method
- Handles API authentication via environment variables
- Formats prompts using functions from `prompt_formatters.lua` or custom logic
- Parses provider-specific response format and calls callback with completions array

Special cases:
- **Ollama**: Has model management logic (`configure_model()`) to detect loaded models and select appropriate one
- **Ollama FIM**: Supports both `/api/generate` and `/api/chat` endpoints with suffix parameter for fill-in-middle

### Prompt Formatting Strategies

The plugin supports multiple prompt formatting strategies in `prompt_formatters.lua`:

1. **general_ai**: For chat-based models (GPT, Claude) - uses system prompt with `<code_prefix>` and `<code_suffix>` tags
2. **ollama_code**: Uses `<PRE>`, `<SUF>`, `<MID>` tokens
3. **santacoder**: Uses `<fim-prefix>`, `<fim-suffix>`, `<fim-middle>` tokens
4. **codestral**: Uses `[SUFFIX]` and `[PREFIX]` markers
5. **fim**: For codegemma/qwen - returns `{prompt, suffix}` table for models with native FIM support

Providers can override formatters via `provider_options.prompt` and `provider_options.suffix` functions.

### Configuration System

Configuration in `config.lua` uses a singleton pattern:
- Stores global config state in local `conf` table
- `setup()` dynamically loads backends from `lua/cmp_ai/backends/` based on provider name
- Provider switching is detected and only reinitializes when provider changes
- Supports both string provider names ("OpenAI") and pre-initialized provider objects

## Development

### Testing Changes

There is no formal test suite. To test changes:

## Dependencies

Runtime dependencies:
- [nvim-cmp](https://github.com/hrsh7th/nvim-cmp) - completion engine
- [plenary.nvim](https://github.com/nvim-lua/plenary.nvim) - Lua utilities (async, job control)
- `curl` - for HTTP requests (not needed for Ollama)

## Common Patterns

### Autocmd Events

The plugin fires user autocmds for integration:
- `User CmpAiRequestStarted` - when a completion request begins
- `User CmpAiRequestComplete` - when a completion request finishes
- `User CmpAiRequestFinished` - fired with response data after JSON parsing

### UTF-8 Handling

Context extraction in `source.lua` uses `vim.fn.strpart()` instead of `string.sub()` to properly handle UTF-8 characters when splitting lines at cursor position.

### Error Handling

- Backends notify errors via `vim.notify()` with configurable logging (`log_errors` config option)
- Failed HTTP requests (non-zero exit codes) return error items to callback
- Missing API keys are detected at initialization and generate error notifications
