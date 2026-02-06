local h = require('tests.helpers')

local new_set = MiniTest.new_set

local child = MiniTest.new_child_neovim()

T = new_set({
  hooks = {
    pre_case = function()
      h.child_start(child)
    end,
    post_case = child.stop,
  },
})

T['Config'] = new_set()

T['Config']['setup() sets default values'] = function()
  child.lua([[
    local config = require('cassandra_ai.config')
    config:setup()
  ]])

  local max_lines = child.lua_get([[require('cassandra_ai.config'):get('max_lines')]])
  local run_on_every_keystroke = child.lua_get([[require('cassandra_ai.config'):get('run_on_every_keystroke')]])
  local log_errors = child.lua_get([[require('cassandra_ai.config'):get('log_errors')]])
  local notify = child.lua_get([[require('cassandra_ai.config'):get('notify')]])

  h.eq(max_lines, 50)
  h.is_true(run_on_every_keystroke)
  h.is_true(log_errors)
  h.is_true(notify)
end

T['Config']['setup() accepts custom values'] = function()
  child.lua([[
    local config = require('cassandra_ai.config')
    config:setup({
      max_lines = 100,
      run_on_every_keystroke = false,
      log_errors = false,
    })
  ]])

  local max_lines = child.lua_get([[require('cassandra_ai.config'):get('max_lines')]])
  local run_on_every_keystroke = child.lua_get([[require('cassandra_ai.config'):get('run_on_every_keystroke')]])
  local log_errors = child.lua_get([[require('cassandra_ai.config'):get('log_errors')]])

  h.eq(max_lines, 100)
  h.is_false(run_on_every_keystroke)
  h.is_false(log_errors)
end

T['Config']['get() retrieves configuration values'] = function()
  child.lua([[
    local config = require('cassandra_ai.config')
    config:setup({ max_lines = 75 })
  ]])

  local result = child.lua_get([[require('cassandra_ai.config'):get('max_lines')]])
  h.eq(result, 75)
end

T['Config']['get() returns nil for non-existent keys'] = function()
  child.lua([[
    local config = require('cassandra_ai.config')
    config:setup()
  ]])

  local result = child.lua_get([[require('cassandra_ai.config'):get('nonexistent_key')]])
  h.eq(vim.NIL, result)
end

T['Config']['setup() deep merges nested configuration'] = function()
  child.lua([[
    local config = require('cassandra_ai.config')
    config:setup({
      context_providers = {
        providers = {'lsp', 'treesitter'},
        timeout_ms = 1000,
      }
    })
  ]])

  local context_config = child.lua_get([[require('cassandra_ai.config'):get('context_providers')]])
  h.is_table(context_config)
  h.eq(context_config.timeout_ms, 1000)
  h.eq(context_config.merge_strategy, 'concat') -- Default preserved
end

T['Config']['setup() preserves ignored_file_types structure'] = function()
  child.lua([[
    local config = require('cassandra_ai.config')
    config:setup({
      ignored_file_types = {
        lua = true,
        vim = true,
      }
    })
  ]])

  local ignored = child.lua_get([[require('cassandra_ai.config'):get('ignored_file_types')]])
  h.is_table(ignored)
  h.is_true(ignored.lua)
  h.is_true(ignored.vim)
end

T['Config']['setup() handles provider_options'] = function()
  child.lua([[
    local config = require('cassandra_ai.config')
    config:setup({
      provider = 'Ollama',
      provider_options = {
        model = 'codellama:7b',
        temperature = 0.5,
      }
    })
  ]])

  local provider_options = child.lua_get([[require('cassandra_ai.config'):get('provider_options')]])
  h.is_table(provider_options)
  h.eq(provider_options.model, 'codellama:7b')
  h.eq(provider_options.temperature, 0.5)
end

T['Config']['setup() handles data collection settings'] = function()
  child.lua([[
    local config = require('cassandra_ai.config')
    config:setup({
      collect_data = true,
      data_buffer_size = 100,
    })
  ]])

  local collect_data = child.lua_get([[require('cassandra_ai.config'):get('collect_data')]])
  local buffer_size = child.lua_get([[require('cassandra_ai.config'):get('data_buffer_size')]])

  h.is_true(collect_data)
  h.eq(buffer_size, 100)
