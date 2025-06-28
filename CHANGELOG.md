# CHANGELOG

## UNRELEASED
### Changed
* Improved trigger logic for "and"
  * *Fixed `and` logic bug where empty triggers would incorrectly match everything. Now `and` and `or` both ignore empty triggers, only evaluating those with actual values.*
* `--exec-action` now works correctly for all action types. You can easily run any of your actions with the last Superwhisper result via CLI.
* `activeInsert` has been replaced with `activeAction`. Any action can now be set as default.
* All action types now support icons
* New unified `--remove-action <name>` command handles any action type (insert, URL, shortcut, shell, AppleScript)
* There's been updates to CLI commands for a more unified "action" terminology and experience.
  * `--get-action [<name>]` is replacing `--get-insert [<name>]`
  * `--action [<name>]` is replacing `--insert [<name>]`
  * `--remove-action <name>` is replacing all individual `--remove-insert`, `remove-url`, etc.
  * New `--list-actions` lists all actions in the configuration file.
* New CLI commands and config changes are backward compatible.
  * These are not breaking changes, so it's not a requirement, but users can update their config file by simply adding an action via CLI (for example, `--add-insert AnyName`)
* Improved `--auto-return <true/false>`
  * Auto-return (which is meant to be triggered for a single interaction) will now be auto-deactivated if the recording is cancelled.
* ActionDelay is set to 0.05 when auto-creating the config file.
  * Minor adjustment to avoid clash with Superwhisper's rec window animation.

---
## [v1.1.2](https://github.com/ognistik/macrowhisper/releases/tag/v1.1.2)
### Changed
* Removed extra notification for syntax errors on JSON files.
* Fix for repeated update dialogs

---
## [v1.1.1](https://github.com/ognistik/macrowhisper/releases/tag/v1.1.1) - 2025/06/25
### Changed
* The configuration file watcher has been improved.
    It now supports apps that create new files and delete originals during editing, in addition to direct file modifications. This means better compatibility with more text editors beyond VS Code or similar.

---
## [v1.1.0](https://github.com/ognistik/macrowhisper/releases/tag/v1.1.0) - 2025/06/24
* The CLI app goes live!