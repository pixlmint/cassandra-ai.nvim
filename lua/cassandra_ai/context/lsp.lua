--- LSP Context Provider
--- Uses treesitter to find identifiers near the cursor,
--- resolves their definitions via LSP, and returns the source code as context.
local BaseContextProvider = require('cassandra_ai.context.base')
local logger = require('cassandra_ai.logger')

local LspContextProvider = BaseContextProvider:new()

local get_clients = vim.lsp.get_clients

-- ---------------------------------------------------------------------------
-- Identifier extraction helpers
-- ---------------------------------------------------------------------------

local identifier_types = {
  identifier = true,
  type_identifier = true,
  field_identifier = true,
  property_identifier = true,
  shorthand_property_identifier = true,
  shorthand_property_identifier_pattern = true,
  jsx_identifier = true,
  private_property_identifier = true,
  namespace_identifier = true,
}

local skip_names_common = {
  ['true'] = true,
  ['false'] = true,
  ['null'] = true,
  ['nil'] = true,
}

local skip_names_by_ft = {
  javascript = { ['undefined'] = true, ['this'] = true, ['super'] = true },
  typescript = { ['undefined'] = true, ['this'] = true, ['super'] = true },
  typescriptreact = { ['undefined'] = true, ['this'] = true, ['super'] = true },
  javascriptreact = { ['undefined'] = true, ['this'] = true, ['super'] = true },
  python = { ['self'] = true, ['cls'] = true, ['True'] = true, ['False'] = true, ['None'] = true },
  java = { ['this'] = true, ['super'] = true },
  kotlin = { ['this'] = true, ['super'] = true },
  cs = { ['this'] = true, ['base'] = true },
  dart = { ['this'] = true, ['super'] = true },
  ruby = { ['self'] = true },
  php = { ['this'] = true, ['self'] = true, ['parent'] = true },
  c = { ['NULL'] = true },
  cpp = { ['this'] = true, ['NULL'] = true, ['nullptr'] = true },
  lua = { ['self'] = true },
  swift = { ['self'] = true, ['Self'] = true, ['super'] = true },
  rust = { ['self'] = true, ['Self'] = true },
}

local function should_skip_name(text, bufnr)
  if skip_names_common[text] then
    return true
  end
  local ft = vim.bo[bufnr or 0].filetype
  local ft_skips = skip_names_by_ft[ft]
  return ft_skips ~= nil and ft_skips[text] == true
end

--- Walk treesitter tree and collect unique identifiers in the given line range (1-indexed)
local function get_identifiers_in_range(bufnr, start_line, end_line)
  if not vim.treesitter or not vim.treesitter.get_parser then
    return {}
  end

  local ok, parser = pcall(vim.treesitter.get_parser, bufnr)
  if not ok or not parser then
    return {}
  end

  local trees = parser:parse()
  if not trees or not trees[1] then
    return {}
  end

  local identifiers = {}
  local seen = {}

  local function collect_from_tree(tree)
    local root = tree:root()

    local function visit(node)
      local sr, sc, er, _ = node:range()
      if sr > end_line - 1 then
        return
      end
      if er < start_line - 1 then
        return
      end

      local node_type = node:type()
      if identifier_types[node_type] then
        local text_ok, text = pcall(vim.treesitter.get_node_text, node, bufnr)
        if text_ok and text and text ~= '' and not should_skip_name(text, bufnr) and not seen[text] then
          seen[text] = true
          table.insert(identifiers, { name = text, line = sr, col = sc })
        end
      end

      for child in node:iter_children() do
        visit(child)
      end
    end

    visit(root)
  end

  for _, tree in ipairs(trees) do
    collect_from_tree(tree)
  end

  return identifiers
end

-- ---------------------------------------------------------------------------
-- LSP definition resolution
-- ---------------------------------------------------------------------------

local function make_position_params(bufnr, line, col)
  local row = line
  local line_text = vim.api.nvim_buf_get_lines(bufnr, row, row + 1, false)[1] or ''

  local clients = get_clients({ bufnr = bufnr })
  local offset_encoding = 'utf-16'
  for _, client in ipairs(clients) do
    if client.offset_encoding then
      offset_encoding = client.offset_encoding
      break
    end
  end

  local character = col
  if offset_encoding ~= 'utf-8' and col > 0 and col <= #line_text then
    local conv_ok, result = pcall(function()
      if vim.str_utfindex then
        return vim.str_utfindex(line_text, offset_encoding, col, false)
      elseif vim.lsp.util._str_utfindex_enc then
        return vim.lsp.util._str_utfindex_enc(line_text, col, offset_encoding)
      end
      return col
    end)
    if conv_ok and result then
      character = result
    end
  end

  return {
    textDocument = { uri = vim.uri_from_bufnr(bufnr) },
    position = { line = row, character = character },
  }
