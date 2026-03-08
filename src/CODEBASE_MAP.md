# Macrowhisper CLI - Codebase Map

## Overview

**Macrowhisper** is an automation layer for **Superwhisper**. It watches recording folders, validates completed transcription results, enriches them with app and clipboard context, then resolves and executes actions through a shared runtime used by both the watcher and CLI.

### Core Functionality
- **Recording watcher pipeline**: monitors Superwhisper recordings, validates `meta.json`, and handles burst/cancel/recovery scenarios
- **Unified action system**: insert, URL, shortcut, shell, and AppleScript actions share chaining, triggering, placeholder expansion, and clipboard semantics
- **Config version 2 semantics**: `null` means inherit defaults, `""` means explicitly empty, and reserved templates like `.none`, `.autoPaste`, and `.run` have dedicated runtime behavior
- **Clipboard/session coordination**: captures selected text and clipboard context early, freezes context for execution, and avoids Superwhisper sync contamination
- **CLI/runtime parity**: socket-backed commands reuse the same action resolution rules as the live watcher
- **JSON schema + config validation**: local schema management, semantic validation, and auto-migration/update support

---

## Project Structure

```text
src/
├── macrowhisper/
│   ├── main.swift                        # Entry point, CLI parsing, daemon/bootstrap, watcher lifecycle
│   ├── Config/
│   │   ├── AppConfiguration.swift        # Codable config model, action definitions, configVersion 2
│   │   └── ConfigurationManager.swift    # Loading, validation, migration, live reload, persistence
│   ├── History/
│   │   └── HistoryManager.swift          # Retention-based recordings cleanup
│   ├── Watcher/
│   │   ├── RecordingsFolderWatcher.swift # Main recording pipeline and runtime action resolution
│   │   ├── SuperwhisperFolderWatcher.swift # Waits for missing recordings folder to appear
│   │   └── ConfigChangeWatcher.swift     # Filesystem watcher for config reloads
│   ├── Utils/
│   │   ├── ActionExecutor.swift          # Shared runtime for action execution and chaining
│   │   ├── TriggerEvaluator.swift        # Trigger matching across voice/app/mode/URL conditions
│   │   ├── ClipboardMonitor.swift        # Global + per-session clipboard coordination
│   │   ├── Placeholders.swift            # Placeholder parsing, transforms, meta traversal
│   │   ├── RecordingReferenceResolver.swift # Resolve current/previous recording folders for placeholders and CLI
│   │   ├── AppVocabulary.swift           # Accessibility-driven app vocabulary extraction
│   │   ├── BrowserURLNormalization.swift # Browser URL normalization for trigger/url context
│   │   ├── SmartInsertBoundary.swift     # Smart casing/punctuation/spacing boundary logic
│   │   ├── SimReturnBehavior.swift       # Return-key timing/behavior helpers
│   │   ├── SchemaManager.swift           # Local schema discovery and `$schema` management
│   │   ├── ServiceManager.swift          # launchd integration
│   │   ├── NotificationManager.swift     # User notifications
│   │   ├── Logger.swift                  # Structured logging and redaction
│   │   ├── Accessibility.swift           # Focus/input-field detection and keyboard helpers
│   │   └── UserDefaultsManager.swift     # Saved config-path persistence
│   └── Networking/
│       ├── SocketCommunication.swift     # Unix socket server and CLI command handling
│       └── VersionChecker.swift          # Update checks
├── macrowhisper-schema.json              # JSON schema for config editing/validation
└── Tests/                                # Focused regression tests for parser/runtime edge cases
```

---

## Core Components

### 1. Main Application (`main.swift`)
- Parses CLI commands, starts the socket server, and owns watcher lifecycle
- Applies startup config auto-update when `defaults.autoUpdateConfig` is enabled
- Exposes config utilities like `--update-config`, `--validate-config`, `--set-config`, and `--reset-config`
- Exposes runtime/action commands like `--exec-action`, `--run-auto`, `--get-action`, `--copy-action`, `--folder-name`, `--folder-path`, and `--mute-triggers`
- Reinitializes watchers live when config path or watch path changes

