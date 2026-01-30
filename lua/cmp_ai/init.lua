local cmp = require('cmp')
local source = require('cmp_ai.source')
local commands = require('cmp_ai.commands')

local M = {}

M.setup = function()
  M.ai_source = source:new()
  cmp.register_source('cmp_ai', M.ai_source)

  -- Setup user commands
  commands.setup()
end

return M
