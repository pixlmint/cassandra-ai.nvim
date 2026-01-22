local M = {}

local conf = {
  max_lines = 50,
  run_on_every_keystroke = true,
  provider = 'HF',
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
}

function M:setup(params)
  -- Store the old provider name if it exists
  local old_provider_name = nil
  if type(conf.provider) == 'table' and conf.provider.name then
    old_provider_name = conf.provider.name
  end

  for k, v in pairs(params or {}) do
    conf[k] = v
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
end

function M:get(what)
  return conf[what]
end

return M
