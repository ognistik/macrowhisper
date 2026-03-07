# Macrowhisper

Automation helper for [Superwhisper](https://superwhisper.com/?via=robert) on macOS.

Macrowhisper watches Superwhisper recordings and runs configured actions based on triggers (voice, app, mode, or browser URL) or a fallback active action.

[![Swift Version](https://img.shields.io/badge/Swift-6.1.2-orange.svg)](https://swift.org)
[![Platform](https://img.shields.io/badge/Platform-macOS-blue.svg)](https://www.apple.com/macos/)

## Learn More
- Full docs and examples: [by.afadingthought.com/macrowhisper](https://by.afadingthought.com/macrowhisper)
- Alfred workflow: [github.com/ognistik/macrowhisper/tree/main/alfred](https://github.com/ognistik/macrowhisper/tree/main/alfred)
- Codebase map: [github.com/ognistik/macrowhisper/blob/main/src/CODEBASE_MAP.md](https://github.com/ognistik/macrowhisper/blob/main/src/CODEBASE_MAP.md)
- Processing flow: [github.com/ognistik/macrowhisper/blob/main/src/PROCESSING_FLOW.md](https://github.com/ognistik/macrowhisper/blob/main/src/PROCESSING_FLOW.md)

## Quick Start

### Install
```bash
brew install ognistik/formulae/macrowhisper
```

Or install from script:
```bash
curl -L https://raw.githubusercontent.com/ognistik/macrowhisper/main/scripts/install.sh | sudo sh
```

### Configure
```bash
# Create/reveal config in Finder (default: ~/.config/macrowhisper/macrowhisper.json)
macrowhisper --reveal-config

# (Optional) Store config in a custom location
macrowhisper --set-config ~/my-configs/

# Check which config path is active
macrowhisper --get-config
```

### Run as Service
```bash
macrowhisper --start-service
macrowhisper --service-status
```

### Essential Superwhisper Settings
To avoid conflicts, in Superwhisper set:
- OFF: `Paste Result Text`, `Restore Clipboard After Paste`, `Simulate Key Presses`
- ON: `Recording Window`

If the recording window does not close reliably, you can increase `defaults.actionDelay` in Macrowhisper config.

## Core CLI Commands

### Service + Config
```bash
macrowhisper --start-service
macrowhisper --stop-service
macrowhisper --restart-service
macrowhisper --uninstall-service
macrowhisper --service-status

macrowhisper --reveal-config
macrowhisper --set-config <path>
macrowhisper --reset-config
macrowhisper --get-config
macrowhisper --validate-config
macrowhisper --update-config
macrowhisper --schema-info
```

### Runtime + Actions (daemon must be running)
```bash
macrowhisper --status
macrowhisper --action <name>           # set fallback action
macrowhisper --action                  # clear fallback action
macrowhisper --get-action [name]
macrowhisper --get-icon
macrowhisper --folder-name [index]
macrowhisper --folder-path [index]
macrowhisper --copy-action <name>
macrowhisper --exec-action <name>
macrowhisper --run-auto
macrowhisper --schedule-action <name>  # one-shot next session override
macrowhisper --schedule-action         # cancel scheduled action
macrowhisper --auto-return <true/false>
macrowhisper --mute-triggers <true/false/duration>
macrowhisper --check-updates

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

## How Matching Works
Processing priority is strict:
1. One-shot runtime overrides (`--auto-return`, `--schedule-action`)
2. Trigger-matched actions (`triggerVoice`, `triggerApps`, `triggerModes`, `triggerUrls`, `triggerLogic`)
3. `defaults.activeAction` fallback

You can also bypass Macrowhisper entirely for specific Superwhisper modes with `defaults.bypassModes`.

## Minimal Config Example

```json
{
  "$schema": "file:///opt/homebrew/share/macrowhisper/macrowhisper-schema.json",
  "configVersion" : 2,
  "defaults": {
    "watch": "~/Documents/superwhisper",
    "activeAction": "autoPaste",
    "actionDelay": 0.02,
    "restoreClipboard": true,
    "scheduledActionTimeout": 5,
    "clipboardBuffer": 5,
    "redactedLogs": false
  },
  "inserts": {
    "autoPaste": {
      "action": ".autoPaste"
    },
    "pasteResult": {
      "action": "{{swResult}}"
    }
  },
  "urls": {
    "Google": {
      "action": "https://www.google.com/search?q={{result}}",
      "triggerVoice": "ask google"
    }
  },
  "shortcuts": {},
  "scriptsShell": {},
  "scriptsAS": {}
}
```

Use `macrowhisper --validate-config` to catch config issues quickly, and `macrowhisper --update-config` after upgrades to apply new schema fields and formatting while preserving your settings.

## Useful Placeholders
- `{{swResult}}`: final transcription result
- `{{result}}`: voice-only transcript from meta.json (used for voice triggers)
- `{{raw:swResult}}`: no escaping (raw value)
- `{{json:swResult}}`: JSON-escaped value
- `{{selectedText}}`: selected text captured at recording start
- `{{clipboardContext}}`: clipboard context captured during recording and optional pre-recording buffer
- `{{appContext}}`: active app/input context
- `{{appVocabulary}}`: likely names, identifiers, and app-specific terms from the front app
- `{{frontApp}}`, `{{frontAppUrl}}`: front app name and current URL in supported browsers
- `{{folderName}}`, `{{folderPath}}`: current or recent recording folder info
- `{{actionResult}}`: output from a prior synchronous script-like step in a chain
- `{{date:short}}`, `{{date:long}}`, `{{date:yyyy-MM-dd}}`
- `{{xml:tagname}}`: extract XML tag content
- `{{placeholder||pattern||replacement}}`: regex replacement pipeline
- `{{placeholder::transform}}`: transform placeholders before use

Any compatible `meta.json` key can also be used as a placeholder, including nested values such as `{{promptContext.systemContext.language}}` and `{{segments}}`.

## Notes for Power Users
- Config values can be set globally in `defaults` and overridden per action.
- Most per-action fields support `null` to inherit global defaults.
- URL actions support `openWith` and `openBackground`.
- Actions support chaining via `nextAction`.
- Action-level `inputCondition` can gate options by input state.
- Insert actions can also use `smartCasing`, `smartPunctuation`, and `smartSpacing` for cleaner output around the insertion point.
- Shortcut, shell, and AppleScript actions run asynchronously by default; set `scriptAsync: false` and `scriptWaitTimeout` when you want to wait for completion.
- `--copy-action`, `--get-action`, `--exec-action`, and `--run-auto` support `--meta` so you can target a specific recording folder or compatible `meta.json`.
- `{{clipboardContext}}`, `{{selectedText}}`, and front-app context are captured with stable runtime snapshots so chained actions stay consistent.

## Explore More
Beyond this quick start, Macrowhisper supports advanced patterns and control:
- Trigger exceptions (`!pattern`) and raw-regex triggers (`==...==`) for precise matching.
- Browser URL triggers and `{{frontAppUrl}}` work in supported browsers.
- Placeholder transforms and regex replacement pipelines for post-processing output.
- Special action values: `.autoPaste` (insert), `.none` (skip this step), `.run` (run Shortcut without input).
- Conditional behavior with `inputCondition`, plus multi-step flows via `nextAction`.

This README is intentionally concise. For complete reference, automation examples, and troubleshooting, see:
- [by.afadingthought.com/macrowhisper](https://by.afadingthought.com/macrowhisper)

## Support
If Macrowhisper is useful in your workflow, I'd be grateful if you [Buy me a coffee](https://buymeacoffee.com/afadingthought/)

Macrowhisper is an independent project and is not affiliated with Superwhisper.