end

local function try_lsp_method(bufnr, method, params, timeout_ms)
  local results = vim.lsp.buf_request_sync(bufnr, method, params, timeout_ms)
  if not results then
    return nil
  end

  for _, res in pairs(results) do
    if res.result then
      local locations = res.result
      if type(locations) == 'table' then
        if locations[1] then
          return locations[1]
        elseif locations.uri or locations.targetUri then
          return locations
        end
      end
    end
  end

  return nil
end

local function lsp_get_definition(bufnr, line, col, timeout_ms)
  timeout_ms = timeout_ms or 2000

  local clients = get_clients({ bufnr = bufnr })
  if #clients == 0 then
    return nil
  end

  local params = make_position_params(bufnr, line, col)

  local methods = {
    'textDocument/definition',
    'textDocument/typeDefinition',
    'textDocument/implementation',
  }

  for _, method in ipairs(methods) do
    local result = try_lsp_method(bufnr, method, params, timeout_ms)
    if result then
      return result
    end
  end

  return nil
end

local function location_to_info(location)
  local uri = location.uri or location.targetUri
  local range = location.range or location.targetSelectionRange or location.targetRange
  if not uri or not range then
    return nil
  end

  local filepath = vim.uri_to_fname(uri)
  local start_line = (range.start and range.start.line or 0) + 1
  local end_line = (range['end'] and range['end'].line or start_line - 1) + 1

  return {
    filepath = filepath,
    start_line = start_line,
    end_line = end_line,
  }
end

-- ---------------------------------------------------------------------------
-- Definition code reading (treesitter-aware)
-- ---------------------------------------------------------------------------

local container_types = {
  function_declaration = true,
  function_definition = true,
  function_item = true,
  ['function'] = true,
  method_definition = true,
  method_declaration = true,
  class_declaration = true,
  class_definition = true,
  interface_declaration = true,
  type_alias_declaration = true,
  lexical_declaration = true,
  variable_declaration = true,
  const_declaration = true,
  let_declaration = true,
  export_statement = true,
  decorated_definition = true,
  assignment = true,
  struct_item = true,
  enum_item = true,
  impl_item = true,
  trait_item = true,
  union_item = true,
  const_item = true,
  static_item = true,
  type_item = true,
  mod_item = true,
  macro_definition = true,
  type_declaration = true,
  type_spec = true,
  type_alias = true,
  constructor_declaration = true,
  field_declaration = true,
  enum_declaration = true,
  record_declaration = true,
  struct_declaration = true,
  property_declaration = true,
  namespace_declaration = true,
  namespace_definition = true,
  delegate_declaration = true,
  event_declaration = true,
  operator_declaration = true,
  declaration = true,
  type_definition = true,
  struct_specifier = true,
  enum_specifier = true,
  union_specifier = true,
  class_specifier = true,
  template_declaration = true,
  alias_declaration = true,
  using_declaration = true,
  ['method'] = true,
  ['module'] = true,
  singleton_method = true,
  object_declaration = true,
  trait_declaration = true,
  mixin_declaration = true,
  extension_declaration = true,
}

