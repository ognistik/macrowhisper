# Macrowhisper CLI - Codebase Map

## Overview

**Macrowhisper** is a sophisticated automation helper application designed to work seamlessly with **Superwhisper**, a dictation application. It functions as a file watcher and automation engine that monitors transcribed results from Superwhisper (stored in `meta.json` files) and executes various automated actions based on configurable rules and intelligent triggers.

> **Note**: This codebase map reflects the current state as of version 1.3.0, with all line counts and feature descriptions updated to match the actual implementation including the unified action system.

### Core Functionality
- **File Watching**: Monitors Superwhisper's recordings folder for new transcriptions
- **Unified Action System**: Supports multiple action types (insert, URL, shortcut, shell script, AppleScript) with consistent management and execution
- **Advanced Trigger System**: Rule-based automation with voice patterns, application context, and mode matching across all action types
- **Enhanced AutoReturn**: Intelligent autoReturn cancellation when recording sessions are interrupted or superseded
- **Service Management**: Full launchd service integration for background operation
- **Inter-Process Communication**: Unix socket-based communication for CLI commands and status queries
- **Configuration Management**: JSON-based configuration with live reloading, auto-migration, and persistent path management
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
    │   ├── RecordingsFolderWatcher.swift # Main file watcher for recordings (766 lines)
    │   ├── SuperwhisperFolderWatcher.swift # Parent directory watcher for graceful startup (85 lines)
    │   └── ConfigChangeWatcher.swift     # Configuration file watcher (42 lines)
    ├── Networking/                  # Network and IPC functionality
    │   ├── SocketCommunication.swift    # Unix socket server for CLI commands (794 lines)
    │   └── VersionChecker.swift         # Automatic update checking (514 lines)
    ├── History/                     # Recording history management
    │   └── HistoryManager.swift         # Cleanup of old recordings (115 lines)
    └── Utils/                       # Utility functions and helpers
        ├── ServiceManager.swift         # macOS launchd service management (437 lines)
         ├── ClipboardMonitor.swift       # Advanced clipboard monitoring and restoration (updated: configurable buffer)
        ├── ActionExecutor.swift         # Action execution coordination (402 lines)
        ├── TriggerEvaluator.swift       # Intelligent trigger evaluation system (385 lines)
        ├── Accessibility.swift          # macOS accessibility and input simulation (524 lines)
        ├── Placeholders.swift           # Dynamic content replacement system (785 lines)
        ├── Logger.swift                 # Logging system with rotation (110 lines)
        ├── NotificationManager.swift    # System notifications (23 lines)
        └── ShellUtils.swift             # Shell command escaping utilities (17 lines)
