local cmp = require('cmp')
local api = vim.api
local conf = require('cmp_ai.config')
local async = require('plenary.async')

--- Generate a UUID v4
local function generate_uuid()
  local template = 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'
  return string.gsub(template, '[xy]', function(c)
    local v = (c == 'x') and math.random(0, 0xf) or math.random(8, 0xb)
    return string.format('%x', v)
  end)
end

local Source = {}
function Source:new(o)
  o = o or {}
  o.pending_requests = {} -- Track requests for acceptance correlation
  setmetatable(o, self)
  self.__index = self
  return o
end

function Source:get_debug_name()
  return 'AI'
end

function Source:_do_complete(ctx, cb)
  if conf:get('notify') then
    local cb = conf:get('notify_callback')
    if type(cb) == 'table' then
      if cb['on_start'] == nil then
        return
      else
        async.run(function()
          cb['on_start']('Completion started')
        end)
      end
    else
      async.run(function()
        cb('Completion started', true)
      end)
    end
  end
  vim.api.nvim_exec_autocmds({ "User" }, {
    pattern = "CmpAiRequestStarted",
  })
  local max_lines = conf:get('max_lines')
  local cursor = ctx.context.cursor
  local cur_line = ctx.context.cursor_line
  -- properly handle utf8
  -- local cur_line_before = string.sub(cur_line, 1, cursor.col - 1)
  local cur_line_before = vim.fn.strpart(cur_line, 0, math.max(cursor.col - 1, 0), true)

  -- properly handle utf8
  -- local cur_line_after = string.sub(cur_line, cursor.col) -- include current character
  local cur_line_after = vim.fn.strpart(cur_line, math.max(cursor.col - 1, 0), vim.fn.strdisplaywidth(cur_line), true) -- include current character

  local lines_before = api.nvim_buf_get_lines(0, math.max(0, cursor.line - max_lines), cursor.line, false)
  table.insert(lines_before, cur_line_before)
  local before = table.concat(lines_before, '\n')

  local lines_after = api.nvim_buf_get_lines(0, cursor.line + 1, cursor.line + max_lines, false)
  table.insert(lines_after, 1, cur_line_after)
  local after = table.concat(lines_after, '\n')

  -- Generate request ID and log request if data collection is enabled
  local request_id = generate_uuid()
  local logger = require('cmp_ai.logger')
  local request_start_time = os.clock()

  if logger:is_enabled() then
    logger:log_request(request_id, {
      cwd = vim.fn.getcwd(),
      filename = vim.api.nvim_buf_get_name(0),
      filetype = vim.bo.filetype,
      cursor = { line = cursor.line, col = cursor.col },
      lines_before = before,
      lines_after = after,
      provider = conf:get('provider').name,
    })

    self.pending_requests[request_id] = {
      timestamp = request_start_time,
      items = {},
    }
  end

  local service = conf:get('provider')
  service:complete(before, after, function(data)
    self:end_complete(data, ctx, cb, request_id, request_start_time)
    vim.api.nvim_exec_autocmds({ "User" }, {
      pattern = "CmpAiRequestComplete",
    })
    if conf:get('notify') then
      local cb = conf:get('notify_callback')
      if type(cb) == 'table' then
        if cb['on_end'] == nil then
          return
        else
          async.run(function()
            cb['on_end']('Completion ended')
          end)
        end
      else
        async.run(function()
          cb('Completion ended', false)
        end)
      end
    end
  end)
end

--- complete
function Source:complete(ctx, callback)
  if conf:get('ignored_file_types')[vim.bo.filetype] then
    callback()
    return
  end
  self:_do_complete(ctx, callback)
end

function Source:end_complete(data, ctx, cb, request_id, request_start_time)
  local items = {}
  for _, response in ipairs(data) do
    local prefix = string.sub(ctx.context.cursor_before_line, ctx.offset)
    local result = prefix .. response
    table.insert(items, {
      cmp = {
        kind_hl_group = 'CmpItemKind' .. conf:get('provider').name,
        kind_text = conf:get('provider').name,
      },
      label = result,
      documentation = {
        kind = cmp.lsp.MarkupKind.Markdown,
        value = '```' .. (vim.filetype.match({ buf = 0 }) or '') .. '\n' .. result .. '\n```',
      },
    })
  end

  -- Log response if data collection is enabled
  local logger = require('cmp_ai.logger')
  if logger:is_enabled() and request_id and self.pending_requests[request_id] then
    local response_time_ms = (os.clock() - request_start_time) * 1000

    logger:log_response(request_id, {
      response_raw = data,
      completions = items,
      response_time_ms = response_time_ms,
    })

    -- Store items for acceptance correlation
    self.pending_requests[request_id].items = items
  end

  cb({
    items = items,
    isIncomplete = conf:get('run_on_every_keystroke'),
  })
end

--- execute - called when user accepts a completion
--- This is the ONLY way nvim-cmp notifies sources about acceptance
function Source:execute(completion_item, callback)
  local logger = require('cmp_ai.logger')

  if logger:is_enabled() then
    -- Find which request this item belongs to
    for request_id, metadata in pairs(self.pending_requests) do
      for _, item in ipairs(metadata.items) do
        if item.label == completion_item.label then
          logger:log_acceptance(request_id, {
            accepted = true,
            accepted_item_label = completion_item.label,
          })

          -- Clean up this request from pending
          self.pending_requests[request_id] = nil
          break
        end
      end
    end
  end

  callback(completion_item)
end

return Source
