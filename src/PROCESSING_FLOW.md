# Macrowhisper Processing Flow Documentation

## Overview

This document provides a comprehensive technical analysis of Macrowhisper's complete processing flow, from the moment a recording folder is detected to the final action execution and clipboard synchronization. This is essential developer documentation to understand the complex timing, conditions, and variables involved in the automation system.

## Table of Contents

1. [High-Level Processing Flow](#high-level-processing-flow)
2. [Recording Folder Detection](#recording-folder-detection)
3. [Early Clipboard Monitoring System](#early-clipboard-monitoring-system)
4. [Meta.json Processing](#metajson-processing)
5. [Action Priority System](#action-priority-system)
6. [ActionDelay System](#actiondelay-system)
7. [Clipboard Synchronization](#clipboard-synchronization)
8. [Trigger Evaluation](#trigger-evaluation)
9. [Action Execution](#action-execution)
10. [Post-Processing](#post-processing)
11. [Key Variables and Settings](#key-variables-and-settings)
12. [Error Handling and Edge Cases](#error-handling-and-edge-cases)
13. [Files and Classes Involved](#files-and-classes-involved)

---

## High-Level Processing Flow

```
0. App Startup
   └── Initialize Global Clipboard Monitoring (5-second rolling buffer)
   ↓
1. Recording Folder Detection (RecordingsFolderWatcher)
   ↓
2. Pre-Recording Data Capture
   ├── Capture clipboard from global history (5s before recording)
   ├── Capture selectedText
   └── Capture original clipboard
   ↓
3. Smart Session Monitoring Decision
   ├── If meta.json complete → Skip session monitoring
   ├── If meta.json incomplete → Start session monitoring
   └── If meta.json missing → Start session monitoring
   ↓
4. Meta.json Processing (RecordingsFolderWatcher)
   ↓
5. Context Gathering & Session Data Enhancement
   ├── Front App context
   ├── Add selectedText to metaJson
   ├── Add clipboardContent to metaJson (session priority, pre-recording fallback)
   └── Add appContext (if placeholder used)
   ↓
6. Action Priority Evaluation
   ├── Auto-Return (Highest Priority)
   ├── Trigger Actions (Medium Priority)
   └── Active Action (Lowest Priority)
   ↓
7. Action Execution with Enhanced Placeholder Processing
   ├── Process placeholders with session data
   ├── ActionDelay Application
   ├── ESC Key Simulation
   ├── Clipboard Monitoring/Restoration
   └── Action Execution
   ↓
8. Post-Processing (MoveTo, History Cleanup)
   ↓
9. Continue Global Clipboard Monitoring (for future recordings)
```

---

## Recording Folder Detection

### Primary File: `macrowhisper/Watcher/RecordingsFolderWatcher.swift`

The process begins when Superwhisper creates a new recording folder in the watched directory.

#### Key Components:
- **File System Watcher**: Uses `DispatchSourceFileSystemObject` to monitor `~/Documents/superwhisper/recordings`
- **Duplicate Prevention**: Maintains `processedRecordings: Set<String>` to prevent reprocessing
- **Startup Behavior**: Marks most recent recording as processed on startup to avoid reprocessing old recordings

#### Detection Flow:
1. **Folder Change Event**: `handleFolderChangeEvent()` detects new subdirectories
2. **Duplicate Check**: `isAlreadyProcessed(recordingPath:)` prevents reprocessing
3. **Smart Monitoring Decision**: Check if meta.json is complete before starting clipboard monitoring
   - If complete → Process immediately without monitoring
   - If incomplete/missing → Start clipboard monitoring
4. **Meta.json Handling**: Either processes existing meta.json or starts watching for its creation

#### Critical Variables:
- `lastKnownSubdirectories: Set<String>` - Tracks known recording folders
- `pendingMetaJsonFiles: [String: DispatchSourceFileSystemObject]` - Active meta.json watchers
- `processedRecordings: Set<String>` - Persistent tracking of processed recordings
- `processedRecordingsFile: String` - File path for persistence

---

## Enhanced Clipboard Monitoring System

### Primary File: `macrowhisper/Utils/ClipboardMonitor.swift`

This is the **most critical component** for handling clipboard synchronization between Superwhisper and Macrowhisper, now enhanced with pre-recording capture.

#### The Problem:
Superwhisper and Macrowhisper both modify the clipboard simultaneously, causing:
- Lost user clipboard content
- Race conditions between clipboard modifications
- Incorrect content being pasted
- Users often copy content shortly before recording and want to access it in actions

#### The Solution - Dual Monitoring Architecture:

##### 1. Lightweight Global Monitoring (App Lifetime):
- **Purpose**: Maintains 5-second rolling buffer for pre-recording capture
- **Frequency**: 0.5-second intervals (lightweight)
- **Scope**: Single shared instance across all components
- **Privacy**: Content not logged, only change events

##### 2. Smart Session Monitoring (Recording Specific):
```swift
// Started conditionally based on meta.json state
func startEarlyMonitoring(for recordingPath: String) {
    let pasteboard = NSPasteboard.general
    let userOriginal = pasteboard.string(forType: .string)
    
    // Capture selected text immediately when monitoring starts
    let selectedText = getSelectedText()
    
    let session = EarlyMonitoringSession(
        userOriginalClipboard: userOriginal,
        startTime: Date(),
        selectedText: selectedText
    )
    // ... session management
}
```

#### Enhanced Session Structure:
```swift
private struct EarlyMonitoringSession {
    let userOriginalClipboard: String?     // User's clipboard when folder appeared
    let selectedText: String?              // Selected text captured at session start
    let startTime: Date                    // Session start time
    var clipboardChanges: [ClipboardChange] = []  // All clipboard changes during session
    var isActive: Bool = true              // Session active state
    var isExecutingAction: Bool = false    // Controls clipboard change logging visibility
    let preRecordingClipboard: String?     // Clipboard content from global history (5s before recording)
}

private struct ClipboardChange {
    let content: String?    // Clipboard content
    let timestamp: Date     // When change occurred
}
```

#### Key Features:
- **Thread-Safe**: Uses `sessionsQueue` with concurrent reads and barrier writes
- **Smart Logging**: Only logs clipboard changes during actual action execution periods (content not logged for privacy)
- **Single Instance**: Shared ClipboardMonitor prevents duplicate monitoring
- **Continuous Monitoring**: Always tracks changes for restoration, but controls log visibility
- **Pre-Recording Capture**: 5-second rolling buffer for {{clipboardContent}} placeholder
- **Change Tracking**: Monitors all clipboard changes during the session
- **Smart Restoration**: Determines correct clipboard content to restore based on session history
- **Action Execution Boundaries**: Clear start/finish markers for relevant logging periods
- **Timing Constants**:
  - `maxWaitTime: 0.1` seconds - Maximum time to wait for Superwhisper
  - `pollInterval: 0.01` seconds - 10ms polling interval for session monitoring
  - `globalMonitoringInterval: 0.5` seconds - Global monitoring frequency
  - `preRecordingBuffer: 5.0` seconds - Pre-recording clipboard capture window

#### Action Execution Control Methods:
```swift
func startActionExecution(for recordingPath: String)   // Enables clipboard change logging
func finishActionExecution(for recordingPath: String)  // Disables clipboard change logging
func stopEarlyMonitoring(for recordingPath: String)    // Natural session cleanup
```

**Smart Logging Logic**:
```swift
// Always track clipboard changes for restoration logic
self.earlyMonitoringSessions[recordingPath]?.clipboardChanges.append(change)

// Only log if we're currently executing an action
if session.isExecutingAction {
    logDebug("[ClipboardMonitor] Detected clipboard change during action execution")
}
```

This approach eliminates the complex cancellation token system and race conditions while providing clean, relevant logging output.

---

## Meta.json Processing

### Primary File: `macrowhisper/Watcher/RecordingsFolderWatcher.swift`

Meta.json contains the transcription results from Superwhisper and may not exist immediately when the recording folder appears.

#### Processing States:
1. **Immediate Processing**: If meta.json exists when folder is detected
2. **Delayed Processing**: Watch for meta.json creation with `watchForMetaJsonCreation()`
3. **Update Processing**: Watch for meta.json changes with `watchMetaJsonForChanges()`

#### Validation Requirements:
```swift
// Must have valid result
guard let result = metaJson["result"], 
      !(result is NSNull), 
      (result as? String)?.isEmpty == false else {
    // Continue watching for updates
    return
}
```

#### Context Enhancement:
```swift
// Always update front app context
var frontApp: NSRunningApplication?
if Thread.isMainThread {
    frontApp = NSWorkspace.shared.frontmostApplication
} else {
    DispatchQueue.main.sync {
        frontApp = NSWorkspace.shared.frontmostApplication
    }
}

// Create enhanced metaJson with context
var enhancedMetaJson = metaJson
enhancedMetaJson["frontAppName"] = frontApp?.localizedName
enhancedMetaJson["frontApp"] = frontApp?.localizedName
enhancedMetaJson["frontAppBundleId"] = frontApp?.bundleIdentifier
```

#### Key Variables:
- `result` or `llmResult` - The transcribed text (llmResult takes precedence)
- `modeName` - Superwhisper mode (e.g., "email", "writing")
- `frontAppName` - Current foreground application name
- `frontAppBundleId` - Current foreground application bundle ID

---

## Action Priority System

Actions are evaluated in strict priority order. **Higher priority actions completely override lower priority actions.**

### Priority Order (Highest to Lowest):

#### 1. Auto-Return (Highest Priority)
- **Condition**: `autoReturnEnabled == true`
- **Purpose**: Immediately return the transcribed result without any processing
- **Behavior**: Uses the raw result (`result` or `llmResult`) directly
- **Reset**: `autoReturnEnabled` is set to `false` after use (single-use)

#### 2. Trigger Actions (Medium Priority)
- **Evaluation**: `TriggerEvaluator.evaluateTriggersForAllActions()`
- **Types**: Insert, URL, Shortcut, Shell Script, AppleScript actions with triggers
- **Selection**: First matched action (sorted alphabetically by name)
- **Override**: Completely overrides active insert if any triggers match

#### 3. Active Insert (Lowest Priority)
- **Condition**: `config.defaults.activeInsert` is set and not empty
- **Fallback**: Only executed if no auto-return and no trigger actions match
- **Special Cases**: 
  - `.none` or empty action: Apply delay but skip execution
  - `.autoPaste`: Smart paste based on input field detection

---

## ActionDelay System

### Configuration Hierarchy:
ActionDelay can be configured at multiple levels with specific precedence:

1. **Action-Specific**: `insert.actionDelay`, `url.actionDelay`, etc.
2. **Global Default**: `config.defaults.actionDelay`
3. **Fallback**: `0.0` seconds if not configured

### Application Points:
ActionDelay is applied **after** clipboard synchronization but **before** ESC simulation and action execution:

```swift
// Step 1: Handle clipboard synchronization with Superwhisper (up to maxWaitTime)
// ... clipboard sync logic ...

// Step 2: Apply actionDelay after clipboard sync is complete
if actionDelay > 0 {
    Thread.sleep(forTimeInterval: actionDelay)
    logDebug("Applied actionDelay: \(actionDelay)s after clipboard sync")
}

// Step 3: Simulate ESC (if enabled)
if shouldEsc {
    simulateKeyDown(key: 53) // ESC key
}

// Step 4: Execute action
insertAction()
```

### Corrected Timing Behavior:
- **Clipboard Sync First**: Always wait up to `maxWaitTime (0.1s)` for Superwhisper, regardless of actionDelay
- **ActionDelay Second**: Applied after clipboard synchronization is complete
- **Independent Timing**: ActionDelay value does not affect clipboard synchronization logic

### Files Involved:
- **Configuration**: `macrowhisper/Config/AppConfiguration.swift` (all action types have `actionDelay: Double?`)
- **Application**: `macrowhisper/Utils/ClipboardMonitor.swift` (handles timing coordination)
- **Fallback**: `macrowhisper/Networking/SocketCommunication.swift` (CLI commands)

---

## Clipboard Synchronization

### Primary File: `macrowhisper/Utils/ClipboardMonitor.swift`

The clipboard synchronization system handles the complex timing between Superwhisper and Macrowhisper clipboard modifications.

#### Synchronization Methods:

##### 1. Enhanced Clipboard Sync (Preferred):
Used for actions triggered by the watcher (with early monitoring data):
```swift
func executeInsertWithEnhancedClipboardSync(
    insertAction: @escaping () -> Void,
    actionDelay: TimeInterval,
    shouldEsc: Bool,
    isAutoPaste: Bool = false,
    recordingPath: String,
    metaJson: [String: Any],
    restoreClipboard: Bool = true
)
```

##### 2. Basic Clipboard Sync (Fallback):
Used when early monitoring data is not available:
```swift
func executeInsertWithClipboardSync(
    insertAction: @escaping () -> Void,
    actionDelay: TimeInterval,
    shouldEsc: Bool,
    isAutoPaste: Bool = false,
    restoreClipboard: Bool = true,
    recordingPath: String
)
```

##### 3. Non-Insert Action Sync:
Used for URL, Shortcut, Shell, and AppleScript actions:
```swift
func executeNonInsertActionWithClipboardRestore(
    action: @escaping () -> Void,
    shouldEsc: Bool,
    actionDelay: TimeInterval,
    recordingPath: String,
    metaJson: [String: Any],
    restoreClipboard: Bool = true
)
```

#### Corrected Timing Flow:
The clipboard synchronization system now follows the proper sequence:

```
1. Extract swResult from metaJson
2. Check if Superwhisper already placed swResult on clipboard
3. If not, wait up to maxWaitTime (0.1s) for Superwhisper to do so
4. Determine correct clipboard content to restore
5. Apply actionDelay (user's setting)
6. Simulate ESC key if enabled
7. Execute insert action
8. Restore clipboard content
```

**Key Fix**: Clipboard synchronization now happens **before** actionDelay is applied, ensuring:
- `maxWaitTime` is always respected (0.1 seconds)
- ActionDelay doesn't interfere with Superwhisper synchronization
- Proper clipboard restoration regardless of actionDelay value

#### Restoration Logic:
The system intelligently determines what clipboard content to restore:

1. **Superwhisper was faster**: Restore content that was on clipboard just before `swResult`
2. **Macrowhisper was faster**: Restore current clipboard content
3. **User made changes**: Preserve user's intentional clipboard changes
4. **No changes**: Restore original user clipboard

#### Restoration Conditions:
Clipboard restoration only occurs when **ALL** conditions are met:
- ESC simulation is enabled (`shouldEsc == true`)
- Clipboard restoration is enabled (`restoreClipboard == true`)
- Action is not `.none` or empty

---

## Trigger Evaluation

### Primary File: `macrowhisper/Utils/TriggerEvaluator.swift`

The trigger system evaluates all configured actions to find matches based on voice, application, and mode criteria.

#### Trigger Types:

##### 1. Voice Triggers (`triggerVoice`):
- **Pattern**: Regex patterns that match the beginning of transcribed text
- **Exceptions**: Patterns prefixed with `!` exclude matches
- **Multiple Patterns**: Separated by `|` (pipe character)
- **Result Stripping**: Matched trigger phrase is removed from the result
- **Case Insensitive**: All voice triggers are case-insensitive

Example:
```json
{
  "triggerVoice": "send email|compose message|!delete email"
}
```

##### 2. Application Triggers (`triggerApps`):
- **Bundle ID**: Matches application bundle identifier (e.g., `com.apple.mail`)
- **App Name**: Matches application display name (case-insensitive)
- **Multiple Patterns**: Separated by `|`

##### 3. Mode Triggers (`triggerModes`):
- **Mode Name**: Matches Superwhisper mode name
- **Custom Modes**: User-defined modes in Superwhisper
- **Multiple Patterns**: Separated by `|`

#### Trigger Logic (`triggerLogic`):
- **"and"**: ALL configured triggers must match
- **"or"**: ANY configured trigger can match
- **Default**: "or" if not specified

#### Evaluation Process:
1. **Collect All Actions**: Inserts, URLs, Shortcuts, Shell Scripts, AppleScripts
2. **Evaluate Each Action**: Check voice, app, and mode triggers
3. **Apply Logic**: Use AND/OR logic to determine matches
4. **Sort Results**: Alphabetically by action name
5. **Return First Match**: Execute first matching action only

---

## Action Execution

### Primary File: `macrowhisper/Utils/ActionExecutor.swift`

Action execution is coordinated through the ActionExecutor which handles all action types uniformly.

#### Action Types:

##### 1. Insert Actions:
- **Processing**: Placeholder replacement, autoPaste detection
- **Execution**: Text insertion via clipboard or keystroke simulation
- **Special Cases**: `.none` (delay only), `.autoPaste` (smart paste)

##### 2. URL Actions:
- **Processing**: URL encoding, placeholder replacement
- **Execution**: Open URL with default or specified application
- **Custom App**: `openWith` parameter for specific application

##### 3. Shortcut Actions:
- **Processing**: Placeholder replacement
- **Execution**: macOS Shortcuts via `/usr/bin/shortcuts` with stdin input
- **Asynchronous**: Non-blocking execution

##### 4. Shell Script Actions:
- **Processing**: Shell escaping, placeholder replacement
- **Execution**: Bash execution via `/bin/bash -c`
- **Isolation**: Separate process with no output capture

##### 5. AppleScript Actions:
- **Processing**: AppleScript escaping, placeholder replacement
- **Execution**: osascript execution via `/usr/bin/osascript`
- **Asynchronous**: Non-blocking execution

#### Execution Flow:
```swift
func executeAction(
    action: Any,
    name: String,
    type: ActionType,
    metaJson: [String: Any],
    recordingPath: String
) {
    // 1. Determine action-specific settings
    let actionDelay = action.actionDelay ?? configManager.config.defaults.actionDelay
    let shouldEsc = !(action.noEsc ?? configManager.config.defaults.noEsc)
    
    // 2. Execute with appropriate clipboard handling
    clipboardMonitor.executeWithClipboardSync(...)
    
    // 3. Handle moveTo setting
    handleMoveToSetting(...)
}
```

---

## Post-Processing

### Primary File: `macrowhisper/Watcher/RecordingsFolderWatcher.swift`

After action execution, several post-processing steps occur:

#### 1. MoveTo Handling:
Determines where to move or how to handle the processed recording folder:

**Priority Order**:
1. **Action-Specific**: `insert.moveTo`, `url.moveTo`, etc.
2. **Global Default**: `config.defaults.moveTo`

**Special Values**:
- `".delete"`: Delete the recording folder
- `".none"`: Keep folder in original location
- **Path**: Move folder to specified directory

#### 2. History Cleanup:
- **Trigger**: `historyManager.performHistoryCleanup()`
- **Policy**: Based on `config.defaults.history` setting
- **Frequency**: After each processed recording

#### 3. Version Checking:
- **Delay**: 30-second delay to avoid interrupting workflow
- **Condition**: Only if version checking is enabled
- **Background**: Executed on utility queue

---

## Key Variables and Settings

### Configuration Variables (`macrowhisper/Config/AppConfiguration.swift`):

#### Global Defaults:
- `actionDelay: Double` - Default delay before action execution (default: 0.0)
- `noEsc: Bool` - Disable ESC key simulation (default: false)
- `restoreClipboard: Bool` - Enable clipboard restoration (default: true)
- `activeInsert: String?` - Currently active insert name
- `moveTo: String?` - Default folder movement behavior
- `pressReturn: Bool` - Auto-press return after actions (default: false)
- `returnDelay: Double` - Delay before pressing return (default: 0.1)

#### Action-Specific Settings:
All action types support:
- `actionDelay: Double?` - Action-specific delay override
- `noEsc: Bool?` - Action-specific ESC override
- `moveTo: String?` - Action-specific moveTo override
- `triggerVoice: String?` - Voice trigger patterns
- `triggerApps: String?` - Application trigger patterns
- `triggerModes: String?` - Mode trigger patterns
- `triggerLogic: String?` - Trigger combination logic ("and"/"or")

### Runtime Variables:

#### Global State (`main.swift`):
- `autoReturnEnabled: Bool` - Auto-return mode state
- `lastDetectedFrontApp: NSRunningApplication?` - Current foreground app
- `recordingsWatcher: RecordingsFolderWatcher?` - Main file watcher
- `configManager: ConfigurationManager` - Configuration manager
- `socketCommunication: SocketCommunication` - IPC server

#### ClipboardMonitor State:
- `earlyMonitoringSessions: [String: EarlyMonitoringSession]` - Active monitoring sessions
- `maxWaitTime: 0.1` seconds - Maximum Superwhisper wait time
- `pollInterval: 0.01` seconds - Clipboard polling interval

---

## Error Handling and Edge Cases

### Clipboard Synchronization Edge Cases:

#### 1. Missing Early Monitoring:
- **Condition**: No early monitoring session found
- **Behavior**: Fall back to basic clipboard monitoring
- **Impact**: Less intelligent clipboard restoration

#### 2. Clipboard Restoration Disabled:
- **Condition**: `restoreClipboard == false` or `shouldEsc == false`
- **Behavior**: Execute action directly without clipboard handling
- **Performance**: Faster execution, no synchronization overhead

### Meta.json Edge Cases:

#### 1. Missing Meta.json:
- **Behavior**: Watch for file creation with timeout
- **Cleanup**: Remove watchers when recording folder is deleted

#### 2. Invalid Meta.json:
- **Behavior**: Continue watching for valid updates
- **Logging**: Error logged but processing continues

#### 3. Empty Results:
- **Behavior**: Continue watching for non-empty results
- **Validation**: Check for null, empty string, or missing result

### Trigger Evaluation Edge Cases:

#### 1. No Matching Triggers:
- **Behavior**: Fall back to active insert processing
- **Logging**: Log that no triggers matched

#### 2. Multiple Matching Triggers:
- **Behavior**: Execute first match (alphabetically sorted)
- **Deterministic**: Consistent behavior across runs

#### 3. Exception-Only Triggers:
- **Pattern**: Only `!pattern` triggers defined
- **Behavior**: Match if no exception patterns match
- **Use Case**: Exclude specific phrases while allowing everything else

---

## Files and Classes Involved

### Core Processing Files:

#### 1. `macrowhisper/main.swift` (1101 lines)
- **Purpose**: Application entry point, global state management
- **Key Variables**: `autoReturnEnabled`, `lastDetectedFrontApp`, global instances
- **Responsibilities**: Initialization, CLI handling, main event loop

#### 2. `macrowhisper/Watcher/RecordingsFolderWatcher.swift` (532 lines)
- **Purpose**: File system monitoring, meta.json processing, action orchestration
- **Key Methods**: `processNewRecording()`, `processMetaJson()`, `handlePostProcessing()`
- **State Management**: Processed recordings tracking, pending watchers

#### 3. `macrowhisper/Utils/ClipboardMonitor.swift` (1024 lines)
- **Purpose**: Clipboard synchronization, timing coordination, smart logging, pre-recording capture
- **Key Methods**: `startEarlyMonitoring()`, `executeInsertWithEnhancedClipboardSync()`, `startActionExecution()`, `finishActionExecution()`
- **Critical Features**: Dual monitoring architecture, single shared instance, smart restoration logic, action execution boundaries
- **Architecture**: Single instance shared between RecordingsFolderWatcher and ActionExecutor to prevent duplicate monitoring

#### 4. `macrowhisper/Utils/ActionExecutor.swift` (347 lines)
- **Purpose**: Unified action execution, moveTo handling
- **Key Methods**: `executeAction()`, action-specific execution methods
- **Integration**: ClipboardMonitor coordination, placeholder processing

#### 5. `macrowhisper/Utils/TriggerEvaluator.swift` (386 lines)
- **Purpose**: Trigger evaluation, action matching
- **Key Methods**: `evaluateTriggersForAllActions()`, `triggersMatch()`
- **Logic**: Multi-criteria evaluation, exception handling

### Configuration Files:

#### 6. `macrowhisper/Config/AppConfiguration.swift` (474 lines)
- **Purpose**: Configuration data structures, defaults
- **Action Types**: Insert, Url, Shortcut, ScriptShell, ScriptAppleScript
- **Settings**: actionDelay, noEsc, restoreClipboard, trigger configurations

#### 7. `macrowhisper/Config/ConfigurationManager.swift` (348 lines)
- **Purpose**: Configuration loading, saving, live reloading
- **Thread Safety**: Dedicated configuration queue
- **Persistence**: UserDefaults integration for path management

### Utility Files:

#### 8. `macrowhisper/Networking/SocketCommunication.swift` (794 lines)
- **Purpose**: CLI command handling, action execution for CLI
- **Key Methods**: `applyInsert()`, `applyInsertWithoutEsc()`, `processInsertAction()`
- **Integration**: Configuration updates, placeholder processing

#### 9. `macrowhisper/Utils/Placeholders.swift` (427 lines)
- **Purpose**: Dynamic content replacement
- **Placeholder Types**: XML, meta.json fields, date formatting
- **Action-Aware**: Different escaping for different action types

#### 10. `macrowhisper/Utils/Accessibility.swift` (254 lines)
- **Purpose**: macOS accessibility integration
- **Key Features**: Input field detection, keyboard simulation
- **ESC Logic**: Smart ESC handling based on application state

### Supporting Files:

#### 11. `macrowhisper/History/HistoryManager.swift` (115 lines)
- **Purpose**: Recording cleanup based on retention policies
- **Cleanup Logic**: Age-based deletion with safety checks

#### 12. `macrowhisper/Utils/Logger.swift` (110 lines)
- **Purpose**: Comprehensive logging with file rotation
- **Global Functions**: `logDebug()`, `logInfo()`, `logWarning()`, `logError()`

---

## Development Guidelines

### When Making Changes:

1. **Clipboard Logic**: Be extremely careful with clipboard synchronization timing
2. **Action Priority**: Understand the strict priority system (auto-return > triggers > active insert)
3. **ActionDelay**: Test with various delay values, especially around the 0.1s threshold
4. **Thread Safety**: ClipboardMonitor uses concurrent queues with barrier writes
5. **Error Handling**: Always handle missing files, invalid JSON, and permission errors
6. **Logging**: Use appropriate log levels for debugging complex timing issues

### Testing Scenarios:

1. **Timing Variations**: Test with actionDelay values of 0, 0.05, 0.1, 0.2, 1.0 seconds
2. **Clipboard Conflicts**: Test with user copying content during processing
3. **Application Switching**: Test trigger evaluation with different foreground apps
4. **Long Processing**: Test with slow meta.json creation or large files
5. **Permission Errors**: Test without accessibility permissions
6. **Configuration Changes**: Test live configuration reloading during processing

### Critical Timing Constants:

- **maxWaitTime**: 0.1 seconds (ClipboardMonitor)
- **pollInterval**: 0.01 seconds (ClipboardMonitor)
- **restoreDelay**: 0.1 seconds (post-action clipboard restoration)
- **returnDelay**: 0.1 seconds (default return key delay)

These constants are carefully tuned for optimal user experience and should not be changed without extensive testing.

---

This documentation should be updated whenever significant changes are made to the processing flow, timing logic, or clipboard synchronization system. 