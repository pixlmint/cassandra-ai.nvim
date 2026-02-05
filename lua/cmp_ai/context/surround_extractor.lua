local M = {}

local conf = require('cmp_ai.config')
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


local function extract_lines(start_line, end_line, cursor)
  local line_num = cursor[1]
  local cur_line_list = api.nvim_buf_get_lines(0, line_num, line_num, false)
  local cur_line = cur_line_list[1]
  -- properly handle utf8
  local cur_line_before = vim.fn.strpart(cur_line, 0, math.max(cursor[2] - 1, 0), 1)

  -- properly handle utf8
  local cur_line_after = vim.fn.strpart(cur_line, math.max(cursor[2] - 1, 0), vim.fn.strdisplaywidth(cur_line), 1)

  local lines_before = api.nvim_buf_get_lines(0, start_line, line_num, false)
  table.insert(lines_before, cur_line_before)

  local lines_after = api.nvim_buf_get_lines(0, line_num + 1, end_line, false)
  table.insert(lines_after, 1, cur_line_after)

  return {
    lines_before = table.concat(lines_before, '\n'),
    lines_after = table.concat(lines_after, '\n'),
  }
end


--- @param ctx cmp.SourceCompletionApiParams
function M.simple_extractor(ctx)
  local max_lines = conf:get('max_lines')

  local cursor = ctx.context.cursor

  local start_line = math.max(0, cursor.line - max_lines)
  local end_line = cursor.line + max_lines

  return extract_lines(start_line, end_line, { cursor.line, cursor.col })
end

local function curry_textobjects(selector, source)
  source = source or 'textobjects'

  return function(ctx)
    return textobjects().textobject_at_point(selector, source, ctx.context.bufnr, { ctx.context.cursor.line, ctx.context.cursor.col }, {})
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

--- @param ctx cmp.SourceCompletionApiParams
function M.smart_extractor(ctx, current_context)
  local rng
  if current_context == 'impl' then
    rng = locate_function(ctx)
    rng = combine_ranges(rng, locate_comment({ context = { bufnr = ctx.context.bufnr, cursor = { line = rng[1] - 1, col = rng[2] }}}))
  elseif current_context == 'comment_func' then
    rng = locate_comment(ctx)
    rng = combine_ranges(rng, locate_function({ context = { bufnr = ctx.context.bufnr, cursor = { line = rng[4] + 2, col = rng[2] }}}))
  elseif current_context == 'init' then
    local line_count = api.nvim_buf_line_count(ctx.context.bufnr)
    local last_line_list = api.nvim_buf_get_lines(0, line_count, line_count, false)
    local last_line = last_line_list[1]
    rng = { 0, 0, nil, line_count, vim.fn.strdisplaywidth(last_line), nil }
  end
  if rng == nil or #rng == 0 then
    return M.simple_extractor(ctx)
  else
    return extract_lines(rng[1], rng[4], { ctx.context.cursor.line, ctx.context.cursor.col })
  end
end

return M
