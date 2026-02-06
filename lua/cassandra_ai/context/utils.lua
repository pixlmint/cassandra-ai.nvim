local M = {}

-- Helper function to check if file has any non-comment code
local function has_code(bufnr)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local parser = vim.treesitter.get_parser(bufnr)
  if not parser then
    -- Fallback: check for non-empty, non-whitespace lines
    for _, line in ipairs(lines) do
      if line:match('^%s*$') == nil then
        return true
      end
    end
    return false
  end

  local tree = parser:parse()[1]
  local root = tree:root()

  -- If there are any non-comment nodes, we have code
  for node in root:iter_children() do
    if node:type() ~= 'comment' then
      return true
    end
  end

  return false
end

-- Detect the current suggestion context using LSP
-- Returns: "init", "comment_func", "impl", or "unknown"
--- @param bufnr number
--- @param pos table
--- @param callback fun(suggestion_context: string)
function M.detect_suggestion_context(bufnr, pos, callback)
  -- TODO: Detection probably doesn't need to use Treesitter
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  pos = pos or vim.api.nvim_win_get_cursor(0)

  -- Check if we have any code in the file
  if not has_code(bufnr) then
    callback('init')
    return
  end

  -- Load treesitter textobjects if available
  local ok, textobjects = pcall(require, 'nvim-treesitter-textobjects.shared')
  if not ok then
    -- No treesitter available, fall back to LSP-only detection
    M.detect_suggestion_context_lsp_only(bufnr, pos, callback)
    return
  end

  -- Check if we're in a comment
  local comment_match = textobjects.textobject_at_point('@comment.outer', 'textobjects', bufnr, pos)

  if comment_match and #comment_match >= 4 then
    -- We're in a comment, check if it's a function doc comment
    local comment_end_line = comment_match[4] + 1
    local next_line_pos = { comment_end_line + 1, comment_match[5] }

    -- Check for function after comment
    local func_match = textobjects.textobject_at_point('@function.outer', 'textobjects', bufnr, next_line_pos)
    if func_match and #func_match >= 4 then
      callback('comment_func')
      return
    end

    -- Generic comment (not a function doc comment)
    callback('unknown')
    return
  end

  -- Use LSP to determine if we're inside a function
  M.detect_suggestion_context_lsp_only(bufnr, pos, callback)
end

-- Helper function to detect context using only LSP (no treesitter textobjects)
function M.detect_suggestion_context_lsp_only(bufnr, pos, callback)
  local current_line_num = pos[1] -- pos is 1-indexed

  -- Get all functions in the file via LSP
  M.find_functions_via_lsp_async(bufnr, 1, math.huge, function(functions)
    -- Check if current line is within any function range
    for _, func in ipairs(functions) do
      if current_line_num >= func.line and current_line_num <= func.end_line then
        callback('impl')
        return
      end
    end

    -- Not in any function, not in a function doc comment
    callback('unknown')
  end)
end

-- LSP function discovery
-- Copied from https://github.com/oribarilan/lensline.nvim/blob/main/lua/lensline/lens_explorer.lua on 2026-01-31
local function_cache = {}
local buffer_changedtick = {}
local cache_access_order = {} -- Track access order for LRU eviction
local MAX_CACHE_SIZE = 50     -- Limit cache to 50 buffers maximum


-- LRU cache management functions
local function update_access_order(bufnr)
  -- Remove bufnr from current position if it exists
  for i, cached_bufnr in ipairs(cache_access_order) do
    if cached_bufnr == bufnr then
      table.remove(cache_access_order, i)
      break
    end
  end
  -- Add to end (most recently used)
  table.insert(cache_access_order, bufnr)
end

local function evict_lru_if_needed()
  while #cache_access_order > MAX_CACHE_SIZE do
    local lru_bufnr = table.remove(cache_access_order, 1) -- Remove least recently used
    function_cache[lru_bufnr] = nil
    buffer_changedtick[lru_bufnr] = nil
  end
end

-- Recursively extract function/method symbols from LSP response
-- Helper function to identify legitimately named functions (not anonymous)
local function is_named_function(symbol)
  -- Only check Functions, not Methods or Constructors
  if symbol.kind ~= vim.lsp.protocol.SymbolKind.Function then
    return false
  end

  -- Must have a name
  if not symbol.name then
    return false
  end

  -- Name must not be empty/whitespace
  if not symbol.name:match("%S") then
    return false
  end

  -- Skip generic names that indicate anonymous functions
  local lower_name = symbol.name:lower()
  if lower_name == "function" or
      lower_name == "lambda" or
      lower_name == "anonymous" or
      symbol.name:match("^function%(") or -- Lua-style "function(" pattern
      symbol.name:match("^vim%.") or      -- Skip Neovim API wrappers
      symbol.name:match("^%[%d+%]$") then -- LSP array-style anonymous functions "[1]", "[2]", required for lua_ls
    return false
  end

  return true
end

-- Helper to get lsp clients (works with newer and older nvim versions)
function M.get_lsp_clients(bufnr)
  if vim.lsp.get_clients then
    return vim.lsp.get_clients({ bufnr = bufnr })
  else
    return vim.lsp.get_active_clients({ bufnr = bufnr })
  end
