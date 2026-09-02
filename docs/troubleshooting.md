# Troubleshooting

[← Documentation index](README.md) · [CLI reference](cli-reference.md) · [Configuration](configuration.md)

When something feels off, start here.

## First checks

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

## Logs

For deeper debugging, set `defaults.redactedLogs` to `false`.

Log folder:

`~/Library/Logs/Macrowhisper/`

You can also use verbose mode:

```bash
macrowhisper --verbose
```

## Common problems

### Nothing pastes

- check macOS Accessibility permissions
- restart the service
- confirm the active action is not empty
- confirm no bypass mode is active

### Double paste

- make sure Superwhisper's `Paste Result Text` is OFF

### A trigger does not fire

- make sure the trigger field is not empty
- double-check `triggerLogic`
- remember that normal `triggerVoice` patterns match only at the start of the transcript
- check whether another action matched through a higher-priority trigger (voice, mode, URL, then app)
- inspect the logs to see which trigger, if any, was used

### `inputCondition` is not working

- remove spaces
- make sure token names are valid for that action type
- avoid empty segments such as `||`

### Clipboard context feels stale or noisy

- adjust `clipboardBuffer`
- add `clipboardIgnore` patterns
- disable conflicting clipboard manager behavior
- keep Superwhisper clipboard restore off

### Config edits are not taking effect

- save valid JSON
- check for semantic validation issues such as missing action references, invalid `inputCondition` tokens, or duplicate action names
- if the config is invalid, Macrowhisper can continue running with in-memory defaults until the file is fixed

---
