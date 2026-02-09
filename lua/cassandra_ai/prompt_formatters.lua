local logger = require('cassandra_ai.logger')

local M = {}

--- @class PromptData
--- @field mode 'chat'|'fim'
--- @field messages? {role: string, content: string}[]  -- chat mode
--- @field prefix? string   -- fim mode: text before cursor
--- @field suffix? string   -- fim mode: text after cursor

--- Chat-style prompt formatter (for general chat models)
--- @param lines_before string
--- @param lines_after string
--- @param opts? {filetype?: string}
--- @param additional_context? string
--- @return PromptData
M.chat = function(lines_before, lines_after, opts, additional_context)
  opts = opts or { filetype = vim.bo.filetype }
  local ft = opts.filetype or vim.bo.filetype

  local user_message = string.format('<code_prefix>%s</code_prefix><code_suffix>%s</code_suffix><code_middle>', lines_before, lines_after)

  local system = [=[You are a coding companion.
You need to suggest code for the language ]=] .. ft .. [=[

Given some code prefix and suffix for context, output code which should follow the prefix code.
You should only output valid code in the language ]=] .. ft .. [=[
. to clearly define a code block, including white space, we will wrap the code block
with tags.
Make sure to respect the white space and indentation rules of the language.
Do not output anything in plain language, make sure you only use the relevant programming language verbatim.
For example, consider the following request:
<code_prefix>def print_hello():</code_prefix><code_suffix>\n    return</code_suffix><code_middle>
Your answer should be:

    print("Hello")</code_middle>
]=]

  if additional_context and additional_context ~= '' then
    system = system .. "\nAdditional Context for the current code section (use this to provider better informed completions):\n" .. additional_context
  end

  local messages = {}
  table.insert(messages, { role = 'system', content = system })
  table.insert(messages, { role = 'user', content = user_message })

  return { mode = 'chat', messages = messages }
end

--- FIM (fill-in-the-middle) prompt formatter
--- @param lines_before string
--- @param lines_after string
--- @param opts? table
--- @param additional_context? string
--- @return PromptData
M.fim = function(lines_before, lines_after, opts, additional_context)
  return { mode = 'fim', prefix = lines_before, suffix = lines_after }
end

-- Backward-compatible formatters table with deprecation warnings
M.formatters = setmetatable({
  chat = M.chat,
  fim = M.fim,
}, {
  __index = function(_, key)
    local aliases = {
      general_ai = 'chat',
      ollama_code = 'fim',
      santacoder = 'fim',
      codestral = 'fim',
    }
    if aliases[key] then
      logger.warn('prompt_formatters: "' .. key .. '" is deprecated, use "' .. aliases[key] .. '" instead')
      return aliases[key] == 'chat' and M.chat or M.fim
    end
    return nil
  end,
})

return M
