# IDE Integration Guide

Get auto-completion, validation, and documentation for your macrowhisper configuration files!

## Quick Setup

1. **Check if schema is available**:
   ```bash
   macrowhisper --schema-info
   ```

2. **Enable schema support** (one-time, if schema file is found):
   ```bash
   macrowhisper --add-schema
   ```

3. **Open your config** in your favorite editor:
   ```bash
   macrowhisper --reveal-config
   ```

4. **Enjoy IDE features!** ✨

## What You Get

### ✅ Auto-completion
Type `"` and see all available properties suggested by your IDE

### ✅ Validation
Instant error highlighting for typos, wrong types, or invalid values

### ✅ Documentation
Hover over any property to see what it does and example values

### ✅ Type Safety
IDE prevents you from using strings where numbers are expected

## Supported Editors

### VS Code (Recommended)
- **Built-in support** - just add schema and it works!
- Shows validation errors in Problems panel
- Ctrl/Cmd+Space for auto-completion

### JetBrains IDEs (IntelliJ, WebStorm, etc.)
- **Built-in JSON Schema support**
- Validation in real-time
- Auto-completion with Ctrl+Space

### Sublime Text
- Install **LSP** and **LSP-json** packages
- Full schema validation and completion

### Vim/Neovim
- With **coc.nvim**: Install `coc-json` extension
- With **nvim-lsp**: Use `jsonls` language server

### Other Editors
Most modern editors support JSON Schema - check for JSON language server support!

## Configuration Example

After running `--add-schema`, your config will look like:

```json
{
  "$schema": "file:///path/to/macrowhisper-schema.json",
  "defaults": {
    "watch": "~/Documents/superwhisper",
    "activeAction": "autoPaste",
    "actionDelay": 0.0
  },
  "inserts": {
    "myAction": {
      "action": "Hello {{swResult}}!",
      "triggerVoice": "^hello"
    }
  }
}
```

The `$schema` line enables all IDE features!

## Schema Management Commands

```bash
# Check if schema is configured
macrowhisper --schema-info

# Add schema reference to config
macrowhisper --add-schema

# Remove schema reference (for testing)
macrowhisper --remove-schema
```

## Troubleshooting

### "Schema file not found" when running --add-schema
1. **Homebrew users**: `brew reinstall macrowhisper`
2. **Manual installation**: Ensure `macrowhisper-schema.json` is in the same directory as the binary
3. **Check status**: `macrowhisper --schema-info`

### "Schema not found" in IDE
1. Check schema status: `macrowhisper --schema-info`
2. Verify schema file exists locally (no internet required)
3. Re-add schema: `macrowhisper --add-schema`

### No auto-completion
1. Ensure your editor supports JSON Schema
2. Check that `$schema` field is present in your config
3. Try saving the file and reopening
4. Verify schema file exists: `macrowhisper --schema-info`

### Validation errors for valid config
1. Ensure you have the latest macrowhisper version
2. Re-run `--add-schema` to update schema reference

## Benefits

- **Faster configuration**: Auto-completion speeds up editing
- **Fewer mistakes**: Validation catches errors before runtime  
- **Better understanding**: Inline documentation explains each field
- **Version safety**: Schema updates with new macrowhisper features

## Advanced: Schema File Locations

The schema manager automatically finds the schema file locally (no internet required):

1. **Alongside binary** - same directory as macrowhisper executable
2. **Homebrew installation** - `/opt/homebrew/share/macrowhisper/macrowhisper-schema.json`
3. **Development environment** - relative to source directory

Check which location is being used:
```bash
macrowhisper --schema-info
```

**Note**: macrowhisper works completely offline - no remote URLs are used for schema validation.