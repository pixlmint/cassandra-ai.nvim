--- Base class for context providers
--- All context providers should inherit from this class
local BaseContextProvider = {}

--- Create a new context provider instance
--- @param opts table|nil User configuration options
--- @return table The new context provider instance
function BaseContextProvider:new(opts)
  local o = {
    opts = opts or {},
  }
  setmetatable(o, self)
  self.__index = self
  return o
end

--- Get context asynchronously
--- This is the main method that subclasses should implement
--- @param params table Context parameters containing:
---   - bufnr: number - Buffer number
---   - cursor_pos: table - Cursor position {line, col}
---   - lines_before: string - Code before cursor
---   - lines_after: string - Code after cursor
---   - filetype: string - Buffer filetype
--- @param callback function - Callback to invoke with result
---   Callback signature: function(result)
---   Result format: { content = string, metadata = table }
function BaseContextProvider:get_context(params, callback)
  -- Default implementation: call sync version if available
  if self.get_context_sync then
    local result = self:get_context_sync(params)
    callback(result)
  else
    -- No context by default
    callback({ content = '', metadata = { source = 'base' } })
  end
end

--- Get context synchronously (optional)
--- Subclasses can implement this for simple, non-async providers
--- @param params table Same as get_context
--- @return table Result in format { content = string, metadata = table }
function BaseContextProvider:get_context_sync(params)
  return { content = '', metadata = { source = 'base' } }
end

--- Check if this provider is available in the current environment
--- Subclasses can override this to check for dependencies (e.g., treesitter, LSP)
--- @return boolean true if provider can be used
function BaseContextProvider:is_available()
  return true
end

--- Get the name of this provider (for logging/debugging)
--- @return string The provider name
function BaseContextProvider:get_name()
  return 'base'
end

return BaseContextProvider
