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
local current_request_id = nil
local pending_rejected = {}

local auto_triggered = false
local pending_validation = nil -- { completions, trigger_pos, trigger_bufnr, trigger_line_text }
local validation_idle_timer = nil

local validate_or_defer, show_validated_completion, reset_validation_idle_timer

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
-- Deferred validation
-- ---------------------------------------------------------------------------

local function cancel_validation_timer()
  if validation_idle_timer then
    validation_idle_timer:stop()
  end
end

local function clear_validation_state()
  auto_triggered = false
  pending_validation = nil
  cancel_validation_timer()
end

--- Get text typed since the trigger position by comparing current buffer state.
--- Returns nil if cursor moved to a different line or backward past trigger column.
local function compute_typed_since_trigger(pv)
  local cur = vim.api.nvim_win_get_cursor(0)
  if cur[1] ~= pv.trigger_pos[1] then
    return nil
  end
  if cur[2] < pv.trigger_pos[2] then
    return nil
  end
  local line = vim.api.nvim_buf_get_lines(pv.trigger_bufnr, cur[1] - 1, cur[1], false)[1] or ''
  return line:sub(pv.trigger_pos[2] + 1, cur[2])
end

--- Find the number of characters the user must type before we show the completion.
--- Returns nil if completion has no space (fall back to idle timer).
local function find_validation_threshold(text)
  local space_pos = text:find('%s')
  if not space_pos then
    return nil
  end
  local next_word_match = conf:get('inline').next_word_match or 1
  return space_pos + next_word_match
end

