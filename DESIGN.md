---
name: Macrowhisper Configuration Editor
description: A quiet local control room for dependable Superwhisper automation.
colors:
  background: "#f5f5f5"
  surface: "#ffffff"
  surface-muted: "#ebebeb"
  surface-raised: "#ffffff"
  surface-selected: "#dedede"
  text: "#111111"
  text-soft: "#4a4a4a"
  text-muted: "#666666"
  border: "#d2d2d2"
  border-strong: "#aaaaaa"
  accent: "#111111"
  accent-inverse: "#ffffff"
  focus: "#111111"
  focus-soft: "rgba(17, 17, 17, 0.16)"
  success: "#2d6d4d"
  success-soft: "#e9f4ed"
  warning: "#895d16"
  warning-soft: "#fff7e7"
  danger: "#a33c39"
  danger-soft: "#fff0ef"
  dark-background: "#111111"
  dark-surface: "#1a1a1a"
  dark-surface-muted: "#242424"
  dark-surface-raised: "#202020"
  dark-surface-selected: "#303030"
  dark-text: "#f5f5f5"
  dark-text-soft: "#c7c7c7"
  dark-text-muted: "#a5a5a5"
  dark-border: "#3e3e3e"
  dark-border-strong: "#575757"
  dark-accent: "#f2f2f2"
  dark-accent-inverse: "#111111"
  dark-focus: "#f5f5f5"
  dark-focus-soft: "rgba(245, 245, 245, 0.2)"
  dark-success: "#82c39a"
  dark-success-soft: "#1e3427"
  dark-warning: "#e8bd6a"
  dark-warning-soft: "#3a2f1b"
  dark-danger: "#f09b95"
  dark-danger-soft: "#40201f"
typography:
  body:
    fontFamily: "-apple-system, BlinkMacSystemFont, \"SF Pro Text\", \"Helvetica Neue\", Helvetica, Arial, sans-serif"
    fontSize: "14px"
    fontWeight: 400
    lineHeight: 1.45
  title:
    fontFamily: "-apple-system, BlinkMacSystemFont, \"SF Pro Text\", \"Helvetica Neue\", Helvetica, Arial, sans-serif"
    fontSize: "22px"
    fontWeight: 700
    lineHeight: 1.12
    letterSpacing: "-0.035em"
  section-title:
    fontFamily: "-apple-system, BlinkMacSystemFont, \"SF Pro Text\", \"Helvetica Neue\", Helvetica, Arial, sans-serif"
    fontSize: "15px"
    fontWeight: 700
  label:
    fontFamily: "-apple-system, BlinkMacSystemFont, \"SF Pro Text\", \"Helvetica Neue\", Helvetica, Arial, sans-serif"
    fontSize: "13px"
    fontWeight: 650
    lineHeight: 1.4
  mono:
    fontFamily: "ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, \"Liberation Mono\", monospace"
    fontSize: "13px"
rounded:
  sm: "4px"
  control: "6px"
  item: "7px"
  panel: "8px"
  modal: "10px"
  mark: "12px"
spacing:
  hairline: "1px"
  xs: "4px"
  sm: "8px"
  md: "12px"
  lg: "20px"
  xl: "30px"
  page-inline: "38px"
  section: "44px"
