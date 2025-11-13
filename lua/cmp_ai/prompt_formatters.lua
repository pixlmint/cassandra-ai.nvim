local M = {}

-- Table of prompt formatters for different providers
M.formatters = {
  -- for general chat models (gpt/claude)
  general_ai = {
    system = function(filetype)
      return [=[You are a coding companion.
You need to suggest code for the language ]=] .. filetype .. [=[
Given some code prefix and suffix for context, output code which should follow the prefix code.
You should only output valid code in the language ]=] .. filetype .. [=[
. to clearly define a code block, including white space, we will wrap the code block
with tags.
Make sure to respect the white space and indentation rules of the language.
Do not output anything in plain language, make sure you only use the relevant programming language verbatim.
For example, consider the following request:
<begin_code_prefix>def print_hello():<end_code_prefix><begin_code_suffix>\n    return<end_code_suffix><begin_code_middle>
Your answer should be:

    print("Hello")<end_code_middle>
]=]
    end,
    user = function(lines_before, lines_after)
      return '<begin_code_prefix>' .. lines_before .. '<end_code_prefix>'
          .. '<begin_code_suffix>' .. lines_after .. '<end_code_suffix><begin_code_middle>'
    end,
  },

  -- Ollama FIM format (no system prompt, uses special tokens)
  ollama_code = function(lines_before, lines_after)
    return '<PRE> ' .. lines_before .. ' <SUF>' .. lines_after .. ' <MID>'
  end,

  santacoder = function(lines_before, lines_after)
    return '<fim-prefix>' .. lines_before .. '<fim-suffix>' .. lines_after .. '<fim-middle>'
  end,

  codestral = function(lines_before, lines_after)
    return '[SUFFIX]' .. lines_before .. '[PREFIX]' .. lines_after
  end,

  -- used for codegemma and qwen
  fim = function(lines_before, lines_after)
    return '<|fim_prefix|>' .. lines_before .. '<|fim_suffix|>' .. lines_after .. '<|fim_middle|>'
  end,
}

return M
