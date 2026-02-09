local requests = require('cassandra_ai.requests')
local logger = require('cassandra_ai.logger')

local Ollama = requests:new(nil)

function Ollama:new(o)
  o = o or {}
  setmetatable(o, self)
  self.__index = self
  self.params = vim.tbl_deep_extend('keep', o or {}, {
    base_url = 'http://127.0.0.1:11434',
    generate_endpoint = '/api/generate',
    chat_endpoint = '/api/chat',
    ps_endpoint = '/api/ps',
    default_model = 'codellama:7b-code',
    model_configs = {},
    headers = {},
  })

  -- Migrate legacy 'prompt' key to 'formatter' in model_configs
  for name, cfg in pairs(self.params.model_configs) do
    if cfg.prompt and not cfg.formatter then
      logger.warn('ollama: model_configs["' .. name .. '"].prompt is deprecated, use .formatter instead')
      cfg.formatter = cfg.prompt
      cfg.prompt = nil
    end
  end

  if self.params.auto_unload then
    vim.api.nvim_create_autocmd('VimLeave', {
      callback = function()
        self:Get(self.params.base_url, {}, { model = self.params.model, keep_alive = 0 }, function() end)
      end,
      group = vim.api.nvim_create_augroup('CmpAIOllama', { clear = true }),
    })
  end
  return o
end

--- @class ModelInfo
--- @field model string
--- @field formatter? function
--- @field options? table

--- Set a model override, bypassing automatic model selection
--- @param model_name string|nil Model name to use, or nil/"auto" to clear
function Ollama:set_model_override(model_name)
  if model_name == nil or model_name == 'auto' then
    self.params.model_override = nil
  else
    self.params.model_override = model_name
  end
end

--- Resolve the current model and its configuration
--- @param cb fun(model_info: ModelInfo|nil)
function Ollama:resolve_model(cb)
  -- If a model override is set, use it directly
  if self.params.model_override then
    local model = self.params.model_override
    local model_config = self.params.model_configs[model]
    local model_info = {
      model = model,
      formatter = model_config and model_config.formatter or nil,
      options = model_config and model_config.options or {},
    }
    logger.trace('Ollama:resolve_model() -> override ' .. model)
    cb(model_info)
    return
  end

  local url = self.params.base_url .. self.params.ps_endpoint
  logger.trace('Ollama:resolve_model()')
  self:Get(url, self.params.headers, nil, function(data)
    if type(data) == 'table' and data['models'] ~= nil then
      local viable_models = {}
      local default_model_loaded = false
      for _, mi in pairs(data['models']) do
        if self.params.model_configs[mi['model']] ~= nil then
          table.insert(viable_models, mi['model'])
          self.params.model_configs[mi['model']].options = self.params.model_configs[mi['model']].options or {}
          self.params.model_configs[mi['model']].options.num_ctx = mi['context_length']
        end
        if mi['model'] == self.params.default_model then
          default_model_loaded = true
        end
      end

      local model_to_use
      if #viable_models == 0 or default_model_loaded then
        model_to_use = self.params.default_model
      else
        model_to_use = viable_models[1]
      end
      logger.trace('Ollama:resolve_model() -> selected ' .. model_to_use)

      local model_config = self.params.model_configs[model_to_use] or {}
      cb({
        model = model_to_use,
        formatter = model_config.formatter or nil,
        options = model_config.options or {},
      })
    else
      logger.warn('ollama: /api/ps returned unexpected data')
      cb(nil)
    end
  end)
end

--- Complete a prompt using the Ollama API
--- @param prompt_data PromptData
--- @param cb function
--- @param request_opts? ModelInfo
--- @return table|nil job handle
function Ollama:complete(prompt_data, cb, request_opts)
  request_opts = request_opts or {}
  local model = request_opts.model or self.params.default_model

  local data = {
    model = model,
    keep_alive = self.params.keep_alive,
    stream = false,
    options = request_opts.options or {},
  }

  local endpoint
  if prompt_data.mode == 'fim' then
    data.prompt = prompt_data.prefix
    data.suffix = prompt_data.suffix
    endpoint = self.params.generate_endpoint
  elseif prompt_data.mode == 'chat' then
    data.messages = prompt_data.messages
    endpoint = self.params.chat_endpoint
  else
    logger.error('ollama: unknown prompt mode: ' .. tostring(prompt_data.mode))
    return nil
  end

  logger.trace('Ollama:complete() -> model=' .. model .. ' mode=' .. prompt_data.mode)
  return self:Post(self.params.base_url .. endpoint, self.params.headers, data, function(answer)
    local new_data = {}
    if answer.error ~= nil then
      logger.error('ollama: API error — ' .. answer.error)
      return
    end

    if answer.done or answer.message or answer.response then
      local result_content
      if answer.message ~= nil and answer.message.content ~= nil then
        result_content = answer.message.content
      elseif answer.response ~= nil then
        result_content = answer.response
      else
        logger.error('ollama: unexpected response format: ' .. vim.fn.json_encode(answer))
        return
      end
      local result = result_content:gsub('<EOT>', '')
      table.insert(new_data, result)
    end
    cb(new_data)
  end)
end

return Ollama