components:
  button-primary:
    backgroundColor: "{colors.accent}"
    textColor: "{colors.accent-inverse}"
    typography: "{typography.label}"
    rounded: "{rounded.control}"
    padding: "0 12px"
    height: "36px"
  button-quiet:
    backgroundColor: "{colors.surface}"
    textColor: "{colors.text-soft}"
    typography: "{typography.label}"
    rounded: "{rounded.control}"
    padding: "0 10px"
    height: "36px"
  button-danger:
    backgroundColor: "transparent"
    textColor: "{colors.danger}"
    typography: "{typography.label}"
    rounded: "{rounded.control}"
    padding: "0 10px"
    height: "36px"
  text-field:
    backgroundColor: "{colors.surface}"
    textColor: "{colors.text}"
    typography: "{typography.body}"
    rounded: "{rounded.control}"
    padding: "0 10px"
    height: "36px"
  nav-item:
    backgroundColor: "{colors.surface}"
    textColor: "{colors.text-soft}"
    typography: "{typography.label}"
    rounded: "{rounded.item}"
    padding: "0 10px"
    height: "36px"
  action-list-item:
    backgroundColor: "transparent"
    textColor: "{colors.text}"
    typography: "{typography.label}"
    rounded: "{rounded.item}"
    padding: "9px 7px"
  source-pill:
    backgroundColor: "{colors.surface-muted}"
    textColor: "{colors.text-soft}"
    typography: "{typography.label}"
    rounded: "{rounded.sm}"
    padding: "2px 6px"
    height: "19px"
  source-pill-invalid:
    backgroundColor: "{colors.danger-soft}"
    textColor: "{colors.danger}"
    typography: "{typography.label}"
    rounded: "{rounded.sm}"
    padding: "2px 6px"
    height: "19px"
  editor-status-control:
    backgroundColor: "transparent"
    textColor: "{colors.text}"
    typography: "{typography.label}"
    rounded: "{rounded.item}"
    padding: "0 9px"
  disclosure:
    backgroundColor: "transparent"
    textColor: "{colors.text}"
    typography: "{typography.label}"
    padding: "8px 1px"
    height: "58px"
  payload-editor:
    backgroundColor: "{colors.surface}"
    textColor: "{colors.text}"
    typography: "{typography.body}"
    rounded: "{rounded.panel}"
    padding: "0"
---

# Design System: Macrowhisper Configuration Editor

## Overview

**Creative North Star: "The Quiet Control Room"**

This is an operate-mode interface for a local configuration editor. It should feel like a calm control room: dependable, legible, and ready for a precise adjustment without demanding attention from the work around it. Graphite, white, and gray surfaces establish hierarchy through tone, borders, and spacing rather than decoration.

The system is compact but not cramped. Familiar controls carry the interaction, while progressive disclosure keeps conditions, chaining, placeholders, and exceptional syntax recovery available without making the first useful path feel technical. Conditions stay plain-language in normal use; exact raw values appear only when recovery requires them. Light and dark appearances use the same neutral roles; green, amber, and red are reserved for connection, save, warning, and error meaning.

**Key Characteristics:**
- Quiet graphite-and-paper surfaces with no colored cast.
- A clear navigation rail, top context bar, and focused editing workspace.
- State made explicit with text, icons, and restrained semantic color.
- Dense enough for configuration work, with a single-surface mobile path.

## Colors

The palette is deliberately neutral: black, graphite, gray, and white do the structural work, while semantic colors appear only when the interface must communicate status or risk. The `dark-*` tokens are the corresponding dark-appearance values for the same CSS variable roles.

### Primary

- **Graphite Accent** (`colors.accent`): the primary action and focus color in the light appearance; it reverses to `colors.dark-accent` in the dark appearance.

### Neutral

- **Quiet Gray** (`colors.background`): the main light-appearance canvas behind editing surfaces.
- **Paper Surface** (`colors.surface`): controls and raised content that need a clean reading plane.
- **Muted Gray** (`colors.surface-muted`): supporting bands, search fields, source pills, and connection context.
- **Selected Gray** (`colors.surface-selected`): active navigation and list selection.
- **Graphite Ink** (`colors.text`): primary headings and readable control text.
- **Soft Ink** (`colors.text-soft`): supporting copy and secondary controls.
- **Muted Ink** (`colors.text-muted`): descriptions, labels, metadata, and low-priority hints.
- **Hairline Gray** (`colors.border`): the default one-pixel divider and control stroke.
- **Strong Hairline** (`colors.border-strong`): field boundaries and higher-contrast edges.

### Semantic status

