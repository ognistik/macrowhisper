# Macrowhisper Development Guide

## Quick Start

### Building
```bash
cd src
swift build
```

### Running in Development
```bash
# Start with verbose logging
./macrowhisper --verbose

# Use custom config for testing
./macrowhisper --config ~/test-config.json --verbose
```

### Testing CLI Commands
```bash
# Test service management
./macrowhisper --service-status

# Test configuration
./macrowhisper --get-config

# Test inserts (requires running daemon)
./macrowhisper --list-inserts
```

## Common Development Tasks

### Adding New CLI Commands
1. Add the command enum in `SocketCommunication.swift`
2. Add the command handler in the switch statement
3. Add the CLI argument parsing in `main.swift`
4. Update the help text in `printHelp()`

### Adding New Action Types
1. Define the action struct in `AppConfiguration.swift`
2. Add the processing logic in `ActionExecutor.swift` 
3. Add trigger evaluation in `TriggerEvaluator.swift`
4. Add CLI management commands in `SocketCommunication.swift`

### Adding New Placeholders
1. Add the placeholder logic in `processDynamicPlaceholders()` in `Placeholders.swift`
2. If using accessibility APIs, add the function to `Accessibility.swift`
3. For session-based placeholders, enhance `ClipboardMonitor` and `ActionExecutor`
4. Update documentation in `CODEBASE_MAP.md`
5. Test with various action types and escaping scenarios

#### Available Placeholders (As of Latest Version)

**Session-Based Placeholders** (captured during recording):
- `{{selectedText}}` - Text selected when recording starts (early capture)
- `{{clipboardContext}}` - Last clipboard change during recording session (supports stacking)
- `{{appContext}}` - Structured app context (captured on-demand)

**Usage Examples:**
- `{{selectedText}}` - Gets selected text with action-type escaping
- `{{json:selectedText}}` - Gets selected text with JSON escaping
- `{{raw:selectedText}}` - Gets selected text with no escaping
- `{{selectedText||\\n||newline}}` - Gets selected text and replaces newlines
- `{{clipboardContext}}` - Last clipboard content during recording
- `{{appContext}}` - Structured app context (app name, window, URL, input content)

#### Implementation Notes:
- **selectedText**: Captured immediately when recording folder appears (if text is selected)
- **clipboardContext**: Captured from clipboard monitoring session (works regardless of restoreClipboard setting)
  - **Stacking**: When `clipboardStacking` is enabled in configuration, captures all clipboard changes with XML formatting
  - **Single change**: Returns content without XML tags (maintains current behavior)
  - **Multiple changes**: Returns all changes with XML tags (`<clipboard_context_1>`, `<clipboard_context_2>`, etc.)
- **appContext**: Only captured when placeholder is used in action (performance optimization)

#### Example: Adding Session-Based Placeholder
```swift
// 1. Enhance ClipboardMonitor session structure
private struct EarlyMonitoringSession {
    let myNewData: String?  // Add your data field
    // ... existing fields
}

// 2. Capture data in startEarlyMonitoring()
let myNewData = captureMyData()
let session = EarlyMonitoringSession(
    // ... existing params
    myNewData: myNewData
)

// 3. Add getter method in ClipboardMonitor
func getMyNewData(for recordingPath: String) -> String {
    // Return session data
}

// 4. Enhance metaJson in ActionExecutor
enhanced["myNewData"] = clipboardMonitor.getMyNewData(for: recordingPath)

// 5. Add placeholder processing in Placeholders.swift
else if key == "myNewData" {
    var value = metaJson["myNewData"] as? String ?? ""
    // ... standard placeholder processing
}
```

### Debugging Tips
- Use `--verbose` for debug logging
- Check logs in `~/Library/Logs/Macrowhisper/`
- Use `--version-state` to debug update checker
- Test socket health with `--status`

## Architecture Notes

- All file operations use the main queue for thread safety
- Configuration changes trigger live reloads
- Socket communication handles both CLI and daemon interactions  
- ClipboardMonitor coordinates with Superwhisper timing

See `CODEBASE_MAP.md` for detailed architecture documentation. 