--- User commands for cassandra-ai
local M = {}

--- Show context from a specific provider in a popup
--- @param provider_name string The name of the provider to test
local function show_context(provider_name)
  local context_manager = require('cassandra_ai.context')

  if not context_manager.is_enabled() then
    vim.notify('Context providers are not configured. Add providers to context_providers.providers in your config.\nExample: context_providers = { providers = {\'lsp\', \'treesitter\'} }',
      vim.log.levels.WARN)
    return
  end

  -- Get current buffer info
  local bufnr = vim.api.nvim_get_current_buf()
  local cursor = vim.api.nvim_win_get_cursor(0)
  local cursor_pos = { line = cursor[1] - 1, col = cursor[2] }
  local filetype = vim.bo.filetype

  -- Get context lines
  local conf = require('cassandra_ai.config')
  local max_lines = conf:get('max_lines') or 50

  local cur_line = vim.api.nvim_get_current_line()
  local cur_line_before = vim.fn.strpart(cur_line, 0, math.max(cursor_pos.col, 0), true)
  local cur_line_after = vim.fn.strpart(cur_line, math.max(cursor_pos.col, 0), vim.fn.strdisplaywidth(cur_line), true)

  local lines_before = vim.api.nvim_buf_get_lines(bufnr, math.max(0, cursor_pos.line - max_lines), cursor_pos.line, false)
  table.insert(lines_before, cur_line_before)
  local before = table.concat(lines_before, '\n')

  local lines_after = vim.api.nvim_buf_get_lines(bufnr, cursor_pos.line + 1, cursor_pos.line + max_lines, false)
  table.insert(lines_after, 1, cur_line_after)
  local after = table.concat(lines_after, '\n')

  -- Prepare context parameters
  local params = {
    bufnr = bufnr,
    cursor_pos = cursor_pos,
    lines_before = before,
    lines_after = after,
    filetype = filetype,
  }

  -- Find the requested provider
  local providers = context_manager.get_providers()
  local target_provider = nil

  for _, provider_data in ipairs(providers) do
    if provider_data.name == provider_name then
      target_provider = provider_data
      break
    end
  end

  if not target_provider then
    local available = {}
    for _, p in ipairs(providers) do
      table.insert(available, p.name)
    end

    vim.notify(
      string.format(
        'Provider "%s" not found or not enabled.\nAvailable providers: %s',
        provider_name,
        table.concat(available, ', ')
      ),
      vim.log.levels.ERROR
    )
    return
  end

  -- Show loading message
  vim.notify('Gathering context from "' .. provider_name .. '"...', vim.log.levels.INFO)

  -- Get context from provider
  local success, err = pcall(function()
    target_provider.instance:get_context(params, function(result)
      -- Create popup buffer
      local popup_buf = vim.api.nvim_create_buf(false, true)

      -- Format content
      local lines = {
        '# Context from provider: ' .. provider_name,
        '',
        '## Metadata',
      }
      
      -- Add metadata lines
      local metadata_str = vim.inspect(result.metadata)
      local metadata_lines = vim.split(metadata_str, '\n', { plain = true })
      for _, line in ipairs(metadata_lines) do
        table.insert(lines, line)
      end
      
      table.insert(lines, '')
      table.insert(lines, '## Content')
      table.insert(lines, '')

      -- Add content lines
      if result.content and result.content ~= '' then
        local content_lines = vim.split(result.content, '\n', { plain = true })
        for _, line in ipairs(content_lines) do
          table.insert(lines, line)
        end
      else
        table.insert(lines, '(no content)')
      end

      -- Add separator
      table.insert(lines, '')
      table.insert(lines, '---')
      table.insert(lines, 'Press q to close')

      vim.api.nvim_buf_set_lines(popup_buf, 0, -1, false, lines)
      vim.api.nvim_buf_set_option(popup_buf, 'modifiable', false)
      vim.api.nvim_buf_set_option(popup_buf, 'buftype', 'nofile')
      vim.api.nvim_buf_set_option(popup_buf, 'filetype', 'markdown')

      -- Calculate popup size
      local width = math.floor(vim.o.columns * 0.8)
      local height = math.floor(vim.o.lines * 0.8)
      local row = math.floor((vim.o.lines - height) / 2)
      local col = math.floor((vim.o.columns - width) / 2)

      -- Create popup window
      local win = vim.api.nvim_open_win(popup_buf, true, {
        relative = 'editor',
        width = width,
        height = height,
        row = row,
        col = col,
        style = 'minimal',
        border = 'rounded',
        title = ' Context: ' .. provider_name .. ' ',
        title_pos = 'center',
      })

      -- Set window options
      vim.api.nvim_win_set_option(win, 'wrap', true)
      vim.api.nvim_win_set_option(win, 'linebreak', true)

      -- Add keybinding to close
      vim.api.nvim_buf_set_keymap(popup_buf, 'n', 'q', ':close<CR>', {
        noremap = true,
        silent = true,
      })

      vim.notify('Context retrieved successfully', vim.log.levels.INFO)
    end)
  end)

  if not success then
    vim.notify('Error getting context from provider "' .. provider_name .. '": ' .. tostring(err), vim.log.levels.ERROR)
  end
end