- **Success Green** (`colors.success` / `colors.success-soft`): connected and saved states.
- **Warning Amber** (`colors.warning` / `colors.warning-soft`): saving, unsaved, fallback, and working-offline states.
- **Repair Red** (`colors.danger` / `colors.danger-soft`): invalid configuration, failed writes, and destructive actions.

**The Quiet Surface Rule.** Keep surfaces, navigation, and controls inside the graphite/white/gray family. Semantic hues are for status and risk, never for decoration.

**The State Must Speak Rule.** Never make a status depend on color alone: pair semantic color with a label, icon, or explicit copy.

## Typography

**Display Font:** none; page and action titles use the system sans stack.
**Body Font:** `-apple-system, BlinkMacSystemFont, "SF Pro Text", "Helvetica Neue", Helvetica, Arial, sans-serif`
**Label/Mono Font:** system sans for labels; `ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, "Liberation Mono", monospace` for paths and serialized values.

**Character:** The system sans keeps the editor native-feeling and familiar on macOS. A restrained monospace face marks configuration paths, code, and raw expressions without turning the whole interface into a developer console.

### Hierarchy

- **Title** (700, 22px, 1.12 line-height, -0.035em tracking): page titles and the selected action title.
- **Section title** (700, 15px): disclosure headings and settings-section headings.
- **Body** (400, 14px, 1.45 line-height): explanatory copy and normal control text.
- **Label** (650, 13px, 1.4 line-height): field labels, buttons, metadata, and navigation copy.
- **Mono** (400, 13px): configuration paths, values, placeholders, and generated expressions.

**The Utility Type Rule.** Use system sans for prose and controls; reserve monospace for paths, serialized values, and expressions. There is no decorative display face.

## Layout

The desktop shell is a sticky contextual left rail (`232px`) beside a flexible main panel. The top context bar is sticky and `60px` tall. Defaults and action editors use one centered reading lane capped at `940px`, with a `12px` gap between card/disclosure sections and a fixed `280px` to `320px` control column where a two-column setting needs one. The rail begins with Defaults and the five action groups; choosing a group replaces those section links with that group's searchable action list and a clear `All sections` return control. Browsing a group changes only the rail. The main panel keeps its current Defaults or action editor until the user selects a concrete action, so the editor never pays for a second permanent sidebar. General screen content is capped at `1240px` with `38px` inline breathing room.

The layout becomes less dense in measured steps: Defaults keep their single reading order at every width and stack each field below `780px`; the single rail narrows below `1050px`; below `780px` it becomes a modal drawer. Opening a group in the drawer reveals its action list while preserving the main panel, and selecting an action closes the drawer onto that editor. Inline padding becomes `15px` on mobile, and controls/popovers wrap again below `430px`. Native `details` sections keep advanced settings behind progressive disclosure. Defaults starts as a fully collapsed overview whenever the user enters it; disclosure state is temporary and is not restored from browser storage.

The spacing rhythm is built from one-pixel dividers, compact `6px` controls, `8px` item/panel edges, `12px` local padding, and larger `20px`/`30px`/`44px` section intervals. Text and metadata remain readable when panes narrow or content wraps.

## Elevation & Depth

Depth is mostly tonal and structural. Resting rows and settings are flat, separated by one-pixel borders and muted surface changes. The payload boundary has only a hairline lift; popovers, drawers, and dialogs use the shared ambient shadow so they can sit above the editing plane. Focus is communicated by a high-contrast outline/ring rather than a glow.

### Shadow Vocabulary

- **Popover / dialog ambient:** light and dark variants of the shared `shadow-popover` token for menus, mobile navigation, and modal surfaces.
- **Payload hairline:** the barely lifted `0 1px 1px` treatment on the payload boundary at rest.
- **Focus ring:** a three-pixel ring appears when a control or payload boundary receives focus.

**The Flat Resting Rule.** Keep ordinary navigation, list items, fields, and settings flat. Reserve shadows for transient layers or the payload boundary's barely perceptible separation.

