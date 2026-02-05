local cmp = require('cmp')
local conf = require('cmp_ai.config')
local async = require('plenary.async')
local surround_extractor = require('cmp_ai.context.surround_extractor')

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

--- @param ctx cmp.SourceCompletionApiParams
--- @param cb function
function Source:_do_complete(ctx, cb)
  if conf:get('notify') then
    local cb = conf:get('notify_callback')
    if type(cb) == 'table' then
      if cb['on_start'] == nil then
        return
      else
        async.run(function() cb['on_start']('Completion started') end)
      end
    else
      async.run(function() cb('Completion started', true) end)
    end
  end
  vim.api.nvim_exec_autocmds({ "User" }, {
    pattern = "CmpAiRequestStarted",
  })

  -- Generate request ID and log request if data collection is enabled
  local request_id = generate_uuid()
  local logger = require('cmp_ai.logger')
  local request_start_time = os.clock()


  local function completed(data)
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
          async.run(function() cb['on_end']('Completion ended') end)
        end
      else
        async.run(function() cb('Completion ended', false) end)
      end
    end
  end

  local cursor = ctx.context.cursor
  local pos = { cursor.line, cursor.col }
  local surround_extract_strategy = conf:get('surround_extractor_strategy')

  --- @class CompletionContext
  --- @field lines_before string
  --- @field lines_after string

  --- @param context CompletionContext
  local function next_action(context)
    if logger:is_enabled() then
      local provider = conf:get('provider')
      logger:log_request(request_id, {
        cwd = vim.fn.getcwd(),
        filename = vim.api.nvim_buf_get_name(0),
        filetype = vim.bo.filetype,
        cursor = { line = cursor.line, col = cursor.col },
        lines_before = context.lines_before,
        lines_after = context.lines_after,
        provider = provider.name,
        provider_config = safe_serialize_config(provider.params),
      })

      self.pending_requests[request_id] = {
        timestamp = request_start_time,
        items = {},
      }
    end

    -- Gather additional context from context providers
    local context_manager = require('cmp_ai.context')

    local service = conf:get('provider')

    if service ~= nil then
      local before = context.lines_before
      local after = context.lines_after

      service:get_model(function(model_config)
        if not context_manager.is_enabled() or not model_config.allows_extra_context then
          vim.notify('using simple completion', vim.log.levels.INFO)
          -- No context providers enabled, proceed normally
          local prompt = model_config.prompt(before, after)
          service:complete(prompt, completed, model_config)
        else
          -- Prepare context parameters
          local context_params = {
            bufnr = ctx.context.bufnr,
            cursor_pos = { line = cursor.line, col = cursor.col },
            before = before,
            after = after,
            filetype = vim.bo.filetype, -- TODO: This should get the filetype by bufnr, not of the current buffer
          }
          vim.notify('using advanced completion with additional context', vim.log.levels.INFO)

          -- Gather context asynchronously
          context_manager.gather_context(context_params, function(additional_context)
            local prompt = model_config.prompt(before, after, nil, additional_context)
            service:complete(prompt, completed, model_config)
          end)
        end
      end)
    end
  end

  if surround_extract_strategy == 'smart' then
    require('cmp_ai.context.utils').detect_suggestion_context(ctx.context.bufnr, pos, function(current_context)
      next_action(surround_extractor.smart_extractor(ctx, current_context))
    end)
  else
    next_action(surround_extractor.simple_extractor(ctx))
  end
end

--- @param ctx cmp.SourceCompletionApiParams
function Source:complete(ctx, callback)
  if conf:get('ignored_file_types')[vim.bo.filetype] then
    callback()
    return
  end
  self:_do_complete(ctx, callback)
end

--- @param data table
--- @param ctx cmp.SourceCompletionApiParams
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
