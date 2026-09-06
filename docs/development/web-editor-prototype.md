# Local editor prototype

[Documentation index](../README.md) · [Development guide](README.md) · [Approved implementation plan](web-editor-plan.md)

This experimental branch contains the first Defaults/Insert interface and a
configuration transaction foundation. The browser uses synthetic fixtures held
in memory. Its save indicators acknowledge fixture transactions; they do not
mean that your `macrowhisper.json` has changed. Reloading the page resets fixture
configuration. Only the appearance preference is retained in browser storage.

The daemon does not yet serve this interface. `--editor`, `-e`, and
`--editor-url` are still planned commands. Authentication, live synchronization,
resource packaging, and connected browser persistence remain separate gates in
the [implementation plan](web-editor-plan.md#implementation-sequence-and-completion-gates).

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

This is a development preview of synthetic configuration, with no access to the running Macrowhisper service.
Node is a development dependency; the planned installed interface will use
bundled static assets.

### Binary and installation status

Compiling this branch today does not connect the webpage to Macrowhisper.
The manager transaction code is implemented independently of the browser;
the local server, authentication, opening commands, and resource packaging
are later integration work. Copying this prototype's files beside your
installed binary will not enable an editor.

For the connected milestone, a signed local test binary and matching static
assets will be prepared using the [signed build workflow](README.md#signed-xcode-build-for-manual-testing).
Node will not be required to run the installed editor. The planned Homebrew
layout keeps resources under `share/macrowhisper/editor/`; the manual archive
and script installer must also install the matching resources. Those layouts
still need implementation and package tests, so there is no supported
installation or Homebrew replacement procedure for the editor yet.
The current script installer copies only the binary and schema beside one
another in its binary directory; it does not copy an editor directory.

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

- Start with Defaults, then select an Insert. Compare System, Light, and Dark.
- Change a discrete choice and observe its pending acknowledgement. Type into
  a text control and leave it to commit; there is no global Save button.
- Return an override to Default, and compare an intentionally empty payload
  with a built-in template. Stored sibling settings must survive mode changes.
- Place the caret inside a payload and insert a placeholder. The toolbar and
  textarea form one editing boundary.
- Exercise validation, conflict, empty-list, and disconnected fixtures. A
  rejected write must retain the draft and must not display a successful save.
- Review narrow windows and keyboard navigation as well as the desktop layout.

The current prototype was inspected at 1440, 1024, 768, and 390 CSS pixels in
light and dark modes. Browser checks covered immediate choice acknowledgement,
blur-only text commits, caret insertion, native Undo after placeholder
insertion, built-in template controls, invalid drafts, and explicit conflict
review/reapply. Automated UI coverage exercises the same save and conflict
state transitions and checks that Defaults and Insert field metadata stays in
step with the generated schema projection.

This pass did not complete a Safari, VoiceOver, or 200% browser-zoom audit.
Those remain required before the connected editor is release-ready.

Passing fixture tests does not establish browser authentication, disk
persistence, or watcher integration. Those require the connected slice and an
isolated signed runtime test setup described in the development guide.

## Configuration transaction boundary

`ConfigurationManager` owns persistence. The future browser API must submit
structured path segments and an expected revision to that manager; it must not
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
`.backup.pre-v2` snapshot. Saving preserves payload strings and numeric
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
