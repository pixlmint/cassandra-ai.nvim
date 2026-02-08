--- Context Provider Manager
--- Orchestrates multiple context providers and merges their results
local async = require('plenary.async')
local logger = require('cassandra_ai.logger')

local M = {}

--- Default configuration
local default_config = {
  providers = {},
  merge_strategy = 'concat', -- 'concat' | 'weighted' | 'custom'
  custom_merger = nil,
  timeout_ms = 5000,
}

local config = vim.deepcopy(default_config)
local registered_providers = {}

--- Initialize the context manager with configuration
--- @param user_config table|nil User configuration
function M.setup(user_config)
  config = vim.tbl_deep_extend('force', default_config, user_config or {})
  registered_providers = {}

  -- Initialize built-in and custom providers
  for _, provider_config in ipairs(config.providers or {}) do
    -- Handle both string format ('lsp') and table format ({ name = 'lsp', ... })
    if type(provider_config) == 'string' then
      -- Simple string format: just the provider name
      M.register_provider({
        name = provider_config,
        enabled = true,
        opts = {},
      })
    elseif type(provider_config) == 'table' then
      -- Table format: full configuration
      if provider_config.enabled ~= false then  -- Register unless explicitly disabled
        M.register_provider(provider_config)
      end
    end
  end
end

--- Register a context provider
--- @param provider_config table Provider configuration
---   - name: string - Provider name (for built-in providers)
---   - provider: table|function - Provider instance or constructor function
---   - opts: table - Provider-specific options
function M.register_provider(provider_config)
  local provider_instance

  if provider_config.provider then
    -- Custom provider (function or instance)
    if type(provider_config.provider) == 'function' then
      -- Wrap function in a provider object
      local BaseContextProvider = require('cassandra_ai.context.base')
      provider_instance = BaseContextProvider:new(provider_config.opts or {})
      provider_instance.get_context = function(self, params, callback)
        provider_config.provider(params.bufnr, params.cursor_pos, callback)
      end
      provider_instance.get_name = function() return provider_config.name or 'custom' end
    else
      -- Already a provider instance
      provider_instance = provider_config.provider
    end
  else
    -- Built-in provider - load by name
    local status, ContextProvider = pcall(require, 'cassandra_ai.context.' .. provider_config.name)
    if not status then
      logger.warn('context: failed to load provider "' .. provider_config.name .. '": ' .. tostring(ContextProvider))
      vim.notify(
        'cassandra-ai: Failed to load context provider "' .. provider_config.name .. '": ' .. ContextProvider,
        vim.log.levels.WARN
      )
      return
    end
    provider_instance = ContextProvider:new(provider_config.opts or {})
  end

  -- Check if provider is available
  if provider_instance:is_available() then
    local name = provider_config.name or provider_instance:get_name()
    logger.debug('context: registered provider "' .. name .. '" (priority=' .. (provider_config.priority or 10) .. ')')
    table.insert(registered_providers, {
      instance = provider_instance,
      priority = provider_config.priority or 10,
      name = name,
    })
  else
    local name = provider_config.name or 'custom'
    logger.debug('context: provider "' .. name .. '" not available in this environment')
    vim.notify(
      'cassandra-ai: Context provider "' .. name .. '" is not available in this environment',
      vim.log.levels.DEBUG
    )
  end
end

--- Merge multiple context results using configured strategy
--- @param contexts table[] Array of context results
--- @return string Merged context
local function merge_contexts(contexts)
  if #contexts == 0 then
    return ''
  end

  if config.merge_strategy == 'custom' and config.custom_merger then
    return config.custom_merger(contexts)
  elseif config.merge_strategy == 'weighted' then
    -- Sort by priority and concatenate
    table.sort(contexts, function(a, b)
      return (a.priority or 10) < (b.priority or 10)
    end)
    local parts = {}
    for _, ctx in ipairs(contexts) do
      if ctx.content and ctx.content ~= '' then
        table.insert(parts, ctx.content)
      end
    end
    return table.concat(parts, '\n\n')
  else
    -- Default: simple concatenation
    local parts = {}
    for _, ctx in ipairs(contexts) do
      if ctx.content and ctx.content ~= '' then
        table.insert(parts, ctx.content)
      end
    end
    return table.concat(parts, '\n\n')
  end
end


--- @class ContextParameterParams
--- @field bufnr number
--- @field cursor_pos table
--- @field lines_before string
--- @field lines_after string
--- @field filetype string

--- Gather context from all registered providers
--- @param params ContextParameterParams
--- @param callback function Callback to invoke with merged context
---   Callback signature: function(merged_context: string)
function M.gather_context(params, callback)
  local results = {}
  local completed = 0
  local total = #registered_providers
  local timeout_timer
  local timed_out = false

  -- Callback wrapper to collect results
  local function collect_result(provider_name, priority)
    return function(result)
      if timed_out then return end

      completed = completed + 1

      if result and result.content then
        table.insert(results, {
          content = result.content,
          metadata = result.metadata or {},
          source = provider_name,
          priority = priority,
        })
      end

      -- All providers completed
      if completed >= total then
        if timeout_timer then
          vim.fn.timer_stop(timeout_timer)
        end
        local merged = merge_contexts(results)
        callback(merged)
      end
    end
  end

  logger.trace('context.gather_context() -> ' .. total .. ' provider(s)')

  -- Set timeout
  timeout_timer = vim.fn.timer_start(config.timeout_ms, function()
    if not timed_out then
      timed_out = true
      logger.warn('context: timed out after ' .. config.timeout_ms .. 'ms (' .. completed .. '/' .. total .. ' completed)')
      -- Call callback with whatever we have
      local merged = merge_contexts(results)
      callback(merged)
    end
  end)

  -- Gather from all providers in parallel
  for _, provider_data in ipairs(registered_providers) do
    local provider = provider_data.instance
    local success, err = pcall(function()
      provider:get_context(params, collect_result(provider_data.name, provider_data.priority))
    end)

    if not success then
      logger.error('context: error in provider "' .. provider_data.name .. '": ' .. tostring(err))
      vim.notify(
        'cassandra-ai: Error in context provider "' .. provider_data.name .. '": ' .. tostring(err),
        vim.log.levels.WARN
      )
      -- Count as completed to avoid hanging
      completed = completed + 1
    end
  end
end

--- Check if context providers are enabled
--- @return boolean
function M.is_enabled()
  return #registered_providers > 0
end

--- Get current configuration
--- @return table
function M.get_config()
  return vim.deepcopy(config)
end

--- Get list of registered providers
--- @return table[]
function M.get_providers()
  return vim.deepcopy(registered_providers)
end

return M
