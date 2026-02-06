local requests = require('cassandra_ai.requests')
local async = require('plenary.async')
local formatters = require('cassandra_ai.prompt_formatters').formatters

OpenWebUI = requests:new(nil)

--- @deprecated only ollama is maintained going forward
function OpenWebUI:new(o)
  o = o or {}
  setmetatable(o, self)
  self.__index = self
  self.params = vim.tbl_deep_extend('keep', o or {}, {
    model_params = {
      model = 'codegemma-2b',
      temperature = 0.1,
      max_tokens = 100,
    },
    prompt = formatters.fim,
  })
  self.api_key = o.api_key or nil
  self.url = o.url or nil

  if not self.url then
    vim.notify("No url specified for openwebui", vim.log.levels.ERROR)
    return
  end
  if not self.api_key then
    vim.notify("No api key specified for openwebui", vim.log.levels.ERROR)
    return
  end

  self.headers = {
    'Authorization: Bearer ' .. self.api_key,
  }
  return o
end

local function json_encode(data)
  local status, result = pcall(vim.fn.json_encode, data)
  if status then
    return result
  else
    return nil, result
  end
end

function OpenWebUI:complete(lines_before, lines_after, cb)
  local data = {
    messages = {
      {
        role = "system",
        content = "",
      },
      {
        role = "user",
        content = self.params.prompt(lines_before, lines_after),
      }
    },
  }

  data = vim.tbl_extend('force', data, self.params.model_params)

  return self:Post(self.params.url, self.headers, json_encode(data), function(answer)
    if self.params.raw_response_cb ~= nil and type(self.params.raw_response_cb) == 'function' then
      async.run(function()
        self.params.raw_response_cb(answer)
      end)
    end
    local new_data = {}
    if answer.choices then
      for _, response in ipairs(answer.choices) do
        local entry = response.message.content
        entry = entry:gsub('<|file_separator|>', '')
        table.insert(new_data, entry)
      end
    end
    cb(new_data)
  end)
end

return OpenWebUI
