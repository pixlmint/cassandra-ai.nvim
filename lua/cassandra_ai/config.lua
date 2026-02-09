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
  -- Prompt formatter: 'chat', 'fim', or a function(before, after, opts, ctx) -> PromptData
  -- nil means adapter/model decides
  formatter = nil,
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

  -- File logging
  log_file = vim.fn.stdpath('data') .. '/cassandra-ai/cassandra-ai.log',
  log_level = 'WARN', -- TRACE | DEBUG | INFO | WARN | ERROR

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

--- Resolve a formatter value (string or function) to an actual function
--- @param fmt string|function|nil
--- @return function|nil
local function resolve_formatter(fmt)
  if fmt == nil then
    return nil
  end
  if type(fmt) == 'function' then
    return fmt
  end
  if type(fmt) == 'string' then
    local formatters = require('cassandra_ai.prompt_formatters')
    if formatters[fmt] then
      return formatters[fmt]
    end
    -- Also check the legacy .formatters table
    if formatters.formatters[fmt] then
      return formatters.formatters[fmt]
    end
    local logger = require('cassandra_ai.logger')
    logger.warn('config: unknown formatter "' .. fmt .. '", falling back to nil')
    return nil
  end
  return nil
end

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
    log_file = conf.log_file,
    log_level = conf.log_level,
  })

  logger.trace('config:setup()')

  -- Resolve formatter string to function
  conf.formatter = resolve_formatter(conf.formatter)

  -- Determine the new provider name
  local new_provider_name = type(conf.provider) == 'string' and conf.provider or conf.provider.name

  -- Only reinitialize if the provider changed or if it's not initialized yet
  if type(conf.provider) == 'string' or (old_provider_name and old_provider_name ~= new_provider_name) then
    local provider_name = type(conf.provider) == 'string' and conf.provider:lower() or conf.provider.name:lower()
    logger.trace('config:setup() -> loading adapter: ' .. provider_name)
    -- Try adapters/ first, fall back to backends/ for backward compat
    local status, provider = pcall(require, 'cassandra_ai.adapters.' .. provider_name)
    if not status then
      status, provider = pcall(require, 'cassandra_ai.backends.' .. provider_name)
    end
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

  -- Initialize telemetry if data collection is enabled
  if conf.collect_data then
    logger.debug('telemetry enabled, data file: ' .. conf.data_file)
    local telemetry = require('cassandra_ai.telemetry')
    telemetry:init({
      enabled = true,
      data_file = conf.data_file,
      buffer_size = conf.data_buffer_size,
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
