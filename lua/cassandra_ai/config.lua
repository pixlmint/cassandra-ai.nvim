local M = {}

local conf = {
  max_lines = 50,
  -- Strategy to use for extracting code that should be sent to the model
  -- Options:
  --    lines: Just grab a preset maximum number of lines (defined by max_lines)
  --    smart: For example when writing a function, only include the
  --           function body and doc comment
  surround_extractor_strategy = 'lines',   -- lines | smart
  -- List of additional context providers
  -- Builtin options:
  --    - diagnostics: Show LSP diagnostics in the current file
  --    - metadata: git branch name, project name, filename...
  --    - LSP completions
  extra_context_providers = {},
  provider = 'Ollama',
  provider_options = {},
  notify = true,
  notify_callback = function(msg)
    vim.notify(msg)
  end,
  ignored_file_types = {
    -- default is not to ignore
    -- uncomment to ignore in lua:
    -- lua = true
  },

  log_errors = true,

  -- Data collection (opt-in)
  collect_data = false,
  data_file = vim.fn.stdpath('data') .. '/cassandra-ai/completions.jsonl',
  data_buffer_size = 50,

  -- Context providers configuration
  context_providers = {
    providers = {},
    merge_strategy = 'concat', -- 'concat' | 'weighted' | 'custom'
    custom_merger = nil,
    timeout_ms = 500,
  },

  -- Inline completion configuration (managed by inline.lua)
  inline = {
    debounce_ms = 150,
    auto_trigger = true,
    highlight = 'Comment',
    keymap = {
      accept = '<Tab>',
      dismiss = '<C-]>',
      next = '<M-]>',
      prev = '<M-[>',
    },
  },
}

function M:setup(params)
  -- Store the old provider name if it exists
  local old_provider_name = nil
  if type(conf.provider) == 'table' and conf.provider.name then
    old_provider_name = conf.provider.name
  end

  conf = vim.tbl_deep_extend('force', conf, params)

  -- Determine the new provider name
  local new_provider_name = type(conf.provider) == 'string' and conf.provider or conf.provider.name

  -- Only reinitialize if the provider changed or if it's not initialized yet
  if type(conf.provider) == 'string' or (old_provider_name and old_provider_name ~= new_provider_name) then
    local provider_name = type(conf.provider) == 'string' and conf.provider or conf.provider.name
    if provider_name:lower() ~= 'ollama' then
      vim.notify_once("Going forward, " .. provider_name .. " is no longer maintained by pixlmint/cassandra-ai. Pin your plugin to tag `v1`, or fork the repo to handle maintenance yourself.", vim.log.levels.WARN)
    end
    local status, provider = pcall(require, 'cassandra_ai.backends.' .. provider_name:lower())
    if status then
      conf.provider = provider:new(conf.provider_options)
      conf.provider.name = provider_name

      if old_provider_name and old_provider_name ~= provider_name then
        vim.notify('Switched provider from ' .. old_provider_name .. ' to ' .. provider_name, vim.log.levels.INFO)
      end
    else
      vim.notify('Bad provider in config: ' .. provider_name, vim.log.levels.ERROR)
    end
  end

  -- Initialize logger if data collection is enabled
  if conf.collect_data then
    local logger = require('cassandra_ai.logger')
    logger:init({
      enabled = true,
      data_file = conf.data_file,
      buffer_size = conf.data_buffer_size,
    })
  end

  -- Initialize context providers if any are configured
  if conf.context_providers and conf.context_providers.providers and #conf.context_providers.providers > 0 then
    local context_manager = require('cassandra_ai.context')
    context_manager.setup(conf.context_providers)
  end
end

function M:get(what)
  return conf[what]
end

return M
