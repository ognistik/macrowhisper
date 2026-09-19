# Placeholders and Context

[← Documentation index](README.md) · [Actions](actions.md) · [Clipboard and recordings](clipboard-and-recordings.md)

## Placeholders

Placeholders let you insert dynamic values into any action string.

This is one of the most powerful parts of Macrowhisper.

### Processing order

For each action payload, Macrowhisper processes values in this order:

1. Parse placeholder structure and decode its versioned argument escapes.
2. Extract requested XML tag content and remove those blocks from the selected Superwhisper result.
3. Resolve each placeholder value, then apply its transform and ordered regex replacements.
4. Apply escaping rules based on action type.

### Basic placeholders

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

Folder indexes are zero-based. Index `0` points to the most recent active recording folder when one exists; subsequent indexes use valid completed folders in newest-first order. A completed folder is eligible when its `meta.json` has a non-empty `result`, or, when `languageModelName` is non-empty, a non-empty `llmResult`. Missing, invalid, or out-of-range indexes resolve to an empty value. CLI commands that resolve the latest valid result can skip newer completed folders still waiting for `llmResult` and use an older valid folder instead.

### Date placeholders

- `{{date:short}}`
- `{{date:long}}`
- `{{date:yyyy-MM-dd}}`

### Context placeholders

These come from Macrowhisper, not from Superwhisper:

- `{{selectedText}}`
- `{{clipboardContext}}`
- `{{appContext}}`
- `{{appVocabulary}}`
- `{{frontApp}}`
- `{{frontAppUrl}}`

These are especially useful in voice-only modes because they do not depend on an AI-processed result.

### XML placeholders

Supported formats:

- `{{xml:tagName}}`
- `{{json:xml:tagName}}`
- `{{raw:xml:tagName}}`

XML values support the same transform and regex suffixes as other placeholders:

- `{{xml:tagName::trim}}`
- `{{xml:tagName::uppercase||\s+|| }}`
- `{{json:xml:tagName::ensureSentence}}`

Behavior:

- when `llmResult` is non-empty, Macrowhisper looks for `<tagName>...</tagName>` there; otherwise it looks in a non-empty `result`
- if the tag exists, Macrowhisper inserts the content
- if the tag is empty or missing, the placeholder becomes empty
- extracted XML blocks are removed from whichever source was used before `{{swResult}}`, `{{llmResult}}`, or `{{result}}` is finalized
- transforms and regex replacements operate on the extracted tag content before final action-specific, `json:`, or `raw:` escaping
- placeholder-looking text inside an extracted tag remains literal content; Macrowhisper does not expand it as another placeholder

### Metadata keys and paths

A metadata key or dot path can be used as a placeholder when each key component contains letters, numbers, or underscores.

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
- time-like values such as `duration`, `languageModelProcessingTime`, and `processingTime` are shown in a human-readable format like `350ms`, `1.2s`, or `2m 5s`

If a placeholder key does not exist, it becomes an empty string.

Valid metadata keys and dot paths use the same `::transform` and
`||regex||replacement` pipeline as built-in placeholders.

### Placeholder transforms with `::`

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

## When Context Is Captured

This section explains when Macrowhisper takes snapshots for context placeholders.

### `{{selectedText}}`

Captured when the recording session starts when Accessibility can read a selection; otherwise it is empty.

### `{{clipboardContext}}`

Session flow:

1. Macrowhisper captures recent clipboard history from the `clipboardBuffer` window before dictation starts.
2. During the session, clipboard changes are tracked.
3. `{{clipboardContext}}` is built from that session data.

Behavior details:

- if stacking is off, Macrowhisper selects the latest eligible clipboard operation as a unit; an attachment-only winner produces an empty string value
- if stacking is on, it returns eligible text values in order while retaining attachment operations in the same capture order for native handoff
- Superwhisper result text is filtered before either representation is selected; single-item mode then uses the latest remaining text operation unless attachment capture is enabled and the latest eligible operation is attachment-classified, in which case its string projection is empty
- empty clipboard entries are ignored
- apps matched by `clipboardIgnore` are ignored

The selected root action controls stacking for the full action chain. Its `clipboardStacking` value inherits from `defaults.clipboardStacking` when it is `null` or omitted. A chained action's override applies when that action is invoked directly as the root of its own chain.

If unwanted clipboard content is captured, run `macrowhisper --reset-clipboard` before the recording finishes and its action runs. Macrowhisper discards the clipboard context captured so far and starts collecting new copies from that point. This works with both single-item capture and clipboard stacking, and it does not clear or modify the macOS clipboard itself.

