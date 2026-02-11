local commands = require('cassandra_ai.commands')

local M = {}

M.setup = function(opts)
  require('cassandra_ai.config'):setup(opts)
  commands.setup()
end

return M
