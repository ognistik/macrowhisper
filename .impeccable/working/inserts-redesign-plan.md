# Inserts redesign working plan

Temporary implementation plan. Delete this file after the final checkpoint is
verified and the closing critique has been compared with the baseline snapshot
at `.impeccable/critique/2026-09-18T03-15-30Z__editor-src-app-tsx.md`.

## Product contract

- The left rail is a browser and the main pane is a destination. Browsing a
  collection never replaces or discards the main pane and does not run the
  destination-navigation flush. A focused text field still follows the normal
  save-on-blur contract when focus moves into the rail.
- Defaults is a direct destination. Action groups are collections: choosing
  Inserts, URLs, Shortcuts, Shell, or AppleScript replaces the rail contents
  with that group's action list.
- The main pane changes only after a concrete action is selected. Until then it
  preserves the currently open Defaults or action editor.
- The contextual rail always offers a clear route back to all sections. Editor
  status and appearance remain anchored at the bottom.
- Navigation to a concrete destination keeps the existing draft flush,
  validation, conflict, and discard behavior.
- The pattern must be reusable by every action type even while only Inserts is
  writable in the current milestone.

## Checkpoint 1 — contextual navigation shell

Status: implemented and verified by the user.

- Replace the permanent global rail plus nested Insert-list pane with one
  contextual rail.
- Decouple the rail's browsed collection from the main pane's open destination.
- Show action lists for every action group; keep create controls limited to the
  currently supported Insert lifecycle.
- Keep the desktop editor full-width beside the single rail.
- On narrow screens, use the same rail as a modal list and return to the editor
  after a concrete action is selected.
- Add regression coverage for independent browsing, leaf selection, returning
  to all sections, unsaved drafts, empty Inserts, and narrow navigation.
- Update the durable design and editor-plan documentation.

Success gate: clicking Inserts while Defaults is visible shows the Insert list
without changing Defaults; selecting an Insert then opens it. From that Insert,
browsing URLs shows the URL list while the Insert remains open.

## Checkpoint 2 — editor hierarchy and payload modes

Status: implemented and verified by the user. The exact custom payload is retained in
tab-scoped editing state when a built-in mode replaces it, remains recoverable
across action navigation and rename, and is intentionally cleared by reload or
scenario reset rather than being persisted outside the configuration.

- Bring the Insert editor onto the Defaults card/disclosure language.
- Consolidate the action header, name, source, duplicate, and delete controls.
- Replace the duplicated payload-mode presentation with one plain-language
  control and a safe recovery path for non-empty custom text.
- Add a compact effective-behavior summary.

Success gate: the simple path—name, payload mode, and custom text—is immediately
legible, while advanced sections remain findable without dominating the page.

## Checkpoint 3 — placeholder workspace

Status: implemented for user review, with the versioned runtime newline model
still open as a separate compatibility checkpoint. Placeholder detection is
continuous and caret-independent; every complete occurrence is listed, while
custom metadata paths remain structured and unsupported XML/raw syntax remains
untouched. The current pass keeps review collapsed after insertion, offers Date
formats as direct choices, coordinates review with the four action disclosures,
uses compact name-purpose rows with equivalent pointer and keyboard feedback,
and preserves typed replacement text without editor-side normalization.

- Detect placeholder occurrences continuously without opening an editor from
  caret movement.
- Add a stable count/review row, an occurrence list, and one deliberate
  occurrence inspector.
- Highlight the selected occurrence in the payload and preserve unsupported raw
  syntax without rewriting it.
- Redesign ordered regex stages as full-width multiline editors with validation,
  quiet symbolic reordering/removal actions and capture guidance.

### Placeholder palette refinement requirement

- Keep each placeholder's concise purpose visibly associated with its title.
  Essential descriptions must not move into a footer that appears only after
  hover, focus, or selection; a footer may supplement a row, but it cannot be
  the only place needed to understand that row.
- Pointer and keyboard users must each be able to discover, compare, and insert
  placeholders from beginning to end without switching input methods. Pointer
  hover and keyboard focus/arrow navigation should expose equivalent states,
  while click, Enter, and Space provide equivalent activation.
- Add an unmistakable but quiet hover state and an equally clear focus state.
  Neither state may depend on color so subtle that it disappears in dark mode.
- Revisit popover width, row hierarchy, description measure, group rhythm, and
  inherited/duplicate styles together. The goal is a compact chooser with clear
  name-description hierarchy, not a wide reference table or a hover-dependent
  master-detail browser.

### Replacement newline compatibility requirement

- Do not silently rewrite typed backslash sequences into visible Returns while
  the user is editing. Preserve existing and newly typed replacement text until
  a complete, versioned escape model can distinguish line breaks from literal
  backslashes without changing existing Insert output.
- Treat the runtime's current global backslash-newline conversion and any future
  context-aware placeholder grammar as a separate compatibility checkpoint;
  editor-only normalization is not considered the final solution.

Success gate: payload layout remains stable while typing and every occurrence,
including repeated sources with different transforms, is independently editable.

## Checkpoint 4 — behavior comprehension and finish

- Refine Insertion behavior, Conditions, Triggers, and Chaining summaries.
- Improve trigger density and advanced/raw boundaries; decide whether a local
  sample tester belongs in this release.
- Complete keyboard, screen-reader, contrast, dark-mode, narrow-window, and 200%
  zoom checks in Safari and Chromium targets.
- Run the mechanical detector once, run a closing Impeccable critique, compare
  it with the 26/40 baseline, close or supersede the critique snapshot, and
  delete this working plan.

Success gate: the finished Inserts experience is visually continuous with
Defaults, retains the complete configuration model, and materially improves the
baseline critique without introducing navigation or round-trip regressions.
