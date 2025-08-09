## Macrowhisper for Alfred

This Alfred workflow lets you run your Macrowhisper actions directly, using your voice input from Superwhisper. It’s built to complement the Macrowhisper's CLI and Superwhisper, so you can schedule actions, execute with the last result, or set an action as active so that future dictations continue to run through it.

### What you can do
- **Schedule & Dictate**: Schedule an action in Macrowhisper and immediately start dictation with Superwhisper, sending the new transcription to that action.
- **Schedule Only**: Schedule an action now; start dictation yourself when you’re ready (scheduled actions have a default timeout setting of 5 seconds in Macrowhisper). This and the above may be the most useful.
- **Set as Active**: Make an action the current active action. Keep dictating over time and each new transcription will be sent to that action. You don’t have to start dictation immediately (but you can).
- **Set as Active & Dictate**: Make an action active and kick off dictation right away. An active action will not deactivate itself until you do it through the CLI, this workflow, or directly in Macrowhisper's configuration file.
- **Execute Action**: Run the selected action using the last valid transcription result.

You can also trigger an optional update to the Keyboard Maestro macro that shows your current active action and Superwhisper’s mode in your menu bar.

### Requirements
- **Macrowhisper CLI**: Installed and available on your PATH (or at a known absolute path). See the [Macrowhisper docs](https://by.afadingthought.com/macrowhisper) for installation.
- **Superwhisper**: This workflow uses Superwhisper’s URL scheme to (optionally) start recording and set change mode.
- **Config file**: Macrowhisper's configuration JSON file defining your actions.
  
### Using the list and search
- Type `@` to browse by category (URL, Shortcut, Insert, AppleScript, Shell). Keep typing to fuzzy-match category names and press Tab/Return to autocomplete (e.g., `@URL `).
- After selecting a category (or if you don’t use `@`), type to fuzzy-search action names.
- Each item’s subtitle shows the available actions for different keys:

### Alfred Configuration
Set these in the workflow’s configuration:

- **Configuration Path**: Absolute path to your Macrowhisper configuration JSON.
- **Macrowhisper's Actions**: Pick your own actions in the dropdowns. You choose what each item does when you trigger it, with or without modifier keys.
- **Dictation Mode** (optional): Superwhisper's “mode key” to use when starting or preparing to dictate. If you leave this blank, the workflow will NOT change Superwhisper’s mode.
  - To get the mode key: [open your Superwhisper’s mode JSON](https://superwhisper.com/docs/modes/switching-modes#deep-links) and copy the `key` for the mode you want. 
- **KM Macro** (optional): Toggle this to trigger the "MW Mbar" Keyboard Maestro macro after setting an action active. This macro shows the active action and Superwhisper mode in your menu bar. You can download it from the [Macrowhisper's documentation](https://by.afadingthought.com/macrowhisper). It’s optional and not required for the workflow to function.

### Superwhisper modes and dictation
- When you choose an option that starts or prepares dictation, the workflow can set Superwhisper’s mode using the mode key.
- If `dictateMode` is set, the workflow will call Superwhisper to switch modes before you dictate (when choosing that option). Be aware it will not auto switch back to your previous Superwhisper mode after the action runs. A voice-only mode is suggested for more versatility.
- If `dictateMode` is left blank, the workflow will NOT change Superwhisper’s mode. This is useful if you prefer to keep your current mode or handle mode switching yourself.

### Troubleshooting
- “macrowhisper not found”: Make sure the Macrowhisper CLI is installed and on your PATH. The workflow will also try to resolve it with `which macrowhisper`.
- Superwhisper doesn’t start or change mode: Confirm Superwhisper is installed and that your `dictateMode` key is correct. Leaving `dictateMode` blank will intentionally skip changing modes.
- No actions listed: Check that `configPath` points to a valid configuration JSON and that the file is readable.

### Automate Outside This Workflow (optional)
Want to automate your Macrowhisper actions outside of this workflow? This workflow is a thin wrapper around the Macrowhisper CLI plus Superwhisper’s URL scheme. You can reproduce the same behavior in Terminal, Keyboard Maestro, Raycast, Shortcuts, or any other automation tool by running the same commands.

- Replace `<Action Name>` with the exact action name from your config
- When using in automation apps, you may need to use Macrowhisper's absolute path. Find it with `which macrowhisper`
- Replace `<your_mode_key>` with your Superwhisper mode key if you want to switch modes (optional)

Below are the exact sequences the workflow runs for each option:

1) Schedule & Dictate

```bash
macrowhisper --schedule-action "<Action Name>"
open -g "superwhisper://record"
# optional: switch Superwhisper mode (leave out if you don’t want to change modes)
open -g "superwhisper://mode?key=<your_mode_key>"
```

2) Schedule Only

```bash
macrowhisper --schedule-action "<Action Name>"
# optional: switch Superwhisper mode
open -g "superwhisper://mode?key=<your_mode_key>"
```

3) Set as Active

```bash
macrowhisper --action "<Action Name>"
# optional: switch Superwhisper mode
open -g "superwhisper://mode?key=<your_mode_key>"
# optional: trigger Keyboard Maestro menu bar macro
osascript -e 'tell application "Keyboard Maestro Engine" to do script "MW MBar"'
```

4) Set as Active & Dictate

```bash
macrowhisper --action "<Action Name>"
open -g "superwhisper://record"
# optional: switch Superwhisper mode
open -g "superwhisper://mode?key=<your_mode_key>"
# optional: trigger Keyboard Maestro menu bar macro
osascript -e 'tell application "Keyboard Maestro Engine" to do script "MW MBar"'
```

5) Execute Action (using last valid transcription result)

```bash
macrowhisper --exec-action "<Action Name>"
```

Tips
- Assign any of the above to a hotkey or trigger in your automation app
- Quote action names if they contain spaces