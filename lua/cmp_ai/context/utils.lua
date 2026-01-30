local M = {}

-- Language-specific patterns for fallback when treesitter unavailable
local patterns = {
  python = {
    class = '^%s*class%s+%w+',
    func = '^%s*def%s+%w+',
    indent = '^%s*',
  },
  php = {
    class = '^%s*class%s+%w+',
    func = '^%s*(public|protected|private|static|function)%s+',
    indent = '^%s*',
  },
  javascript = {
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
  if not has_textobjects() then return false, {} end
  local textobjects = require('nvim-treesitter-textobjects.shared')
  local comment = textobjects.textobject_at_point('@comment.inner', 'textobjects')
  return comment and #comment > 0, comment
end

-- Check if we're in a function body using treesitter
local function in_function_body()
  if not has_textobjects() then return false, {} end
  local textobjects = require('nvim-treesitter-textobjects.shared')
  local func = textobjects.textobject_at_point('@function.inner', 'textobjects')
  return func and #func > 0, func
end

-- Check if we're in a class body using treesitter
local function in_class_body()
  if not has_textobjects() then return false, {} end
  local textobjects = require('nvim-treesitter-textobjects.shared')
  local class = textobjects.textobject_at_point('@class.inner', 'textobjects')
  return class and #class > 0, class
end

-- Check if current line is a class/function definition using pattern
local function is_definition(line, lang)
  local pat = patterns[lang]
  if not pat then return false end
  return line:match(pat.class) or line:match(pat.func)
end

-- Check if we're writing a doc comment for class/function
local function is_doc_comment_for_definition()
  if not has_textobjects() then return false end
  local textobjects = require('nvim-treesitter-textobjects.shared')

  local is_comment, comment = in_comment()
  if not is_comment then return false end
  -- local comment = textobjects.textobject_at_point('@comment.inner', 'textobjects')
  -- if not comment or #comment == 0 then return false end

  -- Get position right after the comment
  local next_line = comment[4] + 1 -- end line + 1

  -- Check if next line is a class definition
  local class_at_next = textobjects.textobject_at_point('@class.outer', 'textobjects', { next_line, 0 })
  if class_at_next and #class_at_next > 0 then
    return 'comment_class'
  end

  -- Check if next line is a function definition
  local func_at_next = textobjects.textobject_at_point('@function.outer', 'textobjects', { next_line, 0 })
  if func_at_next and #func_at_next > 0 then
    return 'comment_func'
  end

  return false
end

-- Count non-empty, non-comment lines in buffer
local function contains_code(bufnr)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

  local comment_variances = { "#", "--", "//", "/%*", "//%*" }

  for _, line in ipairs(lines) do
    -- Skip empty lines
    if not line:match('^%s*$') then
      for _, pat in pairs(comment_variances) do
        if line:match("^%s*" .. pat) then
          return true
        end
      end
    end
  end

  return false
end

local function string_split(inputstr, sep)
  if sep == nil then
    sep = "%s"
  end
  local t = {}
  for str in string.gmatch(inputstr, "([^" .. sep .. "]+)") do
    table.insert(t, str)
  end
  return t
end


local lang_intelligence = {
  php = {
    in_function_body = function()
      local is_func, _ = in_function_body()
      if not is_func then return false end

      local line = vim.api.nvim_get_current_line()

      local pre_function_keywords = { "public", "private", "protected", "static", "abstract", "final" }

      local words = string_split(line, "%s+")

      local func_found = false
      local name_found = false
      local opening_brace_found = false
      local closing_brace_found = false

      for _, word in pairs(words) do
        if not func_found then
          if word == 'function' then
            func_found = true
          else
            for _, pre_key in pairs(pre_function_keywords) do
              if word ~= pre_key then
                return false, {}
              end
            end
          end
        elseif not name_found then
          if word:match("^%a[a-zA-Z0-9_]*$") then
            name_found = true
          elseif word:match("^%a[a-zA-Z0-9_]*%([%a[a-zA-Z0-9_]*$") then
            name_found = true
            opening_brace_found = true
          elseif word:match("^%a[a-zA-Z0-9_]*%(%)$") then
            name_found = true
            opening_brace_found = true
            closing_brace_found = true
          else
            return false, {}
          end
        elseif not opening_brace_found then
          if word == '(' then
            opening_brace_found = true
          else
            return false, {}
          end
        end
      end

      return closing_brace_found, {}
    end,
    definition_type = function()
    end
  },
}

function M.detect_suggestion_context()
  local lang = get_language()
  if not lang then return 'init' end

  local bufnr = vim.api.nvim_get_current_buf()

  -- Check for new file
  if not contains_code(bufnr) then
    return 'init'
  end

  -- Check for doc comment using treesitter
  local doc_type = is_doc_comment_for_definition()
  if doc_type then return doc_type end

  -- Check if we're in a comment
  -- local is_comment, _ = in_comment()
  -- if is_comment then
  --   -- Already handled doc comment case above, so this is just a regular comment
  --   return 'impl'
  -- end

  -- Check if we're in a function body
  local in_function_body_func = lang_intelligence[lang].in_function_body or in_function_body
  local is_function, _ = in_function_body_func()
  if is_function then
    return 'impl'
  end

  -- Check if we're in a class body
  local in_class, _ = in_class_body()
  if in_class then
    -- Could be writing a method or property
    local current_line = vim.api.nvim_get_current_line()
    vim.print(current_line)
    if is_definition(current_line, lang) then
      return current_line:match(patterns[lang].class) and 'class' or 'func'
    end
    return 'impl'
  end

  -- Default case
  return 'impl'
end

return M
