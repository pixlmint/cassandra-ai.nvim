local M = {}

local conf = require('cassandra_ai.config')
local api = vim.api

M._textobjects_instance = nil

local function textobjects()
  if M._textobjects_instance == nil then
    local ok, inst = pcall(require, 'nvim-treesitter-textobjects.shared')
    if ok then
      M._textobjects_instance = inst
    else
      vim.notify("Unable to load textobjects", vim.log.levels.ERROR)
    end
  end

  return M._textobjects_instance
end


--- Extract lines before and after cursor position
--- @param start_line number 0-indexed start line
--- @param end_line number 0-indexed end line (exclusive)
--- @param line_0 number 0-indexed cursor line
--- @param col number 0-indexed byte column
--- @param buf number buffer handle
local function extract_lines(start_line, end_line, line_0, col, buf)
  local cur_line_list = api.nvim_buf_get_lines(buf, line_0, line_0 + 1, false)
  local cur_line = cur_line_list[1] or ''
  -- properly handle utf8
  local cur_line_before = vim.fn.strpart(cur_line, 0, col, 1)

  -- properly handle utf8
  local cur_line_after = vim.fn.strpart(cur_line, col, vim.fn.strdisplaywidth(cur_line), 1)

  local lines_before = api.nvim_buf_get_lines(buf, start_line, line_0, false)
  table.insert(lines_before, cur_line_before)

  local lines_after = api.nvim_buf_get_lines(buf, line_0 + 1, end_line, false)
  table.insert(lines_after, 1, cur_line_after)

  return {
    lines_before = table.concat(lines_before, '\n'),
    lines_after = table.concat(lines_after, '\n'),
  }
end


--- @class SurroundContext
--- @field cursor {line: number, col: number} cursor position (1-indexed line, 0-indexed byte col) as from nvim_win_get_cursor
--- @field bufnr number buffer handle
--- @field current_context? string context type for smart extraction ('impl'|'comment_func'|'init')

--- @param ctx SurroundContext
function M.simple_extractor(ctx)
  local max_lines = conf:get('max_lines')

  local line_0 = ctx.cursor.line - 1
  local col = ctx.cursor.col

  local start_line = math.max(0, line_0 - max_lines)
  local end_line = line_0 + 1 + max_lines

  return extract_lines(start_line, end_line, line_0, col, ctx.bufnr)
end

local function curry_textobjects(selector, source)
  source = source or 'textobjects'

  --- @param ctx SurroundContext
  return function(ctx)
    local line_0 = ctx.cursor.line - 1
    return textobjects().textobject_at_point(selector, source, ctx.bufnr, { line_0, ctx.cursor.col }, {})
  end
end

--- @param rng1 Range6
--- @param rng2 Range6
--- @return Range6
local function combine_ranges(rng1, rng2)
  if rng1 == nil or #rng1 == 0 then
    return rng2
  elseif rng2 == nil or #rng2 == 0 then
    return rng1
  end
  return {
    math.min(rng1[1], rng2[1]),
    math.min(rng1[2], rng2[2]),
    math.min(rng1[3], rng2[3]),
    math.max(rng1[4], rng2[4]),
    math.max(rng1[5], rng2[5]),
    math.max(rng1[6], rng2[6]),
  }
end

local locate_function = curry_textobjects('@function.outer')
local locate_comment = curry_textobjects('@comment.outer')

--- @param ctx SurroundContext
function M.smart_extractor(ctx)
  local current_context = ctx.current_context
  local rng
  if current_context == 'impl' then
    rng = locate_function(ctx)
    -- Look for comment above the function; rng[1] is 0-indexed, convert to 1-indexed for ctx
    rng = combine_ranges(rng, locate_comment({ bufnr = ctx.bufnr, cursor = { line = rng[1], col = rng[2] }}))
  elseif current_context == 'comment_func' then
    rng = locate_comment(ctx)
    -- Look for function below the comment; rng[4] is 0-indexed end row
    rng = combine_ranges(rng, locate_function({ bufnr = ctx.bufnr, cursor = { line = rng[4] + 3, col = rng[2] }}))
  elseif current_context == 'init' then
    local line_count = api.nvim_buf_line_count(ctx.bufnr)
    local last_line_list = api.nvim_buf_get_lines(ctx.bufnr, line_count - 1, line_count, false)
    local last_line = last_line_list[1] or ''
    rng = { 0, 0, nil, line_count, vim.fn.strdisplaywidth(last_line), nil }
  end
  if rng == nil or #rng == 0 then
    return M.simple_extractor(ctx)
  else
    local line_0 = ctx.cursor.line - 1
    return extract_lines(rng[1], rng[4], line_0, ctx.cursor.col, ctx.bufnr)
  end
end

return M