end

-- Check if any LSP client supports a specific method for the buffer
function M.has_lsp_capability(bufnr, method)
  local clients = M.get_lsp_clients(bufnr)
  if not clients or #clients == 0 then
    return false
  end

  for _, client in ipairs(clients) do
    -- Check if client supports the method
    if client.server_capabilities then
      -- Only check the methods we actually use in this plugin
      -- Note: lens_explorer.lua only handles core capabilities for function discovery.
      -- Additional LSP capabilities (textDocument/definition, textDocument/implementation)
      -- are handled in utils.lua for provider-specific features like the usages provider.
      local capability_map = {
        ["textDocument/references"] = "referencesProvider",
        ["textDocument/documentSymbol"] = "documentSymbolProvider",
      }

      local capability_key = capability_map[method]
      if capability_key and client.server_capabilities[capability_key] then
        return true
      end
    end
  end

  return false
end

function M.extract_symbols_recursive(symbols, functions, start_line, end_line)
  for _, symbol in ipairs(symbols) do
    -- Identify symbol kinds we care about (function / method / constructor)
    local symbol_kinds = {
      [vim.lsp.protocol.SymbolKind.Function] = true,
      [vim.lsp.protocol.SymbolKind.Method] = true,
      [vim.lsp.protocol.SymbolKind.Constructor] = true,
    }

    if symbol_kinds[symbol.kind] then
      local include = true
      -- Only add plain Functions if they are "named" per our heuristic
      if symbol.kind == vim.lsp.protocol.SymbolKind.Function and not is_named_function(symbol) then
        include = false -- (previously used Lua 5.2 goto to "continue"; rewritten for 5.1 portability)
      end

      if include then
        local line_num
        local end_line_num
        local character

        -- Handle both DocumentSymbol and SymbolInformation formats
        if symbol.range then
          -- DocumentSymbol format
          line_num = symbol.range.start.line + 1      -- Convert to 1-indexed
          end_line_num = symbol.range["end"].line + 1 -- Convert to 1-indexed
          character = symbol.range.start.character
        elseif symbol.location then
          -- SymbolInformation format
          line_num = symbol.location.range.start.line + 1
          end_line_num = symbol.location.range["end"].line + 1
          character = symbol.location.range.start.character
        end

        if line_num and line_num >= start_line and line_num <= end_line then
          table.insert(functions, {
            line = line_num,
            end_line = end_line_num,
            character = character,
            name = symbol.name,
            kind = symbol.kind
          })
        end
      end
    end
    -- Recursively process children if they exist
    if symbol.children then
      M.extract_symbols_recursive(symbol.children, functions, start_line, end_line)
    end
  end
end

-- Use LSP document symbols to find functions (async version - eliminates UI hang)
function M.find_functions_via_lsp_async(bufnr, start_line, end_line, callback)
  local clients = M.get_lsp_clients(bufnr)
  if not clients or #clients == 0 then
    callback({})
    return
  end

  -- Check if any LSP client supports document symbols
  if not M.has_lsp_capability(bufnr, "textDocument/documentSymbol") then
    callback({})
    return
  end

  -- Check cache validity using buffer's changedtick
  local current_changedtick = vim.api.nvim_buf_get_changedtick(bufnr)
  local cache_key = bufnr

  if function_cache[cache_key] and buffer_changedtick[cache_key] == current_changedtick then
    -- Cache hit - update LRU order and filter functions for requested range
    update_access_order(cache_key)
    local cached_functions = function_cache[cache_key]
    local filtered_functions = {}
    for _, func in ipairs(cached_functions) do
      if func.line >= start_line and func.line <= end_line then
        table.insert(filtered_functions, func)
      end
    end
    callback(filtered_functions)
    return
  end

  local params = {
    textDocument = vim.lsp.util.make_text_document_params(bufnr)
  }

  -- Add timing logs around the async LSP call
  -- local start_time = vim.loop.hrtime()

  vim.lsp.buf_request(bufnr, "textDocument/documentSymbol", params, function(err, results)
    -- local end_time = vim.loop.hrtime()
    -- local duration_ms = (end_time - start_time) / 1000000 -- Convert to milliseconds

    if err or not results then
      callback({})
      return
    end

    local functions = {}

    -- Process async results - different format than sync version
    -- In async callback, 'results' is the direct LSP response, not wrapped in client responses
    if results and type(results) == "table" then
      M.extract_symbols_recursive(results, functions, 1, math.huge)
    end

    -- Cache the complete function list for this buffer with LRU management
    -- NOTE: Race condition possible here - if rapid saves occur, an older
    -- request might overwrite newer cache data. This causes temporary stale
    -- lenses until next edit. Can add changedtick validation if needed:
    -- if vim.api.nvim_buf_get_changedtick(bufnr) == current_changedtick then
    function_cache[cache_key] = functions
    buffer_changedtick[cache_key] = current_changedtick
    update_access_order(cache_key)
    evict_lru_if_needed()

    -- Return filtered results for the requested range
    local filtered_functions = {}
    for _, func in ipairs(functions) do
      if func.line >= start_line and func.line <= end_line then
        table.insert(filtered_functions, func)
      end
    end

    callback(filtered_functions)
  end)
end

return M
