# Local editor preview and connected slice

[Documentation index](../README.md) · [Development guide](README.md) · [Approved implementation plan](web-editor-plan.md)

This branch has two editor modes. The connected mode is served by the running
Macrowhisper daemon after `macrowhisper --editor` (or `-e`) opens a one-use
authenticated loopback URL. It reads and writes the canonical JSON file through
the manager's revision-checked transaction API. The connected editing scope is
Defaults and Inserts. URL, Shortcut, Shell, and AppleScript names and counts
come from the live snapshot for cross-action context, but their type-specific
panels remain read-only. In the Vite preview, all configuration data is fixture-backed.

The Vite development preview remains fixture-backed when it is opened on its
default port without a live credential. A persistent **Preview mode** notice,
the neutral status control, and preview-qualified **Updating preview…** /
**Updated in preview** field acknowledgements identify these as in-memory
transactions; they never borrow **Connected** or **Saved** from the live editor.
They do not mean that `macrowhisper.json` changed, and reloading resets fixture
configuration. Appearance is a browser-local presentation preference. Defaults
and ordinary action disclosures instead start from a tidy, fully collapsed
overview whenever the user enters that editor; a section that needs repair may
open itself to expose the problem. See the [user editor guide](../editor.md) for
the supported connected behavior and the
[implementation plan](web-editor-plan.md) for the remaining expansion gates.

The preview also shows the **Choose…** control beside folder paths. Opening it
explains the integration boundary without inventing a filesystem selection or
writing a fixture value. In the connected editor, the same control uses the
authenticated daemon bridge to open a native macOS directory panel and saves a
selected path immediately. Cancelling leaves the field unchanged. Manual path
entry keeps the existing blur-save behavior in both modes.

The daemon serves only bundled static resources from the executable's resolved
Homebrew-style share root (or the documented `.build/editor` development
output). It binds `127.0.0.1`, uses port `49172` when available and otherwise an
OS-selected loopback port, and never serves editor JavaScript from the current
working directory. `--editor-url` prints the credential-bearing URL without
opening a browser. The bootstrap fragment is exchanged once, removed from the
address bar, and replaced by a bearer session held in that tab's
`sessionStorage`; a new tab or a daemon restart needs a fresh link.

## Run the interface locally

You can review this prototype while your normal Homebrew or script-installed
Macrowhisper continues running. You do not need a different binary or any files
beside that binary for this milestone.

Use Node 22.12 or later (the pinned Vite version also supports Node 20.19).
Open Terminal and run this once to install the development dependencies:

```bash
cd /path/to/macrowhisper-editor
npm --prefix editor ci
```

Then, whenever you want to review it:

```bash
cd /path/to/macrowhisper-editor
npm --prefix editor run dev -- --open
```

Keep that Terminal window open while reviewing. Vite opens your browser and
prints its loopback address; it chooses another available port if its default
is occupied. You do not need to choose a port or ask an assistant to start it.
Press Control-C in Terminal to stop the preview. Run the same command to start
it again. If a preview is already running, use its printed address or stop it
before starting another copy.

