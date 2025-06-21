# Macrowhisper CLI - Codebase Map

## Overview

**Macrowhisper** is a sophisticated automation helper application designed to work seamlessly with **Superwhisper**, a dictation application. It functions as a file watcher and automation engine that monitors transcribed results from Superwhisper (stored in `meta.json` files) and executes various automated actions based on configurable rules and intelligent triggers.

> **Note**: This codebase map reflects the current state as of version 1.1.0, with all line counts and feature descriptions updated to match the actual implementation.

### Core Functionality
- **File Watching**: Monitors Superwhisper's recordings folder for new transcriptions
- **Intelligent Action Execution**: Supports multiple action types including text insertion, URL opening, shell scripts, AppleScript execution, and keyboard shortcuts
- **Advanced Trigger System**: Rule-based automation with voice patterns, application context, and mode matching
- **Service Management**: Full launchd service integration for background operation
- **Inter-Process Communication**: Unix socket-based communication for CLI commands and status queries
- **Configuration Management**: JSON-based configuration with live reloading and persistent path management
- **History Management**: Automatic cleanup of old recordings based on retention policies
- **Enhanced Clipboard Management**: Smart clipboard monitoring and restoration to handle timing conflicts
- **Update Checking**: Automatic version checking with intelligent notification system

---

## Project Structure

```
macrowhisper-cli/src/
├── Package.swift                    # Swift Package Manager configuration (Swifter dependency)
├── macrowhisper.xcodeproj/          # Xcode project files
└── macrowhisper/                    # Main application source code
    ├── main.swift                   # Application entry point and CLI handling (1101 lines)
    ├── Info.plist                   # App permissions and metadata
    ├── Config/                      # Configuration management system
    │   ├── AppConfiguration.swift   # Configuration data structures (473 lines)
    │   └── ConfigurationManager.swift # Configuration loading/saving/watching (348 lines)
    ├── Watcher/                     # File system monitoring
    │   ├── RecordingsFolderWatcher.swift # Main file watcher for recordings (521 lines)
    │   └── ConfigChangeWatcher.swift     # Configuration file watcher (42 lines)
    ├── Networking/                  # Network and IPC functionality
    │   ├── SocketCommunication.swift    # Unix socket server for CLI commands (794 lines)
    │   └── VersionChecker.swift         # Automatic update checking (514 lines)
    ├── History/                     # Recording history management
    │   └── HistoryManager.swift         # Cleanup of old recordings (115 lines)
    └── Utils/                       # Utility functions and helpers
        ├── ServiceManager.swift         # macOS launchd service management (437 lines)
        ├── ClipboardMonitor.swift       # Advanced clipboard monitoring and restoration (753 lines)
        ├── ActionExecutor.swift         # Action execution coordination (347 lines)
        ├── TriggerEvaluator.swift       # Intelligent trigger evaluation system (385 lines)
        ├── Accessibility.swift          # macOS accessibility and input simulation (254 lines)
        ├── Placeholders.swift           # Dynamic content replacement system (427 lines)
        ├── Logger.swift                 # Logging system with rotation (110 lines)
        ├── NotificationManager.swift    # System notifications (23 lines)
        └── ShellUtils.swift             # Shell command escaping utilities (17 lines)
```

---

## Core Components

### 1. Application Entry Point

#### `macrowhisper/main.swift` (1101 lines)
**Purpose**: Application bootstrap, CLI argument parsing, service management, and main event loop

**Key Global Variables**:
- `globalConfigManager`: Shared configuration manager instance
- `recordingsWatcher`: File system watcher for recordings
- `socketCommunication`: IPC server for CLI commands
- `historyManager`: Recording cleanup manager
- `logger`: Global logging instance
- `autoReturnEnabled`: Auto-return functionality state
- `lastDetectedFrontApp`: Application context tracking

**Key Functions**:
- `acquireSingleInstanceLock()`: Ensures only one instance runs using file locking
- `initializeWatcher()`: Sets up file system monitoring with error handling
- `checkWatcherAvailability()`: Validates Superwhisper folder existence
- `checkSocketHealth()` / `recoverSocket()`: Socket health monitoring and recovery
- `registerForSleepWakeNotifications()`: System sleep/wake handling
- `printHelp()`: Comprehensive CLI help system

