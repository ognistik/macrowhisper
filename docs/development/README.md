# Macrowhisper Development Guide

[Documentation index](../README.md)

This guide covers local compilation, signed manual-test binaries, focused
regression runners, and the common source changes that affect Macrowhisper's
runtime. The [codebase map](codebase-map.md) describes ownership and the
[processing flow](processing-flow.md) follows a recording through execution.

## Quick Start

Run the commands in this guide from the repository root. Use SwiftPM for the
application compile check below. Use the Xcode project for signed
application builds, manual testing, and releases.

### SwiftPM compile check

`src/Package.swift` exposes the application sources as an executable target and
resolves the Swifter dependency. Run the package description check and build
from the repository root:

```bash
swift package --package-path src describe --type json
swift build --package-path src
```

SwiftPM writes its product under the package-local `src/.build/` directory,
using platform and configuration subdirectories. Query the exact output path
instead of assuming the host architecture:

```bash
swift build --package-path src --show-bin-path
```

For example, the default debug executable on Apple Silicon is
`src/.build/arm64-apple-macosx/debug/macrowhisper`.

This product is a bare developer executable. It does not carry the Xcode
project's configured signing identity, entitlements, application metadata, or
release packaging, so use it for compiler and dependency checks only; use the
signed Xcode build below for Accessibility/TCC, service, watcher, and other
manual runtime tests. The package has no test target. The focused regression
runners in `src/Tests/` remain separate standalone binaries and are compiled
with `swiftc` as listed below.

### Local configuration editor

The editor has two deliberately separate modes. A browser opened by
`macrowhisper --editor` or `--editor-url` connects to the daemon and writes the
canonical JSON file through authenticated, revision-checked transactions. The
connected scope is Defaults and Inserts. URL, Shortcut, Shell, and AppleScript
names come from the live snapshot, but their type-specific panels remain
read-only; only the standalone Vite preview is fixture-backed. The [user editor guide](../editor.md)
covers the workflow and [prototype guide](web-editor-prototype.md) covers the
synthetic preview.

For frontend development, install the pinned Node dependencies and build the
static output into `.build/editor`:

```bash
npm --prefix editor ci
npm --prefix editor test
npm --prefix editor run build
```

Use `swift build --package-path src --scratch-path .build/swiftpm` to keep
editor-branch compile products under the root `.build/` directory. Node is a
build dependency only; the daemon serves the bundled output and does not run a
Vite development server.

### Signed Xcode build for manual testing

The Xcode project signs local builds. Its Debug configuration uses the
`Apple Development` identity with automatic signing and team `T25AGZF6DS`;
its macOS Release configuration uses `Developer ID Application` with manual
signing and the same team. Inspect the settings before a build so the identity
and team used by Xcode remain consistent:

```bash
xcodebuild -project src/macrowhisper.xcodeproj -scheme macrowhisper -configuration Release -derivedDataPath .build/local-xcode -showBuildSettings | grep -E 'CODE_SIGN_IDENTITY|CODE_SIGN_STYLE|DEVELOPMENT_TEAM'
```

Before overwriting an existing test binary, inspect its identity and designated
requirement so you can compare them with the replacement:

```bash
LOCAL_BINARY=".build/local-xcode/Build/Products/Release/macrowhisper"
if [ -x "$LOCAL_BINARY" ]; then
  codesign -d -r- "$LOCAL_BINARY" 2>&1
  codesign --display --verbose=4 "$LOCAL_BINARY" 2>&1 | grep -E 'Identifier=|TeamIdentifier=|Authority='
fi
```

Build the frontend before the signed Xcode build. The Xcode target has a build
phase that copies `.build/editor` beside the signed local binary, so a missing
frontend build is a build error rather than a partially packaged editor:

```bash
npm --prefix editor ci
npm --prefix editor run build
xcodebuild -project src/macrowhisper.xcodeproj -scheme macrowhisper -configuration Release -derivedDataPath .build/local-xcode build
cp src/macrowhisper-schema.json .build/local-xcode/Build/Products/Release/
```

The exact manual-test resources are:

```text
.build/local-xcode/Build/Products/Release/macrowhisper
.build/local-xcode/Build/Products/Release/macrowhisper-schema.json
.build/local-xcode/Build/Products/Release/editor/index.html
.build/local-xcode/Build/Products/Release/editor/assets/...
```

