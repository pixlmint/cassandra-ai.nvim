--- Treesitter Context Provider
--- Extracts context from the syntax tree around the cursor position
local BaseContextProvider = require('cassandra_ai.context.base')

local TreesitterContextProvider = BaseContextProvider:new()

--- Create a new treesitter context provider
--- @param opts table|nil Configuration options
---   - max_context_size: number - Maximum characters to include (default: 500)
---   - include_parent_nodes: boolean - Include parent node context (default: true)
---   - node_types: table|nil - Specific node types to extract (default: all)
---   - context_lines: number - Number of lines to include from parent nodes (default: 5)
--- @return table The new provider instance
function TreesitterContextProvider:new(opts)
  local o = BaseContextProvider.new(self, opts)
  o.opts = vim.tbl_deep_extend('keep', opts or {}, {
    max_context_size = 500,
    include_parent_nodes = true,
    node_types = nil, -- nil means all types
    context_lines = 5,
  })
  setmetatable(o, self)
  self.__index = self
  return o
end

--- Check if treesitter is available
--- @return boolean
function TreesitterContextProvider:is_available()
  local status, _ = pcall(require, 'nvim-treesitter')
  return status and vim.treesitter.get_parser ~= nil
end

--- Get the name of this provider
--- @return string
function TreesitterContextProvider:get_name()
  return 'treesitter'
end

--- Get text content from a treesitter node
--- @param node table Treesitter node
--- @param bufnr number Buffer number
--- @return string Node text content
local function get_node_text(node, bufnr)
  if not node then return '' end

  local start_row, start_col, end_row, end_col = node:range()
  local lines = vim.api.nvim_buf_get_lines(bufnr, start_row, end_row + 1, false)

  if #lines == 0 then return '' end

  -- Handle single line
  if #lines == 1 then
    return string.sub(lines[1], start_col + 1, end_col)
  end

  -- Handle multiple lines
  lines[1] = string.sub(lines[1], start_col + 1)
  lines[#lines] = string.sub(lines[#lines], 1, end_col)

  return table.concat(lines, '\n')
end

--- Extract context from parent nodes
--- @param node table Current treesitter node
--- @param bufnr number Buffer number
--- @param opts table Provider options
--- @return string Parent context
local function extract_parent_context(node, bufnr, opts)
  local context_parts = {}
  local current = node:parent()
  local total_size = 0

  while current and total_size < opts.max_context_size do
    local node_type = current:type()

    -- Filter by node types if specified
    if not opts.node_types or vim.tbl_contains(opts.node_types, node_type) then
      local text = get_node_text(current, bufnr)
      local text_size = #text

      -- Don't exceed max context size
      if total_size + text_size <= opts.max_context_size then
        -- Add type annotation for clarity
        table.insert(context_parts, 1, string.format('-- [%s]\n%s', node_type, text))
        total_size = total_size + text_size
      else
        break
      end
    end

    current = current:parent()

    -- Limit depth
    if #context_parts >= 3 then
      break
    end
  end

  return table.concat(context_parts, '\n\n')
end

--- Extract context around the cursor using treesitter
--- @param node table Current treesitter node at cursor
--- @param bufnr number Buffer number
--- @param cursor_pos table Cursor position {line, col}
--- @param opts table Provider options
--- @return string Context information
local function extract_node_context(node, bufnr, cursor_pos, opts)
  if not node then return '' end

  local context_parts = {}
  local node_type = node:type()

  -- Get the current node info
  local node_text = get_node_text(node, bufnr)
  table.insert(context_parts, string.format('-- Current node: %s', node_type))

  -- Include parent context if enabled
  if opts.include_parent_nodes then
    local parent_context = extract_parent_context(node, bufnr, opts)
    if parent_context and parent_context ~= '' then
      table.insert(context_parts, '-- Parent context:')
      table.insert(context_parts, parent_context)
    end
  end

  local result = table.concat(context_parts, '\n')

  -- Truncate if too long
  if #result > opts.max_context_size then
    result = string.sub(result, 1, opts.max_context_size) .. '\n-- [truncated]'
  end

  return result
end

--- Get context synchronously
--- @param params table Context parameters
--- @return table Result with content and metadata
function TreesitterContextProvider:get_context_sync(params)
  local bufnr = params.bufnr
  local cursor_pos = params.cursor_pos

  -- Try to get parser for buffer
  local status, parser = pcall(vim.treesitter.get_parser, bufnr)
  if not status or not parser then
    return { content = '', metadata = { source = 'treesitter', error = 'No parser available' } }
  end

  -- Get syntax tree
  local trees = parser:parse()
  if not trees or #trees == 0 then
    return { content = '', metadata = { source = 'treesitter', error = 'No syntax tree' } }
  end

  local root = trees[1]:root()

  -- Get node at cursor position
  local node = root:named_descendant_for_range(cursor_pos.line, cursor_pos.col, cursor_pos.line, cursor_pos.col)

  if not node then
    return { content = '', metadata = { source = 'treesitter', error = 'No node at cursor' } }
  end

  -- Extract context
  local context = extract_node_context(node, bufnr, cursor_pos, self.opts)

  return {
    content = context,
    metadata = {
      source = 'treesitter',
      node_type = node:type(),
      has_parent_context = context:match('-- Parent context:') ~= nil,
    },
  }
end

return TreesitterContextProvider