## Shapes

The form language is gently squared and functional. Controls use `6px` corners; list and navigation items use `7px`; panels and payload boundaries use `8px`; Defaults accordion surfaces and dialogs use `10px`; compact marks use `12px`. Source/status pills use a small `4px` corner, while status dots are circular. Every recurring edge is a one-pixel border or an explicit focus outline; there are no gradients or ornamental silhouettes.

## Components

### Buttons

Buttons are direct and compact, with monochrome fills or strokes that keep attention on the configuration task.

- **Shape:** gently squared corners (`6px`), `36px` minimum height; compact actions reduce to `31px`.
- **Primary:** graphite accent fill, inverse text, `0 12px` horizontal padding. Used for New Insert, Create Insert, and other committing actions.
- **Quiet / toolbar / back:** surface background, one-pixel border, soft ink. Hover shifts to a stronger border and muted surface; toolbar controls may begin borderless and gain the edge on hover.
- **Danger:** transparent red-edged action for ordinary destructive affordances; the filled variant is reserved for the final delete confirmation.
- **Hover / focus / active:** primary hover reduces opacity; quiet hover increases contrast; all buttons use a two-pixel focus outline with a two-pixel offset; active buttons move down one pixel.

### Chips

- **Source pills:** small neutral badges (`4px` radius, `2px 6px` padding) identify Custom override, Inherits Defaults, or Built-in template. Invalid/repair state alone uses the danger colors.
- **Count chips:** quiet metadata uses the same neutral surfaces and muted text, never a decorative accent. Raw configuration revision metadata belongs only in copyable troubleshooting diagnostics, never primary chrome.

### Cards / Containers

- **Editor status control:** a compact bottom-rail row stays quiet while connected and changes text plus semantic tone for saving, failure, fallback, or disconnection. Its transient popover shows only the configuration filename, bounded Copy/Reveal actions, and Appearance in the healthy state. The full path remains available by tooltip and copy action. Degraded states add an explanation and Copy diagnostics; raw schema and revision metadata never compete with routine controls.
- **Create panel / modal:** raised or muted surface with a one-pixel edge and `8px`/`10px` radius; modals add the shared overlay shadow and keep actions aligned at the end.
- **Action list item:** flat at rest, muted on hover, selected gray with a one-pixel border; a small bordered icon box anchors the row without competing with its name.
- **Action overview:** one bordered surface consolidates the action title, source, duplicate/delete controls, editable name, and a compact effective-behavior summary. It replaces a detached action toolbar plus a separate Identity section.
- **Payload boundary:** clean surface with an eight-pixel radius, a toolbar/footer divider, and the focus ring when editing.

### Inputs / Fields

Fields are familiar native controls: `36px` inputs/selects, one-pixel strong hairline borders, six-pixel corners, and surface backgrounds. Cross-action references use a searchable listbox with predictable exact, prefix, then substring matching; each result exposes its type and the picker preserves complete keyboard operation. Textareas use `11px 12px` padding and a `1.55` line-height. Hover increases border contrast; focus uses the shared two-pixel outline, and a focused payload boundary adds a three-pixel ring. Units, reset links, and field state stay adjacent to the control rather than being hidden in tooltips.

### Navigation

The left rail is sticky and quiet, with uppercase group labels, 16px line icons, 36px navigation rows, neutral selected-state fill, and the compact editor-status control at its base. Defaults is a direct destination: selecting it changes the main panel. Action-group rows are collection browsers: selecting one swaps the rail to that group's searchable list without changing the main panel, and only selecting a concrete action navigates the editor. The contextual list keeps `All sections` at its top and uses the same rail rather than adding a second pane. The top bar breadcrumb always describes the main panel—not the collection being browsed—and the development-only preview selector does not expose the internal revision number as a user task. Fixture-backed builds always show a neutral Preview mode notice, use preview-qualified update acknowledgements, and identify storage as in-memory sample data. They never borrow Connected or Saved language from the canonical live editor. At mobile width the rail becomes a modal drawer with a close control and focus containment; selecting an action closes the drawer onto the editor. Interactive targets grow to at least `44px` at the mobile breakpoint without changing the compact desktop density.

