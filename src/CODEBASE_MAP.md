# Macrowhisper CLI - Codebase Map

## Overview

**Macrowhisper** is a sophisticated automation helper application designed to work seamlessly with **Superwhisper**, a dictation application. Macrowhisper acts as a file watcher and automation engine that monitors transcribed results from Superwhisper (stored in `meta.json` files) and executes various automated actions based on configurable rules and triggers.

### Core Functionality
- **File Watching**: Monitors Superwhisper's recordings folder for new transcriptions
- **Action Execution**: Supports multiple action types including text insertion, URL opening, shell scripts, AppleScript execution, and Apple shortcuts
- **Rule-Based Automation**: Configurable triggers based on voice patterns, applications, and modes
- **Inter-Process Communication**: Socket-based communication for CLI commands and status queries
- **Configuration Management**: JSON-based configuration with live reloading
- **History Management**: Automatic cleanup of old recordings based on retention policies
- **Update Checking**: Automatic version checking for both CLI and Keyboard Maestro components

---

## Project Structure

```
macrowhisper-cli/src/
├── Package.swift                    # Swift Package Manager configuration
├── Package.resolved                 # Package dependencies lock file
├── oldCode.swift                    # Legacy monolithic implementation (5363 lines)
├── macrowhisper.xcodeproj/          # Xcode project files
├── .swiftpm/                        # Swift Package Manager metadata
└── macrowhisper/                    # Main application source code
    ├── main.swift                   # Application entry point and CLI handling
    ├── Info.plist                   # App permissions and metadata
    ├── Config/                      # Configuration management
    │   ├── AppConfiguration.swift   # Configuration data structures
    │   └── ConfigurationManager.swift # Configuration loading/saving/watching
    ├── Watcher/                     # File system monitoring
    │   ├── RecordingsFolderWatcher.swift # Main file watcher for recordings
    │   └── ConfigChangeWatcher.swift     # Configuration file watcher
    ├── Networking/                  # Network and IPC functionality
    │   ├── SocketCommunication.swift    # Unix socket server for CLI commands
    │   └── VersionChecker.swift         # Automatic update checking
    ├── History/                     # Recording history management
    │   └── HistoryManager.swift         # Cleanup of old recordings
    ├── Utils/                       # Utility functions and helpers
    │   ├── Accessibility.swift          # macOS accessibility and input simulation
    |   |-- ActionExecutor.sift     #Handles execution of differen action types
    │   ├── Placeholders.swift           # Dynamic content replacement system
    │   ├── ShellUtils.swift             # Shell command escaping utilities
    │   ├── Logger.swift                 # Logging system with rotation
    │   └── NotificationManager.swift    # System notifications
    └── System/                      # System-level operations (empty)
```

---

## Core Components

### 1. Application Entry Point

#### `macrowhisper/main.swift` (710 lines)
**Purpose**: Application bootstrap, CLI argument parsing, and main event loop

**Key Global Variables**:
- `globalConfigManager`: Shared configuration manager instance
- `recordingsWatcher`: File system watcher for recordings
- `socketCommunication`: IPC server for CLI commands
- `historyManager`: Recording cleanup manager
- `logger`: Global logging instance

**Key Functions**:
- `acquireSingleInstanceLock()`: Ensures only one instance runs
- `initializeWatcher()`: Sets up file system monitoring
- `checkWatcherAvailability()`: Validates Superwhisper folder existence
- `main()`: Application entry point and event loop

**CLI Commands Supported**:
- `--help`, `-h`: Show usage information
- `--version`, `-v`: Display version information
- `--status`, `-s`: Show application status
- `--exec-insert <name>`: Execute specific insert action
- `--get-insert`: Get current active insert
- `--list-inserts`: List all available inserts
- `--auto-return [true/false]`: Toggle auto-return functionality

---

### 2. Configuration System

#### `macrowhisper/Config/AppConfiguration.swift` (415 lines)
**Purpose**: Defines the complete configuration data structure

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

**`AppConfiguration.Insert`**:
- `action`: Text or command to execute
- `icon`: Optional icon override
- `moveTo`: Optional window/app target
- `noEsc`, `simKeypress`, `actionDelay`, `pressReturn`: Per-insert overrides
- **Trigger System**:
  - `triggerVoice`: Regex pattern for voice matching
  - `triggerApps`: Regex pattern for app matching
  - `triggerModes`: Regex pattern for mode matching
  - `triggerLogic`: "and"/"or" logic for combining triggers

