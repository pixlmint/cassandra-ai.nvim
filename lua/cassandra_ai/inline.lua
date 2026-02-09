local conf = require('cassandra_ai.config')
local logger = require('cassandra_ai.logger')

local M = {}

-- Module state
local generation = 0
local current_job = nil
local debounce_timer = nil
local completions = {}
local current_index = 0
local is_visible = false
local cursor_pos = nil
local bufnr = nil
local internal_move = false

local ns = vim.api.nvim_create_namespace('cassandra_ai_inline')

-- ---------------------------------------------------------------------------
-- Request Logging
-- ---------------------------------------------------------------------------

--- Generate a UUID v4
local function generate_uuid()
  local template = 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'
  return string.gsub(template, '[xy]', function(c)
    local v = (c == 'x') and math.random(0, 0xf) or math.random(8, 0xb)
    return string.format('%x', v)
  end)
end

--- Safely serialize provider config for logging
--- Only logs provider.params (never api_key or headers)
--- Replaces functions with type metadata
local function safe_serialize_config(params)
  if type(params) ~= 'table' then
    return params
  end

  local result = {}
  for key, value in pairs(params) do
    local value_type = type(value)
    if value_type == 'function' then
      result[key] = { __type = 'function' }
    elseif value_type == 'table' then
      result[key] = safe_serialize_config(value) -- Recursive
    elseif value_type == 'string' or value_type == 'number' or value_type == 'boolean' then
      result[key] = value
    elseif value_type == 'nil' then
      -- Skip nil values
    else
      -- Thread, userdata, etc.
      result[key] = { __type = value_type }
    end
  end
  return result
end

-- ---------------------------------------------------------------------------
-- Virtual text rendering
-- ---------------------------------------------------------------------------

local function clear_ghost_text()
  if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
    vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
  end
  is_visible = false
end

local function render_ghost_text(text)
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  clear_ghost_text()
  if not text or text == '' then
    return
  end

  local lines = vim.split(text, '\n', { plain = true })
  local row = cursor_pos[1] - 1 -- 0-indexed
  local col = cursor_pos[2]

  local virt_text = { { lines[1], 'CassandraAiInline' } }
  local virt_lines = nil

  if #lines > 1 then
    virt_lines = {}
    for i = 2, #lines do
      table.insert(virt_lines, { { lines[i], 'CassandraAiInline' } })
    end
  end

  vim.api.nvim_buf_set_extmark(bufnr, ns, row, col, {
    virt_text = virt_text,
    virt_text_pos = 'inline',
    virt_lines = virt_lines,
  })
  is_visible = true
end

-- ---------------------------------------------------------------------------
-- Request management
-- ---------------------------------------------------------------------------

local function cancel_request()
  if current_job then
    pcall(function()
      current_job:shutdown()
    end)
    current_job = nil
  end
end

local function cancel_debounce()
  if debounce_timer then
    debounce_timer:stop()
  end
end

-- ---------------------------------------------------------------------------
-- Response post-processing
-- ---------------------------------------------------------------------------

