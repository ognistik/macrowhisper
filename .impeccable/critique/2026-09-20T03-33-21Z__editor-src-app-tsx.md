---
target: Insert editor Conditions section
total_score: 25
max_score: 40
na_heuristics: 
p0_count: 0
p1_count: 3
target_identity: "file:/Users/ognistik/Documents/GitHubRepos/macrowhisper-editor/editor/src/App.tsx"
target_fingerprint: "sha256:4dd5df610b32c03eafd512c1784593a9e88e17db2e0f1c6cd7c91050e323ba27"
target_path: /Users/ognistik/Documents/GitHubRepos/macrowhisper-editor/editor/src/App.tsx
timestamp: 2026-09-20T03-33-21Z
slug: editor-src-app-tsx
closed: true
---
## Design Health Score

| # | Heuristic | Score | Key issue |
|---|---|---:|---|
| 1 | Visibility of system status | 3/4 | Rule count is visible, but save feedback is detached from the changed row. |
| 2 | Match system / real world | 2/4 | Plain-language choices work; generated-expression and raw-token language leaks implementation detail. |
| 3 | User control and freedom | 3/4 | Removal and recovery exist, but raw editing is awkwardly exposed. |
| 4 | Consistency and standards | 2/4 | Add condition and the empty state diverge from Action overrides. |
| 5 | Error prevention | 2/4 | Structured controls constrain tokens, but the simultaneous raw editor invites conflicting mental models. |
| 6 | Recognition rather than recall | 3/4 | Labels and choices are visible; fallback-to-Defaults semantics are not. |
| 7 | Flexibility and efficiency | 3/4 | Structured and expert paths exist, but are not separated. |
| 8 | Aesthetic and minimalist design | 2/4 | Intro copy, empty-state copy, generated output, raw input, and raw help duplicate one concept. |
| 9 | Error recovery | 3/4 | Existing expressions are preserved, but repair depends on finding the raw toggle. |
| 10 | Help and documentation | 2/4 | The key consequence of an unmet condition is not explained. |
| **Total** |  | **25/40** | **Moderate health; simplify the normal path and isolate recovery.** |

## Design Specificity Verdict

The surrounding Insert editor feels authored for Macrowhisper's quiet-control-room direction. The Conditions body is less specific: it presents a good context-aware rule builder and then repeats its state as a generic serialization inspector. The product-specific promise should be simple: choose which part of this action changes inside or outside a text field.

The deterministic scan returned zero findings for `editor/src/App.tsx`. Browser evidence at 1280x720 confirmed the duplication: explanatory copy, an Always card, Add condition, Generated expression, an Edit raw expression toggle, and a read-only raw field are all visible in the same open section. No reliable browser overlay was available because the browser evaluation surface rejected mutable injection.

## Overall Impression

The underlying interaction is sound, but the section is visually and conceptually over-explained. The largest opportunity is to make Conditions inherit the Action overrides interaction language while keeping storage syntax out of the normal workflow.

## What's Working

- “Only in a text field” and “Only outside text fields” map directly to user intent.
- The disclosure header and rule-count summary provide useful progressive disclosure.
- Existing unusual expressions are preserved instead of silently rewritten.

## Priority Issues

1. **[P1] The same condition is represented several times.** Keep the disclosure subtitle, remove the repeated intro and empty Always card, and remove generated/raw syntax from the normal path.
2. **[P1] Add condition does not follow Action overrides.** Reuse its placement, alphabetical ordering, pending-row lifecycle, cancel behavior, and commit-only-after-selection rule.
3. **[P1] Raw syntax is primary chrome instead of exceptional recovery.** Hide it in healthy states. When a saved expression cannot round-trip visually, show a contextual recovery state that preserves the exact value and routes the user to deliberate repair.
4. **[P2] The UI does not explain the actual fallback.** For settings, an unmet condition restores Defaults; it does not generally disable the setting. Explain that once, adjacent to the relevant rule or in the section subtitle.

## Persona Red Flags

- **First-timer:** “Always” can sound like a trigger, while raw tokens appear before there is any reason to understand them.
- **Power user:** Conditions ordering and pending-row behavior differ from the learned Action overrides workflow.
- **Keyboard/VoiceOver user:** A disabled structured fieldset beside a focusable read-only raw input makes availability ambiguous, and the condition error lacks a strong announcement relationship.

## Minor Observations

- Conditions options currently follow schema order while Action overrides are alphabetical.
- Built-in payload modes leave disabled controls and raw machinery visible even though stored conditions are not active.
- Focused UI tests are missing for empty Conditions, pending rows, successful saves, removal, and exceptional-expression recovery.

## Questions to Consider

- Should the visual Add menu offer only Payload plus eligible settings that actually have an action-level value?
- Should unusual manual expressions be repaired in a contextual drawer, or should the editor direct users to the canonical JSON file?
