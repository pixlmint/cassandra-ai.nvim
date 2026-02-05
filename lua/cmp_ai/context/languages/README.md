# Language-Specific Context Extraction

This directory contains language-specific handlers for extracting context from code. Each language can have custom logic for:

- Extracting imports/use statements
- Identifying private methods/functions
- Extracting function/method signatures
- Extracting class definitions with methods

## Structure

- `base.lua` - Default implementation used as fallback
- `init.lua` - Language handler loader
- `python.lua` - Python-specific extraction
- `php.lua` - PHP-specific extraction
- `javascript.lua` - JavaScript/TypeScript extraction
- `[language].lua` - Add more as needed

## Adding a New Language

To add support for a new language, create a new file named after the language (e.g., `rust.lua`):

```lua
--- Rust Language Handler
local base = require('cmp_ai.context.languages.base')
local M = vim.deepcopy(base)

--- Extract imports for Rust
function M.extract_imports(bufnr, lines)
  local imports = {}
  
  for i = 1, math.min(100, #lines) do
    local line = lines[i]
    
    if line:match('^use%s+') then
      table.insert(imports, line)
      if #imports >= 15 then break end
    end
    
    -- Stop at first fn/struct
    if line:match('^fn%s+') or line:match('^struct%s+') then
      break
    end
  end
  
  if #imports > 0 then
    return '// Imports:\n' .. table.concat(imports, '\n') .. '\n\n'
  end
  
  return ''
end

--- Check if function is private in Rust
function M.is_private(text)
  -- In Rust, items are private by default
  return not text:match('pub%s+')
end

--- Extract Rust function signature
function M.extract_signature(lines, start_line, end_line)
  local signature_lines = {}
  
  for i = start_line + 1, end_line + 1 do
    if i > #lines then break end
    local line = lines[i]
    
    -- Capture doc comments (///)
    if line:match('^%s*///') then
      table.insert(signature_lines, line)
    -- Capture function definition
    elseif line:match('fn%s+') or line:match('pub%s+fn') then
      table.insert(signature_lines, line)
      if line:match('{%s*$') then
        break
      end
    end
  end
  
  return table.concat(signature_lines, '\n')
end

--- Extract Rust struct/impl context
function M.extract_class_context(bufnr, lines, start_line, end_line, include_private)
  local context_lines = {}
  
  -- Get struct definition
  for i = start_line + 1, start_line + 5 do
    if i > #lines then break end
    local line = lines[i]
    
    if line:match('struct%s+') or line:match('impl%s+') then
      table.insert(context_lines, line)
      break
    end
  end
  
  table.insert(context_lines, '')
  
  -- Extract method signatures from impl blocks
  for i = start_line + 1, math.min(end_line + 1, #lines) do
    local line = lines[i]
    
    if line:match('%s*fn%s+') or line:match('%s*pub%s+fn') then
      if include_private or line:match('pub') then
        local signature = M.extract_signature(lines, i - 5, i - 1)
        if signature ~= '' then
          table.insert(context_lines, signature)
          table.insert(context_lines, '')
        end
      end
    end
  end
  
  return table.concat(context_lines, '\n')
end

--- Rust should include imports
function M.should_include_imports()
  return true
end

return M
```

Then register it in `init.lua`:

```lua
local filetype_map = {
  python = 'python',
  php = 'php',
  javascript = 'javascript',
  typescript = 'javascript',
  rust = 'rust',  -- Add this
  -- ...
}
```

## Interface

Each language handler must implement:

### `extract_imports(bufnr, lines)`
Extract import/use statements from the buffer.

**Parameters:**
- `bufnr` - Buffer number
- `lines` - Array of all buffer lines

**Returns:** String of formatted imports or empty string

### `is_private(text)`
Check if a function/method signature indicates it's private.

**Parameters:**
- `text` - The function/method signature line

**Returns:** Boolean

### `extract_signature(lines, start_line, end_line)`
Extract a function/method signature including doc comments.

**Parameters:**
- `lines` - Buffer lines
- `start_line` - Start line (0-indexed)
- `end_line` - End line (0-indexed)

**Returns:** String of formatted signature

### `extract_class_context(bufnr, lines, start_line, end_line, include_private)`
Extract class/struct definition with method signatures.

**Parameters:**
- `bufnr` - Buffer number
- `lines` - Buffer lines
- `start_line` - Start line (0-indexed)
- `end_line` - End line (0-indexed)
- `include_private` - Boolean to include private methods

**Returns:** String of formatted class context

### `should_include_imports()`
Determine if imports should be included for this language.

**Returns:** Boolean

## Language-Specific Features

### Python
- Extracts `import` and `from X import Y` statements
- Recognizes decorators (@property, @classmethod, etc.)
- Extracts docstrings (""" """)
- Identifies private methods (starts with _)
- Always includes imports

### PHP
- Extracts `use` statements (but disabled by default due to autoloading)
- Recognizes PHPDoc comments (/** */)
- Handles visibility modifiers (public, private, protected)
- Identifies private methods via `private` keyword
- Does not include imports by default

### JavaScript/TypeScript
- Extracts `import` statements
- Recognizes JSDoc comments (/** */)
- Handles multiple function forms (function, arrow, async, methods)
- Supports TypeScript modifiers (public, private, protected)
- Identifies private fields (#)
- Always includes imports

## Testing

To test a language handler:

1. Open a file in that language
2. Position cursor on a class member access (e.g., `obj.method()`)
3. Run `:CmpAiContext lsp`
4. Check the output includes:
   - Imports (if applicable)
   - Class definition
   - Method signatures (public only unless configured)

## Contributing

When adding a new language:

1. Study the existing handlers (`python.lua`, `php.lua`, `javascript.lua`)
2. Implement all interface methods
3. Test with real code in that language
4. Consider the language's conventions:
   - How are imports typically used?
   - What indicates a private method?
   - What doc comment format is standard?
   - How are functions/methods typically declared?
