local requests = require('cmp_ai.requests')
local formatter = require('cmp_ai.prompt_formatters').formatters

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

function Ollama:configure_model(cb)
  local url = self.params.base_url .. self.params.ps_endpoint
  self:Get(url, self.params.headers, nil, function(data)
    if type(data) == 'table' and data['models'] ~= nil then
      vim.print(url, data)
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
      local model_config = self.params.model_configs[model_to_use]
      model_config.model = model_to_use
      cb(model_config)
    end
  end)
end

function Ollama:complete(lines_before, lines_after, cb)
  self:configure_model(function(model_config)
    vim.print(model_config)
    local prompt = model_config.prompt or formatter.ollama_code
    local data = {
      model = model_config.model,
      keep_alive = self.params.keep_alive,
      stream = false,
      options = model_config.options,
    }

    -- if self.params.system then
    --   table.insert(messages, {
    --     role = "system",
    --     message = self.params.system(vim.bo.filetype)
    --   })
    -- end

    local formatted_prompt = prompt(lines_before, lines_after)

    -- if type(formatted_prompt) == 'table' then
    data = vim.tbl_deep_extend('force', data, formatted_prompt)
    -- else
    --   table.insert(messages, {
    --     role = "user",
    --     content = prompt(lines_before, lines_after),
    --   })
    --   data.messages = messages
    -- end

    vim.print(data)

    self:Post(self.params.base_url .. self.params.generate_endpoint, self.params.headers, data, function(answer)
      local new_data = {}
      if answer.error ~= nil then
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
          vim.notify('Unable to get result from ollama response: ' .. vim.fn.json_encode(answer), vim.log.levels.ERROR)
          return
        end
        local result = result_content:gsub('<EOT>', '')
        table.insert(new_data, result)
      end
      cb(new_data)
    end)
  end)
end

function Ollama:test()
  self:complete('def factorial(n)\n    if', '    return ans\n', function(data)
    dump(data)
  end)
end

return Ollama
