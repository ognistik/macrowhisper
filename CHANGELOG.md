# CHANGELOG

## UNRELEASED
* Reduced first-dictation latency after app restart by avoiding expensive Accessibility front-app lookups in app-identity-only paths.
* Moved automatic history retention cleanup off the action execution path so it no longer competes with initial dictation responsiveness.
* **Improved browser URL detection** performance by replacing the old content-heavy accessibility crawl with a bounded, cache-first URL resolver. 
  * This keeps URL triggers and page detection working while significantly reducing paste delays on complex websites.
* **Improved input field detection for browsers.** Should have better performance.
* **Improved detection of front app.** It resolves with AX detection first, uses NSWorkspace as fallback.
  * It should be more reliable with special window types.
* Improved smart insertion around paragraph boundaries, especially in supported browsers. 
  * Ambiguous newline caret positions now use a safer browser-only resolution path and fall back to the correct paragraph-end behavior instead of forcing the wrong line-start interpretation.
* Also fixed a related regression in non-browser text areas, where smart insertion could incorrectly rewrite valid before-newline positions.
  * Added focused regression coverage for browser ambiguity resolution and newline-boundary handling.

## [v2.0.2](https://github.com/ognistik/macrowhisper/releases/tag/v2.0.1) - 2026/03/16
### Changed
* **Improvements** to Context Placeholders in `--copy-action`
  * Fixed `--copy-action` so context placeholders are resolved from live invocation-time state instead of reusing stale recording metadata.
  * Repeated `--copy-action` calls now rebuild `{{clipboardContext}}` from the active session or recent clipboard buffer, while normal action execution still keeps its validated frozen session context.
  * This means that during a recording, the `--copy-action` flag will always grab fresh content for context placeholders.
* **Improvements** to smart punctuation.
  * Added ellipsis (...) to the list of valid closing punctuation for the ensureSentence transform.
  * Added rules for punctuation stripping mid-sentence... specific punctuation that is allowed like `,`, `;`, `:`
* **Improved** support for smart insertion settings in supported browsers.
  * Tries to dig deeper in the accessibility tree to get correct caret position.
  * Noticeable improvement in text editing interfaces (for example, ChatGPT Canvas)
* **Improved** `ensureSentence` transformation for normalizing sentences that may have wrappers (parenthesis, asterisks, brackets, etc.)

