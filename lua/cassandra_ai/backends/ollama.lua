local requests = require('cassandra_ai.requests')
local formatter = require('cassandra_ai.prompt_formatters').formatters
local logger = require('cassandra_ai.logger')

Ollama = requests:new(nil)

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
    -- an associative table of models and their configuration
    -- before each generation, we'll check which model is loaded,
    -- and if it isn't the default one, but one from this table,
    -- we'll use that instead
    model_configs = {},
    headers = {},
  })

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

--- @class ModelConfig
--- @field prompt fun(lines_before: string, lines_after: string, opts: table, additional_context?: string)
--- @field model string
--- @field options table

--- @param cb fun(model_config: ModelConfig)
function Ollama:get_model(cb)
  -- TODO: This function should be better equipped to deal with a timeout/ bad response
  -- TODO: Implement caching
  local url = self.params.base_url .. self.params.ps_endpoint
  logger.trace('Ollama:get_model()')
  self:Get(url, self.params.headers, nil, function(data)
    if type(data) == 'table' and data['models'] ~= nil then
      local viable_models = {}
      local default_model_loaded = false
      for _, model_info in pairs(data['models']) do
        if self.params.model_configs[model_info['model']] ~= nil then
          table.insert(viable_models, model_info['model'])
          self.params.model_configs[model_info['model']].options.num_ctx = model_info['context_length']
        end
        if model_info['model'] == self.params.default_model then
          default_model_loaded = true
        end
      end

      local model_to_use
      if #viable_models == 0 or default_model_loaded then
        model_to_use = self.params.default_model
      else
        model_to_use = viable_models[1]
      end
      logger.trace('Ollama:get_model() -> selected ' .. model_to_use)
      local model_config = self.params.model_configs[model_to_use]
      model_config.model = model_to_use
      cb(model_config)
    else
      logger.warn('ollama: /api/ps returned unexpected data')
    end
  end)
end

function Ollama:complete(prompt, cb, model_config)
  local data = {
    model = model_config.model,
    keep_alive = self.params.keep_alive,
    stream = false,
    options = model_config.options,
  }

  data = vim.tbl_deep_extend('force', data, prompt)

  logger.trace('Ollama:complete() -> model=' .. model_config.model)
  return self:Post(self.params.base_url .. self.params.generate_endpoint, self.params.headers, data, function(answer)
    local new_data = {}
    if answer.error ~= nil then
      logger.error('ollama: API error — ' .. answer.error)
      vim.notify('Ollama error: ' .. answer.error, vim.log.levels.ERROR)
      return
    end

    if answer.done then
      local result_content
      if answer.message ~= nil and answer.message.content ~= nil then
        result_content = answer.message.content
      elseif answer.response ~= nil then
        result_content = answer.response
      else
        logger.error('ollama: unexpected response format: ' .. vim.fn.json_encode(answer))
        vim.notify('Unable to get result from ollama response: ' .. vim.fn.json_encode(answer), vim.log.levels.ERROR)
        return
      end
      local result = result_content:gsub('<EOT>', '')
      table.insert(new_data, result)
    end
    cb(new_data)
  end)
end

function Ollama:test()
  self:complete('def factorial(n)\n    if', '    return ans\n', function(data)
    dump(data)
  end)
end

return Ollama
