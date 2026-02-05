--- LSP Context Provider
--- Extracts class/function signatures from LSP using references and definitions
local BaseContextProvider = require('cmp_ai.context.base')

local LspContextProvider = BaseContextProvider:new()

--- Create a new LSP context provider
--- @param opts table|nil Configuration options
---   - max_definitions: number - Maximum definitions to include (default: 3)
---   - include_private: boolean - Include private methods (default: false)
---   - max_lines_per_definition: number - Max lines per definition (default: 50)
--- @return table The new provider instance
function LspContextProvider:new(opts)
  local o = BaseContextProvider.new(self, opts)
  o.opts = vim.tbl_deep_extend('keep', opts or {}, {
    max_definitions = 3,
    include_private = false,
    max_lines_per_definition = 50,
  })
  setmetatable(o, self)
  self.__index = self
  return o
end

--- Check if LSP is available
--- @return boolean
function LspContextProvider:is_available()
  return vim.lsp ~= nil
end

--- Get the name of this provider
--- @return string
function LspContextProvider:get_name()
  return 'lsp'
end

--- Extract function/method signature from text
--- Includes doc comments and function signature, excludes body
--- @param lines table Array of lines
--- @param start_line number Starting line (0-indexed)
--- @param end_line number Ending line (0-indexed)
--- @return string Extracted signature
local function extract_signature(lines, start_line, end_line)
  local signature_lines = {}
  local in_doc_comment = false
  local found_function = false
  local brace_count = 0

  for i = start_line + 1, end_line + 1 do
    if i > #lines then break end
    local line = lines[i]

    -- Detect doc comments (/** */ or /// or #)
    if line:match('^%s*//%s') or line:match('^%s*/%*%*') or line:match('^%s*#') then
      in_doc_comment = true
      table.insert(signature_lines, line)
    elseif in_doc_comment and (line:match('%*/') or not line:match('^%s*[/*#]')) then
      if line:match('%*/') then
        table.insert(signature_lines, line)
      end
      in_doc_comment = false
    elseif in_doc_comment then
      table.insert(signature_lines, line)
      -- Detect function/method declaration
    elseif line:match('function%s+') or line:match('def%s+') or
        line:match('fn%s+') or line:match('func%s+') or
        line:match('public%s+') or line:match('private%s+') or
        line:match('protected%s+') or line:match('static%s+') then
      found_function = true
      table.insert(signature_lines, line)

      -- Check for opening brace on same line
      for char in line:gmatch('.') do
        if char == '{' then
          brace_count = brace_count + 1
        elseif char == '}' then
          brace_count = brace_count - 1
        end
      end

      -- If we found the opening brace, stop
      if brace_count > 0 or line:match('[{;]%s*$') then
        break
      end
    elseif found_function then
      -- Continue collecting signature until we hit opening brace
      table.insert(signature_lines, line)

      for char in line:gmatch('.') do
        if char == '{' then
          brace_count = brace_count + 1
        elseif char == '}' then
          brace_count = brace_count - 1
        end
      end

      if brace_count > 0 or line:match('[{;]%s*$') then
        break
      end
    end
  end

  return table.concat(signature_lines, '\n')
end

--- Check if a method/function is private
--- @param text string The method signature text
--- @return boolean
local function is_private(text)
  -- Check for private keyword
  if text:match('%sprivate%s') or text:match('^private%s') then
    return true
  end

  -- Check for private naming convention (starts with _ or __)
  if text:match('function%s+_') or text:match('def%s+_') then
    return true
  end

  return false
end

--- Get definition at position using LSP
--- @param bufnr number Buffer number
--- @param line number Line number (0-indexed)
--- @param col number Column number (0-indexed)
--- @param callback function Callback with definition info
local function get_definition(bufnr, line, col, callback)
  local params = {
    textDocument = vim.lsp.util.make_text_document_params(bufnr),
    position = { line = line, character = col },
  }

  vim.lsp.buf_request(bufnr, 'textDocument/definition', params, function(err, result)
    if err or not result then
      callback(nil)
      return
    end

    -- Handle both single result and array of results
    local locations = {}
    if vim.tbl_islist(result) then
      locations = result
    elseif result.uri then
      locations = { result }
    end

    callback(locations)
  end)
end

--- Extract class signature and public methods from a class definition
--- @param def_bufnr number Buffer number of definition
--- @param start_line number Start line of class (0-indexed)
--- @param end_line number End line of class (0-indexed)
--- @param include_private boolean Whether to include private methods
--- @return string Formatted class signature
local function extract_class_context(def_bufnr, start_line, end_line, include_private)
  local lines = vim.api.nvim_buf_get_lines(def_bufnr, 0, -1, false)
  local context_lines = {}

  -- Get class declaration and doc comment
  local class_start = math.max(0, start_line - 10) -- Look back for doc comment
  for i = class_start + 1, start_line + 1 do
    if i > #lines then break end
    local line = lines[i]

    -- Include doc comments
    if line:match('^%s*//%s') or line:match('^%s*/%*') or line:match('^%s*%*') or line:match('^%s*#') then
      table.insert(context_lines, line)
      -- Include class declaration
    elseif line:match('class%s+') or line:match('interface%s+') or line:match('trait%s+') then
      table.insert(context_lines, line)
      break
    end
  end

  table.insert(context_lines, '')

  -- Extract method signatures
  local in_method = false
  local method_start = nil

  for i = start_line + 1, math.min(end_line + 1, #lines) do
    local line = lines[i]

    -- Detect method/function declarations
    if line:match('function%s+') or line:match('def%s+') or
        line:match('public%s+function') or line:match('protected%s+function') or
        line:match('private%s+function') then
      -- Skip private methods if not requested
      if include_private or not is_private(line) then
        method_start = i - 1
        in_method = true

        -- Extract signature (look back for doc comments)
        local sig_start = math.max(start_line, method_start - 5)
        local signature = extract_signature(lines, sig_start, i - 1)

        if signature ~= '' then
          table.insert(context_lines, signature)
          table.insert(context_lines, '')
        end
      end

      in_method = false
    end
  end

  return table.concat(context_lines, '\n')
end

--- Get context from LSP
--- @param params table Context parameters
--- @param callback function Callback for result
function LspContextProvider:get_context(params, callback)
  local bufnr = params.bufnr
  local cursor_pos = params.cursor_pos

  -- Get active LSP clients
  local clients = vim.lsp.get_active_clients({ bufnr = bufnr })

  if #clients == 0 then
    callback({
      content = '',
      metadata = { source = 'lsp', error = 'No LSP client attached' },
    })
    return
  end

  -- Get definition at cursor position
  get_definition(bufnr, cursor_pos.line, cursor_pos.col, function(locations)
    if not locations or #locations == 0 then
      callback({
        content = '',
        metadata = { source = 'lsp', error = 'No definition found' },
      })
      return
    end

    local definitions = {}
    local processed = 0

    for i, location in ipairs(locations) do
      if i > self.opts.max_definitions then
        break
      end

      local uri = location.uri or location.targetUri
      local range = location.range or location.targetRange

      if uri and range then
        -- Get buffer for definition location
        local def_bufnr = vim.uri_to_bufnr(uri)

        -- Ensure buffer is loaded
        if not vim.api.nvim_buf_is_loaded(def_bufnr) then
          vim.fn.bufload(def_bufnr)
        end

        local start_line = range.start.line
        local end_line = range['end'].line

        -- Try to extract class context if this looks like a class
        local lines = vim.api.nvim_buf_get_lines(def_bufnr, start_line, start_line + 5, false)
        local first_lines = table.concat(lines, '\n')

        if first_lines:match('class%s+') or first_lines:match('interface%s+') then
          -- Find end of class (look for closing brace)
          local all_lines = vim.api.nvim_buf_get_lines(def_bufnr, 0, -1, false)
          local brace_count = 0
          local class_end = start_line

          for j = start_line + 1, math.min(#all_lines, start_line + self.opts.max_lines_per_definition) do
            for char in all_lines[j]:gmatch('.') do
              if char == '{' then
                brace_count = brace_count + 1
              elseif char == '}' then
                brace_count = brace_count - 1
                if brace_count == 0 then
                  class_end = j - 1
                  break
                end
              end
            end
            if brace_count == 0 and class_end > start_line then
              break
            end
          end

          local context = extract_class_context(def_bufnr, start_line, class_end, self.opts.include_private)
          if context ~= '' then
            table.insert(definitions, context)
          end
        else
          -- Extract function/method signature
          local def_lines = vim.api.nvim_buf_get_lines(def_bufnr, 0, -1, false)
          local signature = extract_signature(def_lines, math.max(0, start_line - 5), end_line)

          if signature ~= '' then
            table.insert(definitions, signature)
          end
        end
      end

      processed = processed + 1
    end

    if #definitions > 0 then
      callback({
        content = '-- LSP Definitions:\n\n' .. table.concat(definitions, '\n\n---\n\n'),
        metadata = {
          source = 'lsp',
          definition_count = #definitions,
        },
      })
    else
      callback({
        content = '',
        metadata = { source = 'lsp', error = 'No context extracted' },
      })
    end
  end)
end

return LspContextProvider
