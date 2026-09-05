# Macrowhisper documentation

Macrowhisper turns Superwhisper recordings into configured actions: paste text, open URLs, run Shortcuts or scripts, and chain steps together.

For installation and a first working setup, start with the [repository README](../README.md). This index maps the complete reference by topic. If you are using AI for help, provide this index and ask it to read the linked pages relevant to your task.

The documentation follows the repository version you are viewing. An installed
release may not include changes listed under `UNRELEASED` in the [changelog](../CHANGELOG.md).
For release-specific behavior, consult the documentation at that release's Git tag.

## Start here

1. [Getting started](getting-started.md): what Macrowhisper does, setup, and what happens after you dictate.
2. [Configuration](configuration.md): the configuration structure, inheritance, special values, and every global default.
3. [Actions](actions.md) and [triggers and conditions](triggers-and-conditions.md): choose what runs and when it runs.
4. [Examples](examples.md): complete configurations and workflows to adapt.

## User reference

| Document | What you will find |
| --- | --- |
| [Getting started](getting-started.md) | Capabilities, installation, essential Superwhisper settings, first use, and the recording-to-action sequence. |
| [CLI reference](cli-reference.md) | Commands for configuration, services, and actions; runtime behavior matrix; `--meta`; updates; full uninstall. |
| [Configuration](configuration.md) | Top-level sections, defaults and action overrides, `null` and empty values, special action values, watch-folder recovery, and validation rules. |
| [Actions](actions.md) | Insert, URL, Shortcut, shell, and AppleScript actions; shared and type-specific fields; `nextAction` chains; script output and wait behavior. |
| [Triggers and conditions](triggers-and-conditions.md) | Voice, app, mode, and browser URL triggers; matching priority, exceptions, regex, `triggerLogic`, and `inputCondition`. |
| [Placeholders and context](placeholders-and-context.md) | Placeholder syntax, metadata, context capture, transforms, regex replacements, escaping, and a prompt for AI help with regex pipelines. |
| [Clipboard and recordings](clipboard-and-recordings.md) | Clipboard timing, restoration, stacking, attachments and cache limits, async behavior, `moveTo`, and recording history. |
| [Runtime](runtime.md) | One-time scheduling and auto-return, timeout rules, bypass modes, and how automatic selection differs from `--run-auto`. |
| [Examples](examples.md) | An everyday configuration, a chained workflow, and a custom transform pipeline. |
| [Troubleshooting](troubleshooting.md) | Initial checks, log locations, configuration issues, and common action, trigger, context, and clipboard problems. |

## Find an answer by task

- **Set up a voice command:** read [triggers and conditions](triggers-and-conditions.md), then choose an [action type](actions.md).
- **Configure Superwhisper for first use or after an update:** follow the [recommended setup](getting-started.md#set-up-superwhisper), then check [matching Macrowhisper settings](getting-started.md#if-you-change-these-settings) if you change window, insertion, or restoration behavior.
- **Change a default or override one action:** read [configuration](configuration.md), then the relevant fields in [actions](actions.md).
- **Use selected text, app information, or clipboard context:** read [placeholders and context](placeholders-and-context.md); use [clipboard and recordings](clipboard-and-recordings.md) for restoration and attachment behavior.
- **Run several steps or reuse script output:** read [actions](actions.md), then [examples](examples.md).
- **Run an action against an earlier recording:** read the `--meta` and recording-selection commands in the [CLI reference](cli-reference.md).
- **Understand why an action did not run:** begin with [troubleshooting](troubleshooting.md), then check [triggers and conditions](triggers-and-conditions.md) and [runtime](runtime.md).
- **Update or uninstall:** use the [CLI reference](cli-reference.md).
- **Build a signed binary for manual testing:** use the [development guide](development/README.md).

## Development and maintenance

These pages describe implementation and contributor workflows. The user reference above describes configuration and observable behavior.

| Document | What you will find |
| --- | --- |
| [Development guide](development/README.md) | Local builds and signing, regression checks, debugging, and common implementation tasks. |
| [Codebase map](development/codebase-map.md) | Source layout, component responsibilities, and where to make changes. |
| [Processing flow](development/processing-flow.md) | Watchers, action selection and execution, clipboard synchronization, timing, and edge cases. |
| [Releasing](development/releasing.md) | Release setup, preparation, preflight, signing and notarization, draft review, publication, and recovery. |
| [Local editor plan](development/web-editor-plan.md) | Proposed experimental web configuration editor: design direction, architecture, implementation milestones, and verification gates. Not an implemented feature. |

Agents working on the repository should also read [AGENTS.md](../AGENTS.md). Version history is in the root [changelog](../CHANGELOG.md).

## Project links

- [Macrowhisper on GitHub](https://github.com/ognistik/macrowhisper)
- [Report an issue](https://github.com/ognistik/macrowhisper/issues)
- [Alfred workflow](../alfred/README.md)
