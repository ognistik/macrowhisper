# Macrowhisper Complete Documentation

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

Macrowhisper is an automation helper for [Superwhisper](https://superwhisper.com/?via=robert). It watches Superwhisper recordings and executes automations based on a configuration file. It's a layer that turns your dictation into repeatable workflows.

  - Superwhisper is excellent at capturing voice and processing it with AI.
  - Macrowhisper makes the results useful beyond pasting your dictations.

### Action types it can execute

  - Insert actions (paste/type text)
  - URL actions (open links/apps)
  - Shortcut actions (run macOS Shortcuts)
  - Shell actions
  - AppleScript actions

> You can also set triggers per action (phrases, active app, used Superwhisper mode) or chain multiple actions one after another one.

### Macrowhisper

  - Removes repetitive post-dictation steps.
  - Makes voice workflows predictable and repeatable.
  - It lets you decide different behavior by phrase, app, and mode.
  - It scales from simple setup to advanced automations without changing tools.

### What actually happens

  1. Superwhisper writes a recording folder and `meta.json`.
  2. Macrowhisper validates required result fields.
  3. Macrowhisper captures and enriches context (front app, selected text, clipboard context).
  4. Macrowhisper resolves action priority (auto-return, scheduled, triggers, active action).
  5. Macrowhisper executes action(s), handles clipboard restoration rules, and applies post-processing.
   
### Quick Examples

  #### **Without Macrowhisper:**
    1. Dictate text.
    2. Manually edit/clean it/copy.
    3. Switch apps to copy and paste results.
    4. Run shortcuts/scripts/macros manually.
    5. Repeat that process many times per day.

  #### **With Macrowhisper:**
    1. Dictate once.
    2. Matching logic picks the right action.
    3. Action runs immediately (insert, URL, shortcut, shell, or AppleScript).
    4. Optional chained steps run automatically.
    5. Clipboard and post-processing are handled consistently.

  #### Example 1: Voice command -> web action
    - You say: `google best mechanical keyboard for mac`.
    - `triggerVoice` matches `google`.
    - Macrowhisper strips the trigger word and opens: `https://www.google.com/search?q=best mechanical keyboard for mac`

  #### Example 2: Dictation -> structured writing template
    - You dictate in a cleanup Superwhisper mode.
    - Insert action pastes a consistent structure: opening text/heading, your dictation (`{{swResult}}`), and closing/signature text.
    - Result: consistent output format every time in a specific app, mode, or with a voice trigger.

  #### Example 3: Dictation -> shortcut pipeline
    - You dictate task details. AI transforms it into a dictionary.
    - Shortcut action sends `{{swResult}}` to a macOS Shortcut.
    - Shortcut creates a task in your task app parsing the details from the dictionary.
    - Optional `nextAction` opens the app to review the task.

  #### Example 4: Dictation -> script execution
    - You dictate: `log this release note`.
    - Shell action writes processed text to a file.
    - Same format, same destination, no manual copy/paste.

---

## 2) Quick Start

### Install Option 1 (Homebrew)

```bash
brew install ognistik/formulae/macrowhisper
```

### Install Option 2 (Script)

```bash
curl -L https://raw.githubusercontent.com/ognistik/macrowhisper/main/scripts/install.sh | sudo sh
```

*Note: installing via the script allows you to skip giving accessibility permissions after every update.*

### Configure Superwhisper (IMPORTANT)

- Recording Window: ON
- Paste Result Text: OFF
- Restore Clipboard After Paste: OFF
- Simulate Key Presses: OFF

*Macrowhisper should be the single source of truth for paste/clipboard/key behavior.*

### Open or create config

```bash
macrowhisper --reveal-config
```

Default path:
`~/.config/macrowhisper/macrowhisper.json`

### Start service

```bash
macrowhisper --start-service
```

Check service:

```bash
macrowhisper --service-status
```

### First test

Dictate once in a normal text field. By default, Macrowhisper creates `autoPaste` and sets it as `defaults.activeAction`. Paste behavior will be exactly as Superwhisper out of the box.

---

## 3) The Execution Flow

This section is the most important mental model.

### Step A: Recording session starts

When a recording folder appears, Macrowhisper starts early monitoring and captures context:

- Selected text at session start
- Clipboard state at session start (to optionally restore later)
- Clipboard captured in the pre-recording buffer window for use in `{{clipboardContext}}` (`clipboardBuffer` seconds before session)

### Step B: Wait for valid result data

Macrowhisper waits until `meta.json` has valid result fields:

- If `languageModelName` exists and is non-empty, it requires `llmResult` and `result`
- Otherwise, it requires `result`

*This allows MacroWhisper to be triggered with correct timing for both voice-only modes or modes with AI processing.*

### Step C: Add runtime context

Before action evaluation/execution, Macrowhisper enriches metadata with:
- Front app name / bundle ID
- Session selected text
- Session clipboard context
- If `{{appContext}}`  or `{{appVocabylary}}` are used, gather context data via accessibility APIs

### Step D: Optional bypass by mode

If `defaults.bypassModes` matches the current mode (`modeName`, case-insensitive), Macrowhisper skips all processing.

*If for some reason you want to bypass Macrowhisper for a specific Superwhisper mode, you can set that here. It is still important that you set auto-paste off in Superwhisper's default configuration, but you can override that option at the mode level.*

### Step E: Priority-based action selection

Priority order:

1. One-time `--auto-return`
2. One-time `--schedule-action`
3. Trigger matches (`triggerVoice`, `triggerApps`, `triggerModes`)
4. `defaults.activeAction`
5. No action

*`--auto-return` and `--schedule-action` are CLI commands that allow for one-time Macrowhisper triggers. These are useful to set via other automation apps like Keyboard Maestro.*

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

### General commands

```bash
macrowhisper --help
macrowhisper --version
```

### Configuration management (no running daemon required)

```bash
macrowhisper --reveal-config
macrowhisper --get-config
macrowhisper --set-config "/path/to/folder-or-file"
macrowhisper --reset-config
macrowhisper --update-config
macrowhisper --schema-info
```

Notes:

- `--set-config` persists the path.
- If you pass a directory, Macrowhisper uses `<dir>/macrowhisper.json`.
- `--update-config` refreshes config formatting/schema-compatible fields.

### Service management

```bash
macrowhisper --install-service
macrowhisper --start-service
macrowhisper --stop-service
macrowhisper --restart-service
macrowhisper --uninstall-service
macrowhisper --service-status
```

### Runtime commands (require running daemon)

```bash
macrowhisper --status
macrowhisper --action [<name>]
macrowhisper --get-action [<name>]
macrowhisper --copy-action <name>
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
- `--copy-action <name>` processes action content and copies it to clipboard (without polluting `clipboardContext` capture).
- `--exec-action <name>` runs the action once using latest valid result.
- `--schedule-action <name>` schedules one action for the next recording.
- `--schedule-action` (no name) cancels scheduled action.
- `--auto-return true` schedules one-time "paste result + return behavior" for the next recording.
- `--auto-return` with no value behaves like `true`.

### Action management commands

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

---

## 5) Configuration File Fundamentals

### 5.1 Top-level shape

```json
{
  "$schema": "file:///path/to/macrowhisper-schema.json",
  "configVersion": 2,
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

### 5.2 Recommended workflow

For most people, the safest and simplest approach is:

- Keep `"autoUpdateConfig": true` (default).
- Let Macrowhisper normalize/migrate config automatically on startup.
- Add/edit/remove actions with CLI commands (section 4), not by hand-editing JSON.
  - Examples: `--add-insert`, `--add-url`, `--add-shortcut`, `--add-shell`, `--add-as`, `--remove-action`.

Why this is recommended:

- It avoids common JSON mistakes.
- It keeps values aligned with current semantics (`configVersion: 2`).
- It reduces confusion around `null` vs `""` and special template strings.

Use manual JSON editing only only for inserting setting values. You'll receive hints from the schema to understand the semantics.

#### For Advanced Users
**If you prefer manually editing everything**
  - Top level: `defaults` is required.
  - Under `defaults`: `watch` is required.
  - Any action you define (`inserts`, `urls`, `shortcuts`, `scriptsShell`, `scriptsAS`) must include `action`.
  - `defaults.autoUpdateConfig` defaults to `true`. You must define it as `false` if you do not want the file to update itself.

**Versioning and auto-update**
  - `configVersion` controls semantics. Current semantics are `configVersion: 2`.
  - If `configVersion` is missing, runtime treats it as legacy (`1`) for semantics checks.
  - With `autoUpdateConfig: true`, startup can rewrite config for migration and normalization.
  - If `configVersion` is missing and auto-update is enabled, startup can update it to current.

**Practical guidance**
  - Most users should keep `autoUpdateConfig` enabled.
  - Set `autoUpdateConfig: false` only if you intentionally manage config updates yourself.
  - Even with `autoUpdateConfig: false`, you can still run `macrowhisper --update-config` manually.
  
### 5.3 Value semantics: defaults vs action-level overrides

Mental model

- `defaults` = normal behavior.
- Action-level values = per-action overrides.
- In `configVersion: 2`, inheritance is uniform: `null` means "inherit/use default".
- `""` is explicit empty for supported string fields; it is not inheritance.

Defaults-level note

- For nullable scalar defaults fields (most bool/number toggles), `null` means "use built-in Macrowhisper default".
- For action-level overrides, `null` means "inherit from `defaults`".
- `activeAction` is special: starter configs set it to `autoPaste`, but explicit `null` or `""` means no fallback action.

Quick rules (what wins?)

| Field type | If action value is `null` | If action value is set |
| --- | --- | --- |
| Boolean/number overrides (`noEsc`, `restoreClipboard`, `actionDelay`, `pressReturn`, `simKeypress`, `smartInsert`) | Use `defaults.<sameField>` | Action value wins |
| `moveTo` | `null` -> use `defaults.moveTo` | Action value wins (`""` = explicit no move, `.delete`, or a path) |
| `icon` | `null` -> use `defaults.icon` | Action value wins (`""` = explicit no icon) |
| `nextAction` | `null` -> use `defaults.nextAction` (first chain step only) | Action value wins (`""` = explicit no next action) |
| `action` payload | No fallback to defaults | `""` = empty payload; non-empty executes after placeholders |

### 5.4 Special `action` values (advanced, exact behavior)

*Macrowhisper has a few built-in templates meant to simplify common behaviors.*

#### For all action types

- `action: ".none"` applies:
    - `action = ""`
    - `inputCondition = ""`
    - `noEsc = true`
    - `restoreClipboard = false`

---

#### For insert actions

- `action: ".autoPaste"` applies:
    - `inputCondition = "!restoreClipboard|!noEsc"`
    - `noEsc = true`
    - `restoreClipboard = false`

These values simulate the exact behavior of Superwhisper's auto-paste.

- Outside input fields: Esc-press is not simulated, clipboard is not restored.
- Inside input fields: those values are cleared and fall back to defaults.

`.autoPaste` and `.none` are not just labels. They apply both template values and conditional fallback behavior. Knowing how this works can allow you to customize the behavior.

---

#### For Shortcut actions

- Shortcut only: `action: ".run"` -> run shortcut with no input payload

### 5.5 Empty/null values that disable behavior

| Field | Empty/`null` means |
| --- | --- |
| `defaults.activeAction` | No fallback action |
| `defaults.nextAction` | No global first-step chain override |
| `defaults.bypassModes` | Bypass-mode feature off |
| `defaults.clipboardIgnore` | No app-ignore regex for clipboard capture |
| `triggerVoice` / `triggerApps` / `triggerModes` | That trigger type is not configured for this action |

### 5.6 Quick real-world examples

```json
"action": ""
```
Meaning: this action runs with no payload.

---

```json
"action": ".none"
```
Meaning: no-op template (`action=""`, `noEsc=true`, `restoreClipboard=false`).

---

```json
"restoreClipboard": null
```
Meaning: inherit `defaults.restoreClipboard`.

---

```json
"icon": null
```
Meaning: inherit `defaults.icon`.

---

```json
"icon": ""
```
Meaning: explicit no icon for this action.

---

## 6) Global Defaults Reference

These live under `defaults`.

Null behavior at `defaults` level:

- For nullable bool/number defaults fields, `null` means "use built-in default."
- `actionDelay` can be omitted or set to `null`; both resolve to built-in default `0`.
- `activeAction` is nullable, but `null`/`""` explicitly disables fallback action.

| Key | Type | Default | Meaning |
| --- | --- | --- | --- |
| `watch` | string | `~/Documents/superwhisper` | Path to Superwhisper folder (the one containing `recordings`). |
| `noUpdates` | bool/null | `false` | Disable periodic update checks. `null` = built-in default (`false`). |
| `noNoti` | bool/null | `false` | Disable notifications. `null` = built-in default (`false`). |
| `activeAction` | string/null | `"autoPaste"` | Fallback action when no trigger matches. Empty/null means none. |
| `icon` | string/null | `null` | Default icon for actions. |
| `moveTo` | string/null | `null` | Default post-processing path (`.delete`, a path, or empty). |
| `noEsc` | bool/null | `false` | Disable ESC simulation before actions. `null` = built-in default (`false`). |
| `simKeypress` | bool/null | `false` | Insert by typing instead of clipboard paste (insert actions). `null` = built-in default (`false`). |
| `smartInsert` | bool/null | `true` | Smart casing/spacing behavior for insert actions. `null` = built-in default (`true`). |
| `actionDelay` | number/null | `0` | Delay before action execution. `null` or omitted = built-in default (`0`). |
| `history` | int/null | `null` | History retention in days. `0` keeps only newest recording folder. |
| `pressReturn` | bool/null | `false` | Press Return after insert execution. `null` = built-in default (`false`). |
| `returnDelay` | number/null | `0.1` | Delay before Return press. `null` = built-in default (`0.1`). |
| `restoreClipboard` | bool/null | `true` | Restore original clipboard at end of action flow. `null` = built-in default (`true`). |
| `scheduledActionTimeout` | number/null | `5` | Timeout (seconds) for pending auto-return/scheduled action when no recording starts. `0` means no timeout. `null` = built-in default (`5`). |
| `clipboardStacking` | bool/null | `false` | Capture multiple clipboard events for `{{clipboardContext}}`. `null` = built-in default (`false`). |
| `clipboardBuffer` | number/null | `5.0` | Pre-recording clipboard capture window in seconds. `0` disables buffer capture. `null` = built-in default (`5.0`). |
| `clipboardIgnore` | string/null | `null` | Regex for apps ignored in clipboard capture. |
| `bypassModes` | string/null | `null` | Pipe-separated Superwhisper mode names that bypass Macrowhisper entirely (case-insensitive). |
| `autoUpdateConfig` | bool/null | `true` | Auto-refresh config format/schema fields at startup. `null` = built-in default (`true`). |
| `redactedLogs` | bool/null | `true` | Redact sensitive content in logs. `null` = built-in default (`true`). |
| `nextAction` | string/null | `null` | Default next action chain target (first-step override). |

*By default, `actionDelay` is set to 0, but some actions (like triggering URLs or scripts) can happen faster than Superwhisper's popup appears with the result. **If you notice Superwhisper's recording window isn't closing correctly, you might need to adjust this value.** I personally prefer setting `actionDelay` to 0 for insert actions since it makes things very responsive. Though, at the default level, I have it with 0.02 for all other action types.*

### Validation rules involving defaults

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

**IMPORTANT: Action names must be unique across all five dictionaries.**

### Quick guide: special `action` values

| Value | Where it works | Simple meaning |
| --- | --- | --- |
| `""` | All action types | Empty payload for this action (not a template). |
| `.none` | All action types | No-op template (`action=""`, `inputCondition=""`, `noEsc=true`, `restoreClipboard=false`). |
| `.autoPaste` | Insert actions only | Insert template that matches Superwhisper-style auto-paste behavior. |
| `.run` | Shortcut actions only | Run the Shortcut with no input payload. |

Section 5.4 has the full behavior details.

### Common fields across all action types

| **Field**          | **Type**    | **Meaning**                                                                     |
| ------------------ | ----------- | ------------------------------------------------------------------------------- |
| `action`           | string      | Main action payload (text/url/script/etc.)                                      |
| `icon`             | string/null | Per-action icon override                                                        |
| `moveTo`           | string/null | Per-action recording folder post-processing override. Can be `.delete` or path. |
| `noEsc`            | bool/null   | Skip ESC before action if `true`.                                               |
| `actionDelay`      | number/null | Per-action delay override                                                       |
| `restoreClipboard` | bool/null   | Per-action clipboard restoration override                                       |
| `inputCondition`   | string/null | Conditional option gating. Applies fields IF user is input field.               |
| `nextAction`       | string/null | Chain to another action                                                         |
| `triggerVoice`     | string/null | Voice trigger patterns                                                          |
| `triggerApps`      | string/null | Front app name/bundle regex trigger                                             |
| `triggerModes`     | string/null | Superwhisper mode trigger                                                       |
| `triggerLogic`     | string/null | `or` or `and`                                                                   |

How to read these fields in practice:

- For bool/number override fields, `null` means fallback to `defaults`.
- For `moveTo`, `icon`, and `nextAction`: `null` means fallback to defaults; `""` means explicit empty.
- For `action`, use the quick guide above (`""`, `.none`, `.autoPaste`, `.run`).
- `inputCondition` can neutralize fields at runtime before execution.
- `trigger*` fields only decide matching; they do not modify payload content.

### Common field examples

```json
"icon": "※"
```

```json
"icon": ".none"
```

```json
"moveTo": ".delete"
```

```json
"actionDelay": 0.02
```

```json
"restoreClipboard": null
```

### 7.1 Insert actions

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

Examples:

```json
"emailDraft": {
  "action": "Hi,\n\n{{swResult}}\n\nThanks,",
  "pressReturn": false,
  "actionDelay": 0,
  "triggerModes": "email"
}
```

```json
"autoPaste": {
  "action": ".autoPaste",
  "icon": "•"
}
```

```json
"showOnlyInWindow": {
  "action": ".none",
  "triggerModes": "assistant"
}
```

### 7.2 URL actions

URL-only extra fields:

- `openWith` (string/null) - app name, app path, or bundle ID used with `open`
- `openBackground` (bool/null) - open without focus (`open -g` behavior)

URL field reference:

| Field | Type | Typical values | Notes |
| --- | --- | --- | --- |
| `action` | string | `"https://...{{swResult}}"`, `".none"` | URL to open/template. |
| `openWith` | string/null | `"Safari"`, `"com.google.Chrome"` | Passed to `open -a`. |
| `openBackground` | bool/null | `true`, `false`, `null` | `true` opens in background. `false` or `null` resolves to foreground behavior. |

Examples:

```json
"searchGoogle": {
  "action": "https://www.google.com/search?q={{swResult}}",
  "openWith": "Safari",
  "openBackground": false,
  "triggerVoice": "google|search"
}
```

```json
"searchDocs": {
  "action": "https://developer.apple.com/search/?q={{swResult||\\.$||}}",
  "openBackground": true
}
```

### 7.3 Shortcut actions

Important: the action name (the object key) is the macOS Shortcut name.

Shortcut field reference:

| Field | Type | Typical values | Notes |
| --- | --- | --- | --- |
| `action` | string | `"{{swResult}}"`, `".run"`, `".none"` | Input sent to shortcut. `.run` runs the shortcut with no input. |

Examples:

```json
"Create Note": {
  "action": "{{swResult}}"
}
```

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

### 7.4 Shell actions

Shell field reference:

| Field | Type | Typical values | Notes |
| --- | --- | --- | --- |
| `action` | string | `"echo '{{swResult}}' | pbcopy"`, `".none"` | Shell command string or special value. |

Examples:

```json
"copyResult": {
  "action": "echo '{{swResult}}' | pbcopy",
  "triggerVoice": "copy result"
}
```

```json
"logMode": {
  "action": "echo 'Mode: {{modeName}} | Text: {{swResult}}' >> ~/Desktop/mw-log.txt"
}
```

### 7.5 AppleScript actions

AppleScript field reference:

| Field | Type | Typical values | Notes |
| --- | --- | --- | --- |
| `action` | string | `"display notification..."`, `".none"` | AppleScript source or special value. |

Example:

```json
"runMacro": {
  "action" : "tell application \"Keyboard Maestro Engine\" to do script \"Sample Macro\" with parameter \"{{swResult}}\""
}
```

*Context placeholders are escaped depending on their action type. More information in Section 14.*

---

## 8) Trigger System (Voice, App, Mode)
Triggers are evaluated across all action types. Matched actions are sorted by name; only the first match executes.

#### Important priority reminder:

Triggers are evaluated across all action types. Matched actions are sorted by name; only the first match executes.

#### Important priority reminder:
Triggered action resolution happens after one-shot runtime commands (`--auto-return`, `--schedule-action`) and before `defaults.activeAction`. This means scheduled actions (plus one-time auto-return) have priority over triggers, but triggers have priority over the currently active action.

### 8.1 `triggerVoice`

#### Default behavior (plain patterns)

#### Plain voice patterns are:

- Prefix-only (start of transcript)
- Case-insensitive
- Treated as literal text (escaped), not raw regex
- `|` splits multiple voice patterns.

#### Examples:

- `"search"`
- `"search|google|ask"`
- `"!test"` (exception means "match all except")

#### Raw regex behavior

- Wrap in `==...==` for raw regex control.
- `|` inside raw regex blocks (`==...==`) is ignored as a separator.
- Raw regex triggers **do not** have automatic prefix stripping
    - *You can remove the actual trigger with a placeholder-level regex replacement*


#### Examples:

```json
"triggerVoice": "==^translate\\s+(.+)$=="
```

```json
"triggerVoice": "==^(search|google)\\s+(.+)$=="
```

#### Exception logic

Exception patterns use `!` prefix.

**Important: if a trigger list has only exceptions, it matches when none of the exceptions match.** Watch out for this because you could accidentally create one action that kicks in with everything except one trigger.

#### Example:

```json
"triggerVoice": "!test|!debug"
```

This will match every voice input except ones matching `test` or `debug` at the start.

### 8.2 `triggerApps`

Regex against front app name and bundle ID.

#### Example:

```json
"triggerApps": "Mail|com.apple.mail"
```

#### Rules:

- Direct regex (no `==...==` wrapper needed)
- Case-insensitive by default
- `!` exception patterns are supported here too
- If only exception patterns are configured, the app trigger passes when none of those exception patterns match

### 8.3 `triggerModes`

Regex against Superwhisper `modeName`. Rules are same as triggerApps.

#### Example:

```json
"triggerModes": "dictation|Super|Custom"
```

### 8.4 `triggerLogic`

- `or` (default): any configured trigger type can match
- `and`: all configured trigger types must match

If all trigger fields are empty, action does not trigger unless it's set as the activeAction or scheduled with --schedule-action

### 8.5 Voice trigger stripping behavior
#### For non-raw voice triggers that match:

- Matched prefix is stripped from `result`
- In trigger-executed flows, equivalent stripping is also attempted for `llmResult`
- Leading punctuation/whitespace after stripped prefix is removed
- First remaining character is uppercased

*This is why voice commands like `"google best pizza"` can trigger URL actions and still pass clean payload text.*

---

## 9) Input Conditions (`inputCondition`) Deep Dive

`inputCondition` controls whether selected fields apply based on whether execution starts inside an input field.

Format rules:

- pipe-separated tokens
- no whitespace allowed
- `token` means apply only in input fields
- `!token` means apply only outside input fields
- When the condition does not apply. The action execution will use default-level values.

Examples:

```json
"inputCondition": "restoreClipboard|action"
```

```json
"inputCondition": "!restoreClipboard|!action"
```

### 9.1 Allowed tokens

- `restoreClipboard`
- `noEsc`
- `nextAction`
- `moveTo`
- `action`
- `actionDelay`

### 9.2 Validation rules

`inputCondition` is rejected if:

- it contains whitespace
- it has empty tokens (`||`)
- `!` is used without a token
- token name is not allowed for that action type

When config validation fails, Macrowhisper reports a configuration error and falls back to defaults in memory until fixed.

### 9.3 How inputCondition is applied internally

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

### 10.1 Precedence

For first step only:

- if action-level `nextAction` is `null`, `defaults.nextAction` can apply
- if action-level `nextAction` is `""`, that explicitly means "no next action" for first step

For subsequent steps:

- only action-level `nextAction` is considered

### 10.2 Safety checks

Macrowhisper validates and blocks:

- missing next action names
- chain cycles (`A -> B -> A`)
- more than one insert action in the same chain

### 10.3 Name uniqueness requirement

Because chains resolve by name across all types, duplicate names across types are rejected by config validation.

### 10.4 Execution behavior

- Actions execute step-by-step.
- If one step fails, chain continues to remaining steps and reports partial failure.
- Clipboard restoration decision is controlled by the last step.
- `moveTo` post-processing is based on final executed action context.

---

## 11) Placeholders Deep Dive

Placeholders are available in every action type via `action` strings.

### 11.1 Processing order

For each action payload:

1. Insert actions only: convert literal `\n` to real line breaks.
2. XML extraction pass (if `llmResult` or `result` exists and XML placeholders are requested).
3. Dynamic placeholder expansion (`{{key}}`, `{{json:key}}`, `{{raw:key}}`, dates, regex transforms).
4. Contextual escaping based on action type.

### 11.2 Basic placeholders

- `{{swResult}}` - prefers `llmResult`, falls back to `result`
- `{{result}}`
- `{{llmResult}}`
- `{{frontApp}}`

`{{frontApp}}` is resolved lazily at placeholder execution time from the current frontmost app.

### 11.3 Date placeholders

- `{{date:short}}`
- `{{date:long}}`
- `{{date:yyyy-MM-dd}}` (UTS-35 style custom format)

### 11.4 Context placeholders
Context placeholders use content captured by Macrowhisper, not Superwhisper. This means that they also work on voice-only modes without LLM. This is particularly useful if you want to use Macrowhisper actions to send your dictation results to other apps. 

- `{{selectedText}}`
- `{{clipboardContext}}`
- `{{appContext}}`
- `{{appVocabulary}}`

*Detailed timing is covered in Section 12.*

### 11.5 XML placeholders

Supported formats:

- `{{xml:tagName}}`
- `{{json:xml:tagName}}`
- `{{raw:xml:tagName}}`
  
*Note: contextual prefixes like `json:` and `raw:` are covered in [Section 14](craftdocs://open?blockId=3cac03d4-186d-06d6-06b7-3cdaa1b189bd&spaceId=dbf93b0b-3c55-5ab0-745b-9fa6a60fc3d2)*

Behavior:

- looks for `<tagName>...</tagName>` in `llmResult` first, else in `result`
- inserts extracted content where placeholder appears
- if tag content is missing/empty, placeholder is removed
- extracted XML blocks are removed from `llmResult` before `{{swResult}}` is finalized (when applicable)

### 11.6 Any metadata key placeholder

Any key in `meta.json` can be used as `{{keyName}}`.
Nested values can be accessed with dot notation and array indexes:

- `{{promptContext.systemContext.language}}`
- `{{promptContext.modeContext.type}}`
- `{{segments.0.text}}`

Examples:

- `{{modeName}}`
- `{{languageModelName}}`
- `{{language}}`
- `{{promptContext.systemContext.language}}`

`{{segments}}` is rendered as a readable transcript.
- With speaker metadata/diarization: consecutive words from the same speaker are merged into blocks, each block starts with `mm:ss Speaker N` (`N` is 1-based).
- Without speaker metadata: all segment words are merged into a single readable paragraph.

Special time keys (`duration`, `languageModelProcessingTime`, `processingTime`) are formatted into human-readable values like `350ms`, `1.2s`, or `2m 05s`.

If a placeholder key does not exist, it resolves to empty string.

---

## 12) Context Capture Timing

### 12.1 `{{selectedText}}`

Primary capture timing:

- captured at recording session start (when recording folder appears)

Fallback behavior:

- in CLI execution context (with `--exec-action` , `--get-action` or `copy-action`), Macrowhisper attempts capture at action execution time

### 12.2 `{{clipboardContext}}`

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

CLI execution flow (`--exec-action`, `--copy-action`, `--get-action <name>`):

- With stacking off: most recent clipboard item in window
- With stacking on: all clipboard items in window
- Important: With `--copy-action` , you can pass stacked clipboards to Superwhisper for processing, if the selected mode includes clipboard capture.

Stacking output format for multiple items:

```xml
<clipboard-context-1>
...
</clipboard-context-1>

<clipboard-context-2>
...
</clipboard-context-2>
```

### 12.3 `{{appContext}}`

- captured at action execution time
- captures richer app/window/text-field context

### 12.4 `{{appVocabulary}}`

- captured at action execution time (lazy, only when placeholder is present)
- extracts comma-separated terms from front app accessibility text (window/focused elements)
- tuned for names/identifiers/noun-like tokens

### 12.5 `{{frontApp}}`

- captured at action execution time (lazy, only when placeholder is present)
- resolves to the current frontmost app name at the moment each action step is processed

### 12.6 On CLI Execution

In CLI execution context (with `--exec-action` , `--get-action` or `copy-action` ), Macrowhisper attempts capture of context placeholders at action execution time.

***Powerful Use-Case**: With `--copy-action` , you can pass stacked clipboards to Superwhisper for processing if the selected mode in Superwhisper includes clipboard capture.*

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
- `""`: explicitly do nothing
- `null` on action-level: fallback to defaults

## 16.2 `history`

`defaults.history` controls retention cleanup.

- `null`: disabled (keep all)
- `0`: keep only most recent recording folder
- positive integer: keep last N days

Cleanup uses a 24-hour in-memory check interval:
- It runs at most once every 24 hours while Macrowhisper stays running.
- The timer is not persisted across app restarts, so after restarting, cleanup can run again on the next processed recording.

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
  "configVersion": 2,
  "defaults": {
    "watch": "~/Documents/superwhisper",
    "activeAction": "autoPaste",
    "actionDelay": 0,
    "restoreClipboard": true,
    "pressReturn": false,
    "smartInsert": true,
    "clipboardBuffer": 5,
    "clipboardStacking": false,
    "clipboardIgnore": null,
    "bypassModes": null,
    "nextAction": null
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
  "configVersion": 2,
  "defaults": {
    "watch": "~/Documents/superwhisper",
    "activeAction": "compose",
    "nextAction": null,
    "restoreClipboard": true,
    "moveTo": "~/Documents/SW-Processed"
  },
  "inserts": {
    "compose": {
      "action": "{{swResult}}",
      "inputCondition": "action|restoreClipboard",
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
