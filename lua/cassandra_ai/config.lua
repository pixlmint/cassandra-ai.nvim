local M = {}

local conf = {
  max_lines = 50,
  -- Strategy to use for extracting code that should be sent to the model
  -- Options:
  --    lines: Just grab a preset maximum number of lines (defined by max_lines)
  --    smart: For example when writing a function, only include the
  --           function body and doc comment
  surround_extractor_strategy = 'lines', -- lines | smart
  -- List of additional context providers
  -- Builtin options:
  --    - diagnostics: Show LSP diagnostics in the current file
  --    - metadata: git branch name, project name, filename...
  --    - LSP completions
  extra_context_providers = {},
  provider = 'Ollama',
  provider_options = {},

  ignored_file_types = {
    -- default is not to ignore
    -- uncomment to ignore in lua:
    -- lua = true
  },

  logging = {
    level = 'WARN', -- TRACE | DEBUG | INFO | WARN | ERROR (set to nil to disable logging)
    file = vim.fn.stdpath('data') .. '/cassandra-ai/cassandra-ai.log',
  },

  telemetry = {
    enabled = false,
    file = vim.fn.stdpath('data') .. '/cassandra-ai/completions.jsonl',
    buffer_size = 50,
  },

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
      regenerate = '<C-<>',
    },
  },
}

function M:setup(params)
  params = params or {}

  -- Store the old provider name if it exists
  local old_provider_name = nil
  if type(conf.provider) == 'table' and conf.provider.name then
    old_provider_name = conf.provider.name
  end

  conf = vim.tbl_deep_extend('force', conf, params)

  -- Initialize logger first so other setup steps can log
  local logger = require('cassandra_ai.logger')
  logger.init({
    log_file = conf.logging.file,
    log_level = conf.logging.level,
  })

  logger.trace('config:setup()')

  require('cassandra_ai.inline').setup(conf.inline)

  -- Determine the new provider name
  local new_provider_name = type(conf.provider) == 'string' and conf.provider or conf.provider.name

  -- Only reinitialize if the provider changed or if it's not initialized yet
  if type(conf.provider) == 'string' or (old_provider_name and old_provider_name ~= new_provider_name) then
    local provider_name = type(conf.provider) == 'string' and conf.provider:lower() or conf.provider.name:lower()
    logger.trace('config:setup() -> loading adapter: ' .. provider_name)
    local status, provider = pcall(require, 'cassandra_ai.adapters.' .. provider_name)
    if status then
      conf.provider = provider:new(conf.provider_options)
      conf.provider.name = provider_name
      logger.debug('provider loaded: ' .. provider_name)

      if old_provider_name and old_provider_name:lower() ~= provider_name then
        logger.info('switched provider from ' .. old_provider_name .. ' to ' .. provider_name)
      end
    else
      logger.error('failed to load provider: ' .. provider_name .. ' — ' .. tostring(provider))
    end
  end

  if conf.provider_options and conf.provider_options.model_configs then
    local formatters = require('cassandra_ai.prompt_formatters')
    for _, model_params in pairs(conf.provider_options.model_configs) do
      if model_params.formatter and type(model_params.formatter) == 'string' then
        if formatters[model_params.formatter] == nil then
          logger.error('Unknown formatter: ' .. model_params.formatter)
        else
          model_params.formatter = formatters[model_params.formatter]
        end
      end
    end
  end

  -- Initialize telemetry if data collection is enabled
  if conf.telemetry.enabled then
    logger.debug('telemetry enabled, data file: ' .. conf.telemetry.file)
    local telemetry = require('cassandra_ai.telemetry')
    telemetry:init({
      enabled = true,
      data_file = conf.telemetry.file,
      buffer_size = conf.telemetry.buffer_size,
    })
  end

  -- Initialize context providers if any are configured
  if conf.context_providers and conf.context_providers.providers and #conf.context_providers.providers > 0 then
    logger.debug('initializing context providers: ' .. #conf.context_providers.providers .. ' configured')
    local context_manager = require('cassandra_ai.context')
    context_manager.setup(conf.context_providers)
  end

  logger.debug('cassandra-ai setup complete')
end

function M:get(what)
  return conf[what]
end

function M:set(key, value)
  conf[key] = value
end

return M
