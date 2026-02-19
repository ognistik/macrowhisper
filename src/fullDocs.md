## OVERVIEW

Macrowhisper is a powerful automation helper app for [Superwhisper](https://superwhisper.com/?via=robert). It monitors your recordings and executes intelligent automated actions based on configurable rules and triggers. It transforms your voice transcriptions into powerful automations by evaluating triggers, and executing various actions including text insertion, opening URLs, shell scripts, AppleScript, and macOS Shortcuts.

---

## KEY FEATURES

- **🎙️ Voice-Triggered Automations**
    - Execute actions based on voice patterns or keywords
- **🧠 Intelligent Trigger System**
    - Advanced pattern matching for applications and Superwhisper active mode
- **📝 Multiple Action Types**
    - Use your dictation results for text insertion, opening URLs, shell scripts, AppleScript, and macOS Shortcuts
- **⚙️ Service Integration**
    - Run as background service as a launch agent
- **🔄 Live Configuration**
    - JSON-based configuration with real-time reloading
- **🗂️ History Management**
    - Automatic cleanup of old recordings
- **🔌 CLI Interface**
    - Comprehensive command-line interface allows for easy integration with automation apps

---

## INSTALLATION & UPDATES

### Install with [Homebrew](https://brew.sh/)

```shell
brew install ognistik/formulae/macrowhisper
```

### Install with Script

```shell
# Installs Macrowhisper's binary in /usr/local/bin
curl -L https://raw.githubusercontent.com/ognistik/macrowhisper/main/scripts/install.sh | sudo sh
```

*You can also build the app yourself. All the files are in [this folder.](https://github.com/ognistik/macrowhisper/tree/main/src)*

---

### ￼Updating (if installed with Homebrew)

    + #### *Why do you need to re-grant accessibility permissions after update?*

        This issue occurs because macOS stores accessibility permissions tied to the absolute file path, not the application signature. Since Macrowhisper is a single binary application rather than an app bundle, when Homebrew upgrades it, the application gets placed in a version-specific folder. Each brew upgrade causes the binary to be stored at a different path, which macOS treats as a completely different application, effectively resetting the accessibility permissions.

        You'll notice multiple versions of Macrowhisper appearing in your System Settings → Privacy & Security → Accessibility panel after updates. You can manually remove these stale entries when upgrading, but unfortunately there's no automatic workaround as long as you install using Homebrew due to this path-based permission system.

        >>> **Alternative installation option**: If you prefer not to re-grant accessibility permissions after each update, you can install Macrowhisper using the script instead of Homebrew.

```shell
# Check for available updates across all your Homebrew apps
brew update

# Install the latest version of Macrowhisper
brew upgrade macrowhisper

# Restart the service
macrowhisper --restart-service
```

*You can also update everything at once with `brew upgrade` (without specifying an app name).*

### Updating (if installed with Script)

```shell
# Run the exact same script
curl -L https://raw.githubusercontent.com/ognistik/macrowhisper/main/scripts/install.sh | sh

# Restart the service
macrowhisper --restart-service
```

---

*Macrowhisper has a built-in mechanism that will notify you when there's an update available. If you choose to turn that off, you can also track updates directly [over at Github.](https://github.com/ognistik/macrowhisper)*

---

## SETUP

# Quick Start

### Configuration File Path

By default, the configuration file will be auto-created and loaded from `~/.config/macrowhisper/macrowhisper.json` . You can change this before running the app with the following:

```shell
macrowhisper --set-config "path-to-new-folder"
```

---

### Auto-Updates Setting

When you first run Macrowhisper, it checks online for app updates. Subsequent checks happen every 24 hrs. If you're concerned about these online calls, you can set `noUpdates` to `true` in the configuration to disable this feature.

The following command will always reveal your configuration file or create one if there's none.

```shell
macrowhisper --reveal-config
```

---

### Superwhisper's Path

Since Macrowhisper monitors recordings created by Superwhisper, you need to verify that the correct Superwhisper folder is set as the correct watch path. Superwhisper creates its folder in Documents by default, so you shouldn't need to change this unless you've manually chosen a new location. This is set in the `watch` key of Macrowhisper's configuration.

---

### Superwhisper's Settings

Since Macrowhisper handles the processing and pasting of your dictation results, you need to adjust a few Superwhisper settings to prevent conflicts and ensure everything works correctly.

- **Recording Window:** Keep the recording window enabled in Superwhisper.
- **Auto-close Recording Window:** For most flexibility, it is suggested you toggle this off. If you prefer Superwhisper to close the recording window automatically for every single dictation, you can leave it on. In that case, you'd need to set the `noEsc` setting in Macrowhisper's defaults from `false` to `true`.
- **Paste Result Text:** Turn this off. Macrowhisper will handle all text pasting.
- **Restore Clipboard After Paste:** Turn this off to avoid conflicts between the two apps. Macrowhisper will manage clipboard restoration.
- **Simulate Key Presses:** Turn this off. Macrowhisper includes this functionality, so you don't need both apps doing the same thing.

These changes ensure Macrowhisper can work without interference and gives you full control over your voice automation workflow.

---

### Start the Service

Now that you've configured both Superwhisper and Macrowhisper, you're ready to start the service! Macrowhisper runs as a launch agent that automatically starts when you restart your computer. You have complete control with multiple commands available, but two are essential:

```shell
# Starts the service (installs it first if needed)
macrowhisper --start-service

# Stops the service if it's running and removes it completely
macrowhisper --uninstall-service
```

---

### Testing Your Setup

After setting up the service you will need to give the app accessibility permissions. This is required for paste actions and key simulation (such as ESC to close the recording window). Do a quick test first. Start dictating in different applications around your system. You'll notice that Macrowhisper's default behavior works exactly like Superwhisper's auto-paste feature:

- **In input fields**: The transcription result goes directly to the input field
- **Outside input fields**: The result stays in the recording window (when input fields can't be detected)

If you are not seeing results pasted, it's possible that accessibility permissions were not granted, or that the app needs to be restarted. In that case, you can run the following:

```shell
macrowhisper --restart-service
```



> Once you’ve finished setup and have the service running, you’re ready to see how Macrowhisper works and make it your own. 👇️

> *Note: Macrowhisper runs alongside Superwhisper, picking up your dictation results for flexible automation—no changes to how Superwhisper itself works. The defaults match what you’re used to, but you can tweak and customize whatever you want.*

---

## USING MACROWHISPER

+ #### Sample Configuration

    >> ***Feel free to check and download this [sample configuration file](https://github.com/ognistik/macrowhisper/blob/main/samples/macrowhisper.json) to get started with Macrowhisper.** Even if you don't understand everything yet, having this configuration gives you working examples to reference as you learn.* 

    >> 

    >> *This sample is also designed to (optionally) work with the Keyboard Maestro macros shared later in this guide, so if you plan to use those automations, you'll want this configuration (or the actions in it) in place.

To install it safely, you can first stop the service with `macrowhisper --stop-service`, then replace your existing configuration file with the downloaded sample, and restart with `macrowhisper --start-service`. Another opion is to just replace the file and run `macrowhisper --restart-service` .This prevents any conflicts with the running application and ensures everything loads properly.*

# Configuration Management

Macrowhisper uses a JSON configuration file that updates in real-time. Here's how it works:

1. **Live reloading**: Every time you save changes to your configuration file, Macrowhisper automatically loads the new settings
2. **JSON format**: All settings use JSON format, so be careful with escaping characters like double quotes (`\"` ). Line breaks in actions should works if you write them as usual (`\n`)
3. **Command-line helpers**: You can add new actions directly via command line, which pre-fills default fields for you
4. **Execute Actions:** Once you've set actions, triggers, and conditions, you can also execute them or interact with the app via commands, which allows for automation integrations

---

#### **To see all available commands:**

```shell
macrowhisper --help
```

---

## JSON Basics

> If you've never edited a JSON file before, don't worry. It's not complicated at all. I made this short video to show you the basics of editing JSON files. Think of it as a quick way to get started.

[Editing the Config](https://screen.studio/share/aP6JJow7)

# Value Types & Priority

Macrowhisper uses different types of values in its configuration. Understanding how these work will help you customize your actions exactly how you want them.

> ### How Defaults and Overrides Work

> Think of defaults as your baseline settings. Every action can either use these defaults or override them with its own values. Here's the key concept: **empty values in actions fall back to defaults, but sometimes you want to explicitly disable something instead**.

---

## String Values (Text in Double Quotes)

String values hold text, paths, or other text-based information. They're always wrapped in double quotes.

| **Location** | **Value**       | **What It Means**                                    |
| ------------ | --------------- | ---------------------------------------------------- |
| Defaults     | `"custom text"` | This is your baseline text                           |
| Defaults     | `""`            | Nothing set at the default level                     |
| Action       | `"custom text"` | Override the default with this value                 |
| Action       | `""`            | Use whatever is set in defaults                      |
| Action       | `".none"`       | Explicitly use nothing (don't fall back to defaults) |

#### **Examples at the action level:**

- > `"icon": "•"` - Shows a bullet icon
- > `"icon": ""` - Uses the default icon (if any)
- > `"icon": ".none"` - Shows no icon, even if defaults has one
- > `"moveTo": ""` - Follows the default `moveTo` setting
- > `"moveTo": "~/Desktop"` - Moves dictation files to Desktop after processing
- > `"moveTo": ".delete"` - deletes dictation files after processing
- > `"moveTo": ".none"` - Disables the `moveTo` setting regardless of the defaults
- > `"action": ".none"` - Does nothing (useful for insert actions that just display results)
- > `"action": ".autoPaste"` - Special value. Behaves as Superwhisper's default autoPaste.

---

## Boolean Values (True/False)

These settings are either on or off. They control yes/no behaviors.

| **Location** | **Value**         | **What It Means**               |
| ------------ | ----------------- | ------------------------------- |
| Defaults     | `true` or `false` | Your baseline on/off setting    |
| Action       | `true` or `false` | Override the default            |
| Action       | `null`            | Use whatever is set in defaults |

#### **Examples at the action level:**

- > `"pressReturn": true` - Always press Return after pasting
- > `"pressReturn": false` - Never press Return after pasting
- > `"pressReturn": null` - Use the default setting

---

## Number Values

These settings accept numeric values like delays or counts.

| **Location** | **Value**     | **What It Means**               |
| ------------ | ------------- | ------------------------------- |
| Defaults     | `0.5` or `10` | Your baseline number            |
| Action       | `1.2` or `5`  | Override the default            |
| Action       | `null`        | Use whatever is set in defaults |

#### **Examples at the action level:**

- > `"actionDelay": 0.5` - Wait half a second before executing
- > `"actionDelay": null` - Use the default delay

---

> ## Quick Reference

- > **Want to use defaults?** Leave strings empty (`""`) or set booleans/numbers to `null`
- > **Want to override defaults?** Set your own value
- > **Want to explicitly disable something?** Use `".none"` for strings

When you add actions through the command line, they automatically get set up with values that fall back to your defaults, so you only need to change what you want to customize. Try it:

```shell
# Add insert actions
macrowhisper --add-insert myNewAction

# Add url actions
macrowhisper --add-url myUrl

# Add Shortcut actions
macrowhisper --add-shortcut myShortcut

# Add Shell Script actions
macrowhisper --add-shell myScript

# Add AppleScript actions
macrowhisper --add-as myScript
```

# Active Action System

The **active action** is a special setting that determines your default behavior:

- **With active action set**: That action becomes your default for all interactions
- **Active action cleared**: You get Superwhisper's default behavior (results stay in recording window)
- **Default active action**: "autoPaste" (created automatically when you first run Macrowhisper)

---

## Managing Active Insert

```shell
# Set an action as active
macrowhisper --action <insert-name>

# Clear active action (results stay in recording window)
macrowhisper --action
```

This makes it easy to switch between auto-pasting or custom actions. You can easily integrate this with 3rd party automation apps.

# Trigger System

Beyond the active insert, you can set up **conditional triggers** that activate specific actions based on:

- **Voice patterns**: Specific words or phrases that appear at the beginning of your dictation
- **Applications**: Which app you're currently using
- **Superwhisper modes**: Which mode is active in Superwhisper

These triggers provide a seamless experience without needing automation apps or manual switching.

---

## How Triggers Work

> What we learned before about how to override default settings with action-level settings becomes very helpful useful you work with triggers. **Triggers take priority over your default active action**, which opens up a lot of possibilities.

Here's how it works: You can set up one way to handle your dictation results by default (as `activeAction`). Then, creating a separate action with a trigger for a specific app, you can make it behave completely differently. For example, you might want your dictation to paste automatically in most apps, but in one particular app, you want the result to just stay in the recording window instead of pasting anywhere.

---

## Trigger Types

> ## **Voice Triggers** (`triggerVoice`)

- Match specific words or phrases at the start of your dictation
- Example: `"save note"` matches "Save note, these are som random thoughts"
- Supports multiple patterns: `"save note|ask google|send message"`
- Exception patterns: `"!test"` to exclude dictations starting with "test"
- **Smart stripping**: When a voice trigger matches, the trigger word is automatically removed from the result (not the llmResult)

*NOTE: Voice triggers work with insert actions, but they really shine with other action types. When you say "Ask  google" to trigger a URL action or "save text" to run a shell script, the voice command feels natural and immediate. Insert actions can use voice triggers too, but the other action types benefit most from this hands-free activation*

> ## **App Triggers** (`triggerApps`)

- Activate actions only in specific applications
- Match by app name: `"Mail"` or bundle ID: `"com.apple.mail"`
- Allows regex pattern matching
- Example: Different behavior in Slack vs. email apps

> ## **Mode Triggers** (`triggerModes`)

- Work with your Superwhisper modes
- Allows regex pattern matching
- Example: you can use an `"Assistant"` custom mode to trigger an insert action with ".none" — to always have the result in the recording window, or you can use  `"Message"` mode with `pressReturn` set to true for auto-sending your dictations

---

## Combining Triggers

You can combine multiple trigger types using logic:

- **OR logic** (default): Action triggers if **any** condition matches
- **AND logic**: Action triggers only if **all** conditions match

Example: Voice trigger "email" AND app trigger "Slack" = only works when you start dictating with the word "email" while in Slack.

---

## Trigger Precedence

When multiple actions could activate:

1. **Triggered actions** (voice, app, or mode triggers) take precedence
2. **Active action** runs if no triggers match
3. **Default Superwhisper behavior** if no active action is set

***Note**: If multiple actions share the exact same trigger, only the first action (determined by its name) will execute to avoid conflicts. Make sure your triggers don't overlap, or you might not get the results you expect.*

# Available Settings

## Core Settings

> #### **`watch`** (String)

- > **Purpose**: Path to your Superwhisper recordings folder
- > **Default**: `~/Documents/superwhisper`
- > **Example**: `"/Users/yourname/Documents/superwhisper"`
- > **Note**: Must point to the folder containing the "recordings" subfolder

> #### **`activeAction`** (String)

- > **Purpose**: Name of the action to run when no triggers match
- > **Default**: `"autoPaste"`
- > **Example**: `"myCustomAction"` or set as empty `""` to disable

> #### **`$schema`** (String)

- > **Purpose**: Provides IDEs with a JSON schema to help users edit their configuration file with validation and auto-complete.
- > **Default**:
    - >> If installed via script: Points to the schema file located in the same directory as the binary.
    - >> If installed via Homebrew: Points to `/opt/homebrew/share/macrowhisper/macrowhisper-schema.json`.
- > **Behavior**: The schema file is automatically downloaded together with the installation and placed in the appropriate location. Users do not need to set or change this path manually; Macrowhisper manages the path and updates it automatically whenever you restart the service.

> #### **`scheduledActionTimeout`** (Number)

- > **Purpose**: Sets the maximum number of seconds to wait for a dictation to begin when a scheduled action is triggered via the `--schedule-action [<name>]` or `--auto-return <true/false>` CLI flags. If no dictation starts within this period, the scheduled action is automatically cancelled.
- > **Default**: `5` 
- > **Example**: `10` for a 10-second timeout. `0` for no timeout.
- > **Note**: You can also cancel a scheduled action by running the `--schedule-action` flag without any arguments.

> #### `autoUpdateConfig` (Boolean)

- > **Purpose**: Controls whether the app updates the configuration file after startup to include new schema changes and options from recent updates.
- > **Default**: `true` 
- > **Behavior**: When true, the app writes any new or changed configuration options to the config file at startup. When false, the app leaves the file unchanged; you can still run an update manually with the --update-config CLI flag.

> #### `redactedLogs`  (Boolean)

- > **Purpose**: Redact sensitive content from logs (dictation result, clipboard context, selected text, app context, trigger payloads, and regex replacement before/after values). Set to false only for deep debugging.
- > **Default**: `true` 

---

## Action Behavior

> #### **`actionDelay`** (Number)

- > **Purpose**: Delay in seconds before executing any action
- > **Default**: `0.0`
- > **Example**: `0.5` for half-second delay, `1.0` for one second
- > **Note**: Useful to give Macrowhisper time to process the result, if you notice conflicts between Superwhisper & Macrowhisper because of the use of clipboard, or for visual feedback

> #### **`pressReturn`** (true/false)

- > **Purpose**: Automatically press the Return key after executing an action
- > **Default**: `false`
- > **Example**: `true` to auto-send messages, `false` for manual sending
- > **Note**: Helpful for auto-sending in messaging apps

> #### **`returnDelay`** (Number)

- > **Purpose**: Delay in seconds before pressing Return when `pressReturn` is enabled
- > **Default**: `0.1`
- > **Example**: `0.2` for slight delay, `0.5` for longer pause

> #### **`icon`** (String or Special Value)

- > **Purpose**: Display a specific icon. Useful for assigning a visual cue to the active insert, when used in automation apps
- > **Default**: `""` (no custom icon)
- > **Values**:
    - >> Any single character or emoji: `"📝"`, `"•"`, `"⚡"`
    - >> **Special Value**: `".none"` to explicitly hide icons
- > **Example**: You can always get the active insert's icon by running `macrowhisper --get-icon`

> #### **`nextAction`** (String)

- > **Purpose**: Chain actions for execution one after the other
- > **Default: ""**
- > **Example**: "Google" (executes the Google action after the current action)
+ > **Note**s:
    - >> Every action can define one `nextAction` 
    - >> `defaults.nextAction` , if set, overrides all actions `nextAction` 
    - >> After the first action is triggered, Macrowhisper resolves and executes the chain step-by-step.
    - >> Chain execution starts from the selected action using normal priority:
        1. >>> auto-return
        2. >>> scheduled action
        3. >>> first trigger match
        4. >>> `defaults.activeAction`
    - >> Cycles are blocked (`A -> B -> A`, etc.)
    - >> `defaults.activeAction` and `defaults.nextAction` cannot be the same.
    - >> More than one insert action type in the chain is not allowed, since this uses the user's clipboard for insertion.
    - >> Chain stops immediately if any step fails.
    - >> Clipboard restoration happens only once, after the **last** action (based on last action’s `restoreClipboard` setting).
    - >> `moveTo`/`.delete`  behavior is applied only from the **last** action in the chain.

---

## Text Input Methods

> #### **`simKeypress`** (true/false)

- > **Purpose**: Use keystroke simulation instead of clipboard for text insertion
- > **Default**: `false`
- > **Example**: `true` for character-by-character typing, `false` for clipboard paste
- > **Note**: Keystroke simulation is slower but works in fields that block pasting.

> #### **`noEsc`** (true/false)

- > **Purpose**: Skip pressing the Escape key before actions
- > **Default**: `false`
- > **Example**: `true` to skip ESC, `false` to press ESC first executing action
- > **Note**: ESC helps dismiss Superwhisper's recording window before pasting

---

## Recording Management

> #### **`moveTo`** (String or Special Values)

- > **Purpose**: Move or delete your recording files after processing
- > **Default**: `""` (deactivated)
- > **Values**:
    - >> Existing folder path: `"/Users/yourname/Desktop"`
    - >> **Special Values**:
        - >>> `".none"`: Explicit "do not move"
        - >>> `".delete"`: Deletes after processing

> #### **`history`** (Number or null)

- > **Purpose**: Number of days to keep old recordings before automatic cleanup (performed every 24 hours)
- > **Default**: `null` (keep all recordings)
- > **Values**:
    - >> `null`: Never delete recordings automatically
    - >> `0`: Keep only the most recent recording (delete all others)
    - >> Positive number: Keep recordings from the last N days
- > **Examples**:
    - >> `7` keeps one week of recordings
    - >> `30` keeps one month of recordings
    - >> `0` keeps only the latest recording

---

## Clipboard Management

> #### **`restoreClipboard`** (true/false)

- > **Purpose**: Restore your original clipboard content after actions
- > **Default**: `true`
- > **Example**: `false` to leave the transcribed text on clipboard
- > **Note**: When disabled, the transcription stays on your clipboard for reuse

> #### `clipboardStacking` (true/false)

- > **Purpose:** Allow multiple clipboard captures to be used in the `{{clipboardContext}}` placeholder.
- > **Default:** `false`

#### `clipboardBuffer` (Number)

- **Purpose:** Number of seconds during which clipboard capture for `{{clipboardContext}}`  remains active BEFORE a dictation.
- **Default: `5`** 

> #### `clipboardIgnore` (String)

- > **Purpose**: Pattern to ignore clipboard content from specific applications (for `{{clipboardContext}}` )
- > **Default**: `""` (deactivated)
- > **Example**: `"Arc|Bitwarden|com.bundle.id"`

---

## Notifications and Updates

> #### **`noNoti`** (true/false)

- > **Purpose**: Disable system notifications from Macrowhisper
- > **Default**: `false`
- > **Example**: `true` for silent operation, `false` for notifications
- > **Note**: Macrowhisper will only display notifications when errors appear

> #### **`noUpdates`** (true/false)

- > **Purpose**: Disable automatic update check performed every 24 hours
- > **Default**: `false`
- > **Example**: `true` to skip update checks, `false` to check for updates
- > **Note**: When set to true, you can still manually check for updates via `macrowhisper --check-updates` (or simply use `brew update` & `brew upgrade`)

---

## URL Actions Specific

> #### `openBackground (true/false)`

- > Opens URL in the background, without taking focus away from active app

> #### `openWith (string)`

- > Specific name of app or browser to open URL

---

### Insert Actions Specific

For **insert actions only**, these special `action` **values** provide specific behaviors:

> #### **`.none`**

- > Skips the action entirely
- > Does not simulates Escape
- > Does not restore clipboard
- > Useful for creating an action type that will keep results in the recording window without pasting

> #### **`.autoPaste`**

- > Intelligent pasting that only closes the recording window when paste is successful
- > Simulates Superwhisper's default behavior

> #### **`inputCondition`** (String)

- > **Purpose**: Conditionally applies selected insert options depending on whether execution starts in an input field.
- > **Default**: `""`
- > **Values:** supports pipe-separated tokens:
`restoreClipboard|pressReturn|noEsc|nextAction|moveTo|action|actionDelay|simKeypress`
+ > You can invert any token with `!`:
    - >> `token` means “apply this option only when in an input field”
    - >> `!token` means “apply this option only when outside an input field”
- > **Examples**:

```other
"inputCondition": "restoreClipboard|!pressReturn|moveTo"
```

    + >> **`.autoPaste`** 
        - >>> If `action` is `.autoPaste`, effective behavior is:
            - >>>> action content from `{{swResult}}`
            - >>>> `inputCondition` forced to `!restoreClipboard|!noEsc`
            - >>>> `noEsc=true`
            - >>>> `restoreClipboard=false`
- > **Note**: `inputCondition` is evaluated before `nextAction`, so it can change chaining behavior. Input-field state is sampled once at the first insert step and reused for the entire chain.

# Action Types

Macrowhisper supports several types of actions:

> #### 1. Insert Actions

- > **Purpose**: Paste transcription results to your current application
- > **Special feature**: Only action type that can be set as "active insert"
- > **Use case**: You can create templates to either simply paste your result, activate auto-paste (default behavior), disable pasting, or paste multiple values from Superwhisper's meta.json file at once
- > **Example:** `"action" : "{{swResult}}"`

> #### 2. AppleScript Actions

- > **Purpose**: Run AppleScript commands
- > **Use case**: Trigger Keyboard Maestro macros, system automation
- > **Example:** `"action" : "tell application \"Keyboard Maestro Engine\" to do script \"Sample Macro\" with parameter \"{{swResult}}\""`

> #### 3. Shell Script Actions

- > **Purpose**: Execute shell commands
- > **Use case**: File operations, system commands
- > **Example:** `"action" : "echo \"{{swResult}}\" > ~/Desktop/testFile.txt"`

> #### 4. Shortcut Actions

- > **Purpose**: Run macOS Shortcuts
- > **Use case**: Complex workflows, app integrations
- > **Important**: The action name must match your shortcut name exactly. The value in `action` gets sent to the shortcut as input. It can be left blank.

> #### 5. URL Actions

- > **Purpose**: Open URLs or web-based actions
- > **Use case**: Search queries, web services
- > **Example:** `"action" : "https://www.google.com/search?q={{result}}"`

---

## Adding Actions

The recommended way to add actions is through the command line:

```shell
# Examples of adding different action types
macrowhisper --add-insert "Paste Result"
macrowhisper --add-url "Google"
macrowhisper --add-shell "Save File"
macrowhisper --add-shortcut "Make Note"
macrowhisper --add-as "Save File"
```

Command-line creation automatically fills in default values, then you can customize them in the configuration file.

# Placeholders

All actions support dynamic content through placeholders:

## Basic Placeholders

- **`{{swResult}}`**: Your transcription result (with LLM processing if available)
- **`{{frontApp}}`**: Currently active application

---

## Date Placeholders

- **`{{date:yyyy-MM-dd}}`**: Custom date format (uses Unicode UTS 35 format)
- **`{{date:long}}`**: Built-in long date format
- **`{{date:short}}`**: Built-in short date format

---

## Context Placeholders

(Optionally) provides access to rich context from your system, making actions even more powerful:

- **`{{selectedText}}`**: Gets the currently selected text from your frontmost app. This is captured exactly the moment your dictation begins.
- **`{{clipboardContext}}`**: Grabs the current contents of your clipboard. This is captured either 5 seconds before your dictation, or during your dictation.
- **`{{appContext}}`**: Provides additional context about the active application window (such as window title, application name, and text from currently active input field). Captured exactly on action execution.

*NOTE: These context placeholders use content captured by Macrowhisper, not Superwhisper. This means that they also work on voice-only modes without AI. This is particularly useful if you want to use Macrowhisper actions to send your dictation results to other AI applications.*

---

## Advanced Placeholders

> ### XML Placeholders

**`{{xml:tagname}}`**: Extract content from XML tags in LLM results

XML placeholders work great for automations with Shortcuts or scripts. For example, set up a custom mode in Superwhisper that asks the AI to format your dictation as a note with bullet points. Also ask it to analyze your content and suggest a title, wrapped in XML tags like `<title>Your Title Here</title>`.

With Macrowhisper, you can then use both pieces of information inside an action:

- `{{swResult}}` gets the formatted note content
- `{{xml:title}}` extracts just the title from the XML tags (it also removes it from swResult)

This lets you trigger a single shortcut that creates a note in your app, sending both the note content and the extracted title at once. The shortcut receives everything it needs to create a properly titled note without any manual input.

> ### META Key Placeholders

Any key from Superwhisper's metadata JSON can be used as `{{keyname}}`

---

## Contextual Escaping

Macrowhisper automatically handles proper character escaping based on where your placeholder is used:

- **Shell scripts**: Escapes characters that could break command execution
- **AppleScript**: Escapes quotes and backslashes appropriately
- **Shortcuts**: No escaping (clean text)
- **URLs**: Combined with URL encoding for web safety
- **Insert Actions:** No escaping (clean text)

This means you can focus on your content without worrying about breaking your automations due to special characters in Superwhisper's results.

---

## Special Cases

> ### No Escaping

There are times when you don’t want any escaping on your placeholders—like if you’re sending AppleScript and your text is already formatted just right. For these moments, use the `raw` prefix:

```shell
{{raw:thePlaceholder}}
```

This skips all automatic escaping. You get the text exactly as it is. Want to tweak it further? You can still add regex replacements right inside the placeholder:

```other
{{raw:swResult||\\n\\n||\\n}}
```

---

> ### JSON Escaping

Another option: the `json` prefix. This is handy if you’re using a placeholder inside a JSON or dictionary structure. This is useful for Shortcut actions, for example. Shortcut actions don’t escape placeholders for you, but sometimes you need your value to be JSON-safe. That’s when you’d write:

```other
{{json:thePlaceholder}}
```

For example, if you’re including a result into a JSON string:

```other
"action": "{\"theResult\": \"{{json:swResult}}\"}"
```

Use these prefixes when you want total control over escaping—because sometimes, you know exactly what your automation needs.

# Regex Replacements

You can modify placeholder content using regex (regular expression) find-and-replace patterns. This is particularly useful for cleaning up dictation results or formatting text for specific use cases.

> **You can use regex in two places in Macrowhisper:**

- **Inside placeholders** to transform text (`{{...}}`).
- **Inside triggers** to control when an action runs (`triggerVoice`, `triggerModes`, `triggerApps`).

---

1. > Placeholder Regex Replacements (text cleanup/formatting)

Use this syntax:

```shell
{{placeholder||find_pattern||replacement||find_pattern2||replacement2}}
```

- `||` separates each find/replace pair.
- Replacements run in order (left to right).
- Invalid regex patterns are safely skipped (they won’t crash execution).
- Matching is case-insensitive by default.
- Add `(?-i)` at the start of a pattern to force case-sensitive matching.

---

## Sample Use Cases

**Remove specific words:**

```other
{{swResult||\\b(uh|um|like)\\b||}}
```

---

**Format for specific apps:**

```other
{{swResult||\\n||<br>}}
```

*Converts line breaks to HTML `<br>` tags for web forms or HTML emails.*

---

**Remove unwanted period at the end of a URL action:**

```other
https://letterboxd.com/search/{{result||\\.$||}}
```

---

**Only remove a word if it appears at the end:**

```other
{{result||\s+thanks$||}}
```

This matches only when text **ends** with `thanks`.

---

**Only remove a word if it appears at the start:**

```other
{{result||^please\s+||}}
```

This matches only when text **starts** with `please`.

---

> ## 2) Trigger Regex Behavior (when actions fire)

> ### `triggerVoice` default behavior (important)

Without special syntax, voice patterns are treated as:

    - **Prefix match** (start of transcript)
    - **Case-insensitive**
    - **Literal text** (escaped, not raw regex)

So a plain trigger like `search` means “starts with `search`”.

If matched, Macrowhisper strips that prefix from the dictation result before running the action.

#### `triggerVoice` advanced raw regex with `==...==`

---

### Wrap pattern in `==` to use full raw regex:

```json
"triggerVoice": "==^search\\s+(.+)$=="
```

- This is true regex control.
- Useful for start/end anchors (`^` / `$`), lookaheads, etc.
- Raw regex voice triggers do **not** strip matched text automatically.
- Still case-insensitive by default unless you start with `(?-i)`.

---

### `triggerVoice` Advanced Regex Samples

**Ends-with example (voice trigger):**

```json
"triggerVoice": "==.*\\bsummary$=="
```

Matches phrases that **end** with `summary` (not just start with it).

---

**Exact Match (voice trigger)**

```json
"==^google this\\.?$=="
```

Matches ONLY the exact phrase "Google This". If user dictates more the action will not trigger.

---

#### `triggerModes` and `triggerApps`

    - These already use regex directly.
    - No special `==...==` wrapper is needed.
    - Case-insensitive by default (use `(?-i)` to make case-sensitive).
    - `triggerApps` matches app name or bundle ID.

---

> #### Tips for Non-Technical Users

1. > Start simple with one replacement at a time.
2. > Prefer multiple small replacements over one giant regex.
3. > Test patterns in a text action before using them in critical automations.
4. > Escape special characters when matching literally: `\.` `\(` `\)` `\?`.
5. > Ask AI for patterns using **NSRegularExpression** syntax (used by Macrowhisper).

# Automation Ideas

Macrowhisper gives you incredible flexibility right out of the box. You don't need external automation tools to create powerful workflows, though they can make things even more interesting. Here are some creative ways to use Macrowhisper's features:

## Creative Workflow Ideas

> #### **Website-Specific Behaviors**

> Even though Macrowhisper doesn't detect websites directly, you can combine it with Superwhisper's website auto-detection for modes. For example, set up a Superwhisper mode for ChatGPT or Discord, then create a Macrowhisper action that triggers on that mode. Want auto-return for messaging sites? Set the mode trigger with `"pressReturn" : true`. This gives you website-specific behavior through the mode system.

> **Smart Recording Cleanup**

> URL actions for web searches don't need to stick around in your history. Create actions with `"moveTo" : ".delete"` for Google searches or YouTube queries. You can also set up privacy-focused modes in Superwhisper that automatically delete recordings after processing.

> **Conversation Templates**

> Create insert actions that paste both your original dictation and the AI response. This lets you build conversations in any text editor without needing external macros. Combined with Superwhisper's app context, you get natural back-and-forth conversations entirely within any text editor.

This is my action template for this insert action:

```shell
"action" : "## USER\n{{result}}\n\n## AI\n{{swResult}}\n\n---\n"
```

---

## Using with Automation Apps

For deeper integration with Keyboard Maestro, BetterTouchTool, or Alfred, Raycast, etc., you'll need Macrowhisper's full path:

```shell
# Find the full path
which macrowhisper
```

Use this full path in your commands sent from outside of Terminal. For example:

```shell
/opt/homebrew/bin/macrowhisper --get-icon
```

---

## Key Commands for Automation

These commands open up powerful automation possibilities:

```shell
# Execute an insert action using the last valid result
--exec-action <name>          

# Get the icon of the active insert
--get-icon

# Get the name of the active insert                   
--get-action

# Get the contents of an insert action. 
# To use on dialogs, send to other automation actions, etc.
--get-action <name>

# Clears your active insert
--action

# Sets an active insert
--action <name>

# Schedule any action for next (or active) recording session
# Takes priority over active action and triggers
# No name = cancel scheduled action
 --schedule-action [<name>]
```

# Troubleshooting

## First Steps: Check the Logs

If Macrowhisper isn't behaving as expected, the first thing to check is the log file. All activity and error messages are recorded here, which can help you understand what's happening behind the scenes.

**Log location:** `~/Library/Logs/Macrowhisper/macrowhisper.log`

You can open this file in any text editor to see recent activity and error messages. Look for entries marked with `[ERROR]` or `[WARNING]` that might explain unexpected behavior.

---

## Recording Window Issues

If your results are pasting into the front app, but you’re running into issues with Superwhisper's recording window failing to close. This may happen because your system specs and Superwhisper’s animation timing don’t quite line up. The issue comes from the escape key simulation, which is meant to close the recording window but sometimes clashes with the window’s animation as it appears.

If you experience this, try tweaking the `actionDelay`  setting. This option delays Macrohisper’s result processing by a short amount of time. Start with a delay of 0.1 or 0.05 seconds and see what works best for your setup.

*One important note: it's also importat that you've set the escape key as the close key for the recording window in Superwhisper’s configuration.*

---

## Clipboard Issues

If you notice your clipboard pastes the wrong text—or keeps pasting an older result instead of the expected one—there’s a good chance it’s a sync issue between Macrowhisper and Superwhisper. Here are a few things to try:

**1. Check Superwhisper Clipboard Settings**

First, make sure clipboard restoration is turned off in Superwhisper (just like you did during setup). If clipboard restoration is enabled, you may run into issues where the clipboard reverts to an earlier state.

**2. Adjust the Action Delay**

Clipboard conflicts usually happen if Macrowhisper and Superwhisper both try to use the clipboard at the exact same time. Try increasing the `actionDelay` by 0.05, or even 0.1 seconds. This small delay gives each app enough breathing room and should clear up paste mix-ups.

**3. Check Your Clipboard Manager**

If you've got a clipboard manager running—like Alfred—double-check its settings. For Alfred, it's best to turn off the “clipboard merging” option. You’ll find this setting in Alfred’s clipboard manager preferences.

This is important because both Superwhisper and Macrowhisper might send their results to the clipboard nearly at the same time, which can cause confusion if your clipboard manager tries to combine them.

---

## Advanced Debugging: Run with Verbose Logging

If the issue is significant and prevents you from using the application normally, you can also get real-time detailed logging by running Macrowhisper directly in Terminal:

1. **Stop the background service** (if running):

```shell
macrowhisper --uninstall-service
```

1. **Run directly with verbose logging:**

```shell
macrowhisper --verbose
```

This will show you detailed, real-time logging in your Terminal window. Since most users install Macrowhisper through Homebrew, you can simply use the `macrowhisper` command directly—no need to specify the full path to the binary.

When running with `--verbose`, try to replicate the issue you're experiencing. The detailed logs will show you exactly what the application is doing and where problems might be occurring. This information is incredibly helpful when reporting issues or troubleshooting complex problems.

---

## Permission Issues

If Macrowhisper won't activate, nothing is pasting, or the app seems completely unresponsive, this is most likely due to **accessibility permissions** that need to be properly configured.

#### What to Try:

1. **Re-grant permissions:** Go to **System Preferences > Security & Privacy > Privacy > Accessibility**
2. **Remove Macrowhisper** from the list if it's already there
3. **Stop the app completely:**

```Bash
macrowhisper --stop-service
```

1. **Restart the service:**

```Bash
macrowhisper --start-service
```

When you restart, macOS should prompt you again for accessibility permissions. **Grant these permissions** when the dialog appears.

---

## Why These Permissions Are Needed

Macrowhisper has been signed and notarized by Apple, so it's completely safe to grant these permissions. The application needs accessibility access to:

- Detect when you're typing in text fields
- Simulate keystrokes for text insertion
- Identify the currently active application

Without these permissions, Macrowhisper simply cannot function properly. These permissions are essential for the automation features to work as intended.

---

> ### Still Having Issues?

> If you're still experiencing problems after checking logs and permissions:

1. > **Collect detailed logs** by running with `--verbose` and replicating the issue
2. > **Note the specific behavior** you're seeing versus what the documentation describes
3. > **Check if it's consistent** - does it happen every time or only in certain situations?

> Open an issue [over at Github](https://github.com/ognistik/macrowhisper/issues) and I'll do my best to help. Having this information makes it much easier to identify and resolve issues quickly.

# Complete Uninstall

If you need to completely remove Macrowhisper from your system, follow these steps to ensure all components are properly removed:

> ## What Gets Removed

> Macrowhisper consists of three main components:

- > **The service** (background process)

    >> *Installed over at `~/Library/LaunchAgents/com.aft.macrowhisper.plist`* 

- > **The binary** (the application itself)

    >> *Installed at brew path or `/usr/local/bin/macrowhisper`* 

- > **Configuration files** (your settings and preferences)

    >> *By default at `~/.config/macrowhisper`* 

---

1. **Stop/remove the service, then uninstall the application:**

#### If Installed with Homebrew

```shell
# Uninstall Service
macrowhisper --uninstall-service

# Remove with Brew
brew uninstall macrowhisper
```

#### If Installed with Script

```shell
# Uninstall Service
macrowhisper --uninstall-service

# Remove executable and potential schema file
MACROWHISPER_PATH=$(which macrowhisper 2>/dev/null)
if [ -n "$MACROWHISPER_PATH" ]; then
    sudo rm -f "$MACROWHISPER_PATH" "$(dirname "$MACROWHISPER_PATH")/macrowhisper-schema.json"
fi
```

1. **Remove configuration files (from default path):**

```shell
rm -rf ~/.config/macrowhisper
```