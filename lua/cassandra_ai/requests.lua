local job = require('plenary.job')
local conf = require('cassandra_ai.config')
local logger = require('cassandra_ai.logger')
Service = {}

function Service:new(o)
  o = o or {}
  setmetatable(o, self)
  self.__index = self
  return o
end

function Service:json_decode(data)
  local status, result = pcall(vim.fn.json_decode, data)
  if status then
    return result
  else
    return nil, result
  end
end

function Service:Post(url, headers, data, cb)
  return Service:_Request(url, headers, data, cb, { '-X', 'POST' })
end

function Service:Get(url, headers, data, cb)
  return Service:_Request(url, headers, data, cb)
end

function Service:_Request(url, headers, data, cb, args)
  args = args or {}

  headers = vim.tbl_extend('force', {}, headers or {})
  headers[#headers + 1] = 'Content-Type: application/json'
  local tmpfname = nil
  if type(data) == 'table' then
    tmpfname = os.tmpname()
    local f = io.open(tmpfname, 'w+')
    if f == nil then
      vim.notify('Cannot open temporary message file: ' .. tmpfname, vim.log.levels.ERROR)
      return
    end
    f:write(vim.fn.json_encode(data))
    f:close()
    args[#args + 1] = '-d'
    args[#args + 1] = '@' .. tmpfname
  elseif type(data) == 'string' then
    args[#args + 1] = "--json"
    args[#args + 1] = data
  end

  local timeout_seconds = conf:get('max_timeout_seconds')
  if tonumber(timeout_seconds) ~= nil then
    args[#args + 1] = '--max-time'
    args[#args + 1] = tonumber(timeout_seconds)
  elseif timeout_seconds ~= nil then
    vim.notify('cassandra-ai: your max_timeout_seconds config is not a number', vim.log.levels.WARN)
  end

  for _, h in ipairs(headers) do
    args[#args + 1] = '-H'
    args[#args + 1] = h
  end

  args[#args + 1] = url

  logger.trace('Service:_Request() -> ' .. url)

  local j = job:new({
    command = 'curl',
    args = args,
    on_exit = vim.schedule_wrap(function(response, exit_code)
      if tmpfname ~= nil then
        os.remove(tmpfname)
      end
      if exit_code ~= 0 then
        logger.error('HTTP request failed: ' .. url .. ' exit_code=' .. exit_code)
        if conf:get('log_errors') then
          vim.notify('An Error Occurred ...', vim.log.levels.ERROR)
        end
        cb({ { error = 'ERROR: API Error' } })
      end

      local result = table.concat(response:result(), '\n')
      local json = self:json_decode(result)
      vim.api.nvim_exec_autocmds({ 'User' }, {
        pattern = 'CassandraAiRequestFinished',
        data = { response = json }
      })
      if json == nil then
        logger.warn('HTTP response: no valid JSON from ' .. url)
        cb({ { error = 'No Response.' } })
      else
        logger.trace('Service:_Request() -> response ok from ' .. url)
        cb(json)
      end
    end),
  })
  j:start()
  return j
end

return Service
