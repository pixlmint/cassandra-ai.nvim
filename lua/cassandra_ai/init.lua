local inline = require('cassandra_ai.inline')
local commands = require('cassandra_ai.commands')

local M = {}

M.setup = function(opts)
  inline.setup(opts)
  commands.setup()
end

return M