## [v2.0.0](https://github.com/ognistik/macrowhisper/releases/tag/v2.0.0) - 2026/03/08
### TLDR;
* For existing users, keep `autoUpdateConfig` set to `true` in your existing configuration. Macrowhisper will handle the migration to `configVersion 2` when you restart the service after the update.
* Biggest config changes are self-explanatory and have been implemented for consistency and predictability in how Macrowhisper handles your config.
* [The entire documentation](https://by.afadingthought.com/macrowhisper) has been rewritten for clarity. There's more examples and explanations.

### Details
**For existing users**
- Macrowhisper now uses `configVersion: 2`, with clearer rules: `null` means “inherit the default,” and `""` means “use an intentionally empty value.”
- Built-in action templates are now clearly separated from empty values: `.none` is a do-nothing template, `.autoPaste` is the insert template, `.run` runs a Shortcut without input, and `action: ""` means an empty payload.
- `action: ""` and `action: ".none"` are not the same. An empty payload stays empty. `.none` also turns off ESC simulation and clipboard restoration.
- `.none` is now reserved for action templates. For fields like `icon` or `moveTo`, use `null` to inherit or `""` for an explicit empty value.
- Existing configs are migrated automatically for users that set `autoUpdateConfig` to `true`, and Macrowhisper creates a one-time backup named `macrowhisper.json.backup.pre-v2`.
- If `defaults.autoUpdateConfig` is `false`, migration is not automatic. You can update manually with `macrowhisper --update-config`.
- Several config names were cleaned up and are migrated automatically: `noEsc` -> `simEsc`, `pressReturn` -> `simReturn`, `noUpdates` -> `disableUpdateCheck`, and `noNoti` -> `muteNotifications`.

**Configuration and action behavior**
- `smartCasing`, `smartPunctuation`, and `smartSpacing` are now available for insert actions and are enabled by default. They improve capitalization, punctuation, and spacing based on the insertion point.
- Most remaining smart-insert edge cases are in apps with weak Accessibility support.
- `restoreClipboardDelay` can now be set globally or per action. The default is `0.3s`.
- Default-level values are now more standardized. Omitted or `null` defaults cleanly fall back to Macrowhisper’s built-in defaults, which also makes smaller hand-edited configs easier when `autoUpdateConfig` is off.
- Auto-updated configs are normalized more clearly, including a built-in `returnDelay` of `0.15s` and cleaner persisted values like `3` instead of `3.0`.
- `inputCondition` now works across all action types, not just insert actions.
- `bypassModes` lets you tell Macrowhisper to completely skip processing for specific Superwhisper modes, so no Macrowhisper action runs for those recordings.

**More powerful actions, chaining, and placeholders**
- Shortcut, shell, and AppleScript actions can now run either asynchronously or synchronously. Set `scriptAsync: false` to wait for completion, and use `scriptWaitTimeout` to control how long Macrowhisper waits.
- Output from synchronous script-like steps can now be reused later in the same chain through `{{actionResult}}`, `{{actionResult:0}}`, `{{actionResult:1}}`, and so on.
- New `{{appVocabulary}}` captures likely names, usernames, and special terms from the active app.
- New folder placeholders are available: `{{folderName}}`, `{{folderPath}}`, `{{folderName:<index>}}`, and `{{folderPath:<index>}}`. Index `0` is the newest or current recording, `1` is the previous one, and so on.
- The same folder lookups are also available in the CLI with `--folder-name [<index>]` and `--folder-path [<index>]`.
- `meta.json` placeholders are more flexible. You can now use nested keys and arrays such as `{{promptContext.systemContext.language}}`.
- `{{segments}}` now formats speaker-separated transcript data into readable output, which makes it much easier to pass multi-speaker transcripts into scripts and automations.
- New `{{frontAppUrl}}` exposes the active browser URL in supported browsers.
- New `triggerUrls` lets actions match against the current browser page. This is still experimental, and not all browsers are supported yet.
- Placeholders now support transforms such as `{{placeholder::transform||find||replace}}`, plus capture transforms like `${1::uppercase}` inside regex replacements.
- Supported transforms include uppercase/lowercase variants, title case, sentence cleanup, camelCase, PascalCase, snake_case, kebab-case, trimming, and alternating/random case.
- If a transform depends on exact first-letter casing, you may want to disable `smartCasing` for that action.
- Placeholder parsing was refactored so placeholders can now include curly brackets (such as `${1::uppercase}`).
- Fixed simReturn so chained insert actions press Return before the next nextAction step begins.
- `simReturn` now also works for empty `""` and `.none` insert actions, and can be gated with insert `inputCondition`.

**CLI and runtime improvements**
- New `--copy-action <name>` renders an action and copies the result to the clipboard without polluting `{{clipboardContext}}`. It supports placeholder expansion and context placeholders.
- `--exec-action`, `--get-action`, and `--copy-action` now support `--meta`, so they can target a recording folder name, a recording folder path, or a compatible standalone `meta.json` file.
- New `--run-auto [--meta <value>]` runs the same automatic action selection logic Macrowhisper uses live, including bypass modes, trigger muting, triggers, and active-action fallback (a great way to re-insert your last dictation following same triggers).
- `--run-auto` ignores one-time runtime overrides such as `--schedule-action` and `--auto-return`.
- New `--validate-config` validates both JSON syntax and Macrowhisper config rules, and config error reporting is clearer.
- New `--mute-triggers` can mute triggers persistently or temporarily for a set duration.
- `--auto-return` now uses the resolved action payload when possible instead of always falling back to a plain `swResult` insert.
- Running `--exec-action` now also respects `moveTo` when there is a real recording folder to move or delete.
- Config path commands are more predictable: `--set-config` saves and switches paths without starting the daemon, `--reset-config` returns to the default path the same way, and `--config <path>` now persists the path immediately and starts the daemon if needed.
- `--exec-action` and `--run-auto` restore the clipboard using one chain-level snapshot, matching watcher-style behavior more closely.
  - CLI clipboard restoration now happens only once at the end of the chain, according to the final step’s `restoreClipboard` and `restoreClipboardDelay`.
  - CLI chains only restore the clipboard if a step in that chain actually wrote to the clipboard, so non-insert-only flows avoid unnecessary clipboard churn.
  - CLI clipboard cleanup remains separate from clipboard restoration, so `{{clipboardContext}}` protection still works without changing restore semantics.

**Reliability, consistency, and performance**
- `{{clipboardContext}}` is now frozen when the recording is validated, so delayed or chained actions keep a stable clipboard snapshot instead of reading a changing live clipboard later.
- That frozen clipboard behavior now applies consistently across all action types, still supports pre-recording clipboard fallback and stacking, and keeps recent Superwhisper sync noise out of the captured context.
- `appContext`, `frontApp`, and `appVocabulary` are now captured lazily only when needed, while `selectedText` and `clipboardContext` are captured once per recording session and reused across chains.
- Selected text capture via Accessibility has been improved.
- Active URL capture via Accessibility has been improved.
- Trigger matching for front apps is more forgiving. Macrowhisper now works if either the app name or the bundle ID is available.
- Recording validation is smarter: if an LLM result is expected, Macrowhisper waits for that result even if the raw voice field is empty.
- In those LLM-driven cases, voice triggers still match only the raw transcription (`result`), not the processed LLM output.
- Burst protection is stronger. If multiple new recordings appear at the same time, Macrowhisper now skips all of them instead of risking the wrong action on the wrong session.
- Logs were cleaned up to be easier to read and less noisy.
- The documentation has been fully updated to match the new behavior.
  
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