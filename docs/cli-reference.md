# CLI Reference

[← Documentation index](README.md) · [Configuration](configuration.md) · [Runtime](runtime.md) · [Troubleshooting](troubleshooting.md)

## Command Reference

This section lists the main terminal commands. You do not need all of them to get started.

### Everyday commands

```bash
macrowhisper --help
macrowhisper --version
macrowhisper --reveal-config
macrowhisper --validate-config
macrowhisper --service-status
macrowhisper --get-config
```

Short aliases are available for the common commands: `-h` is `--help`, `-v` is
`--version`, and `-s` is `--status`.

### Daemon startup and diagnostics

Starting `macrowhisper` with no command runs the foreground daemon. These
options control that run:

```bash
macrowhisper --config "/path/to/macrowhisper.json"
macrowhisper --verbose
macrowhisper --debug-ax-tree
```

`--config` normalizes and saves the path for future starts. If a daemon is
already running, it switches that instance to the path; otherwise the next
daemon start uses it. When combined with `--reveal-config` or
`--validate-config`, it selects the path for that command without changing the
saved path.

`--verbose` enables debug console output and detailed logging for that daemon
run. It also disables log redaction for that run; it does not change the
`defaults.redactedLogs` setting in the config file. `--debug-ax-tree` is a
read-only quick diagnostic that dumps the front application's Accessibility
tree to the log and does not require a daemon.

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

- `--set-config` saves the config path for future runs and switches a running
  daemon immediately when one is available
- `--reset-config` restores and creates the default path, switching a running
  daemon immediately when one is available
- if you pass a directory, Macrowhisper uses `<dir>/macrowhisper.json`
- `--reveal-config` creates the effective config file if it is missing, then
  opens it in Finder
- `--validate-config` checks both JSON validity and config rules; an explicit
  `--config` path is validated for that command without being saved
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

`--install-service` writes or updates the launchd plist. `--start-service`
installs or updates it as needed and bootstraps the job; the top-level command
also stops a manually running daemon first. `--stop-service` stops both the
launchd job and any daemon reachable through the local socket. `--restart-service`
stops, waits briefly, and starts again. `--uninstall-service` stops the job and
removes the plist only; it does not remove the binary, config, or logs.

### Action management commands

