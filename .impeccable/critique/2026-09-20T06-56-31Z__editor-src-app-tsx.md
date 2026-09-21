---
target: Insert editor Triggers section
total_score: 23
max_score: 40
na_heuristics: 
p0_count: 1
p1_count: 3
target_identity: "file:/Users/ognistik/Documents/GitHubRepos/macrowhisper-editor/editor/src/App.tsx"
target_fingerprint: "sha256:f815f22a1bed55de6ae1aa27c5a6ab90457eea384607ea16a0cc7985c56d73f1"
target_path: /Users/ognistik/Documents/GitHubRepos/macrowhisper-editor/editor/src/App.tsx
timestamp: 2026-09-20T06-56-31Z
slug: editor-src-app-tsx
closed: true
---
Method: dual-agent (A: /root/trigger_design_review · B: /root/trigger_detector_review)

## Design Health Score

| # | Heuristic | Score | Key issue |
|---|---|---:|---|
| 1 | Visibility of System Status | 2 | Structured token edits become dirty drafts but have no blur or Enter commit path, so the interface can look edited without reaching the save transaction. |
| 2 | Match System / Real World | 3 | Product terms are strong; `Advanced raw`, `Exclude`, and AND/OR still require translation. |
| 3 | User Control and Freedom | 3 | Revert and removal exist, but group-level and row-level X controls do not make their scope sufficiently distinct. |
| 4 | Consistency and Standards | 2 | Triggers does not follow the full-width configured-list, stable control rail, and footer pattern established by Conditions and Action overrides. |
| 5 | Error Prevention | 1 | Unsaved structured edits, ambiguous exception semantics, and raw-mode switching create preventable configuration errors. |
| 6 | Recognition Rather Than Recall | 2 | Users must infer `!`, `==…==`, prefix stripping, and the difference between intentional regex and unrepresentable syntax. |
| 7 | Flexibility and Efficiency | 3 | Structured rows and raw regex serve novices and experts, but repeated raw toggles add unnecessary work. |
| 8 | Aesthetic and Minimalist Design | 2 | The priority callout, duplicate empty state, two-column grid, and repeated advanced controls compete with the task. |
| 9 | Error Recovery | 2 | Exact-value preservation is good, but an invalid saved Trigger logic value can be shown without exposing a repair control. |
| 10 | Help and Documentation | 3 | The documentation is strong; local copy is uneven and does not consistently state consequences. |
| **Total** | | **23/40** | **Acceptable foundation; significant trigger-specific improvements needed.** |

## Design Specificity Verdict

The trigger concepts are unmistakably Macrowhisper: voice prefixes, Superwhisper modes, front apps, browser URLs, fallback behavior, and preserved expressions. The composition is still category-interchangeable. A two-column settings grid, repeated checkboxes, and generic icon removal controls make four related matching rules feel like unrelated fields instead of one coherent trigger builder.

The deterministic scan returned zero generic findings. That does not clear the surface: live/source inspection found a broken structured-save boundary, unmatched heading labels in structured mode, trigger errors without live announcement, and an invalid Trigger logic state whose repair control can be hidden. These are product-specific problems outside the detector's rule set.

No visual overlay was injected. The live-injection helper reported `config_missing`, so browser evidence came from a fresh background fixture tab, accessibility state, screenshots, and source inspection.

## Overall Impression

The user's diagnosis is correct. The current Triggers section has good semantics inside the wrong layout. The single biggest opportunity is to make it use the same full-width configured-list grammar as Conditions and Action overrides, while separating normal trigger authoring from exceptional syntax recovery.

## Recommended Shape

1. Keep the disclosure title `Triggers`, subtitle `Match a phrase, app, mode, or URL.`, and compact closed-state meta.
2. Remove the Matching priority callout from the editor; it belongs in documentation because it is not configurable.
3. Reduce the empty expanded state to one quiet framed row containing only the `Add trigger…` control. Do not repeat `No triggers` or fallback/chain-step explanation in the body. Keep `No triggers` only as compact closed-state/effective-state metadata.
4. Replace the two-column trigger grid with one full-width configured list. Each trigger type uses three stable regions: left copy, flexible editor, and far-right group removal.
5. Put the Voice matching-mode selector at the top of the editor region, not beside the group-removal X. Offer only `Prefix phrases` and `Raw regular expression`.
6. Structure each ordinary value row as `Except` checkbox, value field, then inner row removal. Putting `Except` before the field makes the row read naturally and separates it visually from the removal control. One shared hint should explain that exception rows prevent the action from matching; avoid repeating it on every row.
7. Keep the group-level X in the same outer utility rail and visual style used by Conditions and Action overrides. Give group and row removal explicit accessible names so their scope is unambiguous.
8. Move `Add phrase/app/mode/URL` directly below that trigger type's rows. Move `Add trigger…` to the standard right-aligned section footer once at least one type exists.
9. Render Trigger logic as the final full-width row with plain-language choices: `Use Defaults — Any type can match`, `Any type can match`, and `All types must match`. Always expose a repair path when a saved value is invalid, even if fewer than two types are configured.
10. Treat unrepresentable saved syntax like Conditions recovery: show the exact preserved value in a needs-review panel, then offer deliberate `Edit raw expression` and `Replace with visual entries` actions. Do not show `Advanced raw mode` in the normal path.

