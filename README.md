# Macrowhisper

Macrowhisper is an automation helper for [Superwhisper](https://superwhisper.link/robert). Superwhisper turns your voice into text; Macrowhisper watches the resulting recording and decides what to do next.

It can paste or type the result, open a URL, run a macOS Shortcut, run a shell command or AppleScript, and chain several actions together. Actions can be selected by voice phrase, frontmost app, Superwhisper mode, browser URL, or a normal fallback action.

[![Swift Version](https://img.shields.io/badge/Swift-6.1.2-orange.svg)](https://swift.org)
[![Platform](https://img.shields.io/badge/Platform-macOS-blue.svg)](https://www.apple.com/macos/)

## Requirements

- macOS 12.4 or later. This is the deployment target configured for the current macOS executable.
- [Superwhisper](https://superwhisper.link/robert), configured to save recordings.
- Accessibility permission for the installed `macrowhisper` executable. Macrowhisper uses it for insertion, key simulation, selected text, and app context. Grant it in System Settings → Privacy & Security → Accessibility when macOS prompts you.
- Automation permission may be requested when you use Shortcuts, AppleScript, or System Events actions.

## Install

### Homebrew

```bash
brew install ognistik/formulae/macrowhisper
```

### Install script

```bash
curl -L https://raw.githubusercontent.com/ognistik/macrowhisper/main/scripts/install.sh | sudo sh
```

The script installs the latest prebuilt release and its JSON schema. It installs to `/usr/local/bin` by default; pass an absolute directory as the script argument when you need another location.

## First use

In Superwhisper, set these options so Macrowhisper owns the paste and clipboard flow:

- `Recording Window`: ON
- `Paste Result Text`: OFF
- `Restore Clipboard After Paste`: OFF
- `Simulate Key Presses`: OFF

Then create the configuration, check its path, validate it, and start the background service:

```bash
macrowhisper --reveal-config
macrowhisper --get-config
macrowhisper --validate-config
macrowhisper --start-service
macrowhisper --service-status
```

`--reveal-config` creates the file when it does not exist and opens it in Finder. The default path is `~/.config/macrowhisper/macrowhisper.json`. A generated configuration creates an `autoPaste` insert and uses it as `defaults.activeAction`, so you can dictate into a normal text field immediately after granting Accessibility permission and starting the service.

The generated `defaults.watch` value follows Superwhisper's configured folder when it can read that setting. A fresh installation normally uses `~/superwhisper`; existing `~/Documents/superwhisper` and custom locations are supported. The value is the Superwhisper folder containing `recordings`, rather than the `recordings` directory itself.

If the recording window does not close reliably, try a small `defaults.actionDelay` such as `0.05` to `0.2` seconds.

## Configuration

`configVersion: 2` is the current configuration format. In action overrides, `null` usually inherits the value from `defaults`, while `""` means an intentional empty value. The generated `$schema` reference is managed automatically when a local schema is available.

To use a different configuration location, pass a file or directory. A directory receives the default filename `macrowhisper.json`:

```bash
macrowhisper --set-config ~/my-configs/
macrowhisper --get-config

# Return to ~/.config/macrowhisper/macrowhisper.json
macrowhisper --reset-config
```

After editing, validate the file. `--update-config` applies current schema and formatting changes while preserving your settings:

```bash
macrowhisper --validate-config
macrowhisper --update-config
```

This small configuration makes ordinary dictation paste into the current text field and turns `ask google ...` into a browser search. Keep the generated `watch` path if it differs from the example because your Superwhisper folder is elsewhere.

```json
{
  "configVersion": 2,
  "defaults": {
    "watch": "~/superwhisper",
    "activeAction": "pasteResult"
  },
  "inserts": {
    "pasteResult": {
      "action": "{{swResult}}"
    }
  },
  "urls": {
    "search": {
      "action": "https://www.google.com/search?q={{result}}",
      "triggerVoice": "ask google"
    }
  },
  "shortcuts": {},
  "scriptsShell": {},
  "scriptsAS": {}
}
```

`{{swResult}}` is the final transcription value. A normal `triggerVoice` pattern matches at the start of the spoken result, and `{{result}}` receives the remaining voice text for the URL. See [configuration](docs/configuration.md), [actions](docs/actions.md), and [triggers and conditions](docs/triggers-and-conditions.md) for the complete behavior.

## Action selection

For a recording, Macrowhisper evaluates actions in this order:

1. one-shot `--auto-return`
2. one-shot `--schedule-action`
3. matching voice, app, mode, or URL triggers
4. `defaults.activeAction`

The first applicable level wins. Trigger matches are ranked by voice, Superwhisper mode, browser URL, then frontmost app; more-specific matches win within a level. `defaults.bypassModes` can skip Macrowhisper processing for selected Superwhisper modes.

## Essential commands

Configuration and service commands do not require a running daemon:

```bash
macrowhisper --help
macrowhisper --version
macrowhisper --get-config
macrowhisper --validate-config
macrowhisper --update-config
macrowhisper --start-service
macrowhisper --service-status
macrowhisper --restart-service
```

Runtime and action commands use the running service:

```bash
macrowhisper --status
macrowhisper --action <name>          # set the fallback action
macrowhisper --action                 # clear the fallback action
macrowhisper --list-actions
macrowhisper --get-action [name]
macrowhisper --copy-action <name>
macrowhisper --exec-action <name>
macrowhisper --run-auto
macrowhisper --schedule-action <name> # use an action for the next session
macrowhisper --schedule-action       # cancel the scheduled action
macrowhisper --auto-return true       # enable one-shot Return behavior
macrowhisper --mute-triggers 10m     # mute triggers temporarily
```

`--exec-action`, `--run-auto`, and `--copy-action` use the latest valid result by default. Use `--meta` to target a recording folder, folder path, or compatible JSON file; the [CLI reference](docs/cli-reference.md) covers those forms and the full command set.

## Documentation

For complete feature explanations, configuration examples, and troubleshooting, start with [the documentation index](docs/README.md).

You can also share the index with an AI assistant and describe what you want Macrowhisper to do. Ask it to read the relevant linked pages to help you set up a workflow, understand a feature, or troubleshoot your configuration.

The [Alfred workflow](alfred/README.md), [Macrowhisper repository](https://github.com/ognistik/macrowhisper), and [issue tracker](https://github.com/ognistik/macrowhisper/issues) are also available.

If Macrowhisper is useful in your workflow, you can [buy me a coffee](https://buymeacoffee.com/afadingthought/). Macrowhisper is an independent project and is not affiliated with Superwhisper.
