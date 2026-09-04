# Troubleshooting

[← Documentation index](README.md) · [CLI reference](cli-reference.md) · [Configuration](configuration.md)

When something feels off, start here. After installing or updating Superwhisper, check the [recommended setup](getting-started.md#set-up-superwhisper), including its clipboard settings, recording window, and Escape shortcut.

## First checks

1. Is the service running?

```bash
macrowhisper --service-status
```

2. Is the daemon responding, and is its recordings watcher armed?

```bash
macrowhisper --status
```

3. Is an active action set?

```bash
macrowhisper --get-action
```

4. Do the action names exist?

```bash
macrowhisper --list-actions
```

5. Is the config valid?

```bash
macrowhisper --validate-config
```

## Logs

For deeper debugging, set `defaults.redactedLogs` to `false`.

Log folder:

`~/Library/Logs/Macrowhisper/`

The main log is `macrowhisper.log`; launchd service stdout and stderr go to
`service.log` in the same folder. All log levels are written to the main log.
It rotates after exceeding 5 MiB and keeps one rotated backup. `--verbose`
raises console/detail logging and disables redaction for that daemon run only;
it does not persist a change to `defaults.redactedLogs`.

You can also use verbose mode:

```bash
macrowhisper --verbose
```

## Common problems

### Nothing pastes

- check macOS Accessibility permissions
- restart the service
- check `macrowhisper --status` for an armed watcher, a missing recordings
  folder, or pending work
- confirm the active action is not empty
- confirm no bypass mode is active
- confirm Superwhisper's **Clipboard content** is **Replace with dictation**,
  with **Paste result text** and **Simulate keypresses**
  off as described in [Getting started](getting-started.md#set-up-superwhisper)
- wait for a valid result: `llmResult` is required when `languageModelName` is
  non-empty; otherwise `result` must be a non-empty string
- a recording folder without a WAV file has a 17-second grace period, and
  existing folders at daemon startup are intentionally ignored

### Double paste

- make sure Superwhisper's **Paste result text** and **Simulate keypresses** are **Off**; Macrowhisper's insert action handles insertion

### The recording window stays open, or Escape dismisses something in my app

- for the recommended setup, use Superwhisper's **Classic** or **Mini** recording window, set **Cancel recording** to **Escape**, and turn **Always close** off
- if the window is **None**, or Superwhisper closes it automatically, set `defaults.simEsc: false` and check for action-level `simEsc: true` overrides
- if the window stays open, check the effective `simEsc` setting and macOS Accessibility permission; the generated `.autoPaste` payload deliberately avoids Escape outside text fields
- if closing is unreliable with the recommended setup, try `defaults.actionDelay` of `0.05` to `0.2` seconds
- see [setup alternatives](getting-started.md#if-you-change-these-settings) for the matching settings

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
- keep Superwhisper's **Clipboard content** set to **Replace with dictation**; use Macrowhisper's `restoreClipboard` for restoration

### Dictation is on the clipboard but missing from clipboard history

- Superwhisper's **Clipboard history: Off** marks dictations as transient so clipboard-history apps skip them; this does not prevent pasting the current clipboard
- use **Clipboard history: On** if you want your clipboard-history app to retain those dictations; Off is still supported by Macrowhisper
- Macrowhisper's paste-based inserts, including `.autoPaste` outside text fields, write ordinary clipboard text that history apps may still capture even when Superwhisper's history is Off
- clipboard-history apps have their own capture and filtering settings; On allows retention rather than guaranteeing an entry in every app

### Config edits are not taking effect

- save valid JSON
- check for semantic validation issues such as missing action references, invalid `inputCondition` tokens, invalid `triggerLogic` values, or duplicate action names
- if the config is invalid, Macrowhisper applies the default configuration in
  memory until the file is fixed; it does not replace the invalid file
- valid file changes are watched and reloaded while the daemon runs; an atomic
  save that replaces the file is supported
- use `--set-config` or `--config` to switch the saved path; with a running
  daemon the path is switched live

### Scheduled action or auto-return did not run

- both modes are one-time and apply to the next single recording, or to a
  recording session that is already active
- enabling auto-return cancels a scheduled action; scheduling an action cancels
  auto-return
- the default timeout is 5 seconds; set `defaults.scheduledActionTimeout` to
  `0` to wait without a timeout
- a simultaneous burst of new recording folders is deliberately marked
  processed without executing any action, and a newer recording can recover an
  incomplete one

### Recording recovery or cleanup

If a recording is canceled or disappears while it is being processed,
Macrowhisper cancels its pending watchers, timers, one-time state, and action
execution group while preserving the current clipboard. A missing WAV after
the 17-second grace period, removal of a previously valid WAV, or deletion of
`meta.json` after recheck can cause this recovery path.

After a completed action, the final action's `moveTo` controls recording-folder
handling: `null` or omission inherits `defaults.moveTo`, explicit `""` keeps the
folder in place even when that default is nonempty, and a nonempty path or
`.delete` moves or deletes it. `.none` is an action payload value, not a
`moveTo` sentinel; see [moveTo](clipboard-and-recordings.md#moveto).
History cleanup is asynchronous and disabled when `history` is `null`; `0`
keeps only the newest folder, while a positive value retains that many days.
Its 24-hour rate limit is per running daemon process.

### Update checks

Automatic checks are limited to once per 24 hours, retry failures after a
one-hour backoff, and remind about the same version no more than every four
days. `--check-updates` forces a synchronous check even when automatic checks
are disabled or throttled, and clears those timing/reminder limits for the
check. Choosing **Open Release** opens the GitHub release page; Macrowhisper
does not install the binary. For diagnostics, `--version-state` shows the
stored state and `--version-clear` removes it.

### Service status and lifecycle

`--service-status` reports the launchd plist, running state, resolved binary,
and saved config path. `--status` checks the daemon socket and returns a
not-running response when no daemon is available. `--start-service` installs
or updates the plist and stops an existing manual daemon before bootstrapping
launchd. `--uninstall-service` stops the launchd job and removes only the
plist; the binary, config, and logs remain until removed separately.

---
