--- File-based logger for cassandra-ai
local M = {}

local LEVELS = {
  TRACE = 1,
  DEBUG = 2,
  INFO = 3,
  WARN = 4,
  ERROR = 5,
}

local LEVEL_NAMES = { 'TRACE', 'DEBUG', 'INFO', 'WARN', 'ERROR' }

local state = {
  initialized = false,
  log_file = nil,
  log_level = LEVELS.WARN,
}

--- Initialize the logger
--- @param opts table { log_file: string, log_level: string }
function M.init(opts)
  opts = opts or {}
  if opts.log_file then
    state.log_file = opts.log_file
  end
  if opts.log_level then
    local level = LEVELS[opts.log_level:upper()]
    if level then
      state.log_level = level
    end
  end
  state.initialized = true
end

--- Ensure the log directory exists and return the file path
--- @return string|nil
local function ensure_log_file()
  if not state.log_file then
    return nil
  end
  local dir = vim.fn.fnamemodify(state.log_file, ':h')
  if vim.fn.isdirectory(dir) == 0 then
    vim.fn.mkdir(dir, 'p')
  end
  return state.log_file
end

--- Write a log entry to file
--- @param level number
--- @param msg string
local function write(level, msg)
  if not state.initialized or level < state.log_level then
    return
  end
  local path = ensure_log_file()
  if not path then
    return
  end
  local timestamp = os.date('%Y-%m-%d %H:%M:%S')
  local level_name = LEVEL_NAMES[level] or 'UNKNOWN'
  local entry = string.format('[%s] [%s] %s\n', timestamp, level_name, msg)
  local f = io.open(path, 'a')
  if f then
    f:write(entry)
    f:close()
  end
end

function M.trace(msg)
  write(LEVELS.TRACE, msg)
end

function M.debug(msg)
  write(LEVELS.DEBUG, msg)
end

function M.info(msg)
  write(LEVELS.INFO, msg)
end

function M.warn(msg)
  write(LEVELS.WARN, msg)
end

function M.error(msg)
  write(LEVELS.ERROR, msg)
end

--- Format and log a message with string.format
--- @param level string 'debug'|'info'|'warn'|'error'
--- @param fmt string
--- @param ... any
function M.fmt(level, fmt, ...)
  local fn = M[level]
  if fn then
    fn(string.format(fmt, ...))
  end
end

--- Get the log file path
--- @return string|nil
function M.get_log_file()
  return state.log_file
end

--- Get available log levels
--- @return table
function M.get_levels()
  return LEVELS
end

return M
