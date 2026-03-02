# CHANGELOG

## UNRELEASED

The [documentation](https://by.afadingthought.com/macrowhisper) has be fully updated for more clarity.

## Big Config semantics update (clearer and more predictable)
This release introduces `configVersion: 2` with clearer rules for the configuration file.
- `null` = inherit default
- `""` = explicit empty value
- Action payload templates stay explicit:
  - `.none` (no-op template)
  - `.autoPaste` (insert only)
  - `.run` (shortcuts only)

### Important difference
- `action: ""` and `action: ".none"` are **not the same**.
- `action: ""` = empty payload.
- `action: ".none"` = template behavior (sets `noEsc` & `restoreClipboard` to false).

### Migration
- Auto migration should allow you to continue using your config without any new manuale edits.
- A backup is created once: `macrowhisper.json.backup.pre-v2`.
- If `defaults.autoUpdateConfig` is `false`, migration is not automatic.  
  - In that case, you can migrate by running `--update-config`.

### Non-action `.none`
- In v2, `.none` is no longer valid for fields like `icon` or `moveTo`.
- Use:
  - `null` to inherit from defaults
  - `""` for explicit empty

## Other
* **Breaking.** `--insert, --get-insert, --exec-insert, getInsert, execInsert` flags have been deprecated for quite some time, and now they've been cleaned up from the code.
* **New.** `restoreClipboardDelay` can be set at the default level or at the actions level.
  * Defaul is 0.3 sec. I suggest not extending too much, especially if you dictate quickly. Could easily lead to clipboard contamination in overlapping dictations.
* **New.** Up until now, action execution for Shortcuts and scripts has been asyng. Now you got a `scriptAsync` which you can set to false.
  * Related to this, there's a customizable `scriptWaitTimeout` that you can set for script execution when set it's not async. 
  * With `scriptAsync` set to false, action execution will wait for script completion. And in chained you can use the result of the first script with `{{actionResult}}` placeholder.
  * `{{actionResult}}` has a set index. No index or `{{actionResult:0}}` is the first script completion, `{{actionResult:1}}` the next, and so on.
* **New** `smartInsert` for insert actions set to true by default (at the defaults level)
  * Lots of edge cases covered. Most minor remaining issues are with those apps that do not have good accessibility integrations.
* **New** `bypassModes` setting in defaults of the config, where the user can set modes where Macrowhisper should not kick in at all.
  * Useful since SuperWhisper now allows overriding the auto-paste setting at the mode level.
  * It is still suggested that users set Superwhisper's autopaste off in the advanced configuration tab. However, if they do want to use SuperWhisper for pasting with a specific mode, now they can bypass that specifically with Macrowhisper. No actions will trigger when using that mode.
* **New** `{{appVocabulary}}` which captures names, usernames, and special terms from the active window.
* **New** `{{folderName}}`, `{{folderName:<index>}}`, `{{folderPath}}`, `{{folderPath:<index>}}` placeholders which return current recording folder information (and indexed folder lookup (0 newest/current, 1 previous, etc.))
  * Info also available via CLI `--folder-name [<index>]` and `--folder-path [<index>]`
  * Useful for automations/scripts where user may need to do something with current or previous recording paths.
* **New** `transform` option for placeholders with the syntax `{{placeholder::transform||regex1find||regex1replace...}}`.
  * For now it supports `uppercase`, `lowercase`, `uppercaseFirst`, `lowercaseFirst`, `titleCase`, `titleCase:all`, `titleCase:en`, `titleCase:es`, `ensureSentence`.
  * More languages for titleCase may be added upon request.
  * This is for transformations beyond what regex allowand. They are applied before regex so you can still set your own exceptions.
* **New.** `--copy-action` which can copy the contents of an action to user's clipboard. 
  * This operation is not captured by Macrowhisper's `{{clipboardContext}}`
  * Supports placeholder expansion, and context placeholders.
  * Great to pass information to Superwhisper's clipboard for processing (you can now pass a stacked clipboard to Superwhisper)
* **New.** `--exec-action`, `--get-action`, and `--copy-action` now support a custom path with `--meta` (action name is still required).
  * This can be a recording folder name, a recording folder path, or the path to any JSON file in the format of `meta.json`
* **Improvement.** cleaned up the logs to make them more readable and less noisy.
* **Improvement.** `inputCondition` has been expanded to all action types
  * You can now have any action behave differently depending on user being in an input field or not.
* **Improvement.** Streamlined the validation and sync with Superwhisper's placement of the result on the user's clipboard before action execution. This improves responsiveness.
* **Improvement.** Updated a couple of config-related CLI flag behavior and fixed related bugs:
  * `--set-config <path>`: persists path, creates default config at that path if missing, if daemon is running, switches immediately, if daemon is not running, does not start daemon
  * `--reset-config`: persists reset to default path, creates default config at default path if missing, if daemon is running, switches immediately, if daemon is not running, does not start daemon
  * `--config <path>`: now persists path immediately, creates config file if missing, if daemon is running, switches immediately and continues, if daemon is not running, starts up and runs daemon with that path
* * **Improvement.** standardized values at default level of config.
  * Now the only required key is the watch folder. This allows for minimal configuration files if users set `autoUpdateConfig` to `false`.
  * It is still suggested to set `autoUpdateConfig` to `true` so users don't miss out on future new features.
* **Improvement.** Better guard protection when multiple recordings appear in burst (none will process).
* **Improvement.** Better handling of `meta.json` values.
  * Use the `segments` key from the `meta.json` file as placeholder, and it will be formatted correctly. **You can now send your speaker-separated transcripts to automations.**
  * It is now also possible to use `meta.json` subkeys or arrays. For example, `{{promptContext.systemContext.language}}` is possible.
* **Improvement.** Raised blackout window for clipboard duplication up to 5 seconds to accommodate to Superwhisper. I'm convinced this is a Superwhisper bug by now and Macrowhisper is just trying to work around it.
* **Improvements to context placeholders for performance.**
  * `appContext`, `frontApp` and `appVocabulary` placeholders are  captured lazily, only when placeholder is found in action, and at action execution.
  * `selectedText` and `clipboardContext` are captured only during recording session and their values are used again in chained actions.
* **Improvement** to trigger evaluation for Front App. Prior to this update, trigger matching would  require both name & bundle ID to exist (would fail otherwise). Now, it works with one value. 
* **Improvement** when users run `--exec-action` on an action with `moveTo`. The `moveTo` now applies for consistency.
* **Improvement** on validation for the `meta.json` file. If an LLM result is expected, the system will only wait for that result, even if voice is empty. 
  * This allows users to use Macrowhisper even in those cases where nothing is dictated.
  * Voice triggers only match against result (raw transcription).
  
---
## [v1.4.0](https://github.com/ognistik/macrowhisper/releases/tag/v1.4.0) - 2026/02/13
### Breaking
* When an insert action is empty `""`. Macrowhisper will no longer close Superwhisper's recording window nor leave the result on user's clipboard.
  * It will respect the user's settings per action. So, to get the previous behaviour, set `noEsc` to `false` and `restoreClipboard` to `false`
  * You may also use `".none"` which serves as a quick template that does the same.
  * This is only for those insert actions where the user didn't want the result automatically inserted in the front app.

### Added
* **New** `clipboardIgnore` setting in config defaults. User can set app names or bundle IDs to indicate applications whose clipboard interactions shouldn't be captured by the `{{clipboardContext}}` placeholder.
  * Implemented retroactive cleanup for clipboard in case the detection from an app happens half a second later.
* **New** `redactedLogs` setting in config defaults. This is set to `true` by default.
  * Now there's more privacy for the dictation and any context capture (even in the logs).
  * User can set it to `false` to get more detailed information to better diagnose bugs.
* **New** `nextAction` field which allows action chaining! 
  * Only one insert action is allowed in the chain
  * There's protection for endless loops, but tt is suggested you keep your chains short and predictable.
  * Clipboard restoration only happens until the last action executes
  * Only the `moveTo` setting of the last action applies.
* **New** `inputCondition` for insert actions.
  * Conditionally applies selected insert options depending on whether execution starts in an input field.
  * This means you can have clipboard restoration, Escape simulation, move the recording folder, chained actions, etc. conditionally executed depending on whether you are currently in an input field or not.
  * Section explaining this added to Documentation.

### Changed
* **Impovement**. Implemented getUTF8Environment() helper that:
 * Checks if LANG is already set with UTF-8 encoding
 * If yes, uses it as-is
 * If LANG exists but without UTF-8, appends .UTF-8 to the base locale
 * If LANG doesn't exist, uses system locale (Locale.current.identifier) with .UTF-8
 * Sets both LANG and LC_ALL to ensure UTF-8 encoding
 * Applies to Shell Scripts and AppleScripts
* **Impovement**. Macrowhisper correctly ignores transient/concealed clipboard types.
* **Improvement**. Clipboard restoration now restores the contents of your pasteboard from the moment dictation started.
  * This approach is more consistent than attempting to synchronize with Superwhisper and detect the correct clipboard after an action executes.
* **Improvement**. Closes clipboard monitoring sessions when recording happens without actions — it prevents zombie sessions to stay active
* **Fix**. The removal of trigger words or phrases was happening only on `result`  (without LLM), but now it's also happening on `llmResult`. This ensures that it will never appear once `{{swResult}}` is formed.
* **Fix**. Added validation for `result` when `llmResult` is present in the meta json file. For some reason, Superwhisper now writes `llmResult` before `result` in those cases. This fixes voice triggers not working when LLMs are being used.
* **Fix**. When a recording starts, there's now a 2.5-second where repeat clipboard capture is suspended.
  * Fixes prevents `{{clipboardContext}}` placeholder contamination
  * If the user is on an app where there is no selected text range (for example, Finder), Superwhisper attempts a clipboard operation. Prior to this fix, this would unexpectedly appear in Macrowhisper capture.
  * Clipboard capture for `{{clipboardContext}}` still works during this period. It just won't capture the same thing more than once.

---
## [v1.3.4](https://github.com/ognistik/macrowhisper/releases/tag/v1.3.4) - 2025/10/07
### Changed
* Improved update system
  * Will now keep track of last dialogue version - will notify of updates if there's a new version before the timout for dialogues happens (before 4 days)
  * `--version-state` now includes more useful information for debugging version checks
  * `--version-clear` flag added to CLI to clear the version check data
* Improved saving of UserDefaults
  * Migration from previous scattered plist preference files
* App Context placeholder now will also capture description of active element
* Fixed `--auto-return true` so that it correctly inserts AI processed result if available.
* Improved cancellation detection and crash detection
  * Crash is detected if an unprocessed folder is being watched but a new folder appears in the recordings directory.
  * Unified Recovery System: Handles crashes, cancellations, and timeouts. Ensures that after recovery, the app returns to a clean state where new recordings can be processed normally without interference from orphaned watchers or actions.
  * Cancellation detection:
    * WAV file removal
    * Meta.json deletion (with overwrite handling)
    * Recording folder deletion
    * Timeout after 17 seconds without WAV file

---
## [v1.3.3](https://github.com/ognistik/macrowhisper/releases/tag/v1.3.3) - 2025/08/27
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