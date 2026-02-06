local Helpers = {}

Helpers = vim.tbl_extend('error', Helpers, require('tests.expectations'))

-- Start a child Neovim instance with minimal configuration
Helpers.child_start = function(child)
  child.restart({ '-u', 'tests/minimal_init.lua' })
  child.o.statusline = ''
  child.o.laststatus = 0
  child.o.cmdheight = 0
end

-- Mock configuration for testing
Helpers.default_config = {
  provider = 'openai',
  max_lines = 20,
  trim_output = true,
  log_errors = false,
  api_key = 'test_key',
  model = 'gpt-3.5-turbo',
  temperature = 0.7,
  max_tokens = 150,
  timeout = 30,
  context_providers = {},
  provider_options = {
    openai = {
      model = 'gpt-3.5-turbo',
      max_tokens = 150,
      temperature = 0.7,
    },
  },
}

-- Setup the plugin with test configuration
Helpers.setup_plugin = function(config)
  local test_config = vim.tbl_deep_extend('force', Helpers.default_config, config or {})
  require('cassandra_ai').setup(test_config)
end

-- Mock HTTP responses
Helpers.mock_http_response = function(response_data)
  local requests_module = require('cassandra_ai.requests')
  requests_module.post = function(self, url, headers, body, callback)
    callback(response_data)
  end
  return requests_module
end

-- Mock context providers
Helpers.mock_context_provider = function(name, context_data)
  local provider = {
    name = name,
    is_available = function()
      return true
    end,
    get_context = function(_, _, callback)
      callback(context_data)
    end,
    get_context_sync = function(_, _)
      return context_data
    end,
  }
  return provider
end

-- Test data helpers
Helpers.get_test_lines = function()
  return {
    'local function calculate_sum(a, b)',
    '  return a + b',
    'end',
    '',
    'local result = calculate_sum(5, 3)',
    'print(result)',
  }
end

Helpers.get_test_context = function()
  return {
    content = 'Test additional context',
    metadata = { source = 'test' },
  }
end

-- Get buffer lines
Helpers.get_buf_lines = function(bufnr)
  return vim.api.nvim_buf_get_lines(bufnr, 0, -1, true)
end

return Helpers