**`AppConfiguration.Url`**: Similar structure for URL actions
**`AppConfiguration.Shortcut`**: Similar structure for keyboard shortcuts
**`AppConfiguration.Shell`**: Similar structure for shell commands
**`AppConfiguration.AppleScript`**: Similar structure for AppleScript execution

#### `macrowhisper/Config/ConfigurationManager.swift` (173 lines)
**Purpose**: Manages configuration loading, saving, and live reloading

**Key Features**:
- Thread-safe configuration access using `DispatchQueue`
- Automatic file watching for configuration changes
- Command-line configuration updates
- JSON serialization with pretty printing and path formatting

**Key Methods**:
- `loadConfig()`: Load configuration from JSON file
- `saveConfig()`: Save configuration with proper formatting
- `updateFromCommandLine()`: Update config from CLI arguments
- `setupFileWatcher()`: Monitor config file for changes

---

### 3. File System Monitoring

#### `macrowhisper/Watcher/RecordingsFolderWatcher.swift` (367 lines)
**Purpose**: Core file system watcher that monitors Superwhisper's recordings folder

**Key Features**:
- **Directory Monitoring**: Watches for new recording subdirectories
- **Meta.json Waiting**: Handles delayed meta.json file creation
- **Duplicate Prevention**: Tracks processed recordings to avoid reprocessing
- **Cleanup Handling**: Manages removal of deleted recordings

**Key Methods**:
- `start()`: Begin monitoring the recordings folder
- `handleFolderChangeEvent()`: Process folder changes
- `processNewRecording()`: Handle new recording detection
- `watchForMetaJsonCreation()`: Wait for meta.json file completion
- `processMetaJson()`: Parse and execute actions from meta.json

**Processing Flow**:
1. Detect new recording directory
2. Check if meta.json exists immediately
3. If not, set up watcher for meta.json creation
4. Once meta.json is available, parse and execute configured actions
5. Mark recording as processed to prevent reprocessing

#### `macrowhisper/Watcher/ConfigChangeWatcher.swift` (43 lines)
**Purpose**: Monitors configuration file for changes and triggers reloads

**Simple Implementation**:
- Uses `DispatchSource.makeFileSystemObjectSource` for file monitoring
- Triggers callback when configuration file is modified
- Enables live configuration reloading without restart

---

### 4. Inter-Process Communication

#### `macrowhisper/Networking/SocketCommunication.swift` (498 lines)
**Purpose**: Unix domain socket server for CLI command handling and action execution

**Key Features**:
- **Command Processing**: Handles various CLI commands via socket
- **Action Execution**: Core logic for executing insert, URL, shell, and AppleScript actions
- **Placeholder Processing**: Dynamic content replacement in actions
- **Accessibility Integration**: Keyboard simulation and input field detection

**Supported Commands**:
- `reloadConfig`: Reload configuration from file
- `updateConfig`: Update configuration values
- `status`: Get application status
- `version`: Get version information
- `listInserts`: List all available inserts
- `execInsert`: Execute specific insert action
- `autoReturn`: Toggle auto-return functionality

**Action Processing Methods**:
- `processInsertAction()`: Handle text insertion with placeholder replacement
- `applyInsert()`: Execute insert action with accessibility checks
- `applyInsertForExec()`: Execute insert for CLI commands (no ESC key)
- `pasteText()`: Handle text pasting via clipboard or keystroke simulation

**Placeholder System**:
- XML tag extraction: `{{xml:tagname}}` extracts content from `<tagname>` in LLM results
- Dynamic placeholders: `{{key}}` replaced with meta.json values
- Date formatting: `{{date:format}}` for timestamp insertion
- Shell escaping for safe command execution

---

### 5. Utility Systems

#### `macrowhisper/Utils/Placeholders.swift` (169 lines)
**Purpose**: Advanced placeholder processing system for dynamic content replacement

**Key Functions**:
- `processXmlPlaceholders()`: Extract XML tags from LLM results and clean content
- `replaceXmlPlaceholders()`: Replace XML placeholders in action strings
- `processDynamicPlaceholders()`: Handle standard placeholders and date formatting

**Placeholder Types**:
1. **XML Placeholders**: `{{xml:summary}}` extracts `<summary>content</summary>`
2. **Meta.json Fields**: `{{result}}`, `{{llmResult}}`, `{{modeName}}`, etc.
3. **Date Placeholders**: `{{date:short}}`, `{{date:long}}`, `{{date:yyyy-MM-dd}}`
4. **Special Fields**: `{{swResult}}` (smart result selection)