**CLI Commands Supported**:
- **Service Management**: `--install-service`, `--start-service`, `--stop-service`, `--restart-service`, `--uninstall-service`, `--service-status`
- **Configuration**: `--reveal-config`, `--set-config`, `--reset-config`, `--get-config`
- **Information**: `--help`, `--version`, `--status`, `--verbose`
- **Insert Management**: `--exec-insert <name>`, `--get-insert`, `--list-inserts`, `--add-insert <name>`, `--remove-insert <name>`
- **Action Management**: `--add-url <name>`, `--add-shortcut <name>`, `--add-shell <name>`, `--add-as <name>`, `--remove-url <name>`, `--remove-shortcut <name>`, `--remove-shell <name>`, `--remove-as <name>`
- **Runtime Control**: `--auto-return [true/false]`, `--quit`, `--stop`
- **Update Management**: `--check-updates`, `--version-state`, `--version-clear`

**Other Features**:
- Complete service management integration
- Advanced configuration path management with persistence
- Socket health monitoring with automatic recovery
- System sleep/wake awareness

---

### 2. Configuration System

#### `macrowhisper/Config/AppConfiguration.swift` (473 lines)
**Purpose**: Defines the complete configuration data structure with advanced features

**Key Structures**:

**`AppConfiguration.Defaults`**:
- `watch`: Path to Superwhisper folder
- `noUpdates`: Disable update checking
- `noNoti`: Disable notifications
- `activeInsert`: Currently active insert name
- `icon`: Default icon for actions
- `moveTo`: Default window/app to move to after actions
- `noEsc`: Disable ESC key simulation
- `simKeypress`: Use keystroke simulation instead of clipboard
- `actionDelay`: Delay before executing actions
- `history`: Days to retain recordings (null = keep forever)
- `pressReturn`: Auto-press return after actions
- `returnDelay`: Delay before pressing return (default: 0.1s)
- `restoreClipboard`: Restore original clipboard content (default: true)

**Action Configurations (All support triggers)**:
- **`AppConfiguration.Insert`**: Text insertion with advanced placeholder support
- **`AppConfiguration.Url`**: URL actions with custom application opening
- **`AppConfiguration.Shortcut`**: macOS Shortcuts integration
- **`AppConfiguration.ScriptShell`**: Shell script execution
- **`AppConfiguration.ScriptAppleScript`**: AppleScript execution

**Advanced Trigger System** (All action types):
- `triggerVoice`: Regex pattern for voice matching (supports exceptions with `!` prefix)
- `triggerApps`: Regex pattern for app matching (name or bundle ID)
- `triggerModes`: Regex pattern for Superwhisper mode matching
- `triggerLogic`: "and"/"or" logic for combining triggers

**Custom Encoding/Decoding**:
- Preserves null values in JSON output
- Ensures backward compatibility
- Automatic defaults for missing fields

#### `macrowhisper/Config/ConfigurationManager.swift` (348 lines)
**Purpose**: Advanced configuration management with persistence and live reloading

**Key Features**:
- **Thread-safe configuration access** using dedicated `DispatchQueue`
- **Persistent configuration paths** using `UserDefaults`
- **Smart path resolution**: Handles both file and directory paths
- **Live file watching** with JSON error recovery
- **Command queue system** for configuration updates
- **Graceful error handling** with user notifications

**Configuration Path Priority**:
1. Explicit `--config` flag parameter
2. Saved user preference in UserDefaults
3. Default path (`~/.config/macrowhisper/macrowhisper.json`)

**Key Methods**:
- `normalizeConfigPath()`: Smart path handling (files vs directories)
- `setDefaultConfigPath()` / `resetToDefaultConfigPath()`: Persistent path management
- `loadConfig()` / `saveConfig()`: JSON serialization with error handling
- `updateFromCommandLine()`: Threaded configuration updates
- `setupFileWatcher()`: Live reload with JSON validation

