--- Language Handler Loader
--- Loads language-specific context extraction logic

local M = {}

--- Cache for loaded language handlers
local handlers = {}

--- Map filetypes to language handlers
local filetype_map = {
  python = 'python',
  php = 'php',
  javascript = 'javascript',
  typescript = 'javascript', -- Use same handler
  javascriptreact = 'javascript',
  typescriptreact = 'javascript',
  -- Add more mappings as needed
}

--- Get language handler for a filetype
--- @param filetype string The filetype
--- @return table Language handler module
function M.get_handler(filetype)
  -- Check if handler is already loaded
  if handlers[filetype] then
    return handlers[filetype]
  end

  -- Get the handler name from filetype
  local handler_name = filetype_map[filetype]

  if not handler_name then
    -- Try to load handler with same name as filetype
    local status, handler = pcall(require, 'cassandra_ai.context.languages.' .. filetype)
    if status then
      handlers[filetype] = handler
      return handler
    end

    -- Fall back to base handler
    handler = require('cassandra_ai.context.languages.base')
    handlers[filetype] = handler
    return handler
  end

  -- Load the mapped handler
  local status, handler = pcall(require, 'cassandra_ai.context.languages.' .. handler_name)
  if status then
    handlers[filetype] = handler
    return handler
  end

  -- Fall back to base handler
  handler = require('cassandra_ai.context.languages.base')
  handlers[filetype] = handler
  return handler
end

--- Check if a language handler exists for a filetype
--- @param filetype string The filetype
--- @return boolean
function M.has_handler(filetype)
  return filetype_map[filetype] ~= nil or
      pcall(require, 'cassandra_ai.context.languages.' .. filetype)
end

--- Get list of supported languages
--- @return table List of supported filetypes
function M.get_supported_languages()
  local supported = {}
  for ft, _ in pairs(filetype_map) do
    table.insert(supported, ft)
  end
  return supported
end

return M