```

---

## Core Components

### 1. Application Entry Point

#### `macrowhisper/main.swift` (1101 lines)
**Purpose**: Application bootstrap, CLI argument parsing, service management, and main event loop with enhanced thread safety

**Thread-Safe State Management** (NEW):
- `GlobalStateManager`: Thread-safe manager for all shared application state
- Uses concurrent dispatch queues with barriers for atomic read/write operations
- Prevents race conditions on timer management and global variables
- Automatic cleanup and invalidation of timers during state transitions

**Key Global Variables** (Now Thread-Safe):
- `globalState`: Thread-safe state manager instance containing all shared state
- `globalConfigManager`: Shared configuration manager instance
- `recordingsWatcher`: File system watcher for recordings
- `superwhisperFolderWatcher`: Parent directory watcher for graceful startup
- `socketCommunication`: IPC server for CLI commands with timeout protection
- `historyManager`: Recording cleanup manager
- `logger`: Global logging instance

**State Variables** (Managed by GlobalStateManager):
- `autoReturnEnabled`: Auto-return functionality state with atomic access
- `scheduledActionName`: Scheduled action name with atomic access
- `autoReturnTimeoutTimer`: Timer with automatic invalidation on updates
- `scheduledActionTimeoutTimer`: Timer with automatic invalidation on updates
- `socketHealthTimer`: Socket health monitoring timer with atomic management
- `lastDetectedFrontApp`: Application context tracking with thread safety

**Key Functions** (Enhanced with Thread Safety):
- `acquireSingleInstanceLock()`: Ensures only one instance runs using file locking
- `initializeWatcher()`: Sets up file system monitoring with error handling
- `checkWatcherAvailability()`: Validates Superwhisper folder existence
- `checkSocketHealth()` / `recoverSocket()`: Socket health monitoring and recovery with timeouts
- `registerForSleepWakeNotifications()`: System sleep/wake handling
- `cancelAutoReturn()`: Thread-safe autoReturn cancellation using atomic operations
- `cancelScheduledAction()`: Thread-safe scheduled action cancellation using atomic operations
- `startAutoReturnTimeout()` / `cancelAutoReturnTimeout()`: Thread-safe timeout management with automatic timer invalidation
- `startScheduledActionTimeout()` / `cancelScheduledActionTimeout()`: Thread-safe timeout management with automatic timer invalidation
- `startSocketHealthMonitor()` / `stopSocketHealthMonitor()`: Thread-safe socket health monitoring with timeout protection
- `printHelp()`: Comprehensive CLI help system

**Concurrency Improvements** (NEW):
- All timer operations are now thread-safe with automatic cleanup
- Global state variables use atomic read/write operations
- Prevents race conditions in multi-threaded scenarios
- Enhanced error handling with timeout recovery mechanisms

**CLI Commands Supported**:
- **Service Management**: `--install-service`, `--start-service`, `--stop-service`, `--restart-service`, `--uninstall-service`, `--service-status`
- **Configuration**: `--reveal-config`, `--set-config`, `--reset-config`, `--get-config`
- **Information**: `--help`, `--version`, `--status`, `--verbose`
- **Unified Action Management**: `--list-actions`, `--exec-action <name>`, `--get-action [<name>]`, `--action [<name>]`, `--remove-action <name>`
- **Type-Specific Action Creation**: `--add-insert <name>`, `--add-url <name>`, `--add-shortcut <name>`, `--add-shell <name>`, `--add-as <name>`
- **Type-Specific Action Listing**: `--list-inserts`, `--list-urls`, `--list-shortcuts`, `--list-shell`, `--list-as`
- **Legacy Commands (Deprecated)**: `--exec-insert <name>`, `--get-insert [<name>]`, `--insert [<name>]`
- **Runtime Control**: `--auto-return [true/false]`, `--schedule-action [<name>]`, `--get-icon`
- **Update Management**: `--check-updates`, `--version-state`, `--version-clear`

**Enhanced Features**:
- **Unified Action System**: All action types managed consistently with type-aware validation
- **Intelligent AutoReturn**: Cancellation when recordings are interrupted or superseded
- **Scheduled Action System**: Schedule any action type for next recording session with same priority as auto-return
- **Timeout Management**: Configurable timeout for auto-return and scheduled actions when no recording session is active (default: 5 seconds, 0 = no timeout)
- **Active Action Indicators**: List commands show which action is currently active
- **Duplicate Prevention**: Action names are unique across all action types
- **Auto-Migration**: Seamless transition from `activeInsert` to `activeAction` in configurations

---

### 2. Configuration System

#### `macrowhisper/Config/AppConfiguration.swift` (473 lines)
**Purpose**: Defines the complete configuration data structure with unified action system and auto-migration

**Key Structures**:

**`AppConfiguration.Defaults`**:
- `watch`: Path to Superwhisper folder
- `noUpdates`: Disable update checking
- `noNoti`: Disable notifications
- `activeAction`: Currently active action name (supports all action types)
- `icon`: Default icon for actions
- `moveTo`: Default window/app to move to after actions
- `noEsc`: Disable ESC key simulation
- `simKeypress`: Use keystroke simulation instead of clipboard
- `actionDelay`: Delay before executing actions
- `history`: Days to retain recordings (null = keep forever)
- `pressReturn`: Auto-press return after actions
- `returnDelay`: Delay before pressing return (default: 0.1s)
- `restoreClipboard`: Restore original clipboard content (default: true)
- `scheduledActionTimeout`: Timeout for auto-return and scheduled actions (default: 5s, 0 = no timeout)
- `clipboardStacking`: Enable multiple clipboard captures during a session (default: false)
- `clipboardBuffer`: Pre-recording clipboard buffer window in seconds (default: 5s)
- `autoUpdateConfig`: Automatically update the configuration file on startup (default: true)

  Required defaults: `watch` and `actionDelay`. All other fields are optional and fall back to the same values used when auto-creating configs. The `autoUpdateConfig` flag controls only the startup-time automatic configuration update.

**Unified Action System** (All action types support the same features):
- **`AppConfiguration.Insert`**: Text insertion with advanced placeholder support
- **`AppConfiguration.Url`**: URL actions with custom application opening
- **`AppConfiguration.Shortcut`**: macOS Shortcuts integration
- **`AppConfiguration.ScriptShell`**: Shell script execution
- **`AppConfiguration.ScriptAppleScript`**: AppleScript execution

**Universal Action Properties** (Available for all action types):
- `action`: The action content/command
- `icon`: Custom icon for the action
- `moveTo`: Application/window to focus after execution
- `actionDelay`: Custom delay before execution
- `noEsc`: Disable ESC key simulation for this action
- `simKeypress`: Use keystroke simulation for this action
- `pressReturn`: Auto-press return after this action
- `restoreClipboard`: Override clipboard restoration setting for this action (null = use global default)
- Plus action-type specific properties (e.g., `openWith` for URLs)

**Advanced Trigger System** (All action types):
- `triggerVoice`: Regex pattern for voice matching (supports exceptions with `!` prefix)
- `triggerApps`: Regex pattern for app matching (name or bundle ID)
- `triggerModes`: Regex pattern for Superwhisper mode matching
- `triggerLogic`: "and"/"or" logic for combining triggers

**Auto-Migration Features**:
- **Backward Compatibility**: Seamless migration from `activeInsert` to `activeAction`
- **Preserves null values** in JSON output for clean configuration files
- **Automatic defaults** for missing fields
- **Version-safe decoding** with fallback logic

#### `macrowhisper/Config/ConfigurationManager.swift` (348 lines)
**Purpose**: Advanced configuration management with persistence, live reloading, and robust error recovery

**Enhanced Error Handling** (NEW):
- **Detailed JSON Error Reporting**: Specific decoding error messages with exact location information
- **Automatic Backup and Recovery**: Creates timestamped backups of corrupted configurations
- **Empty File Detection**: Handles empty configuration files gracefully
- **Atomic Write Operations**: Prevents configuration corruption during saves
- **Validation Before Commit**: Verifies generated JSON can be parsed before replacing original
- **Permission Error Handling**: Specific guidance for file system permission issues

**Key Features**:
- **Thread-safe configuration access** using dedicated `DispatchQueue`
- **Persistent configuration paths** using `UserDefaults`
- **Smart path resolution**: Handles both file and directory paths
- **Live file watching** with JSON error recovery and automatic retry
- **Command queue system** for configuration updates
- **Enhanced error notifications**: User-friendly messages with recovery instructions
- **Corruption recovery**: Automatic backup creation and reset to defaults when needed

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
- `hasActiveRecordingSessions()`: Check if any recording sessions are in progress

---

### 4. File System Monitoring

#### `macrowhisper/Watcher/RecordingsFolderWatcher.swift` (766 lines)
**Purpose**: Advanced file system watcher with intelligent processing, enhanced autoReturn management, and memory leak prevention

**Memory Management Improvements** (NEW):
- **Automatic Resource Cleanup**: Added deinit method for proper cleanup
- **Weak Reference Patterns**: All dispatch sources use weak self references to prevent retain cycles
- **Proper Timer Invalidation**: Enhanced cleanup of all watchers and timers on stop
- **Thread-safe Cleanup**: Coordinated cleanup across multiple monitoring sessions

**Key Features**:
- **Persistent processing tracking**: Prevents duplicate processing using file-based storage
- **Intelligent startup behavior**: Marks most recent recording as processed on startup
- **Smart clipboard monitoring initiation**: Only starts clipboard monitoring when needed (incomplete meta.json)
- **Enhanced AutoReturn Management**: Intelligent cancellation when recordings are interrupted or superseded
- **Advanced trigger evaluation**: Uses TriggerEvaluator for smart action selection across all action types
- **Comprehensive cleanup**: Handles deleted recordings, meta.json files, and orphaned watchers with proper memory management
- **Memory leak prevention**: Proper resource cleanup and weak reference usage throughout

**Enhanced AutoReturn and Scheduled Action Logic**:
- **Normal Operation**: AutoReturn and scheduled actions apply to the intended recording and get reset after use
- **Mutual Exclusion**: Only one of auto-return or scheduled action can be active at a time
- **Timeout Management**: Configurable timeout when no recording session is active (prevents indefinite waiting, 0 = no timeout)
- **Interruption Handling**: Both cancelled if recording folder is deleted during processing
- **Supersession Logic**: Both cancelled if newer recordings appear before current one completes
- **Smart Timing**: Only cancels when recordings are actually interrupted, not when they naturally complete

**Smart Clipboard Monitoring Logic**:
```swift
if meta.json exists immediately {
    if isMetaJsonComplete(has valid duration) {
        // Process immediately WITHOUT clipboard monitoring
        processMetaJson()
    } else {
        // Start clipboard monitoring and process incomplete meta.json
        clipboardMonitor.startEarlyMonitoring()
        processMetaJson()
    }
} else {
    // Start clipboard monitoring and wait for meta.json creation
    clipboardMonitor.startEarlyMonitoring()
    watchForMetaJsonCreation()
}
```

**Enhanced Processing Flow**:
1. **Conditional Monitoring**: Start clipboard monitoring only if meta.json is incomplete or missing
2. **Early Data Capture**: Capture selectedText and clipboard state when monitoring starts
3. **Meta.json Waiting**: Handle delayed meta.json creation with timeout
4. **Context Gathering**: Capture application context and mode information
5. **Session Data Enhancement**: Add selectedText and clipboardContext to metaJson
6. **AutoReturn/Scheduled Action Priority Check**: Highest priority actions with intelligent cancellation and timeout management
7. **Unified Trigger Evaluation**: Use TriggerEvaluator to find matching actions across all types
8. **Unified Action Execution**: Execute matched actions via ActionExecutor with enhanced metaJson
9. **Comprehensive Cleanup**: Mark as processed and clean up all monitoring

**Key Components**:
- **Enhanced TriggerEvaluator**: Intelligent action matching across all action types
- **Unified ActionExecutor**: Coordinated action execution for all action types
- **Enhanced ClipboardMonitor**: Early clipboard state capture with smart restoration
- **Persistent Tracking**: File-based processing history
- **AutoReturn/Scheduled Action Management**: Context-aware cancellation and timeout management with detailed logging
- **Timeout System**: 5-second timeout for actions when no recording session is active

#### `macrowhisper/Watcher/SuperwhisperFolderWatcher.swift` (85 lines)
**Purpose**: Graceful startup watcher for scenarios where Superwhisper folder doesn't exist yet

**Problem Solved**: When users configure a Superwhisper path that doesn't exist yet (first-time setup, cloud sync, etc.), the app can now wait gracefully instead of failing to start.

**Key Features**:
- **Parent directory monitoring**: Watches the Superwhisper parent directory for changes
- **Auto-directory creation**: Creates parent directories if they don't exist
- **Event-driven detection**: Efficiently detects when the recordings subdirectory appears
- **Seamless handoff**: Automatically initializes RecordingsFolderWatcher when recordings folder is detected
- **One-time operation**: Stops itself once the target folder is found

**Usage Scenarios**:
1. **First-time setup**: User hasn't created Superwhisper folder yet
2. **Cloud sync**: Folder is syncing and temporarily unavailable
3. **Configuration changes**: User changes watch path to non-existent location
4. **Startup reliability**: Ensures app continues running while waiting for folder

**Integration Flow**:
1. **Startup Check**: If recordings folder doesn't exist, SuperwhisperFolderWatcher starts instead of RecordingsFolderWatcher
2. **Directory Monitoring**: Watches parent directory for filesystem changes
3. **Detection**: When recordings folder appears, triggers callback
4. **Handoff**: Stops itself and initializes RecordingsFolderWatcher
5. **Status Reporting**: Reports status via `--status` command as "Folder watcher: yes (waiting for recordings folder)"

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
   - Raw regex patterns: Full regex control wrapped in `==` delimiters (e.g., `==^exact match$==`); raw matches do not strip any text from the result
   - Normal patterns: Treated as prefix matches and stripped from the start of result/swResult on match
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

### 6. Unified Action Execution System

#### `macrowhisper/Utils/ActionExecutor.swift` (402 lines)
**Purpose**: Coordinated execution of all action types with unified interface and advanced features

**Key Features**:
- **Unified execution interface**: Single entry point for all action types (insert, URL, shortcut, shell, AppleScript)
- **Type-aware execution**: Intelligent handling based on action type detection
- **Enhanced clipboard management**: Integration with ClipboardMonitor for all action types
- **Context-aware execution**: Application-specific behavior for all actions
- **Advanced placeholder processing**: Dynamic content replacement across all action types
- **Graceful error handling**: Comprehensive error recovery

**Unified Action Types**:
1. **Insert Actions**: Text insertion with clipboard management and smart paste detection
2. **URL Actions**: Web/application launching with custom handlers and opening preferences
3. **Shortcut Actions**: macOS Shortcuts integration with stdin piping and temp file handling
4. **Shell Script Actions**: Bash command execution with environment isolation
5. **AppleScript Actions**: Native AppleScript execution with proper error handling

**Universal Action Features**:
- **Custom Delays**: Per-action `actionDelay` settings with fallback to global defaults
- **ESC Key Management**: Per-action `noEsc` settings with intelligent simulation
- **Icon Support**: Custom icons for all action types with fallback hierarchy
- **Move-To Functionality**: Application/window focus management for all action types
- **Trigger Coordination**: Seamless integration with trigger-based action execution

**Special Features**:
- **`.none` handling**: Skip action but apply delays and context changes for all action types
- **`.autoPaste` intelligence**: Smart paste behavior based on input field detection (insert actions)
- **Placeholder Processing**: XML tags, dynamic content, and context variables for all actions
- **CLI Execution Methods**: Separate execution paths for CLI commands vs. automated triggers

---

### 7. Enhanced Clipboard Management

#### `macrowhisper/Utils/ClipboardMonitor.swift` (1024 lines)
**Purpose**: Advanced clipboard monitoring and restoration to handle timing conflicts with smart logging, enhanced session management, and memory-bounded storage

**Problem Solved**: Superwhisper and Macrowhisper both modify the clipboard simultaneously, leading to conflicts and lost user content. Additionally, users often copy content shortly before starting a recording and want to access it in actions.

**Memory Management Improvements** (NEW):
- **Bounded Arrays**: Maximum 50 clipboard changes per session, 100 global history entries
- **Periodic Cleanup**: Automatic cleanup every 30 seconds to prevent memory growth
- **Real-time Bounds Checking**: Prevents unbounded growth during active monitoring
- **Intelligent Session Cleanup**: Removes inactive sessions older than 5 minutes
- **Performance Monitoring**: Tracks cleanup performance and memory usage

**Key Features**:
- **Lightweight app-lifetime monitoring**: Continuous configurable rolling buffer of clipboard changes from app startup (default 5s, 0 disables)
- **Smart session monitoring**: Only starts intensive session monitoring when meta.json is incomplete; skips if recording is ready immediately
- **Early session data capture**: Captures selectedText, userOriginalClipboard, and pre-recording clipboard when recording folder appears
- **Enhanced clipboardContext logic**: Prioritizes session changes, falls back to pre-recording clipboard content from global history
- **Clipboard stacking support**: Optional feature to capture multiple clipboard changes during recording with XML formatting
- **Smart logging system**: Only logs clipboard changes during actual action execution periods (content not logged for privacy)
- **Dual monitoring architecture**: Lightweight global monitoring (0.5s intervals) + intensive session monitoring (0.01s intervals)
- **Single instance architecture**: Shared ClipboardMonitor instance prevents duplicate monitoring and logging
- **Action execution boundaries**: Clear start/finish markers for relevant logging periods
- **Thread-safe management**: Concurrent monitoring with proper synchronization using barriers
- **Configurable restoration**: Optional clipboard restoration for user preference
- **Independent placeholder support**: clipboardContext placeholder works regardless of restoreClipboard setting
- **Memory bounds enforcement**: Automatic trimming of old data to prevent memory leaks

**Enhanced Session Structure**:
```swift
private struct EarlyMonitoringSession {
    let userOriginalClipboard: String?    // Initial clipboard when folder appears
    let startTime: Date                   // Session start timestamp  
    var clipboardChanges: [ClipboardChange] = []  // All changes during session
    var isActive: Bool = true             // Session state
    let selectedText: String?             // Selected text captured at session start
    var isExecutingAction: Bool = false   // Controls clipboard change logging visibility
    let preRecordingClipboard: String?    // Clipboard content from before recording started
}
```

**Dual Monitoring Architecture**:
1. **App Startup**: Begin lightweight global monitoring (0.5s intervals) with 5-second rolling buffer
2. **Recording Detection**: When recording folder appears, capture pre-recording clipboard from global history
3. **Conditional Session Start**: Begin intensive session monitoring only if meta.json is incomplete or doesn't exist
4. **Early Data Capture**: Capture selectedText, original clipboard, and pre-recording clipboard immediately
5. **Intensive Change Tracking**: Monitor all clipboard changes during session with high precision (0.01s intervals)
6. **Action Execution Marking**: Mark start/finish of action execution for relevant logging
7. **Smart Logging**: Only log clipboard changes during action execution periods
8. **Coordinated Execution**: Execute actions with proper timing and Superwhisper synchronization
9. **Intelligent Restoration**: Restore appropriate clipboard content based on timing analysis
10. **Session Cleanup**: Session cleanup happens after action completion and restoration
11. **Continued Global Monitoring**: Lightweight monitoring continues for future recordings

**Action Execution Control Methods**:
- `startActionExecution(for:)`: Marks beginning of action execution, enables relevant clipboard logging
- `finishActionExecution(for:)`: Marks end of action execution, disables clipboard logging
- `stopEarlyMonitoring(for:)`: Natural session cleanup after action completion and restoration

**Smart Logging Architecture**:
- **Always Track**: All clipboard changes are tracked for restoration logic
- **Selectively Log**: Only clipboard changes during action execution periods are logged
- **Clean Output**: Eliminates phantom clipboard monitoring logs after action completion
- **No Race Conditions**: Simple boolean flag avoids complex cancellation token systems

**Placeholder Data Extraction**:
- **selectedText**: From session start capture, independent of current selection
- **clipboardContext**: Enhanced with pre-recording support and optional stacking:
  - **Priority 1**: Last clipboard change during recording session (maintains current behavior)
  - **Priority 2**: Most recent clipboard change within the configurable buffer window before recording started (default 5s)
  - **Fallback**: Empty string if no relevant changes found
  - **Stacking Behavior**: When `clipboardStacking` is enabled in configuration:
    - **Single change**: Returns content without XML tags (maintains current behavior)
    - **Multiple changes**: Returns all changes formatted with XML tags (`<clipboard_context_1>`, `<clipboard_context_2>`, etc.)
    - **Disabled (default)**: Returns only the last clipboard change (original behavior)
- **Restoration Independence**: Placeholder data available regardless of restoreClipboard setting

**Critical Timing Values**:
- `maxWaitTime: 0.1` seconds - Maximum time to wait for Superwhisper
- `pollInterval: 0.01` seconds - 10ms polling interval for intensive session monitoring
- `globalMonitoringInterval: 0.5` seconds - Lightweight global monitoring frequency (500ms)
- `clipboardBuffer (configurable)`: Rolling buffer size for pre-recording clipboard capture. Default 5.0s. Set to 0 to disable.

---

### 8. Inter-Process Communication

#### `macrowhisper/Networking/SocketCommunication.swift` (794 lines)
**Purpose**: Comprehensive Unix socket server for unified CLI commands and action execution with timeout protection

**Enhanced Reliability Features** (NEW):
- **Timeout Protection**: 10-second timeouts on all socket read/write operations
- **Non-blocking I/O**: Uses select() system calls to prevent indefinite blocking
- **Graceful Degradation**: Proper error handling and recovery from network timeouts
- **Atomic Operations**: Thread-safe socket operations with proper cleanup

**Key Features**:
- **Unified command system**: Streamlined command set with consistent action management
- **Service integration**: Service management commands
- **Configuration commands**: Live configuration updates with auto-migration
- **Universal action execution**: Unified execution system for all action types
- **Health monitoring**: Socket health checking and recovery with timeout detection
- **Thread-safe operation**: Proper queue management and concurrent client handling

**Socket Operations** (Enhanced):
- `readWithTimeout()`: Timeout-protected socket reading with select()
- `writeWithTimeout()`: Timeout-protected socket writing with select()
- `sendResponse()`: Safe response delivery with timeout and error handling
- `handleConnection()`: Enhanced connection handling with timeout protection

**Unified Command Categories**:
1. **Configuration**: `reloadConfig`, `updateConfig`
2. **Information**: `status`, `version`, `debug`
3. **Unified Action Management**: `listActions`, `execAction`, `getAction`, `removeAction`
4. **Type-Specific Listing**: `listInserts`, `listUrls`, `listShortcuts`, `listShell`, `listAppleScript`
5. **Action Creation**: `addInsert`, `addUrl`, `addShortcut`, `addShell`, `addAppleScript`
6. **Legacy Support**: `execInsert`, `getInsert`, `listInserts` (deprecated but functional)
7. **Service Control**: `serviceStatus`, `serviceStart`, `serviceStop`, `serviceRestart`, `serviceInstall`, `serviceUninstall`
8. **Runtime Control**: `autoReturn`, `getIcon`

**Enhanced Action Management**:
- **Universal Action Validation**: Consistent validation across all action types
- **Active Action Indicators**: All list commands show which action is currently active
- **Duplicate Prevention**: Action names must be unique across all action types
- **Type-Aware Execution**: Intelligent execution based on action type detection
- **Icon Management**: Smart icon resolution with fallback to defaults

**Enhanced Status Reporting**:
- **Recordings watcher status**: Shows if actively watching recordings folder
- **Folder watcher status**: Shows if waiting for recordings folder to appear ("yes (waiting for recordings folder)")
- **Active action display**: Shows current active action with type information
- **Auto-return status**: Shows if auto-return is enabled
- **Scheduled action status**: Shows if any action is scheduled for next recording
- **Path validation**: Reports both Superwhisper folder and recordings folder existence
- **Health warnings**: Alerts if watchers are in inconsistent states

**Advanced Features**:
- **Unified placeholder processing**: Full XML and dynamic placeholder support for all action types
- **Enhanced clipboard integration**: Proper clipboard handling for CLI commands
- **Context awareness**: Application and mode detection for all actions
- **Error recovery**: Graceful handling of connection failures

---

### 9. Utility Systems

#### `macrowhisper/Utils/Placeholders.swift` (785 lines)
**Purpose**: Advanced placeholder processing system for dynamic content replacement

**Placeholder Types**:
1. **XML Placeholders**: `{{xml:tagname}}` extracts content from `<tagname>` in LLM results
   - **JSON-escaped XML**: `{{json:xml:tagname}}` applies JSON string escaping to extracted XML content
   - **Raw XML**: `{{raw:xml:tagname}}` applies no escaping to extracted XML content (useful for AppleScript)
2. **Meta.json Fields**: `{{result}}`, `{{llmResult}}`, `{{modeName}}`, etc.
   - **JSON-escaped fields**: `{{json:swResult}}`, `{{json:frontApp}}`, etc. apply JSON string escaping
   - **Raw fields**: `{{raw:swResult}}`, `{{raw:frontApp}}`, etc. apply no escaping (useful for AppleScript)
3. **Date Placeholders**: `{{date:format}}` with various format options
   - **JSON-escaped dates**: `{{json:date:short}}` applies JSON string escaping to formatted dates
   - **Raw dates**: `{{raw:date:short}}` applies no escaping to formatted dates
4. **Smart Result**: `{{swResult}}` (intelligent result selection: llmResult > result)
5. **Selected Text**: `{{selectedText}}` gets text selected when recording folder appears (early capture)
   - **Capture timing**: Selected text captured immediately when recording session starts, not during placeholder processing
   - **JSON-escaped selected text**: `{{json:selectedText}}` applies JSON string escaping to selected text
   - **Raw selected text**: `{{raw:selectedText}}` applies no escaping to selected text (useful for AppleScript)
   - **Empty behavior**: If no text was selected at recording start, placeholder is removed entirely
6. **App Context**: `{{appContext}}` gets structured context information from the frontmost application
   - **Capture timing**: Captured during placeholder processing only if placeholder is used in action
   - **Structured format**: Always includes Active App and Active Window, optionally includes Active URL (browsers) and Active Element Content (input fields)
   - **Accessibility-based**: Uses macOS accessibility APIs to extract app, window, URL, and input field content
   - **JSON-escaped app context**: `{{json:appContext}}` applies JSON string escaping
   - **Raw app context**: `{{raw:appContext}}` applies no escaping (useful for AppleScript)
   - **Performance optimized**: Fast capture with minimal processing overhead
7. **Clipboard Content**: `{{clipboardContext}}` gets clipboard content with enhanced pre-recording capture
   - **Enhanced capture logic**: 
     - **Priority 1**: Last clipboard change during recording session (maintains existing behavior)
     - **Priority 2**: Most recent clipboard change within 5 seconds before recording started (new feature)
   - **Pre-recording buffer**: Continuously monitors clipboard with 5-second rolling buffer before recordings
   - **Intelligent fallback**: Uses pre-recording content only when no session changes occurred
   - **Independence**: Works regardless of `restoreClipboard` setting
   - **JSON-escaped clipboard**: `{{json:clipboardContext}}` applies JSON string escaping
   - **Raw clipboard**: `{{raw:clipboardContext}}` applies no escaping (useful for AppleScript)
   - **Empty behavior**: If no relevant clipboard changes found, placeholder is removed entirely
8. **Regex Replacements**: All placeholders support `{{placeholder||regex||replacement}}` syntax
   - **Multiple replacements**: `{{key||pattern1||replace1||pattern2||replace2}}` applied sequentially
   - **Works with prefixes**: `{{raw:swResult||\\n||newline||"||quote}}` for precise control
   - **Escape sequences**: Standard regex escape sequences and replacement templates supported

**Advanced Features**:
- **XML content extraction**: Parse and clean LLM-generated XML tags
- **Content sanitization**: Remove HTML/XML artifacts
- **Date formatting**: Flexible date/time insertion
- **Processing order**: Regex replacements applied first, then prefix-based or action-type escaping
- **Prefix hierarchy**: `raw:` = no escaping, `json:` = JSON escaping, default = action-type escaping
- **Shell escaping**: Safe command execution for shell actions
- **Action-type awareness**: Different escaping for different action types (Insert/Shortcut = none, AppleScript = quotes, Shell/URL = full shell escaping)

#### `macrowhisper/Utils/Accessibility.swift` (524 lines)
**Purpose**: macOS accessibility system integration with enhanced capabilities

**Key Features**:
- **Permission management**: Request and validate accessibility permissions
- **Input field detection**: Advanced detection of text input contexts
- **Keyboard simulation**: Proper key event generation
- **Context awareness**: Smart ESC key handling based on application state
- **Selected text retrieval**: Get currently selected text from any application using accessibility APIs
- **Window content extraction**: Recursively extract all text content from application windows using accessibility APIs

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
├── Check recordings folder existence
│   ├── If exists: Start recordings watcher normally
│   └── If missing: Start SuperwhisperFolderWatcher to wait for folder creation
├── Register for system sleep/wake notifications
├── Start socket health monitoring
├── Initialize version checker
└── Enter main run loop
```

### 2. Recording Processing Flow (Enhanced with Smart Monitoring and Unified Actions)
```
RecordingsFolderWatcher detects new directory
├── Check if already processed (persistent tracking)
├── Smart Clipboard Monitoring Decision:
│   ├── If meta.json exists with valid duration → Process immediately WITHOUT monitoring
│   ├── If meta.json exists but incomplete → Start monitoring + process
│   └── If meta.json missing → Start monitoring + watch for creation
├── Early Data Capture (when monitoring starts):
│   ├── Capture selectedText using accessibility APIs
│   ├── Capture userOriginalClipboard state
│   └── Begin tracking all clipboard changes during session
├── Meta.json processing and validation
├── Gather application context (foreground app, bundle ID, mode)
├── Enhance metaJson with session data:
│   ├── Add selectedText (from early capture)
│   ├── Add clipboardContext (last clipboard change during session)
│   └── Add frontApp context
├── Unified Action Priority Evaluation (STRICT ORDER):
│   ├── 1. Auto-Return (highest priority - overrides everything)
│   │   ├── Check if autoReturnEnabled is true
│   │   ├── Apply result directly with enhanced clipboard sync
│   │   ├── Reset autoReturnEnabled to false after use
│   │   └── Handle cancellation if recording gets interrupted
│   ├── 2. Scheduled Action (same priority as auto-return - overrides everything)
│   │   ├── Check if scheduledActionName is set
│   │   ├── Find and execute the scheduled action across all action types
│   │   ├── Reset scheduledActionName to nil after use
│   │   └── Handle cancellation if recording gets interrupted
│   ├── 3. Trigger Actions (medium priority - all action types)
│   │   ├── Evaluate triggers across ALL action types (TriggerEvaluator)
│   │   ├── Check voice triggers (with exceptions and result stripping)
│   │   ├── Check application triggers (bundle ID and name)
│   │   ├── Check mode triggers (Superwhisper modes)
│   │   ├── Apply trigger logic (AND/OR) for each action
│   │   ├── Return first matched action (sorted alphabetically by name)
│   │   └── Execute via unified ActionExecutor
│   └── 4. Active Action (lowest priority - fallback only)
│       ├── Check config.defaults.activeAction (supports all action types)
│       ├── Find action by name across all action types
│       └── Execute via unified ActionExecutor if found
├── Execute matched action (Unified ActionExecutor)
│   ├── Determine action type (insert/URL/shortcut/shell/AppleScript)
│   ├── Apply action-specific settings (actionDelay, noEsc, icon, moveTo, etc.)
│   ├── Process placeholders with context (Placeholders.swift)
│   ├── Execute with enhanced clipboard sync (ClipboardMonitor)
│   │   ├── Apply actionDelay after clipboard sync
│   │   ├── Handle ESC simulation with accessibility checks
│   │   ├── Coordinate timing with Superwhisper clipboard changes
│   │   └── Restore intelligent clipboard content
│   └── Handle action-type-specific execution with universal features
├── AutoReturn/Scheduled Action Cancellation Logic:
│   ├── Cancel if recording folder is deleted during processing
│   ├── Cancel if newer recordings appear before current completes
│   ├── Cancel if meta.json is deleted during processing
│   ├── Cancel if CLI commands are executed (exec-action, exec-insert)
│   └── Preserve autoReturn/scheduled action for intended recording session
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

## Configuration Schema (Unified Action System)

The application uses a comprehensive JSON configuration file with unified action management:

```json
{
  "defaults": {
    "watch": "~/Documents/superwhisper",
    "noUpdates": false,
    "noNoti": false,
    "activeAction": "",
    "icon": "",
    "moveTo": "",
    "noEsc": false,
    "simKeypress": false,
    "actionDelay": 0.0,
    "history": null,
    "pressReturn": false,
    "returnDelay": 0.1,
    "restoreClipboard": true,
    "scheduledActionTimeout": 5
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
      "pressReturn": false,
      "restoreClipboard": null
    }
  },
  "urls": {
    "urlName": {
      "action": "https://example.com/search?q={{swResult}}",
      "openWith": "/Applications/Safari.app",
      "triggerVoice": "^search|!private",
      "triggerApps": "com.apple.finder",
      "triggerModes": "search",
      "triggerLogic": "and",
      "icon": "🔍",
      "moveTo": "com.apple.Safari",
      "actionDelay": 0.5,
      "restoreClipboard": false
    }
  },
  "shortcuts": {
    "shortcutName": {
      "action": "MyShortcut",
      "triggerVoice": "^run shortcut",
      "triggerApps": "com.apple.Notes",
      "icon": "⚡",
      "actionDelay": 1.0,
      "restoreClipboard": null
    }
  },
  "scriptsShell": {
    "shellName": {
      "action": "echo '{{swResult}}' | pbcopy",
      "triggerVoice": "^copy result",
      "icon": "📋",
      "actionDelay": 0.0,
      "restoreClipboard": true
    }
  },
  "scriptsAS": {
    "applescriptName": {
      "action": "tell application \"TextEdit\" to make new document with properties {text:\"{{swResult}}\"}",
      "triggerVoice": "^new document",
      "icon": "📝",
      "moveTo": "com.apple.TextEdit",
      "restoreClipboard": null
    }
  }
}
```

**Key Features**:
- **Unified Action Management**: All action types share the same property structure
- **Universal Triggers**: Every action type supports voice, app, and mode triggers
- **Consistent Icons**: All actions support custom icons with fallback hierarchy
- **Smart Defaults**: Missing properties inherit from global defaults
- **Auto-Migration**: Seamless upgrade from `activeInsert` to `activeAction`

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

## Recent Reliability and Performance Improvements

### Thread Safety and Concurrency (NEW)
- **GlobalStateManager**: Thread-safe state management for all shared variables
- **Atomic Operations**: Race condition prevention in timer and state management
- **Concurrent Queue Design**: Proper synchronization using dispatch barriers
- **Memory Leak Prevention**: Weak references and automatic resource cleanup
- **Enhanced Timer Management**: Automatic invalidation and thread-safe updates

### Network Reliability (NEW)
- **Socket Timeout Protection**: 10-second timeouts on all socket operations
- **Non-blocking I/O**: Uses select() to prevent indefinite blocking
- **Graceful Timeout Handling**: Proper error recovery from network timeouts
- **Client-Server Reliability**: Enhanced error handling in both directions

### Memory Management (NEW)
- **Bounded Data Structures**: Prevents unbounded growth in clipboard monitoring
- **Periodic Cleanup**: Automatic cleanup of old data every 30 seconds
- **Session Lifecycle Management**: Proper cleanup of inactive monitoring sessions
- **Resource Tracking**: Performance monitoring of memory usage

### Configuration Robustness (NEW)
- **Enhanced JSON Error Handling**: Detailed error messages with exact locations
- **Automatic Backup and Recovery**: Timestamped backups of corrupted configurations
- **Atomic Write Operations**: Prevents configuration corruption during saves
- **Validation Before Commit**: Verifies JSON validity before file replacement
- **Empty File Handling**: Graceful recovery from empty configuration files

---

## Error Handling and Recovery

### Comprehensive Error Recovery (Enhanced)
- **Configuration errors**: Advanced JSON validation with detailed error reporting and automatic recovery
- **Socket failures**: Timeout-protected socket recovery with health monitoring
- **File system errors**: Enhanced error handling with specific guidance for permission issues
- **Missing folders**: SuperwhisperFolderWatcher provides graceful waiting instead of app failure
- **Service failures**: Automatic restart and recovery procedures with better error detection
- **Accessibility errors**: Clear user guidance and fallback behavior
- **Memory exhaustion**: Bounded data structures prevent memory leaks and excessive growth
- **Network timeouts**: Graceful handling of socket timeouts with proper cleanup

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