---

### 3. Service Management System

#### `macrowhisper/Utils/ServiceManager.swift` (437 lines)
**Purpose**: Complete macOS launchd service integration for background operation

**Key Features**:
- **Full service lifecycle management**: Install, start, stop, restart, uninstall
- **Smart binary path detection**: Handles various installation scenarios (Homebrew, manual, development)
- **Configuration path preservation**: Maintains custom config paths in service
- **Automatic service updates**: Detects binary path changes and updates service
- **Robust error handling**: Comprehensive error reporting and recovery

**Service Management Flow**:
1. **Detection**: Finds current binary path using multiple strategies
2. **Installation**: Creates launchd plist with proper configuration
3. **Management**: Start/stop/restart with proper dependency handling
4. **Monitoring**: Service status checking and health validation
5. **Updates**: Automatic service updates when binary path changes

**Key Methods**:
- `getCurrentBinaryPath()`: Multi-strategy binary path resolution
- `installService()` / `uninstallService()`: Service lifecycle management
- `isServiceRunning()` / `isServiceInstalled()`: Status checking
- `stopRunningDaemon()`: Graceful daemon termination

---

### 4. File System Monitoring

#### `macrowhisper/Watcher/RecordingsFolderWatcher.swift` (521 lines)
**Purpose**: Advanced file system watcher with intelligent processing

**Key Features**:
- **Persistent processing tracking**: Prevents duplicate processing using file-based storage
- **Intelligent startup behavior**: Marks most recent recording as processed on startup
- **Early clipboard monitoring integration**: Captures user clipboard state before conflicts
- **Advanced trigger evaluation**: Uses TriggerEvaluator for smart action selection
- **Graceful cleanup**: Handles deleted recordings and orphaned watchers

**Enhanced Processing Flow**:
1. **Early Monitoring**: Start clipboard monitoring when folder appears
2. **Meta.json Waiting**: Handle delayed meta.json creation with timeout
3. **Context Gathering**: Capture application context and mode information
4. **Trigger Evaluation**: Use TriggerEvaluator to find matching actions
5. **Action Execution**: Execute matched actions via ActionExecutor
6. **Cleanup**: Mark as processed and clean up monitoring

**Key Components**:
- **TriggerEvaluator**: Intelligent action matching
- **ActionExecutor**: Coordinated action execution
- **ClipboardMonitor**: Early clipboard state capture
- **Persistent Tracking**: File-based processing history

---

### 5. Advanced Trigger System

#### `macrowhisper/Utils/TriggerEvaluator.swift` (385 lines)
**Purpose**: Intelligent trigger evaluation for all action types

**Key Features**:
- **Multi-criteria evaluation**: Voice, application, and mode triggers
- **Exception support**: Negative patterns with `!` prefix
- **Flexible logic**: AND/OR combinations of trigger conditions
- **Result stripping**: Clean voice results by removing trigger phrases
- **Comprehensive logging**: Detailed evaluation tracing

**Trigger Types**:
1. **Voice Triggers**: Regex patterns matching transcribed text
   - Positive patterns: Match required phrases
   - Exception patterns: Exclude specific phrases (prefix with `!`)
   - Result stripping: Remove trigger phrase from action input
2. **Application Triggers**: Match current foreground application
   - Bundle ID matching: `com.apple.mail`
   - Application name matching: Case-insensitive
3. **Mode Triggers**: Match Superwhisper mode names
   - Custom mode patterns: `email`, `writing`, etc.

**Evaluation Logic**:
- **AND logic**: All configured triggers must match
- **OR logic**: Any configured trigger can match
- **Smart defaults**: Empty triggers treated as matched for AND logic

---

### 6. Action Execution System

#### `macrowhisper/Utils/ActionExecutor.swift` (347 lines)
**Purpose**: Coordinated execution of all action types with advanced features

**Key Features**:
- **Unified execution interface**: Single entry point for all action types
- **Enhanced clipboard management**: Integration with ClipboardMonitor
- **Context-aware execution**: Application-specific behavior
- **Advanced placeholder processing**: Dynamic content replacement
- **Graceful error handling**: Comprehensive error recovery