## What's Working

- The underlying trigger model is correctly represented, including multiple values, negative exceptions, raw voice regex, and AND/OR composition.
- The disclosure summary and effective-behavior summary provide strong orientation before editing.
- The quiet graphite system, native controls, preview/save states, and exceptional preservation patterns elsewhere in the editor provide the right design language to reuse.

## Priority Issues

### [P0] Structured trigger rows do not cross the save boundary

`TriggerTokenRows` calls `updateRows`, which calls `setDraftValue`, but the row inputs have no blur or Enter handler that calls `commitIfChanged`. Adding, editing, excluding, or removing ordinary structured values can appear successful without persisting through the editor transaction.

Fix: follow the editor's save contract. Text changes update the local draft and commit the serialized trigger on blur or Enter; the discrete `Except` choice and removal action commit immediately. Add regression coverage that asserts the fixture snapshot changes and that live/preview acknowledgement appears.

Suggested command: `$impeccable harden`

### [P1] The body uses redundant framing and the wrong composition

The priority callout and duplicate no-trigger card front-load non-actionable information. The two-column grid narrows editors and produces uneven vertical columns, conflicting with the full-width rows users just learned in Conditions and Action overrides.

Fix: use the full-width configured-list and footer blueprint above. Keep the outer 940px lane; the internal grid is the problem, not the page width.

Suggested command: `$impeccable layout`

### [P1] Raw regex is conflated with exceptional syntax recovery

For Voice phrases, Raw regex is a valid intentional input mode. `Advanced raw` is a byte-preserving escape hatch for saved syntax the visual editor cannot safely represent. Presenting both as peer modes, plus repeating Advanced raw toggles on valid structured fields, makes the editor teach an implementation detail as routine configuration.

Fix: retain `Prefix phrases` and `Raw regular expression` as normal Voice modes. Move all unrepresentable expressions to the same explicit needs-review recovery model used by Conditions. Apps and modes already accept regex patterns in their normal rows and do not need a routine advanced toggle.

Suggested command: `$impeccable distill`

### [P1] Invalid Trigger logic can be visible without a repair control

The logic selector renders only when two or more trigger types are configured, while the invalid-value error renders independently. A saved `xor` can therefore be reported with no visible way to fix it.

Fix: keep the healthy logic control hidden when irrelevant, but always reveal the selector or a one-click replacement action for an invalid saved value.

Suggested command: `$impeccable harden`

### [P2] Row semantics, removal scope, and accessibility associations are unclear

`Exclude` sits between the value and X, creating the checkmark/X competition the user noticed. Group and row removal use the same symbol without enough spatial or accessible distinction. In structured mode, trigger headings use `htmlFor` values that do not match the token inputs, and trigger errors are not live-announced.

Fix: use `Except` before the field, reserve separate inner and outer removal rails, group token sets with `fieldset`/`legend` or `aria-labelledby`, connect errors with `aria-describedby`, and announce blocking errors with `role="alert"` or an appropriate live region.

Suggested command: `$impeccable clarify`

## Persona Red Flags

**Alex, power user:** repeated Advanced raw toggles and the two-column layout slow scanning and editing. The silent draft-only behavior is especially dangerous because expert users will move on assuming the blur-save contract is consistent.

**Jordan, first-timer:** Matching priority, Raw regex, Advanced raw, Exclude, and AND/OR arrive before a simple matching rule is established. The current surface teaches internals instead of the direct task: choose what should start this action.

**Sam, accessibility-dependent user:** structured trigger headings are not programmatically tied to their token group, trigger errors may not be announced, and identical X icons require context to understand whether a value or an entire trigger type will be removed.

## Minor Observations

- Use consequence-oriented descriptions consistently: Voice starts the action from a spoken prefix; Front apps match the foreground app name or bundle ID; Modes match the current Superwhisper mode; URLs match a domain or URL prefix.
- Apps and modes accept regex patterns according to the documentation. Say `Regular expressions are supported` once in their shared help rather than adding another mode.
- For Voice raw regex, explain the important consequence, not the storage wrapper: it uses the complete expression and does not automatically remove the spoken prefix.
- The 781–960px band currently retains the two-column trigger grid and deserves a targeted browser check after the full-width rewrite.
- Add tests for empty triggers, last-row/group removal, exception-only lists, invalid Trigger logic recovery, raw-expression recovery, blur/Enter commit, and error announcement.

## Questions to Consider

- Should exceptional raw-expression editing remain available inline after an explicit warning, or should the recovery panel offer only replacement with visual entries plus a documentation link?
- Should exception rows be labeled `Except` or the more explicit `Do not match`?
- Should the first implementation pass cover only Triggers, or also extract the shared configured-list primitives now used by Action overrides, Conditions, and Triggers?
