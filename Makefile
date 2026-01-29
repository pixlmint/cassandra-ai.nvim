all: format test

format:
	@echo Formatting...
	@stylua lua/ tests/ -f ./stylua.toml

test: deps
	@echo Testing...
	nvim --headless --noplugin -u ./tests/minimal_init.lua -c "lua MiniTest.run()"

test_file: deps
	@echo Testing File...
	nvim --headless --noplugin -u ./tests/minimal_init.lua -c "lua MiniTest.run_file('$(FILE)')"

deps: tests/deps/plenary.nvim tests/deps/mini.nvim tests/deps/nvim-treesitter
	@echo Dependencies ready...

tests/deps/plenary.nvim:
	@mkdir -p tests/deps
	git clone --filter=blob:none https://github.com/nvim-lua/plenary.nvim.git $@

tests/deps/mini.nvim:
	@mkdir -p tests/deps
	git clone --filter=blob:none https://github.com/echasnovski/mini.nvim $@

tests/deps/nvim-treesitter:
	@mkdir -p tests/deps
	git clone --filter=blob:none https://github.com/nvim-treesitter/nvim-treesitter.git $@