**Action Types**:
1. **Insert Actions**: Text insertion with clipboard management
2. **URL Actions**: Web/application launching with custom handlers
3. **Shortcut Actions**: macOS Shortcuts integration with stdin piping
4. **Shell Scripts**: Bash command execution with environment isolation
5. **AppleScript**: Native AppleScript execution

**Special Features**:
- **`.none` handling**: Skip action but apply delays and context changes
- **`.autoPaste` intelligence**: Smart paste behavior based on input field detection
- **Move-to functionality**: Application/window focus management
- **ESC key coordination**: Intelligent ESC simulation for responsiveness

---

### 7. Enhanced Clipboard Management

#### `macrowhisper/Utils/ClipboardMonitor.swift` (759 lines)
**Purpose**: Advanced clipboard monitoring and restoration to handle timing conflicts

**Problem Solved**: Superwhisper and Macrowhisper both modify the clipboard simultaneously, leading to conflicts and lost user content.

**Key Features**:
- **Early monitoring sessions**: Capture clipboard state when recording folder appears
- **Smart restoration logic**: Determine correct clipboard content to restore based on session history
- **Timing coordination**: Handle ESC simulation and action delays with precise timing
- **Thread-safe session management**: Concurrent monitoring with proper synchronization using barriers
- **Configurable restoration**: Optional clipboard restoration for user preference
- **Enhanced vs. Basic sync**: Two-tier system with fallback for missing early monitoring data

**Session Lifecycle**:
1. **Early Start**: Begin monitoring immediately when recording folder detected
2. **Change Tracking**: Monitor all clipboard changes during session with timestamps
3. **Smart Analysis**: Determine user vs. system clipboard changes using session history
4. **Coordinated Execution**: Execute actions with proper timing and Superwhisper synchronization
5. **Intelligent Restoration**: Restore appropriate clipboard content based on timing analysis

**Restoration Logic**:
- **Case 1**: If Superwhisper was faster, restore content from just before swResult
- **Case 2**: If Macrowhisper was faster, preserve current clipboard content
- **Case 3**: Handle user intentional clipboard changes during processing
- **Timing Thresholds**: Use actionDelay vs. maxWaitTime (0.1s) for synchronization decisions

**Critical Timing Constants**:
- `maxWaitTime: 0.1` seconds - Maximum time to wait for Superwhisper
- `pollInterval: 0.01` seconds - 10ms polling interval for clipboard changes

---

### 8. Inter-Process Communication

#### `macrowhisper/Networking/SocketCommunication.swift` (794 lines)
**Purpose**: Comprehensive Unix socket server for CLI commands and action execution

**Key Features**:
- **Extensive command set**: 25+ different CLI commands
- **Service integration**: Service management commands
- **Configuration commands**: Live configuration updates
- **Action execution**: Direct insert execution for CLI
- **Health monitoring**: Socket health checking and recovery
- **Thread-safe operation**: Proper queue management

**Command Categories**:
1. **Configuration**: `reloadConfig`, `updateConfig`
2. **Information**: `status`, `version`, `debug`, `listInserts`
3. **Action Management**: `addInsert`, `removeInsert`, `execInsert`
4. **Service Control**: `serviceStatus`, `serviceStart`, `serviceStop`
5. **System Control**: `quit`, `autoReturn`

**Advanced Features**:
- **Placeholder processing**: Full XML and dynamic placeholder support
- **Clipboard integration**: Proper clipboard handling for CLI commands
- **Context awareness**: Application and mode detection
- **Error recovery**: Graceful handling of connection failures

---

### 9. Utility Systems

#### `macrowhisper/Utils/Placeholders.swift` (428 lines)
**Purpose**: Advanced placeholder processing system for dynamic content replacement