--- Setup user commands
function M.setup()
  -- Create CassandraAiContext command
  vim.api.nvim_create_user_command('CassandraAiContext', function(opts)
    local provider_name = opts.args

    if not provider_name or provider_name == '' then
      vim.notify('Usage: :CassandraAiContext <provider_name>\nExample: :CassandraAiContext lsp', vim.log.levels.ERROR)
      return
    end

    show_context(provider_name)
  end, {
    nargs = 1,
    desc = 'Show context from a specific context provider',
    complete = function()
      local context_manager = require('cassandra_ai.context')

      if not context_manager.is_enabled() then
        return {}
      end

      local providers = context_manager.get_providers()
      local names = {}

      for _, provider_data in ipairs(providers) do
        table.insert(names, provider_data.name)
      end

      return names
    end,
  })

  -- Create CassandraAiContextAll command to show all contexts
  vim.api.nvim_create_user_command('CassandraAiContextAll', function()
    local context_manager = require('cassandra_ai.context')

    if not context_manager.is_enabled() then
      vim.notify('Context providers are not configured. Add providers to context_providers.providers in your config.\nExample: context_providers = { providers = {\'lsp\', \'treesitter\'} }',
        vim.log.levels.WARN)
      return
    end

    -- Get current buffer info
    local bufnr = vim.api.nvim_get_current_buf()
    local cursor = vim.api.nvim_win_get_cursor(0)
    local cursor_pos = { line = cursor[1] - 1, col = cursor[2] }
    local filetype = vim.bo.filetype

    -- Get context lines
    local conf = require('cassandra_ai.config')
    local max_lines = conf:get('max_lines') or 50

    local cur_line = vim.api.nvim_get_current_line()
    local cur_line_before = vim.fn.strpart(cur_line, 0, math.max(cursor_pos.col, 0), true)
    local cur_line_after = vim.fn.strpart(cur_line, math.max(cursor_pos.col, 0), vim.fn.strdisplaywidth(cur_line), true)

    local lines_before = vim.api.nvim_buf_get_lines(bufnr, math.max(0, cursor_pos.line - max_lines), cursor_pos.line,
      false)
    table.insert(lines_before, cur_line_before)
    local before = table.concat(lines_before, '\n')

    local lines_after = vim.api.nvim_buf_get_lines(bufnr, cursor_pos.line + 1, cursor_pos.line + max_lines, false)
    table.insert(lines_after, 1, cur_line_after)
    local after = table.concat(lines_after, '\n')

    -- Prepare context parameters
    local params = {
      bufnr = bufnr,
      cursor_pos = cursor_pos,
      lines_before = before,
      lines_after = after,
      filetype = filetype,
    }

    vim.notify('Gathering context from all providers...', vim.log.levels.INFO)

    -- Gather all contexts
    context_manager.gather_context(params, function(merged_context)
      -- Create popup buffer
      local popup_buf = vim.api.nvim_create_buf(false, true)

      -- Format content
      local lines = {
        '# All Context Providers (Merged)',
        '',
        '## Merged Context',
        '',
      }

      -- Add merged content
      if merged_context and merged_context ~= '' then
        local content_lines = vim.split(merged_context, '\n', { plain = true })
        for _, line in ipairs(content_lines) do
          table.insert(lines, line)
        end
      else
        table.insert(lines, '(no content)')
      end

      -- Add separator
      table.insert(lines, '')
      table.insert(lines, '---')
      table.insert(lines, 'Press q to close | Use :CassandraAiContext <provider> to see individual providers')

      vim.api.nvim_buf_set_lines(popup_buf, 0, -1, false, lines)
      vim.api.nvim_buf_set_option(popup_buf, 'modifiable', false)
      vim.api.nvim_buf_set_option(popup_buf, 'buftype', 'nofile')
      vim.api.nvim_buf_set_option(popup_buf, 'filetype', 'markdown')

      -- Calculate popup size
      local width = math.floor(vim.o.columns * 0.8)
      local height = math.floor(vim.o.lines * 0.8)
      local row = math.floor((vim.o.lines - height) / 2)
      local col = math.floor((vim.o.columns - width) / 2)

      -- Create popup window
      local win = vim.api.nvim_open_win(popup_buf, true, {
        relative = 'editor',
        width = width,
        height = height,
        row = row,
        col = col,
        style = 'minimal',
        border = 'rounded',
        title = ' All Context Providers (Merged) ',
        title_pos = 'center',
      })

      -- Set window options
      vim.api.nvim_win_set_option(win, 'wrap', true)
      vim.api.nvim_win_set_option(win, 'linebreak', true)

      -- Add keybinding to close
      vim.api.nvim_buf_set_keymap(popup_buf, 'n', 'q', ':close<CR>', {
        noremap = true,
        silent = true,
      })

      vim.notify('Context retrieved successfully', vim.log.levels.INFO)
    end)
  end, {
    nargs = 0,
    desc = 'Show merged context from all enabled context providers',
  })

  -- Create CassandraAiContextList command to list available providers
  vim.api.nvim_create_user_command('CassandraAiContextList', function()
    local context_manager = require('cassandra_ai.context')

    if not context_manager.is_enabled() then
      vim.notify('Context providers are not configured. Add providers to context_providers.providers in your config.\nExample: context_providers = { providers = {\'lsp\', \'treesitter\'} }',
        vim.log.levels.WARN)
      return
    end

    local providers = context_manager.get_providers()

    if #providers == 0 then
      vim.notify('No context providers are registered.', vim.log.levels.WARN)
      return
    end

    local lines = { 'Registered Context Providers:', '' }

    for _, provider_data in ipairs(providers) do
      table.insert(lines, string.format('  • %s (priority: %d)', provider_data.name, provider_data.priority or 10))
    end

    table.insert(lines, '')
    table.insert(lines, 'Usage: :CassandraAiContext <provider_name>')

    vim.notify(table.concat(lines, '\n'), vim.log.levels.INFO)
  end, {
    nargs = 0,
    desc = 'List all registered context providers',
  })
end

return M
