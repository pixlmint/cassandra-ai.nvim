--- User commands for cassandra-ai
local M = {}

--- Creates an autocompletion function for a command tree
--- @param commands table The command tree structure
--- @return function Autocompletion function compatible with nvim_create_user_command
function create_completer(commands)
  return function(arglead, cmdline, _)
    local words = vim.split(cmdline, ' ')
    local current = commands
    local last_word = words[#words - 1]

    -- Traverse the command tree following subcommands
    for i = 2, #words do
      if current[words[i]] then
        if current[words[i]].subcommands then
          current = current[words[i]].subcommands
        else
          last_word = words[i]
          break
        end
      else
        break
      end
    end

    -- Handle options completion (flags starting with -)
    if current[last_word] and current[last_word].options and words[#words]:sub(1, 1) == '-' then
      local matches = {}
      for opt, _ in pairs(current[last_word].options) do
        if opt:find('^' .. vim.pesc(words[#words])) then
          table.insert(matches, opt)
        end
      end
      return matches
    end

    -- Use custom completion function if available
    if current[last_word] and current[last_word].complete then
      return current[last_word].complete(arglead)
    end

    -- Complete available commands at this level
    local matches = {}
    for cmd in pairs(current) do
      if cmd:find('^' .. vim.pesc(arglead)) then
        table.insert(matches, cmd)
      end
    end

    return matches
  end
end

--- Creates a command dispatcher for a command tree
--- @param commands table The command tree structure
--- @return function Dispatcher function that executes commands
function create_dispatcher(commands)
  return function(args)
    local current = commands

    -- Traverse command tree to find the execute function
    for i = 1, #args do
      if current[args[i]] and current[args[i]].subcommands then
        -- Move deeper into subcommands
        current = current[args[i]].subcommands
      elseif current[args[i]] and current[args[i]].execute then
        -- Found executable command, run it with remaining args
        current[args[i]].execute(vim.list_slice(args, i + 1))
        return
      else
        vim.notify('Unknown command: ' .. args[i], vim.log.levels.ERROR)
        return
      end
    end

    vim.notify('Incomplete command. Please specify a subcommand.', vim.log.levels.WARN)
  end
end

--- Registers a user command with the given command tree
--- @param name string The command name (e.g., "Docker")
--- @param commands table The command tree structure
--- @param opts table|nil Optional configuration (e.g., { nargs = "*" })
local function register_command(name, commands, opts)
  opts = opts or {}

  local dispatcher = create_dispatcher(commands)
  local completer = create_completer(commands)

  vim.api.nvim_create_user_command(
    name,
    function(cmd_opts)
      local args = vim.split(cmd_opts.args, ' ', { trimempty = true })
      dispatcher(args)
    end,
    vim.tbl_extend('force', {
      nargs = '*',
      complete = completer,
    }, opts)
  )
end

--- Show context from a specific provider in a popup
--- @param provider_name string The name of the provider to test
local function show_context(provider_name)
  local context_manager = require('cassandra_ai.context')

  if not context_manager.is_enabled() then
    vim.notify("Context providers are not configured. Add providers to context_providers.providers in your config.\nExample: context_providers = { providers = {'lsp', 'treesitter'} }", vim.log.levels.WARN)
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

    vim.notify(string.format('Provider "%s" not found or not enabled.\nAvailable providers: %s', provider_name, table.concat(available, ', ')), vim.log.levels.ERROR)
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
  local commands = {
    context = {
      description = 'Show context from a specific context provider',
      complete = function(arglead)
        local context_manager = require('cassandra_ai.context')

        if not context_manager.is_enabled() then
          return {}
        end

        local providers = context_manager.get_providers()
        local names = {}

        for _, provider_data in ipairs(providers) do
          if provider_data.name:find('^' .. arglead) then
            table.insert(names, provider_data.name)
          end
        end

        return names
      end,
      execute = function(opts)
        local provider_name = opts[1]

        if not provider_name or provider_name == '' then
          vim.notify('Usage: :CassandraAiContext <provider_name>\nExample: :CassandraAiContext lsp', vim.log.levels.ERROR)
          return
        end

        show_context(provider_name)
      end,
    },
    log = {
      description = 'Open the cassandra-ai log file',
      execute = function(_)
        local logger = require('cassandra_ai.logger')
        local log_file = logger.get_log_file()

        if not log_file then
          vim.notify('No log file configured', vim.log.levels.WARN)
          return
        end

        if vim.fn.filereadable(log_file) == 0 then
          vim.notify('Log file does not exist yet: ' .. log_file, vim.log.levels.INFO)
          return
        end

        vim.cmd('tabnew | edit ' .. vim.fn.fnameescape(log_file))
      end,
    },
    config = {
      description = 'Change configuration at runtime',
      subcommands = {
        auto_trigger = {
          description = 'Toggle, enable, or disable auto_trigger',
          complete = function(arglead)
            local options = { 'toggle', 'enable', 'disable' }
            local matches = {}
            for _, opt in ipairs(options) do
              if opt:find('^' .. vim.pesc(arglead)) then
                table.insert(matches, opt)
              end
            end
            return matches
          end,
          execute = function(opts)
            local conf = require('cassandra_ai.config')
            local inline = conf:get('inline')
            local action = opts[1]

            if action == 'toggle' then
              inline.auto_trigger = not inline.auto_trigger
            elseif action == 'enable' then
              inline.auto_trigger = true
            elseif action == 'disable' then
              inline.auto_trigger = false
            else
              vim.notify('Usage: :Cassy config auto_trigger toggle|enable|disable', vim.log.levels.ERROR)
              return
            end

            vim.notify('auto_trigger: ' .. (inline.auto_trigger and 'enabled' or 'disabled'), vim.log.levels.INFO)
          end,
        },
        telemetry = {
          description = 'Toggle, enable, or disable telemetry',
          complete = function(arglead)
            local options = { 'toggle', 'enable', 'disable' }
            local matches = {}
            for _, opt in ipairs(options) do
              if opt:find('^' .. vim.pesc(arglead)) then
                table.insert(matches, opt)
              end
            end
            return matches
          end,
          execute = function(opts)
            local conf = require('cassandra_ai.config')
            local telemetry = require('cassandra_ai.telemetry')
            local action = opts[1]
            local enabled

            if action == 'toggle' then
              enabled = not telemetry:is_enabled()
            elseif action == 'enable' then
              enabled = true
            elseif action == 'disable' then
              enabled = false
            else
              vim.notify('Usage: :Cassy config telemetry toggle|enable|disable', vim.log.levels.ERROR)
              return
            end

            telemetry:set_enabled(enabled)
            conf:set('collect_data', enabled)
            vim.notify('telemetry: ' .. (enabled and 'enabled' or 'disabled'), vim.log.levels.INFO)
          end,
        },
        log_level = {
          description = 'Set the log level',
          complete = function(arglead)
            local levels = { 'TRACE', 'DEBUG', 'INFO', 'WARN', 'ERROR' }
            local matches = {}
            for _, level in ipairs(levels) do
              if level:find('^' .. vim.pesc(arglead:upper())) then
                table.insert(matches, level)
              end
            end
            return matches
          end,
          execute = function(opts)
            local level = opts[1]
            if not level then
              vim.notify('Usage: :Cassy config log_level TRACE|DEBUG|INFO|WARN|ERROR', vim.log.levels.ERROR)
              return
            end

            local logger = require('cassandra_ai.logger')
            local levels = logger.get_levels()
            if not levels[level:upper()] then
              vim.notify('Invalid log level: ' .. level .. '. Use TRACE, DEBUG, INFO, WARN, or ERROR', vim.log.levels.ERROR)
              return
            end

            logger.set_log_level(level)
            vim.notify('log_level: ' .. level:upper(), vim.log.levels.INFO)
          end,
        },
        model = {
          description = 'Set the Ollama model override',
          complete = function(arglead)
            local conf = require('cassandra_ai.config')
            local provider = conf:get('provider')
            local matches = { 'auto' }

            if provider and provider.params and provider.params.model_configs then
              for name, _ in pairs(provider.params.model_configs) do
                table.insert(matches, name)
              end
            end

            local filtered = {}
            for _, m in ipairs(matches) do
              if m:find('^' .. vim.pesc(arglead)) then
                table.insert(filtered, m)
              end
            end
            return filtered
          end,
          execute = function(opts)
            local model_name = opts[1]
            if not model_name then
              vim.notify('Usage: :Cassy config model <model_name|auto>', vim.log.levels.ERROR)
              return
            end

            local conf = require('cassandra_ai.config')
            local provider = conf:get('provider')

            if not provider or not provider.set_model_override then
              vim.notify('Model override is only supported for the Ollama backend', vim.log.levels.ERROR)
              return
            end

            provider:set_model_override(model_name)
            if model_name == 'auto' then
              vim.notify('model: automatic selection', vim.log.levels.INFO)
            else
              vim.notify('model: ' .. model_name, vim.log.levels.INFO)
            end
          end,
        },
      },
    },
  }

  register_command('Cassy', commands)
end

return M