**Placeholder Types**:
1. **XML Placeholders**: `{{xml:tagname}}` extracts content from `<tagname>` in LLM results
2. **Meta.json Fields**: `{{result}}`, `{{llmResult}}`, `{{modeName}}`, etc.
3. **Date Placeholders**: `{{date:format}}` with various format options
4. **Smart Result**: `{{swResult}}` (intelligent result selection: llmResult > result)

**Advanced Features**:
- **XML content extraction**: Parse and clean LLM-generated XML tags
- **Content sanitization**: Remove HTML/XML artifacts
- **Date formatting**: Flexible date/time insertion
- **Shell escaping**: Safe command execution for shell actions
- **Action-type awareness**: Different escaping for different action types

#### `macrowhisper/Utils/Accessibility.swift` (254 lines)
**Purpose**: macOS accessibility system integration with enhanced capabilities

**Key Features**:
- **Permission management**: Request and validate accessibility permissions
- **Input field detection**: Advanced detection of text input contexts
- **Keyboard simulation**: Proper key event generation
- **Context awareness**: Smart ESC key handling based on application state

**Input Field Detection**:
- **Role-based**: `AXTextField`, `AXTextArea`, `AXSearchField`
- **Subrole checking**: `AXSecureTextField`, `AXTextInput`
- **Capability verification**: Check for `AXInsertText`, `AXDelete` actions
- **Editable validation**: Ensure fields are actually editable

#### `macrowhisper/Utils/Logger.swift` (110 lines)
**Purpose**: Comprehensive logging system with file rotation and intelligent output

**Features**:
- **Multiple log levels**: DEBUG, INFO, WARNING, ERROR
- **Automatic file rotation**: Rotation when logs exceed 5MB
- **Smart console output**: TTY detection for appropriate console logging
- **Thread-safe operations**: Proper synchronization for concurrent access
- **Structured formatting**: Consistent timestamps and component identification

**Global Functions**: `logInfo()`, `logWarning()`, `logError()`, `logDebug()`

---

### 10. History Management

#### `macrowhisper/History/HistoryManager.swift` (115 lines)
**Purpose**: Intelligent cleanup of old recordings with flexible policies

**Cleanup Policies**:
- `history = null`: Keep all recordings (no cleanup)
- `history = 0`: Keep only the most recent recording
- `history = N`: Keep recordings from last N days

**Features**:
- **Scheduled execution**: Automatic cleanup every 24 hours
- **Safe deletion**: Handles errors gracefully and logs results
- **Smart preservation**: Always keeps at least one recording when `history = 0`
- **Configurable retention**: Respects user configuration changes

---

### 11. Network Services

#### `macrowhisper/Networking/VersionChecker.swift` (514 lines)
**Purpose**: Intelligent update checking with user-centric notification system

**Key Features**:
- **Usage-triggered checking**: Checks during active app usage (recording processing)
- **Smart notifications**: Different notification types based on update requirements
- **Backoff strategy**: Prevents excessive checking after failures
- **Configuration respect**: Honors `noUpdates` setting and timing constraints
- **Comprehensive state management**: Tracks update states and user responses

**Check Triggers**:
1. **Application startup**: Initial check when app starts
2. **Recording processing**: Check during active usage every 24 hours
3. **Configuration changes**: Immediate check when updates are enabled
4. **Manual trigger**: Force check via `--check-updates` command

**Update Flow**:
1. **Version comparison**: Semantic version comparison logic
2. **Component analysis**: Determine which components need updates
3. **Smart notifications**: Show appropriate message based on update needs
4. **Update guidance**: Provide specific instructions or direct links
5. **State persistence**: Remember check dates and backoff periods

---

## Data Flow and Integration

### 1. Application Startup Flow
```
main.swift
├── Parse CLI arguments and handle quick commands
├── Acquire single instance lock (prevents multiple instances)
├── Initialize configuration manager with path priority
├── Start socket server for IPC
├── Initialize history manager for cleanup
├── Start recordings watcher (if path valid)
├── Register for system sleep/wake notifications
├── Start socket health monitoring
├── Initialize version checker
└── Enter main run loop
```