end

T['Config']['setup() preserves notify_callback function'] = function()
  child.lua([[
    local config = require('cassandra_ai.config')
    config:setup()
  ]])

  local callback = child.lua_get([[type(require('cassandra_ai.config'):get('notify_callback'))]])
  h.eq(callback, 'function')
end

T['Config']['setup() accepts custom merge strategy'] = function()
  child.lua([[
    local config = require('cassandra_ai.config')
    config:setup({
      context_providers = {
        merge_strategy = 'weighted',
      }
    })
  ]])

  local merge_strategy = child.lua_get([[require('cassandra_ai.config'):get('context_providers').merge_strategy]])
  h.eq(merge_strategy, 'weighted')
end

T['Config']['setup() can be called multiple times'] = function()
  child.lua([[
    local config = require('cassandra_ai.config')
    config:setup({ max_lines = 30 })
  ]])

  local first = child.lua_get([[require('cassandra_ai.config'):get('max_lines')]])
  h.eq(first, 30)

  child.lua([[
    local config = require('cassandra_ai.config')
    config:setup({ max_lines = 60 })
  ]])

  local second = child.lua_get([[require('cassandra_ai.config'):get('max_lines')]])
  h.eq(second, 60)
end

T['Config']['setup() handles empty configuration'] = function()
  child.lua([[
    local config = require('cassandra_ai.config')
    config:setup({})
  ]])

  local max_lines = child.lua_get([[require('cassandra_ai.config'):get('max_lines')]])
  h.eq(max_lines, 50) -- Should use default
end

T['Config']['setup() handles nil configuration'] = function()
  child.lua([[
    local config = require('cassandra_ai.config')
    config:setup(nil)
  ]])

  local max_lines = child.lua_get([[require('cassandra_ai.config'):get('max_lines')]])
  h.eq(max_lines, 50) -- Should use default
end

T['Config']['data_file path uses stdpath'] = function()
  child.lua([[
    local config = require('cassandra_ai.config')
    config:setup()
  ]])

  local data_file = child.lua_get([[require('cassandra_ai.config'):get('data_file')]])
  h.is_string(data_file)
  h.contains(data_file, 'cassandra-ai/completions.jsonl')
end

T['Config']['context_providers default timeout is set'] = function()
  child.lua([[
    local config = require('cassandra_ai.config')
    config:setup()
  ]])

  local timeout = child.lua_get([[require('cassandra_ai.config'):get('context_providers').timeout_ms]])
  h.eq(timeout, 500)
end

T['Config']['context_providers providers list defaults to empty'] = function()
  child.lua([[
    local config = require('cassandra_ai.config')
    config:setup()
  ]])

  local providers = child.lua_get([[require('cassandra_ai.config'):get('context_providers').providers]])
  h.is_table(providers)
  h.eq(#providers, 0)
end

T['Config']['setup() preserves custom_merger when provided'] = function()
  child.lua([[
    local config = require('cassandra_ai.config')
    config:setup({
      context_providers = {
        custom_merger = function(contexts) return contexts end,
      }
    })
  ]])

  local merger_type = child.lua_get([[type(require('cassandra_ai.config'):get('context_providers').custom_merger)]])
  h.eq(merger_type, 'function')
end

T['Config']['setup() handles boolean flags correctly'] = function()
  child.lua([[
    local config = require('cassandra_ai.config')
    config:setup({
      notify = false,
      log_errors = false,
      collect_data = false,
    })
  ]])

  local notify = child.lua_get([[require('cassandra_ai.config'):get('notify')]])
  local log_errors = child.lua_get([[require('cassandra_ai.config'):get('log_errors')]])
  local collect_data = child.lua_get([[require('cassandra_ai.config'):get('collect_data')]])

  h.is_false(notify)
  h.is_false(log_errors)
  h.is_false(collect_data)
end

return T

