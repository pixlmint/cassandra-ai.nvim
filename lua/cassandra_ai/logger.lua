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

local function create_log_function(level, notify_level)
  return function(msg)
    if not state.initialized or level < state.log_level then
      return
    end
    if notify_level == nil then
      print(msg)
    else
      vim.notify(msg, notify_level)
    end
    write(level, msg)
  end
end

M.trace = create_log_function(LEVELS.TRACE)

M.debug = create_log_function(LEVELS.DEBUG)

M.info = create_log_function(LEVELS.INFO)

M.warn = create_log_function(LEVELS.WARN, vim.log.levels.WARN)

M.error = create_log_function(LEVELS.ERROR, vim.log.levels.ERROR)

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

--- Set the log level at runtime
--- @param level_str string One of TRACE, DEBUG, INFO, WARN, ERROR
function M.set_log_level(level_str)
  local level = LEVELS[level_str:upper()]
  if level then
    state.log_level = level
  end
end

--- Get available log levels
--- @return table
function M.get_levels()
  return LEVELS
end

return M
