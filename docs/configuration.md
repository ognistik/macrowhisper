# Configuration

[← Documentation index](README.md) · [Actions](actions.md) · [Triggers and conditions](triggers-and-conditions.md) · [Examples](examples.md)

## Configuration Basics

This section is the best place to start if you want to customize behavior.

### The top-level structure

```json
{
  "$schema": "file:///path/to/macrowhisper-schema.json",
  "configVersion": 3,
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
- most users never need to edit the schema path by hand

### The recommended workflow

For most people, the safest setup is:

- keep `"autoUpdateConfig": true`
- let Macrowhisper migrate older config versions on startup
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

### A simple way to think about defaults and overrides

Use this mental model:

- `defaults` = your normal behavior
- action-level values = exceptions for one specific action

In `configVersion: 2` and later:

- action-level `null` usually means "inherit from `defaults`"
- `""` usually means "intentionally empty"

Important exceptions:

- `defaults.activeAction`: `null` or `""` means there is no fallback action
- `action`: an empty string skips the action's payload operation; the action can still apply its other lifecycle settings

Quick reference:

| Field type | If action value is `null` or omitted | If action value is set |
| --- | --- | --- |
| Boolean and number overrides such as `simEsc`, `restoreClipboard`, `actionDelay`, `simReturn`, `simKeypress`, `smartCasing`, `smartPunctuation`, `smartSpacing` | Use the matching value from `defaults` | The action value wins |
| `moveTo` | Use `defaults.moveTo` | A nonempty path or `.delete` overrides the default; `""` keeps the recording folder in place, even when `defaults.moveTo` is nonempty |
| `icon` | Use `defaults.icon` | The action value wins |
| `nextAction` | Use `defaults.nextAction` on the first step only | The action value wins |
| `action` | No fallback from `defaults` | The action payload is used directly |

### Special `action` values

Macrowhisper includes a few built-in action shortcuts.

#### All action types

- `action: ".none"`

This applies:

- `action = ""`
- `inputCondition = ""`
- `simEsc = false`
- `restoreClipboard = false`

Use it when you want this action's payload skipped and its ESC simulation and clipboard restoration disabled. Other lifecycle settings, including `actionDelay`, `simReturn`, `nextAction`, and `moveTo`, can still apply.

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

### Empty and `null` values that turn things off

| Field | Empty or `null` means |
| --- | --- |
| `defaults.activeAction` | No fallback action |
| `defaults.nextAction` | No default next step |
| `defaults.bypassModes` | Bypass behavior is off |
| `defaults.clipboardIgnore` | No clipboard ignore rules |
| `triggerVoice` / `triggerApps` / `triggerModes` / `triggerUrls` | That trigger type is not configured |

### Quick examples

```json
"action": ""
```

Meaning: skip the action's payload operation. Other lifecycle settings, such as `actionDelay` or an insert's `simReturn`, can still apply.

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

### For advanced users

If you prefer editing everything by hand:

- `defaults` is required
- `defaults.watch` may be omitted or set to `null`; both use the built-in default watch folder
- any action you define must include `action`
- `autoUpdateConfig` defaults to `true`, so set it to `false` only if you want to run version migrations yourself

If you want to go back to a built-in root default later, set that defaults value to null (or remove it). Macrowhisper resolves the value in memory without rewriting a current-version file merely because the service restarted.

Versioning notes:

- `configVersion: 3` is the current format
- if `configVersion` is missing, Macrowhisper treats it as version 1 behavior
- with `autoUpdateConfig: true`, startup migrates older files one version at a time; a current-version file is left byte-for-byte unchanged
- each migration target creates one immutable `<filename>.backup.pre-vN` copy before replacing the older file; migration does not create the rolling editor backup
- with `autoUpdateConfig: false`, an older file continues to run through the compatibility layer but stays unchanged on disk; the web editor is read-only until you choose its **Update to version 3** action or run `macrowhisper --update-config`
- when notifications are enabled, a genuinely new background-service process reminds you about an older manually managed configuration; live reloads, config-path changes, watcher resets, editor commands, and ordinary action commands do not show that reminder
- legacy files may use `noUpdates`, `noNoti`, `noEsc`, and `pressReturn`; Macrowhisper reads these aliases and maps them to the current setting names
- version 2 introduced explicit empty values: use `""` for an explicit empty `icon` or `moveTo` value because `.none` is reserved for action templates

### Insert escaping in version 3

There are two separate layers when an Insert action is stored in the JSON
configuration:

| Meaning | Macrowhisper Insert syntax | JSON source |
| --- | --- | --- |
| Line break | `\n` | `\\n` |
| Literal backslash followed by `n` | `\\n` | `\\\\n` |
| Regex word boundary | `\b` | `\\b` |

This is ordinary JSON behavior followed by Macrowhisper Insert parsing.
For example, JSON `"\b"` is valid but decodes to the backspace control character;
it is not a regex word boundary. Write `"\\b"` in JSON when the regex engine
needs `\b`.

The version 3 migration canonicalizes newline spellings throughout Insert action
text, including placeholder regex arguments. This matches the scope of the old
Insert compatibility behavior while making its result explicit. After migration,
a single Macrowhisper `\n` means a line break and doubled `\\n` is how you
request the literal characters `\n`.

---

## Global Defaults Reference

These settings live under `defaults`.

At the defaults level, `null` is accepted for backward compatibility and resolves to the built-in value in memory. Version migration may persist the corresponding explicit value; restarting with a current-version file does not rewrite it.

When Macrowhisper creates a configuration, it selects the Superwhisper folder once and writes the resolved path to `defaults.watch`. It first honors Superwhisper's configured folder, then checks the current `~/superwhisper` and legacy `~/Documents/superwhisper` locations. Paths inside the user's home directory are written with `~` so configs stay portable and do not expose the local username; custom locations outside the home directory remain absolute. If Superwhisper has not created either folder yet, Macrowhisper uses `~/superwhisper`, matching new Superwhisper installations. Healthy explicit `watch` values are never migrated automatically. If a configured recordings folder later moves or disappears, Macrowhisper checks Superwhisper's current preference and the known legacy-to-current location, requires a real replacement `recordings` folder, and persists an unambiguous repair. If recovery is not immediately possible, Macrowhisper waits for the original folder to return and occasionally checks whether Superwhisper's setting now points to a valid location. This lightweight recovery monitoring stops as soon as the recordings folder is available again.

| Key | Type | Default | What it controls |
| --- | --- | --- | --- |
| `watch` | string/null | detected once when generated | Path to the Superwhisper folder that contains `recordings`. New configs usually use `~/superwhisper`; legacy and custom Superwhisper locations are detected and preserved. Omit or use `null` only for backward compatibility with the legacy built-in fallback. |
| `disableUpdateCheck` | bool/null | `false` | Turns periodic update checks off. |
| `muteNotifications` | bool/null | `false` | Turns notifications off. |
| `activeAction` | string/null | `"autoPaste"` in generated starter configs | Fallback action when no trigger matches. If a `defaults` object explicitly omits this key, or sets it to empty/`null`, there is no fallback action. |
| `icon` | string/null | `""` | Default icon for actions. Empty or `null` means no default icon. |
| `moveTo` | string/null | `""` | Destination path for processed recording folders, or `.delete` to remove them. Empty or `null` means no default move behavior. |
| `simEsc` | bool/null | `true` | Simulate ESC before actions. |
| `simKeypress` | bool/null | `false` | Type characters instead of pasting for insert actions. |
| `smartCasing` | bool/null | `true` | Adjust capitalization at insert boundaries. |
| `smartPunctuation` | bool/null | `true` | Clean punctuation conflicts at insert boundaries. |
| `smartSpacing` | bool/null | `true` | Clean spacing at insert boundaries. |
| `actionDelay` | number/null | `0` | Delay before the action starts. |
| `history` | int/null | `null` | Retention in days. `null` keeps history indefinitely; `0` keeps only the newest folder. |
| `simReturn` | bool/null | `false` | Press Return after an insert action, including empty or `.none` inserts. |
| `returnDelay` | number/null | `0.15` | Delay before pressing Return. |
| `restoreClipboard` | bool/null | `true` | Restore the original clipboard after the action flow ends. |
| `restoreClipboardDelay` | number/null | `0.3` | Delay before restoring the clipboard. |
| `scheduledActionTimeout` | number/null | `5` | How long one-time auto-return and scheduled actions stay pending when no recording starts. `0` disables the timeout. |
| `scriptAsync` | bool/null | `true` | Whether Shortcut, shell, and AppleScript actions run asynchronously by default. |
| `scriptWaitTimeout` | number/null | `3` | Max wait time when `scriptAsync` is `false`; the runtime uses at least `0.1` seconds. |
| `clipboardStacking` | bool/null | `false` | Choose all eligible clipboard operations or only the most recent one for text context and attachment handoff. Actions can override it. |
| `clipboardAttachments` | bool/null | `false` | Preserve supported files and raw images for a later manual paste, independently of `{{clipboardContext}}` placeholder use. Actions can override it. |
| `clipboardBuffer` | number/null | `5` | How many seconds of clipboard history to capture before recording. `0` disables the buffer. |
| `clipboardIgnore` | string/null | `""` | Case-insensitive regex checked against the front app name or bundle ID during clipboard capture. Empty or `null` means no ignore rules. |
| `bypassModes` | string/null | `""` | Pipe-separated Superwhisper mode names that exactly match, case-insensitively, to bypass Macrowhisper. Empty or `null` disables bypass. |
| `muteTriggers` | bool/null | `false` | Mute trigger matching globally. |
| `autoUpdateConfig` | bool/null | `true` | Allow startup to migrate an older `configVersion`. Current-version files are not rewritten. `false` leaves version migration to `--update-config` or the editor. |
| `redactedLogs` | bool/null | `true` | Hide sensitive content in logs. |
| `nextAction` | string/null | `""` | Default next action to use as the first chain step. Empty or `null` means no default chain step. |

Practical note about `actionDelay`:

By default it is `0`, which is usually fine. But URL and script actions can sometimes happen before Superwhisper's recording window has fully settled. If that creates UI timing issues, try a small delay such as `0.05` to `0.2`.

### Validation rules involving defaults

- `defaults.activeAction` must exist if it is not empty
- `defaults.nextAction` must exist if it is not empty
- `defaults.activeAction` cannot equal `defaults.nextAction`

---
