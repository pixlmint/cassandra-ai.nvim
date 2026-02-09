local requests = require('cassandra_ai.requests')
local logger = require('cassandra_ai.logger')

local Anthropic = requests:new(nil)

function Anthropic:new(o)
  o = o or {}
  setmetatable(o, self)
  self.__index = self
  self.params = vim.tbl_deep_extend('keep', o or {}, {
    base_url = 'https://api.anthropic.com',
    messages_endpoint = '/v1/messages',
    model = 'claude-sonnet-4-5-20250929',
    api_key_env = 'ANTHROPIC_API_KEY',
    max_tokens = 1024,
    anthropic_version = '2023-06-01',
    extra_headers = {},
    temperature = nil,
  })

  local api_key = os.getenv(self.params.api_key_env)
  if not api_key then
    vim.schedule(function()
      vim.notify(self.params.api_key_env .. ' environment variable not set', vim.log.levels.ERROR)
    end)
    api_key = 'NO_KEY'
  end

  self.headers = {
    'x-api-key: ' .. api_key,
    'anthropic-version: ' .. self.params.anthropic_version,
  }
  for _, h in ipairs(self.params.extra_headers) do
    table.insert(self.headers, h)
  end

  return o
end

--- No model discovery for Anthropic
--- @param cb fun(model_info: table|nil)
function Anthropic:resolve_model(cb)
  cb(nil)
end

--- Complete a prompt using the Anthropic Messages API
--- @param prompt_data PromptData
--- @param cb function
--- @param request_opts? table
--- @return table|nil job handle
function Anthropic:complete(prompt_data, cb, request_opts)
  request_opts = request_opts or {}

  local messages = {}
  local system_content = nil

  if prompt_data.mode == 'chat' then
    -- Extract system message from the messages array (Anthropic uses top-level 'system' field)
    for _, msg in ipairs(prompt_data.messages) do
      if msg.role == 'system' then
        system_content = msg.content
      else
        table.insert(messages, { role = msg.role, content = msg.content })
      end
    end
  elseif prompt_data.mode == 'fim' then
    -- FIM not natively supported by Anthropic; wrap as a chat prompt
    system_content = 'You are a code completion assistant. Given a code prefix and suffix, output ONLY the code that should go between them. Do not include any explanation.'
    local user_msg = 'Complete the code between the prefix and suffix.\n\nPrefix:\n' .. (prompt_data.prefix or '') .. '\n\nSuffix:\n' .. (prompt_data.suffix or '')
    table.insert(messages, { role = 'user', content = user_msg })
  else
    logger.error('anthropic: unknown prompt mode: ' .. tostring(prompt_data.mode))
    return nil
  end

  local data = {
    model = self.params.model,
    max_tokens = self.params.max_tokens,
    messages = messages,
    stream = false,
  }

  if system_content then
    data.system = system_content
  end

  if self.params.temperature then
    data.temperature = self.params.temperature
  end

  local url = self.params.base_url .. self.params.messages_endpoint
  logger.trace('Anthropic:complete() -> ' .. url .. ' mode=' .. prompt_data.mode)

  return self:Post(url, self.headers, data, function(answer)
    local new_data = {}

    if answer.error then
      local err_msg = type(answer.error) == 'table' and (answer.error.message or vim.fn.json_encode(answer.error)) or tostring(answer.error)
      logger.error('anthropic: API error — ' .. err_msg)
      vim.notify('Anthropic API error: ' .. err_msg, vim.log.levels.ERROR)
      return
    end

    if answer.content and type(answer.content) == 'table' and #answer.content > 0 then
      for _, block in ipairs(answer.content) do
        if block.text then
          table.insert(new_data, block.text)
        end
      end
    end

    cb(new_data)
  end)
end

return Anthropic
