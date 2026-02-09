local requests = require('cassandra_ai.requests')
local logger = require('cassandra_ai.logger')

local OpenAICompat = requests:new(nil)

function OpenAICompat:new(o)
  o = o or {}
  setmetatable(o, self)
  self.__index = self
  self.params = vim.tbl_deep_extend('keep', o or {}, {
    base_url = 'https://api.openai.com/v1',
    chat_endpoint = '/chat/completions',
    completions_endpoint = '/completions',
    model = 'gpt-4',
    api_key_env = 'OPENAI_API_KEY',
    auth_header_format = 'Bearer %s',
    extra_headers = {},
    temperature = 0.1,
    max_tokens = nil,
    n = 1,
  })

  local api_key = os.getenv(self.params.api_key_env)
  if not api_key then
    vim.schedule(function()
      vim.notify(self.params.api_key_env .. ' environment variable not set', vim.log.levels.ERROR)
    end)
    api_key = 'NO_KEY'
  end

  self.headers = {}
  table.insert(self.headers, 'Authorization: ' .. string.format(self.params.auth_header_format, api_key))
  for _, h in ipairs(self.params.extra_headers) do
    table.insert(self.headers, h)
  end

  return o
end

--- No model discovery for OpenAI-compatible providers
--- @param cb fun(model_info: table|nil)
function OpenAICompat:resolve_model(cb)
  cb(nil)
end

--- Complete a prompt using the OpenAI-compatible API
--- @param prompt_data PromptData
--- @param cb function
--- @param request_opts? table
--- @return table|nil job handle
function OpenAICompat:complete(prompt_data, cb, request_opts)
  request_opts = request_opts or {}

  local data = {
    model = self.params.model,
    temperature = self.params.temperature,
    n = self.params.n,
    stream = false,
  }

  if self.params.max_tokens then
    data.max_tokens = self.params.max_tokens
  end

  local endpoint
  if prompt_data.mode == 'chat' then
    data.messages = prompt_data.messages
    endpoint = self.params.chat_endpoint
  elseif prompt_data.mode == 'fim' then
    data.prompt = prompt_data.prefix
    if prompt_data.suffix then
      data.suffix = prompt_data.suffix
    end
    endpoint = self.params.completions_endpoint
  else
    logger.error('openai_compat: unknown prompt mode: ' .. tostring(prompt_data.mode))
    return nil
  end

  local url = self.params.base_url .. endpoint
  logger.trace('OpenAICompat:complete() -> ' .. url .. ' mode=' .. prompt_data.mode)

  return self:Post(url, self.headers, data, function(answer)
    local new_data = {}
    if answer.error then
      local err_msg = type(answer.error) == 'table' and (answer.error.message or vim.fn.json_encode(answer.error)) or tostring(answer.error)
      logger.error('openai_compat: API error — ' .. err_msg)
      vim.notify('OpenAI-compatible API error: ' .. err_msg, vim.log.levels.ERROR)
      return
    end

    if answer.choices then
      for _, choice in ipairs(answer.choices) do
        local text
        if choice.message and choice.message.content then
          text = choice.message.content
        elseif choice.text then
          text = choice.text
        end
        if text then
          table.insert(new_data, text)
        end
      end
    end
    cb(new_data)
  end)
end

return OpenAICompat