--- Strip lines from the edges of a completion that overlap with surrounding context.
--- Some models echo back parts of the before/after text in their response.
local function strip_context_overlap(text, lines_before, lines_after)
  local lines = vim.split(text, '\n', { plain = true })
  if #lines == 0 then
    return text
  end

  local before_split = vim.split(lines_before, '\n', { plain = true })
  local after_split = vim.split(lines_after, '\n', { plain = true })

  local before_set = {}
  for _, line in ipairs(before_split) do
    local trimmed = vim.trim(line)
    if trimmed ~= '' then
      before_set[trimmed] = true
    end
  end

  local after_set = {}
  for _, line in ipairs(after_split) do
    local trimmed = vim.trim(line)
    if trimmed ~= '' then
      after_set[trimmed] = true
    end
  end

  -- Strip leading lines that appear in before context
  local start_strip = 0
  for i = 1, #lines do
    local trimmed = vim.trim(lines[i])
    if trimmed ~= '' and before_set[trimmed] then
      start_strip = i
    else
      break
    end
  end

  -- Strip trailing lines that appear in after context.
  -- Allow short trailing lines (e.g. }, ), ]) that aren't in after_set
  -- to be bridged over, since the after context may have been truncated.
  local tail_skip = 0
  for i = #lines, start_strip + 1, -1 do
    local trimmed = vim.trim(lines[i])
    if trimmed == '' or after_set[trimmed] then
      break
    elseif #trimmed <= 2 then
      tail_skip = tail_skip + 1
      if tail_skip > 2 then
        tail_skip = 0
        break
      end
    else
      tail_skip = 0
      break
    end
  end

  local end_strip = 0
  for i = #lines - tail_skip, start_strip + 1, -1 do
    local trimmed = vim.trim(lines[i])
    if trimmed == '' or after_set[trimmed] then
      end_strip = end_strip + 1
    else
      break
    end
  end

  -- Only count tail_skip if we found actual after-context matches
  if end_strip > 0 then
    end_strip = end_strip + tail_skip
  end

  if start_strip == 0 and end_strip == 0 then
    return text
  end

  local result = {}
  for i = start_strip + 1, #lines - end_strip do
    result[#result + 1] = lines[i]
  end

  -- Don't strip everything - return original if nothing would remain
  if #result == 0 then
    return text
  end

  return table.concat(result, '\n')
end

-- ---------------------------------------------------------------------------
-- Main trigger
-- ---------------------------------------------------------------------------

function M.trigger()
  -- Bail if not insert mode
  if vim.fn.mode() ~= 'i' then
    return
  end

  local ft = vim.bo.filetype
  if conf:get('ignored_file_types')[ft] then
    return
  end

  cancel_request()
  cancel_debounce()
  clear_ghost_text()

  generation = generation + 1
  local my_gen = generation

  bufnr = vim.api.nvim_get_current_buf()
  cursor_pos = vim.api.nvim_win_get_cursor(0)
  completions = {}
  current_index = 0

  local service = conf:get('provider')
  if service == nil then
    logger.warn('trigger: no provider configured')
    return
  end

  logger.info('trigger: generation=' .. my_gen .. ' buf=' .. bufnr .. ' ft=' .. ft)

  local function do_complete(surround_context)
    if my_gen ~= generation then
      return
    end

    local before = surround_context.lines_before
    local after = surround_context.lines_after

    local request_id = generate_uuid()
    local telemetry = require('cassandra_ai.telemetry')

    local start_time

    if telemetry:is_enabled() then
      local provider = conf:get('provider')
      telemetry:log_request(request_id, {
        cwd = vim.fn.getcwd(),
        filename = vim.api.nvim_buf_get_name(0),
        filetype = vim.bo.filetype,
        cursor = { line = cursor_pos[1], col = cursor_pos[2] },
        lines_before = before,
        lines_after = after,
        provider = provider.name,
        provider_config = safe_serialize_config(provider.params),
      })
    end

    vim.api.nvim_exec_autocmds({ 'User' }, {
      pattern = 'CassandraAiRequestStarted',
    })

    local function on_complete(data)
      local elapsed_ms = (os.clock() - start_time) * 1000
      if telemetry:is_enabled() then
        telemetry:log_response(request_id, {
          response_raw = data,
          response_time_ms = elapsed_ms,
        })
      end
      -- Stale check
      if my_gen ~= generation then
        logger.trace('on_complete() -> discarding: stale generation')
        return
      end
      if not vim.api.nvim_buf_is_valid(bufnr) then
        logger.trace('on_complete() -> discarding: buffer invalid')
        return
      end
      if vim.fn.mode() ~= 'i' then
        logger.trace('on_complete() -> discarding: left insert mode')
        return
      end
      -- Check cursor hasn't moved
      local cur = vim.api.nvim_win_get_cursor(0)
      if cur[1] ~= cursor_pos[1] or cur[2] ~= cursor_pos[2] then
        logger.trace('on_complete() -> discarding: cursor moved')
        return
      end

      vim.api.nvim_exec_autocmds({ 'User' }, {
        pattern = 'CassandraAiRequestComplete',
      })

      if not data or #data == 0 then
        logger.trace('on_complete() -> no completions returned')
        return
      end

      -- Strip markdown code fences some providers wrap responses in
      for i, item in ipairs(data) do
        local lines = vim.split(item, '\n', { plain = true })
        if #lines >= 2 then
          if lines[1]:match('^```') then
            table.remove(lines, 1)
          end
          if #lines > 0 and lines[#lines]:match('^```') then
            table.remove(lines, #lines)
          end
          data[i] = table.concat(lines, '\n')
        end
      end

      -- Strip lines at edges that overlap with the surrounding context
      for i, item in ipairs(data) do
        data[i] = strip_context_overlap(item, before, after)
      end

      logger.info(string.format('completion received: %d item(s) in %.0fms', #data, elapsed_ms))
      completions = data
      current_index = 1
      render_ghost_text(completions[current_index])
    end

    local context_manager = require('cassandra_ai.context')
    local formatters = require('cassandra_ai.prompt_formatters')

    service:resolve_model(function(model_info)
      if my_gen ~= generation then
        return
      end

      local fmt = (model_info and model_info.formatter) or conf:get('formatter') or formatters.fim
      local supports_context = (fmt == formatters.chat)

      local function do_request(additional_context)
        if my_gen ~= generation then
          return
        end
        start_time = os.clock()
        local prompt_data = fmt(before, after, { filetype = ft }, additional_context)
        current_job = service:complete(prompt_data, on_complete, model_info or {})
      end

      if context_manager.is_enabled() and supports_context then
        local params = {
          bufnr = bufnr,
          cursor_pos = { line = cursor_pos[1] - 1, col = cursor_pos[2] },
          lines_before = before,
          lines_after = after,
          filetype = ft,
        }
        context_manager.gather_context(params, function(additional_context)
          do_request(additional_context)
        end)
      else
        do_request(nil)
      end
    end)
  end

  local surround_extractor = require('cassandra_ai.context.surround_extractor')
  local ctx = {
    cursor = { line = cursor_pos[1], col = cursor_pos[2] },
    bufnr = bufnr,
  }

  local strategy = conf:get('surround_extractor_strategy')
  if strategy == 'smart' then
    require('cassandra_ai.context.utils').detect_suggestion_context(bufnr, cursor_pos, function(current_context)
      if my_gen ~= generation then
        return
      end
      ctx.current_context = current_context
      do_complete(surround_extractor.smart_extractor(ctx))
    end)
  else
    do_complete(surround_extractor.simple_extractor(ctx))
  end
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

function M.is_visible()
  return is_visible
end

function M.dismiss()
  cancel_request()
  cancel_debounce()
  clear_ghost_text()
  completions = {}
  current_index = 0
end

function M.next()
  if #completions == 0 then
    return
  end
  current_index = current_index % #completions + 1
  logger.info('next completion: ' .. current_index .. '/' .. #completions)
  render_ghost_text(completions[current_index])
end

function M.prev()
  if #completions == 0 then
    return
  end
  current_index = (current_index - 2) % #completions + 1
  logger.info('prev completion: ' .. current_index .. '/' .. #completions)
  render_ghost_text(completions[current_index])
end

function M.accept()
  if not is_visible or current_index == 0 or #completions == 0 then
    return false
  end

  local text = completions[current_index]
  if not text or text == '' then
    return false
  end

  logger.info('completion accepted (' .. #vim.split(text, '\n', { plain = true }) .. ' lines)')

  local row = cursor_pos[1] -- 1-indexed
  local col = cursor_pos[2] -- 0-indexed bytes

  clear_ghost_text()

  local cur_line = vim.api.nvim_buf_get_lines(bufnr, row - 1, row, false)[1] or ''
  local before = vim.fn.strpart(cur_line, 0, col, 1)
  local after_cursor = vim.fn.strpart(cur_line, col, vim.fn.strdisplaywidth(cur_line), 1)

  local comp_lines = vim.split(text, '\n', { plain = true })

  internal_move = true

  local new_lines
  if #comp_lines == 1 then
    new_lines = { before .. comp_lines[1] .. after_cursor }
  else
    new_lines = {}
    new_lines[1] = before .. comp_lines[1]
    for i = 2, #comp_lines - 1 do
      new_lines[#new_lines + 1] = comp_lines[i]
    end
    new_lines[#new_lines + 1] = comp_lines[#comp_lines] .. after_cursor
  end

  vim.api.nvim_buf_set_lines(bufnr, row - 1, row, false, new_lines)

  -- Set cursor at end of completion text
  local new_row = row - 1 + #new_lines -- 1-indexed
  local last_comp_line = comp_lines[#comp_lines]
  local new_col
  if #comp_lines == 1 then
    new_col = #before + #last_comp_line
  else
    new_col = #last_comp_line
  end
  vim.api.nvim_win_set_cursor(0, { new_row, new_col })

  completions = {}
  current_index = 0

  vim.schedule(function()
    internal_move = false
  end)

  return true
end

-- ---------------------------------------------------------------------------
-- Debounce
-- ---------------------------------------------------------------------------

local function debounced_trigger()
  cancel_debounce()
  local ic = conf:get('inline')
  if not ic.auto_trigger then
    return
  end
  if not debounce_timer then
    debounce_timer = vim.uv.new_timer()
  end
  debounce_timer:start(
    ic.debounce_ms,
    0,
    vim.schedule_wrap(function()
      M.trigger()
    end)
  )
end

-- ---------------------------------------------------------------------------
-- Autocmds
-- ---------------------------------------------------------------------------

local function setup_autocmds()
  local group = vim.api.nvim_create_augroup('cassandra_ai_inline', { clear = true })

  vim.api.nvim_create_autocmd('CursorMovedI', {
    group = group,
    callback = function()
      if internal_move then
        return
      end
      if is_visible and cursor_pos then
        local cur = vim.api.nvim_win_get_cursor(0)
        if cur[1] ~= cursor_pos[1] or cur[2] ~= cursor_pos[2] then
          M.dismiss()
        end
      end
      debounced_trigger()
    end,
  })

  vim.api.nvim_create_autocmd('InsertEnter', {
    group = group,
    callback = function()
      if internal_move then
        return
      end
      debounced_trigger()
    end,
  })

  vim.api.nvim_create_autocmd('InsertLeave', {
    group = group,
    callback = function()
      M.dismiss()
    end,
  })

  vim.api.nvim_create_autocmd('BufLeave', {
    group = group,
    callback = function()
      M.dismiss()
    end,
  })
end

-- ---------------------------------------------------------------------------
-- Keymaps
-- ---------------------------------------------------------------------------

local function setup_keymaps()
  local km = conf:get('inline').keymap

  if km.accept then
    vim.keymap.set('i', km.accept, function()
      if M.is_visible() then
        -- Schedule accept so buffer modification happens outside expr evaluation
        vim.schedule(M.accept)
        return ''
      end
      -- Fall through to original mapping
      return vim.api.nvim_replace_termcodes(km.accept, true, false, true)
    end, { expr = true, noremap = true, silent = true, desc = 'Accept AI completion' })
  end

  if km.dismiss then
    vim.keymap.set('i', km.dismiss, function()
      M.dismiss()
    end, { noremap = true, silent = true, desc = 'Dismiss AI completion' })
  end

  if km.next then
    vim.keymap.set('i', km.next, function()
      M.next()
    end, { noremap = true, silent = true, desc = 'Next AI completion' })
  end

  if km.prev then
    vim.keymap.set('i', km.prev, function()
      M.prev()
    end, { noremap = true, silent = true, desc = 'Previous AI completion' })
  end
end

-- ---------------------------------------------------------------------------
-- Setup
-- ---------------------------------------------------------------------------

function M.setup(opts)
  opts = opts or {}

  -- Pass all opts to config (inline is deep-merged there)
  conf:setup(opts)

  -- Define highlight group
  local ic = conf:get('inline')
  vim.api.nvim_set_hl(0, 'CassandraAiInline', { link = ic.highlight, default = true })

  setup_autocmds()
  setup_keymaps()
end

return M
