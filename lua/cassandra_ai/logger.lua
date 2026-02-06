--- Logger module for cassandra-ai data collection
--- Implements fire-and-forget async writes with buffering

local Logger = {}
Logger.__index = Logger

-- Singleton instance
local instance = nil

-- Default config
local default_config = {
  enabled = false,
  data_file = vim.fn.stdpath('data') .. '/cassandra-ai/completions.jsonl',
  buffer_size = 50,
}

-- State
local config = vim.deepcopy(default_config)
local buffer = {}
local write_in_progress = false
local flush_timer = nil

--- Initialize logger with config
--- @param user_config table Configuration options
function Logger:init(user_config)
  config = vim.tbl_extend('force', default_config, user_config or {})
  buffer = {}
  write_in_progress = false

  if config.enabled then
    self:_setup_autocmds()
    self:_setup_timer()
  end

  return self
end

--- Check if logging is enabled
--- @return boolean
function Logger:is_enabled()
  return config.enabled
end

--- Log a request event
--- @param request_id string UUID for this request
--- @param data table Request data (cwd, filename, filetype, cursor, lines_before, lines_after, provider, provider_config)
function Logger:log_request(request_id, data)
  if not config.enabled then
    return
  end

  local entry = {
    event_type = 'request',
    request_id = request_id,
    timestamp = os.time(),
    cwd = data.cwd,
    filename = data.filename,
    filetype = data.filetype,
    cursor = data.cursor,
    lines_before = data.lines_before,
    lines_after = data.lines_after,
    provider = data.provider,
    provider_config = data.provider_config,
  }

  self:_add_to_buffer(entry)
end

--- Log a response event
--- @param request_id string UUID for this request
--- @param data table Response data (response_raw, completions, response_time_ms)
function Logger:log_response(request_id, data)
  if not config.enabled then
    return
  end

  local entry = {
    event_type = 'response',
    request_id = request_id,
    timestamp = os.time(),
    response_raw = data.response_raw,
    completions = data.completions,
    response_time_ms = data.response_time_ms,
  }

  self:_add_to_buffer(entry)
end

--- Log an acceptance event
--- @param request_id string UUID for this request
--- @param data table Acceptance data (accepted, accepted_item_label)
function Logger:log_acceptance(request_id, data)
  if not config.enabled then
    return
  end

  local entry = {
    event_type = 'acceptance',
    request_id = request_id,
    timestamp = os.time(),
    accepted = data.accepted,
    accepted_item_label = data.accepted_item_label,
  }

  self:_add_to_buffer(entry)
end

--- Add entry to buffer and flush if needed
--- @param entry table The log entry to add
function Logger:_add_to_buffer(entry)
  table.insert(buffer, entry)

  if #buffer >= config.buffer_size then
    self:flush()
  end
end

--- Flush buffer to disk (fire-and-forget async)
function Logger:flush()
  if not config.enabled or #buffer == 0 then
    return
  end

  -- Skip write if already in progress (better to lose data than block)
  if write_in_progress then
    return
  end

  -- Ensure directory exists
  self:_ensure_directory()

  -- Copy buffer and clear it immediately
  local entries_to_write = vim.deepcopy(buffer)
  buffer = {}

  -- Convert entries to JSONL string
  local lines = {}
  for _, entry in ipairs(entries_to_write) do
    local ok, json = pcall(vim.json.encode, entry)
    if ok then
      table.insert(lines, json)
    end
  end

  if #lines == 0 then
    return
  end

  local jsonl_content = table.concat(lines, '\n') .. '\n'

  -- Fire-and-forget write using jobstart
  write_in_progress = true

  local job_id = vim.fn.jobstart({ 'sh', '-c', 'cat >> ' .. vim.fn.shellescape(config.data_file) }, {
    detach = true,
    stdin = 'pipe',
    stdout = false,
    stderr = false,
    on_exit = function(_, exit_code, _)
      write_in_progress = false

      -- Optional: notify on error if log_errors is configured
      if exit_code ~= 0 then
        local cassandra_ai_config = require('cassandra_ai.config')
        if cassandra_ai_config and cassandra_ai_config:get('log_errors') then
          vim.notify(
            string.format('cassandra-ai: Failed to write data log (exit code %d)', exit_code),
            vim.log.levels.WARN
          )
        end
      end
    end,
  })

  -- Send data to stdin and close it
  if job_id > 0 then
    vim.fn.chansend(job_id, jsonl_content)
    vim.fn.chanclose(job_id, 'stdin')
  else
    write_in_progress = false
  end
end

--- Synchronous flush for shutdown
function Logger:shutdown()
  if not config.enabled or #buffer == 0 then
    return
  end

  -- Stop timer
  if flush_timer then
    flush_timer:stop()
    flush_timer:close()
    flush_timer = nil
  end

  -- Ensure directory exists
  self:_ensure_directory()

  -- Convert buffer to JSONL
  local lines = {}
  for _, entry in ipairs(buffer) do
    local ok, json = pcall(vim.json.encode, entry)
    if ok then
      table.insert(lines, json)
    end
  end

  if #lines == 0 then
    return
  end

  local jsonl_content = table.concat(lines, '\n') .. '\n'

  -- Synchronous write for shutdown
  local file = io.open(config.data_file, 'a')
  if file then
    file:write(jsonl_content)
    file:close()
  end

  buffer = {}
end

--- Ensure data directory exists
function Logger:_ensure_directory()
  local dir = vim.fn.fnamemodify(config.data_file, ':h')
  if vim.fn.isdirectory(dir) == 0 then
    vim.fn.mkdir(dir, 'p')
  end
end

--- Setup autocmds for shutdown
function Logger:_setup_autocmds()
  vim.api.nvim_create_autocmd('VimLeavePre', {
    callback = function()
      Logger:shutdown()
    end,
    desc = 'Flush cassandra-ai data collection buffer on exit',
  })
end

--- Setup periodic flush timer (30s)
function Logger:_setup_timer()
  if flush_timer then
    return
  end

  flush_timer = vim.loop.new_timer()
  flush_timer:start(
    30000, -- 30 seconds
    30000, -- repeat every 30 seconds
    vim.schedule_wrap(function()
      self:flush()
    end)
  )
end

-- Return singleton instance
if not instance then
  instance = setmetatable({}, Logger)
end

return instance