Keep the matching schema beside the local binary so configuration creation and
updates can discover it. `EditorResourceResolver` finds the editor directory
beside this binary; `SchemaManager` uses the local schema and has no remote
schema fallback.

This is a manual-test build only. Building it does not install over Homebrew or
the script-installed binary, change launchd, or start/modify a service. A
connected runtime test cannot coexist with the normal singleton daemon. Record
the current state, stop that daemon yourself, launch this exact binary in the
foreground, then use another terminal to run its `--editor` command:

```bash
LOCAL_BINARY=".build/local-xcode/Build/Products/Release/macrowhisper"
INSTALLED_BINARY="$(command -v macrowhisper)"
"$INSTALLED_BINARY" --get-config
"$INSTALLED_BINARY" --service-status
"$INSTALLED_BINARY" --stop-service
"$LOCAL_BINARY" --verbose
# In another terminal, while the foreground daemon is running:
"$LOCAL_BINARY" --editor
```

The foreground process uses the selected configuration and Unix socket.
`--config` persists the normalized selection and is not an isolation switch.
To roll back, stop the manual daemon with Control-C, restore a changed path with
`"$INSTALLED_BINARY" --set-config '<recorded-path>'` (or use `--reset-config`
only when the default path was the original selection), then run
`"$INSTALLED_BINARY" --start-service` and verify
`"$INSTALLED_BINARY" --service-status`. The build procedure itself leaves the
installed files and saved configuration untouched; only the explicit manual
runtime sequence above stops and restarts the service.

Verify the identity and signature before launching it:

```bash
LOCAL_BINARY=".build/local-xcode/Build/Products/Release/macrowhisper"
LOCAL_EDITOR_DIR=".build/local-xcode/Build/Products/Release/editor"
test -x "$LOCAL_BINARY"
test -f "$LOCAL_EDITOR_DIR/index.html"
test -d "$LOCAL_EDITOR_DIR/assets"
test -n "$(find "$LOCAL_EDITOR_DIR/assets" -type f -print -quit)"
codesign -d -r- "$LOCAL_BINARY" 2>&1
codesign --display --verbose=4 "$LOCAL_BINARY" 2>&1 | grep -E 'Identifier=|TeamIdentifier=|Authority='
codesign --verify --strict --verbose=2 "$LOCAL_BINARY"
```

Compare the designated requirement and identity with the previous binary's
output. Keep the path and signing identity stable across manual-test builds.

The signature output must show the configured `Developer ID Application`
authority and team `T25AGZF6DS`. If Xcode cannot sign with that identity,
report the signing failure and stop; do not replace the binary with an ad hoc
or unsigned build. A valid signature does not grant Accessibility permission
or guarantee that macOS TCC permission survives a rebuild. Grant permission to
this exact binary in System Settings when macOS requests it, and reauthorize
after a path or signing-identity change if needed.

For debugger-oriented work, use the signed Debug configuration and the same
derived-data directory. Debug uses `Apple Development` and its output path is
`.build/local-xcode/Build/Products/Debug/macrowhisper`; inspect and verify it
with the same commands, substituting `Debug` and `Apple Development`.

### Running in Development
```bash
# Start with verbose logging
.build/local-xcode/Build/Products/Release/macrowhisper --verbose

# Use custom config for testing
.build/local-xcode/Build/Products/Release/macrowhisper --config ~/test-config.json --verbose
```

### Testing CLI Commands
```bash
# Test service management
.build/local-xcode/Build/Products/Release/macrowhisper --service-status

# Test configuration
.build/local-xcode/Build/Products/Release/macrowhisper --get-config

# Test inserts (requires running daemon)
.build/local-xcode/Build/Products/Release/macrowhisper --list-inserts
```

The commands above use the verified signed Xcode binary. They communicate
with the normal service where a command requires a daemon; do not infer a
successful compile from a service command's result.

The `--config` flag persists the normalized path for later runs and applies it
to a running daemon when possible, so it is not an isolated per-command
override. Inspect the current selection, choose a different path, or restore
the default path explicitly:

```bash
.build/local-xcode/Build/Products/Release/macrowhisper --get-config
.build/local-xcode/Build/Products/Release/macrowhisper --set-config "$HOME/test-config.json"
.build/local-xcode/Build/Products/Release/macrowhisper --reset-config
```

