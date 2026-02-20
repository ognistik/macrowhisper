# Macrowhisper Complete Documentation

This guide is intentionally detailed.

If someone has never used Macrowhisper before, they should be able to read this file and understand:

- how Macrowhisper thinks
- how actions are chosen
- what every important setting does
- how triggers and placeholders work
- how clipboard/context capture timing works
- how to debug real problems

Macrowhisper works with [Superwhisper](https://superwhisper.com/?via=robert). It watches Superwhisper recordings and executes automations based on your config.

---

## Table of Contents

1. What Macrowhisper Is
2. Quick Start
3. How Macrowhisper Processes a Dictation (Execution Flow)
4. Command Reference
5. Configuration File Fundamentals
6. Global Defaults Reference
7. Action Types (Insert, URL, Shortcut, Shell, AppleScript)
8. Trigger System (Voice, App, Mode)
9. Input Conditions (`inputCondition`) Deep Dive
10. Chaining Actions (`nextAction`) Deep Dive
11. Placeholders Deep Dive
12. Context Capture Timing (selected text, clipboard, app context)
13. Regex Replacements
14. Contextual Escaping
15. Clipboard System Deep Dive
16. Recording File Handling (`moveTo`, `history`)
17. Advanced Runtime Behavior Notes
18. Full Config Examples
19. Troubleshooting
20. Updating and Version Checks
21. Full Uninstall
22. Final Learning Path

---

## 1) What Macrowhisper Is

Macrowhisper is the layer that turns Superwhisper dictation into repeatable workflows.

Superwhisper is excellent at capturing voice.  
Macrowhisper is what makes that voice useful beyond plain paste.

### Why learn Macrowhisper

- It removes repetitive post-dictation steps.
- It makes voice workflows predictable and repeatable.
- It lets you decide different behavior by phrase, app, and mode.
- It scales from simple setup to advanced automations without changing tools.

### Without vs with Macrowhisper

Without Macrowhisper:

1. Dictate text.
2. Manually copy/edit/clean it.
3. Switch apps.
4. Run shortcuts/scripts manually.
5. Repeat that process many times per day.

With Macrowhisper:

1. Dictate once.
2. Matching logic picks the right action.
3. Action runs immediately (insert, URL, shortcut, shell, or AppleScript).
4. Optional chained steps run automatically.
5. Clipboard and post-processing are handled consistently.

### Real examples

Example 1: Voice command -> web action

- You say: `google best mechanical keyboard for mac`.
- `triggerVoice` matches `google`.
- Macrowhisper strips the trigger word and opens:
  `https://www.google.com/search?q=best mechanical keyboard for mac`

Example 2: Dictation -> structured writing template

- You dictate in a writing mode.
- Insert action pastes a consistent structure: opening text, your dictation (`{{swResult}}`), and closing/signature text.
- Result: consistent output format every time.

Example 3: Dictation -> shortcut pipeline

- You dictate task details.
- Shortcut action sends `{{swResult}}` to a macOS Shortcut.
- Shortcut creates a task in your task app.
- Optional `nextAction` opens the related project page.

Example 4: Dictation -> script execution

- You dictate: `log this release note`.
- Shell action writes processed text to a file.
- Same format, same destination, no manual copy/paste.

### What Macrowhisper actually does each time

1. Superwhisper writes a recording folder and `meta.json`.
2. Macrowhisper validates required result fields.
3. Macrowhisper captures and enriches context (front app, selected text, clipboard context).
4. Macrowhisper resolves action priority (auto-return, scheduled, triggers, active action).
5. Macrowhisper executes action(s), handles clipboard restoration rules, and applies post-processing.

### Action types it can execute

- Insert actions (paste/type text)
- URL actions (open links/apps)
- Shortcut actions (run macOS Shortcuts)
- Shell actions
- AppleScript actions

---

## 2) Quick Start

### Install (Homebrew)

```bash
brew install ognistik/formulae/macrowhisper
```

### Install (Script)

```bash
curl -L https://raw.githubusercontent.com/ognistik/macrowhisper/main/scripts/install.sh | sh
```

### Open or create config

```bash
macrowhisper --reveal-config
```

Default path:

`~/.config/macrowhisper/macrowhisper.json`

### Configure Superwhisper (important)

Recommended Superwhisper settings:

- Recording Window: ON
- Paste Result Text: OFF
- Restore Clipboard After Paste: OFF
- Simulate Key Presses: OFF

Why: Macrowhisper should be the single source of truth for paste/clipboard/key behavior.

### Start service

```bash
macrowhisper --start-service
```

Check service:

```bash
macrowhisper --service-status
```

### First test

Dictate once in a normal text field. By default, Macrowhisper creates `autoPaste` and sets it as `defaults.activeAction`.

---

## 3) How Macrowhisper Processes a Dictation (Execution Flow)

This section is the most important mental model.

### Step A: Recording session starts

When a recording folder appears, Macrowhisper starts early monitoring and captures context:

- selected text at session start
- clipboard state at session start
- clipboard history from the pre-recording buffer window (`clipboardBuffer` seconds before session)

### Step B: Wait for valid result data

Macrowhisper waits until `meta.json` has valid result fields:

- if `languageModelName` exists and is non-empty, it requires `llmResult` and `result`
- otherwise, it requires `result`

### Step C: Add runtime context

Before action evaluation/execution, Macrowhisper enriches metadata with:

- front app name / bundle ID
- session selected text
- session clipboard context

### Step D: Optional bypass by mode

If `defaults.bypassModes` matches the current mode (`modeName`, case-insensitive), Macrowhisper skips all processing.

### Step E: Priority-based action selection

Priority order:

1. One-time `--auto-return`
2. One-time `--schedule-action`
3. Trigger matches (`triggerVoice`, `triggerApps`, `triggerModes`)
4. `defaults.activeAction`
5. No action

### Step F: Action execution + chain resolution

If an action runs, Macrowhisper can chain to next actions with `nextAction` rules.

### Step G: Post-processing

After action completion:

- recording folder move/delete behavior according to resolved `moveTo`
- cleanup of monitoring state
- clipboard cleanup protections to avoid cross-session contamination
- periodic history cleanup (if enabled)

---

## 4) Command Reference

## General commands

```bash
macrowhisper --help
macrowhisper --version
```

## Configuration management (no running daemon required)

```bash
macrowhisper --reveal-config
macrowhisper --get-config
macrowhisper --set-config /path/to/folder-or-file
macrowhisper --reset-config
macrowhisper --update-config
macrowhisper --schema-info
```

Notes:

- `--set-config` persists the path.
- If you pass a directory, Macrowhisper uses `<dir>/macrowhisper.json`.
- `--update-config` refreshes config formatting/schema-compatible fields.

## Service management

```bash
macrowhisper --install-service
macrowhisper --start-service
macrowhisper --stop-service
macrowhisper --restart-service
macrowhisper --uninstall-service
macrowhisper --service-status
```

## Runtime commands (require running daemon)

```bash
macrowhisper --status
macrowhisper --action [<name>]
macrowhisper --get-action [<name>]
macrowhisper --exec-action <name>
macrowhisper --schedule-action [<name>]
macrowhisper --auto-return <true/false>
macrowhisper --get-icon
macrowhisper --check-updates
```

Behavior notes:

- `--action <name>` sets `defaults.activeAction`.
- `--action` with no name clears active action.
- `--get-action` with no name returns active action name.
- `--get-action <name>` returns the processed action content using the latest valid result.
- `--exec-action <name>` runs the action once using latest valid result.
- `--schedule-action <name>` schedules one action for the next recording.
- `--schedule-action` (no name) cancels scheduled action.
- `--auto-return true` schedules one-time "paste result + return behavior" for the next recording.
- `--auto-return` with no value behaves like `true`.

## Action management commands

```bash
macrowhisper --list-actions
macrowhisper --list-inserts
macrowhisper --list-urls
macrowhisper --list-shortcuts
macrowhisper --list-shell
macrowhisper --list-as

macrowhisper --add-insert <name>
macrowhisper --add-url <name>
macrowhisper --add-shortcut <name>
macrowhisper --add-shell <name>
macrowhisper --add-as <name>

macrowhisper --remove-action <name>
```

Important: action names must be unique across all action types.

## Deprecated but still accepted

```bash
macrowhisper --insert [<name>]
macrowhisper --get-insert [<name>]
macrowhisper --exec-insert <name>
```

Prefer:

- `--action`
- `--get-action`
- `--exec-action`

---

## 5) Configuration File Fundamentals

## Top-level shape

```json
{
  "$schema": "file:///path/to/macrowhisper-schema.json",
  "defaults": {},
  "inserts": {},
  "urls": {},
  "shortcuts": {},
  "scriptsShell": {},
  "scriptsAS": {}
}
```

About `$schema`:

- Macrowhisper manages this automatically when saving config.
- It helps editors/IDEs validate JSON and suggest keys.
- In normal use, you should not need to edit this manually.

## Value semantics: defaults vs per-action overrides

Use this simple model:

- `defaults` = your normal behavior.
- Action-level values = one action can override `defaults`.
- Some empty values mean "use defaults again", but not all fields work the same.

Three words used in this guide:

- `inherit`: use `defaults` for that field.
- `empty payload`: run this action with no content.
- `template`: a special string (like `.none`) that sets multiple fields for you.

### 5.1 Quick rules (what wins?)

| Field type | If action value is empty/`null` | If action value is set |
| --- | --- | --- |
| Boolean/number overrides (`noEsc`, `restoreClipboard`, `actionDelay`, `pressReturn`, `simKeypress`, `smartInsert`) | Use `defaults.<sameField>` | Action value wins |
| `moveTo` | `""` or `null` -> use `defaults.moveTo` | Action value wins (`.none`, `.delete`, or a path) |
| `icon` | `""` or `null` -> use `defaults.icon` | Action value wins (`.none` means "show no icon") |
| `action` payload | `""` -> empty payload (does **not** inherit from `defaults`) | Non-empty payload is executed after placeholders |

Important:

- `action` does not have fallback-to-default behavior.
- `action: ""` means empty payload.
- `action: ".none"` means apply a template (next section).

Special `action` values:

- `action: ".none"` -> apply the no-op template (section 5.2)
- Insert only: `action: ".autoPaste"` -> apply the autoPaste template (section 5.3)
- Shortcut only: `action: ".run"` -> run shortcut with no input payload

### 5.2 What `action: ".none"` actually does

For insert/url/shortcut/shell/AppleScript actions, `.none` is converted to:

- `action = ""`
- `inputCondition = ""`
- `noEsc = true`
- `restoreClipboard = false`

Important:

- `action: ""` and `action: ".none"` are different.
- `""` only means "empty payload" (no template behavior).
- `.none` also forces `noEsc=true` and `restoreClipboard=false`.

### 5.3 What insert `action: ".autoPaste"` actually does

For insert actions only, `.autoPaste` sets:

- `inputCondition = "!restoreClipboard|!noEsc"`
- `noEsc = true`
- `restoreClipboard = false`

Then `inputCondition` is checked:

- If you are **outside** an input field:
  - `noEsc=true` stays active
  - `restoreClipboard=false` stays active
- If you are **inside** an input field:
  - `noEsc` is cleared and falls back to `defaults.noEsc`
  - `restoreClipboard` is cleared and falls back to `defaults.restoreClipboard`

So `.autoPaste` is not just a label. It applies both template values and conditional fallback behavior.

### 5.4 Quick real-world examples

```json
"action": ""
```

Meaning: this action runs with no payload.

```json
"action": ".none"
```

Meaning: no-op template (`action=""`, `noEsc=true`, `restoreClipboard=false`).

```json
"restoreClipboard": null
```

Meaning: inherit `defaults.restoreClipboard`.

### 5.5 Empty/null string values that mean "disabled"

| Field | Empty/`null` means |
| --- | --- |
| `defaults.activeAction` | No fallback action |
| `defaults.nextAction` | No global first-step chain override |
| `defaults.bypassModes` | Bypass-mode feature off |
| `defaults.clipboardIgnore` | No app-ignore regex for clipboard capture |
| `triggerVoice` / `triggerApps` / `triggerModes` | That trigger type is not configured for this action |

### 5.6 Special string values cheat sheet

- `.none` -> no-op template (`noEsc=true`, `restoreClipboard=false`)
- `.autoPaste` -> insert-only template + input-field conditional behavior
- `.delete` -> `moveTo` should delete processed recording folder
- `.run` -> shortcut runs without input payload

## Minimal starter config

```json
{
  "defaults": {
    "watch": "~/Documents/superwhisper",
    "activeAction": "autoPaste",
    "actionDelay": 0,
    "restoreClipboard": true
  },
  "inserts": {
    "autoPaste": {
      "action": ".autoPaste"
    }
  },
  "urls": {},
  "shortcuts": {},
  "scriptsShell": {},
  "scriptsAS": {}
}
```

---

## 6) Global Defaults Reference

These live under `defaults`.

| Key | Type | Default | Meaning |
| --- | --- | --- | --- |
| `watch` | string | `~/Documents/superwhisper` | Path to Superwhisper folder (the one containing `recordings`). |
| `noUpdates` | bool | `false` | Disable periodic update checks. |
| `noNoti` | bool | `false` | Disable notifications. |
| `activeAction` | string/null | `"autoPaste"` | Fallback action when no trigger matches. Empty/null means none. |
| `icon` | string/null | `""` | Default icon for actions. `.none` forces no icon. |
| `moveTo` | string/null | `""` | Default post-processing path, `.delete`, `.none`, or empty fallback. |
| `noEsc` | bool | `false` | Disable ESC simulation before actions. |
| `simKeypress` | bool | `false` | Insert by typing instead of clipboard paste (insert actions). |
| `smartInsert` | bool | `true` | Smart casing/spacing behavior for insert actions. |
| `actionDelay` | number | `0` | Delay before action execution. |
| `history` | int/null | `null` | History retention in days. `0` keeps only newest recording folder. |
| `pressReturn` | bool | `false` | Press Return after insert execution. |
| `returnDelay` | number | `0.1` | Delay before Return press. |
| `restoreClipboard` | bool | `true` | Restore original clipboard at end of action flow. |
| `scheduledActionTimeout` | number | `5` | Timeout (seconds) for pending auto-return/scheduled action when no recording starts. `0` means no timeout. |
| `clipboardStacking` | bool | `false` | Capture multiple clipboard events for `{{clipboardContext}}`. |
| `clipboardBuffer` | number | `5.0` | Pre-recording clipboard capture window in seconds. `0` disables buffer capture. |
| `clipboardIgnore` | string/null | `""` | Regex for apps ignored in clipboard capture. |
| `bypassModes` | string/null | `""` | Pipe-separated Superwhisper mode names that bypass Macrowhisper entirely (case-insensitive). |
| `autoUpdateConfig` | bool | `true` | Auto-refresh config format/schema fields at startup. |
| `redactedLogs` | bool | `true` | Redact sensitive content in logs. |
| `nextAction` | string/null | `""` | Default next action chain target (first-step override). |

## Validation rules involving defaults

- `defaults.activeAction` must exist if not empty.
- `defaults.nextAction` must exist if not empty.
- `defaults.activeAction` cannot equal `defaults.nextAction`.

---

## 7) Action Types

All actions are stored by name in one of five dictionaries:

- `inserts`
- `urls`
- `shortcuts`
- `scriptsShell`
- `scriptsAS`

### Cross-type rule

Action names must be unique across all five dictionaries.

### Common fields across all action types

| Field | Type | Meaning |
| --- | --- | --- |
| `action` | string | Main action payload (text/url/script/etc.) |
| `icon` | string/null | Per-action icon override |
| `moveTo` | string/null | Per-action recording folder post-processing override |
| `noEsc` | bool/null | Per-action ESC behavior override |
| `actionDelay` | number/null | Per-action delay override |
| `restoreClipboard` | bool/null | Per-action clipboard restoration override |
| `inputCondition` | string/null | Token-based conditional gating of selected action fields |
| `nextAction` | string/null | Chain to another action |
| `triggerVoice` | string/null | Voice trigger patterns |
| `triggerApps` | string/null | Front app name/bundle regex trigger |
| `triggerModes` | string/null | Superwhisper mode trigger |
| `triggerLogic` | string/null | `or` or `and` |

How to read these fields in practice:

- For bool/number override fields, `null` means fallback to `defaults`.
- For `moveTo` and `icon`, empty/null means fallback to defaults.
- For `action`, empty string means empty payload for that step (not template behavior).
- For `action`, `.none` and `.autoPaste` (insert only) are template behaviors.
- `inputCondition` can neutralize fields at runtime before execution.
- `trigger*` fields only decide matching; they do not modify payload content.

### Common field examples

```json
"icon": "🧠"
```

```json
"icon": ".none"
```

```json
"moveTo": ".delete"
```

```json
"actionDelay": 0.25
```

```json
"restoreClipboard": null
```

## 7.1 Insert actions

Insert-only extra fields:

- `simKeypress` (bool/null)
- `smartInsert` (bool/null)
- `pressReturn` (bool/null)

Insert field reference:

| Field | Type | Typical values | Notes |
| --- | --- | --- | --- |
| `action` | string | `"{{swResult}}"`, `".autoPaste"`, `".none"` | Main inserted content/template. |
| `simKeypress` | bool/null | `true`, `false`, `null` | `true` types characters; slower but useful where paste is blocked. |
| `smartInsert` | bool/null | `true`, `false`, `null` | Smart punctuation/casing/spacing adjustments. |
| `pressReturn` | bool/null | `true`, `false`, `null` | Return key after insert. |
| `noEsc` | bool/null | `true`, `false`, `null` | Skip ESC before action if `true`. |
| `inputCondition` | string/null | `"action|smartInsert"`, `"!action|!pressReturn"` | Conditional option gating. |

Example:

```json
"emailDraft": {
  "action": "Hi,\n\n{{swResult}}\n\nThanks,",
  "pressReturn": false,
  "actionDelay": 0.1,
  "triggerModes": "email"
}
```

`action` semantics for insert actions are defined in section 5.

Insert reminders:

- `.autoPaste` = insert-only template with input-field-aware behavior (section 5.3).
- `.none` = no-op template (section 5.2).
- `""` = empty payload, not template.
- If you need guaranteed `noEsc=true` and `restoreClipboard=false`, use `.none` (not `""`).

Practical `.autoPaste` use:

```json
"autoPaste": {
  "action": ".autoPaste",
  "icon": "•"
}
```

Practical no-op insert use:

```json
"showOnlyInWindow": {
  "action": ".none",
  "triggerModes": "assistant"
}
```

## 7.2 URL actions

URL-only extra fields:

- `openWith` (string/null) - app name, app path, or bundle ID used with `open`
- `openBackground` (bool/null) - open without focus (`open -g` behavior)

URL field reference:

| Field | Type | Typical values | Notes |
| --- | --- | --- | --- |
| `action` | string | `"https://...{{swResult}}"`, `".none"` | URL template. Empty/`.none` skips URL opening. |
| `openWith` | string/null | `"Safari"`, `"/Applications/Google Chrome.app"`, `"com.google.Chrome"` | Passed to `open -a`. |
| `openBackground` | bool/null | `true`, `false`, `null` | `true` opens in background. `false` or `null` resolves to foreground behavior. |

Example:

```json
"searchGoogle": {
  "action": "https://www.google.com/search?q={{swResult}}",
  "openWith": "Safari",
  "openBackground": false,
  "triggerVoice": "google|search"
}
```

Another URL example with punctuation cleanup:

```json
"searchDocs": {
  "action": "https://developer.apple.com/search/?q={{swResult||\\.$||}}",
  "openBackground": true
}
```

`action` semantics are the same as section 5:

- `.none` = no-op template.
- `""` = empty payload (URL open is skipped).
- `noEsc` / `restoreClipboard` still follow normal resolution unless template forces values.

## 7.3 Shortcut actions

Important: the action name is the macOS Shortcut name.

Shortcut field reference:

| Field | Type | Typical values | Notes |
| --- | --- | --- | --- |
| `action` | string | `"{{swResult}}"`, `".run"`, `".none"` | Input sent to shortcut. `.run` executes shortcut without input. |
| `triggerVoice` | string/null | `"task"`, `"==^todo\\\\s+(.+)$=="` | Optional trigger entry points. |

Example:

```json
"Create Note": {
  "action": "{{swResult}}"
}
```

Shortcut-specific reminder:

- `.run` = run shortcut with no input payload.

Other `action` semantics come from section 5:

- `.none` = no-op template.
- `""` = empty payload.
- `noEsc` / `restoreClipboard` still follow normal resolution unless template forces values.

Shortcut examples:

```json
"Create Task": {
  "action": "{{swResult}}",
  "triggerVoice": "task"
}
```

```json
"Refresh Dashboard": {
  "action": ".run",
  "triggerVoice": "refresh dashboard"
}
```

## 7.4 Shell actions

Shell field reference:

| Field | Type | Typical values | Notes |
| --- | --- | --- | --- |
| `action` | string | `"echo '{{swResult}}' | pbcopy"`, `".none"` | Shell command string. |
| `triggerApps` | string/null | `"Terminal|iTerm"` | Useful to scope command actions by app. |

Example:

```json
"copyResult": {
  "action": "echo '{{swResult}}' | pbcopy",
  "triggerVoice": "copy result"
}
```

`action` semantics are the same as section 5:

- `.none` = no-op template.
- `""` = empty payload (shell execution is skipped).
- `noEsc` / `restoreClipboard` still follow normal resolution unless template forces values.

Shell example with metadata key:

```json
"logMode": {
  "action": "echo 'Mode: {{modeName}} | Text: {{swResult}}' >> ~/Desktop/mw-log.txt"
}
```

## 7.5 AppleScript actions

AppleScript field reference:

| Field | Type | Typical values | Notes |
| --- | --- | --- | --- |
| `action` | string | `"display notification ..."`, `".none"` | AppleScript source. |
| `triggerModes` | string/null | `"email|message"` | Good for mode-specific scripting. |

Example:

```json
"showNoti": {
  "action": "display notification \"{{swResult}}\" with title \"Macrowhisper\""
}
```

`action` semantics are the same as section 5:

- `.none` = no-op template.
- `""` = empty payload (AppleScript execution is skipped).
- `noEsc` / `restoreClipboard` still follow normal resolution unless template forces values.

---

## 8) Trigger System (Voice, App, Mode)

Triggers are evaluated across all action types.

Matched actions are sorted by name; only the first match executes.

Important priority reminder:

- Triggered action resolution happens after one-shot runtime commands (`--auto-return`, `--schedule-action`) and before `defaults.activeAction`.

## 8.1 `triggerVoice`

### Default behavior (plain patterns)

Plain voice patterns are:

- prefix-only (start of transcript)
- case-insensitive
- treated as literal text (escaped), not raw regex

Examples:

- `"search"`
- `"search|google|ask"`
- `"!test"` (exception)

Pipe splitting detail:

- `|` splits multiple voice patterns.
- `|` inside raw regex blocks (`==...==`) is ignored as a separator.
- That means this is one raw pattern, not two:

```json
"triggerVoice": "==^(search|google)\\s+(.+)$=="
```

### Raw regex behavior

Wrap in `==...==` for raw regex control.

Example:

```json
"triggerVoice": "==^translate\\s+(.+)$=="
```

Rules:

- raw regex is case-insensitive by default
- if you explicitly set `(?i)` or `(?-i)`, that explicit mode is respected
- raw regex triggers do not use automatic prefix stripping

### Exception logic

Exception patterns use `!` prefix.

If a trigger list has only exceptions, it matches when none of the exceptions match.

Example:

```json
"triggerVoice": "!test|!debug"
```

This will match every voice input except ones matching `test` or `debug` at the start.

## 8.2 `triggerApps`

Regex against front app name and bundle ID.

Examples:

```json
"triggerApps": "Mail|com.apple.mail"
```

```json
"triggerApps": "^com\\.apple\\."
```

Rules:

- direct regex (no `==...==` wrapper needed)
- case-insensitive by default unless you explicitly specify mode
- `!` exception patterns are supported here too
- if only exception patterns are configured, the app trigger passes when none of those exception patterns match

## 8.3 `triggerModes`

Regex against Superwhisper `modeName`.

Example:

```json
"triggerModes": "dictation|rewrite|email"
```

Rules are same style as `triggerApps`.

That includes:

- regex patterns directly
- supports `!` exception patterns
- case-insensitive default behavior unless explicitly overridden

## 8.4 `triggerLogic`

- `or` (default): any configured trigger type can match
- `and`: all configured trigger types must match

Important behavior:

- only non-empty trigger fields are considered
- if all trigger fields are empty, action does not trigger

Detailed logic behavior:

- `or`: at least one configured trigger type must match.
- `and`: every configured trigger type must match.
- "Configured" means non-empty for that action.

## 8.5 Voice trigger stripping behavior

For non-raw voice triggers that match:

- matched prefix is stripped from `result`
- in trigger-executed flows, equivalent stripping is also attempted for `llmResult`
- leading punctuation/whitespace after stripped prefix is removed
- first remaining character is uppercased

This is why voice commands like `"google best pizza"` can trigger URL actions and still pass clean payload text.

---

## 9) Input Conditions (`inputCondition`) Deep Dive

`inputCondition` controls whether selected fields apply based on whether execution starts inside an input field.

Format rules:

- pipe-separated tokens
- no whitespace allowed
- `token` means apply only in input fields
- `!token` means apply only outside input fields

Examples:

```json
"inputCondition": "restoreClipboard|pressReturn|action"
```

```json
"inputCondition": "!restoreClipboard|!action"
```

## 9.1 Allowed tokens by action type

### Insert actions

Allowed tokens:

- `restoreClipboard`
- `pressReturn`
- `noEsc`
- `nextAction`
- `moveTo`
- `action`
- `actionDelay`
- `simKeypress`
- `smartInsert`

### URL, Shortcut, Shell, AppleScript actions

Allowed tokens:

- `restoreClipboard`
- `noEsc`
- `nextAction`
- `moveTo`
- `action`
- `actionDelay`

## 9.2 Validation rules

`inputCondition` is rejected if:

- it contains whitespace
- it has empty tokens (`||`)
- `!` is used without a token
- token name is not allowed for that action type

When config validation fails, Macrowhisper reports a configuration error and falls back to defaults in memory until fixed.

## 9.3 How inputCondition is applied internally

When a token does not apply in current context, the related field is neutralized:

- booleans/numbers set to `nil` (fallback to defaults)
- `action` set to empty string (effectively skip payload for that step)
- strings like `moveTo`/`nextAction` set to `nil` (fallback behavior)

---

## 10) Chaining Actions (`nextAction`) Deep Dive

`nextAction` lets one action call another.

It can be set:

- per action (`action.nextAction`)
- globally (`defaults.nextAction`)

## 10.1 Precedence

For first step only:

- if `defaults.nextAction` is non-empty, it overrides the first action's own `nextAction`

For subsequent steps:

- only action-level `nextAction` is considered

## 10.2 Safety checks

Macrowhisper validates and blocks:

- missing next action names
- chain cycles (`A -> B -> A`)
- more than one insert action in the same chain

## 10.3 Name uniqueness requirement

Because chains resolve by name across all types, duplicate names across types are rejected by config validation.

## 10.4 Execution behavior

- Actions execute step-by-step.
- If one step fails, chain continues to remaining steps and reports partial failure.
- Clipboard restoration decision is controlled by the last step.
- `moveTo` post-processing is based on final executed action context.

---

## 11) Placeholders Deep Dive

Placeholders are available in every action type via `action` strings.

## 11.1 Processing order

For each action payload:

1. Insert actions only: convert literal `\n` to real line breaks.
2. XML extraction pass (if `llmResult` or `result` exists and XML placeholders are requested).
3. Dynamic placeholder expansion (`{{key}}`, `{{json:key}}`, `{{raw:key}}`, dates, regex transforms).
4. Contextual escaping based on action type.

## 11.2 Basic placeholders

- `{{swResult}}` - prefers `llmResult`, falls back to `result`
- `{{result}}`
- `{{llmResult}}`
- `{{frontApp}}`

`{{frontApp}}` is sourced from pre-captured front app when available, otherwise fetched at placeholder time.

## 11.3 Date placeholders

- `{{date:short}}`
- `{{date:long}}`
- `{{date:yyyy-MM-dd}}` (UTS-35 style custom format)

## 11.4 Context placeholders

- `{{selectedText}}`
- `{{clipboardContext}}`
- `{{appContext}}`

Detailed timing is covered in Section 12.

## 11.5 XML placeholders

Supported formats:

- `{{xml:tagName}}`
- `{{json:xml:tagName}}`
- `{{raw:xml:tagName}}`

Behavior:

- looks for `<tagName>...</tagName>` in `llmResult` first, else in `result`
- inserts extracted content where placeholder appears
- if tag content is missing/empty, placeholder is removed
- extracted XML blocks are removed from `llmResult` before `{{swResult}}` is finalized (when applicable)

## 11.6 Any metadata key placeholder

Any key in `meta.json` can be used as `{{keyName}}`.

Examples:

- `{{modeName}}`
- `{{languageModelName}}`
- `{{language}}`

Special time keys (`duration`, `languageModelProcessingTime`, `processingTime`) are formatted into human-readable values like `350ms`, `1.2s`, or `2m 05s`.

If a placeholder key does not exist, it resolves to empty string.

---

## 12) Context Capture Timing

This section explains exactly when each context placeholder is captured.

## 12.1 `{{selectedText}}`

Primary capture timing:

- captured at recording session start (when recording folder appears)

Fallback behavior:

- in CLI execution context, if missing in metadata, Macrowhisper attempts capture at action execution time

## 12.2 `{{clipboardContext}}`

Session execution flow:

1. Macrowhisper captures pre-recording clipboard history from the `clipboardBuffer` window before dictation starts.
2. During session, clipboard changes are tracked.
3. `{{clipboardContext}}` resolves from session data:
   - if stacking is off: last session clipboard change, else most recent pre-recording capture
   - if stacking is on: all relevant captures in order; if more than one item exists, output is XML-tagged

Filtering behavior:

- Superwhisper result text is filtered out from stacked clipboard context entries.
- Empty clipboard entries are ignored.
- Ignored apps (from `clipboardIgnore`) do not contribute entries.

CLI execution flow (`--exec-action` etc):

- no recording session context exists
- Macrowhisper uses global clipboard history within `clipboardBuffer`
- with stacking off: most recent clipboard item in window
- with stacking on: all clipboard items in window

Stacking output format for multiple items:

```xml
<clipboard-context-1>
...
</clipboard-context-1>

<clipboard-context-2>
...
</clipboard-context-2>
```

## 12.3 `{{appContext}}`

- captured at action execution time
- captures richer app/window/text-field context

## 12.4 `{{frontApp}}`

- sourced from pre-captured front app state during processing when that value is present
- fallback fetch at placeholder time if missing

## 12.5 Capture protections

Clipboard system includes protections to reduce contamination between runs:

- short blackout/ignore window at recording start
- app ignore filtering (`clipboardIgnore`)
- marker-type filtering for transient/concealed pasteboard types
- cleanup after action execution

Current internal windows used by monitoring logic:

- startup duplicate-ignore blackout: `2.5s`
- retroactive cleanup window for ignored-app activation race cases: `0.5s`
- non-insert/insert clipboard synchronization wait ceiling: `0.1s`
- clipboard polling interval: `0.01s`

---

## 13) Regex Replacements

Regex replacements work inside placeholder syntax:

```text
{{placeholder||find_regex||replace||find_regex2||replace2}}
```

Examples:

Remove filler words:

```text
{{swResult||\b(uh|um|like)\b||}}
```

Remove trailing period (common for URL query cleanup):

```text
{{swResult||\.$||}}
```

Replace line breaks with HTML `<br>`:

```text
{{swResult||\n||<br>}}
```

Behavior details:

- multiple replacements execute in order
- invalid regex patterns are logged and skipped
- placeholder value is only transformed if non-empty

---

## 14) Contextual Escaping (`raw:` / `json:` and default behavior)

Macrowhisper applies escaping based on action type unless overridden.

## 14.1 Default escaping by action type

- Insert: no escaping
- Shortcut: no escaping
- URL: URL-encoding on final value
- Shell: shell-safe escaping
- AppleScript: AppleScript-safe escaping

## 14.2 Prefix overrides

Use `raw:` to disable escaping:

```text
{{raw:swResult}}
```

Use `json:` to force JSON string escaping:

```text
{{json:swResult}}
```

Example (embedding inside JSON string payload):

```json
"action": "{\"input\":\"{{json:swResult}}\"}"
```

---

## 15) Clipboard System Deep Dive

Most users can skip this section. It is for precision debugging and advanced setups.

## 15.1 Why this exists

Superwhisper and Macrowhisper can touch clipboard near the same time. The clipboard subsystem exists to avoid race conditions and stale clipboard reuse.

## 15.2 Key timing values used internally

- short wait window for Superwhisper clipboard sync before insert (`0.1s`)
- fast polling interval for clipboard changes (`0.01s`)
- recent-activity window to skip unnecessary waiting (`0.5s`)
- startup duplicate-ignore blackout window (`2.5s`)
- pre-recording capture window from `clipboardBuffer` (user-configurable, default `5s`)

## 15.3 Important settings

- `restoreClipboard`
- `clipboardBuffer`
- `clipboardStacking`
- `clipboardIgnore`

How these combine:

- `clipboardBuffer = 0` disables pre-recording global clipboard buffer capture.
- `clipboardStacking = false` returns one best clipboard context candidate.
- `clipboardStacking = true` can return multiple ordered snippets tagged as `<clipboard-context-N>`.
- `restoreClipboard = true` restores the original clipboard at the end of the action flow (chain-aware: final step governs restoration).

## 15.4 `clipboardIgnore` examples

```json
"clipboardIgnore": "Arc|Bitwarden|com.apple.passwords"
```

This prevents clipboard captures from ignored apps from polluting `{{clipboardContext}}`.

## 15.5 Best practices

1. Keep Superwhisper clipboard restoration disabled.
2. Start with `clipboardBuffer: 5`.
3. Enable `clipboardStacking` only when you actually need multi-copy context.
4. Use `clipboardIgnore` for password managers / browsers that produce noisy clipboard events.
5. If you see intermittent clipboard race behavior, add a small `actionDelay` (for example `0.05` to `0.2`).

---

## 16) Recording File Handling (`moveTo`, `history`)

## 16.1 `moveTo`

Supported values:

- folder path: move processed recording folder
- `.delete`: delete processed folder
- `.none`: explicitly do nothing
- `""`/`null` on action-level: fallback to defaults

## 16.2 `history`

`defaults.history` controls retention cleanup.

- `null`: disabled (keep all)
- `0`: keep only most recent recording folder
- positive integer: keep last N days

Cleanup runs with a 24-hour check interval.

---

## 17) Advanced Runtime Behavior Notes

## 17.1 `--schedule-action` and `--auto-return` are one-shot

After use (or cancellation), they are cleared.

## 17.2 Timeout behavior

`scheduledActionTimeout` controls how long one-shot runtime modes remain pending when there is no active recording session.

- `0` means no timeout
- default is `5` seconds

## 17.3 `bypassModes`

If mode is bypassed:

- no action selection
- no action execution
- recording is marked processed

Example:

```json
"bypassModes": "dictation|raw"
```

---

## 18) Full Config Examples

## 18.1 Beginner-friendly everyday config

```json
{
  "defaults": {
    "watch": "~/Documents/superwhisper",
    "activeAction": "autoPaste",
    "actionDelay": 0,
    "restoreClipboard": true,
    "pressReturn": false,
    "smartInsert": true,
    "clipboardBuffer": 5,
    "clipboardStacking": false,
    "clipboardIgnore": "",
    "bypassModes": "",
    "nextAction": ""
  },
  "inserts": {
    "autoPaste": {
      "action": ".autoPaste",
      "icon": "•"
    },
    "emailDraft": {
      "action": "Hi,\n\n{{swResult}}\n\nThanks,",
      "triggerModes": "email"
    }
  },
  "urls": {
    "google": {
      "action": "https://www.google.com/search?q={{swResult||\.$||}}",
      "triggerVoice": "google|search",
      "triggerLogic": "or",
      "openWith": "Safari",
      "openBackground": false
    }
  },
  "shortcuts": {
    "Create Note": {
      "action": "{{swResult}}",
      "triggerVoice": "note"
    }
  },
  "scriptsShell": {
    "copyResult": {
      "action": "echo '{{swResult}}' | pbcopy",
      "triggerVoice": "copy result"
    }
  },
  "scriptsAS": {
    "notify": {
      "action": "display notification \"{{swResult}}\" with title \"Macrowhisper\"",
      "triggerVoice": "notify"
    }
  }
}
```

## 18.2 Advanced chained workflow example

```json
{
  "defaults": {
    "watch": "~/Documents/superwhisper",
    "activeAction": "compose",
    "nextAction": "",
    "restoreClipboard": true,
    "moveTo": "~/Documents/SW-Processed"
  },
  "inserts": {
    "compose": {
      "action": "{{swResult}}",
      "inputCondition": "action|smartInsert|simKeypress|restoreClipboard",
      "nextAction": "searchDocs"
    }
  },
  "urls": {
    "searchDocs": {
      "action": "https://www.google.com/search?q={{swResult}}",
      "openBackground": true,
      "nextAction": "notifyDone"
    }
  },
  "scriptsAS": {
    "notifyDone": {
      "action": "display notification \"Done\" with title \"Macrowhisper\""
    }
  },
  "shortcuts": {},
  "scriptsShell": {}
}
```

---

## 19) Troubleshooting

## 19.1 First checks

1. Is service running?

```bash
macrowhisper --service-status
```

2. Is active action set?

```bash
macrowhisper --get-action
```

3. Do action names exist?

```bash
macrowhisper --list-actions
```

4. Is config valid JSON and semantically valid?

```bash
macrowhisper --reveal-config
```

## 19.2 Logs

Log directory:

`~/Library/Logs/Macrowhisper/`

Use verbose mode for deep debugging:

```bash
macrowhisper --verbose
```

## 19.3 Common problems

### Nothing pastes

- Check macOS Accessibility permissions.
- Restart service.
- Confirm active action is not empty.
- Confirm no bypass mode is currently active.

### Trigger does not fire

- Verify `triggerLogic` and trigger fields are actually non-empty.
- For `triggerVoice`, remember plain pattern is prefix-only literal matching.
- Check for another action name that sorts earlier and matches first.

### `inputCondition` suddenly not working

- Ensure no spaces in string.
- Ensure token names are valid for that action type.
- Avoid empty segments like `||`.

### Clipboard context feels stale/noisy

- Tune `clipboardBuffer`.
- Add `clipboardIgnore` patterns.
- Disable conflicting clipboard manager features.
- Keep Superwhisper clipboard restore off.

### Config edits not applying

- Save valid JSON.
- Check for semantic validation errors (missing action refs, invalid inputCondition tokens, duplicate action names).
- If invalid, Macrowhisper can run with in-memory defaults until file is fixed.

---

## 20) Updating and Version Checks

### Homebrew update

```bash
brew update
brew upgrade macrowhisper
macrowhisper --restart-service
```

### Script update

```bash
curl -L https://raw.githubusercontent.com/ognistik/macrowhisper/main/scripts/install.sh | sh
macrowhisper --restart-service
```

Manual update check while running:

```bash
macrowhisper --check-updates
```

---

## 21) Full Uninstall

If installed with Homebrew:

```bash
macrowhisper --uninstall-service
brew uninstall macrowhisper
```

If installed with script:

```bash
macrowhisper --uninstall-service
sudo rm -f /usr/local/bin/macrowhisper
```

Optional cleanup:

- remove config folder: `~/.config/macrowhisper`
- remove logs: `~/Library/Logs/Macrowhisper`

---

## 22) Final Learning Path (Recommended)

If you want to become advanced quickly, follow this order:

1. Master `activeAction` and simple insert actions.
2. Add one trigger type at a time (`triggerVoice`, then app/mode).
3. Learn `inputCondition` with 1-2 tokens first.
4. Learn placeholders (`swResult`, `selectedText`, `clipboardContext`).
5. Add regex replacements for cleanup.
6. Add chained workflows with `nextAction`.
7. Tune clipboard settings only when needed.

This progression keeps setup stable while you gain power.

---

Repository and issue tracker:

- [Macrowhisper on GitHub](https://github.com/ognistik/macrowhisper)
