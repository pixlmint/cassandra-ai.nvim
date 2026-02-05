--- Diagnostics Context Provider
--- Extracts diagnostic messages from LSP
local BaseContextProvider = require('cmp_ai.context.base')

local DiagnosticsContextProvider = BaseContextProvider:new()

--- Create a new diagnostics context provider
--- @param opts table|nil Configuration options
---   - include_diagnostics: boolean - Include diagnostic messages (default: true)
---   - include_hover: boolean - Include hover information (default: false)
---   - include_symbols: boolean - Include document symbols (default: true)
---   - max_symbols: number - Maximum number of symbols to include (default: 3)
---   - max_diagnostics: number - Maximum diagnostics to include (default: 3)
---   - diagnostic_range: number - Lines before/after cursor to check (default: 10)
--- @return table The new provider instance
function DiagnosticsContextProvider:new(opts)
  local o = BaseContextProvider.new(self, opts)
  o.opts = vim.tbl_deep_extend('keep', opts or {}, {
    include_diagnostics = true,
    include_hover = false,
    include_symbols = true,
    max_symbols = 3,
    max_diagnostics = 3,
    diagnostic_range = 10,
  })
  setmetatable(o, self)
  self.__index = self
  return o
end

--- Check if diagnostics are available
--- @return boolean
function DiagnosticsContextProvider:is_available()
  return vim.diagnostic ~= nil
end

--- Get the name of this provider
--- @return string
function DiagnosticsContextProvider:get_name()
  return 'diagnostics'
end

--- Format diagnostic message
--- @param diagnostic table Diagnostic object
--- @return string Formatted diagnostic
local function format_diagnostic(diagnostic)
  local severity_map = {
    [vim.diagnostic.severity.ERROR] = 'ERROR',
    [vim.diagnostic.severity.WARN] = 'WARN',
    [vim.diagnostic.severity.INFO] = 'INFO',
    [vim.diagnostic.severity.HINT] = 'HINT',
  }

  local severity = severity_map[diagnostic.severity] or 'INFO'
  local line = diagnostic.lnum + 1 -- Convert to 1-indexed
  return string.format('[%s] Line %d: %s', severity, line, diagnostic.message)
end

--- Get diagnostics near cursor
--- @param bufnr number Buffer number
--- @param cursor_line number Cursor line (0-indexed)
--- @param opts table Provider options
--- @return string Formatted diagnostics
local function get_diagnostics(bufnr, cursor_line, opts)
  if not opts.include_diagnostics then
    return ''
  end

  local range_start = math.max(0, cursor_line - opts.diagnostic_range)
  local range_end = cursor_line + opts.diagnostic_range

  local diagnostics = vim.diagnostic.get(bufnr, {
    lnum = cursor_line,
  })

  -- Also get diagnostics in the range
  local all_diagnostics = vim.diagnostic.get(bufnr)
  for _, diag in ipairs(all_diagnostics) do
    if diag.lnum >= range_start and diag.lnum <= range_end and diag.lnum ~= cursor_line then
      table.insert(diagnostics, diag)
    end
  end

  -- Sort by severity and limit
  table.sort(diagnostics, function(a, b)
    return a.severity < b.severity
  end)

  local formatted = {}
  for i, diag in ipairs(diagnostics) do
    if i > opts.max_diagnostics then break end
    table.insert(formatted, format_diagnostic(diag))
  end

  if #formatted > 0 then
    return '-- LSP Diagnostics:\n' .. table.concat(formatted, '\n')
  end

  return ''
end

--- Get document symbols near cursor
--- @param bufnr number Buffer number
--- @param cursor_pos table Cursor position {line, col}
--- @param opts table Provider options
--- @return string Formatted symbols
local function get_symbols(bufnr, cursor_pos, opts)
  if not opts.include_symbols then
    return ''
  end

  local clients = vim.lsp.get_active_clients({ bufnr = bufnr })
  if #clients == 0 then
    return ''
  end

  -- Try to get symbols from LSP (this is simplified - real implementation would be async)
  -- For now, we'll use a simpler approach with treesitter or vim's built-in functionality

  -- Get function/class name at cursor using LSP's textDocument/documentSymbol
  -- This is a synchronous approximation - a full implementation would need async handling

  return '' -- Placeholder - full async symbol fetching would go here
end

--- Get hover information at cursor
--- @param bufnr number Buffer number
--- @param cursor_pos table Cursor position {line, col}
--- @param opts table Provider options
--- @param callback function Callback for async result
local function get_hover_async(bufnr, cursor_pos, opts, callback)
  if not opts.include_hover then
    callback('')
    return
  end

  local clients = vim.lsp.get_active_clients({ bufnr = bufnr })
  if #clients == 0 then
    callback('')
    return
  end

  -- Request hover information
  local params = {
    textDocument = vim.lsp.util.make_text_document_params(bufnr),
    position = { line = cursor_pos.line, character = cursor_pos.col },
  }

  local hover_results = {}
  local responses_received = 0
  local total_clients = #clients

  for _, client in ipairs(clients) do
    if client.server_capabilities.hoverProvider then
      client.request('textDocument/hover', params, function(err, result)
        responses_received = responses_received + 1

        if not err and result and result.contents then
          local contents = result.contents
          if type(contents) == 'string' then
            table.insert(hover_results, contents)
          elseif contents.value then
            table.insert(hover_results, contents.value)
          end
        end

        -- All responses received
        if responses_received >= total_clients then
          if #hover_results > 0 then
            callback('-- LSP Hover:\n' .. table.concat(hover_results, '\n'))
          else
            callback('')
          end
        end
      end, bufnr)
    else
      responses_received = responses_received + 1
      if responses_received >= total_clients then
        callback('')
      end
    end
  end

  -- Handle case where no clients support hover
  if total_clients == 0 or responses_received >= total_clients then
    callback('')
  end
end

--- Get context from diagnostics
--- @param params table Context parameters
--- @param callback function Callback for result
function DiagnosticsContextProvider:get_context(params, callback)
  local bufnr = params.bufnr
  local cursor_pos = params.cursor_pos

  local context_parts = {}

  -- Get diagnostics (synchronous)
  local diagnostics = get_diagnostics(bufnr, cursor_pos.line, self.opts)
  if diagnostics ~= '' then
    table.insert(context_parts, diagnostics)
  end

  -- Get symbols (synchronous for now)
  local symbols = get_symbols(bufnr, cursor_pos, self.opts)
  if symbols ~= '' then
    table.insert(context_parts, symbols)
  end

  -- Get hover (asynchronous)
  if self.opts.include_hover then
    get_hover_async(bufnr, cursor_pos, self.opts, function(hover_info)
      if hover_info ~= '' then
        table.insert(context_parts, hover_info)
      end

      callback({
        content = table.concat(context_parts, '\n\n'),
        metadata = {
          source = 'diagnostics',
          has_diagnostics = diagnostics ~= '',
          has_hover = hover_info ~= '',
        },
      })
    end)
  else
    callback({
      content = table.concat(context_parts, '\n\n'),
      metadata = {
        source = 'diagnostics',
        has_diagnostics = diagnostics ~= '',
      },
    })
  end
end

return DiagnosticsContextProvider
