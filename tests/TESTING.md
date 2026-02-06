# Testing Guide

This document describes the testing setup for cassandra-ai.

## Running Tests

```bash
# Run all tests
make test

# Run a specific test file
make test_file FILE=tests/test_config.lua
```

## Test Infrastructure

The test setup follows the pattern used by [codecompanion.nvim](https://github.com/olimorris/codecompanion.nvim):

### Key Files

- **tests/minimal_init.lua**: Minimal Neovim configuration for testing
  - Sets up runtimepath for dependencies
  - Configures mini.test to exclude tests/deps/ directory
  - Mocks nvim-cmp module
  
- **tests/helpers.lua**: Test helper functions
  - `child_start()`: Start a child Neovim instance
  - `default_config`: Default test configuration
  - `setup_plugin()`: Setup cassandra-ai with test config
  - `get_test_lines()`: Get sample code lines for testing
  
- **tests/expectations.lua**: Custom assertion helpers
  - `h.eq()`: Assert equality
  - `h.is_true()`, `h.is_false()`: Boolean assertions
  - `h.is_nil()`, `h.is_not_nil()`: Nil checks
  - `h.matches()`: Pattern matching
  - `h.is_table()`, `h.is_string()`, `h.is_number()`: Type checks

### Test Structure

Tests use [mini.test](https://github.com/echasnovski/mini.nvim/blob/main/readmes/mini-test.md) with child Neovim instances:

```lua
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

T['Module Name'] = new_set()

T['Module Name']['should do something'] = function()
  local result = child.lua([[
    local module = require('cassandra_ai.module')
    return module.some_function()
  ]])
  
  h.eq('expected', result)
end

return T
```

## Test Dependencies

Dependencies are managed via Makefile and stored in `tests/deps/`:

- **mini.nvim**: Test framework
- **plenary.nvim**: Lua utilities (used by the plugin)
- **nvim-treesitter**: Treesitter support (for context providers)

## Current Test Status

Run `make test` to see current status. As of the latest run:

- **21 tests passing**
- **25 tests failing**

### Passing Tests

- Context Providers (LSP): 2/2 tests
- Context Providers (Treesitter): 2/2 tests
- Prompt Formatters: 1/6 tests
- Requests: 1/4 tests
- Backends (Ollama): 1/4 tests
- Integration: 1/3 tests
- Context Providers: 1/3 tests

### Known Issues

Some tests are failing because:
1. Some modules need the plugin to be fully initialized
2. Some tests need actual API responses (currently mocked)
3. Config tests need better setup/teardown

## Writing New Tests

1. Create a new file in `tests/` with the prefix `test_`
2. Follow the structure shown above
3. Use child Neovim instances to isolate tests
4. Use the helper functions from `tests/helpers.lua`
5. Use the assertion functions from `tests/expectations.lua`

Example:

```lua
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

T['My Feature'] = new_set()

T['My Feature']['should work correctly'] = function()
  local result = child.lua([[
    local my_module = require('cassandra_ai.my_module')
    return my_module.my_function('test')
  ]])
  
  h.eq('expected_result', result)
end

return T
```

## Debugging Tests

To debug a specific test:

```bash
# Run with more verbose output
nvim --headless --noplugin -u ./tests/minimal_init.lua \
  -c "lua MiniTest.run_file('tests/test_config.lua')"

# Or use the Makefile
make test_file FILE=tests/test_config.lua
```

You can also add print statements in the child Neovim code:

```lua
local result = child.lua([[
  local module = require('cassandra_ai.module')
  print('Debug:', vim.inspect(module))
  return module.function()
]])
```

## Continuous Integration

The test suite is designed to run in CI environments. Make sure to:

1. Install Neovim (>= 0.9.0)
2. Run `make deps` to install dependencies
3. Run `make test` to execute tests

Exit code will be non-zero if any tests fail.
