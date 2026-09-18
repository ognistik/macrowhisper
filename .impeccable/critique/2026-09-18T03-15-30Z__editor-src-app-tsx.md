---
target: Inserts tab
total_score: 26
max_score: 40
na_heuristics: 
p0_count: 0
p1_count: 2
target_identity: "file:/Users/ognistik/Documents/GitHubRepos/macrowhisper-editor/editor/src/App.tsx"
target_fingerprint: "sha256:74ebd4fc51d01020e1275ae257a5b8fa68750ccbbeb717c405007de7c45dff91"
target_path: /Users/ognistik/Documents/GitHubRepos/macrowhisper-editor/editor/src/App.tsx
timestamp: 2026-09-18T03-15-30Z
slug: editor-src-app-tsx
---
# Inserts design critique

Method: dual-agent (A: inserts_design_review · B: inserts_technical_audit)

## Design Health Score

| # | Heuristic | Score | Key issue |
|---|---|---:|---|
| 1 | Visibility of system status | 3 | Save/source states are clear, but list previews can lag local drafts. |
| 2 | Match system / real world | 3 | Friendly labels coexist with leaked sentinel and expression syntax. |
| 3 | User control and freedom | 3 | Recovery is strong, but payload-mode changes immediately replace the stored payload. |
| 4 | Consistency and standards | 2 | Inserts abandons the calm Defaults card/disclosure topology. |
| 5 | Error prevention | 2 | Empty replacement stages can serialize before users have formed a valid rule. |
| 6 | Recognition rather than recall | 3 | Helpful summaries exist, but advanced syntax and precedence must still be remembered. |
| 7 | Flexibility and efficiency | 3 | Search, duplicate, raw modes, and keyboard-friendly controls help experts. |
| 8 | Aesthetic and minimalist design | 2 | The two rails and expanding inspector make the workspace dense and spatially unstable. |
| 9 | Error recovery | 3 | Invalid data is preserved and retry/revert/resync paths are thoughtful. |
| 10 | Help and documentation | 2 | Inline help is limited and the main syntax help leaves the editor for GitHub. |
| **Total** |  | **26/40** | **Promising foundation, major structural pass needed** |

## Design Specificity Verdict

The Inserts surface inherits the credible monochrome macOS/settings language of Defaults, but it currently feels like a generic configuration form plus a code editor rather than a purpose-built text-automation workspace. The implementation is careful; the composition does not yet unify payload, placeholders, inheritance, triggers, conditions, and chaining into one understandable model.

The deterministic detector returned zero mechanical findings for `editor/src/App.tsx`. Browser inspection nevertheless found five manual issues outside the detector's reach: dark destructive-button contrast, incomplete listbox arrow-key behavior, a 781–851px squeeze range, undersized mobile checkbox hit areas, and dynamic error text without live-region semantics. No reliable visual overlay was available because the sub-agent browser allowed read-only evaluation only.

## What is working

- The neutral visual system, typography, focus styling, and field lifecycle states are strong and worth preserving.
- Insert lifecycle operations—search, create, duplicate, rename, guarded delete, empty state, and source classification—are well conceived.
- The implementation protects advanced/raw values and demonstrates good accessibility intent, including native disclosures and enlarged mobile controls.

## Priority issues

1. **[P1] The two-sidebar topology spends too much width on navigation.** At 1280px the 232px global rail plus 270px action list leave about 763px for the editor; the intermediate breakpoint remains squeezed until an abrupt one-surface switch at 780px. Replace the nested permanent rails with one contextual rail that changes from section navigation to the selected action group's list, with a clear Back to all sections control.
2. **[P1] Placeholder editing is tied to an invisible caret rule and changes the page geometry.** Moving the caret into a recognized token inserts a large inspector under the textarea. Detection should be persistent, but opening an editor should be deliberate. Expose a stable footer such as “3 placeholders found,” expand to a list of occurrences, and open exactly one occurrence editor on request.
3. **[P2] The payload mode is presented twice and mode changes are destructively immediate.** The toolbar label and three large cards repeat the same choice, while `.autoPaste` and `.none` leak implementation details. Use one compact, plain-language selector and provide an undo/recovery path when leaving non-empty custom text.
4. **[P2] Regex replacement stages are visually compressed and lack a safe creation state.** A new empty stage immediately produces opaque generated syntax. Stack each ordered stage vertically, allow multiline Find and Replace, keep raw syntax behind disclosure, validate before representing an empty stage as complete, and consider an optional sample input/output test later.
5. **[P2] Effective behavior is fragmented.** Insertion behavior, Conditions, Triggers, and Chaining read as neighboring technical modules rather than one action. Reuse the Defaults accordion language, add meaningful closed summaries, and lead with a compact behavioral sentence such as “Triggered manually · Inserts custom text · Uses Defaults · No next action.”

## Persona red flags

- A first-time automation builder can type text successfully, then hits an expert cliff around sentinel values, precedence, inheritance, conditions, and regex syntax.
- A frequent user with many Inserts benefits from quick switching but pays for a permanently visible second rail and truncated action summaries.
- A regex/power user gets raw control without validation, sample output, or a clear boundary between structured and raw editing.
- A keyboard or screen-reader user encounters a dynamically appearing placeholder region that is neither deliberately opened nor announced; the Inserts list also lacks expected arrow-key navigation.

## Questions to consider

- Should the left rail prioritize the user's current editing task by becoming the Insert index, or should global sections remain permanently visible at the cost of editor width?
- Should placeholder rows represent each occurrence in the payload, preserving different transforms and replacements even when two occurrences share a source?
- Should the first redesign pass stop at shell, hierarchy, and payload/placeholder structure, leaving trigger testing and deeper regex tooling for a subsequent pass?
