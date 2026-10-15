# Runtime

[← Documentation index](README.md) · [CLI reference](cli-reference.md) · [Triggers and conditions](triggers-and-conditions.md)

## Advanced Runtime Notes

This section is for advanced behavior and edge cases.

### `--schedule-action` and `--auto-return` are one-time

After they are used, or canceled, they are cleared.

`--run-auto` does not consume or clear those values. It ignores them and only applies bypass mode checks, trigger muting, trigger matching, and active-action fallback for the chosen recording source.

The two modes are mutually exclusive: enabling auto-return cancels a
scheduled action, and scheduling an action disables auto-return. If a recording
session is already active, either mode applies to that session immediately;
otherwise it waits for the next single recording arrival.

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
- if a recording is already active, either one-time mode applies to that recording without starting a timeout

### Recording readiness and arrival boundaries

The watcher only processes recordings that arrive after startup as a single
new directory. Existing directories are marked processed when the watcher
starts. If several new directories arrive in one filesystem event, all are
marked processed and none is executed; an older directory arriving later is
also skipped as a cloud-sync copy. A newer single arrival can supersede an
incomplete recording and trigger recovery before processing the new session.

The watcher checks metadata `kind` before waiting for a transcription result.
If it matches `meeting` after surrounding whitespace is trimmed, without
regard to case, the recording is skipped. Other `kind` values and metadata
without `kind` continue through normal processing.

Macrowhisper waits for a non-empty string in the field appropriate to the
recording metadata: `llmResult` when `languageModelName` is non-empty, and
`result` otherwise. For the integrated S1 pair (`languageModelKey` `sl-1` and
`modelKey` `sv-1`), a non-empty `llmResult` with an empty `result` receives a
one-second settle grace period before the LLM result is accepted. Malformed or
incomplete metadata remains watched for a later update.

CLI commands that use the latest recording by default skip meetings, as do the
folder lookup commands. An explicit `--meta` can select one for an action
command.

### `bypassModes`

If the current mode is bypassed:

- no action is selected
- no action is executed
- the recording is still marked as processed

Example:

```json
"bypassModes": "dictation|raw"
```

The bypass match is case-insensitive. The recording is marked processed and
its pending watchers are cleaned up, but no action or trigger is selected.

### Recovery and cleanup

The watcher treats an incomplete or disappearing recording as a recoverable
session. A recording with no non-empty `.wav` or `.ogg` file is given a
17-second grace period; the file extensions are matched without regard to case.
If all such audio files are removed after a valid non-empty one was seen, or a
recording's `meta.json` is deleted after recheck, the session is recovered and
skipped. Recovery cancels pending metadata/audio watchers, settle work, timers,
one-time state, and clipboard execution groups while preserving the current
clipboard.

After a valid recording is marked processed, the final action controls its
recording-folder handling: `moveTo` set to `null` or omitted inherits
`defaults.moveTo`; an explicit `""` keeps the folder in place even when that
default is nonempty; and a nonempty path moves it while `.delete` removes it.
`.none` is an action payload shortcut, not a `moveTo` value. See
[`moveTo`](clipboard-and-recordings.md#moveto) for the supported recording-folder
values. A direct JSON source passed through the CLI has no recording folder to
move, so `moveTo` is skipped there.

History cleanup runs
asynchronously after the action when `history` is configured: `null` disables
it, `0` retains only the newest recording, and a positive value retains the
configured number of days. Cleanup is scheduled after about 30 seconds and is
rate-limited to once per 24 hours within a running daemon process.

### Missing folders and configuration changes

If the configured Superwhisper `recordings` folder is missing, Macrowhisper
watches the nearest existing parent and arms the recording watcher when the
folder reappears. It does not create the folder. Changes to the config file
are watched and valid updates reload while the daemon runs; invalid JSON or
validation applies the default configuration in memory until the file is fixed.
On startup, `defaults.autoUpdateConfig` controls whether an older
`configVersion` is migrated automatically. A current-version file is not
rewritten merely because the service restarted.

---