`--get-config` reports the saved or effective path; `--set-config` changes it;
`--reset-config` removes the saved path and returns to the default. If your
normal configuration uses a custom path, record it before testing and restore
that path with `--set-config` afterward instead of using `--reset-config`.

## Focused regression runners

The files in `src/Tests/` are standalone executables, not XCTest cases. Each
runner has an `@main` entry point and must be compiled as its own binary. Run
these commands from the repository root on macOS; Cocoa and Application
Services runners require the macOS SDK. The commands do not build the package
or start the service.

Create a disposable output directory first:

```bash
mkdir -p .build/regressions
```

Use this form for every runner:

```bash
swiftc -parse-as-library <compile-inputs> -o .build/regressions/<runner>
.build/regressions/<runner>
```

The compile inputs and runner names are:

| Runner | Compile inputs |
| --- | --- |
| `cli-clipboard-chain-state` | `src/macrowhisper/Config/AppConfiguration.swift` + `src/Tests/CLIClipboardChainStateRegression.swift` |
| `defaults-watch` | `src/macrowhisper/Config/AppConfiguration.swift` + `src/Tests/DefaultsWatchRegression.swift` |
| `config-watcher-lifecycle` | `src/macrowhisper/Watcher/ConfigChangeWatcher.swift` + `src/Tests/ConfigChangeWatcherLifecycleRegression.swift` |
| `configuration-transactions` | Add `-D CONFIGURATION_TRANSACTION_TESTING`; compile `src/macrowhisper/Config/AppConfiguration.swift` + `src/macrowhisper/Config/ConfigurationManager.swift` + `src/macrowhisper/Config/ConfigurationTransaction.swift` + `src/Tests/ConfigurationTransactionTestStubs.swift` + `src/Tests/ConfigurationTransactionRegression.swift` |
| `editor-server` | Add `-D CONFIGURATION_TRANSACTION_TESTING`; compile `src/macrowhisper/Config/AppConfiguration.swift` + `src/macrowhisper/Config/ConfigurationManager.swift` + `src/macrowhisper/Config/ConfigurationTransaction.swift` + `src/Tests/ConfigurationTransactionTestStubs.swift` + `src/macrowhisper/Networking/EditorServer.swift` + `src/Tests/EditorServerRegression.swift` |
| `action-chain-validation` | `src/macrowhisper/Config/AppConfiguration.swift` + `src/macrowhisper/Config/ConfigurationManager.swift` + `src/macrowhisper/Config/ConfigurationTransaction.swift` + `src/Tests/ConfigurationValidationTestStubs.swift` + `src/Tests/ActionChainValidationRegression.swift` |
| `input-condition-validation` | `src/macrowhisper/Config/AppConfiguration.swift` + `src/macrowhisper/Config/ConfigurationManager.swift` + `src/macrowhisper/Config/ConfigurationTransaction.swift` + `src/Tests/ConfigurationValidationTestStubs.swift` + `src/Tests/InputConditionValidationRegression.swift` |
| `recording-reference-selection` | `src/macrowhisper/Utils/RecordingReferenceResolver.swift` + `src/Tests/RecordingReferenceSelectionRegression.swift` (the runner supplies its manager/watcher stubs) |
| `recording-metadata-settle-policy` | `src/macrowhisper/Utils/RecordingMetadataSettlePolicy.swift` + `src/Tests/RecordingMetadataSettlePolicyRegression.swift` |
| `sim-return-behavior` | `src/macrowhisper/Utils/SimReturnBehavior.swift` + `src/Tests/SimReturnBehaviorRegression.swift` |
| `smart-insert-boundary` | `src/macrowhisper/Utils/SmartInsertBoundary.swift` + `src/Tests/SmartInsertBoundaryRegression.swift` |
| `smart-insert-heuristics` | `src/macrowhisper/Utils/SmartInsertBoundary.swift` + `src/macrowhisper/Utils/SmartInsertHeuristics.swift` + `src/Tests/SmartInsertHeuristicsRegression.swift` |
| `browser-url-normalization` | `src/macrowhisper/Utils/BrowserURLNormalization.swift` + `src/Tests/BrowserURLNormalizationRegression.swift` |
| `trigger-priority` | `src/macrowhisper/Utils/TriggerEvaluator.swift` + `src/Tests/TriggerEvaluatorUrlMatchingTestStubs.swift` + `src/Tests/TriggerPriorityRegression.swift` |
| `trigger-url-matching` | `src/macrowhisper/Utils/TriggerEvaluator.swift` + `src/Tests/TriggerEvaluatorUrlMatchingTestStubs.swift` + `src/Tests/TriggerUrlMatchingRegression.swift` |
| `trigger-logic-validation` | `src/macrowhisper/Config/AppConfiguration.swift` + `src/macrowhisper/Config/ConfigurationManager.swift` + `src/macrowhisper/Config/ConfigurationTransaction.swift` + `src/Tests/ConfigurationValidationTestStubs.swift` + `src/Tests/TriggerLogicValidationRegression.swift` |
| `placeholder-regex-pipeline` | `src/macrowhisper/Utils/Placeholders.swift` + `src/Tests/PlaceholderPipelineTestStubs.swift` + `src/Tests/PlaceholderRegexPipelineRegression.swift` |
| `app-vocabulary-extraction` | `src/macrowhisper/Utils/AppVocabulary.swift` + `src/Tests/AppVocabularyTestStubs.swift` + `src/Tests/AppVocabularyExtractionRegression.swift` |
| `clipboard-transient-activity` | `src/macrowhisper/Utils/ClipboardMonitor.swift` + `src/Tests/ClipboardMonitorTestStubs.swift` + `src/Tests/ClipboardTransientActivityRegression.swift` |
| `clipboard-attachments` | `src/macrowhisper/Utils/ClipboardMonitor.swift` + `src/Tests/ClipboardMonitorTestStubs.swift` + `src/Tests/ClipboardAttachmentsRegression.swift` |
| `superwhisper-folder-recovery` | `src/macrowhisper/Watcher/SuperwhisperFolderWatcher.swift` + `src/Tests/SuperwhisperFolderWatcherRecoveryRegression.swift` |

