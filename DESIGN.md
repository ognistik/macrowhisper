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
  connection-card:
    backgroundColor: "{colors.surface-muted}"
    textColor: "{colors.text}"
    typography: "{typography.label}"
    rounded: "{rounded.panel}"
    padding: "11px"
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

The system is compact but not cramped. Familiar controls carry the interaction, while progressive disclosure keeps advanced conditions, chaining, placeholders, and raw syntax available without making the first useful path feel technical. Light and dark appearances use the same neutral roles; green, amber, and red are reserved for connection, save, warning, and error meaning.

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

The desktop shell is a sticky left navigation rail (`232px`) beside a flexible main panel. The top context bar is sticky and `60px` tall. Defaults use one centered reading lane capped at `940px`, with a `12px` gap between accordion sections and a fixed `280px` to `320px` control column inside an open section. The action workspace adds a sticky action list (`270px`) beside a flexible editor, so the full desktop experience reads as navigation → list → editor. The action editor reading column is capped at `790px`, while general screen content is capped at `1240px` with `38px` inline breathing room.

The layout becomes less dense in measured steps: Defaults keep their single reading order at every width and stack each field below `780px`; the rail and list narrow below `1050px`; below `780px` the rail becomes a drawer and the action workspace exposes either the list or editor as one surface at a time. Inline padding becomes `15px` on mobile, and controls/popovers wrap again below `430px`. Native `details` sections keep advanced settings behind progressive disclosure. Defaults first appears as a fully collapsed overview, then restores the user's last open section or deliberately collapsed state from browser-local presentation storage.

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
- **Revision and count chips:** quiet metadata uses the same neutral surfaces and muted text, never a decorative accent.

### Cards / Containers

- **Connection card:** muted surface, one-pixel border, `8px` radius, compact internal padding; the status dot and explicit sentence explain live, fixture, fallback, or disconnected state.
- **Create panel / modal:** raised or muted surface with a one-pixel edge and `8px`/`10px` radius; modals add the shared overlay shadow and keep actions aligned at the end.
- **Action list item:** flat at rest, muted on hover, selected gray with a one-pixel border; a small bordered icon box anchors the row without competing with its name.
- **Payload boundary:** clean surface with an eight-pixel radius, a toolbar/footer divider, and the focus ring when editing.

### Inputs / Fields

Fields are familiar native controls: `36px` inputs/selects, one-pixel strong hairline borders, six-pixel corners, and surface backgrounds. Textareas use `11px 12px` padding and a `1.55` line-height. Hover increases border contrast; focus uses the shared two-pixel outline, and a focused payload boundary adds a three-pixel ring. Units, reset links, and field state stay adjacent to the control rather than being hidden in tooltips.

### Navigation

The left rail is sticky and quiet, with uppercase group labels, 16px line icons, 36px navigation rows, and neutral selected-state fill. The top bar provides the Macrowhisper breadcrumb, revision/live signal, and fixture scenario selector. At mobile width the rail becomes a modal drawer with a close control and focus containment; action editing switches between list and editor surfaces instead of squeezing both panes together.

### Disclosure Rows

Native `details`/`summary` rows keep Insertion behavior, Conditions, Triggers, Chaining, and other settings available but out of the first-run path. Defaults opens one section at a time in a single centered accordion. Each quiet, flat, one-pixel-bordered section surface uses spacing instead of repeated full-width rules to establish hierarchy: its collapsed header shows only the title and effective-state summary, then reveals the explanatory copy and fields when opened. A native `Built-in value` group identifies only the value Macrowhisper ships with for that particular root setting; a decorative divider and a second semantic group separate explicit choices, and an integrated source pill appears inside the closed control while the built-in value is active. Eligible text and numeric root fields with an unambiguous shipped fallback expose `Use built-in` only until restoration succeeds. Default descriptions use a protected reading measure so long copy wraps before entering the trailing utility rail's visual territory. Transient status, recovery controls, and this persistent reset action occupy that stable, right-aligned rail beside the field label; the rail is optically aligned with a single desktop control, shifts to the lower input baseline only while a custom two-control editor is open, and remains visually empty when idle so routine state changes never resize the row. Revert discards the local draft without triggering a blur save. Clearing an ordinary numeric Default saves the built-in state, while explicit zero remains distinct and History retains its `Keep forever` meaning. The Defaults body reveal and chevron rotation share a restrained `180ms` transition and respect reduced-motion preferences. Successful save acknowledgement clears after roughly two seconds, while errors remain until resolved; neither save activity nor error recovery copy is folded into the effective-behavior summary. Action disclosures show configured exceptions first; empty sections offer a single Add control. Each row exposes its title, consequence, and useful state summary before it opens; the chevron rotates as an orientation cue.

### Payload Editor

The payload editor is the signature interaction: a bordered editing boundary with a mode label, a source-only placeholder menu, built-in choice cards for Auto-paste / Do nothing / Custom text, a raw text area, and a character/state footer. Date formatting belongs to the Date insertion flow. When the caret is inside a recognized placeholder, a persistent inline inspector edits that placeholder's source, transform, and ordered regex replacements without nesting a builder inside a menu. The raw value remains visible and unsupported technical syntax stays intact.

## Do's and Don'ts

### Do:

- **Do** use neutral graphite, white, and gray roles for all resting surfaces and structural chrome.
- **Do** reserve green, amber, and red for connection, saved/saving, warning, error, and destructive states, and pair each with text or an icon.
- **Do** show whether a value is Saved, Saving, Unsaved, Not saved, inherited, a built-in template, fixture-backed, or live-connected.
- **Do** keep advanced syntax behind a deliberate disclosure or raw-mode opt-in while keeping the raw value recoverable.
- **Do** preserve the desktop navigation → list → editor hierarchy and the mobile list/editor single-surface behavior.
- **Do** keep familiar native controls, visible focus, readable wrapping, and reduced-motion behavior.

### Don't:

- **Don't** introduce blue, purple, gradients, or colored surface washes into the neutral editor chrome.
- **Don't** use semantic color as decoration or as the only signal for state.
- **Don't** imply that a fixture-only, failed, or disconnected write was saved to the real configuration.
- **Don't** flatten every advanced setting into an always-open form or hide the consequences of raw configuration.
- **Don't** add strong shadows to ordinary rows, cards, or controls; depth belongs to transient layers.
- **Don't** replace the canonical configuration semantics with a simplified visual-only model.
