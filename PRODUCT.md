# Product

<!-- impeccable:product-schema 1 -->

## Platform

web

## Users

The configuration editor is for people who use Superwhisper on macOS and want Macrowhisper to turn dictation into dependable, repeatable actions without having to learn or hand-edit its JSON configuration.

It must welcome people setting up their first useful workflow while preserving the control expected by existing Macrowhisper users who work with triggers, placeholders, inheritance, scripts, and action chains.

## Product Purpose

Give Macrowhisper a comfortable local configuration experience. The editor should help people understand what Macrowhisper will do, create and refine actions, and recover confidently from invalid or conflicting changes.

Success means a user can move from intent to a valid configuration with less syntax knowledge and less uncertainty, without reducing what the underlying configuration can express or making manual editing unsafe.

## Positioning

Macrowhisper is the automation layer after Superwhisper turns voice into text. Its configuration editor exposes that post-transcription system—context-aware action selection, formatting, insertion, URLs, Shortcuts, scripts, and multi-step chains—as understandable controls while keeping the same portable JSON configuration canonical.

The editor is local to the Macrowhisper daemon. It is not a hosted account, a separate automation engine, or a simplified replacement format.

## Operating Context

The editor runs in a browser but belongs to a macOS-only workflow. It is opened through the local Macrowhisper command-line tool and is planned to be served from the existing daemon over loopback with bundled, offline-capable assets.

Users configure Defaults first, then actions grouped as Inserts, URLs, Shortcuts, Shell, and AppleScript. They may also edit the same `macrowhisper.json` file directly, sometimes while the editor is open. Configuration choices affect a background service that watches Superwhisper recordings and executes actions in the context of the frontmost app, selected text, browser URL, and clipboard state.

## Capabilities and Constraints

- The version 3 JSON configuration remains the canonical source of truth; manual editing remains supported. JSON serialization and Macrowhisper Insert escaping are separate layers, so the editor can show semantic values without making manual JSON behavior surprising.
- The editor must preserve the runtime's existing configuration semantics, including action-level inheritance through `null`, intentional empty values, built-in values such as `.autoPaste` and `.none`, globally unique action names, trigger expressions, input conditions, and `nextAction` chains.
- The editor must distinguish clean server values, local drafts, saving, accepted changes, validation failures, transport failures, stale revisions, external edits, invalid disk state, and disconnected state. It must never report a failed or fixture-only write as saved to the real configuration.
- Discrete choices save immediately. Text and numeric text controls save when their editing boundary is left. There is no global Save button and no timer-based text autosave.
- The first complete connected slice covers Defaults and the full Insert lifecycle. The other four action types follow through the same model rather than lowering the quality of the foundational interactions.
- The editor must not execute actions, expand placeholders against private live context, expose remote access, or provide arbitrary file-read or shell-evaluation APIs.
- Configuration reads and writes are private local operations. The eventual server must authenticate same-user access, reject cross-origin access, keep credentials and configuration content out of logs and URLs, and allow automation to continue if the editor fails.
- The existing React, TypeScript, and Vite frontend is an experimental fixture-backed prototype. It does not currently read or write the live configuration, and its present visual treatment is not a binding design direction.
- Open engineering decisions include the final loopback port, browser-session lifetime and new-tab behavior, update transport, compatible packaged-asset layout, and representation of advanced expressions that cannot round-trip through structured controls.

## Brand Commitments

Preserve the names and capitalization **Macrowhisper** and **Superwhisper**. Describe Macrowhisper as an independent automation helper or layer for Superwhisper, never as an official Superwhisper product.

Product language should be direct, practical, approachable, and precise. Explain advanced behavior in plain language without hiding its consequences or inventing certainty.

No current editor styling, palette, typography, or component treatment is a durable commitment. The existing interface is a first iteration and may be redesigned.

## Evidence on Hand

- The current fixture-backed editor implementation is in `editor/`, with interaction coverage in `editor/src/App.test.tsx` and `editor/src/store/fixtureStore.test.ts`.
- `docs/development/web-editor-plan.md` records the approved editor scope, behavior, architecture, security boundaries, implementation sequence, and verification gates.
- `docs/development/web-editor-prototype.md` records what the current synthetic prototype does and does not prove.
- The root `README.md` and user documentation under `docs/` define Macrowhisper's shipped behavior and canonical terminology. `src/macrowhisper-schema.json` is the configuration schema projected into the frontend.
- Existing product assets include the Superwhisper setup screenshot under `docs/assets/` and Macrowhisper artwork under `alfred/workflow/assets/images/`.
- There are no confirmed user-research findings, usability metrics, testimonials, customer logos, or editor adoption data in the repository. Future design work must not fabricate them.

## Product Principles

1. Make powerful configuration understandable without making it less powerful.
2. Preserve meaning across the editor, JSON, daemon, watcher, and CLI; one setting must not acquire different semantics in different surfaces.
3. Make state and consequences legible—especially inheritance, drafts, validation, conflicts, disconnection, and what has actually been saved.
4. Keep the configuration local, private, recoverable, and manually editable.
5. Prefer a smaller complete workflow over broad but shallow coverage of every action type.

## Accessibility & Inclusion

The editor must support keyboard navigation, meaningful labels and descriptions, visible focus, non-color-only status communication, readable error and disabled states, reduced motion, narrow windows, and 200% browser zoom. Before release, verify the shipped interface in Safari and a Chromium browser, with VoiceOver and keyboard-only navigation, in light and dark appearances.

These are release requirements, not claims that the current prototype has already passed those audits.