--- Trim the typed prefix from all completion candidates, filter out empty results.
local function trim_completions(comps, prefix)
  local result = {}
  for _, c in ipairs(comps) do
    if c:sub(1, #prefix) == prefix then
      local trimmed = c:sub(#prefix + 1)
      if trimmed ~= '' then
        result[#result + 1] = trimmed
      end
    end
  end
  return result
end

show_validated_completion = function(pv, typed)
  local trimmed = trim_completions(pv.completions, typed)
  if #trimmed == 0 then
    logger.trace('deferred: all completions empty after trimming')
    clear_validation_state()
    return
  end

  local cur = vim.api.nvim_win_get_cursor(0)
  cursor_pos = cur
  completions = trimmed
  current_index = 1
  clear_validation_state()
  render_ghost_text(completions[current_index])
end

validate_or_defer = function()
  local pv = pending_validation
  if not pv then
    return
  end

  local typed = compute_typed_since_trigger(pv)
  if typed == nil then
    logger.trace('deferred: cursor moved off trigger line, discarding')
    clear_validation_state()
    return
  end

  -- Check that what the user typed is a prefix of at least one completion
  local has_match = false
  for _, c in ipairs(pv.completions) do
    if c:sub(1, #typed) == typed then
      has_match = true
      break
    end
  end

  if not has_match then
    logger.trace('deferred: typed "' .. typed .. '" mismatches all completions, discarding')
    clear_validation_state()
    return
  end

  -- Check if past the validation threshold
  local threshold = find_validation_threshold(pv.completions[1])
  if threshold and #typed >= threshold then
    logger.info('deferred: threshold reached (' .. #typed .. '>=' .. threshold .. '), showing completion')
    show_validated_completion(pv, typed)
    return
  end

  -- Not enough typed yet — (re)start idle timer
  reset_validation_idle_timer()
end

reset_validation_idle_timer = function()
  cancel_validation_timer()
  if not validation_idle_timer then
    validation_idle_timer = vim.uv.new_timer()
  end
  local idle_ms = conf:get('inline').deferred_idle_ms or 1000
  validation_idle_timer:start(
    idle_ms,
    0,
    vim.schedule_wrap(function()
      local pv = pending_validation
      if not pv then
        return
      end
      local typed = compute_typed_since_trigger(pv) or ''
      logger.info('deferred: idle timer fired, showing completion')
      show_validated_completion(pv, typed)
    end)
  )
end

-- ---------------------------------------------------------------------------
-- Main trigger
-- ---------------------------------------------------------------------------

function M.trigger(opts)
  opts = opts or {}

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
  clear_validation_state()

  generation = generation + 1
  local my_gen = generation
  auto_triggered = opts.auto or false

  bufnr = vim.api.nvim_get_current_buf()
  cursor_pos = vim.api.nvim_win_get_cursor(0)
  completions = {}
  current_index = 0
  current_request_id = nil

  local rejected = pending_rejected
  pending_rejected = {}

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
    current_request_id = request_id
    local telemetry = require('cassandra_ai.telemetry')

    local start_time

    vim.api.nvim_exec_autocmds({ 'User' }, {
      pattern = 'CassandraAiRequestStarted',
    })

    local function on_complete(data)
      current_job = nil
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
        clear_validation_state()
        return
      end
      if vim.fn.mode() ~= 'i' then
        logger.trace('on_complete() -> discarding: left insert mode')
        clear_validation_state()
        return
      end

      local cur = vim.api.nvim_win_get_cursor(0)
      local ic = conf:get('inline')
      local use_deferred = auto_triggered and ic.deferred_validation

      if use_deferred then
        -- For auto-triggered with deferred validation: only require same line
        if cur[1] ~= cursor_pos[1] then
          logger.trace('on_complete() -> discarding: cursor moved to different line')
          clear_validation_state()
          return
        end
      else
        -- Manual trigger or deferred disabled: require exact cursor match
        if cur[1] ~= cursor_pos[1] or cur[2] ~= cursor_pos[2] then
          logger.trace('on_complete() -> discarding: cursor moved')
          return
        end
      end

      vim.api.nvim_exec_autocmds({ 'User' }, {
        pattern = 'CassandraAiRequestComplete',
      })

      if not data or #data == 0 then
        logger.trace('on_complete() -> no completions returned')
        clear_validation_state()
        return
      end

      -- Strip markdown code fences some providers wrap responses in
      for i, item in ipairs(data) do
        local lines = vim.split(item, '\n', { plain = true })
        if #lines >= 2 then
          if lines[1]:match('^```') then
            table.remove(lines, 1)
            -- Remove leading whitespace from the next line if we removed a code fence
            if #lines > 0 then
              lines[1] = lines[1]:gsub('^%s+', '')
            end
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

      if use_deferred then
        -- Store for validation instead of rendering immediately
        pending_validation = {
          completions = data,
          trigger_pos = cursor_pos,
          trigger_bufnr = bufnr,
          trigger_line_text = vim.api.nvim_buf_get_lines(bufnr, cursor_pos[1] - 1, cursor_pos[1], false)[1] or '',
        }
        logger.trace('on_complete() -> deferred: stored ' .. #data .. ' completion(s) for validation')
        validate_or_defer()
      else
        completions = data
        current_index = 1
        render_ghost_text(completions[current_index])
      end
    end

    local context_manager = require('cassandra_ai.context')
    local formatters = require('cassandra_ai.prompt_formatters')

    service:resolve_model(function(model_info)
      if my_gen ~= generation then
        return
      end

      local fmt = (model_info and model_info.formatter) or conf:get('formatter') or formatters.fim
      if type(fmt) == 'string' then
        if formatters[fmt] then
          return formatters[fmt]
        end
        logger.warn('config: unknown formatter "' .. fmt .. '", falling back to nil')
        return
      end
      local supports_context = (fmt == formatters.chat)

      local function do_request(additional_context)
        if my_gen ~= generation then
          return
        end
        start_time = os.clock()
        local prompt_data = fmt(before, after, { filetype = ft, rejected_completions = rejected }, additional_context)

        if telemetry:is_enabled() then
          local provider = conf:get('provider')
          telemetry:log_request(request_id, {
            cwd = vim.fn.getcwd(),
            filename = vim.api.nvim_buf_get_name(0),
            filetype = ft,
            cursor = { line = cursor_pos[1], col = cursor_pos[2] },
            lines_before = before,
            lines_after = after,
            provider = provider.name,
            provider_config = safe_serialize_config(provider.params),
            model = model_info and model_info.model,
            prompt_data = prompt_data,
            additional_context = additional_context,
          })
        end

        current_job = service:complete(prompt_data, on_complete, model_info or {})
      end

      if context_manager.is_enabled() and supports_context then
        logger.trace('resolve_model() -> collect context')
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
  if is_visible and current_request_id then
    local telemetry = require('cassandra_ai.telemetry')
    if telemetry:is_enabled() then
      telemetry:log_acceptance(current_request_id, { accepted = false })
    end
  end
  cancel_request()
  cancel_debounce()
  clear_ghost_text()
  clear_validation_state()
  completions = {}
  current_index = 0
  current_request_id = nil
  pending_rejected = {}
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

function M.regenerate()
  if not is_visible or current_index == 0 or #completions == 0 then
    return
  end

  local text = completions[current_index]
  if not text or text == '' then
    return
  end

  -- Log dismissal in telemetry
  if current_request_id then
    local telemetry = require('cassandra_ai.telemetry')
    if telemetry:is_enabled() then
      telemetry:log_acceptance(current_request_id, { accepted = false })
    end
  end

  logger.info('regenerate: rejecting completion and requesting new one')
  table.insert(pending_rejected, text)
  M.trigger()
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
  current_request_id = nil

  vim.schedule(function()
    internal_move = false
  end)

  return true
end

-- ---------------------------------------------------------------------------
-- Debounce
-- ---------------------------------------------------------------------------

local function debounced_trigger()
  if auto_triggered then
    return
  end
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
      M.trigger({ auto = true })
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
      if pending_validation then
        validate_or_defer()
        return
      end
      if is_visible and cursor_pos and #completions > 0 then
        local cur = vim.api.nvim_win_get_cursor(0)
        if cur[1] == cursor_pos[1] and cur[2] > cursor_pos[2] then
          -- User typed forward on the same line — check if it matches the completion
          local advance = cur[2] - cursor_pos[2]
          local text = completions[current_index]
          local prefix = text:sub(1, advance)
          local line = vim.api.nvim_buf_get_lines(bufnr, cur[1] - 1, cur[1], false)[1] or ''
          local typed = line:sub(cursor_pos[2] + 1, cur[2])
          if typed == prefix then
            -- Still matching — trim completion and re-render at new cursor
            local trimmed = text:sub(advance + 1)
            if trimmed == '' then
              M.dismiss()
            else
              completions[current_index] = trimmed
              cursor_pos = cur
              render_ghost_text(trimmed)
            end
            return
          end
        end
        -- Mismatch or moved elsewhere — dismiss and allow re-trigger
        M.dismiss()
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

  if km.regenerate then
    vim.keymap.set('i', km.regenerate, function()
      M.regenerate()
    end, { noremap = true, silent = true, desc = 'Regenerate AI completion' })
  end
end

-- ---------------------------------------------------------------------------
-- Setup
-- ---------------------------------------------------------------------------

function M.setup(opts)
  print('inline setup called')
  -- Define highlight group
  vim.api.nvim_set_hl(0, 'CassandraAiInline', { link = opts.highlight, default = true })

  setup_autocmds()
  setup_keymaps()
end

return M