--- Read the definition code at filepath:start_line, using treesitter to find the containing declaration.
--- Falls back to reading max_lines raw lines.
local function read_definition_code(filepath, start_line, max_lines)
  max_lines = max_lines or 50

  local ok, lines = pcall(vim.fn.readfile, filepath)
  if not ok or not lines then
    return nil, nil
  end

  -- Fallback: return raw lines
  local function fallback()
    local end_line = math.min(start_line + max_lines - 1, #lines)
    local code_lines = {}
    for i = start_line, end_line do
      table.insert(code_lines, lines[i])
    end
    return table.concat(code_lines, '\n'), end_line
  end

  if not vim.treesitter then
    return fallback()
  end

  local ft = vim.filetype.match({ filename = filepath })
  if not ft then
    return fallback()
  end

  local content = table.concat(lines, '\n')
  local parser_ok, parser = pcall(vim.treesitter.get_string_parser, content, ft)
  if not parser_ok or not parser then
    return fallback()
  end

  local trees = parser:parse()
  if not trees or not trees[1] then
    return fallback()
  end

  local root = trees[1]:root()
  local target_row = start_line - 1
  local node = root:named_descendant_for_range(target_row, 0, target_row, 0)

  while node do
    if container_types[node:type()] then
      local sr, _, er, ec = node:range()
      local actual_end = er + 1
      if ec == 0 and er > sr then
        actual_end = er
      end
      -- Clamp to max_lines
      if actual_end - sr > max_lines then
        actual_end = sr + max_lines
      end
      local code_lines = {}
      for i = sr + 1, actual_end do
        table.insert(code_lines, lines[i])
      end
      return table.concat(code_lines, '\n'), actual_end
    end
    node = node:parent()
  end

  return fallback()
end

-- ---------------------------------------------------------------------------
-- Provider implementation
-- ---------------------------------------------------------------------------

--- Create a new LSP context provider
--- @param opts table|nil Configuration options
---   - max_definitions: number - Maximum definitions to include (default: 5)
---   - max_lines_per_definition: number - Max lines per definition (default: 50)
---   - context_range: number - Lines before/after cursor to scan for identifiers (default: 10)
---   - timeout_ms: number - Per-definition LSP timeout in ms (default: 2000)
--- @return table The new provider instance
function LspContextProvider:new(opts)
  local o = BaseContextProvider.new(self, opts)
  o.opts = vim.tbl_deep_extend('keep', opts or {}, {
    max_definitions = 5,
    max_lines_per_definition = 50,
    context_range = 10,
    timeout_ms = 2000,
  })
  setmetatable(o, self)
  self.__index = self
  return o
end

--- Check if LSP and treesitter are available
--- @return boolean
function LspContextProvider:is_available()
  return vim.lsp ~= nil and vim.treesitter ~= nil
end

--- Get the name of this provider
--- @return string
function LspContextProvider:get_name()
  return 'lsp'
end

--- Get context from LSP definitions of identifiers near the cursor
--- @param params table Context parameters (bufnr, cursor_pos, lines_before, lines_after, filetype)
--- @param callback function Callback for result
function LspContextProvider:get_context(params, callback)
  local bufnr = params.bufnr or 0
  local cursor_line = params.cursor_pos and params.cursor_pos.line or 0 -- 0-indexed
  local max_lines = require('cassandra_ai.config'):get('max_lines') or 50

  -- Check for LSP clients
  local clients = get_clients({ bufnr = bufnr })
  if #clients == 0 then
    logger.trace('lsp: no LSP clients attached')
    callback({ content = '', metadata = { source = 'lsp', definitions_count = 0 } })
    return
  end

  -- Compute scan range around cursor (1-indexed for treesitter helper)
  local line_count = vim.api.nvim_buf_line_count(bufnr)
  local start_line = math.max(1, cursor_line + 1 - self.opts.context_range)
  local end_line = math.min(line_count, cursor_line + 1 + self.opts.context_range)

  logger.trace('lsp: scanning identifiers in lines ' .. start_line .. '-' .. end_line)

  local identifiers = get_identifiers_in_range(bufnr, start_line, end_line)
  if #identifiers == 0 then
    logger.trace('lsp: no identifiers found')
    callback({ content = '', metadata = { source = 'lsp', definitions_count = 0 } })
    return
  end

  logger.trace('lsp: found ' .. #identifiers .. ' identifier(s)')

  local current_filepath = vim.api.nvim_buf_get_name(bufnr)
  local visible_start = cursor_line + 1 - max_lines
  local visible_end = cursor_line + 1 + max_lines

  local definitions = {}
  local seen_locations = {}

  for _, ident in ipairs(identifiers) do
    if #definitions >= self.opts.max_definitions then
      break
    end

    local location = lsp_get_definition(bufnr, ident.line, ident.col, self.opts.timeout_ms)
    if location then
      local info = location_to_info(location)
      if info then
        local key = info.filepath .. ':' .. info.start_line
        if not seen_locations[key] then
          seen_locations[key] = true

          -- Skip definitions in the same file that are already visible in the context window
          local same_file = info.filepath == current_filepath
          local in_visible_range = info.start_line >= visible_start and info.start_line <= visible_end
          if not (same_file and in_visible_range) then
            local code, actual_end = read_definition_code(info.filepath, info.start_line, self.opts.max_lines_per_definition)
            if code and code ~= '' then
              table.insert(definitions, {
                name = ident.name,
                filepath = info.filepath,
                start_line = info.start_line,
                end_line = actual_end,
                code = code,
              })
            end
          end
        end
      end
    end
  end

  if #definitions == 0 then
    logger.trace('lsp: no external definitions resolved')
    callback({ content = '', metadata = { source = 'lsp', definitions_count = 0 } })
    return
  end

  -- Format definitions for the AI model
  local cwd = vim.fn.getcwd()
  local parts = { '-- LSP Definitions:' }
  for _, def in ipairs(definitions) do
    local display_path = def.filepath
    if cwd and vim.startswith(def.filepath, cwd) then
      display_path = def.filepath:sub(#cwd + 2)
    end
    table.insert(parts, '-- definition: ' .. def.name .. ' (' .. display_path .. ':' .. def.start_line .. ')')
    table.insert(parts, def.code)
  end

  local content = table.concat(parts, '\n')
  logger.trace('lsp: returning ' .. #definitions .. ' definition(s)')
  callback({ content = content, metadata = { source = 'lsp', definitions_count = #definitions } })
end

return LspContextProvider