#### `macrowhisper/Utils/Accessibility.swift` (129 lines)
**Purpose**: macOS accessibility system integration for input simulation

**Key Functions**:
- `requestAccessibilityPermission()`: Request accessibility permissions
- `isInInputField()`: Detect if cursor is in text input field
- `simulateKeyDown()`: Send keyboard events
- `simulateEscKeyPress()`: Smart ESC key handling with configuration respect

**Input Field Detection**:
- Role-based detection: `AXTextField`, `AXTextArea`, `AXSearchField`
- Subrole checking: `AXSecureTextField`, `AXTextInput`
- Editable attribute verification
- Action capability checking: `AXInsertText`, `AXDelete`

#### `macrowhisper/Utils/Logger.swift` (94 lines)
**Purpose**: Comprehensive logging system with file rotation

**Features**:
- **Log Levels**: DEBUG, INFO, WARNING, ERROR
- **File Rotation**: Automatic rotation when logs exceed 5MB
- **Console Output**: Conditional console logging based on TTY detection
- **Timestamp Formatting**: Consistent timestamp format across all logs

**Global Logging Functions**:
- `logInfo()`, `logWarning()`, `logError()`, `logDebug()`

#### `macrowhisper/Utils/NotificationManager.swift` (24 lines)
**Purpose**: System notification handling

**Simple Implementation**:
- Uses AppleScript for cross-system compatibility
- Respects global notification disable setting
- Provides `notify()` global function

#### `macrowhisper/Utils/ShellUtils.swift` (11 lines)
**Purpose**: Shell command safety utilities

**Key Function**:
- `escapeShellCharacters()`: Escape special characters for safe shell execution
- Handles: `\`, `"`, `` ` ``, `$` characters

---

### 6. History Management

#### `macrowhisper/History/HistoryManager.swift` (114 lines)
**Purpose**: Automatic cleanup of old recording files based on retention policies

**Key Features**:
- **Configurable Retention**: Based on `history` setting in configuration
- **Smart Cleanup**: Keeps most recent recording when `history = 0`
- **Scheduled Execution**: Runs cleanup every 24 hours
- **Safe Deletion**: Handles errors gracefully and logs results

**Cleanup Logic**:
- `history = null`: Keep all recordings (no cleanup)
- `history = 0`: Keep only the most recent recording
- `history = N`: Keep recordings from last N days

---

### 7. Network Services

#### `macrowhisper/Networking/VersionChecker.swift` (347 lines)
**Purpose**: Automatic update checking for CLI and Keyboard Maestro components

**Key Features**:
- **Dual Component Checking**: Monitors both CLI and KM macro versions
- **Smart Notifications**: Different notification types based on what needs updating
- **Backoff Strategy**: Prevents excessive checking after failures
- **Version Comparison**: Semantic version comparison logic

**Update Flow**:
1. Check versions.json from GitHub repository
2. Compare current versions with latest available
3. Show appropriate notification based on what needs updating
4. Provide update instructions or direct links

---

## Data Flow and Integration

### 1. Application Startup Flow
```
main.swift
├── Load configuration (ConfigurationManager)
├── Initialize logging (Logger)
├── Acquire single instance lock
├── Start socket server (SocketCommunication)
├── Initialize history manager (HistoryManager)
├── Start recordings watcher (RecordingsFolderWatcher)
└── Enter main run loop
```

### 2. Recording Processing Flow
```
RecordingsFolderWatcher detects new directory
├── Check if already processed
├── Look for meta.json file
├── If not found, watch for creation
├── Once available, parse meta.json
├── Determine active insert/action
├── Process placeholders (Placeholders.swift)
├── Execute action (SocketCommunication)
├── Handle accessibility (Accessibility.swift)
├── Mark as processed
└── Log results (Logger)
```

### 3. Configuration Management Flow
```
ConfigurationManager
├── Load from JSON file
├── Watch for file changes (ConfigChangeWatcher)
├── Handle CLI updates
├── Validate and save changes
├── Notify components of updates
└── Trigger watcher restart if needed
```

### 4. CLI Command Flow
```
CLI command received
├── Check single instance lock
├── Send command via socket (SocketCommunication)
├── Server processes command
├── Execute appropriate action
├── Return response to client
└── Exit client process
```