For example, the configuration and clipboard runners can be compiled as
follows (repeat the same pattern for the other rows):

```bash
swiftc -parse-as-library \
  src/macrowhisper/Config/AppConfiguration.swift \
  src/macrowhisper/Config/ConfigurationManager.swift \
  src/macrowhisper/Config/ConfigurationTransaction.swift \
  src/Tests/ConfigurationValidationTestStubs.swift \
  src/Tests/InputConditionValidationRegression.swift \
  -o .build/regressions/input-condition-validation
.build/regressions/input-condition-validation

swiftc -parse-as-library \
  src/macrowhisper/Utils/ClipboardMonitor.swift \
  src/Tests/ClipboardMonitorTestStubs.swift \
  src/Tests/ClipboardTransientActivityRegression.swift \
  -o .build/regressions/clipboard-transient-activity
.build/regressions/clipboard-transient-activity
```

### Testing Insert `inputCondition`
- Configure an insert with `inputCondition` and test watcher flow and CLI flow (`--exec-action`).
- Verify both input states (inside and outside input field) for positive and negated tokens:
  - `restoreClipboard`, `!restoreClipboard`
  - `restoreClipboardDelay`, `!restoreClipboardDelay`
  - `simEsc`, `!simEsc`
  - `simReturn`, `!simReturn`
  - `nextAction`, `!nextAction`
  - `moveTo`, `!moveTo`
  - `action`, `!action`
  - `actionDelay`, `!actionDelay`
- Verify strict validation behavior:
  - Invalid tokens, whitespace, empty segments (`||`), or malformed `!` should fail config validation.
  - A configuration error notification should be emitted and defaults used until fixed.
- Verify sentinel compatibility:
  - `action: ".autoPaste"` and `action: ".none"` must ignore user sibling overrides and apply built-in hard templates.

### Testing Script Wait Modes
- For `shortcuts`, `scriptsShell`, and `scriptsAS` actions:
  - `scriptAsync = true` should launch and continue chain immediately.
  - `scriptAsync = false` should wait up to `scriptWaitTimeout` seconds.
  - `{{actionResult}}` and `{{actionResult:N}}` should resolve stdout from prior synchronous script steps in the same execution group.