These commands are sent to the running daemon.

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
macrowhisper --reset-clipboard
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
macrowhisper --version-state
macrowhisper --version-clear
```

Before using runtime commands, make sure the service is running:

```bash
macrowhisper --start-service
```

### Runtime command reference

#### Inspect state

| Command | What it does |
| --- | --- |
| `--status` | Shows whether the daemon is running and includes trigger mute state. |
| `--get-action` | Shows the current active action name. |
| `--get-action <name>` | Shows the processed output for that action. |
| `--get-icon` | Shows the icon for the active action. |
| `--folder-name [<index>]` / `--folder-path [<index>]` | Looks up the active recording first, then valid completed recording folders newest by creation date (`0` is the first result). Invalid or incomplete folders are skipped. |

#### Set defaults

| Command | What it does |
| --- | --- |
| `--action <name>` | Sets the default active action. |
| `--action` | Clears the default active action. |

#### One-time runtime controls

| Command | What it does |
| --- | --- |
| `--schedule-action <name>` | Uses that action for the next recording, or immediately for the currently active recording session. |
| `--schedule-action` | Clears the scheduled action. |
| `--auto-return true\|false` | Turns one-time auto-return on or off for the next recording, or for the currently active recording session. |
| `--auto-return` | Clears one-time auto-return. |
| `--mute-triggers true\|false` | Saves trigger muting on or off in config. |
| `--mute-triggers <duration>` | Temporarily mutes triggers for a positive duration such as `30`, `30s`, `5m`, or `1h` (`30` means seconds). |
| `--mute-triggers` | Unmutes and clears any temporary mute timer. |
| `--reset-clipboard` | Discards clipboard context captured so far and starts a fresh capture boundary. |

You can check mute state through `--status`.

#### Execute actions

| Command | What it does |
| --- | --- |
| `--exec-action <name>` | Runs one specific action right now. |
| `--run-auto` | Runs automatic selection logic against the latest valid or chosen recording. |
| `--copy-action <name>` | Renders an action and copies the result using live context placeholders at invocation time, without polluting clipboard capture. |

#### Other runtime commands

- `--check-updates` forces an update check, even when automatic checks are disabled or throttled. The check runs synchronously and the dialog's **Open Release** button opens the GitHub release page; it does not install an update.
- `--version-state` prints the update-check timestamps and reminder state for debugging.
- `--version-clear` clears the update-check UserDefaults so the next check starts without prior timing or reminder state.

### Important runtime details

- `--run-auto` does not take an action name
- `--run-auto` does not consume or clear one-time runtime state such as `--auto-return` or `--schedule-action`
- enabling `--auto-return` cancels a scheduled action; scheduling an action cancels auto-return
- `--exec-action` clears pending auto-return and scheduled-action state when no recording session is active. If a recording is active, it preserves that one-time state for the session.
- if persistent trigger muting is already `true`, then `--mute-triggers <duration>` is ignored

### `--meta`: use a different `meta.json`

By default, action commands use the latest valid Superwhisper result.

Use `--meta` when you want to point Macrowhisper to:

- a specific recording folder name
- a specific recording folder path
- a direct JSON file with compatible `meta.json` content

How Macrowhisper reads the value:

- a value containing `/`, beginning with `~`, or beginning with `.` is treated as a path; relative path values are resolved from the current working directory
- `~` is expanded
- a directory path loads `<directory>/meta.json`; a file path loads that JSON file directly
- otherwise, the value is treated as a recording folder name under the configured Superwhisper `recordings` directory
- without `--meta`, Macrowhisper chooses the newest completed folder with a valid result; folders missing the required non-empty `llmResult` or `result` are skipped
- when `languageModelName` is non-empty, the required field is a non-empty string `llmResult`; otherwise it is a non-empty string `result`

Examples:

```bash
# Recording folder name inside the recordings directory
macrowhisper --get-action summarizeEmail --meta 2026-03-01_10-00-00
```

```bash
# Folder path that contains meta.json
macrowhisper --copy-action summarizeEmail --meta ~/superwhisper/recordings/2026-03-01_10-00-00
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

- when execution uses a recording folder (the default source or a recording-folder `--meta`), the final action's `moveTo` controls post-processing: `null` or omission inherits `defaults.moveTo`, explicit `""` keeps the folder in place even when that default is nonempty, and a nonempty path or `.delete` overrides it
- if `--meta` points to a direct JSON file, `moveTo` is skipped because there is no recording folder to move or delete
- `.none` is an action payload shortcut, not a `moveTo` value

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
| Consumes one-time runtime state | Clears pending auto-return and scheduled action when no recording is active; preserves them for an active session | No | No | No |

---

## Updating and Version Checks

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

## Full Uninstall

Macrowhisper has four main parts:

**The service**

- the background process
- usually installed at `~/Library/LaunchAgents/com.aft.macrowhisper.plist`

**The binary**

- the executable itself
- usually installed by Homebrew or at `/usr/local/bin/macrowhisper`

**Your config files**

- your settings and preferences
- by default in `~/.config/macrowhisper`

**The generated attachment cache**

- temporary PNG files created for native clipboard attachment handoff
- stored in `~/Library/Caches/Macrowhisper/ClipboardAttachments`

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

### Step 3: Complete data cleanup

For a complete uninstall, remove Macrowhisper's configuration, logs, and generated attachment cache:

```shell
# Remove config
rm -rf ~/.config/macrowhisper

# Remove logs
rm -rf ~/Library/Logs/Macrowhisper

# Remove generated clipboard attachment cache
rm -rf ~/Library/Caches/Macrowhisper
```
