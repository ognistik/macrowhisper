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

Status: implemented for user review. Placeholder detection is continuous and
caret-independent; every complete occurrence is listed, while custom metadata
paths remain structured and unsupported XML/raw syntax remains untouched.

- Detect placeholder occurrences continuously without opening an editor from
  caret movement.
- Add a stable count/review row, an occurrence list, and one deliberate
  occurrence inspector.
- Highlight the selected occurrence in the payload and preserve unsupported raw
  syntax without rewriting it.
- Redesign ordered regex stages as full-width multiline editors with validation,
  reordering, removal, and raw syntax behind disclosure.

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
