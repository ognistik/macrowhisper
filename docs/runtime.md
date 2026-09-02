# Runtime

[← Documentation index](README.md) · [CLI reference](cli-reference.md) · [Triggers and conditions](triggers-and-conditions.md)

## Advanced Runtime Notes

This section is for advanced behavior and edge cases.

### `--schedule-action` and `--auto-return` are one-time

After they are used, or canceled, they are cleared.

`--run-auto` does not consume or clear those values. It ignores them and only applies bypass mode checks, trigger muting, trigger matching, and active-action fallback for the chosen recording source.

#### Auto-return details

- auto-return keeps normal runtime priority: `auto-return` -> `schedule-action` -> triggers -> active action
- it resolves the same trigger or active candidate that would normally run
- when several triggers match, it uses the same built-in voice -> mode -> URL -> app order before adding the one-time Return press
- if that candidate is an insert action, Macrowhisper uses that insert action's placeholders and insert settings
- for insert actions with `inputCondition`, auto-return behaves as if `isInInputField = true`
- `nextAction` is ignored during auto-return
- if the resolved insert output is empty, `.none`, or `.autoPaste`, auto-return inserts `{{swResult}}` instead
- if the resolved candidate is non-insert or missing, Macrowhisper falls back to inserting `{{swResult}}`
- non-insert settings are ignored in that fallback case
- auto-return always forces one Return key simulation for that one-time run

### Timeout behavior

`scheduledActionTimeout` controls how long one-time runtime modes stay pending when no recording starts.

- `0` means no timeout
- the default is `5` seconds
- if a recording is already active, the scheduled action applies to that recording without timeout

### `bypassModes`

If the current mode is bypassed:

- no action is selected
- no action is executed
- the recording is still marked as processed

Example:

```json
"bypassModes": "dictation|raw"
```

---
