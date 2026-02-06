-- Test runner for cassandra-ai
-- Run with: nvim --headless --noplugin -u tests/minimal_init.lua -c "luafile tests/run_tests.lua"

local MiniTest = require("mini.test")

-- Set up test environment
vim.opt.swapfile = false
vim.opt.backup = false
vim.opt.writebackup = false
vim.opt.updatecount = 0
vim.opt.updatetime = 0
vim.opt.timeout = false
vim.opt.timeoutlen = 500
vim.opt.ttimeout = false
vim.opt.ttimeoutlen = 10

-- Run all tests
local ok, result = pcall(function()
  return MiniTest.run()
end)

-- Report results
if ok then
  print("Tests completed successfully")
  if result and result.summary then
    print(string.format("Passed: %d, Failed: %d, Skipped: %d", 
      result.summary.passed or 0,
      result.summary.failed or 0,
      result.summary.skipped or 0))
  end
  vim.cmd("qa!")
else
  print("Test execution failed: " .. tostring(result))
  vim.cmd("cquit 1")
end