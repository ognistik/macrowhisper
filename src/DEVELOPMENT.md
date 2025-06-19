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