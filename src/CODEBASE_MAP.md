# Macrowhisper CLI - Codebase Map

## Overview

**Macrowhisper** is an automation helper for **Superwhisper** dictation app. It monitors transcription results and executes automated actions based on intelligent triggers.

### Core Functionality
- **File Watching**: Monitors Superwhisper's recordings folder for new transcriptions
- **Unified Action System**: Insert, URL, shortcut, shell script, AppleScript actions with consistent management
- **Advanced Trigger System**: Voice patterns, application context, and mode matching
- **Smart Clipboard Management**: Handles timing conflicts with Superwhisper
- **Service Management**: Background operation via launchd
- **JSON Schema Integration**: IDE validation support with automatic schema management

---

## Project Structure

```
src/
├── macrowhisper/
    ├── main.swift                   # Application entry point and CLI handling
    ├── Config/                      # Configuration management
    │   ├── AppConfiguration.swift   # Configuration data structures with unified actions
    │   └── ConfigurationManager.swift # Live reloading, JSON schema integration
    ├── Watcher/                     # File system monitoring
    │   ├── RecordingsFolderWatcher.swift # Main recordings watcher
    │   └── SuperwhisperFolderWatcher.swift # Graceful startup when folder missing
    ├── Utils/                       # Core utilities
    │   ├── ActionExecutor.swift     # Unified action execution
    │   ├── TriggerEvaluator.swift   # Intelligent trigger matching
    │   ├── ClipboardMonitor.swift   # Clipboard synchronization with Superwhisper
    │   ├── Placeholders.swift       # Dynamic content replacement
    │   ├── SchemaManager.swift      # JSON schema management
    │   └── ServiceManager.swift     # macOS service integration
    └── Networking/
        └── SocketCommunication.swift # CLI command handling
```

---

## Core Components

### 1. Main Application (`main.swift`)
- **Entry point**: CLI parsing, daemon mode, single-instance locking
- **Global state**: Thread-safe state management with atomic operations
- **Key variables**: `autoReturnEnabled`, `scheduledActionName`, `activeAction`
- **CLI commands**: Service management, action management, configuration
- **JSON Schema**: Automatic schema reference management for IDE validation

---

### 2. Configuration System

#### `AppConfiguration.swift`
- **Unified action types**: Insert, URL, Shortcut, Shell, AppleScript
- **Common properties**: All actions support triggers, delays, icons, moveTo
- **JSON Schema**: `schema` field for IDE validation (maps to `$schema`)
- **Auto-migration**: Seamless upgrade from old config formats

#### `ConfigurationManager.swift` 
- **Live reloading**: Watches config file for changes
- **JSON Schema integration**: Automatic schema reference management
- **Error recovery**: Backup/restore corrupted configs
- **Thread-safe**: Dedicated queue for config operations

---

### 3. File System Monitoring

#### `RecordingsFolderWatcher.swift`
- **Smart monitoring**: Only starts clipboard monitoring when needed
- **Persistent tracking**: Prevents duplicate processing
- **Priority system**: AutoReturn > Triggers > ActiveAction
- **Intelligent cancellation**: Handles interrupted recordings

#### `SuperwhisperFolderWatcher.swift`
- **Graceful startup**: Waits for Superwhisper folder creation
- **One-time operation**: Auto-handoff to RecordingsFolderWatcher

---

### 4. Action System

#### `TriggerEvaluator.swift`
- **Multi-criteria**: Voice, app, and mode triggers
- **Exceptions**: `!` prefix for negative patterns
- **Raw regex**: `==pattern==` for full regex control
- **Logic**: AND/OR combinations

#### `ActionExecutor.swift`
- **Unified execution**: All action types through single interface
- **Smart clipboard sync**: Coordinates with Superwhisper timing
- **Placeholder processing**: Dynamic content replacement

### 5. Clipboard Management

#### `ClipboardMonitor.swift`
- **Dual architecture**: Lightweight global + intensive session monitoring
- **Smart timing**: Only monitors when meta.json incomplete
- **Pre-recording capture**: Configurable buffer (default 5s)
- **Thread-safe**: Concurrent monitoring with barriers
- **Action boundaries**: Logs only during action execution

### 6. Inter-Process Communication

#### `SocketCommunication.swift`
- **Unix socket server**: CLI command handling
- **Timeout protection**: 10-second timeouts on operations
- **Unified commands**: Action management across all types
- **Thread-safe**: Proper queue management

---

### 7. Supporting Utilities

#### `Placeholders.swift`
- **Dynamic content**: `{{swResult}}`, `{{selectedText}}`, `{{clipboardContext}}`, etc.
- **Escaping modes**: `raw:`, `json:`, action-type aware
- **Regex replacements**: `{{placeholder||pattern||replacement}}`

#### `SchemaManager.swift` (NEW)
- **Schema discovery**: Finds JSON schema file alongside binary
- **Auto-management**: Adds/updates `$schema` reference in configs
- **IDE integration**: Enables IntelliSense and validation

#### Other Utilities
- **ServiceManager**: macOS launchd integration
- **Logger**: File rotation, TTY detection  
- **Accessibility**: Input field detection, keyboard simulation
- **HistoryManager**: Recording cleanup policies

---

## Action Priority System

**Strict Priority Order:**
1. **AutoReturn** (highest) - Direct result passthrough
2. **Triggers** - Voice/app/mode pattern matching  
3. **ActiveAction** (lowest) - Fallback default action

## Configuration Schema (Key Fields)

```json
{
  "$schema": "file://path/to/macrowhisper-schema.json",
  "defaults": {
    "watch": "~/Documents/superwhisper",
    "activeAction": "actionName",
    "actionDelay": 0.0,
    "clipboardBuffer": 5.0
  },
  "inserts": { "name": { "action": "text", "triggerVoice": "pattern" }},
  "urls": { "name": { "action": "https://...", "openWith": "app" }},
  "shortcuts": { "name": { "action": "shortcutName" }},
  "scriptsShell": { "name": { "action": "command" }},
  "scriptsAS": { "name": { "action": "tell app..." }}
}
```

## Key Files for AI Development

- **Core Logic**: `RecordingsFolderWatcher.swift` - Main processing flow
- **Actions**: `ActionExecutor.swift`, `TriggerEvaluator.swift` - Execution system
- **Clipboard**: `ClipboardMonitor.swift` - Timing synchronization  
- **Config**: `AppConfiguration.swift`, `ConfigurationManager.swift` - Settings
- **Schema**: `SchemaManager.swift` - JSON schema integration