### Testing Clipboard Attachments
- `defaults.clipboardAttachments` defaults to `false`; an action-level `null` or omission inherits it, and the effective root value remains fixed for the full chain.
- With attachments disabled, the existing string projection is unchanged. `{{clipboardContext}}` remains string-only; an attachment-only operation expands to an empty placeholder.
- With attachments enabled, a successfully executed watcher action is eligible for native handoff even when its template does not use `{{clipboardContext}}`; the placeholder remains string-only and independent.
- Handoff is for a later manual paste only. A successful eligible chain hands off attachments even when the final step has `restoreClipboard: false`; failed, cancelled, and structurally invalid chains do not.
- Verify operation grouping by `NSPasteboard.changeCount`, ordered text/file URLs/PNG/TIFF, reset and `clipboardIgnore` boundaries, the pre-recording buffer, internal-write suppression, overlap ownership, and finalization across chains.
- Verify single-item image providers whose PNG/TIFF representation is available only at pasteboard level, including Finder Get Info icons with an ICNS-only item. Capture must retain the supported image and use the existing PNG handoff, preserve file-URL precedence, avoid duplicating multi-item operations, and apply the same image retention limits.
- Verify that late image bytes can repair an accepted empty/missing-data observation at the same change count without refreshing its age, duplicating it, reviving reset/ignored observations, or reversing deliberate eviction. Session repair must work without the global pre-recording buffer.
- Verify final handoff exposes every attachment through one eager ordered Finder filename array from which AppKit synthesizes file URLs: existing files stay borrowed, raw PNG is validated and retained exactly, raw TIFF is transcoded to a decodable PNG for target compatibility, mixed ordering is preserved, and no raw image type is advertised as the primary handoff. Generated images remain cached for 24 hours after clipboard ownership ends unless still referenced.
- Verify generated files survive while an existing generated file is referenced by the clipboard and across service restart, are not deleted during an active restoration/handoff group, and remain for 24 hours after clipboard ownership ends before expiry cleanup. Stale clipboard paths must not refresh retention, destructive cleanup must revalidate clipboard ownership, expired empty UUID debris from interrupted creation is reclaimed, and nonempty unmarked directories remain untouched. The 1 GiB cache ceiling removes the oldest unreferenced generations first and must never touch borrowed user files.
- Verify the 64 MiB per-image and 192 MiB aggregate limits. Oversized items stay classified as attachments, never fall back to incidental text, and emit diagnostics without clipboard content, image bytes, or private paths.
- Pure CLI execution and `copyAction` must not hand attachments off. CLI original-clipboard restoration may still use the supported representations.

## Common Development Tasks

### Adding New CLI Commands
1. Add the command enum in `SocketCommunication.swift`
2. Add the command handler in the switch statement
3. Add the CLI argument parsing in `main.swift`
4. Update the help text in `printHelp()`
5. Update the [CLI reference](../cli-reference.md), affected topic pages, and relevant regression coverage

### Adding New Action Types
1. Define the action struct in `AppConfiguration.swift`
2. Add the processing logic in `ActionExecutor.swift`
3. Add trigger evaluation in `TriggerEvaluator.swift`
4. Add CLI management commands in `SocketCommunication.swift`
5. Update the JSON schema, validation, [action reference](../actions.md), and relevant regression coverage

### Adding New Placeholders
1. Add the placeholder logic in `processDynamicPlaceholders()` in `Placeholders.swift`
2. If using accessibility APIs, add the function to `Accessibility.swift`
3. For session-based placeholders, enhance `ClipboardMonitor` and `ActionExecutor`
4. Update the [placeholder reference](../placeholders-and-context.md) and the [codebase map](codebase-map.md)
5. Test with various action types and escaping scenarios

#### Context placeholders used during development

The [placeholder reference](../placeholders-and-context.md) is the complete
catalog. These examples highlight context sources relevant to runtime work.

**Session-Based Placeholders** (captured during recording):
- `{{selectedText}}` - Text selected when recording starts (early capture)
- `{{clipboardContext}}` - String projection of eligible clipboard operations during the recording session (supports stacking)
- `{{appContext}}` - Structured app context (captured on-demand, anchored to chain app snapshot)
- `{{appVocabulary}}` - Names/terms/identifiers from app accessibility content (captured on-demand, anchored to chain app snapshot)
- `{{folderName}}` / `{{folderPath}}` - Most recent active folder (or latest valid completed folder)
- `{{folderName:<index>}}` / `{{folderPath:<index>}}` - Indexed folder lookup by recency (`0`, `1`, `2`, ...)

