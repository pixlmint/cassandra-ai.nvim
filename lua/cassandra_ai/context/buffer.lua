--- Buffer Context Provider
--- Provides context from other open buffers with the same filetype
local BaseContextProvider = require('cassandra_ai.context.base')

local BufferContextProvider = BaseContextProvider:new()

--- Create a new buffer context provider
--- @param opts table|nil Configuration options
---   - max_buffers: number - Maximum number of buffers to include (default: 3)
---   - max_lines_per_buffer: number - Max lines from each buffer (default: 10)
---   - same_filetype_only: boolean - Only include buffers with same filetype (default: true)
---   - include_buffer_name: boolean - Include buffer name in context (default: true)
--- @return table The new provider instance
function BufferContextProvider:new(opts)
  local o = BaseContextProvider.new(self, opts)
  o.opts = vim.tbl_deep_extend('keep', opts or {}, {
    max_buffers = 3,
    max_lines_per_buffer = 10,
    same_filetype_only = true,
    include_buffer_name = true,
  })
  setmetatable(o, self)
  self.__index = self
  return o
end

--- Check if this provider is available
--- @return boolean
function BufferContextProvider:is_available()
  return true
end

--- Get the name of this provider
--- @return string
function BufferContextProvider:get_name()
  return 'buffer'
end

--- Get context from other buffers
--- @param params table Context parameters
--- @return table Result with content and metadata
function BufferContextProvider:get_context_sync(params)
  local current_bufnr = params.bufnr
  local current_filetype = params.filetype
  local context_parts = {}
  local buffers_included = 0

  -- Get all listed buffers
  local buffers = vim.api.nvim_list_bufs()

  for _, bufnr in ipairs(buffers) do
    if buffers_included >= self.opts.max_buffers then
      break
    end

    -- Skip current buffer and non-listed buffers
    if bufnr ~= current_bufnr and vim.api.nvim_buf_is_loaded(bufnr) and vim.api.nvim_buf_get_option(bufnr, 'buflisted') then
      local buf_filetype = vim.api.nvim_buf_get_option(bufnr, 'filetype')

      -- Check filetype filter
      if not self.opts.same_filetype_only or buf_filetype == current_filetype then
        local buf_name = vim.api.nvim_buf_get_name(bufnr)

        -- Only include buffers with names (skip unnamed buffers)
        if buf_name and buf_name ~= '' then
          local lines = vim.api.nvim_buf_get_lines(bufnr, 0, self.opts.max_lines_per_buffer, false)

          if #lines > 0 then
            local buffer_context = table.concat(lines, '\n')

            if self.opts.include_buffer_name then
              -- Get relative path if possible
              local relative_name = vim.fn.fnamemodify(buf_name, ':.')
              table.insert(context_parts, string.format('-- From buffer: %s', relative_name))
            end

            table.insert(context_parts, buffer_context)
            buffers_included = buffers_included + 1
          end
        end
      end
    end
  end

  if #context_parts > 0 then
    return {
      content = '-- Related buffer content:\n' .. table.concat(context_parts, '\n\n'),
      metadata = {
        source = 'buffer',
        buffers_count = buffers_included,
      },
    }
  else
    return {
      content = '',
      metadata = {
        source = 'buffer',
        buffers_count = 0,
      },
    }
  end
end

return BufferContextProvider
