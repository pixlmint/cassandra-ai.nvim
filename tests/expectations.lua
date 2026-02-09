local H = {}

H.expect = MiniTest.expect
H.eq = MiniTest.expect.equality
H.not_eq = MiniTest.expect.no_equality

H.is_true = MiniTest.new_expectation('value is true', function(value)
  return value == true
end, function(value)
  return string.format('\nExpected value to be true, but got:\n%s', vim.inspect(value))
end)

H.is_false = MiniTest.new_expectation('value is false', function(value)
  return value == false
end, function(value)
  return string.format('\nExpected value to be false, but got:\n%s', vim.inspect(value))
end)

H.is_nil = MiniTest.new_expectation('value is nil', function(value)
  return value == nil
end, function(value)
  return string.format('\nExpected value to be nil, but got:\n%s', vim.inspect(value))
end)

H.is_not_nil = MiniTest.new_expectation('value is not nil', function(value)
  return value ~= nil
end, function(value)
  return '\nExpected value to not be nil'
end)

H.matches = MiniTest.new_expectation('string matches pattern', function(str, pattern)
  return string.match(str, pattern) ~= nil
end, function(str, pattern)
  return string.format('\nExpected string to match pattern:\n%s\n\nObserved string:\n%s', pattern, str)
end)

H.contains = MiniTest.new_expectation('string contains substring', function(str, substring)
  return str:find(substring, 1, true) ~= nil
end, function(str, substring)
  return string.format('\nExpected string to contain:\n%s\n\nObserved string:\n%s', substring, str)
end)

H.is_table = MiniTest.new_expectation('value is table', function(value)
  return type(value) == 'table'
end, function(value)
  return string.format('\nExpected value to be a table, but got type: %s', type(value))
end)

H.is_string = MiniTest.new_expectation('value is string', function(value)
  return type(value) == 'string'
end, function(value)
  return string.format('\nExpected value to be a string, but got type: %s', type(value))
end)

H.is_number = MiniTest.new_expectation('value is number', function(value)
  return type(value) == 'number'
end, function(value)
  return string.format('\nExpected value to be a number, but got type: %s', type(value))
end)

return H
