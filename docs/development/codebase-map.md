# Macrowhisper CLI - Codebase Map

[Documentation index](../README.md)

This map is an implementation index for contributors. Paths are rooted at the
repository; source-file links point into `src/` and remain valid from this
document's location.

## Overview

**Macrowhisper** is an automation layer for **Superwhisper**. It watches recording folders, validates completed transcription results, enriches them with app and clipboard context, then resolves and executes actions. Watcher execution lives in `ActionExecutor`; CLI execution lives in `SocketCommunication`, with shared configuration, trigger, placeholder, and clipboard utilities. Changes to action semantics must account for both execution paths.

### Core Functionality
- **Recording watcher pipeline**: monitors Superwhisper recordings, validates `meta.json`, and handles burst/cancel/recovery scenarios
- **Unified action system**: insert, URL, shortcut, shell, and AppleScript actions share chaining, triggering, placeholder expansion, and clipboard semantics
- **Config version 2 semantics**: `null` means inherit defaults, `""` means explicitly empty, and reserved templates like `.none`, `.autoPaste`, and `.run` have dedicated runtime behavior
- **Clipboard/session coordination**: captures selected text and clipboard context early, freezes context for execution, and avoids Superwhisper sync contamination; optional attachment handoff remains separate from the string placeholder and original-clipboard snapshot
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
│   │   ├── ActionExecutor.swift          # Watcher action execution and chaining
│   │   ├── TriggerEvaluator.swift        # Trigger matching across voice/app/mode/URL conditions
│   │   ├── ClipboardMonitor.swift        # Global + per-session clipboard coordination
│   │   ├── Placeholders.swift            # Placeholder parsing, transforms, meta traversal
│   │   ├── RecordingReferenceResolver.swift # Resolve current/previous recording folders for placeholders and CLI
│   │   ├── RecordingMetadataSettlePolicy.swift # One-second grace for integrated S1 transcript readiness
│   │   ├── AppVocabulary.swift           # Accessibility-driven app vocabulary extraction
│   │   ├── BrowserURLNormalization.swift # Browser URL normalization for trigger/url context
│   │   ├── SmartInsertBoundary.swift     # Smart casing/punctuation/spacing boundary logic
│   │   ├── SmartInsertHeuristics.swift   # Pure helpers used by smart insertion
│   │   ├── SimReturnBehavior.swift       # Return-key timing/behavior helpers
│   │   ├── SchemaManager.swift           # Local schema discovery and `$schema` management
│   │   ├── ServiceManager.swift          # launchd integration
│   │   ├── ServiceLifecycleDiagnostics.swift # Launch intents, sessions, and shutdown diagnostics
│   │   ├── ShellUtils.swift              # Shell escaping helpers
│   │   ├── NotificationManager.swift     # User notifications
│   │   ├── Logger.swift                  # Structured logging and redaction
│   │   ├── Accessibility.swift           # Focus/input-field detection and keyboard helpers
│   │   └── UserDefaultsManager.swift     # Saved config-path persistence
│   └── Networking/
│       ├── SocketCommunication.swift     # Unix socket server and CLI command handling
│       └── VersionChecker.swift          # Update checks
├── macrowhisper-schema.json              # JSON schema for config editing/validation
├── macrowhisper.xcodeproj/               # Supported signed application build
├── Package.swift                        # SwiftPM metadata; source target currently undiscovered
└── Tests/                                # Focused regression tests for parser/runtime edge cases
```

---

## Core Components

### 1. Main Application ([src/macrowhisper/main.swift](../../src/macrowhisper/main.swift))
- Parses CLI commands, starts the socket server, and owns watcher lifecycle
- Applies startup config auto-update when `defaults.autoUpdateConfig` is enabled
- Exposes config utilities like `--update-config`, `--validate-config`, `--set-config`, and `--reset-config`
- Exposes runtime/action commands like `--exec-action`, `--run-auto`, `--get-action`, `--copy-action`, `--folder-name`, `--folder-path`, and `--mute-triggers`
- Reinitializes watchers live when config path or watch path changes

### 2. Configuration System

#### [src/macrowhisper/Config/AppConfiguration.swift](../../src/macrowhisper/Config/AppConfiguration.swift)
- Defines the full config model and sets `currentConfigVersion = 2`
- Centralizes defaults and normalized persistence behavior for root defaults and all action types
- Provides `clipboardAttachments` (default `false`) with nullable action overrides; the effective root setting applies to the full chain and enables native handoff independently of string-placeholder use
- All action types support `nextAction`, `inputCondition`, trigger fields, and per-action clipboard timing settings
- Script-like actions (`shortcut`, `shell`, `AppleScript`) also support `scriptAsync` and `scriptWaitTimeout`
- Reserved action templates are runtime-significant:
  - `.autoPaste` for insert template behavior
  - `.none` for explicit no-op behavior
  - `.run` for shortcut execution without input payload

#### [src/macrowhisper/Config/ConfigurationManager.swift](../../src/macrowhisper/Config/ConfigurationManager.swift)
- Loads config from explicit path, saved path, or default path
- Performs semantic validation, not just JSON decoding
- Auto-migrates legacy naming/semantics to config version 2 when allowed
- Preserves schema references and normalizes persisted config values
- Reports detailed validation issues for `--validate-config`

### 3. Recording / Watcher Pipeline

#### [src/macrowhisper/Watcher/RecordingsFolderWatcher.swift](../../src/macrowhisper/Watcher/RecordingsFolderWatcher.swift)
- Main runtime path for new recordings
- Starts early clipboard monitoring as soon as a recording folder appears
- Waits for a valid result using LLM-aware validation:
  - if `languageModelName` is a nonempty string, nonempty `llmResult` is required
  - otherwise nonempty `result` is required
  - integrated S1-Language/S1-Voice gets a one-second grace period for a missing source `result`, then may proceed with `llmResult`
- Enriches `meta.json` with front-app, selected-text, clipboard, and URL context
- Applies bypass and execution priority rules:
  1. auto-return
  2. scheduled action
  3. trigger-matched action
  4. active action fallback
- Includes burst protection, stalled-recording timeout handling, folder deletion cleanup, and recovery for interrupted sessions

#### [src/macrowhisper/Watcher/SuperwhisperFolderWatcher.swift](../../src/macrowhisper/Watcher/SuperwhisperFolderWatcher.swift)
- Keeps the service running even when the Superwhisper recordings folder does not exist yet
- Hands off cleanly to `RecordingsFolderWatcher` once the folder appears

`RecordingsFolderWatcher` also monitors the configured Superwhisper parent for rename/delete/revoke events. A broken path triggers a quick recovery sequence that checks Superwhisper's preference and the known legacy-to-current move and persists only a verified replacement. If no replacement is ready, a lightweight recovery state watches for the original path to return and checks Superwhisper's preference once per minute until service resumes.

#### [src/macrowhisper/Watcher/ConfigChangeWatcher.swift](../../src/macrowhisper/Watcher/ConfigChangeWatcher.swift)
- Watches the config file path and triggers live reloads without restarting the daemon

### 4. Action Runtime

#### [src/macrowhisper/Utils/ActionExecutor.swift](../../src/macrowhisper/Utils/ActionExecutor.swift)
- Execution engine for watcher-driven actions; CLI execution is implemented separately in `SocketCommunication`
- Resolves action chains at runtime and detects duplicate/missing/cyclic chains
- Applies legacy template overrides and `inputCondition` across all action types
- Freezes chain context for delayed/chained execution so placeholders stay stable
- Supports synchronous script-like steps and carries their outputs forward as `actionResult` / `actionResults`
- Reports the final executed action to the watcher, which applies `moveTo`/deletion during post-processing

#### [src/macrowhisper/Utils/TriggerEvaluator.swift](../../src/macrowhisper/Utils/TriggerEvaluator.swift)
- Evaluates triggers across all action types
- Supports voice, front app, mode, and browser URL matching
- Ranks actual positive matches with built-in voice > mode > URL > app priority; exception-only rules are catch-alls and action name is the final tie-breaker
- Allows negative patterns (`!pattern`), raw regex (`==pattern==`), and AND/OR trigger logic
- Voice-trigger stripping feeds cleaned text into downstream placeholder execution when appropriate
- App matching is tolerant of missing name or bundle ID

### 5. Clipboard and Context Capture

#### [src/macrowhisper/Utils/ClipboardMonitor.swift](../../src/macrowhisper/Utils/ClipboardMonitor.swift)
- Maintains two clipboard layers:
  - lightweight global history for pre-recording context
  - per-recording session monitoring for active action execution
- Captures selected text and clipboard context once per recording session, then reuses that snapshot across chains
- Handles overlap/pending-restore execution groups so chained or adjacent recordings do not corrupt each other
- Filters duplicate/system clipboard writes and resets contaminated history after action execution
- Treats `NSPasteboard.changeCount` as the operation boundary for ordered text/file-URL/PNG/TIFF representations; attachment retention is bounded to 64 MiB per image and 192 MiB total
- Keeps the context payload separate from the original snapshot; successful eligible chains can hand attachments off for manual paste even when `restoreClipboard` is `false`
- Converts final file/raw-image/mixed handoff into one eager ordered Finder filename array from which AppKit synthesizes file URLs; raw PNG is validated and raw TIFF is normalized to PNG only at successful final handoff, in a managed cache that preserves existing current-clipboard files across restart, rejects stale references, reclaims interrupted empty generations, retains unreferenced files for 24 hours, and caps generated data at 1 GiB
- Provides CLI-safe clipboard cleanup/restoration hooks used by socket commands

### 6. Placeholder / Context System

#### [src/macrowhisper/Utils/Placeholders.swift](../../src/macrowhisper/Utils/Placeholders.swift)
- Expands standard placeholders such as `{{swResult}}`, `{{selectedText}}`, `{{clipboardContext}}`, and `{{frontApp}}`
- Keeps `{{clipboardContext}}` string-only; attachment-only operations expand to an empty placeholder while attachments-enabled watcher chains hand supported attachments off independently of placeholder use
- Supports nested `meta.json` traversal, including arrays and objects
- Supports transformed placeholders like `{{placeholder::transform||find||replace}}`
- Handles newer context sources including:
  - `{{actionResult}}`, `{{actionResult:N}}`
  - `{{appVocabulary}}`
  - `{{frontAppUrl}}`
  - `{{folderName}}`, `{{folderPath}}`, and indexed variants
  - `{{segments}}` for readable speaker-formatted transcript output

#### Supporting Context Utilities
- [src/macrowhisper/Utils/RecordingMetadataSettlePolicy.swift](../../src/macrowhisper/Utils/RecordingMetadataSettlePolicy.swift): identifies the integrated S1-Language/S1-Voice case that gets a one-second grace period for source-transcript readiness
- [src/macrowhisper/Utils/RecordingReferenceResolver.swift](../../src/macrowhisper/Utils/RecordingReferenceResolver.swift): resolves current/latest/prior recording folders for placeholders and CLI commands
- [src/macrowhisper/Utils/AppVocabulary.swift](../../src/macrowhisper/Utils/AppVocabulary.swift): derives app-specific vocabulary from accessibility data
- [src/macrowhisper/Utils/BrowserURLNormalization.swift](../../src/macrowhisper/Utils/BrowserURLNormalization.swift): normalizes browser URLs for trigger matching and placeholder use
- [src/macrowhisper/Utils/SmartInsertBoundary.swift](../../src/macrowhisper/Utils/SmartInsertBoundary.swift), [src/macrowhisper/Utils/SmartInsertHeuristics.swift](../../src/macrowhisper/Utils/SmartInsertHeuristics.swift), and [src/macrowhisper/Utils/SimReturnBehavior.swift](../../src/macrowhisper/Utils/SimReturnBehavior.swift): keep insert formatting and return timing consistent

### 7. CLI / Inter-Process Communication

#### [src/macrowhisper/Networking/SocketCommunication.swift](../../src/macrowhisper/Networking/SocketCommunication.swift)
- Runs the Unix socket server used by CLI commands
- Reuses watcher-like action semantics for CLI execution
- Supports:
  - config/service commands
  - unified action listing/get/remove/execute/copy
  - `--run-auto` with runtime-style resolution
  - `--meta` against latest result, recording folder name, folder path, or direct `meta.json`
  - folder lookup commands (`--folder-name`, `--folder-path`)
- Preserves CLI clipboard behavior separately from watcher execution while matching chain-level restore semantics; pure CLI and `copyAction` do not perform attachment handoff, although supported original restoration may be shared

### 8. Supporting Infrastructure
- [src/macrowhisper/Utils/SchemaManager.swift](../../src/macrowhisper/Utils/SchemaManager.swift): finds a local schema and manages `$schema` references without requiring network access
- [src/macrowhisper/History/HistoryManager.swift](../../src/macrowhisper/History/HistoryManager.swift): deletes old recording folders based on `defaults.history`
- [src/macrowhisper/Utils/ServiceManager.swift](../../src/macrowhisper/Utils/ServiceManager.swift): install/start/stop/restart/uninstall for launchd service mode
- [src/macrowhisper/Utils/ServiceLifecycleDiagnostics.swift](../../src/macrowhisper/Utils/ServiceLifecycleDiagnostics.swift): records launch intents, daemon sessions, clean signal shutdowns, and unclean previous sessions; launchd status parsing lives in `ServiceManager`
- [src/macrowhisper/Utils/Logger.swift](../../src/macrowhisper/Utils/Logger.swift): central logging with redaction-aware helpers
- [src/macrowhisper/Utils/NotificationManager.swift](../../src/macrowhisper/Utils/NotificationManager.swift): user-facing alerts for startup/config/runtime issues
- [src/macrowhisper/Networking/VersionChecker.swift](../../src/macrowhisper/Networking/VersionChecker.swift): optional update checks

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
- Current post-processing treats an empty action `moveTo` as inheritance despite the version 2 empty-value contract; see the [current moveTo limitation](../configuration.md#current-moveto-limitation)
- Legacy keys are still migrated:
  - `noEsc` -> `simEsc`
  - `pressReturn` -> `simReturn`
  - `noUpdates` -> `disableUpdateCheck`
  - `noNoti` -> `muteNotifications`

---

## Configuration and examples

The [configuration guide](../configuration.md) explains the top-level structure,
inheritance, and defaults. Use [actions](../actions.md) for fields supported by
each action type and [examples](../examples.md) for complete configurations.

The [JSON schema](../../src/macrowhisper-schema.json) supports editor completion
and structural checks. `ConfigurationManager` adds semantic checks such as
unique action names across all five groups, valid `activeAction`/`nextAction`
references, and chain validation. A document can parse as JSON while failing
those checks; use `macrowhisper --validate-config` on the intended configuration.

---

## Key Files for Development

- **Pipeline**: [RecordingsFolderWatcher.swift](../../src/macrowhisper/Watcher/RecordingsFolderWatcher.swift), [ActionExecutor.swift](../../src/macrowhisper/Utils/ActionExecutor.swift), [ClipboardMonitor.swift](../../src/macrowhisper/Utils/ClipboardMonitor.swift)
- **Config / migration**: [AppConfiguration.swift](../../src/macrowhisper/Config/AppConfiguration.swift), [ConfigurationManager.swift](../../src/macrowhisper/Config/ConfigurationManager.swift), [macrowhisper-schema.json](../../src/macrowhisper-schema.json)
- **Triggering / placeholders**: [TriggerEvaluator.swift](../../src/macrowhisper/Utils/TriggerEvaluator.swift), [Placeholders.swift](../../src/macrowhisper/Utils/Placeholders.swift)
- **CLI parity**: [SocketCommunication.swift](../../src/macrowhisper/Networking/SocketCommunication.swift), [main.swift](../../src/macrowhisper/main.swift), [RecordingReferenceResolver.swift](../../src/macrowhisper/Utils/RecordingReferenceResolver.swift)
- **Support behavior**: [SmartInsertBoundary.swift](../../src/macrowhisper/Utils/SmartInsertBoundary.swift), [SimReturnBehavior.swift](../../src/macrowhisper/Utils/SimReturnBehavior.swift), [AppVocabulary.swift](../../src/macrowhisper/Utils/AppVocabulary.swift)
