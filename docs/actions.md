# Actions

[← Documentation index](README.md) · [Triggers and conditions](triggers-and-conditions.md) · [Placeholders and context](placeholders-and-context.md) · [Configuration](configuration.md)

## Action Types

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
| `""` | All action types | Skip the payload operation |
| `.none` | All action types | Use the built-in do-nothing template |
| `.autoPaste` | Insert actions only | Use Superwhisper-like auto-paste behavior |
| `.run` | Shortcut actions only | Run the Shortcut with no input |

`.none` clears this action's payload, input condition, ESC simulation, and clipboard restoration. Its delay, Return, chain, and recording-folder settings can still apply.

### Fields used by actions

| Field | Type | Meaning |
| --- | --- | --- |
| `action` | string | The main payload for the action |
| `icon` | string/null | Override the icon for this action |
| `moveTo` | string/null | Override recording-folder handling for this action |
| `simEsc` | bool/null | Simulate ESC before this action |
| `actionDelay` | number/null | Delay before this action starts |
| `restoreClipboard` | bool/null | Override clipboard restoration |
| `restoreClipboardDelay` | number/null | Override clipboard restoration delay |
| `clipboardStacking` | bool/null | Override clipboard stacking for this action and its chain |
| `clipboardAttachments` | bool/null | Override attachment handoff for this action and its chain |
| `scriptAsync` | bool/null | Override async behavior for Shortcut, shell, or AppleScript actions |
| `scriptWaitTimeout` | number/null | Override how long Macrowhisper waits when `scriptAsync` is `false`; values below `0.1` seconds are clamped at runtime |
| `inputCondition` | string/null | Apply some fields only in or outside input fields |
| `nextAction` | string/null | Chain to another action |
| `triggerVoice` | string/null | Match by spoken phrase |
| `triggerApps` | string/null | Match by front app name or bundle ID |
| `triggerModes` | string/null | Match by Superwhisper mode |
| `triggerUrls` | string/null | Match by active browser URL |
| `triggerLogic` | string/null | Use `or` or `and` when combining trigger types; other values invalidate the configuration |

How to interpret those fields:

- `null` on most boolean and number overrides means "use the default"
- for `clipboardStacking`, `null` inherits `defaults.clipboardStacking`, while `true` and `false` explicitly override it
- for `clipboardAttachments`, `null` inherits `defaults.clipboardAttachments`, while `true` and `false` explicitly override it for the full chain
- for `icon` and `nextAction`, `null` means inherit, while `""` means intentionally empty
- for `moveTo`, `null` or omission inherits `defaults.moveTo`, `""` keeps the recording folder in place even when that default is nonempty, and a nonempty path or `.delete` overrides the default
- `trigger*` fields help Macrowhisper choose the action; a normal positive `triggerVoice` match also removes the spoken prefix, or a suffix marked with leading `*`, before the payload is expanded

### Common field examples

```json
"icon": "※"
```

```json
"icon": ""
```

An empty `icon` explicitly disables the icon for this action. `.none` is an action value, not a current configuration icon value.

```json
"moveTo": ".delete"
```

```json
"actionDelay": 0.02
```

```json
"restoreClipboard": null
```

```json
"clipboardStacking": true
```

### Insert actions

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
| `simReturn` | bool/null | `true`, `false`, `null` | Press Return after insertion, including empty or `.none` inserts. |

If Accessibility is unavailable or the insertion context is low-confidence, smart casing, smart punctuation, and smart spacing are skipped for that insertion.

When the context is available, smart casing lowercases a mid-sentence first letter and uppercases strong sentence or line starts while preserving headings, lists, `I`, and all-uppercase words. Smart punctuation removes conflicting boundary punctuation, including terminal `.`, `!`, or `?` when text is being continued, and does not add punctuation. Smart spacing adjusts word and wrapper boundaries without adding a space where whitespace already exists. Macrowhisper trims surrounding whitespace from the text before these checks.

If an insert also chains with `nextAction`, any required `simReturn` happens before Macrowhisper starts the next step.

The first action selected for a chain controls clipboard stacking and attachment handoff for the whole chain. A later action's override takes effect when that action is invoked as the root action of a separate run.

Examples:

```json
"emailDraft": {
  "action": "Hi,\\n\\n{{swResult}}\\n\\nThanks,",
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

### URL actions

URL actions open websites or apps.

Extra URL-only fields:

- `openWith` - app name, app path, or bundle ID used with `open`
- `openBackground` - open without focus

| Field | Type | Typical values | Notes |
| --- | --- | --- | --- |
| `action` | string | `"https://...{{swResult}}"`, `".none"` | The URL or template to open. |
| `openWith` | string/null | `"Safari"`, `"com.google.Chrome"` | Passed to `open -a`. |
| `openBackground` | bool/null | `true`, `false`, `null` | `true` opens in the background. |

An empty or `null` `openWith` uses the system default application. `false` or `null` `openBackground` keeps the normal foreground behavior.

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

### Shortcut actions

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

### Shell actions

Shell actions run Terminal commands.

| Field | Type | Typical values | Notes |
| --- | --- | --- | --- |
| `action` | string | `"echo '{{swResult}}' \| pbcopy"`, `".none"` | The shell command to run. |

By default, shell actions launch asynchronously. If you want Macrowhisper to wait for completion before continuing, set `scriptAsync: false`.

Examples:

```json
"copyResult": {
  "action": "echo '{{swResult}}' | pbcopy",
  "restoreClipboard": false,
  "triggerVoice": "copy result"
}
```

```json
"logMode": {
  "action": "echo 'Mode: {{modeName}} | Text: {{swResult}}' >> ~/Desktop/mw-log.txt"
}
```

### AppleScript actions

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

Context placeholders are escaped differently depending on action type. See [Escaping Rules](placeholders-and-context.md#escaping-rules).

---

## Chaining Actions with `nextAction`

`nextAction` lets one action call another action automatically.

Chains can mix action types freely, including multiple insert steps.

You can define it:

- on the action itself
- in `defaults.nextAction`

### Which `nextAction` wins

For the first step only:

- if the action-level `nextAction` is `null`, `defaults.nextAction` can apply
- if the action-level `nextAction` is `""`, that explicitly means "do not chain"

For later steps in the chain:

- only action-level `nextAction` is used

### Safety checks

Macrowhisper blocks these problems:

- missing action names
- loops such as `A -> B -> A`

### Unique names matter

Chains resolve by action name across all action types, so duplicate names are not allowed.

### How chains behave at runtime

- actions run one step at a time
- for insert steps, any `simReturn` or one-time auto-return Return press happens before the next chained step begins
- if one step fails, the rest of the chain still continues
- Shortcut, shell, and AppleScript steps launch asynchronously by default
- if `scriptAsync: false`, Macrowhisper waits for completion up to `scriptWaitTimeout` (at least `0.1` seconds at runtime)
- synchronous script output can be reused later through `{{actionResult}}`
- clipboard restoration is decided by the last step
- `moveTo` is resolved from the final executed action: `null` or omission inherits `defaults.moveTo`, `""` keeps the recording folder in place, and a nonempty path or `.delete` overrides the default
- `simEsc` comes from the first action-level setting if present, otherwise from `defaults.simEsc`
- `inputCondition` is evaluated live for each executed step
- `frontApp`, `appContext`, and `appVocabulary` stay frozen for the whole chain

---
