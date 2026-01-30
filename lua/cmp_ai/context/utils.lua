local M = {}

-- Language-specific patterns for fallback when treesitter unavailable
local patterns = {
  python = {
    comment = '^%s*#',
    class = '^%s*class%s+%w+',
    func = '^%s*def%s+%w+',
    indent = '^%s*',
  },
  php = {
    comment = '^%s*//',
    class = '^%s*class%s+%w+',
    func = '^%s*(public|protected|private|static|function)%s+',
    indent = '^%s*',
  },
  javascript = {
    comment = '^%s*//',
    class = '^%s*class%s+%w+',
    func = '^%s*(async%s+)?function%s+%w+|^%s*(const|let|var)%s+%w+%s*=%s*(async%s+)?%(',
    indent = '^%s*',
  },
}

-- Get language from current buffer
local function get_language()
  local ft = vim.bo.filetype
  if ft == 'python' then return 'python' end
  if ft == 'php' then return 'php' end
  if ft == 'javascript' or ft == 'jsx' or ft == 'typescript' or ft == 'tsx' then
    return 'javascript'
  end
  return nil
end

-- Check if treesitter textobjects is available
local function has_textobjects()
  local ok = pcall(require, 'nvim-treesitter-textobjects.shared')
  return ok
end

-- Check if we're in a comment using treesitter
local function in_comment()
  if not has_textobjects() then return false end
  local textobjects = require('nvim-treesitter-textobjects.shared')
  local comment = textobjects.textobject_at_point('@comment.inner', 'textobjects')
  return comment and #comment > 0
end

-- Check if we're in a function body using treesitter
local function in_function_body()
  if not has_textobjects() then return false end
  local textobjects = require('nvim-treesitter-textobjects.shared')
  local func = textobjects.textobject_at_point('@function.inner', 'textobjects')
  return func and #func > 0
end

-- Check if we're in a class body using treesitter
local function in_class_body()
  if not has_textobjects() then return false end
  local textobjects = require('nvim-treesitter-textobjects.shared')
  local class = textobjects.textobject_at_point('@class.inner', 'textobjects')
  return class and #class > 0
end

-- Check if current line is a class/function definition using regex fallback
local function is_definition(line, lang)
  local pat = patterns[lang]
  if not pat then return false end
  return line:match(pat.class) or line:match(pat.func)
end

-- Check if we're writing a doc comment for class/function
local function is_doc_comment_for_definition()
  if not has_textobjects() then return false end
  local textobjects = require('nvim-treesitter-textobjects.shared')

  -- Check if we're in a comment
  local comment = textobjects.textobject_at_point('@comment.inner', 'textobjects')
  if not comment or #comment == 0 then return false end

  -- Get position right after the comment
  local next_line = comment[4] + 1 -- end line + 1

  -- Check if next line is a class definition
  local class_at_next = textobjects.textobject_at_point('@class.inner', 'textobjects', { next_line, 0 })
  if class_at_next and #class_at_next > 0 then
    return 'comment_class'
  end

  -- Check if next line is a function definition
  local func_at_next = textobjects.textobject_at_point('@function.inner', 'textobjects', { next_line, 0 })
  if func_at_next and #func_at_next > 0 then
    return 'comment_func'
  end

  return false
end

-- Count non-empty, non-comment lines in buffer
local function count_code_lines(bufnr)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local count = 0

  for _, line in ipairs(lines) do
    -- Skip empty lines
    if not line:match('^%s*$') then
      -- Use treesitter to check if it's a comment
      if has_textobjects() then
        local textobjects = require('nvim-treesitter-textobjects.shared')
        local row = vim.api.nvim_win_get_cursor(0)[1] - 1
        local is_comment_now = textobjects.textobject_at_point('@comment.inner', 'textobjects', { row, 0 })
        if not is_comment_now or #is_comment_now == 0 then
          count = count + 1
        end
      else
        -- Fallback to regex
        local lang = get_language()
        if lang and not line:match(patterns[lang].comment) then
          count = count + 1
        end
      end
    end
  end

  return count
end

function M.detect_suggestion_context()
  local lang = get_language()
  if not lang then return 'init' end

  local bufnr = vim.api.nvim_get_current_buf()

  -- Check for new file
  if count_code_lines(bufnr) == 0 then
    return 'init'
  end

  -- Check for doc comment using treesitter
  local doc_type = is_doc_comment_for_definition()
  if doc_type then return doc_type end

  -- Check if we're in a comment
  if in_comment() then
    -- Already handled doc comment case above, so this is just a regular comment
    return 'impl'
  end

  -- Check if we're in a function body
  if in_function_body() then
    return 'impl'
  end

  -- Check if we're in a class body
  if in_class_body() then
    -- Could be writing a method or property
    local current_line = vim.api.nvim_get_current_line()
    if is_definition(current_line, lang) then
      return current_line:match(patterns[lang].class) and 'class' or 'func'
    end
    return 'impl'
  end

  -- Check current line for class/function definitions (fallback)
  local current_line = vim.api.nvim_get_current_line()
  if is_definition(current_line, lang) then
    return current_line:match(patterns[lang].class) and 'class' or 'func'
  end

  -- Default case
  return 'impl'
end

-- Add language pattern for extensibility
function M.add_language(name, lang_patterns)
  patterns[name] = lang_patterns
end

return M
