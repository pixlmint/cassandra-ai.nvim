local requests = require('cassandra_ai.requests')
local formatters = require('cassandra_ai.prompt_formatters').formatters

Claude = requests:new(nil)
BASE_URL = 'https://api.anthropic.com/v1/messages'

--- @deprecated only ollama is maintained going forward
function Claude:new(o, params)
  o = o or {}
  setmetatable(o, self)
  self.__index = self
  self.params = vim.tbl_deep_extend('keep', params or {}, {
    -- Custom params for claude
  })

  self.api_key = os.getenv('CLAUDE_API_KEY')
  if not self.api_key then
    vim.schedule(function()
      vim.notify('CLAUDE_API_KEY environment variable not set', vim.log.levels.ERROR)
    end)
    self.api_key = 'NO_KEY'
  end
  self.headers = {
    'x-api-key: ' .. self.api_key,
  }
  return o
end

function Claude:complete(lines_before, lines_after, cb)
  if not self.api_key then
    vim.schedule(function()
      vim.notify('CLAUDE_API_KEY environment variable not set', vim.log.levels.ERROR)
    end)
    return
  end

  local data = {
    messages = {
      {
        role = 'system',
        content = formatters.general_ai.system(vim.o.filetype),
      },
      {
        role = 'user',
        content = formatters.general_ai.user(lines_before, lines_after),
      },
    },
  }

  data = vim.tbl_deep_extend('keep', data, self.params)
  return self:Get(BASE_URL, self.headers, data, function(answer)
    local new_data = {}
    if answer.choices then
      for _, response in ipairs(answer.choices) do
        local entry = response.message.content:gsub('<end_code_middle>', '')
        entry = entry:gsub('```', '')
        table.insert(new_data, entry)
      end
    end
    cb(new_data)
  end)
end

function Claude:test()
  self:complete('def factorial(n)\n    if', '    return ans\n', function(data)
    dump(data)
  end)
end

return Claude
