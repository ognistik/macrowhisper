---
target: Defaults interaction polish
total_score: 25
max_score: 40
na_heuristics:
p0_count: 0
p1_count: 1
target_identity: "file:/Users/ognistik/Documents/GitHubRepos/macrowhisper-editor/editor/src/App.tsx"
target_fingerprint: "sha256:7a3103d1ef5bcf5fd2ba9521103589b8f046bc9a27882e727385bacd7138d9ad"
target_path: /Users/ognistik/Documents/GitHubRepos/macrowhisper-editor/editor/src/App.tsx
timestamp: 2026-09-15T07-45-21Z
slug: editor-src-app-tsx
closed: true
---
Method: dual-agent (A: `/root/defaults_critique_a` · B: `/root/defaults_critique_b`)

## Design Health Score

| # | Heuristic | Score | Key issue |
|---|---|---:|---|
| 1 | Visibility of system status | 3/4 | Saving and error states are clear, but routine metadata is not compositionally stable. |
| 2 | Match with the real world | 3/4 | The language is mostly plain; Built-in, Defaults, and Revert still need sharper separation. |
| 3 | User control and freedom | 2/4 | Revert is currently unsafe because blur can save before the discard action runs. |
| 4 | Consistency and standards | 3/4 | Native controls and grouping are coherent; reset semantics differ across field types. |
| 5 | Error prevention | 2/4 | Blank numeric drafts reach an avoidable validation failure. |
| 6 | Recognition rather than recall | 3/4 | Summaries and descriptions help, but blank/null/zero behavior is not visible. |
| 7 | Flexibility and efficiency | 2/4 | Keyboard operation exists, but the Revert race affects keyboard users too. |
| 8 | Aesthetic and minimalist design | 3/4 | The page is calm and polished; conditional utility content introduces motion it does not need. |
| 9 | Error recovery | 2/4 | Errors preserve drafts, but Revert can commit and the blank field can visually resemble its placeholder default. |
| 10 | Help and documentation | 2/4 | Field descriptions exist, but the relationship between Built-in and user Defaults is still implicit. |
| **Total** | | **25/40** | **Good foundation; interaction semantics need hardening** |

## Design Specificity Verdict

This feels substantially authored for Macrowhisper: the Superwhisper terminology, action-chain language, revision status, effective summaries, and built-in provenance all belong to this product. The broad shell is conventional, appropriately so for an operational configuration editor. Product specificity should come from exceptionally clear state semantics, not more decoration.

The deterministic scan found 0 issues in `editor/src/App.tsx`. Native browser inspection succeeded, but a user-visible detector overlay was unavailable because this browser exposes only read-only page evaluation.

## Overall Impression

The visual structure should stay. The biggest opportunity is to make every ordinary edit transition geometrically stable and to ensure Revert and Use built-in have completely different, reliable meanings. Saved did not change row geometry in the measured desktop layout. The conditional built-in action did: Action delay measured about 92px tall with the link and 84px without it. Saved can still wrap in narrower layouts, so its slot should be stabilized too.

## What's Working

- The single open-section model and collapsed effective summaries make a dense configuration surface feel calm.
- The graphite, border, typography, and native-control treatment are restrained and convincingly macOS-like.
- Keeping the setting-specific Built-in option first is correct. The shipped behavior should be encountered before explicit alternatives.

## Priority Issues

1. **[P1] Revert currently saves the draft it is supposed to discard.** Clicking Revert while the field is focused fires blur first, starts the save, and only then clears the draft. Make Revert cancel or outrank the pending blur commit, restore the last successfully saved value without a write, and test pointer and keyboard activation.

2. **[P2] The conditional built-in action should move into a stable utility region.** Adding or removing the link changes the control stack height and shifts every following row. Move Use built-in into the left-side metadata area used for save state and give the status/action cluster stable dimensions. Keep the text action rather than hiding it behind three dots.

3. **[P2] Blank numeric fields should mean unset in this Defaults context.** On Defaults, blank plus blur/Enter should commit null, meaning Use built-in. Explicit 0 remains a numeric value. In action overrides, blank should mean inherit Defaults. Keep History's blank meaning Keep forever. Nonempty invalid values and negatives should still error.

4. **[P2] Built-in terminology is structurally correct but needs one definition.** Keep Built-in value at the top, followed by explicit alternatives. Rename Restore built-in to Use built-in and explain once that Built-in is the behavior Macrowhisper ships with and Use built-in removes the custom value. Change the General copy to “Shared behavior used unless an action overrides it.”

## Persona Red Flags

- Power user: a rapid Revert click can silently commit the unwanted value.
- First-time user: Built-in, Defaults, fallback action, unset, and explicit zero have no single visible explanation.
- Keyboard or screen-reader user: tabbing away from a dirty field before activating Revert can initiate the unwanted commit.
- Stress tester: empty, zero, null, and Keep forever follow different rules that are not apparent from the form.

## Minor Observations

- Built-in pills are useful but repetitive in long sections; once explained, their contrast can remain quiet.
- Defaults intro metadata competes slightly with the page heading, but is not worth changing during this pass.
- A collapsed unresolved-state marker may eventually help, but is lower priority than correct Revert behavior.

## Questions to Consider

- Should Use built-in remain a visible text action in the stable left metadata cluster, or use a compact but less discoverable reset icon?
- Should clearing any ordinary numeric Default commit Built-in on blur/Enter, while History retains Keep forever?
- Should the next pass remain limited to these interaction fixes, leaving the visual structure untouched?
