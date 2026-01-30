local M = {}

-- Helper function to check if file has any non-comment code
local function has_code(bufnr)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local parser = vim.treesitter.get_parser(bufnr)
  if not parser then
    -- Fallback: check for non-empty, non-whitespace lines
    for _, line in ipairs(lines) do
      if line:match('^%s*$') == nil then
        return true
      end
    end
    return false
  end

  local tree = parser:parse()[1]
  local root = tree:root()

  -- If there are any non-comment nodes, we have code
  for node in root:iter_children() do
    if node:type() ~= 'comment' then
      return true
    end
  end

  return false
end

-- Helper function to check if we're at a class/function declaration line
local function is_declaration_line(line, filetype)
  -- Remove leading/trailing whitespace for matching
  local trimmed = line:match('^%s*(.-)%s*$')

  -- Language-specific patterns for incomplete declarations
  local patterns = {
    python = {
      class_pattern = '^class%s+%w*',
      func_pattern = '^def%s+%w*',
    },
    lua = {
      class_pattern = nil, -- Lua doesn't have native classes
      func_pattern = '^function%s+%w*',
    },
    javascript = {
      class_pattern = '^class%s+%w*',
      func_pattern = '^function%s+%w*',
    },
    typescript = {
      class_pattern = '^class%s+%w*',
      func_pattern = '^function%s+%w*',
    },
    php = {
      class_pattern = '^class%s+%w*',
      -- PHP functions can have visibility modifiers (public/private/protected), static, etc.
      func_pattern = '^[%w%s]*function%s*%w*',
    },
    java = {
      class_pattern = '^class%s+%w*',
      func_pattern = '^%w+%s+%w+%s*%(', -- return_type function_name(
    },
  }

  local lang_patterns = patterns[filetype]
  if not lang_patterns then
    -- Generic patterns
    lang_patterns = {
      class_pattern = '^class%s+%w*',
      func_pattern = '^function%s+%w*',
    }
  end

  if lang_patterns.class_pattern and trimmed:match(lang_patterns.class_pattern) then
    return 'class'
  end

  if lang_patterns.func_pattern and trimmed:match(lang_patterns.func_pattern) then
    return 'func'
  end

  return nil
end

-- Helper function to check if a line is empty or whitespace-only
local function is_empty_line(line)
  return line:match('^%s*$') ~= nil
end

-- Detect the current suggestion context
function M.detect_suggestion_context(bufnr, pos)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  pos = pos or vim.api.nvim_win_get_cursor(0)

  local filetype = vim.bo[bufnr].filetype
  local current_line = vim.api.nvim_buf_get_lines(bufnr, pos[1] - 1, pos[1], false)[1] or ''

  -- Check if we have any code in the file
  if not has_code(bufnr) then
    return 'init'
  end

  -- Load treesitter textobjects if available
  local ok, textobjects = pcall(require, 'nvim-treesitter-textobjects.shared')
  if not ok then
    return nil
  end

  -- Check if we're in a comment
  local comment_match = textobjects.textobject_at_point('@comment.inner', 'textobjects')

  if comment_match and #comment_match >= 4 then
    -- We're in a comment, check if it's a class or function comment
    local comment_end_line = comment_match[4]
    local next_line_pos = { comment_end_line + 1, 0 }

    -- Check for class after comment
    local class_match = textobjects.textobject_at_point('@class.outer', 'textobjects', next_line_pos)
    if class_match and #class_match >= 4 then
      local class_start_line = class_match[1]
      if class_start_line == comment_end_line + 1 then
        return 'comment_class'
      end
    end

    -- Check for function after comment
    local func_match = textobjects.textobject_at_point('@function.outer', 'textobjects', next_line_pos)
    if func_match and #func_match >= 4 then
      local func_start_line = func_match[1]
      if func_start_line == comment_end_line + 1 then
        return 'comment_func'
      end
    end

    -- Generic comment (not a doc comment)
    return 'impl'
  end

  -- Check if we're writing a class or function declaration
  local decl_type = is_declaration_line(current_line, filetype)
  if decl_type then
    return decl_type
  end

  -- Check if we're in a function body
  local func_match = textobjects.textobject_at_point('@function.inner', 'textobjects')

  if func_match and #func_match >= 4 then
    -- We matched a function.inner, but we need to verify this isn't a false positive
    -- where we're declaring a new function above an existing one
    local func_start_line = func_match[1]
    local func_end_line = func_match[4]
    local current_pos_line = pos[1] - 1 -- Convert to 0-indexed

    -- Edge case: Check if we're actually declaring a new function above an existing one
    -- by verifying if there's no function body content between cursor and the matched function
    if current_pos_line < func_start_line then
      -- Cursor is before the function start, we're definitely not in it
      return 'impl'
    end

    -- Get the line at the function start to check if it's where we are
    local func_start_line_content = vim.api.nvim_buf_get_lines(bufnr, func_start_line, func_start_line + 1, false)[1] or
    ''

    -- If we're on a line that looks like a function declaration and it's not the actual
    -- matched function's declaration line, we're declaring a new function
    if is_declaration_line(current_line, filetype) then
      -- Check if current line is different from the matched function's start
      if current_pos_line ~= func_start_line then
        -- We're on a declaration line that's not the matched function's start
        -- This means we're declaring a new function above an existing one
        return 'func'
      end
    end

    -- If cursor is at or very close to the function start and the line is a declaration,
    -- check if there's actual function body content below
    if current_pos_line <= func_start_line + 2 and is_declaration_line(current_line, filetype) then
      -- Check if the next few lines are empty (no body yet)
      local lines_below = vim.api.nvim_buf_get_lines(bufnr, current_pos_line + 1,
        math.min(current_pos_line + 3, func_end_line), false)
      local has_body_content = false
      for _, line in ipairs(lines_below) do
        if not is_empty_line(line) then
          has_body_content = true
          break
        end
      end

      if not has_body_content then
        return 'func'
      end
    end

    return 'impl'
  end

  -- Default to implementation context
  return 'impl'
end

return M
