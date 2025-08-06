# CHANGELOG

## UNRELEASED

### Added
* New `{{selectedText}}`, `{{clipboardContext}}`, and `{{appContext}}` dynamic placeholders for Macrowhisper actions. They support all the standard placeholder features:
  * Basic: `{{selectedText}}` - Gets selected text with action-type escaping
  * JSON-escaped: `{{json:selectedText}}` - Applies JSON string escaping
  * Raw: `{{raw:selectedText}}` - No escaping (useful for AppleScript)
  * Regex replacements: `{{selectedText||\\n||newline}}` - Apply text transformations
  
* Clipboard synchronization improvements to support the optional `{{clipboardContext}}` placeholder.
  * Clipboard context for placeholder use is only captured either 5 seconds before starting dictation or during dictation (similar to Superwhisper).
  
* New JSON schema to assist users when editing the configuration file in their IDE.
  * `--schema-info` - new CLI flag to debug schema issues.
  
* Configuration file is now automatically updated when service starts to include new values and schema changes.
  * `--config-update` - new CLI flag to manually update configuration.

### Changed
* Macrowhisper can now work with empty "result" values—since Superwhisper itself can also do this. This means that when using a Superwhisper mode that has AI, the mode can process captured context alone (without dictated text). Macrowhisper will also trigger actions properly based on this. Note: This is experimental and could be removed from Superwhisper anytime.

---
## [v1.2.2](https://github.com/ognistik/macrowhisper/releases/tag/v1.2.2) - 2025/07/31
* The implementation for Keypress Simulation has been rewritten to use CGEvents (accessibility). Should be much more reliable now.
* Cleaned up unnecessary log messages.

---
## [v1.2.1](https://github.com/ognistik/macrowhisper/releases/tag/v1.2.1) - 2025/07/30
### Added
* Added a new `openBackground` option for URL Actions, which is set to `false` by default. This lets URLs open in the background without the app taking focus—perfect for automation workflows. To update all your URL actions with this new field, just add any action to your config via the CLI.

### Changed
* Clipboard restoration now has a delay of 0.3 seconds instead of the previous 0.1, to prevent paste issues. [#3](https://github.com/ognistik/macrowhisper/issues/3)

---
## [v1.2.0](https://github.com/ognistik/macrowhisper/releases/tag/v1.2.0) - 2025/07/02
### Changed

* All action types now support icons.

* Any action can be set as default—`activeInsert` has been replaced with `activeAction`.

* The `restoreClipboard` setting can now be configured at the action level.

* Improved clipboard restoration and syncing with Superwhisper's result:
  * This enhancement reduces conflicts with Superwhisper's recording window animation and clipboard usage.
  * Most users can now set `actionDelay` to 0 for better performance. If you encounter issues (e.g., the recording window not closing), you can still adjust this setting..

* The `--exec-action` flag now works correctly for all action types. You can run any action using the last Superwhisper result directly from the command line.
  * I am finding this a very convenient way to trigger scripts/shortcuts using Superwhisper results, but triggered externally from Keyboard Maestro/Karabiner/BTT.

* Improved trigger logic for "and" conditions:
  * Fixed a bug where empty triggers in "and" logic matched everything. Now both "and" and "or" logic ignore empty triggers and only use those with values.

* The new unified `--remove-action <name>` CLI command works with any action type (insert, URL, shortcut, shell, AppleScript).

* CLI commands now use consistent "action" terminology:
  * `--get-action [<name>]` replaces `--get-insert [<name>]`
  * `--action [<name>]` replaces `--insert [<name>]`
  * `--remove-action <name>` replaces all individual `--remove-insert`, `--remove-url`, etc.
  * New `--list-actions` command shows all actions in the configuration file.

* Improved `--auto-return <true/false>`:
  * If a recording is cancelled, auto-return (designed for single interactions) will now turn itself off automatically.

* Fixed date placeholders like `{{date:yyyy-MM-dd}}`. Macrowhisper previously converted UTS 35 patterns to localized formats—now it follows your template exactly.

* Added special escaping template for JSON. This is particularly useful for Shortcut actions. To build dictionaries with placeholders, add the `json:` prefix to any existing placeholder for proper escaping:
  * Simple Shortcut Action with Dictionary: `"action" : "{\"theResult\": \"{{json:swResult}}\"}"`
  * A more complex example is included in the [sample config](https://github.com/ognistik/macrowhisper/blob/main/samples/macrowhisper.json).
  * A simpler approach to using dictionaries without dealing with escaping is creating a Superwhisper mode to give you the result in JSON. Then you just send `{{swResult}}` to a Shortcut, which will parse it correctly

* Introduced a `raw:` prefix for placeholders, which strips any escaping added by default. Use this prefix if you need your placeholder output to remain untouched for a given action (this is the default for Shortcuts or Insert actions).
  * For example, with this, you can now instruct a Superwhisper mode to write AppleScript for you, then send it right to execution—letting you control your Mac with plain voice instructions. Be cautious if you do this, it's powerful stuff.

* The values of `{{duration}}`, `{{processingTime}}`, and `{{languageModelProcessingTime}}` are now dynmically converted to seconds or minutes when used in actions for better readability.

* Expanded the regex engine's capability to handle newlines in placeholders.

* Improved logic for regex replacements and removal of empty meta.json key placeholders:
  * If a placeholder is used in an action but found empty in the meta.json file, it will simply be removed.

**The new CLI commands and config changes are backward compatible, so updating your config file isn't required—nothing will break. However, sample Keyboard Maestro macros and documentation have been updated for the new flags.** If you want to refresh your config quickly, add an action via the CLI (for example: `--add-insert AnyName`). This will add `icon` and `restoreClipboard` properties to all actions and convert `activeInsert` to `activeAction`. **If you decide to update your config, it is suggested you make a backup first—just to be safe.**

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