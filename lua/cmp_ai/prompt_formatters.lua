local M = {}


local function chat_formatting(user_msgs, system_msg)
  -- TODO: Add support to also include old assistant messages
  local chat = {}
  if system_msg ~= nil then
    table.insert(chat, {
      role = 'system',
      content = system_msg
    })
  end
  if type(user_msgs) == 'string' then
    user_msgs = { user_msgs }
  end
  for _, msg in pairs(user_msgs) do
    table.insert(chat, {
      role = 'user',
      content = msg,
    })
  end

  return {
    prompt = vim.fn.json_encode(chat),
  }
end

-- Table of prompt formatters for different providers
M.formatters = {
  -- for general chat models (gpt/claude)
  general_ai = function(lines_before, lines_after, opts, additional_context)
    opts = opts or { filetype = vim.bo.filetype }
    additional_context = additional_context or ''

    local user_message = string.format('<code_prefix>%s</code_prefix><code_suffix>%s</code_suffix><code_middle>', lines_before, lines_after)

    -- Add additional context if provided
    if additional_context and additional_context ~= '' then
      user_message = string.format('<additional_context>\n%s\n</additional_context>\n\n%s', additional_context, user_message)
    end

    local system = [=[You are a coding companion.
You need to suggest code for the language ]=] .. opts.filetype .. [=[

Given some code prefix and suffix for context, output code which should follow the prefix code.
You should only output valid code in the language ]=] .. opts.filetype .. [=[
. to clearly define a code block, including white space, we will wrap the code block
with tags.
Make sure to respect the white space and indentation rules of the language.
Do not output anything in plain language, make sure you only use the relevant programming language verbatim.
For example, consider the following request:
<code_prefix>def print_hello():</code_prefix><code_suffix>\n    return</code_suffix><code_middle>
Your answer should be:

    print("Hello")</code_middle>

If additional context is provided (such as LSP diagnostics, treesitter information, or other metadata), use it to inform your completion but do not reference it directly in your output.
]=]
    return chat_formatting(user_message, system)
  end,

  -- Ollama FIM format (no system prompt, uses special tokens)
  ollama_code = function(lines_before, lines_after, opts, additional_context)
    additional_context = additional_context or ''
    local prompt = '<PRE> ' .. lines_before .. ' <SUF>' .. lines_after .. ' <MID>'

    -- Prepend additional context if provided
    if additional_context and additional_context ~= '' then
      prompt = additional_context .. '\n\n' .. prompt
    end

    return chat_formatting(prompt)
  end,

  santacoder = function(lines_before, lines_after, opts, additional_context)
    additional_context = additional_context or ''
    local prompt = '<fim-prefix>' .. lines_before .. '<fim-suffix>' .. lines_after .. '<fim-middle>'

    -- Prepend additional context if provided
    if additional_context and additional_context ~= '' then
      prompt = additional_context .. '\n\n' .. prompt
    end

    return chat_formatting(prompt)
  end,

  codestral = function(lines_before, lines_after, opts, additional_context)
    additional_context = additional_context or ''
    local prompt = '[SUFFIX]' .. lines_before .. '[PREFIX]' .. lines_after

    -- Prepend additional context if provided
    if additional_context and additional_context ~= '' then
      prompt = additional_context .. '\n\n' .. prompt
    end

    return chat_formatting(prompt)
  end,

  -- used for codegemma and qwen
  fim = function(lines_before, lines_after, opts, additional_context)
    additional_context = additional_context or ''

    -- For FIM models, prepend context to the prefix
    local prompt = lines_before
    if additional_context and additional_context ~= '' then
      prompt = additional_context .. '\n\n' .. lines_before
    end

    return {
      prompt = prompt,
      suffix = lines_after,
    }
    -- return '<|fim_prefix|>' .. lines_before .. '<|fim_suffix|>' .. lines_after .. '<|fim_middle|>'
  end,
}

return M
