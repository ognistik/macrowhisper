# Working on Macrowhisper

Macrowhisper is a macOS command-line automation helper for Superwhisper. It watches recordings and runs configured insert, URL, Shortcut, shell, and AppleScript actions. Watcher execution lives in `ActionExecutor` and CLI execution in `SocketCommunication`; both use shared configuration, trigger, placeholder, and clipboard utilities. Keep their action semantics consistent when changing behavior.

## Find the relevant context

- Start with the [documentation index](docs/README.md) for user-visible behavior and configuration semantics. Read the relevant topic pages rather than the entire reference for every task.
- Use the [development guide](docs/development/README.md) for build, signing, testing, and debugging procedures.
- Use the [codebase map](docs/development/codebase-map.md) to locate components and the [processing flow](docs/development/processing-flow.md) for watcher, clipboard, timing, and execution details.
- Application source is in `src/macrowhisper/`; the configuration schema is `src/macrowhisper-schema.json`. Xcode and Swift package metadata live in `src/`.
- Focused regression runners and their stubs are in `src/Tests/`. Installer and release tooling are in `scripts/`.
- `versions.json` stays at the root: the update checker consumes it. Release procedures are in [releasing](docs/development/releasing.md).

## Implement and document changes together

- When adding a feature or changing behavior, update the relevant documentation in the same change. Documentation is part of completing the work.
- Keep examples, configuration options and defaults, CLI instructions, and behavioral edge cases consistent with the implementation. Update the schema, CLI help, and relevant regression coverage when affected.
- Update the root `README.md` when requirements, installation, setup, or basic usage changes. It must remain sufficient for a technically comfortable user to get Macrowhisper running.
- Update `docs/README.md` when topics are added or reorganized, and repair related links and heading anchors.
- Keep documentation in the topic pages under `docs/`, with developer details in `docs/development/`. Do not add a combined guide, generated AI export, or another maintained copy under `src/`.
- Preserve approachable explanations and technical detail. Prefer links to canonical explanations over duplicating large sections.
- Preserve configuration inheritance and sentinel semantics, watcher/CLI behavior, context snapshots, and clipboard finalization rules unless the requested change explicitly affects them. Consult the relevant docs and source before changing these areas.

## Build and verify appropriately

- When asked for a binary for manual testing, use the signed Xcode workflow in the development guide and its stable local output location. Keep the established signing identity, identifier, and designated requirement consistent with the previously authorized test binary.
- Verify the resulting signature and report the binary's full path. Do not silently substitute an unsigned or ad hoc signed binary when signing fails. Generic signing alone does not guarantee retained macOS Accessibility permissions.
- Keep local build products under `.build/`. A manual-test build does not imply installation over the user's binary, service changes, notarization, or a release.
- Use the Xcode project for application compilation; the current Swift package manifest does not discover the application source directory. It also has no test target. Choose relevant standalone regression runners with their specific production sources and, where applicable, test stubs, as described in the development guide.
- For documentation-only changes, check examples, links, content coverage, and the diff. Do not build or change the running service merely to validate documentation layout.

## Respect repository and release boundaries

- Preserve unrelated working-tree changes. Do not stage or commit unrelated user edits.
- Treat `alfred/` and `samples/` as separate areas; change them only when the task calls for it.
- Keep release metadata and tooling changes deliberate. Use the documented release workflow when release work is requested; do not run it as a shortcut for a local test binary.
- The release helper can mutate Git state, GitHub releases, and the Homebrew formula repository. Even its dry run performs external preflight checks; read the release guide before invoking it.
- Keep `.release.env` and signing/notarization credentials private and uncommitted. Do not print their contents in logs or task output.

## Delegate bounded work

- Use subagents proactively for independently completable exploration, implementation, investigation, or test interpretation. Keep the main agent focused on coordination, review, and integration; trivial work can be handled directly.
- Explicitly set `fork_turns` to `"none"` by default. Use a small positive turn count only when recent conversation is necessary; use `"all"` only when the task requires the full history.
- Provide self-contained assignments with the goal, relevant files or areas, constraints, expected result, and applicable checks. Let agents inspect the repository rather than copying large logs or source blocks into their prompts.
- Parallelize only independent work and avoid edits to overlapping files. Request concise findings and verification summaries.
