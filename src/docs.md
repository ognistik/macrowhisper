# Macrowhisper User Guide

Macrowhisper works with [Superwhisper](https://superwhisper.com/?via=robert). Superwhisper turns your voice into text. Macrowhisper decides what should happen next.

That "next step" can be as simple as pasting your text, or as advanced as opening a website, running a Shortcut, launching a shell command, or chaining several actions together.

If you are new, start with these sections:

1. What Macrowhisper Does
2. Quick Start
3. What Happens After You Dictate
4. Configuration Basics
5. Action Types
6. Triggers
7. Config Examples
8. Troubleshooting

Everything else is there when you want more control.

## Table of Contents

1. What Macrowhisper Does
2. Quick Start
3. What Happens After You Dictate
4. Command Reference
5. Configuration Basics
6. Global Defaults Reference
7. Action Types
8. Triggers
9. Conditional Behavior with `inputCondition`
10. Chaining Actions with `nextAction`
11. Placeholders
12. When Context Is Captured
13. Regex Replacements
14. Escaping Rules
15. Clipboard Behavior
16. Recording File Handling
17. Advanced Runtime Notes
18. Config Examples
19. Troubleshooting
20. Updating and Version Checks
21. Full Uninstall

---

## 1) What Macrowhisper Does

Macrowhisper is an automation layer for Superwhisper.

Superwhisper is great at turning speech into text. Macrowhisper makes that text useful by sending it where you want it to go, in the format you want, with the rules you choose.

In practice, that means you can:

- paste your dictated text into the current app
- open a search or a website
- send the text into a macOS Shortcut
- run a shell command
- run an AppleScript
- decide different behavior by phrase, app, mode, or browser URL
- chain several actions together

### The action types

Macrowhisper can run five kinds of actions:

- Insert actions: paste or type text
- URL actions: open websites or apps
- Shortcut actions: run macOS Shortcuts
- Shell actions: run Terminal commands
- AppleScript actions: run AppleScript code

### What it helps with

Without Macrowhisper, a normal voice workflow often looks like this:

1. Dictate text.
2. Clean it up manually.
3. Switch to another app.
4. Copy and paste it somewhere else.
5. Run a shortcut, script, or macro by hand.
6. Repeat that many times a day.

With Macrowhisper, the flow can become:

1. Dictate once.
2. Macrowhisper chooses the right action.
3. The action runs right away.
4. Any follow-up steps run automatically.
5. Clipboard handling stays consistent.

### A simple mental model

Think of Macrowhisper like this:

- Superwhisper gives you the text.
- Macrowhisper decides what to do with the text.

### What happens behind the scenes

At a high level, Macrowhisper:

1. Detects a new Superwhisper recording.
2. Waits until the result is ready.
3. Collects useful context such as the front app, selected text, and clipboard context.
4. Chooses which action should run.
5. Runs that action, plus any chained actions.
6. Cleans up afterward.

You do not need to memorize that to use the app, but it helps when setting up more advanced behavior.

### Quick examples

#### Example 1: Voice command -> web search

- You say: `google best mechanical keyboard for mac`
- `triggerVoice` matches `google`
- Macrowhisper removes the trigger word and opens:
  `https://www.google.com/search?q=best mechanical keyboard for mac`

#### Example 2: Dictation -> writing template

- You dictate in a specific Superwhisper mode
- an insert action pastes a template around your text
- your dictation appears inside the template by using `{{swResult}}`

Result: the output keeps the same format every time.

#### Example 3: Dictation -> Shortcut

- You dictate a task
- a Shortcut action sends the text to a macOS Shortcut
- the Shortcut creates or updates something in another app

#### Example 4: Dictation -> script

- You say: `log this release note`
- a shell action writes the processed text to a file
- the format and destination stay consistent

---

## 2) Quick Start

This is the fastest path to a working setup.

### Install option 1: Homebrew

```bash
brew install ognistik/formulae/macrowhisper
```

### Install option 2: Install script

```bash
curl -L https://raw.githubusercontent.com/ognistik/macrowhisper/main/scripts/install.sh | sudo sh
```

Note: the script install can be more convenient if you want to avoid re-granting accessibility permissions after every update.

### Set up Superwhisper

These settings matter:

- Recording Window: ON
- Paste Result Text: OFF
- Restore Clipboard After Paste: OFF
- Simulate Key Presses: OFF

Macrowhisper should be the one handling paste, clipboard, and key behavior.

### Open or create your config

```bash
macrowhisper --reveal-config
```

Default path:

`~/.config/macrowhisper/macrowhisper.json`

### Start the background service

```bash
macrowhisper --start-service
```

Check that it is running:

```bash
macrowhisper --service-status
```

### First test

Dictate once in a normal text field.

By default, Macrowhisper creates an `autoPaste` action and sets it as `defaults.activeAction`, so the starting behavior should feel very close to normal Superwhisper paste behavior.

If that works, the basic setup is done.

---

## 3) What Happens After You Dictate

This section gives you the best overall picture of how Macrowhisper behaves.

### Step A: A recording starts

When a new recording folder appears, Macrowhisper begins tracking that session.

At this stage it can capture:

- selected text at the start of the session
- the clipboard state at the start of the session
- recent clipboard context from the pre-recording buffer window

### Step B: It waits for a usable result

Macrowhisper waits until `meta.json` contains the result it needs.

The short version:

- if Superwhisper produced an AI-processed result, Macrowhisper waits for that
- otherwise, it uses the regular result field

This prevents actions from firing too early.

### Step C: It gathers runtime context

Before running an action, Macrowhisper can gather:

- front app name
- front app bundle ID
- selected text
- clipboard context
- front app PID

If you use `{{appContext}}` or `{{appVocabulary}}`, those are only collected when needed and then reused during the rest of the action chain.

### Step D: It can skip processing for some modes

If `defaults.bypassModes` matches the current Superwhisper mode, Macrowhisper skips all action processing for that recording.

This is useful when you want certain modes to behave as if Macrowhisper were not involved.

### Step E: It chooses which action should run

Macrowhisper chooses actions in this order:

1. one-time `--auto-return`
2. one-time `--schedule-action`
3. trigger matches (`triggerVoice`, `triggerApps`, `triggerModes`, `triggerUrls`)
4. `defaults.activeAction`
5. no action

That order matters. A scheduled action can override triggers, and a trigger can override your normal active action.

### Step F: It runs the action, then any chained actions

If the chosen action has a `nextAction`, Macrowhisper can continue into the next step automatically.

Shortcut, shell, and AppleScript actions are asynchronous by default so Macrowhisper stays responsive. If you want Macrowhisper to wait for the script to finish, set:

- `scriptAsync: false`
- `scriptWaitTimeout`

### Step G: It finishes cleanup

After the action flow ends, Macrowhisper may:

- move or delete the recording folder according to `moveTo`
- clean up temporary monitoring state
- restore the clipboard if needed
- run retention cleanup if `history` is enabled

---

## 4) Command Reference

This section lists the main terminal commands. You do not need all of them to get started.

### Everyday commands

```bash
macrowhisper --help
macrowhisper --version
macrowhisper --reveal-config
macrowhisper --validate-config
macrowhisper --service-status
macrowhisper --list-actions
```

### Config commands

These do not require the running background service.

```bash
macrowhisper --reveal-config
macrowhisper --get-config
macrowhisper --set-config "/path/to/folder-or-file"
macrowhisper --validate-config
macrowhisper --reset-config
macrowhisper --update-config
macrowhisper --schema-info
```

Useful notes:

- `--set-config` saves the config path for future runs
- if you pass a directory, Macrowhisper uses `<dir>/macrowhisper.json`
- `--validate-config` checks both JSON validity and config rules
- `--update-config` refreshes formatting and schema-related fields

### Service commands

```bash
macrowhisper --install-service
macrowhisper --start-service
macrowhisper --stop-service
macrowhisper --restart-service
macrowhisper --uninstall-service
macrowhisper --service-status
```

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

### Runtime commands

These are for use while the background service is running.

```bash
# Check runtime state
macrowhisper --status
macrowhisper --get-action [<name>] [--meta <value>]
macrowhisper --get-icon
macrowhisper --folder-name [<index>]
macrowhisper --folder-path [<index>]

# Set or clear the default action
macrowhisper --action [<name>]

# One-time controls
macrowhisper --auto-return [<true|false>]
macrowhisper --schedule-action [<name>]
macrowhisper --mute-triggers [<true|false|duration>]

# Execute actions
macrowhisper --copy-action <name> [--meta <value>]
macrowhisper --exec-action <name> [--meta <value>]
macrowhisper --run-auto [--meta <value>]

# Other runtime tasks
macrowhisper --check-updates
```

Before using runtime commands, make sure the service is running:

```bash
macrowhisper --start-service
```

### Runtime command reference

#### 1) Inspect state

| Command | What it does |
| --- | --- |
| `--status` | Shows whether the daemon is running and includes trigger mute state. |
| `--get-action` | Shows the current active action name. |
| `--get-action <name>` | Shows the processed output for that action. |
| `--get-icon` | Shows the icon for the active action. |
| `--folder-name [<index>]` / `--folder-path [<index>]` | Looks up recent recording folders by recency. |

#### 2) Set defaults

| Command | What it does |
| --- | --- |
| `--action <name>` | Sets the default active action. |
| `--action` | Clears the default active action. |

#### 3) One-time runtime controls

| Command | What it does |
| --- | --- |
| `--schedule-action <name>` | Uses that action for the next recording. |
| `--schedule-action` | Clears the scheduled action. |
| `--auto-return true|false` | Turns one-time auto-return on or off for the next recording. |
| `--auto-return` | Clears one-time auto-return. |
| `--mute-triggers true|false` | Saves trigger muting on or off in config. |
| `--mute-triggers <duration>` | Temporarily mutes triggers for a runtime duration such as `30s`, `5m`, or `1h`. |
| `--mute-triggers` | Unmutes and clears any temporary mute timer. |

You can check mute state through `--status`.

#### 4) Execute actions

| Command | What it does |
| --- | --- |
| `--exec-action <name>` | Runs one specific action right now. |
| `--run-auto` | Runs automatic selection logic against the current or chosen recording. |
| `--copy-action <name>` | Renders an action and copies the result without affecting `clipboardContext` capture. |

#### 5) Other runtime commands

- `--check-updates` forces an update check

### Important runtime details

- `--run-auto` does not take an action name
- `--run-auto` does not consume or clear one-time runtime state such as `--auto-return` or `--schedule-action`
- if persistent trigger muting is already `true`, then `--mute-triggers <duration>` is ignored

### `--meta`: use a different `meta.json`

By default, action commands use the latest valid Superwhisper result.

Use `--meta` when you want to point Macrowhisper to:

- a specific recording folder name
- a specific recording folder path
- a direct JSON file with compatible `meta.json` content

How Macrowhisper reads the value:

- `~` is supported
- if the value looks like a path, Macrowhisper treats it as a path
- otherwise, it treats the value as a recording folder name

Examples:

```bash
# Recording folder name inside the recordings directory
macrowhisper --get-action summarizeEmail --meta 2026-03-01_10-00-00
```

```bash
# Folder path that contains meta.json
macrowhisper --copy-action summarizeEmail --meta ~/Documents/superwhisper/recordings/2026-03-01_10-00-00
```

```bash
# Direct JSON file
macrowhisper --exec-action summarizeEmail --meta ~/tmp/custom-meta.json
```

```bash
# Show the active action name
macrowhisper --get-action
```

```bash
# This is invalid because --meta needs a specific action name here
macrowhisper --get-action --meta 2026-03-01_10-00-00
```

```bash
# Let Macrowhisper choose the action automatically
macrowhisper --run-auto --meta 2026-03-01_10-00-00
```

### `moveTo` when using `--meta`

For `--exec-action` and `--run-auto`:

- if `--meta` points to a recording folder, `moveTo` works normally
- if `--meta` points to a direct JSON file, `moveTo` is skipped because there is no recording folder to move or delete

### Behavior matrix

| Behavior | `--exec-action <name> [--meta <value>]` | `--run-auto [--meta <value>]` | `--get-action <name> [--meta <value>]` | `--copy-action <name> [--meta <value>]` |
| --- | --- | --- | --- | --- |
| Processes placeholders | Yes | Yes | Yes | Yes |
| Uses latest valid recording by default | Yes | Yes | Yes | Yes |
| Can use `--meta` | Yes | Yes | Yes | Yes |
| Evaluates `inputCondition` | Yes | Yes | No | No |
| Runs side effects such as open, paste, or scripts | Yes | Yes | No | No |
| Applies `actionDelay` | Yes | Yes | No | No |
| Applies `nextAction` | Yes | Yes | No | No |
| Uses watcher-style auto selection | No | Yes | No | No |
| Applies `moveTo` | Yes, except direct JSON `--meta` | Yes, except direct JSON `--meta` | No | No |
| Simulates ESC with `simEsc` | No practical effect in CLI execution | No practical effect in CLI execution | N/A | N/A |
| Restores clipboard | Chain-level: once at the end if the chain wrote to the clipboard and the final step enables restore | Chain-level: once at the end if the chain wrote to the clipboard and the final step enables restore | No | No |
| Writes to clipboard | Only if the action itself does so | Only if the action itself does so | No | Yes |
| Consumes one-time runtime state | No | No | No | No |

---

## 5) Configuration Basics

This section is the best place to start if you want to customize behavior.

### 5.1 The top-level structure

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

- Macrowhisper manages it automatically
- it helps editors validate the JSON and suggest keys
- most users never need to edit it the schema path hand

### 5.2 The recommended workflow

For most people, the safest setup is:

- keep `"autoUpdateConfig": true`
- let Macrowhisper normalize the config on startup
- create or remove actions with CLI commands instead of always adding everything in the JSON by hand

Examples:

- `--add-insert`
- `--add-url`
- `--add-shortcut`
- `--add-shell`
- `--add-as`
- `--remove-action`

Why this is easier:

- it avoids JSON mistakes
- it keeps the config aligned with the current format
- it reduces confusion around `null`, empty strings, and template values

Manual JSON editing is still fine when you want to adjust settings and action content. The schema exists to help.

### 5.3 A simple way to think about defaults and overrides

Use this mental model:

- `defaults` = your normal behavior
- action-level values = exceptions for one specific action

In `configVersion: 2`:

- action-level `null` usually means "inherit from `defaults`"
- `""` usually means "intentionally empty"

Important exceptions:

- `defaults.activeAction`: `null` or `""` means there is no fallback action
- `action`: empty string means "run this action with an empty payload"

Quick reference:

| Field type | If action value is `null` | If action value is set |
| --- | --- | --- |
| Boolean and number overrides such as `simEsc`, `restoreClipboard`, `actionDelay`, `simReturn`, `simKeypress`, `smartCasing`, `smartPunctuation`, `smartSpacing` | Use the matching value from `defaults` | The action value wins |
| `moveTo` | Use `defaults.moveTo` | The action value wins |
| `icon` | Use `defaults.icon` | The action value wins |
| `nextAction` | Use `defaults.nextAction` on the first step only | The action value wins |
| `action` | No fallback from `defaults` | The action payload is used directly |

### 5.4 Special `action` values

Macrowhisper includes a few built-in action shortcuts.

#### All action types

- `action: ".none"`

This applies:

- `action = ""`
- `inputCondition = ""`
- `simEsc = false`
- `restoreClipboard = false`

Use it when you want a safe do-nothing template with no payload.

#### Insert actions

- `action: ".autoPaste"`

This applies:

- `inputCondition = "!restoreClipboard|!simEsc"`
- `simEsc = false`
- `restoreClipboard = false`

It is designed to feel like Superwhisper's normal auto-paste behavior.

Simple summary:

- inside text fields, Macrowhisper behaves like a normal insert flow
- outside text fields, it avoids ESC simulation and clipboard restoration

#### Shortcut actions

- `action: ".run"`

This runs the Shortcut without sending any input payload.

### 5.5 Empty and `null` values that turn things off

| Field | Empty or `null` means |
| --- | --- |
| `defaults.activeAction` | No fallback action |
| `defaults.nextAction` | No default next step |
| `defaults.bypassModes` | Bypass behavior is off |
| `defaults.clipboardIgnore` | No clipboard ignore rules |
| `triggerVoice` / `triggerApps` / `triggerModes` / `triggerUrls` | That trigger type is not configured |

### 5.6 Quick examples

```json
"action": ""
```

Meaning: the action runs with an empty payload.

```json
"action": ".none"
```

Meaning: use the built-in do-nothing template.

```json
"restoreClipboard": null
```

Meaning: inherit `defaults.restoreClipboard`.

```json
"icon": null
```

Meaning: inherit `defaults.icon`.

```json
"icon": ""
```

Meaning: explicitly show no icon for this action.

### 5.7 For advanced users

If you prefer editing everything by hand:

- `defaults` is required
- `defaults.watch` may be omitted or set to `null`; both use the built-in default watch folder
- any action you define must include `action`
- `autoUpdateConfig` defaults to `true`, so set it to `false` only if you want to manage format updates yourself

If you want to go back to a built-in root default later, set that defaults value to null (or remove it), set autoUpdateConfig: true, and restart the service. On startup, Macrowhisper will resolve it and write the effective value back into the file.

Versioning notes:

- `configVersion: 2` is the current format
- if `configVersion` is missing, Macrowhisper treats it as legacy behavior
- with `autoUpdateConfig: true`, startup can rewrite the config to keep it current

---

## 6) Global Defaults Reference

These settings live under `defaults`.

At the defaults level, `null` is accepted for backward compatibility, but auto-updated configs are normalized toward explicit persisted values.

| Key | Type | Default | What it controls |
| --- | --- | --- | --- |
| `watch` | string/null | `~/Documents/superwhisper` | Path to the Superwhisper folder that contains `recordings`. Omit or use `null` to fall back to the built-in default path. |
| `disableUpdateCheck` | bool/null | `false` | Turns periodic update checks off. |
| `muteNotifications` | bool/null | `false` | Turns notifications off. |
| `activeAction` | string/null | `"autoPaste"` | Fallback action when no trigger matches. Empty or `null` means none. |
| `icon` | string/null | `""` | Default icon for actions. Empty or `null` means no default icon. |
| `moveTo` | string/null | `""` | What to do with processed recording folders: move them, delete them, or do nothing. Empty or `null` means no default move behavior. |
| `simEsc` | bool/null | `true` | Simulate ESC before actions. |
| `simKeypress` | bool/null | `false` | Type characters instead of pasting for insert actions. |
| `smartCasing` | bool/null | `true` | Adjust capitalization at insert boundaries. |
| `smartPunctuation` | bool/null | `true` | Clean punctuation conflicts at insert boundaries. |
| `smartSpacing` | bool/null | `true` | Clean spacing at insert boundaries. |
| `actionDelay` | number/null | `0` | Delay before the action starts. |
| `history` | int/null | `null` | How long to keep old recording folders. |
| `simReturn` | bool/null | `false` | Press Return after an insert action. |
| `returnDelay` | number/null | `0.15` | Delay before pressing Return. |
| `restoreClipboard` | bool/null | `true` | Restore the original clipboard after the action flow ends. |
| `restoreClipboardDelay` | number/null | `0.3` | Delay before restoring the clipboard. |
| `scheduledActionTimeout` | number/null | `5` | How long one-time runtime actions stay pending when no recording starts. |
| `scriptAsync` | bool/null | `true` | Whether Shortcut, shell, and AppleScript actions run asynchronously by default. |
| `scriptWaitTimeout` | number/null | `3` | Max wait time when `scriptAsync` is `false`. |
| `clipboardStacking` | bool/null | `false` | Whether `{{clipboardContext}}` can include several clipboard items. |
| `clipboardBuffer` | number/null | `5` | How many seconds of clipboard history to capture before recording. |
| `clipboardIgnore` | string/null | `""` | Regex for apps that should be ignored during clipboard capture. Empty or `null` means no ignore rules. |
| `bypassModes` | string/null | `""` | Pipe-separated Superwhisper mode names that should bypass Macrowhisper. Empty or `null` disables bypass. |
| `muteTriggers` | bool/null | `false` | Mute trigger matching globally. |
| `autoUpdateConfig` | bool/null | `true` | Automatically refresh config format and schema fields. |
| `redactedLogs` | bool/null | `true` | Hide sensitive content in logs. |
| `nextAction` | string/null | `""` | Default next action to use as the first chain step. Empty or `null` means no default chain step. |

Practical note about `actionDelay`:

By default it is `0`, which is usually fine. But URL and script actions can sometimes happen before Superwhisper's recording window has fully settled. If that creates UI timing issues, try a small delay such as `0.05` to `0.2`.

### Validation rules involving defaults

- `defaults.activeAction` must exist if it is not empty
- `defaults.nextAction` must exist if it is not empty
- `defaults.activeAction` cannot equal `defaults.nextAction`

---

## 7) Action Types

All actions are stored by name in one of these five groups:

- `inserts`
- `urls`
- `shortcuts`
- `scriptsShell`
- `scriptsAS`

Important: action names must be unique across all five groups.

### Quick guide to special `action` values

| Value | Where it works | Simple meaning |
| --- | --- | --- |
| `""` | All action types | Use an empty payload |
| `.none` | All action types | Use the built-in do-nothing template |
| `.autoPaste` | Insert actions only | Use Superwhisper-like auto-paste behavior |
| `.run` | Shortcut actions only | Run the Shortcut with no input |

### Fields shared by all action types

| Field | Type | Meaning |
| --- | --- | --- |
| `action` | string | The main payload for the action |
| `icon` | string/null | Override the icon for this action |
| `moveTo` | string/null | Override recording-folder handling for this action |
| `simEsc` | bool/null | Simulate ESC before this action |
| `actionDelay` | number/null | Delay before this action starts |
| `restoreClipboard` | bool/null | Override clipboard restoration |
| `restoreClipboardDelay` | number/null | Override clipboard restoration delay |
| `scriptAsync` | bool/null | Override async behavior for Shortcut, shell, or AppleScript actions |
| `scriptWaitTimeout` | number/null | Override how long Macrowhisper waits when `scriptAsync` is `false` |
| `inputCondition` | string/null | Apply some fields only in or outside input fields |
| `nextAction` | string/null | Chain to another action |
| `triggerVoice` | string/null | Match by spoken phrase |
| `triggerApps` | string/null | Match by front app name or bundle ID |
| `triggerModes` | string/null | Match by Superwhisper mode |
| `triggerUrls` | string/null | Match by active browser URL |
| `triggerLogic` | string/null | Use `or` or `and` when combining trigger types |

How to interpret those fields:

- `null` on most boolean and number overrides means "use the default"
- for `moveTo`, `icon`, and `nextAction`, `null` means inherit, while `""` means intentionally empty
- `trigger*` fields only help Macrowhisper choose the action; they do not change the payload

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

Insert actions are for pasting or typing text into the current app.

Extra insert-only fields:

- `simKeypress`
- `smartCasing`
- `smartPunctuation`
- `smartSpacing`
- `simReturn`

| Field | Type | Typical values | Notes |
| --- | --- | --- | --- |
| `action` | string | `"{{swResult}}"`, `".autoPaste"`, `".none"` | The text or template to insert. |
| `simKeypress` | bool/null | `true`, `false`, `null` | `true` types characters instead of pasting. Slower, but useful in apps that block paste. |
| `smartCasing` | bool/null | `true`, `false`, `null` | Adjusts capitalization at insertion boundaries. |
| `smartPunctuation` | bool/null | `true`, `false`, `null` | Removes punctuation conflicts at insertion boundaries. |
| `smartSpacing` | bool/null | `true`, `false`, `null` | Adjusts spacing around inserted text. |
| `simReturn` | bool/null | `true`, `false`, `null` | Press Return after insertion. |

If Accessibility is unavailable or the insertion context is low-confidence, smart casing, smart punctuation, and smart spacing are skipped for that insertion.

Examples:

```json
"emailDraft": {
  "action": "Hi,\n\n{{swResult}}\n\nThanks,",
  "simReturn": false,
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

```json
"titleWithException": {
  "action": "{{swResult::titleCase||\\bapi\\b||API}}"
}
```

In the last example, `API` stays uppercase even when title casing runs.

### 7.2 URL actions

URL actions open websites or apps.

Extra URL-only fields:

- `openWith` - app name, app path, or bundle ID used with `open`
- `openBackground` - open without focus

| Field | Type | Typical values | Notes |
| --- | --- | --- | --- |
| `action` | string | `"https://...{{swResult}}"`, `".none"` | The URL or template to open. |
| `openWith` | string/null | `"Safari"`, `"com.google.Chrome"` | Passed to `open -a`. |
| `openBackground` | bool/null | `true`, `false`, `null` | `true` opens in the background. |

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

Shortcut actions run macOS Shortcuts.

Important: the action name itself is the Shortcut name.

| Field | Type | Typical values | Notes |
| --- | --- | --- | --- |
| `action` | string | `"{{swResult}}"`, `".run"`, `".none"` | Input sent to the Shortcut. `.run` means run with no input. |

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

Shell actions run Terminal commands.

| Field | Type | Typical values | Notes |
| --- | --- | --- | --- |
| `action` | string | `"echo '{{swResult}}' | pbcopy"`, `".none"` | The shell command to run. |

By default, shell actions launch asynchronously. If you want Macrowhisper to wait for completion before continuing, set `scriptAsync: false`.

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

AppleScript actions run AppleScript source directly.

| Field | Type | Typical values | Notes |
| --- | --- | --- | --- |
| `action` | string | `"display notification..."`, `".none"` | The AppleScript source to run. |

Like shell and Shortcut actions, AppleScript actions run asynchronously by default unless `scriptAsync: false`.

Example:

```json
"runMacro": {
  "action": "tell application \"Keyboard Maestro Engine\" to do script \"Sample Macro\" with parameter \"{{swResult}}\""
}
```

Context placeholders are escaped differently depending on action type. See Section 14.

---

## 8) Triggers

Triggers help Macrowhisper decide when an action should run automatically.

Triggered actions are evaluated across all action types. If several actions match, Macrowhisper sorts them by name and runs the first one.

Important priority reminder:

- one-time runtime commands win first
- then triggers
- then `defaults.activeAction`

If `defaults.muteTriggers` is on, or a temporary trigger mute is active, Macrowhisper skips trigger matching and moves on to the active action.

### 8.1 `triggerVoice`

Use `triggerVoice` when you want spoken phrases to trigger actions.

Normal voice patterns are:

- prefix-only
- case-insensitive
- treated as literal text
- separated with `|`

Examples:

```json
"triggerVoice": "search|google|ask"
```

That means:

- `google best pizza` can match
- `search latest release notes` can match

#### Raw regex mode

Wrap the pattern in `==...==` when you want full regex control.

Example:

```json
"triggerVoice": "==^(search|google)\\s+(.+)$=="
```

Important:

- raw regex voice triggers do not do automatic prefix stripping
- if you need to remove the spoken trigger in that case, use a placeholder regex replacement

#### Exception patterns

Use `!` to define exceptions.

Example:

```json
"triggerVoice": "!test|!debug"
```

If a trigger list contains only exceptions, the action matches whenever none of those exceptions match.

### 8.2 `triggerApps`

Use `triggerApps` when an action should run only in certain apps.

It matches against:

- the front app name
- the front app bundle ID

Rules:

- direct regex, no `==...==` wrapper needed
- case-insensitive by default
- `!` exceptions are supported

Example:

```json
"triggerApps": "Mail|com.apple.mail"
```

### 8.3 `triggerModes`

Use `triggerModes` when you want a rule tied to a Superwhisper mode.

It matches against `modeName` and follows the same rules as `triggerApps`.

Example:

```json
"triggerModes": "dictation|Super|Custom"
```

### 8.4 `triggerUrls`

Use `triggerUrls` when behavior should change depending on the current browser page.

Rules:

- `|` separates tokens
- `!` creates exception tokens
- empty tokens are ignored

Token types:

- domain token: no scheme, such as `google.com`
- full URL token: starts with `http://` or `https://`

Examples:

- `google.com` matches `google.com`, `www.google.com`, and `docs.google.com`
- `www.google.com` matches `www.google.com` and deeper subdomains under it
- `www.google.com` does not match `maps.google.com`
- `https://google.com` matches `http://google.com/maps`
- `https://google.com` does not match `docs.google.com`

URL capture works only for supported browsers. If your browser is not behaving correctly with `triggerUrls`, open a GitHub issue with details.

### 8.5 `triggerLogic`

Use `triggerLogic` to combine trigger types:

- `or` means any configured trigger type can match
- `and` means all configured trigger types must match

If all trigger fields are empty, the action will not auto-trigger. It can still run as the active action or via `--schedule-action`.

### 8.6 What happens to spoken trigger words

For normal, non-regex voice triggers:

- the matched prefix is removed from `result`
- during trigger-executed flows, Macrowhisper also tries to remove the equivalent prefix from `llmResult`
- leading punctuation and whitespace after the removed prefix are cleaned up
- the first remaining character is uppercased

That is why a phrase like `google best pizza` can trigger a search and still pass clean text into the URL.

---

## 9) Conditional Behavior with `inputCondition`

`inputCondition` lets you say:

- only use this setting when I am already in a text field
- only use this setting when I am not in a text field

This is most useful when you want the same action to behave differently depending on where you dictated.

Format rules:

- use pipe-separated tokens
- do not include spaces
- `token` means "only in input fields"
- `!token` means "only outside input fields"

Examples:

```json
"inputCondition": "restoreClipboard|action"
```

```json
"inputCondition": "!restoreClipboard|!action"
```

If the condition does not apply, Macrowhisper falls back to the matching default behavior.

### 9.1 Allowed tokens

- `restoreClipboard`
- `restoreClipboardDelay`
- `simEsc`
- `nextAction`
- `moveTo`
- `action`
- `actionDelay`
- `scriptAsync` for Shortcut, shell, and AppleScript actions
- `scriptWaitTimeout` for Shortcut, shell, and AppleScript actions

### 9.2 Validation rules

`inputCondition` is rejected if:

- it contains spaces
- it contains empty tokens such as `||`
- `!` is used without a token
- the token name is not allowed for that action type

If validation fails, Macrowhisper reports the config problem and falls back to in-memory defaults until you fix it.

### 9.3 What Macrowhisper changes internally

When a token does not apply in the current context:

- booleans and numbers fall back to defaults
- `action` becomes an empty string
- values such as `moveTo` and `nextAction` fall back to defaults

In plain terms: Macrowhisper temporarily turns off the parts of the action that do not apply.

---

## 10) Chaining Actions with `nextAction`

`nextAction` lets one action call another action automatically.

You can define it:

- on the action itself
- in `defaults.nextAction`

### 10.1 Which `nextAction` wins

For the first step only:

- if the action-level `nextAction` is `null`, `defaults.nextAction` can apply
- if the action-level `nextAction` is `""`, that explicitly means "do not chain"

For later steps in the chain:

- only action-level `nextAction` is used

### 10.2 Safety checks

Macrowhisper blocks these problems:

- missing action names
- loops such as `A -> B -> A`
- more than one insert action in the same chain

### 10.3 Unique names matter

Chains resolve by action name across all action types, so duplicate names are not allowed.

### 10.4 How chains behave at runtime

- actions run one step at a time
- if one step fails, the rest of the chain still continues
- Shortcut, shell, and AppleScript steps launch asynchronously by default
- if `scriptAsync: false`, Macrowhisper waits for completion up to `scriptWaitTimeout`
- synchronous script output can be reused later through `{{actionResult}}`
- clipboard restoration is decided by the last step
- `moveTo` is based on the final executed action context
- `simEsc` comes from the first action-level setting if present, otherwise from `defaults.simEsc`

---

## 11) Placeholders

Placeholders let you insert dynamic values into any action string.

This is one of the most powerful parts of Macrowhisper.

### 11.1 Processing order

For each action payload, Macrowhisper processes values in this order:

1. Insert actions only: turn literal `\n` into real line breaks.
2. Extract XML placeholders if needed.
3. Expand placeholders such as `{{key}}`, `{{json:key}}`, `{{raw:key}}`, dates, transforms, and regex replacements.
4. Apply escaping rules based on action type.

### 11.2 Basic placeholders

- `{{swResult}}` - prefers `llmResult`, falls back to `result`
- `{{result}}`
- `{{llmResult}}`
- `{{folderName}}`
- `{{folderPath}}`
- `{{folderName:<index>}}`
- `{{folderPath:<index>}}`
- `{{actionResult}}`
- `{{actionResult:0}}`, `{{actionResult:1}}`, and so on

For most users, `{{swResult}}` is the main one to remember.

### 11.3 Date placeholders

- `{{date:short}}`
- `{{date:long}}`
- `{{date:yyyy-MM-dd}}`

### 11.4 Context placeholders

These come from Macrowhisper, not from Superwhisper:

- `{{selectedText}}`
- `{{clipboardContext}}`
- `{{appContext}}`
- `{{appVocabulary}}`
- `{{frontApp}}`
- `{{frontAppUrl}}`

These are especially useful in voice-only modes because they do not depend on an AI-processed result.

### 11.5 XML placeholders

Supported formats:

- `{{xml:tagName}}`
- `{{json:xml:tagName}}`
- `{{raw:xml:tagName}}`

Behavior:

- Macrowhisper looks for `<tagName>...</tagName>` in `llmResult` first, then in `result`
- if the tag exists, Macrowhisper inserts the content
- if the tag is empty or missing, the placeholder becomes empty
- extracted XML blocks are removed from `llmResult` before `{{swResult}}` is finalized when applicable

### 11.6 Any `meta.json` key

Any key in `meta.json` can be used as a placeholder.

Examples:

- `{{modeName}}`
- `{{languageModelName}}`
- `{{language}}`

Nested values are supported too:

- `{{promptContext.systemContext.language}}`
- `{{promptContext.modeContext.type}}`
- `{{segments.0.text}}`

About `{{segments}}`:

- when speaker data exists, consecutive words from the same speaker are merged into readable blocks
- time-like values such as `duration` and `processingTime` are shown in a human-readable format like `350ms`, `1.2s`, or `2m 05s`

If a placeholder key does not exist, it becomes an empty string.

### 11.7 Placeholder transforms with `::`

You can transform a placeholder before it is used.

Basic format:

```text
{{placeholder::transformName}}
```

Transform names are case-insensitive.

Available transforms:

- `uppercase`
- `lowercase`
- `uppercaseFirst`
- `lowercaseFirst`
- `camelCase`
- `pascalCase`
- `snakeCase`
- `kebabCase`
- `altCase`
- `altCase:upperFirst`
- `randomCase`
- `trim`
- `titleCase`
- `titleCase:en`
- `titleCase:es`
- `titleCase:fr`
- `titleCase:all`
- `ensureSentence`

Examples:

- `{{swResult::uppercase}}`
- `{{json:swResult::lowercase}}`
- `{{raw:swResult::uppercaseFirst}}`
- `{{date:short::uppercase}}`
- `{{folderName:1::lowercase}}`
- `{{swResult::ensureSentence}}`
- `{{swResult::camelCase}}`
- `{{swResult::altCase:upperFirst}}`
- `{{swResult::trim}}`

When the built-in transforms are not enough, you can use a synchronous script action to create your own transform pipeline, then pass its output to a later step through `{{actionResult}}`.

### Smart insert behavior and transforms

- transforms do not automatically disable smart insert behavior
- `smartCasing`, `smartPunctuation`, and `smartSpacing` are still controlled by config
- `ensureSentence` is a good option when you want cleaner dictation before insert
- if your transform relies on a very specific first-letter case, you may want to disable `smartCasing`

If Accessibility is unavailable or the insertion context is low-confidence, the smart insert passes are skipped.

---

## 12) When Context Is Captured

This section explains when Macrowhisper takes snapshots for context placeholders.

### 12.1 `{{selectedText}}`

Captured when the recording session starts.

### 12.2 `{{clipboardContext}}`

Session flow:

1. Macrowhisper captures recent clipboard history from the `clipboardBuffer` window before dictation starts.
2. During the session, clipboard changes are tracked.
3. `{{clipboardContext}}` is built from that session data.

Behavior details:

- if stacking is off, Macrowhisper returns one best clipboard candidate
- if stacking is on, it can return multiple items in order
- Superwhisper result text is filtered out from stacked clipboard entries
- empty clipboard entries are ignored
- apps matched by `clipboardIgnore` are ignored

When several clipboard items are returned, the output looks like this:

```xml
<clipboard-context-1>
...
</clipboard-context-1>

<clipboard-context-2>
...
</clipboard-context-2>
```

### 12.3 `{{appContext}}`

- anchored to the app that was frontmost when recording finished, before the first action step
- collected only if needed
- reused across the whole chain
- can include richer app, window, and text-field context
- includes `ACTIVE URL` only for supported browsers

### 12.4 `{{appVocabulary}}`

- anchored to the same app snapshot used for `{{appContext}}`
- collected only if needed
- reused across the whole chain
- extracts a comma-separated list of likely terms, names, or identifiers from the app's accessibility text

### 12.5 `{{frontApp}}` and `{{frontAppUrl}}`

- use the same anchored app snapshot used for triggers and chains
- stay stable across the whole chain even if focus changes while the chain is running
- `{{frontAppUrl}}` works only in supported browsers
- unsupported apps return an empty value quickly

### 12.6 CLI execution

For CLI commands such as `--exec-action`, `--run-auto`, `--get-action`, and `--copy-action`, context placeholders are captured at the moment you run the command.

Useful example:

With `--copy-action`, you can collect stacked clipboard context and then send that into Superwhisper if the selected Superwhisper mode uses clipboard capture.

---

## 13) Regex Replacements

Regex replacements work inside placeholders and run after placeholder transforms.

Basic format:

```text
{{placeholder||find_regex||replace||find_regex2||replace2}}
```

With a transform:

```text
{{placeholder::titleCase||find_regex||replace}}
```

### Capture transforms inside replacements

You can also transform captures inside the replacement value:

```text
${N::transformName}
```

`N` is the capture index:

- `0` = full match
- `1+` = capture groups

### 13.1 Examples

Remove filler words:

```text
{{swResult||(uh|um|like)||}}
```

Remove a trailing period:

```text
{{swResult||\.$||}}
```

Replace line breaks with HTML `<br>`:

```text
{{swResult||\\n||<br>}}
```

Uppercase only an acronym capture:

```text
{{swResult||\\b(api|sdk)\\b||${1::uppercase}}}
```

Mix raw and transformed captures:

```text
{{swResult||(foo)\\s+(bar)||${1} ${2::titleCase}}}
```

### 13.2 Behavior details

- replacements run in order
- invalid regex patterns are logged and skipped
- unknown transforms are logged and ignored
- capture transforms are optional
- standard replacement syntax such as `${1}` and `$1` still works

### 13.3 Prompt template for AI help

If you want ChatGPT, Claude, Gemini, or another AI to help you write a Macrowhisper placeholder regex, use this template:

```text
Output requirements (strict):
1) Return ONLY Macrowhisper placeholder snippets (no explanation text).
2) Prefer this full format when needed:
   {{swResult::transformName||pattern||replacement||pattern2||replacement2}}
3) If no placeholder-level transform is needed, use:
   {{swResult||pattern||replacement}}
4) Use regex syntax compatible with Apple NSRegularExpression.
5) Do NOT use JavaScript regex literals like /pattern/gi.
6) If case-insensitive matching is needed, use inline options in pattern (for example (?i), (?-i), (?m), (?s)).
7) Assume replacements are already global; do not add g flags.
8) Escape backslashes correctly for Macrowhisper placeholder text (example: \\b, \\s, \\n).
9) Capture references in replacement can use $1 or ${1}.
10) If capture transforms are useful, use this syntax in replacement:
    ${N::transformName}

Available transformName values:
uppercase, lowercase, uppercaseFirst, lowercaseFirst, camelCase, pascalCase,
snakeCase, kebabCase, altCase, altCase:upperFirst, randomCase, trim,
titleCase, titleCase:en, titleCase:es, titleCase:fr, titleCase:all, ensureSentence

Goal:
[Describe what should be matched, removed, or replaced]

Input examples to handle:
[Paste 3-10 realistic phrases or transcriptions]
```

Replace `swResult` with another placeholder if needed, such as `clipboardContext`.

---

## 14) Escaping Rules

Macrowhisper automatically escapes placeholder values differently depending on the action type.

### 14.1 Default escaping by action type

- Insert: no escaping
- Shortcut: no escaping
- URL: URL-encode the final value
- Shell: shell-safe escaping
- AppleScript: AppleScript-safe escaping

### 14.2 Override prefixes

Use `raw:` to disable escaping:

```text
{{raw:swResult}}
```

Example use case: Superwhisper returns AppleScript that you want to run directly.

Use `json:` to force JSON string escaping:

```text
{{json:swResult}}
```

Example:

```json
"action": "{\"input\":\"{{json:swResult}}\"}"
```

This is especially useful in Shortcut actions when the receiving side expects valid JSON.

---

## 15) Clipboard Behavior

Most users can skip this section. It matters mainly for debugging and advanced setups.

### 15.1 Why Macrowhisper handles the clipboard carefully

Superwhisper and Macrowhisper may touch the clipboard near the same time. Macrowhisper's clipboard system exists to reduce race conditions and prevent stale clipboard values from leaking into later actions.

### 15.2 The main timing values

- a short wait for Superwhisper clipboard sync before the first action in a chain: `0.1s`
- a recent-activity window to avoid unnecessary waiting: `0.5s`
- a startup duplicate-ignore window: `3s`
- the user-controlled pre-recording capture window from `clipboardBuffer`

### 15.3 The settings that matter most

- `restoreClipboard`
- `clipboardBuffer`
- `clipboardStacking`
- `clipboardIgnore`

How they work together:

- `clipboardBuffer = 0` turns off pre-recording clipboard capture
- `clipboardStacking = false` returns one best clipboard context value
- `clipboardStacking = true` can return several ordered snippets
- `restoreClipboard = true` restores the original clipboard when the action flow ends

For CLI execution (`--exec-action` and `--run-auto`):

- Macrowhisper captures one clipboard snapshot at chain start
- it restores once at the end, not after every insert step
- it only restores if a step in that CLI chain actually wrote to the clipboard
- pure URL / shell / AppleScript / Shortcut chains do not perform a fake restore write

### 15.4 `clipboardIgnore` example

```json
"clipboardIgnore": "Arc|Bitwarden|com.apple.passwords"
```

This prevents noisy clipboard events from those apps from polluting `{{clipboardContext}}`.

Macrowhisper also respects clipboard items marked as concealed.

### 15.5 Best practices

1. Keep Superwhisper clipboard restoration off.
2. Start with `clipboardBuffer: 5` if you use `{{clipboardContext}}`.
3. Turn on `clipboardStacking` only when you actually need several clipboard items.
4. Use `clipboardIgnore` for password managers and other noisy apps.
5. If clipboard behavior feels racy, try a small `actionDelay` such as `0.05` to `0.2`.

### 15.6 Async execution and clipboard

The short version:

- Macrowhisper is optimized to stay responsive
- shell, AppleScript, and Shortcut actions launch asynchronously by default
- if you need Macrowhisper to wait, set `scriptAsync: false`
- clipboard restoration happens according to `restoreClipboardDelay` on the final chain step

Because Superwhisper always interacts with the clipboard, the safest way to pass earlier clipboard content into scripts is usually to use `{{clipboardContext}}` instead of reading the live clipboard during script execution.

---

## 16) Recording File Handling

### 16.1 `moveTo`

Supported values:

- a folder path: move the processed recording folder there
- `.delete`: delete the processed folder
- `""`: do nothing
- `null` at the action level: inherit from `defaults`

### 16.2 `history`

`defaults.history` controls retention cleanup:

- `null`: keep everything
- `0`: keep only the newest recording folder
- positive integer: keep the last N days

Cleanup runs on a 24-hour check.

---

## 17) Advanced Runtime Notes

This section is for advanced behavior and edge cases.

### 17.1 `--schedule-action` and `--auto-return` are one-time

After they are used, or canceled, they are cleared.

`--run-auto` does not consume or clear those values. It ignores them and only applies bypass mode checks, trigger muting, trigger matching, and active-action fallback for the chosen recording source.

#### Auto-return details

- auto-return keeps normal runtime priority: `auto-return` -> `schedule-action` -> triggers -> active action
- it resolves the same trigger or active candidate that would normally run
- if that candidate is an insert action, Macrowhisper uses that insert action's placeholders and insert settings
- for insert actions with `inputCondition`, auto-return behaves as if `isInInputField = true`
- `nextAction` is ignored during auto-return
- if the resolved insert output is empty, `.none`, or `.autoPaste`, auto-return inserts `{{swResult}}` instead
- if the resolved candidate is non-insert or missing, Macrowhisper falls back to inserting `{{swResult}}`
- non-insert settings are ignored in that fallback case
- auto-return always forces one Return key simulation for that one-time run

### 17.2 Timeout behavior

`scheduledActionTimeout` controls how long one-time runtime modes stay pending when no recording starts.

- `0` means no timeout
- the default is `5` seconds
- if a recording is already active, the scheduled action applies to that recording without timeout

### 17.3 `bypassModes`

If the current mode is bypassed:

- no action is selected
- no action is executed
- the recording is still marked as processed

Example:

```json
"bypassModes": "dictation|raw"
```

---

## 18) Config Examples

### 18.1 Simple everyday config

```json
{
  "configVersion": 2,
  "defaults": {
    "watch": "~/Documents/superwhisper",
    "activeAction": "autoPaste",
    "actionDelay": 0,
    "returnDelay": 0.15,
    "restoreClipboard": true,
    "restoreClipboardDelay": 0.3,
    "scriptAsync": true,
    "scriptWaitTimeout": 3,
    "simReturn": false,
    "smartCasing": true,
    "smartPunctuation": true,
    "smartSpacing": true,
    "clipboardBuffer": 5,
    "clipboardStacking": false,
    "icon": "",
    "moveTo": "",
    "clipboardIgnore": "",
    "bypassModes": "",
    "nextAction": ""
  },
  "inserts": {
    "autoPaste": {
      "action": ".autoPaste",
      "icon": "•"
    },
    "emailWithDictatedLineBreaks": {
      "action": "Hey,\n\n{{swResult::ensureSentence||(?i)\\s*\\bline\\s*br(?:eak|eek|eik|iek|ick|ake)\\b[\\s.,;!?]*||\n||(?m)([^\\s.!?])(\\n+)||$1.$2||(?m)(\\n+)([a-z])||$1${2::uppercase}}}\n\nThanks,\nRobert",
      "triggerUrls": "mail.yahoo.com"
    }
  },
  "urls": {
    "google": {
      "action": "https://www.google.com/search?q={{swResult||\\.$||}}",
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

### 18.2 Chained workflow example

In this example, the user dictates into an insert action, then a URL opens, then a notification appears.

```json
{
  "configVersion": 2,
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

### 18.3 Custom transform pipeline

Use this pattern when the built-in placeholder transforms are not enough.

In this example:

- a shell action rewrites `{{swResult}}`
- `scriptAsync: false` makes Macrowhisper wait
- the script's output becomes available as `{{actionResult}}`
- the next insert action pastes the transformed result

```json
{
  "configVersion": 2,
  "defaults": {
    "watch": "~/Documents/superwhisper",
    "activeAction": "buildTicketPayload",
    "nextAction": "",
    "restoreClipboard": true
  },
  "inserts": {
    "insertTicketPayload": {
      "action": "## Ticket Draft\\n\\n{{actionResult}}\\n\\nSource App: {{frontApp}}"
    }
  },
  "urls": {},
  "shortcuts": {},
  "scriptsShell": {
    "buildTicketPayload": {
      "action": "TEXT='{{swResult}}'; CLEAN=$(printf \"%s\" \"$TEXT\" | tr '\\n' ' ' | sed -E 's/[[:space:]]+/ /g; s/^ +| +$//g'); LEET_TEXT=$(printf \"%s\" \"$CLEAN\" | tr 'aeio' '4310'); printf \"Original: %s\\nTransformed: %s\\n\" \"$TEXT\" \"$LEET_TEXT\"",
      "scriptAsync": false,
      "scriptWaitTimeout": 3,
      "nextAction": "insertTicketPayload"
    }
  },
  "scriptsAS": {}
}
```

Notes:

- `{{actionResult}}` is the first synchronous script result in the current execution group
- if you chain several synchronous script-like steps, use `{{actionResult:0}}`, `{{actionResult:1}}`, and so on
- if the script fails or times out, the chain still continues, but `{{actionResult}}` may be empty

---

## 19) Troubleshooting

When something feels off, start here.

### 19.1 First checks

1. Is the service running?

```bash
macrowhisper --service-status
```

2. Is an active action set?

```bash
macrowhisper --get-action
```

3. Do the action names exist?

```bash
macrowhisper --list-actions
```

4. Is the config valid?

```bash
macrowhisper --validate-config
```

### 19.2 Logs

For deeper debugging, set `defaults.redactedLogs` to `false`.

Log folder:

`~/Library/Logs/Macrowhisper/`

You can also use verbose mode:

```bash
macrowhisper --verbose
```

### 19.3 Common problems

#### Nothing pastes

- check macOS Accessibility permissions
- restart the service
- confirm the active action is not empty
- confirm no bypass mode is active

#### Double paste

- make sure Superwhisper's `Paste Result Text` is OFF

#### A trigger does not fire

- make sure the trigger field is not empty
- double-check `triggerLogic`
- remember that normal `triggerVoice` patterns match only at the start of the transcript
- check whether another action sorts earlier by name and matches first
- inspect the logs to see which trigger, if any, was used

#### `inputCondition` is not working

- remove spaces
- make sure token names are valid for that action type
- avoid empty segments such as `||`

#### Clipboard context feels stale or noisy

- adjust `clipboardBuffer`
- add `clipboardIgnore` patterns
- disable conflicting clipboard manager behavior
- keep Superwhisper clipboard restore off

#### Config edits are not taking effect

- save valid JSON
- check for semantic validation issues such as missing action references, invalid `inputCondition` tokens, or duplicate action names
- if the config is invalid, Macrowhisper can continue running with in-memory defaults until the file is fixed

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
curl -L https://raw.githubusercontent.com/ognistik/macrowhisper/main/scripts/install.sh | sudo sh
macrowhisper --restart-service
```

Manual update check while running:

```bash
macrowhisper --check-updates
```

---

## 21) Full Uninstall

Macrowhisper has three main parts:

**The service**

- the background process
- usually installed at `~/Library/LaunchAgents/com.aft.macrowhisper.plist`

**The binary**

- the executable itself
- usually installed by Homebrew or at `/usr/local/bin/macrowhisper`

**Your config files**

- your settings and preferences
- by default in `~/.config/macrowhisper`

### Step 1: Stop the service

```bash
macrowhisper --stop-service
```

### Step 2: Remove the service and binary

If you installed with Homebrew:

```bash
macrowhisper --uninstall-service
brew uninstall macrowhisper
```

If you installed with the script:

```bash
macrowhisper --uninstall-service
sudo rm -f /usr/local/bin/macrowhisper
```

### Step 3: Optional cleanup

```shell
# Remove config
rm -rf ~/.config/macrowhisper

# Remove logs
rm -rf ~/Library/Logs/Macrowhisper
```

Repository and issue tracker:

- [Macrowhisper on GitHub](https://github.com/ognistik/macrowhisper)
