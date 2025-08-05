# JSON Schema Integration - Build Notes

## Distribution Strategy

### 1. Manual Installation (tar.gz releases)

When creating releases, include the schema file in the tar.gz:

```bash
# Build the binary
swift build -c release

# Create distribution directory
mkdir -p dist/macrowhisper-{version}
cp .build/release/macrowhisper dist/macrowhisper-{version}/
cp macrowhisper-schema.json dist/macrowhisper-{version}/

# Create tar.gz
cd dist
tar -czf macrowhisper-{version}-macos.tar.gz macrowhisper-{version}/
```

**Result**: Users get both binary and schema file in the same directory.

### 2. Homebrew Integration

Update your Homebrew formula to include the schema:

```ruby
class Macrowhisper < Formula
  desc "Automation helper for Superwhisper dictation app"
  homepage "https://github.com/ognistik/macrowhisper"
  url "https://github.com/ognistik/macrowhisper/releases/download/v{version}/macrowhisper-{version}-macos.tar.gz"
  sha256 "{hash}"
  
  def install
    bin.install "macrowhisper"
    share.install "macrowhisper-schema.json" => "macrowhisper/macrowhisper-schema.json"
  end
end
```

**Result**: Schema installed to `/opt/homebrew/share/macrowhisper/macrowhisper-schema.json`

### 3. Manual Schema Management

Users control when IDE validation is enabled via CLI commands:

```bash
# Add schema reference (requires local schema file)
macrowhisper --add-schema

# Remove schema reference
macrowhisper --remove-schema

# Check schema status
macrowhisper --schema-info
```

Result in config file:
```json
{
  "$schema": "file:///path/to/local/schema.json",
  "defaults": {
    "watch": "~/Documents/superwhisper",
    ...
  }
}
```

## CLI Commands

Users can manage schema integration:

```bash
# Add schema reference to config (if not already present)
macrowhisper --add-schema

# Check schema status
macrowhisper --schema-info

# Remove schema reference (for testing backward compatibility)
macrowhisper --remove-schema
```

## IDE Setup for Users

### VS Code
1. Install "JSON" extension (usually included)
2. Schema reference is automatically detected from `$schema` field
3. Users get instant validation and auto-completion

### Other IDEs
- **IntelliJ/WebStorm**: Built-in JSON schema support
- **Sublime Text**: With LSP-json plugin
- **Vim/Neovim**: With coc-json or similar

## Backward Compatibility

✅ **100% Backward Compatible**
- Existing configs work unchanged
- Schema reference is optional
- IDEs that don't support schemas ignore the `$schema` field
- No breaking changes to JSON structure

## Testing

Test all scenarios:

```bash
# Test local schema detection
macrowhisper --schema-info

# Test manual schema addition
macrowhisper --remove-schema  # Remove if present
macrowhisper --add-schema     # Add it back

# Test automatic addition on config save
macrowhisper --action myAction  # Triggers config save
```

## Release Checklist

1. [ ] Build binary with `swift build -c release`
2. [ ] Include `macrowhisper-schema.json` in distribution tar.gz
3. [ ] Update Homebrew formula to install schema file
4. [ ] Test schema detection in different installation scenarios
5. [ ] Update release notes to mention IDE integration feature
6. [ ] Consider updating install script to mention `--add-schema` command

## Benefits for Users

- **User control**: Users decide when to enable IDE validation
- **Offline operation**: No internet required - uses local schema files only  
- **Auto-completion**: IDEs suggest valid property names
- **Validation**: Immediate error highlighting for typos
- **Documentation**: Hover tooltips explain each field
- **Type safety**: Prevents string/number/boolean mixups
- **Future-proof**: Schema can be updated as features are added