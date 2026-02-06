# cassandra-ai

*Named after [Cassandra](https://en.wikipedia.org/wiki/Cassandra), the tragic Trojan priestess cursed to speak true prophecies that none would believe.*

AI-powered inline code completion for Neovim.

A general purpose AI completion source, easily adapted to any REST API
supporting remote code completion.

Supported backends: HuggingFace, OpenAI, Codestral, Ollama, Claude, Tabby, and OpenWebUI.

## Install

### Dependencies

- You will need `plenary.nvim` to use this plugin.
- For using Codestral, OpenAI or HuggingFace, you will also need `curl`.

### Using a plugin manager

Using [Lazy](https://github.com/folke/lazy.nvim/):

```lua
return require("lazy").setup({
    {'pixlmint/cassandra-ai', dependencies = 'nvim-lua/plenary.nvim'},
})
```

## Setup

Please note the use of `:` instead of a `.`

To use HuggingFace:

```lua
local cassandra_ai = require('cassandra_ai.config')

cassandra_ai:setup({
  max_lines = 1000,
  provider = 'HF',
  notify = true,
  notify_callback = function(msg)
    vim.notify(msg)
  end,
  ignored_file_types = {
    -- default is not to ignore
    -- uncomment to ignore in lua:
    -- lua = true
  },
})
```

You will also need to make sure you have the Hugging Face api key in your
environment, `HF_API_KEY`.

To use OpenAI:

```lua
local cassandra_ai = require('cassandra_ai.config')

cassandra_ai:setup({
  max_lines = 1000,
  provider = 'OpenAI',
  provider_options = {
    model = 'gpt-4',
  },
  notify = true,
  notify_callback = function(msg)
    vim.notify(msg)
  end,
  ignored_file_types = {
    -- default is not to ignore
    -- uncomment to ignore in lua:
    -- lua = true
  },
})
```

You will also need to make sure you have the OpenAI api key in your
environment, `OPENAI_API_KEY`.

To use Codestral:

```lua
local cassandra_ai = require('cassandra_ai.config')

cassandra_ai:setup({
  max_lines = 1000,
  provider = 'Codestral',
  provider_options = {
    model = 'codestral-latest',
  },
  notify = true,
  notify_callback = function(msg)
    vim.notify(msg)
  end,
  ignored_file_types = {
    -- default is not to ignore
    -- uncomment to ignore in lua:
    -- lua = true
  },
})
```

You will also need to make sure you have the Codestral api key in your
environment, `CODESTRAL_API_KEY`.

You can also use the `suffix` and `prompt` parameters:

```lua
local cassandra_ai = require('cassandra_ai.config')

cassandra_ai:setup({
  max_lines = 1000,
  provider = 'Codestral',
  provider_options = {
    model = 'codestral-latest',
    prompt = function(lines_before, lines_after)
      return lines_before
    end,
    suffix = function(lines_after)
      return lines_after
    end
  },
  notify = true,
  notify_callback = function(msg)
    vim.notify(msg)
  end,
})
```

To use [Ollama](https://ollama.ai):

```lua
local cassandra_ai = require('cassandra_ai.config')

cassandra_ai:setup({
  max_lines = 100,
  provider = 'Ollama',
  provider_options = {
    model = 'codellama:7b-code',
    auto_unload = false, -- Set to true to automatically unload the model when
                        -- exiting nvim.
  },
  notify = true,
  notify_callback = function(msg)
    vim.notify(msg)
  end,
  ignored_file_types = {
    -- default is not to ignore
    -- uncomment to ignore in lua:
    -- lua = true
  },
})
```

With Ollama you can also use the `suffix` parameter, typically when you want to use cassandra-ai for code completion and you want to use the default plugin/prompt.

If the model you're using has the following template:
```
{{- if .Suffix }}<|fim_prefix|>{{ .Prompt }}<|fim_suffix|>{{ .Suffix }}<|fim_middle|>
{{- else }}{{ .Prompt }}
{{- end }}
```
then you can use the suffix parameter to not change the prompt. Since the model will use your suffix and the prompt to construct the template.
The prompts should be the `lines_before` and suffix the `lines_after`.
Now you can even change the model without the need to adjust the prompt or suffix functions.

```lua
local cassandra_ai = require('cassandra_ai.config')

cassandra_ai:setup({
  max_lines = 100,
  provider = 'Ollama',
  provider_options = {
    model = 'codegemma:2b-code',
    prompt = function(lines_before, lines_after)
      return lines_before
    end,
    suffix = function(lines_after)
      return lines_after
    end,
  },
  notify = true,
  notify_callback = function(msg)
    vim.notify(msg)
  end,
})
```
> [!NOTE]
> Different models may implement different special tokens to delimit
> prefix and suffix. You may want to consult the official documentation for the
> specific tokens used for your model and the recommended format of the prompt. For example, [qwen2.5-coder](https://github.com/QwenLM/Qwen2.5-Coder?tab=readme-ov-file#basic-information) used `<|fim_prefix|>`, `<|fim_middle|>` and `<|fim_suffix|>` (as well as some other special tokens for project context) as the delimiter for fill-in-middle code completion and provided [examples](https://github.com/QwenLM/Qwen2.5-Coder?tab=readme-ov-file#3-file-level-code-completion-fill-in-the-middle) on how to construct the prompt. This is model-specific and Ollama supports all kinds of different models and fine-tunes, so it's best if you write your own prompt like the following example:

```lua
local cassandra_ai = require('cassandra_ai.config')

cassandra_ai:setup({
  max_lines = 100,
  provider = 'Ollama',
  provider_options = {
    model = 'qwen2.5-coder:7b-base-q6_K',
    prompt = function(lines_before, lines_after)
    -- You may include filetype and/or other project-wise context in this string as well.
    -- Consult model documentation in case there are special tokens for this.
      return "<|fim_prefix|>" .. lines_before .. "<|fim_suffix|>" .. lines_after .. "<|fim_middle|>"
    end,
  },
  notify = true,
  notify_callback = function(msg)
    vim.notify(msg)
  end,
})
```

> [!NOTE]
> It's also worth noting that, for some models (like [qwen2.5-coder](https://github.com/QwenLM/Qwen2.5-Coder)), the base model appears to be better for completion because it only replies with the code, whereas the instruction-tuned variant tends to reply with a piece of Markdown text which cannot be directly used as the completion candidate.

To use Tabby:

```lua
local cassandra_ai = require('cassandra_ai.config')

cassandra_ai:setup({
  max_lines = 1000,
  provider = 'Tabby',
  notify = true,
  provider_options = {
    -- These are optional
    -- user = 'yourusername',
    -- temperature = 0.2,
    -- seed = 'randomstring',
  },
  notify_callback = function(msg)
    vim.notify(msg)
  end,
  ignored_file_types = {
    -- default is not to ignore
    -- uncomment to ignore in lua:
    -- lua = true
  },
})
```

You will also need to make sure you have the Tabby api key in your environment, `TABBY_API_KEY`.


### `notify`

As some completion sources can be quite slow, setting this to `true` will trigger
a notification when a completion starts and ends using `vim.notify`.

### `notify_callback`

The default notify function uses `vim.notify`, but an override can be configured.
For example:

```lua
notify_callback = function(msg)
  require('notify').notify(msg, vim.log.levels.INFO, {
    title = 'OpenAI',
    render = 'compact',
  })
end
```

If you want, you can also configure callbacks for `on_start` and `on_end` events

```lua
notify_callback = {
    on_start = function(msg)
        require('notify').notify(
            msg .. "completion started",
            vim.log.levels.INFO,
            {
                title = 'OpenAI',
                render = 'compact',
            }
        )

        -- do pretty animations or something here
    end,

    on_end = function(msg)
        require('notify').notify(
            msg .. "completion ended",
            vim.log.levels.INFO,
            {
                title = 'OpenAI',
                render = 'compact',
            }
        )

        -- finish pretty animations started above
    end,
}
```

### log_errors

Log any errors that the AI backend returns. Defaults to `true`. This does not
prevent the notification callbacks from being called; you can set this to
`false` to prevent excess noise if you perform other `vim.notify` calls in
your callbacks.

```lua
cassandra_ai:setup({
    log_errors = true,
})
```


### `max_lines`

How many lines of buffer context to use

### `max_timeout_seconds`

Number of seconds before a code completion request is cancelled. This is `--max-time` for `curl`.

example:

```lua
cassandra_ai:setup({
  max_timeout_seconds = 8,
})
```

### `ignored_file_types` `(table: <string:bool>)`

Which file types to ignore. For example:

```lua
local ignored_file_types = {
  html = true,
}
```

`cassandra-ai` will not offer completions when `vim.bo.filetype` is `html`.

## Debugging Information

To retrieve the raw response from the backend, you can set the following option
in `provider_options`:
```lua
provider_options = {
  raw_response_cb = function(response)
    -- the `response` parameter contains the raw response (JSON-like) object.

    vim.notify(vim.inspect(response)) -- show the response as a lua table

    vim.g.ai_raw_response = response -- store the raw response in a global
                                     -- variable so that you can use it
                                     -- somewhere else (like statusline).
  end,
}
```
This provides useful information like context lengths (# of tokens) and
generation speeds (tokens per seconds), depending on your backend.