### 2. Configuration System

#### `AppConfiguration.swift`
- Defines the full config model and sets `currentConfigVersion = 2`
- Centralizes defaults and normalized persistence behavior for root defaults and all action types
- All action types support `nextAction`, `inputCondition`, trigger fields, and per-action clipboard timing settings
- Script-like actions (`shortcut`, `shell`, `AppleScript`) also support `scriptAsync` and `scriptWaitTimeout`
- Reserved action templates are runtime-significant:
  - `.autoPaste` for insert template behavior
  - `.none` for explicit no-op behavior
  - `.run` for shortcut execution without input payload

#### `ConfigurationManager.swift`
- Loads config from explicit path, saved path, or default path
- Performs semantic validation, not just JSON decoding
- Auto-migrates legacy naming/semantics to config version 2 when allowed
- Preserves schema references and normalizes persisted config values
- Reports detailed validation issues for `--validate-config`

### 3. Recording / Watcher Pipeline

#### `RecordingsFolderWatcher.swift`
- Main runtime path for new recordings
- Starts early clipboard monitoring as soon as a recording folder appears
- Waits for a valid result using LLM-aware validation:
  - if `languageModelName` is present, `llmResult` is required
  - otherwise `result` is required
- Enriches `meta.json` with front-app, selected-text, clipboard, and URL context
- Applies bypass and execution priority rules:
  1. auto-return
  2. scheduled action
  3. trigger-matched action
  4. active action fallback
- Includes burst protection, stalled-recording timeout handling, folder deletion cleanup, and recovery for interrupted sessions

#### `SuperwhisperFolderWatcher.swift`
- Keeps the service running even when the Superwhisper recordings folder does not exist yet
- Hands off cleanly to `RecordingsFolderWatcher` once the folder appears

#### `ConfigChangeWatcher.swift`
- Watches the config file path and triggers live reloads without restarting the daemon

### 4. Action Runtime

#### `ActionExecutor.swift`
- Shared execution engine for watcher-driven actions
- Resolves action chains at runtime and detects duplicate/missing/cyclic chains
- Applies legacy template overrides and `inputCondition` across all action types
- Freezes chain context for delayed/chained execution so placeholders stay stable
- Supports synchronous script-like steps and carries their outputs forward as `actionResult` / `actionResults`
- Applies `moveTo`/deletion behavior after execution when a real recording folder exists

#### `TriggerEvaluator.swift`
- Evaluates triggers across all action types
- Supports voice, front app, mode, and browser URL matching
- Allows negative patterns (`!pattern`), raw regex (`==pattern==`), and AND/OR trigger logic
- Voice-trigger stripping feeds cleaned text into downstream placeholder execution when appropriate
- App matching is tolerant of missing name or bundle ID

### 5. Clipboard and Context Capture

#### `ClipboardMonitor.swift`
- Maintains two clipboard layers:
  - lightweight global history for pre-recording context
  - per-recording session monitoring for active action execution
- Captures selected text and clipboard context once per recording session, then reuses that snapshot across chains
- Handles overlap/pending-restore execution groups so chained or adjacent recordings do not corrupt each other
- Filters duplicate/system clipboard writes and resets contaminated history after action execution
- Provides CLI-safe clipboard cleanup/restoration hooks used by socket commands

### 6. Placeholder / Context System

#### `Placeholders.swift`
- Expands standard placeholders such as `{{swResult}}`, `{{selectedText}}`, `{{clipboardContext}}`, and `{{frontApp}}`
- Supports nested `meta.json` traversal, including arrays and objects
- Supports transformed placeholders like `{{placeholder::transform||find||replace}}`
- Handles newer context sources including:
  - `{{actionResult}}`, `{{actionResult:N}}`
  - `{{appVocabulary}}`
  - `{{frontAppUrl}}`
  - `{{folderName}}`, `{{folderPath}}`, and indexed variants
  - `{{segments}}` for readable speaker-formatted transcript output

