vim.cmd([[let &rtp.=','.getcwd()]])
vim.cmd('set rtp+=tests/deps/mini.nvim')
vim.cmd('set rtp+=tests/deps/plenary.nvim')
vim.cmd('set rtp+=tests/deps/nvim-treesitter')

-- Ensure mini.test is available with custom config to exclude deps
require('mini.test').setup({
  collect = {
    find_files = function()
      -- Only collect test files from tests/ directory, not from tests/deps/
      return vim.fn.globpath('tests', 'test_*.lua', false, true)
    end,
  },
})

-- Mock nvim-cmp before any modules that might require it
package.preload['cmp'] = function()
  return {
    register_source = function() end,
    lsp = {
      CompletionItemKind = {
        Text = 1,
        Method = 2,
        Function = 3,
        Constructor = 4,
        Field = 5,
        Variable = 6,
        Class = 7,
        Interface = 8,
        Module = 9,
        Property = 10,
        Unit = 11,
        Value = 12,
        Enum = 13,
        Keyword = 14,
        Snippet = 15,
        Color = 16,
        File = 17,
        Reference = 18,
        Folder = 19,
        EnumMember = 20,
        Constant = 21,
        Struct = 22,
        Event = 23,
        Operator = 24,
        TypeParameter = 25,
      },
    },
  }
end