When no recording is active, the command resets the pre-recording clipboard buffer instead. This lets you clear unwanted buffered context before starting the next dictation.

When several clipboard items are returned, the output looks like this:

```xml
<clipboard-context-1>
...
</clipboard-context-1>

<clipboard-context-2>
...
</clipboard-context-2>
```

### `{{appContext}}`

- anchored to the app that was frontmost when recording finished, before the first action step
- collected only if needed
- reused across the whole chain
- can include richer app, window, and text-field context
- includes `ACTIVE URL` only for supported browsers

### `{{appVocabulary}}`

- anchored to the same app snapshot used for `{{appContext}}`
- collected only if needed
- reused across the whole chain
- extracts a comma-separated list of likely terms, names, or identifiers from the app's accessibility text
- recognized browsers can contribute readable web-area content as well as window and focused-element text

### `{{frontApp}}` and `{{frontAppUrl}}`

- use the same anchored app snapshot used for triggers and chains
- stay stable across the whole chain even if focus changes while the chain is running
- `{{frontAppUrl}}` works only in supported browsers
- unsupported apps return an empty value quickly

For a supported browser, URL candidates come from Accessibility data and are normalized before use. A value without a scheme is treated as `https://...`; values without a usable host are discarded. Arc's command-bar fallback requires a path, query, or fragment, so a host-only command-bar value is ignored.

### CLI execution

For CLI commands such as `--exec-action`, `--run-auto`, `--get-action`, and `--copy-action`, context placeholders are captured at the moment you run the command.

For `--copy-action`, context placeholders use live invocation-time state instead of stored session snapshots. This includes `selectedText`, `clipboardContext`, `frontApp`, `frontAppUrl`, `appContext`, and `appVocabulary`. Action execution paths still use the normal frozen validated context for the running action chain.

Useful example:

With `--copy-action`, you can collect stacked clipboard context and then send that into Superwhisper if the selected Superwhisper mode uses clipboard capture.

---

## Regex Replacements

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

### Examples

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
{{swResult||\n||<br>}}
```

Uppercase only an acronym capture:

```text
{{swResult||\b(api|sdk)\b||${1::uppercase}}}
```

Mix raw and transformed captures:

```text
{{swResult||(foo)\s+(bar)||${1} ${2::titleCase}}}
```

### Behavior details

- replacements run in order
- invalid regex patterns are logged and skipped
- unknown transforms are logged and ignored
- capture transforms are optional
- standard replacement syntax such as `${1}` and `$1` still works

### Escapes and replacement line breaks

Configuration version 3 gives Insert action text one canonical escape language.
In the action, `\n` means a line break and `\\n` means the literal characters
`\n`. The same rule therefore applies inside placeholder arguments. Other regex
escapes keep their normal meaning: `\b` is a regex word boundary, while `\\b`
passes a literal backslash and `b` to the regex engine.

JSON is a separate serialization layer. A backslash that must reach the
placeholder parser is itself escaped in JSON:

| Meaning | Placeholder text | JSON source |
| --- | --- | --- |
| Line break | `\n` | `\\n` |
| Literal `\n` | `\\n` | `\\\\n` |
| Regex word boundary | `\b` | `\\b` |

The web editor hides the JSON layer. In a replacement helper, pressing Return
stores a real semantic line break. Typing `\n` there produces the same value,
while typing `\\n` requests a literal `\n`. The surrounding Custom text remains
visually multiline for ordinary action text, but each complete placeholder
displays its canonical inline spelling. A semantic line break outside a
placeholder is therefore shown as a real line break; the same value in a
placeholder argument is shown as `\n`. A Return typed while hand-writing a
complete placeholder stays visible during that edit and is normalized to `\n`
when the field commits. Incomplete placeholder text is treated as ordinary
multiline text until it has closing braces. In ordinary Custom text, `\\n`
remains the unambiguous visible spelling for a literal backslash followed by
`n`.

Version 1 and 2 files retain their historical behavior through the compatibility
loader. Migrating to version 3 rewrites ambiguous Insert newline spellings to
their canonical form while preserving what those actions produced before.

### Prompt template for AI help

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
8) Use Macrowhisper placeholder escapes directly (example: \b, \s, \n). When placing the result in JSON, escape each backslash once more.
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

## Escaping Rules

Macrowhisper automatically escapes placeholder values differently depending on the action type.

### Default escaping by action type

- Insert: no escaping
- Shortcut: no escaping
- URL: URL-encode the final value
- Shell: shell-safe escaping
- AppleScript: AppleScript-safe escaping

### Override prefixes

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
