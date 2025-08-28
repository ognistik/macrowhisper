# CHANGELOG

## UNRELEASED

---
## [v1.3.3](https://github.com/ognistik/macrowhisper/releases/tag/v1.3.2) - 2025/08/27
### Changed
* Improved recovery for cases where Superwhisper crashes.
  * Cleanup of all watchers after a crash is detected.
  * This change allows all actions (particularly scheduled actions) continue to execute after a Sw crash.
  * For automated scheduled actions, the recommended flow is now to start recording prior to scheduling action.

---
## [v1.3.2](https://github.com/ognistik/macrowhisper/releases/tag/v1.3.2) - 2025/08/27
### Changed
* New validation check for the meta JSON file that stores the user's dictation results.
  * Superwhisper will change how it saves data to meta.json in an upcoming release.
  * This update (v1.3.2) makes sure Macrowhisper keeps working smoothly when that change rolls out in Superwhisper.
  
---
## [v1.3.1](https://github.com/ognistik/macrowhisper/releases/tag/v1.3.1) - 2025/08/18
### Changed
* Fix for writing configuration file ([#11](https://github.com/ognistik/macrowhisper/issues/11))
* Fix for scheduled actions being detected as if a session was ongoing when it wasn't.
* Improvements to the clipboard restoration logic when Superwhisper was faster to place content on user's clipboard.
  * When Superwhisper was faster: Looks for the most recent clipboard change that is NOT the Superwhisper result
  * When maxWaitTime is reached: Uses the same logic to find what was on clipboard before Superwhisper modified it
  * Fallback: If no changes found, uses the original user clipboard from when the recording folder appeared
* Fix for issue where the previous clipboard would become part of the clipboard context placeholder if action was triggered too soon after previous one.
* Added schema to App Configuration for better detection of whether user's config already has the correct schema reference or not.
  
---
## [v1.3.0](https://github.com/ognistik/macrowhisper/releases/tag/v1.3.0) - 2025/08/14
### Added
* New `clipboardStacking` option in config defaults. When enabled, it allows users to capture multiple content for the `{{clipboardContext}}` placeholder.
* New `autoUpdateConfig` option to choose to autoupdate config or not during service restart.
* Added `clipboardBuffer` option in the defaults of the config to set custom buffer time for `{{clipboardContext}}` to be captured.
* New [Alfred Workflow](https://github.com/ognistik/macrowhisper/tree/main/alfred)!
* Added validation and error notification when user attempts to schedule a non-existing action.

### Changed
* Fixed `clipboardContext` placeholder bug where it wouldn't detect the clipboard captured if it was the same that already was in the clipboard before the buffer or starting a session.
* Adjusted JSON schema to only require the very essential defaults.
* Voice triggers now support raw regex. For this, the phrases have to be exactly between `==`. For example `==^google this\\.?$==` will exactly match this phrase. Or if you want to match a string that ends with a specific phrase: `"==.*ends with this$=="` . This can be mixed with strings that are processed as usual, without `==`. For example: `==^exact match$==|normal keyword`. Mode triggers and app triggers already have this behavior by default (without `==`).
* Added trimming to selectedText, clipboardContext, appContext.
* Improvements for URL encoding in actions
* Improvement and fix for `{{selectedText}}` placeholder. Previously it was being captured on action execution, now it only gets captured when session starts.
* Socket communication has been completely rewritten to include safety timeouts, better error handling, and avoid memory hangs. There's also an automatic backup system to prevent config files corruption.

---
## [v1.2.3](https://github.com/ognistik/macrowhisper/releases/tag/v1.2.3) - 2025/08/06
### Added
* New JSON schema to assist users when editing the configuration file in their IDE.
  * `--schema-info` - new CLI flag to debug schema issues.
  
* New `{{selectedText}}`, `{{clipboardContext}}`, and `{{appContext}}` dynamic placeholders for Macrowhisper actions. They support all the standard placeholder features:
  * Basic: `{{selectedText}}` - Gets selected text with action-type escaping
  * JSON-escaped: `{{json:selectedText}}` - Applies JSON string escaping
  * Raw: `{{raw:selectedText}}` - No escaping (useful for AppleScript)
  * Regex replacements: `{{selectedText||\\n||newline}}` - Apply text transformations
  
* Clipboard synchronization improvements to support the optional `{{clipboardContext}}` placeholder.
  * Clipboard context for placeholder use is only captured either 5 seconds before starting dictation or during dictation (similar to Superwhisper).

* New `--schedule-action [<name>]` CLI flag. 
  * It schedules an action which is prioritized above any trigger.
  * This scheduled action has a customizable timeout with a new `scheduledActionTimeout` option in the configuration. If no dictation begins before X amount of seconds, the scheduled action will be cancelled. 
  * A scheduled action can also be cancelled by sending the `--schedule-action` flag without any arguments.

### Changed
* Macrowhisper can now work with empty "result" values—since Superwhisper itself can also do this. This means that when using a Superwhisper mode that has AI, the mode can process captured context alone (without dictated text). Macrowhisper will also trigger actions properly based on this. Note: This is experimental and could be removed from Superwhisper anytime.

* Configuration file is now automatically updated when service starts to include new values and schema changes.
  * `--config-update` - new CLI flag to manually update configuration.

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