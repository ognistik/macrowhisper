# Macrowhisper Processing Flow Documentation

[Documentation index](../README.md)

## Overview

This document provides a comprehensive technical analysis of Macrowhisper's complete processing flow, from the moment a recording folder is detected to the final action execution and clipboard synchronization. This is essential developer documentation to understand the complex timing, conditions, and variables involved in the automation system.

Source paths link to the repository's `src/` tree. For implementation
ownership and local build/test procedures, see the [codebase map](codebase-map.md)
and [development guide](README.md).

## Table of Contents

1. [High-Level Processing Flow](#high-level-processing-flow)
2. [Recording Folder Detection](#recording-folder-detection)
3. [Enhanced Clipboard Monitoring System](#enhanced-clipboard-monitoring-system)
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
   └── Initialize Global Clipboard Monitoring (configurable rolling buffer; default 5s; 0 disables)
   ↓
1. Recording Folder Detection (RecordingsFolderWatcher)
   ↓
2. Pre-Recording Data Capture
   ├── Capture clipboard from global history (within configurable buffer window before recording)
   ├── Capture selectedText
   └── Capture original clipboard
   ↓
3. Start Session, Audio, and Timeout Monitoring
   ├── If meta.json complete → Check its kind and result with early monitoring active
   ├── If meta.json incomplete → Watch for metadata changes and a valid result
   └── If meta.json missing → Watch for file creation
   ↓
4. Meta.json Processing (RecordingsFolderWatcher)
   ├── If kind is meeting → Skip automatic processing before result readiness
   └── Otherwise → Wait for a valid result, then continue action selection
   ↓
5. Context Gathering & Session Data Enhancement
   ├── Front App context
   ├── Freeze app snapshot for chain consistency (name, bundle ID, PID)
   ├── Add selectedText to metaJson
   ├── Add clipboardContext to metaJson (session priority, pre-recording fallback)
   ├── Freeze root clipboardStacking/clipboardAttachments settings for the chain
   └── Add appContext/appVocabulary lazily on first placeholder use; reuse for chain
   ↓
6. Action Priority Evaluation
   ├── Auto-Return (Highest Priority)
   ├── Scheduled action
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

### Primary File: [src/macrowhisper/Watcher/RecordingsFolderWatcher.swift](../../src/macrowhisper/Watcher/RecordingsFolderWatcher.swift)

The process begins when Superwhisper creates a new recording folder in the watched directory.

#### Key Components:
- **File System Watcher**: Uses `DispatchSourceFileSystemObject` to monitor the `recordings` directory under the configured `defaults.watch` path
- **Duplicate Prevention**: Maintains `processedRecordings: Set<String>` to prevent reprocessing
- **Startup Behavior**: Marks all existing recordings as processed to avoid replaying old recordings
- **Burst/old arrivals**: Multiple folders in one event are marked processed without execution; a single newly arrived folder older than the latest known folder is also skipped

#### Detection Flow:
1. **Folder Change Event**: `handleFolderChangeEvent()` detects new subdirectories
2. **Duplicate Check**: `isAlreadyProcessed(recordingPath:)` prevents reprocessing
3. **Early Monitoring**: `processNewRecording` starts clipboard, audio-file, and timeout monitoring before testing metadata readiness
   - If complete → Process with session state already available
   - If incomplete/missing → Keep monitoring while waiting for valid metadata
4. **Meta.json Handling**: Either processes existing meta.json or starts watching for its creation

#### Critical Variables:
- `lastKnownSubdirectories: Set<String>` - Tracks known recording folders
- `pendingMetaJsonFiles: [String: DispatchSourceFileSystemObject]` - Active meta.json watchers
- `processedRecordings: Set<String>` - Persistent tracking of processed recordings
- `processedRecordingsFile: String` - File path for persistence

---

## Enhanced Clipboard Monitoring System

### Primary File: [src/macrowhisper/Utils/ClipboardMonitor.swift](../../src/macrowhisper/Utils/ClipboardMonitor.swift)

This is the **most critical component** for handling clipboard synchronization between Superwhisper and Macrowhisper, now enhanced with pre-recording capture.

#### The Problem:
Superwhisper and Macrowhisper both modify the clipboard simultaneously, causing:
- Lost user clipboard content
- Race conditions between clipboard modifications
- Incorrect content being pasted
- Users often copy content shortly before recording and want to access it in actions

#### The Solution - Dual Monitoring Architecture:

##### 1. Lightweight Global Monitoring (App Lifetime):
- **Purpose**: Maintains configurable rolling buffer for pre-recording capture (defaults to 5s; set to 0 to disable)
- **Frequency**: 0.5-second intervals (lightweight)
- **Scope**: Single shared instance across all components
- **Diagnostics**: Clipboard observation logs describe operations using counts, types, timing, and fingerprints. Other content-bearing debug paths depend on `redactedLogs`; do not assume all application logs are content-free.

##### 2. Smart Session Monitoring (Recording Specific):
`startEarlyMonitoring(for:sessionStartTime:)` captures a representation-aware
original clipboard snapshot, selected text, input-field state, and eligible
pre-recording observations. It creates or joins an execution group so adjacent
recordings and pending finalization share a controlled clipboard owner.

During this bootstrap boundary, Superwhisper may publish a temporary clipboard
value after the stable startup state was sampled and restore that stable state
before the first session poll. For sessions that began outside an input field,
bootstrap reconciliation can exclude the temporary operation and its restore as
one transaction, but only when the stable content or payload matches exactly,
the `NSPasteboard.changeCount` values are adjacent, and both observations fit
the narrow startup timing window. First copies, mismatched baselines, and
non-adjacent or late observations remain eligible clipboard context.

#### Enhanced Session Structure:
- `EarlyMonitoringSession` owns per-recording observations: `groupId`, start time, selected text, session-start input state, clipboard changes, pre-recording text/stack/changes, replay guards, change counts, and the frozen context snapshot.
- `ExecutionGroup` owns `rootOriginalSnapshot`, root selected text and pre-recording context, frozen root settings, member recording paths, script results, attachment eligibility, and pending restoration/finalization. The original snapshot is separate from the context payload.
- `ClipboardChange` identifies an operation by `changeCount`, with its timestamp, optional string projection, representation-aware payload, front app, pasteboard types, and same-content-rewrite status.

#### Key Features:
- **Thread-Safe**: Uses `sessionsQueue` with concurrent reads and barrier writes
- **Execution markers**: Track when action execution begins and ends; observation and cleanup diagnostics can also occur outside that interval
- **Single Instance**: Shared ClipboardMonitor prevents duplicate monitoring
- **Continuous Monitoring**: Tracks eligible operations throughout the active session, with separate cleanup and finalization boundaries
- **Pre-Recording Capture**: Configurable rolling buffer for {{clipboardContext}} placeholder (defaults to 5s; 0 disables)
- **Change Tracking**: Monitors all clipboard changes during the session
- **Original Restoration**: Restores the representation-aware root snapshot captured at session start, subject to finalization ownership
- **Operation boundary**: `NSPasteboard.changeCount` identifies one clipboard operation; ordered text, file URLs, PNG, and TIFF representations from that operation stay together
- **Attachment handoff**: Optional `clipboardAttachments` data is bounded to 64 MiB per image and 192 MiB in aggregate, with oldest pre-recording image data evicted before active-session or original-snapshot data
- **Privacy and separation**: `{{clipboardContext}}` remains string-only, files remain URLs, and the context payload is separate from the original clipboard restoration snapshot
- **Action Execution Boundaries**: Clear start/finish markers for relevant logging periods
- **Timing Constants**:
  - `maxWaitTime: 0.1` seconds - Maximum time to wait for Superwhisper
  - `pollInterval: 0.01` seconds - 10ms polling interval for session monitoring
  - `globalMonitoringInterval: 0.5` seconds - Global monitoring frequency
- `clipboardBuffer (configurable)`: Pre-recording clipboard capture window (Double seconds). Default 5.0; 0 disables global monitoring/capture.

#### Action Execution Control Methods:
- `startActionExecution` marks the step active and ends the startup replay guard for its group.
- `finishActionExecution` marks it inactive and can schedule clipboard-history cleanup after the restore delay plus cleanup grace.
- `stopEarlyMonitoring` detaches a recording, preserves root context while other members or pending work need it, and finalizes only after the group has no active members.
- `abortExecutionGroups` handles cancellation/recovery by discarding the affected groups and preserving the current clipboard.

Delayed finalization checks the group's `finalizationToken`, current owner, and
membership before writing the clipboard. Concurrent queues with barrier writes
coordinate this state; operations requiring both queues use global-history
then session ordering.

---

## Meta.json Processing

### Primary File: [src/macrowhisper/Watcher/RecordingsFolderWatcher.swift](../../src/macrowhisper/Watcher/RecordingsFolderWatcher.swift)

Meta.json contains the transcription results from Superwhisper and may not exist immediately when the recording folder appears.

#### Processing States:
1. **Immediate Processing**: If meta.json exists when folder is detected
2. **Delayed Processing**: Watch for meta.json creation with `watchForMetaJsonCreation()`
3. **Update Processing**: Watch for meta.json changes with `watchMetaJsonForChanges()`

Before waiting for result readiness, the watcher skips a recording whose
metadata `kind`, after trimming surrounding whitespace, matches `meeting`
without regard to case. Other kind values and missing `kind` continue through
normal processing.

#### Validation Requirements:
- A nonempty string `languageModelName` selects the LLM path, which requires a nonempty string `llmResult`.
- Without a nonempty `languageModelName`, a nonempty string `result` is required.
- Missing, null, nonstring, and empty required results keep the metadata watcher active.
- For integrated S1-Language + S1-Voice (`languageModelKey: "sl-1"`, `modelKey: "sv-1"`), an available `llmResult` with an empty `result` gets a one-second grace period. Processing then continues with `llmResult` if `result` still has not arrived.
- Voice triggers use `result`; they do not match when that source text is empty, even if `llmResult` is ready. See [runtime](../runtime.md) for readiness and recovery behavior.

The same exclusion applies to CLI commands that use the latest recording by
default and to folder lookup commands. An explicit `--meta` can select a
meeting recording for an action command.

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

Before dispatching an action, the watcher freezes the effective root `clipboardStacking` and `clipboardAttachments` values into the chain context. A nullable action value inherits the default (`clipboardAttachments` defaults to `false`), and chained steps do not replace the root setting. Attachment handoff is tracked separately from the string `clipboardContext` value; an attachments-enabled watcher execution is eligible without requiring a placeholder consumer.

#### Key Variables:
- `result` or `llmResult` - The transcribed text (llmResult takes precedence)
- `modeName` - Superwhisper mode (e.g., "email", "writing")
- `frontAppName` - Current foreground application name
- `frontAppBundleId` - Current foreground application bundle ID

---

## Action Priority System

Actions are evaluated in strict priority order. **Higher priority actions completely override lower priority actions.**

`defaults.bypassModes` is checked before this selection and can skip processing
entirely. Auto-return and scheduled actions are mutually exclusive through the
CLI: enabling either clears the other. If a recording is already active, the
one-time selection applies to that session without starting a new timeout;
otherwise it waits for the next single arrival.

### Priority Order (Highest to Lowest):

#### 1. Auto-Return (Highest Priority)
- **Condition**: `autoReturnEnabled == true`
- **Purpose**: One-shot auto-send behavior for the next recording
- **Behavior**:
  - Resolves trigger/active candidate using normal selection rules
  - If resolved candidate is insert: resolves insert payload/settings, forcing `inputCondition` as in-input
  - Ignores `nextAction` (single insert only)
  - If resolved insert is empty/`.none`/`.autoPaste`, or candidate is non-insert/missing: falls back to `swResult`
  - Non-insert fallback ignores non-insert action settings and uses defaults
  - Forces one Return key simulation for the one-shot run
  - That forced Return is emitted before auto-return completes
- **Reset**: `autoReturnEnabled` is set to `false` after use (single-use)

#### 2. Scheduled Action
- **Condition**: `scheduledActionName != nil`
- **Behavior**: Runs exactly the scheduled action once, then clears the schedule
- **Override**: Higher priority than trigger and active action

#### 3. Trigger Actions (Medium Priority)
- **Evaluation**: `TriggerEvaluator.evaluateTriggersForAllActions()`
- **Types**: Insert, URL, Shortcut, Shell Script, AppleScript actions with triggers
- **Selection**: Highest-ranked actual match using voice > mode > URL > app priority, then required-condition and source-specific specificity; action name is the final tie-breaker
- **Override**: Completely overrides active action if any triggers match

#### 4. Active Action (Lowest Priority)
- **Condition**: `config.defaults.activeAction` is set and not empty
- **Fallback**: Only executed if no auto-return, no scheduled action, and no trigger actions match
- **Special Cases**: 
  - `.autoPaste`: Hard compatibility template for insert actions
  - `.none`: Hard compatibility template for insert actions
  - Empty insert action (`""`): No insertion content, but action settings still execute (ESC/restore/return/moveTo/chain)

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
- **Clipboard Sync First**: On the first action in a chain, wait up to `maxWaitTime (0.1s)` for Superwhisper unless recent clipboard activity allows skipping the wait
- **ActionDelay Second**: Applied after clipboard synchronization is complete
- **Independent Timing**: ActionDelay value does not affect clipboard synchronization logic

### Files Involved:
- **Configuration**: [src/macrowhisper/Config/AppConfiguration.swift](../../src/macrowhisper/Config/AppConfiguration.swift) (all action types have `actionDelay: Double?`)
- **Application**: [src/macrowhisper/Utils/ClipboardMonitor.swift](../../src/macrowhisper/Utils/ClipboardMonitor.swift) (handles timing coordination)
- **Fallback**: [src/macrowhisper/Networking/SocketCommunication.swift](../../src/macrowhisper/Networking/SocketCommunication.swift) (CLI commands)

---

## Clipboard Synchronization

### Primary File: [src/macrowhisper/Utils/ClipboardMonitor.swift](../../src/macrowhisper/Utils/ClipboardMonitor.swift)

The clipboard synchronization system handles the complex timing between Superwhisper and Macrowhisper clipboard modifications.

#### Synchronization Methods:

- `prepareClipboardContextForAction` reconciles the Superwhisper result before freezing context. A matching current pasteboard operation can be classified immediately; otherwise it uses the short activity wait and reconciliation fallback.
- Startup bootstrap reconciliation separately handles a temporary write that is present in the bootstrap snapshot and whose first later observation restores the exact stable pre-bootstrap state. It is limited to outside-input sessions and exact adjacent count/timing matches, so ordinary first copies are not hidden.
- `executeInsertWithEnhancedClipboardSync` runs watcher inserts, while `executeNonInsertActionWithClipboardRestore` runs watcher URL, Shortcut, shell, and AppleScript steps. Both receive a Boolean-returning action closure, chain boundary flags, restoration settings, and an optional completion callback.
- `shouldUseSuperwhisperSync` controls the first-step wait; `shouldStopMonitoringAfterAction` and `shouldTriggerCleanupAfterAction` keep intermediate steps from finalizing the chain.
- CLI execution has separate original-snapshot and chain-state handling in `SocketCommunication`; there is no separate `executeInsertWithClipboardSync` fallback method.

#### Corrected Timing Flow:
The clipboard synchronization system now follows the proper sequence:

```
1. For the first action in the chain, check for very recent session clipboard activity
2. Activity within 0.5s allows skipping the wait, even if its text differs from swResult
3. Otherwise, wait up to maxWaitTime (0.1s) for clipboard activity
4. Reconcile result contamination and freeze context before placeholder consumption
5. Apply actionDelay (user's setting)
6. Simulate ESC key if enabled
7. Execute action
8. At group finalization, hand off eligible attachments or apply effective restoration
```

#### Restoration Logic:
The execution group retains a supported original snapshot separately from
clipboard context. Sync/replay filtering keeps Superwhisper and internal
writes out of context. Finalization checks ownership before using the original
snapshot or committing an eligible attachment handoff. Missing or incomplete
original snapshots are not restored as partial text substitutes. Aborted groups
preserve the current clipboard and do not perform delayed restoration.

#### Restoration Conditions:
Clipboard restoration only occurs when **ALL** conditions are met:
- The execution group has no remaining active members and still owns its finalization boundary
- The final step requests restoration and its execution path permits it. `ActionExecutor` passes `restoreClipboardIndependentlyOfEsc: true` for the final step, including a one-step chain. Auto-return calls the monitor directly without that override, so its restoration depends on effective ESC simulation.
- A complete original snapshot is available, and a successful attachment handoff has not already supplied the final clipboard outcome

#### Attachment Handoff:
- Handoff is for a later manual paste, not placeholder expansion; attachment-only operations produce an empty string placeholder.
- It requires the frozen root `clipboardAttachments` value to be enabled and a watcher action path to execute; `{{clipboardContext}}` consumption is not required.
- Finalization of a successful eligible execution group is the final clipboard outcome, even when the final step has `restoreClipboard == false`.
- Failed, cancelled, and structurally invalid chains never hand attachments off. Handoff/restoration occurs only at execution-group finalization, never between steps.
- Pure CLI execution and `copyAction` do not hand attachments off. CLI original-clipboard restoration can still use the supported representations.
- Final handoff publishes one eager ordered `NSFilenamesPboardType` Finder file list; AppKit synthesizes the public file-URL flavors without relying on lazy NSURL writers. Existing files remain URLs; retained raw PNG is validated and materialized unchanged, while TIFF-only clipboard images are transcoded to PNG for upload compatibility. All generated files are created atomically in a private Macrowhisper cache generation before the pasteboard changes.
- Generated images remain available while the clipboard references an existing generated file, survive service restart, and remain cached for 24 hours after clipboard ownership ends. The cache is capped at 1 GiB; cleanup removes the oldest expired or over-capacity unreferenced Macrowhisper generations first. It revalidates clipboard ownership before each deletion, ignores stale paths to missing files, reclaims expired empty UUID debris from interrupted creation, and leaves nonempty unmarked directories and borrowed user files untouched.

Supported faithful representations are ordered text, file URLs, PNG, and TIFF. Oversized images remain attachments rather than falling back to incidental text; the unavailable item is not handed off and diagnostics must not contain clipboard text, image bytes, or private filenames/paths.

---

## Trigger Evaluation

### Primary File: [src/macrowhisper/Utils/TriggerEvaluator.swift](../../src/macrowhisper/Utils/TriggerEvaluator.swift)

The trigger system evaluates all configured actions to find matches based on voice, application, mode, and active URL criteria.

#### Trigger Types:

##### 1. Voice Triggers (`triggerVoice`):
- **Literal placement**: Plain phrases match the beginning of transcribed text; a leading `*` matches the end
- **Exceptions**: Patterns prefixed with `!` exclude matches
- **Multiple Patterns**: Separated by `|` (pipe character)
- **Result Stripping (literal patterns)**: Matched prefixes and suffixes are removed from result/swResult; suffix cleanup preserves or transfers sentence-ending punctuation
- **Case Insensitive**: All voice triggers are case-insensitive by default
- **Raw Regex**: Wrap patterns in `==` for full regex control (e.g., `==^exact match$==`); raw regex does not strip any text from result/swResult

Example:
```json
{
  "triggerVoice": "send email|compose message|*send it|!*cancel|==^google this\\.?$=="
}
```

**Raw Regex Examples:**
- `==^exact match$==` - Exact string match
- `==.*ends with this$==` - Match strings ending with phrase
- `==^(?!.*exclude).*$==` - Match anything not containing "exclude"
- `==(?-i)Case Sensitive==` - Case-sensitive matching

##### 2. Application Triggers (`triggerApps`):
- **Bundle ID**: Matches application bundle identifier (e.g., `com.apple.mail`)
- **App Name**: Matches application display name (case-insensitive)
- **Multiple Patterns**: Separated by `|`

##### 3. Mode Triggers (`triggerModes`):
- **Mode Name**: Matches Superwhisper mode name
- **Custom Modes**: User-defined modes in Superwhisper
- **Multiple Patterns**: Separated by `|`

##### 4. URL Triggers (`triggerUrls`):
- **Domain tokens** (no scheme): host suffix matching with subdomain coverage by default
- **Full URL tokens** (`http://` / `https://`): strict exact-host matching
- **Exceptions**: `!` prefix supported
- **Multiple Patterns**: Separated by `|`
- **Path/Query Prefix**: If token includes path/query, candidate URL must start with that prefix
- **Wildcard Syntax**: Explicit `*` wildcard is not supported

#### Trigger Logic (`triggerLogic`):
- **"and"**: ALL configured triggers must match
- **"or"**: ANY configured trigger can match
- **Default**: "or" if not specified
- **Validation**: Other values are rejected during configuration validation;
  the evaluator also refuses to match them defensively

#### Evaluation Process:
1. **Collect All Actions**: Inserts, URLs, Shortcuts, Shell Scripts, AppleScripts
2. **Evaluate Each Action**: Check voice, app, mode, and URL triggers
3. **Apply Logic**: Use AND/OR logic to determine matches
4. **Rank Results**: Positive actual matches use voice > mode > URL > app priority; exception-only matches are catch-alls, and more-specific required conditions, voice matches, and URLs win within the same source
5. **Return First Match**: Execute first matching action only

---

## Action Execution

### Primary File: [src/macrowhisper/Utils/ActionExecutor.swift](../../src/macrowhisper/Utils/ActionExecutor.swift)

Watcher action execution is coordinated through `ActionExecutor`. CLI execution
uses `SocketCommunication` with the same configuration and placeholder helpers;
changes to action behavior need verification in both paths.

#### Action Types:

##### 1. Insert Actions:
- **Processing**: Placeholder replacement (including placeholder transforms, regex replacements, and capture-scoped regex replacement transforms), insert runtime conditioning via `inputCondition`, then smart insertion passes (`smartCasing`, `smartPunctuation`, `smartSpacing`) when AX context is available and confident
- **Execution**: Text insertion via clipboard or keystroke simulation
- **Special Cases**:
  - `.autoPaste` hard override: `action="{{swResult}}"`, `inputCondition="!restoreClipboard|!simEsc"`, `simEsc=false`, `restoreClipboard=false`
  - `.none` hard override: `action=""`, `simEsc=false`, `restoreClipboard=false`
- **Conditional tokens**: `restoreClipboard`, `restoreClipboardDelay`, `simEsc`, `simReturn`, `nextAction`, `moveTo`, `action`, `actionDelay` (with optional `!`)
- **Input-field checks**: `inputCondition` is evaluated for each action step, so later steps can see focus changes. This differs from the frozen app and clipboard placeholder context.
- **Return timing**: `simReturn` is step-synchronous; Return is emitted before the action step completes, even for empty/`.none` inserts

##### 2. URL Actions:
- **Processing**: URL encoding, placeholder replacement
- **Execution**: Open URL with default or specified application
- **Custom App**: `openWith` parameter for specific application

##### 3. Shortcut Actions:
- **Processing**: Placeholder replacement
- **Execution**: `/usr/bin/shortcuts run <action-name> -i <temporary-file>` with UTF-8 input; `.run` omits the input file
- **Wait mode**: `scriptAsync` defaults to `true`; `false` waits up to `scriptWaitTimeout` and records nonempty trimmed stdout for downstream `actionResult` placeholders

##### 4. Shell Script Actions:
- **Processing**: Shell escaping, placeholder replacement
- **Execution**: Bash execution via `/bin/bash -c`
- **Output**: Synchronous mode captures nonempty trimmed stdout for later steps; asynchronous mode continues without a captured result

##### 5. AppleScript Actions:
- **Processing**: AppleScript escaping, placeholder replacement
- **Execution**: osascript execution via `/usr/bin/osascript`
- **Wait mode**: Shares `scriptAsync`/`scriptWaitTimeout` and stdout-result handling with shell and Shortcut actions

#### Execution Flow:
1. Resolve the current step at runtime, including conditional `nextAction` and `inputCondition`.
2. Apply the current action type's input gates and sentinel overrides.
3. Execute with clipboard synchronization and resolved options.
4. Resolve the next step dynamically from the effective `nextAction`.
5. Apply `moveTo` after the final executed step.

---

## Post-Processing

### Primary File: [src/macrowhisper/Watcher/RecordingsFolderWatcher.swift](../../src/macrowhisper/Watcher/RecordingsFolderWatcher.swift)

After action execution, several post-processing steps occur:

#### 1. MoveTo Handling:
Determines where to move or how to handle the processed recording folder:

**Resolution**:
1. **Final Action**: `null` or omitted `moveTo` inherits `config.defaults.moveTo`; explicit `""` keeps the folder in place even when that default is nonempty; a nonempty path or `.delete` overrides the default

**Special Values**:
- `".delete"`: Delete the recording folder
- **Path**: Move folder to specified directory
- **Empty value**: Keep the folder in its original location
- `.none`: An action payload template, not a `moveTo` value

#### 2. History Cleanup:
- **Trigger**: Post-processing calls `historyManager.scheduleHistoryCleanup()` with a default 30-second delay
- **Policy**: Based on `config.defaults.history`; `0` keeps the newest folder, while positive values delete folders older than the configured number of days by creation date
- **Frequency**: Requests are coalesced, and cleanup runs at most once per 24 hours within the current process

#### 3. Version Checking:
- **Delay**: 30-second delay to avoid interrupting workflow
- **Condition**: Only if version checking is enabled
- **Background**: Executed on utility queue

---

## Key Variables and Settings

### Configuration Variables ([src/macrowhisper/Config/AppConfiguration.swift](../../src/macrowhisper/Config/AppConfiguration.swift)):

The root `AppConfiguration.schema` property maps to `$schema`; it is not a
member of `defaults`. The [configuration reference](../configuration.md#global-defaults-reference)
contains the full defaults table. Important runtime settings include:

#### Global Defaults:
- `actionDelay: Double` - Default delay before action execution (default: 0.0)
- `simEsc: Bool` - Simulate ESC key before action execution (default: true)
- `restoreClipboard: Bool` - Enable clipboard restoration (default: true)
- `restoreClipboardDelay: Double` - Delay before requested clipboard restoration/finalization (default: 0.3)
- `clipboardAttachments: Bool` - Preserve supported clipboard attachments for manual-paste handoff independently of string-placeholder use (default: false)
- `activeAction: String?` - Currently active action name (supports all action types)
- `moveTo: String?` - Default folder movement behavior
- `simReturn: Bool` - Auto-press return after actions (default: false)
- `smartCasing: Bool` - Smart first-letter case normalization at insertion boundaries (default: true)
- `smartPunctuation: Bool` - Smart punctuation conflict cleanup at insertion boundaries (default: true)
- `smartSpacing: Bool` - Smart boundary spacing normalization (default: true)
- `returnDelay: Double` - Delay before pressing return (default: 0.15)
- `scheduledActionTimeout: Double` - Timeout for auto-return and scheduled actions (default: 5, 0 = no timeout)

#### Action-Specific Settings:
All action types support:
- `actionDelay: Double?` - Action-specific delay override
- `simEsc: Bool?` - Action-specific ESC simulation override
- `clipboardAttachments: Bool?` - Action-specific attachment handoff override; nullable values inherit the root default for the full chain
- `moveTo: String?` - Action-specific moveTo override
- `triggerVoice: String?` - Voice trigger patterns
- `triggerApps: String?` - Application trigger patterns
- `triggerModes: String?` - Mode trigger patterns
- `triggerUrls: String?` - Active URL trigger patterns
- `triggerLogic: String?` - Trigger combination logic ("and"/"or")
- `inputCondition: String?` - Pipe-separated conditional gates; the allowed fields depend on the action type

For inserts, `inputCondition` supports `restoreClipboard`, `restoreClipboardDelay`,
`simEsc`, `simReturn`, `nextAction`, `moveTo`, `action`, and `actionDelay`.
`!` inverts a gate. See [conditional behavior](../triggers-and-conditions.md#conditional-behavior-with-inputcondition)
for each action type's tokens and fallback behavior.

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
- **Behavior**: Missing session/group lookups return without creating a replacement original snapshot; action completion can still proceed
- **Impact**: Do not assume restoration or attachment handoff is available without tracked group state

#### 2. Clipboard Restoration Disabled:
- **Condition**: `restoreClipboard == false` for the final effective step
- **Behavior**: Skip original-snapshot restoration; a successful eligible attachment handoff can still provide the final clipboard outcome

#### 3. Input Field Detection Permission Not Granted:
- **Condition**: Accessibility permission denied during insert conditioning
- **Behavior**: Treat as `isInInputField == false` (outside-input branch)
- **Impact**: Negated tokens (`!token`) will apply; positive tokens (`token`) will fall back

#### 4. Attachment Handoff:
- **Disabled**: `clipboardAttachments: false` keeps the existing string projection unchanged.
- **Attachment-only operation**: `{{clipboardContext}}` resolves to an empty string while the operation remains eligible for supported manual-paste handoff.
- **Filtering and boundaries**: `clipboardIgnore`, `--reset-clipboard`, the pre-recording buffer, internal-write suppression, overlap invalidation, and chain execution-group ownership apply to attachments exactly as they do to text.
- **Multi-attachment interoperability**: File URLs and materialized raw images are published together as one ordered file list so first-item-only paste targets receive the complete attachment set. TIFF-only raw images are handed off as PNG files because TIFF uploads are not consistently accepted by paste targets.
- **Generated-file lifecycle**: Macrowhisper preserves existing clipboard-owned generated images across restart and retains unreferenced generations for 24 hours. The cache has a 1 GiB ceiling; expiry and capacity cleanup run only while no execution group can still need files for restoration or handoff, revalidate clipboard ownership before deletion, and reclaim expired empty UUID debris from interrupted directory creation.
- **Oversized image**: Per-image limit is 64 MiB and aggregate retention is 192 MiB. The item remains semantically an attachment, never falls back to incidental text, and is omitted from handoff with a privacy-safe diagnostic.
- **Incomplete bounded original**: If an original image cannot be retained within those limits, restoration does not write a partial or incidental-text substitute; the current clipboard is left unchanged and the omission is diagnosed.
- **CLI**: Pure CLI and `copyAction` do not hand attachments off; supported original restoration may still be shared with CLI execution.

### Meta.json Edge Cases:

#### 1. Missing Meta.json:
- **Behavior**: Watch for file creation; this watcher has no independent metadata timeout
- **Recording timeout**: A separate 17-second check recovers recordings still lacking a non-empty `.wav` or `.ogg` file
- **Cancellation**: Removing all previously detected non-empty `.wav` and `.ogg` files triggers recovery
- **Cleanup**: Remove watchers when recording folder is deleted

#### 2. Invalid Meta.json:
- **Behavior**: Continue watching for valid updates
- **Logging**: Error logged but processing continues

#### 3. Empty Results:
- **Behavior**: Continue watching for non-empty results
- **Validation**: Check for null, empty string, or missing result

### Trigger Evaluation Edge Cases:

#### 1. No Matching Triggers:
- **Behavior**: Fall back to active action processing
- **Logging**: Log that no triggers matched

#### 2. Multiple Matching Triggers:
- **Behavior**: Execute the highest-ranked actual match using voice > mode > URL > app priority
- **Tie-breaking**: Prefer more-specific required conditions, voice matches, and URLs, then sort by action name
- **Deterministic**: Consistent behavior across runs

#### 3. Exception-Only Triggers:
- **Pattern**: Only `!pattern` triggers defined
- **Behavior**: Match if no exception patterns match
- **Use Case**: Exclude specific phrases while allowing everything else
- **Priority**: Acts as a catch-all below positive trigger matches

#### 4. Missing Mode Context:
- **Behavior**: A configured mode trigger does not match when `modeName` is missing or empty, including exception-only mode rules

---

## Files and Classes Involved

### Core Processing Files:

#### 1. [src/macrowhisper/main.swift](../../src/macrowhisper/main.swift)
- **Purpose**: Application entry point, global state management
- **Key Variables**: `autoReturnEnabled`, `lastDetectedFrontApp`, global instances
- **Responsibilities**: Initialization, CLI handling, main event loop

#### 2. [src/macrowhisper/Watcher/RecordingsFolderWatcher.swift](../../src/macrowhisper/Watcher/RecordingsFolderWatcher.swift)
- **Purpose**: File system monitoring, meta.json processing, action orchestration
- **Key Methods**: `processNewRecording()`, `processMetaJson()`, `handlePostProcessing()`
- **State Management**: Processed recordings tracking, pending watchers

#### 3. [src/macrowhisper/Utils/ClipboardMonitor.swift](../../src/macrowhisper/Utils/ClipboardMonitor.swift)
- **Purpose**: Clipboard synchronization, timing coordination, smart logging, pre-recording capture
- **Key Methods**: `startEarlyMonitoring()`, `executeInsertWithEnhancedClipboardSync()`, `startActionExecution()`, `finishActionExecution()`
- **Critical Features**: Dual monitoring architecture, single shared instance, smart restoration logic, action execution boundaries
- **Architecture**: Single instance shared between RecordingsFolderWatcher and ActionExecutor to prevent duplicate monitoring

#### 4. [src/macrowhisper/Utils/ActionExecutor.swift](../../src/macrowhisper/Utils/ActionExecutor.swift)
- **Purpose**: Watcher action execution; reports the final action to the watcher for `moveTo` handling
- **Key Methods**: `executeAction()`, action-specific execution methods
- **Integration**: ClipboardMonitor coordination, placeholder processing

#### 5. [src/macrowhisper/Utils/TriggerEvaluator.swift](../../src/macrowhisper/Utils/TriggerEvaluator.swift)
- **Purpose**: Trigger evaluation, action matching
- **Key Methods**: `evaluateTriggersForAllActions()`, `triggersMatch()`
- **Logic**: Multi-criteria evaluation, exception handling

### Configuration Files:

#### 6. [src/macrowhisper/Config/AppConfiguration.swift](../../src/macrowhisper/Config/AppConfiguration.swift)
- **Purpose**: Configuration data structures, defaults, JSON schema integration
- **Action Types**: Insert, Url, Shortcut, ScriptShell, ScriptAppleScript
- **Settings**: actionDelay, simEsc, restoreClipboard, trigger configurations, all-action `inputCondition`
- **Schema Field**: `schema` property for IDE validation support

#### 7. [src/macrowhisper/Config/ConfigurationManager.swift](../../src/macrowhisper/Config/ConfigurationManager.swift)
- **Purpose**: Configuration loading, saving, live reloading, schema management
- **Thread Safety**: Dedicated configuration queue
- **Persistence**: UserDefaults integration for path management
- **Schema Integration**: Automatic schema reference management
- **Validation**: Strict `inputCondition` token validation with configuration error notifications

#### 8. [src/macrowhisper/Utils/SchemaManager.swift](../../src/macrowhisper/Utils/SchemaManager.swift)
- **Purpose**: JSON schema discovery and configuration file schema reference management
- **Schema Discovery**: Finds schema file alongside binary using multiple strategies
- **Auto-Management**: Adds/updates `$schema` reference in configuration files
- **IDE Integration**: Enables IntelliSense and validation in code editors

### Utility Files:

#### 9. [src/macrowhisper/Networking/SocketCommunication.swift](../../src/macrowhisper/Networking/SocketCommunication.swift)
- **Purpose**: CLI command handling, action execution for CLI
- **Key Methods**: `applyInsert()`, `applyInsertWithoutEsc()`, `processInsertAction()`
- **Integration**: Configuration updates, placeholder processing
- **CLI parity**: Insert CLI execution applies `inputCondition` and `.autoPaste`/`.none` hard overrides

#### 10. [src/macrowhisper/Utils/Placeholders.swift](../../src/macrowhisper/Utils/Placeholders.swift)
- **Purpose**: Dynamic content replacement
- **Placeholder Types**: XML, meta.json fields, date formatting
- **Action-Aware**: Different escaping for different action types

#### 11. [src/macrowhisper/Utils/Accessibility.swift](../../src/macrowhisper/Utils/Accessibility.swift)
- **Purpose**: macOS accessibility integration
- **Key Features**: Input field detection, keyboard simulation
- **ESC Logic**: Smart ESC handling based on application state

### Supporting Files:

#### 12. [src/macrowhisper/History/HistoryManager.swift](../../src/macrowhisper/History/HistoryManager.swift)
- **Purpose**: Recording cleanup based on retention policies
- **Cleanup Logic**: Age-based deletion with safety checks

#### 13. [src/macrowhisper/Utils/Logger.swift](../../src/macrowhisper/Utils/Logger.swift)
- **Purpose**: Comprehensive logging with file rotation
- **Global Functions**: `logDebug()`, `logInfo()`, `logWarning()`, `logError()`

---

## Development Guidelines

### When Making Changes:

1. **Clipboard Logic**: Be extremely careful with clipboard synchronization timing
2. **Action Priority**: Understand the strict priority system (auto-return > scheduled action > triggers > active action)
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
- **recentClipboardActivityWindow**: 0.5 seconds (allows skipping the short sync wait)
- **restoreClipboardDelay**: 0.3 seconds by default (configurable finalization/restoration delay)
- **CLIPBOARD_CLEANUP_GRACE**: 0.2 seconds (history-cleanup grace after action/restore timing)
- **returnDelay**: 0.15 seconds by default (configurable return key delay)

Keep fixed synchronization windows separate from configurable action, return,
and restoration delays when changing or testing timing behavior.

---

This documentation should be updated whenever significant changes are made to the processing flow, timing logic, or clipboard synchronization system. 