### Disclosure Rows

Native `details`/`summary` rows keep Insertion behavior, Conditions, Triggers, Chaining, and other settings available but out of the first-run path. Defaults opens one section at a time in a single centered accordion. Inserts applies the same one-open-at-a-time rule across placeholder review and its four action disclosures, and resets the set when a different action opens. Each quiet, flat, one-pixel-bordered section surface uses spacing instead of repeated full-width rules to establish hierarchy: its collapsed header shows only the title and effective-state summary, then reveals the explanatory copy and fields when opened. Long or conceptually mixed sections use lightweight internal headings, descriptions, spacing, and at most a hairline separator—never nested cards or accordions—to group decisions by consequence. Root values remain visible when they can be inherited by action-level overrides or used by another entry point, even if a neighboring default toggle currently disables the common path; copy explains the broader scope instead of using artificial disclosure. A native `Built-in value` group identifies only the value Macrowhisper ships with for that particular root setting; action references preserve the same distinction in their searchable picker, and an integrated source pill appears inside the closed control while the built-in value is active. Eligible text and numeric root fields with an unambiguous shipped fallback expose `Use built-in` only until restoration succeeds. Default descriptions use a protected reading measure so long copy wraps before entering the trailing utility rail's visual territory. Transient status, recovery controls, and this persistent reset action occupy that stable, right-aligned rail beside the field label; the rail is optically aligned with a single desktop control, shifts to the lower input baseline only while a custom two-control editor is open, and remains visually empty when idle so routine state changes never resize the row. Revert discards the local draft without triggering a blur save. Clearing an ordinary numeric Default saves the built-in state, while explicit zero remains distinct and History retains its `Keep forever` meaning with a visible `days` unit for numeric values. The Defaults body reveal and chevron rotation share a restrained `180ms` transition and respect reduced-motion preferences. Successful live-save acknowledgement clears after roughly two seconds, while preview updates use equally brief preview-qualified copy and errors remain until resolved; neither save activity nor error recovery copy is folded into the effective-behavior summary. Action disclosures show configured exceptions first; empty sections offer a single Add control. Conditions are the exception-aware version of that pattern: an empty inset state says `Same behavior everywhere`, while Add condition offers Payload plus eligible settings explicitly configured by the action. Pending rows ask where the payload should run or the setting should apply; saved Payload rows say that it `Runs only` in the selected context and that other settings still apply, while saved setting rows name their selected context and Defaults behavior elsewhere. An unmet setting rule uses Defaults, and an unmet Payload rule skips the payload. Condition selectors and both Add controls share a stable right-aligned desktop control rail, then stack at mobile widths. Saved rules for no-longer-configured settings stay visible with a recovery route, while unusual expressions keep their exact bytes behind an exceptional repair action rather than a permanent raw editor. Triggers use a deliberately narrower configured-value rail with a separate utility rail for removing a trigger type, so short values do not stretch across the panel while phrases and regular expressions retain useful room. Voice rules form one ordered list: phrase rows keep Beginning/End visible because placement changes their primary meaning, while regex rows carry a quiet `Regex` badge and omit placement. Explicit Add phrase and Add regular expression actions support heterogeneous saved rules without a global mode switch or unsafe conversion. Phrase and non-voice rows keep exception state beside removal in the contextual menu; regex rows keep that menu for removal only. An excluded saved value retains a quiet `Except` badge inside its value control, so exceptional state remains visible without forcing every normal row to carry another decision. The Add trigger choice aligns to the same right-side control rail and width as Trigger logic. Trigger logic names the built-in OR behavior as `Any type can match (default)` rather than implying inheritance from Defaults; its full-width choice is optically centered with its copy while idle, and save or recovery feedback appears below only while present so routine rows remain compact. Harmless empty alternatives are normalized only after an intentional edit; blank local scaffolding disappears when Triggers closes, while genuinely unreadable expressions keep their exact bytes behind a compact remove-or-documentation recovery state, never routine raw syntax. Built-in payload modes retain stored conditions but place protected template behavior in control. Each row exposes its title, consequence, and useful state summary before it opens; the chevron rotates as an orientation cue.

