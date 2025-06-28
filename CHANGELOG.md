# CHANGELOG

## UNRELEASED
### Changed
* All action types now support icons
* Any action can now be set as default. `activeInsert` has been replaced with `activeAction`. 
* Improved clipboard restoration and clipboard syncing (with Superwhisper's result)
  * This tweak should prevent trouble with Superwhisper’s recording window animation. Remember the `actionDelay` setting can help with this too, though with this small change to how clipboard restoration and syncing work, things already feel more reliable even with `actionDelay` set to 0.
* `--exec-action` now works correctly for all action types. You can easily run any of your actions with the last Superwhisper result via CLI.
* Improved trigger logic for "and"
  * *Fixed `and` logic bug where empty triggers would incorrectly match everything. Now `and` and `or` both ignore empty triggers, only evaluating those with actual values.*
* New unified `--remove-action <name>` command handles any action type (insert, URL, shortcut, shell, AppleScript)
* There's been updates to CLI commands for a more unified "action" terminology and experience.
  * `--get-action [<name>]` is replacing `--get-insert [<name>]`
  * `--action [<name>]` is replacing `--insert [<name>]`
  * `--remove-action <name>` is replacing all individual `--remove-insert`, `remove-url`, etc.
  * New `--list-actions` lists all actions in the configuration file.
* Improved `--auto-return <true/false>`
  * Auto-return (which is meant to be triggered for a single interaction) will now be auto-deactivated if the recording is cancelled.
* New CLI commands and config changes are backward compatible.
  * It's not a requirement to update your config file, since these changes won't break anything. If you want, you can auto-refresh your config by adding an action with the CLI—for example: `--add-insert AnyName`. After this, all your actions should have `icon`, your `activeInsert` will be converted to `activeAction`, etc.

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