**Usage Examples:**
- `{{selectedText}}` - Gets selected text with action-type escaping
- `{{json:selectedText}}` - Gets selected text with JSON escaping
- `{{raw:selectedText}}` - Gets selected text with no escaping
- `{{selectedText||\\n||newline}}` - Gets selected text and replaces newlines
- `{{clipboardContext}}` - Selected or stacked text from eligible clipboard operations during recording
- `{{appContext}}` - Structured app context (app name, window, URL, input content)
- `{{appVocabulary}}` - Comma-separated app vocabulary terms (names, nouns, identifiers)
- `{{folderName:1}}` - Previous recording folder name
- `{{folderPath:0}}` - Current/latest recording folder path

#### Implementation Notes:
- **selectedText**: Captured immediately when recording folder appears (if text is selected)
- **clipboardContext**: Captured from clipboard monitoring session (works regardless of restoreClipboard setting)
  - **Stacking**: The root action's nullable `clipboardStacking` override falls back to `defaults.clipboardStacking` and applies to the full chain
  - **Attachments**: The root action's nullable `clipboardAttachments` override falls back to `defaults.clipboardAttachments` (`false`) and applies to the full chain; successful watcher execution enables manual-paste handoff independently of `{{clipboardContext}}` use
  - **Filtering**: Empty and Superwhisper-result entries are removed before choosing either the single or stacked representation
  - **Single change**: Returns content without XML tags (maintains current behavior)
  - **Multiple changes**: Returns all changes with XML tags (`<clipboard-context-1>`, `<clipboard-context-2>`, etc.)
  - **Attachment-only changes**: Keep their attachment classification but yield an empty string placeholder; supported handoff representations are ordered text, file URLs, PNG, and TIFF
  - **Latest-operation selection**: With stacking disabled, a later text copy supersedes an earlier attachment and a later attachment produces an empty text projection while remaining the handoff candidate
- **appContext**: Only captured when placeholder is used in action (performance optimization)
- **appVocabulary**: Only captured when placeholder is used in action; uses bounded accessibility traversal
- **frontApp/appContext/appVocabulary consistency**: In watcher flow, app identity is frozen once before first action step (`frontAppName`/`frontAppBundleId`/`frontAppPid`). `appContext` and `appVocabulary` resolve lazily on first use, then are reused for the full chain.
- **CLI behavior**: Context placeholders are resolved live at CLI execution time.

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
- Use `--verbose` for debug logging; it also disables redaction for that daemon run without changing the saved configuration
- Check logs in `~/Library/Logs/Macrowhisper/`
- Use `--version-state` to debug update checker
- Test socket health with `--status`

### Developer diagnostics

`--debug-ax-tree` runs without a daemon and writes the front application's
Accessibility tree to the log with redaction disabled. Use it to inspect what
context the accessibility helpers can read.

The hidden `--test-update-dialog` command previews an update dialog without
requiring the daemon. `--test-version` and `--test-description` customize its
contents:

```bash
.build/local-xcode/Build/Products/Release/macrowhisper \
  --test-update-dialog \
  --test-version 2.1.2 \
  --test-description "Preview release notes."
```

Use the [release helper's preview step](releasing.md) when previewing the
actual changelog for a release. The runtime commands `--version-state` and
`--version-clear` require the daemon; the latter resets persisted update-check
and reminder state.

## Architecture Notes

- Queue ownership varies by component. Watcher event handling and UI work use
  the main queue in several paths, ClipboardMonitor protects session state with
  its concurrent queue and barrier operations, and asynchronous scripts,
  networking, and other work use background queues. Preserve each component's
  existing dispatch and synchronization boundaries.
- Configuration changes trigger live reloads
- Socket communication handles both CLI and daemon interactions
- ClipboardMonitor coordinates with Superwhisper timing
- Insert chains resolve next actions at runtime (not precomputed) to support conditional `nextAction`.
- Input-field state for conditional behavior is evaluated live per executed step.
- Attachment context and the original clipboard snapshot are separate; final attachment handoff/restoration occurs only at execution-group finalization, never between chain steps.

See the [codebase map](codebase-map.md) for detailed architecture documentation.