### Payload Editor

The payload editor is the signature interaction. One plain-language native control chooses Auto-paste dictation, Do nothing, or Insert custom text; serialized sentinels never appear in the interface. Custom text opens a bordered editing boundary with a compact categorized placeholder palette, raw text area, stable occurrence-review row, and character/state footer. Moving from non-empty Custom text to a built-in mode retains the exact text in tab-scoped editing state and exposes an explicit Restore custom text action; this recovery follows the action through navigation and rename but is intentionally not written into `macrowhisper.json` or browser-local storage. Built-in modes replace the editor with a compact explanation of their effective behavior and retain stored conditions without presenting them as active controls. The palette is a linear grouped chooser: each full-width row keeps its stable name and concise purpose together in a clear hierarchy, while insertion syntax remains available after the choice rather than competing inside the menu. Pointer hover and keyboard focus receive equally legible feedback without sharing focus state; keyboard navigation takes visual precedence until the pointer moves again, keeping the active row unambiguous. Either input method can complete discovery and insertion without switching to the other. Common Date formats are direct insertion choices. Caret movement and placeholder insertion never expand the inspector: the count updates in place, then the user deliberately expands the review row, selects one occurrence, and works in one inspector. Selecting that occurrence again returns to the clean list without adding another control. Repeated occurrences remain independent; custom metadata paths show their source as a fixed identity while using the complete transform and ordered multiline regex controls. Indexed sources accept only blank or non-negative digits through the inspector, while invalid raw values remain visible and untouched until repaired. Regex-stage reordering and removal remain accessible symbolic actions without persistent button chrome. Replacement fields preserve Return and typed backslash sequences exactly as entered; the existing runtime's ambiguous newline compatibility remains unchanged until a versioned, context-aware escape model can replace it safely. Raw placeholder syntax is shown once, and unsupported technical syntax stays byte-for-byte intact.

## Do's and Don'ts

### Do:

- **Do** use neutral graphite, white, and gray roles for all resting surfaces and structural chrome.
- **Do** reserve green, amber, and red for connection, saved/saving, warning, error, and destructive states, and pair each with text or an icon.
- **Do** show whether a value is Saved, Saving, Unsaved, Not saved, inherited, a built-in template, fixture-backed, or live-connected.
- **Do** qualify every fixture acknowledgement as a preview update and state that preview data resets without writing `macrowhisper.json`.
- **Do** preserve the stored value and recovery state of a dependent setting when its controlling behavior hides it.
- **Do** make payload-mode replacement recoverable within the editing session and say clearly when retained text is not persisted.
- **Do** keep advanced syntax recoverable without making it routine chrome; unusual condition and trigger expressions use exceptional recovery states instead of permanent raw-mode controls.
- **Do** preserve the single contextual rail: groups browse collections without replacing the current editor, concrete actions navigate the main panel, and mobile presents the rail and editor sequentially.
- **Do** keep familiar native controls, visible focus, readable wrapping, and reduced-motion behavior.

### Don't:

- **Don't** introduce blue, purple, gradients, or colored surface washes into the neutral editor chrome.
- **Don't** use semantic color as decoration or as the only signal for state.
- **Don't** imply that a fixture-only, failed, or disconnected write was saved to the real configuration.
- **Don't** flatten every advanced setting into an always-open form or hide the consequences of raw configuration.
- **Don't** add strong shadows to ordinary rows, cards, or controls; depth belongs to transient layers.
- **Don't** replace the canonical configuration semantics with a simplified visual-only model.