### 2. Recording Processing Flow (Enhanced)
```
RecordingsFolderWatcher detects new directory
├── Check if already processed (persistent tracking)
├── Start early clipboard monitoring IMMEDIATELY (ClipboardMonitor)
├── Look for meta.json file
├── If not found, watch for creation with timeout
├── Once available, parse and validate meta.json
├── Gather application context (foreground app, bundle ID, mode)
├── Action Priority Evaluation (STRICT ORDER):
│   ├── 1. Auto-Return (highest priority - overrides everything)
│   ├── 2. Trigger Actions (TriggerEvaluator)
│   │   ├── Check voice triggers (with exceptions and result stripping)
│   │   ├── Check application triggers (bundle ID and name)
│   │   ├── Check mode triggers (Superwhisper modes)
│   │   ├── Apply trigger logic (AND/OR)
│   │   └── Return first alphabetically sorted match
│   └── 3. Active Insert (lowest priority - fallback only)
├── Execute matched action (ActionExecutor)
│   ├── Determine action-specific settings (actionDelay, noEsc, etc.)
│   ├── Process placeholders with context (Placeholders.swift)
│   ├── Execute with enhanced clipboard sync (ClipboardMonitor)
│   │   ├── Apply actionDelay before ESC and action
│   │   ├── Handle ESC simulation with accessibility checks
│   │   ├── Coordinate timing with Superwhisper clipboard changes
│   │   └── Restore intelligent clipboard content
│   └── Handle action-specific execution (insert/URL/shortcut/shell/AppleScript)
├── Mark as processed (persistent tracking)
├── Perform post-processing tasks:
│   ├── Handle moveTo operations with precedence (action > default)
│   ├── Execute history cleanup (HistoryManager)
│   └── Check for version updates with 30s delay (VersionChecker)
└── Clean up monitoring sessions and watchers
```

### 3. Service Management Flow
```
Service commands (--install-service, --start-service, etc.)
├── Initialize ServiceManager
├── Detect current binary path (multiple strategies)
├── Validate configuration requirements
├── Create/update launchd plist
├── Execute launchctl commands
├── Verify service state
└── Provide user feedback
```

### 4. Configuration Management Flow
```
ConfigurationManager
├── Determine effective config path (priority order)
├── Load from JSON file with validation
├── Watch for file changes (ConfigChangeWatcher)
├── Handle CLI updates through command queue
├── Validate and save changes with formatting
├── Notify components of updates (live reload)
└── Trigger dependent component restarts
```

### 5. CLI Command Flow
```
CLI command received
├── Parse arguments and detect command type
├── Handle quick commands (help, version, config management)
├── Check single instance lock for daemon commands
├── Send command via Unix socket (SocketCommunication)
├── Server processes command with appropriate handler
├── Execute action or return information
├── Return structured response to client
└── Exit client process with appropriate code
```

---

## Advanced Design Patterns

### 1. **Enhanced Single Instance Pattern**
- File-based locking with proper cleanup
- Socket health monitoring and recovery
- Graceful handling of crashed instances

### 2. **Comprehensive Observer Pattern**
- File system watchers with proper cleanup
- Configuration change propagation
- System sleep/wake event handling

### 3. **Sophisticated Command Pattern**
- Structured socket communication with 25+ commands
- Command queuing for configuration updates
- Type-safe command serialization

### 4. **Advanced Strategy Pattern**
- Multiple action types with unified interface
- Pluggable trigger evaluation strategies
- Configurable clipboard restoration strategies

### 5. **Service Oriented Architecture**
- Clear separation of concerns across components
- Dependency injection for testability
- Proper error boundary isolation

---

## Configuration Schema (Enhanced)

The application uses a comprehensive JSON configuration file:

