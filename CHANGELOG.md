# CHANGELOG

## UNRELEASED
### Changed
* All action types now support icons.
* Any action can now be set as default—`activeInsert` has been replaced with `activeAction`
* The `restoreClipboard` setting can now be set at he action level as well.
* Improved clipboard restoration and clipboard syncing with Superwhisper's result
  * This tweak should prevent trouble with Superwhisper’s recording window animation
  * Most users will now get a better experience with `actionDelay` set to 0, but if you run into issues you can still adjust this setting.
* The `--exec-action` flag now works correctly for all action types. You can run any action using the last Superwhisper result right from the command line.
* Improved trigger logic for "and"
  * Fixed a bug where empty triggers in and logic matched everything. Now, both and and or will ignore empty triggers and only use those that have values.
* The new unified `--remove-action <name>` command works with any action type (insert, URL, shortcut, shell, AppleScript).
* CLI commands now use more consistent "action" terminology:
  * `--get-action [<name>]` replaces `--get-insert [<name>]`
  * `--action [<name>]` replaces `--insert [<name>]`
  * `--remove-action <name>` replaces all individual `--remove-insert`, `remove-url`, etc.
  * New `--list-actions` to see all actions in the configuration file.
* Improved --auto-return <true/false>:
  * If a recording is cancelled, auto-return (meant for single interactions) will now turn itself off.
* Fixed date placeholders like `{{date:yyyy-MM-dd}}`. Macrowhisper was previously converting UTS 35 patterns to localized formats, now it follows user's template.
* Added special escaping template for use with Shortcut actions. If you want to build dictionaries with placeholders, you can now add the `json:` prefix for any existing placeholder. It will escape correctly.
  * Simple Shortcut Action with Dictionary: `"{\"theResult\": \"{{json:swResult}}\"}"`
  * More complex example now included in the sample config.

**The new CLI commands and config changes are backward compatible, so you don’t have to update your config file—nothing should break. Sample KM Macros have been updated with new flags.** If you want, you can refresh your config by adding an action via the CLI (for example: `--add-insert AnyName`). After that, all actions will have `icon`, `restoreClipboard`, and `activeInsert` will become `activeAction`. Sample macros have received updates to use the new flags (though the previous ones still work). **If you do decide to update your config, it’s smart to make a quick backup first—just in case.**

---
## [v1.1.2](https://github.com/ognistik/macrowhisper/releases/tag/v1.1.2) - 2025/06/26
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