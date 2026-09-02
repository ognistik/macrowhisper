# Triggers and Conditions

[← Documentation index](README.md) · [Actions](actions.md) · [Configuration](configuration.md)

## Triggers

Triggers help Macrowhisper decide when an action should run automatically.

Triggered actions are evaluated across all action types. If several actions match, Macrowhisper uses the trigger that most clearly reflects the user's current intent:

1. voice trigger
2. Superwhisper mode trigger
3. browser URL trigger
4. front app trigger

This priority is built in; there is nothing extra to configure. Macrowhisper uses the trigger type that actually matched an action, prefers more specific required conditions, voice phrases, and URLs within the same level, and uses the action name only as the final tie-breaker. Positive matches take priority over rules made only from exceptions.

Important priority reminder:

- a matching `defaults.bypassModes` entry skips processing entirely, including one-time commands, scheduled actions, triggers, and the active action
- otherwise one-shot `--auto-return` wins first, followed by `--schedule-action`
- then trigger matching
- then `defaults.activeAction`

If `defaults.muteTriggers` is on, or a temporary trigger mute is active, Macrowhisper skips trigger matching and moves on to the active action.

### `triggerVoice`

Use `triggerVoice` when you want spoken phrases to trigger actions.

Normal voice patterns are:

- prefix-only
- case-insensitive
- treated as literal text
- separated with `|`

The separator is ignored inside a `==...==` raw-regex wrapper, so `|` can remain part of that expression.

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
- raw regex is case-insensitive by default; start the expression with `(?i)` or `(?-i)` when you want to state the case behavior explicitly

#### Exception patterns

Use `!` to define exceptions.

Example:

```json
"triggerVoice": "!test|!debug"
```

If a trigger list contains only exceptions, the action matches whenever none of those exceptions match.

When positive and exception patterns are mixed, at least one positive pattern must match and no exception may match.

### `triggerApps`

Use `triggerApps` when an action should run only in certain apps.

It matches against:

- the front app name
- the front app bundle ID

Rules:

- direct regex, no `==...==` wrapper needed
- case-insensitive by default
- `|` separates patterns and `!` prefixes exceptions
- `(?i)` and `(?-i)` can set case behavior

Example:

```json
"triggerApps": "Mail|com.apple.mail"
```

### `triggerModes`

Use `triggerModes` when you want a rule tied to a Superwhisper mode.

It matches against `modeName` and follows the same rules as `triggerApps`.

If Superwhisper does not provide a mode name, or provides an empty one, a configured mode trigger does not match. This includes mode trigger lists made only from exceptions.

Example:

```json
"triggerModes": "dictation|Super|Custom"
```

### `triggerUrls`

Use `triggerUrls` when behavior should change depending on the current browser page.

Rules:

- `|` separates tokens
- `!` creates exception tokens
- empty tokens are ignored

Token types:

- domain token: no scheme, such as `google.com`
- full URL token: starts with `http://` or `https://`

URL matching details:

- a no-scheme domain token matches the host and its subdomains
- a full URL token matches the exact host; an optional port must match when specified
- a path or query suffix is a case-insensitive prefix, so `https://www.google.com/issues` matches `/issues/123` but not `/maps`
- `http://` and `https://` are treated the same for matching
- `*` is unsupported; invalid tokens are skipped when another valid token can still match, and an all-invalid list does not match

Examples:

- `google.com` matches `google.com`, `www.google.com`, and `docs.google.com`
- `www.google.com` matches `www.google.com` and deeper subdomains under it
- `www.google.com` does not match `maps.google.com`
- `https://google.com` matches `http://google.com/maps`
- `https://google.com` does not match `docs.google.com`

If no active browser URL is available, a URL trigger does not match. URL capture works only for supported browsers. If your browser is not behaving correctly with `triggerUrls`, open a GitHub issue with details.

### `triggerLogic`

Use `triggerLogic` to combine trigger types:

- `or` means any configured trigger type can match
- `and` means all configured trigger types must match
- omitted or `null` uses `or`; other values are treated as `or` at runtime

If all trigger fields are empty, the action will not auto-trigger. It can still run as the active action or via `--schedule-action`.

### What happens to spoken trigger words

For normal, non-regex voice triggers:

- the matched prefix is removed from `result`
- during trigger-executed flows, Macrowhisper also tries to remove the equivalent prefix from `llmResult`
- leading punctuation and whitespace after the removed prefix are cleaned up
- the first remaining character is uppercased

That is why a phrase like `google best pizza` can trigger a search and still pass clean text into the URL.

---

## Conditional Behavior with `inputCondition`

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

### Allowed tokens

- `restoreClipboard`
- `restoreClipboardDelay`
- `simEsc`
- `simReturn` for insert actions
- `nextAction`
- `moveTo`
- `action`
- `actionDelay`
- `scriptAsync` for Shortcut, shell, and AppleScript actions
- `scriptWaitTimeout` for Shortcut, shell, and AppleScript actions

### Validation rules

`inputCondition` is rejected if:

- it contains spaces
- it contains empty tokens such as `||`
- `!` is used without a token
- the token name is not allowed for that action type

If validation fails, Macrowhisper reports the config problem and falls back to in-memory defaults until you fix it.

For compatibility, the legacy `noEsc` spelling in an `inputCondition` is normalized to the current `simEsc` token when an older configuration is loaded.

### What Macrowhisper changes internally

When a token does not apply in the current context:

- booleans and numbers fall back to defaults
- `action` becomes an empty string
- values such as `moveTo` and `nextAction` fall back to defaults

In plain terms: Macrowhisper temporarily turns off the parts of the action that do not apply.

---