---

## Key Design Patterns

### 1. **Single Instance Pattern**
- Uses file locking to ensure only one instance runs
- CLI commands communicate with running instance via Unix socket

### 2. **Observer Pattern**
- File system watchers notify of changes
- Configuration changes trigger component updates

### 3. **Command Pattern**
- Socket communication uses structured command messages
- Each command type has specific handling logic

### 4. **Strategy Pattern**
- Different action types (insert, URL, shell, AppleScript) use common interface
- Placeholder processing supports multiple replacement strategies

### 5. **Template Method Pattern**
- Action execution follows consistent flow with customizable steps
- Accessibility checks and delay handling are standardized

---

## Configuration Schema

The application uses a JSON configuration file with the following structure:

```json
{
  "defaults": {
    "watch": "~/Documents/superwhisper",
    "noUpdates": false,
    "noNoti": false,
    "activeInsert": "default",
    "icon": "",
    "moveTo": "",
    "noEsc": false,
    "simKeypress": false,
    "actionDelay": 0.0,
    "history": null,
    "pressReturn": false
  },
  "inserts": {
    "insertName": {
      "action": "Text to insert with {{placeholders}}",
      "triggerVoice": "^(summarize|summary)",
      "triggerApps": "com.apple.mail",
      "triggerModes": "email",
      "triggerLogic": "or"
    }
  },
  "urls": { /* Similar structure */ },
  "shortcuts": { /* Similar structure */ },
  "shell": { /* Similar structure */ },
  "applescript": { /* Similar structure */ }
}
```

---

## Dependencies

### External Dependencies (Package.swift)
- **Swifter**: HTTP server framework (used for socket communication)

### System Dependencies
- **Foundation**: Core Swift framework
- **Cocoa**: macOS UI framework
- **ApplicationServices**: Accessibility and input simulation
- **Carbon**: Low-level keyboard event handling
- **UserNotifications**: System notifications (legacy)

---

## File Permissions and Security

### Required Permissions (Info.plist)
- **NSAppleEventsUsageDescription**: Required for AppleScript execution
- **NSAccessibilityUsageDescription**: Required for keyboard input simulation

### File System Access
- **Configuration**: `~/.config/macrowhisper/`
- **Logs**: `~/Library/Logs/Macrowhisper/`
- **Socket**: `~/.config/macrowhisper/macrowhisper.sock`
- **Lock File**: `/tmp/macrowhisper.lock`
- **Processed Recordings**: `~/Library/Application Support/Macrowhisper/`

---

## Error Handling and Logging

### Logging Strategy
- **File-based logging** with automatic rotation
- **Console output** when running interactively
- **Structured log levels** (DEBUG, INFO, WARNING, ERROR)
- **Contextual information** including timestamps and component names

### Error Recovery
- **Graceful degradation** when components fail
- **Automatic retry** for transient failures
- **User notification** for critical errors
- **Configuration validation** with fallback to defaults

---

## Performance Considerations

### File System Monitoring
- **Efficient event-driven** monitoring using `DispatchSource`
- **Minimal polling** - only when necessary for meta.json completion
- **Processed recording tracking** to avoid duplicate processing

### Memory Management
- **Weak references** in closures to prevent retain cycles
- **Automatic cleanup** of temporary watchers
- **Log file rotation** to prevent unbounded growth

### Thread Safety
- **Dedicated queues** for different components
- **Synchronized access** to shared configuration
- **Background processing** for network operations

---

## Future Extension Points

### Trigger System
The configuration includes placeholder trigger fields for future extensibility:
- **Voice triggers**: Regex matching on transcribed text
- **App triggers**: Regex matching on application names/bundle IDs
- **Mode triggers**: Regex matching on Superwhisper modes
- **Trigger logic**: AND/OR combinations of trigger conditions

### Action Types
The modular action system can be extended with new action types:
- Current: Insert, URL, Shell, AppleScript, Shortcut
- Potential: File operations, API calls, database operations

### Placeholder System
The placeholder processing system supports:
- **XML tag extraction** from LLM results
- **Dynamic content** from meta.json
- **Date/time formatting**
- **Custom functions** (extensible)

This codebase map serves as a comprehensive guide for understanding and extending the Macrowhisper application. Each component is designed with clear separation of concerns and well-defined interfaces, making it easy to modify or extend functionality while maintaining system stability.