This is a development preview of synthetic configuration, with no access to the
running Macrowhisper service. To test the connected mode, use the signed manual
build workflow in the [development guide](README.md#signed-xcode-build-for-manual-testing)
and open the resulting binary's editor URL. Node is a development/build
dependency only; an installed editor uses bundled static assets.

### Binary and installation status

The connected slice is implemented for the signed local build, release archive,
and script installer. Node is not required to run it. All distribution paths use
the same layout:

```text
<prefix>/bin/macrowhisper
<prefix>/share/macrowhisper/macrowhisper-schema.json
<prefix>/share/macrowhisper/editor/index.html
<prefix>/share/macrowhisper/editor/assets/...
```

The installer infers `<prefix>` as the parent of the selected `BIN_DIR`, so a
custom absolute directory such as `/Applications/My Tools/bin` keeps its spaces
and receives the matching `share/macrowhisper` tree. It stages the binary and
owned resources together, refuses malformed/symlinked resource targets, and
restores the prior pair if replacement fails. It does not install a service or
change the active configuration selection.

Your current service and installation can stay in place throughout this
design review. A later switch to the test daemon needs its own tested startup
and rollback instructions: the existing `--config` option changes the saved
selection and may communicate with your running daemon, so it does not create
an isolated test instance by itself.

## Developer verification

Run the frontend checks from the worktree root:

```bash
npm --prefix editor test
npm --prefix editor run build
swift build --package-path src --scratch-path .build/swiftpm
```

The SwiftPM command is a compile check, not a signed manual-test installation.

Generated frontend build output belongs in `.build/`, outside the maintained source.
The checked-in `editor/src/generated/schema.ts` projection is generated from
`src/macrowhisper-schema.json`, preserving its descriptions, constraints, and
field types. Regenerate it with `node editor/scripts/generate-schema.mjs`;
verify it with `node editor/scripts/generate-schema.mjs --check`. UI labels
and grouping remain separate from this schema projection.
The [configuration](../configuration.md), [actions](../actions.md),
[conditions](../triggers-and-conditions.md), and
[placeholders](../placeholders-and-context.md) references define the underlying
behavior. The interface explains those settings; it does not execute an action
or expand placeholders against private runtime context.

## Review the interactions

- Defaults is a single centered accordion capped at `940px`, with `12px` between flat, subtly bordered section surfaces. It starts fully collapsed whenever the user enters Defaults. Choosing another section closes the current one and opens the new section in the same interaction. Closed sections show only their title and effective-state summary, while the explanatory copy and fields appear after opening with a restrained `180ms` reveal and matching chevron rotation.
- Open Defaults sections give controls a `280px` to `320px` column on desktop and stack labels above controls below `780px`. Insertion, Clipboard, and Scripts and triggers add lightweight internal groups without nested cards. Their root timing values remain visible because action-level overrides can enable the related behavior while inheriting that root value; Return delay also applies to one-shot CLI auto-return. Ordinary native choices keep their `Built-in value` group separate from explicit values. Cross-action references use a searchable keyboard-operable picker that ranks exact and prefix matches before substring matches, keeps built-in/inheritance/no-action choices explicit, and identifies each result's action type. When the built-in value is active, the closed control shows the plain value with an integrated `Built-in` source label; eligible text and numeric fields with an unambiguous shipped fallback expose `Use built-in` only until restoration succeeds.
- Field save acknowledgement is intentionally brief: the live editor keeps `Saving…` while a write is pending and clears `Saved` after roughly two seconds; the fixture preview uses `Updating preview…` and `Updated in preview` instead. Errors persist until resolved. Descriptions use a protected reading measure so long copy wraps before entering the utility rail's visual territory. Status and `Use built-in` occupy a stable, right-aligned trailing rail beside the field label; it is optically aligned with the corresponding desktop control, moves to the lower input baseline when a custom two-control editor is open, and remains visually empty when idle so routine state changes do not resize the row. Revert suppresses the field's blur commit and restores the last accepted value without issuing a write. Save activity is not folded into a section's effective-behavior summary.
- Clearing an ordinary numeric Default and leaving the field—or pressing Enter—saves `null` to use the shipped value. An explicit `0` remains distinct, History keeps its blank `Keep forever` meaning while displaying `days` beside numeric values, and nonempty invalid or negative values continue to surface validation errors.
- The sidebar ends with one compact status control. Healthy state stays quiet; saving, failure, fallback, and disconnection remain explicit. Its popover shows the selected configuration filename, bounded Copy/Reveal actions, and Appearance. The full path stays available through the filename tooltip and Copy path. Failure, fallback, and disconnection add explanatory copy plus a Copy diagnostics action containing the path, schema, revision, generation, fingerprint, and disk state; raw technical metadata is absent from the healthy panel and primary page chrome.
- Start with Defaults, then select an Insert. Open Editor details to compare System, Light, and Dark.
- Change a discrete choice and observe its pending acknowledgement. Type into
  a text control and leave it to commit; there is no global Save button.
- Add and remove an action override, and compare an intentionally empty payload
  with a built-in template. Removing an override must restore Use Defaults, and
  stored sibling settings and conditions must survive payload-mode changes while
  the protected template behavior remains explicit.
- Open Conditions on an empty and configured custom action. Verify its
  plain-language rows, that Add condition offers only Payload and eligible
  explicitly configured settings, and that an unmet setting uses Defaults while
  an unmet Payload rule skips the payload. Confirm inert saved rules remain
  visible with a route to configure their target, and unusual expressions keep
  their exact saved value until deliberate exceptional recovery.
- Insert a placeholder source at the caret, then put the caret inside it to edit
  its transform and regex replacements in the inline inspector. The toolbar,
  textarea, and inspector form one editing boundary.
- Exercise validation, conflict, empty-list, and disconnected fixtures. The
  empty-list fixture is a healthy configuration with no Inserts and presents a
  creation prompt rather than a disk error. A rejected write must retain the
  draft and must not display a successful save.
- Open Triggers on empty, configured, regular-expression, malformed-separator,
  unreadable-expression, and invalid-logic fixtures. Confirm that opening or
  viewing mixed phrase/regex rows never writes, an intentional edit normalizes
  harmless empty separators, explicit Add phrase and Add regular expression
  actions create ordered rows, phrase menus expose exception and removal while
  regex menus expose removal only, excluded saved values retain a visible Except
  badge, and blank pending rows keep their positions through focus changes and
  saves to later rows but disappear on collapse/navigation. Compact muted info notes explain regex behavior and
  exception-only matching beneath the affected group; row and group removal
  remain distinct, and the full-width list stacks cleanly below the desktop
  layout.
- Review narrow windows and keyboard navigation as well as the desktop layout.

The current prototype was inspected at 1440, 1024, 960, 781, 780, and 390 CSS pixels in
light and dark modes. Browser checks covered immediate choice acknowledgement,
blur-only text commits, caret insertion, native Undo after placeholder
insertion, built-in template controls, invalid drafts, and explicit conflict
review/reapply. Conditions were also checked for empty, configured, inert,
unusual-expression, and built-in-retention states without exposing raw syntax in
the normal path. Triggers were checked as a full-width configured list, including
visible voice Beginning/End placement, contextual row actions, persistent Except
badges, heterogeneous phrase/regex editing, pending-row cleanup, separator
cleanup on deliberate edit, unreadable-value recovery, and invalid logic repair. Automated
UI coverage exercises the same save and conflict state transitions, condition
and trigger recovery, and checks that Defaults and Insert field metadata stays
in step with the generated schema projection.

This pass did not complete a Safari, VoiceOver, or 200% browser-zoom audit.
Those remain required before the connected editor is release-ready.

Passing fixture tests does not establish browser authentication, disk
persistence, or watcher integration. Those require the connected slice and an
isolated signed runtime test setup described in the development guide.

## Configuration transaction boundary

`ConfigurationManager` owns persistence. The live browser API submits structured
path segments and an expected revision to that manager; it must not
load a configuration, mutate a shared property, and call `saveConfig()` as
separate operations. Existing socket commands and watch-folder recovery use
the manager's closure transaction entry point.

The revision binds a draft to a manager/configuration generation, an accepted
version, and a disk fingerprint. Disk inspection is separate from the runtime
loader: an invalid, legacy, future-version, or unknown-field file must not be
replaced merely because an editor opens it. Explicit JSON null, an omitted edit
value, and removal are distinct operations. Dots in action names are literal
path components.

A successful write validates the complete typed candidate and publishes the
accepted runtime configuration only after persistence. A rejected candidate
is never published. Reconciling an independently changed file can still update
the runtime view, including its established in-memory fallback for invalid
JSON; the snapshot reports that disk error separately. The callback is installed before the socket begins
accepting commands. CLI removal retains its existing active-action cleanup;
the browser's deletion flow instead requires inbound references to be changed
explicitly before deletion.

A disk fingerprint catches ordinary external edits, including changes that
arrive before a watcher notification. Atomic replacement is not a filesystem
compare-and-swap against an unrelated editor. A noncooperating process can
still write during the final read/replace window; a recoverable pre-write
snapshot mitigates this boundary but does not eliminate it.
The latest pre-write snapshot is retained beside the resolved JSON target as
`<filename>.macrowhisper-backup`; each successful backup replaces that one
owned recovery file. Explicit legacy migration also retains its existing
versioned migration snapshots such as `.backup.pre-v3`. Saving preserves payload strings and numeric
precision rather than applying numeric formatting expressions to JSON text.

Run the transaction regression independently of your service:

```bash
mkdir -p .build/regressions
swiftc -D CONFIGURATION_TRANSACTION_TESTING -parse-as-library \
  src/macrowhisper/Config/AppConfiguration.swift \
  src/macrowhisper/Config/ConfigurationManager.swift \
  src/macrowhisper/Config/ConfigurationTransaction.swift \
  src/Tests/ConfigurationTransactionTestStubs.swift \
  src/Tests/ConfigurationTransactionRegression.swift \
  -o .build/regressions/configuration-transactions
.build/regressions/configuration-transactions
```

This runner uses disposable files and preference/watcher stubs. Its compile
flag enables deterministic write-failure and external-edit hooks that are
absent from the application build. It does not run the daemon or change your
saved configuration selection.

The configuration file watcher serializes its own lifecycle and cancels
delayed restarts when stopped. Its focused `config-watcher-lifecycle` runner
uses disposable files to verify ordinary writes, atomic replacements,
continued observation, stop/restart, and creation of a missing file. See the
[regression commands](README.md#focused-regression-runners).
