# Getting Started

[← Documentation index](README.md) · [Configuration](configuration.md) · [Actions](actions.md) · [Triggers and conditions](triggers-and-conditions.md)

Macrowhisper works with [Superwhisper](https://superwhisper.link/robert). Superwhisper turns your voice into text. Macrowhisper decides what should happen next.

That "next step" can be as simple as pasting your text, or as advanced as opening a website, running a Shortcut, launching a shell command, or chaining several actions together.

If you are new, start with these sections:

1. [What Macrowhisper Does](#what-macrowhisper-does)
2. [Quick Start](#quick-start)
3. [What Happens After You Dictate](#what-happens-after-you-dictate)
4. [Configuration Basics](configuration.md#configuration-basics)
5. [Action Types](actions.md#action-types)
6. [Triggers](triggers-and-conditions.md#triggers)
7. [Config Examples](examples.md#config-examples)
8. [Troubleshooting](troubleshooting.md#troubleshooting)

Everything else is there when you want more control.

## What Macrowhisper Does

Macrowhisper is an automation layer for Superwhisper.

Superwhisper is great at turning speech into text. Macrowhisper makes that text useful by sending it where you want it to go, in the format you want, with the rules you choose.

In practice, that means you can:

- paste your dictated text into the current app
- open a search or a website
- send the text into a macOS Shortcut
- run a shell command
- run an AppleScript
- decide different behavior by phrase, app, mode, or browser URL
- chain several actions together

### The action types

Macrowhisper can run five kinds of actions:

- Insert actions: paste or type text
- URL actions: open websites or apps
- Shortcut actions: run macOS Shortcuts
- Shell actions: run Terminal commands
- AppleScript actions: run AppleScript code

### What it helps with

Without Macrowhisper, a normal voice workflow often looks like this:

1. Dictate text.
2. Clean it up manually.
3. Switch to another app.
4. Copy and paste it somewhere else.
5. Run a shortcut, script, or macro by hand.
6. Repeat that many times a day.

With Macrowhisper, the flow can become:

1. Dictate once.
2. Macrowhisper chooses the right action.
3. The action runs right away.
4. Any follow-up steps run automatically.
5. Clipboard handling stays consistent.

### A simple mental model

Think of Macrowhisper like this:

- Superwhisper gives you the text.
- Macrowhisper decides what to do with the text.

### What happens behind the scenes

At a high level, Macrowhisper:

1. Detects a new Superwhisper recording.
2. Waits until the result is ready.
3. Collects useful context such as the front app, selected text, and clipboard context.
4. Chooses which action should run.
5. Runs that action, plus any chained actions.
6. Cleans up afterward.

You do not need to memorize that to use the app, but it helps when setting up more advanced behavior.

### Quick examples

#### Example 1: Voice command -> web search

- You say: `google best mechanical keyboard for mac`
- `triggerVoice` matches `google`
- Macrowhisper removes the trigger word and opens:
  `https://www.google.com/search?q=best mechanical keyboard for mac`

#### Example 2: Dictation -> writing template

- You dictate in a specific Superwhisper mode
- an insert action pastes a template around your text
- your dictation appears inside the template by using `{{swResult}}`

Result: the output keeps the same format every time.

#### Example 3: Dictation -> Shortcut

- You dictate a task
- a Shortcut action sends the text to a macOS Shortcut
- the Shortcut creates or updates something in another app

#### Example 4: Dictation -> script

- You say: `log this release note`
- a shell action writes the processed text to a file
- the format and destination stay consistent

---

## Quick Start

This is the fastest path to a working setup.

### Install option 1: Homebrew

```bash
brew install ognistik/formulae/macrowhisper
```

### Install option 2: Install script

```bash
curl -L https://raw.githubusercontent.com/ognistik/macrowhisper/main/scripts/install.sh | sudo sh
```

The script installs the prebuilt release version specified in the script and
verifies its SHA-256 hash before copying the binary.

### Set up Superwhisper

These settings matter:

- Recording Window: ON
- Paste Result Text: OFF
- Restore Clipboard After Paste: OFF
- Simulate Key Presses: OFF

Macrowhisper should be the one handling paste, clipboard, and key behavior.

### Open or create your config

```bash
macrowhisper --reveal-config
```

Default path:

`~/.config/macrowhisper/macrowhisper.json`

### Start the background service

```bash
macrowhisper --start-service
```

Check that it is running:

```bash
macrowhisper --service-status
```

### First test

Dictate once in a normal text field.

By default, Macrowhisper creates an `autoPaste` action and sets it as `defaults.activeAction`, so the starting behavior should feel very close to normal Superwhisper paste behavior.

If that works, the basic setup is done.

---

## What Happens After You Dictate

This section gives you the best overall picture of how Macrowhisper behaves.

### Step A: A recording starts

When a new recording folder appears, Macrowhisper begins tracking that session.

At startup, existing recording folders are marked as processed. Macrowhisper
then waits for a single new folder; simultaneous arrivals are marked processed
without execution, and an older folder arriving later is treated as a cloud
sync copy and skipped.

At this stage it can capture:

- selected text at the start of the session
- the clipboard state at the start of the session
- recent clipboard context from the pre-recording buffer window

### Step B: It waits for a usable result

Macrowhisper waits until `meta.json` contains the result it needs.

The short version:

- if `languageModelName` is non-empty, Macrowhisper waits for a non-empty
  `llmResult` string
- otherwise, it waits for a non-empty `result` string
- for the integrated S1 pair (`languageModelKey` `sl-1` and `modelKey` `sv-1`),
  a non-empty `llmResult` with an empty `result` gets a one-second settle grace
  period before processing

Malformed or incomplete metadata stays under watch for a later update. A
recording with no WAV file is given a 17-second grace period; removed audio or
metadata can cause the session to be recovered and skipped.

This prevents actions from firing too early.

### Step C: It gathers runtime context

Before running an action, Macrowhisper can gather:

- front app name
- front app bundle ID
- selected text
- clipboard context
- front app PID

If you use `{{appContext}}` or `{{appVocabulary}}`, those are only collected when needed and then reused during the rest of the action chain.

### Step D: It can skip processing for some modes

If `defaults.bypassModes` matches the current Superwhisper mode, Macrowhisper skips all action processing for that recording.

This is useful when you want certain modes to behave as if Macrowhisper were not involved.

The recording is still marked processed and its pending monitoring state is
cleaned up. The comparison is case-insensitive.

### Step E: It chooses which action should run

Macrowhisper chooses actions in this order:

1. one-time `--auto-return`
2. one-time `--schedule-action`
3. trigger matches (`triggerVoice`, `triggerApps`, `triggerModes`, `triggerUrls`)
4. `defaults.activeAction`
5. no action

That order matters. A scheduled action can override triggers, and a trigger can override your normal active action.

### Step F: It runs the action, then any chained actions

If the chosen action has a `nextAction`, Macrowhisper can continue into the next step automatically.

Shortcut, shell, and AppleScript actions are asynchronous by default so Macrowhisper stays responsive. If you want Macrowhisper to wait for the script to finish, set:

- `scriptAsync: false`
- `scriptWaitTimeout`

### Step G: It finishes cleanup

After the action flow ends, Macrowhisper may:

- resolve the final action's `moveTo`: `null` or omission inherits the
  `defaults.moveTo` value, explicit `""` keeps the folder in place even when
  that default is nonempty, and a nonempty path or `.delete` moves or deletes it
- clean up temporary monitoring state
- restore the clipboard if needed
- run retention cleanup if `history` is enabled

History cleanup is disabled when `history` is `null`; `0` keeps only the newest
recording, and a positive value keeps that many days. It runs asynchronously
after the action (normally after about 30 seconds) and no more than once per
24 hours within a running daemon process. `.none` is an action payload value,
not a `moveTo` sentinel; see [moveTo](clipboard-and-recordings.md#moveto) and
[Runtime](runtime.md#recovery-and-cleanup) for the recovery and cleanup edge
cases.

---
