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

#### Inspect state

| Command | What it does |
| --- | --- |
| `--status` | Shows whether the daemon is running and includes trigger mute state. |
| `--get-action` | Shows the current active action name. |
| `--get-action <name>` | Shows the processed output for that action. |
| `--get-icon` | Shows the icon for the active action. |
| `--folder-name [<index>]` / `--folder-path [<index>]` | Looks up recent recording folders by recency. |

#### Set defaults

| Command | What it does |
| --- | --- |
| `--action <name>` | Sets the default active action. |
| `--action` | Clears the default active action. |

#### One-time runtime controls

| Command | What it does |
| --- | --- |
| `--schedule-action <name>` | Uses that action for the next recording. |
| `--schedule-action` | Clears the scheduled action. |
| `--auto-return true\|false` | Turns one-time auto-return on or off for the next recording. |
| `--auto-return` | Clears one-time auto-return. |
| `--mute-triggers true\|false` | Saves trigger muting on or off in config. |
| `--mute-triggers <duration>` | Temporarily mutes triggers for a runtime duration such as `30s`, `5m`, or `1h`. |
| `--mute-triggers` | Unmutes and clears any temporary mute timer. |
| `--reset-clipboard` | Discards clipboard context captured so far and starts a fresh capture boundary. |

You can check mute state through `--status`.

#### Execute actions

| Command | What it does |
| --- | --- |
| `--exec-action <name>` | Runs one specific action right now. |
| `--run-auto` | Runs automatic selection logic against the current or chosen recording. |
| `--copy-action <name>` | Renders an action and copies the result using live context placeholders at invocation time, without polluting clipboard capture. |

#### Other runtime commands

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
