## Macrowhisper Alfred – Codebase Map

This Swift CLI runs inside an Alfred Script Filter. It reads a Macrowhisper configuration JSON (provided via the `configPath` Alfred variable), aggregates actions across categories, supports fuzzy filtering and `@` category filtering, and returns Alfred Script Filter JSON.

### High-level Flow
- `Macrowhisper Alfred/main.swift`: Entry point. Reads `configPath` and the user argument, loads config, aggregates actions, handles `@` type filtering, fuzzy-filters action names, and emits Script Filter JSON.
- On selection (action phase): If invoked again with selection variables present (e.g., via a downstream Run Script node), it executes side-effects based on the pressed modifier label (schedule, set active, dictate, etc.).
- `Workflow/*`: Helpers for Alfred integration (stdout/stderr JSON, env variables, return/quit/info, response model encoding).
- `Workflow/Alfred/*`: Alfred Script Filter JSON primitives (`Item`, `Modifier`, `Argument`, `Icon`, `Text`) and the `Inflatable` helper.
- `Models/*`: Macrowhisper config models and unification of different action types into one list.
- `Utilities/*`: Fuzzy search, config loading, and process execution helpers.
- `Extensions/*`: Small shared extensions.

### Entry Point
- `main.swift`
  - Reads `configPath` from Alfred env.
  - Interprets user input for two modes:
    - Category selection while typing immediately after `@` (no space): shows filtered list of categories with autocomplete (e.g., `@u` → `URL`).
    - After a space (e.g., `@url search`), filters actions within that category using fuzzy matching on action names.
  - Builds items with:
    - Title: `Name (Type)`
    - Subtitle: `⏎ {pressReturn} • ⌘ {pressCmd} • ⌥ {pressOpt} • ⌘⌥ {pressCmdOpt} • ⌃ {pressCtrl}`
    - Copy: action content string
    - Large Type: action content string
    - Quick Look: `configPath`
    - Modifiers enabled: none (return), ⌘, ⌥, ⌘⌥, ⌃ — each sets `pressMods` and `theAction`
    - All other modifiers disabled
  - Selection execution path:
    - If the app is invoked with `pressMods` and `theAction` in the environment, it maps the pressed modifier to its configured label (`pressReturn`, `pressCmd`, `pressOpt`, `pressCmdOpt`, `pressCtrl`) and runs the corresponding commands:
      - Schedule & Dictate: `macrowhisper --schedule-action "$theAction"`, `open -g superwhisper://record`, `open -g superwhisper://mode?key=$dictateMode`
      - Schedule Only: `macrowhisper --schedule-action "$theAction"`, `open -g superwhisper://mode?key=$dictateMode`
      - Set as Active: `macrowhisper --action "$theAction"`, `open -g superwhisper://mode?key=$dictateMode` (+ Keyboard Maestro macro if enabled)
      - Set as Active & Dictate: `macrowhisper --action "$theAction"`, `open -g superwhisper://record`, `open -g superwhisper://mode?key=$dictateMode` (+ Keyboard Maestro macro if enabled)
      - Execute Action: `macrowhisper --exec-action "$theAction"`
    - Uses `which macrowhisper` to resolve the absolute path (fallback to `macrowhisper`).
    - Optional Keyboard Maestro step: `osascript -e 'tell application "Keyboard Maestro Engine" to do script "MW MBar"'` if `kmMacro` is truthy.

### Workflow Layer (Alfred Integration)
- `Workflow/Workflow.swift`: Stdout/stderr handling, `return`/`quit`/`info` helpers.
- `Workflow/Workflow+Environment.swift`: Access to Alfred env variables and workflow identifiers.
- `Workflow/ScriptFilter+Response.swift`: `Response` model with JSON encoding helpers.

### Alfred Script Filter Models
- `Workflow/Alfred/Protocols.swift`: `Inflatable` protocol for `.with { }` population.
- `Workflow/Alfred/ScriptFilter+Item.swift`: `Item`, `Modifier`, and `mods` wrapper encoding (`cmd+alt`, etc.), plus variable helpers.
- `Workflow/Alfred/ScriptFilter+Argument.swift`: `Argument` supporting string/array/nested and validation for variables.
- `Workflow/Alfred/ScriptFilter+Text.swift`: Copy and Large Type payloads.
- `Workflow/Alfred/ScriptFilter+Icon.swift`: Icon primitive and convenience constants.

### Models
- `Models/MacrowhisperConfig.swift`:
  - Schema for Macrowhisper config sections (`defaults`, `inserts`, `scriptsAS`, `scriptsShell`, `shortcuts`, `urls`).
  - `ActionKind`: URL, Shortcut, Insert, AppleScript, Shell.
  - `UnifiedAction`: normalized action representation.
  - `allActions()`: flattens all sections to `[UnifiedAction]`.

### Utilities
- `Utilities/ConfigLoader.swift`: Loads and decodes the config from `configPath`.
- `Utilities/FuzzySearch.swift`: Generic fuzzy matching used for both categories and action names.
 - `Utilities/ProcessRunner.swift`: Minimal process runner and `which` helper for resolving executables.

### Extensions
- `Extensions/String+Extensions.swift`: `trimmed`, `expandingTildeInPathIfNeeded`.

### Alfred Variables (input)
- `configPath`: Absolute path to the configuration JSON.
- `pressReturn`, `pressCmd`, `pressOpt`, `pressCmdOpt`, `pressCtrl`: Labels interpolated into subtitles and per-modifier subtitles.
 - `dictateMode`: Mode key used by Superwhisper URLs.
 - `kmMacro`: Enables Keyboard Maestro macro when truthy (accepted: `true`, `1`, `yes`, `y`, case-insensitive).
 - `debugKM` (optional): If truthy, logs command exit statuses to Alfred’s debugger.

### Alfred Variables (output on selection)
- `pressMods`: One of `noMods`, `cmd`, `opt`, `cmdOpt`, `ctrl`.
- `theAction`: The selected action name.

### Workflow wiring
- Script Filter → Run Script (or equivalent) that invokes the binary again (no args needed). This second invocation carries selection variables (`pressMods`, `theAction`, plus any other env vars) so the app can execute the side-effect commands.

### UX Notes
 - Typing `@` shows categories; fuzzy narrows them inline (`@u` → `URL`). Pressing Tab/Return autocompletes to `@URL `, after which the full category list is shown immediately and fuzzy search applies to action names as you type.
- Supports both `@url` and `@ url` forms; no-space is preferred.