#### Supporting Context Utilities
- `RecordingReferenceResolver.swift`: resolves current/latest/prior recording folders for placeholders and CLI commands
- `AppVocabulary.swift`: derives app-specific vocabulary from accessibility data
- `BrowserURLNormalization.swift`: normalizes browser URLs for trigger matching and placeholder use
- `SmartInsertBoundary.swift` and `SimReturnBehavior.swift`: keep insert formatting and return timing consistent

### 7. CLI / Inter-Process Communication

#### `SocketCommunication.swift`
- Runs the Unix socket server used by CLI commands
- Reuses watcher-like action semantics for CLI execution
- Supports:
  - config/service commands
  - unified action listing/get/remove/execute/copy
  - `--run-auto` with runtime-style resolution
  - `--meta` against latest result, recording folder name, folder path, or direct `meta.json`
  - folder lookup commands (`--folder-name`, `--folder-path`)
- Preserves CLI clipboard behavior separately from watcher execution while matching chain-level restore semantics

### 8. Supporting Infrastructure
- `SchemaManager.swift`: finds a local schema and manages `$schema` references without requiring network access
- `HistoryManager.swift`: deletes old recording folders based on `defaults.history`
- `ServiceManager.swift`: install/start/stop/restart/uninstall for launchd service mode
- `Logger.swift`: central logging with redaction-aware helpers
- `NotificationManager.swift`: user-facing alerts for startup/config/runtime issues
- `VersionChecker.swift`: optional update checks

---

## Runtime Priority

### Watcher Priority
1. **AutoReturn**
2. **Scheduled action**
3. **Trigger match**
4. **ActiveAction**

### `--run-auto` Priority
1. **Bypass mode check**
2. **Trigger mute check**
3. **Trigger match**
4. **ActiveAction**

---

## Config Version 2 Notes

- `configVersion: 2` is the current semantic baseline
- `null` means inherit from defaults or built-in behavior
- `""` means intentionally empty
- `.none` is reserved for action-template semantics, not for fields like `icon` or `moveTo`
- Legacy keys are still migrated:
  - `noEsc` -> `simEsc`
  - `pressReturn` -> `simReturn`
  - `noUpdates` -> `disableUpdateCheck`
  - `noNoti` -> `muteNotifications`

---

## Minimal Schema Shape

```json
{
  "$schema": "file://path/to/macrowhisper-schema.json",
  "configVersion": 2,
  "defaults": {
    "watch": "~/Documents/superwhisper",
    "activeAction": "autoPaste",
    "restoreClipboardDelay": 0.3,
    "clipboardBuffer": 5,
    "bypassModes": "",
    "autoUpdateConfig": true
  },
  "inserts": {
    "name": {
      "action": ".autoPaste",
      "inputCondition": "restoreClipboard|!simEsc",
      "triggerVoice": "pattern",
      "triggerUrls": "example.com",
      "nextAction": "followUp"
    }
  },
  "urls": {
    "name": {
      "action": "https://example.com",
      "inputCondition": "restoreClipboard"
    }
  },
  "shortcuts": {
    "name": {
      "action": ".run",
      "scriptAsync": false,
      "scriptWaitTimeout": 3
    }
  },
  "scriptsShell": {
    "name": {
      "action": "echo {{swResult}}",
      "scriptAsync": false
    }
  },
  "scriptsAS": {
    "name": {
      "action": "tell application \"Finder\" to activate"
    }
  }
}
```

---

## Key Files for Development

- **Pipeline**: `RecordingsFolderWatcher.swift`, `ActionExecutor.swift`, `ClipboardMonitor.swift`
- **Config / migration**: `AppConfiguration.swift`, `ConfigurationManager.swift`, `macrowhisper-schema.json`
- **Triggering / placeholders**: `TriggerEvaluator.swift`, `Placeholders.swift`
- **CLI parity**: `SocketCommunication.swift`, `main.swift`, `RecordingReferenceResolver.swift`
- **Support behavior**: `SmartInsertBoundary.swift`, `SimReturnBehavior.swift`, `AppVocabulary.swift`