```json
{
  "defaults": {
    "watch": "~/Documents/superwhisper",
    "noUpdates": false,
    "noNoti": false,
    "activeInsert": "",
    "icon": "",
    "moveTo": "",
    "noEsc": false,
    "simKeypress": false,
    "actionDelay": 0.0,
    "history": null,
    "pressReturn": false,
    "returnDelay": 0.1,
    "restoreClipboard": true
  },
  "inserts": {
    "insertName": {
      "action": "Text with {{placeholders}} and {{xml:tags}}",
      "triggerVoice": "^(summarize|summary)|!ignore_this",
      "triggerApps": "com.apple.mail|Mail",
      "triggerModes": "email|writing",
      "triggerLogic": "or",
      "icon": "",
      "moveTo": "",
      "noEsc": false,
      "simKeypress": false,
      "actionDelay": 0.0,
      "pressReturn": false
    }
  },
  "urls": { /* Similar structure with openWith field */ },
  "shortcuts": { /* Similar structure for macOS Shortcuts */ },
  "scriptsShell": { /* Similar structure for shell scripts */ },
  "scriptsAS": { /* Similar structure for AppleScript */ }
}
```

---

## Dependencies and Requirements

### External Dependencies (Package.swift)
- **Swifter**: HTTP/Socket server framework (1.5.0+)

### System Dependencies
- **Foundation**: Core Swift framework
- **Cocoa**: macOS UI framework
- **ApplicationServices**: Accessibility and input simulation
- **Carbon**: Low-level keyboard event handling
- **UserNotifications**: System notifications
- **Darwin**: Unix system calls

### macOS Requirements
- **Accessibility Permission**: Required for input detection and key simulation

---

## File System Layout

### Configuration and Data
- **Configuration**: `~/.config/macrowhisper/` (customizable)
- **Logs**: `~/Library/Logs/Macrowhisper/`
- **Service Logs**: `~/Library/Logs/Macrowhisper/service.log`
- **Processed Recordings**: `~/Library/Application Support/Macrowhisper/`
- **Launch Agent**: `~/Library/LaunchAgents/com.macrowhisper.aft.plist`

### Runtime Files
- **Unix Socket**: `/tmp/macrowhisper-{uid}.sock`
- **Lock File**: `/tmp/macrowhisper.lock`
- **Config Preferences**: UserDefaults `com.macrowhisper.preferences`

---

## Error Handling and Recovery

### Comprehensive Error Recovery
- **Configuration errors**: JSON validation with user notification
- **Socket failures**: Automatic socket recovery with health monitoring
- **File system errors**: Graceful degradation and retry logic
- **Service failures**: Automatic restart and recovery procedures
- **Accessibility errors**: Clear user guidance and fallback behavior

### Logging Strategy
- **Structured logging** with contextual information
- **Automatic log rotation** to prevent disk space issues
- **Console output** when running interactively
- **Service logging** for background operation debugging

---

## Performance Optimizations

### Efficient Operations
- **Thread-safe design**: Proper queue usage for concurrent operations
- **Minimal polling**: Event-driven architecture with efficient file watching
- **Smart caching**: Configuration caching with invalidation
- **Resource cleanup**: Proper cleanup of file handles and watchers
- **Background processing**: Non-blocking action execution

### Memory Management
- **Weak references**: Prevent retain cycles in closures
- **Resource pooling**: Efficient reuse of expensive objects
- **Automatic cleanup**: Timer-based cleanup of expired sessions
- **Bounded queues**: Prevent unbounded memory growth

---

## Future Extension Points

### Trigger System Evolution
- **Advanced pattern matching**: Support for complex regex patterns
- **Conditional logic**: More complex trigger combinations and nested conditions

### Action Type Expansion
- **Current types**: Insert, URL, Shell, AppleScript, Shortcut
- **Potential additions**: 
  - File operations (create, move, delete)
  - API calls and webhooks
  - System automation (brightness, volume, etc.)
  - Multi-step actions/workflows

## Additional Documentation

For detailed technical analysis of the complete processing flow, timing, and clipboard synchronization, see:
- **[PROCESSING_FLOW.md](./PROCESSING_FLOW.md)** - Comprehensive developer documentation covering the complete flow from recording detection to action execution, including all timing variables, conditions, and edge cases.

---

This comprehensive codebase map serves as a complete guide for understanding, maintaining, and extending the Macrowhisper application. The architecture supports robust operation, easy extensibility, and maintainable code organization across all components.