local M = {}

local conf = {
  max_lines = 50,
  run_on_every_keystroke = true,
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
  data_file = vim.fn.stdpath('data') .. '/cmp-ai/completions.jsonl',
  data_buffer_size = 50,

  -- Context providers configuration
  context_providers = {
    providers = {},
    merge_strategy = 'concat', -- 'concat' | 'weighted' | 'custom'
    custom_merger = nil,
    timeout_ms = 500,
  },
}

function M:setup(params)
  -- Store the old provider name if it exists
  local old_provider_name = nil
  if type(conf.provider) == 'table' and conf.provider.name then
    old_provider_name = conf.provider.name
  end

  -- Deep merge configuration, especially for nested tables like context_providers
  for k, v in pairs(params or {}) do
    if k == 'context_providers' and type(v) == 'table' and type(conf[k]) == 'table' then
      -- Deep merge context_providers to preserve defaults
      conf[k] = vim.tbl_deep_extend('force', conf[k], v)
    else
      conf[k] = v
    end
  end

  -- Determine the new provider name
  local new_provider_name = type(conf.provider) == 'string' and conf.provider or conf.provider.name

  -- Only reinitialize if the provider changed or if it's not initialized yet
  if type(conf.provider) == 'string' or (old_provider_name and old_provider_name ~= new_provider_name) then
    local provider_name = type(conf.provider) == 'string' and conf.provider or conf.provider.name
    if provider_name:lower() ~= 'ollama' then
      vim.notify_once("Going forward, " .. provider_name .. " is no longer maintained by pixlmint/cmp-ai. Pin your plugin to tag `v1`, or fork the repo to handle maintenance yourself.", vim.log.levels.WARN)
    end
    local status, provider = pcall(require, 'cmp_ai.backends.' .. provider_name:lower())
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
    local logger = require('cmp_ai.logger')
    logger:init({
      enabled = true,
      data_file = conf.data_file,
      buffer_size = conf.data_buffer_size,
    })
  end

  -- Initialize context providers if any are configured
  if conf.context_providers and conf.context_providers.providers and #conf.context_providers.providers > 0 then
    local context_manager = require('cmp_ai.context_providers')
    context_manager.setup(conf.context_providers)
  end
end

function M:get(what)
  return conf[what]
end

return M
