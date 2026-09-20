# Local configuration editor

[Documentation index](README.md) · [CLI reference](cli-reference.md) · [Configuration](configuration.md)

Macrowhisper includes a local browser editor for the configuration file. It is
served by the running daemon and is reachable only through a loopback address.
The JSON file remains the canonical configuration: the editor reads it,
validates changes through `ConfigurationManager`, and writes the same file.
There is no second editor database.

## Current scope

The connected, writable slice is deliberately small and complete:

| Area | Connected behavior |
| --- | --- |
| Defaults | Review shared behavior in concise section summaries, then open one area at a time to change paths, timing, clipboard, recording, and chain controls. Defaults starts fully collapsed whenever you enter it. |
| Inserts | Create, duplicate, rename, edit, and delete Insert actions; add only the overrides, triggers, conditions, and links that differ from normal behavior. Conditions use plain-language inside/outside choices and can target Payload or an eligible setting that the action explicitly configures. |
| URLs, Shortcuts, Shell, AppleScript | Names and counts come from the authenticated live snapshot, but the type-specific panels remain read-only until their editor slice is implemented. In the standalone Vite preview, these values are fixtures. |

Names from every action group can still appear in the Defaults and Insert
pickers. These pickers are searchable by action name and type, keep the
no-action/inheritance choices explicit, and support arrow-key selection. This
lets an Insert link to an existing action without pretending that the
type-specific editor is finished. The runtime action behavior itself is
unchanged. Manual JSON editing and the existing CLI remain available for URL,
Shortcut, Shell, and AppleScript actions.

Voice phrase rows can match at the **Beginning** or **End** of a dictation.
End placement writes the literal suffix syntax (`*phrase`) for you; exclusions
remain a separate checkbox and raw regex remains available as an advanced mode.

## Open the editor

The daemon must already be running. The editor commands do not start another
daemon, switch configuration files, install a service, or change launchd:

```bash
macrowhisper --start-service
macrowhisper --editor
```

`-e` is an alias for `--editor`. It requests a fresh authenticated link,
opens that link in the default browser, and prints the credential-free address
that was opened, for example `http://127.0.0.1:49172/`. If the browser cannot
be opened, copy a fresh link instead:

```bash
macrowhisper --editor-url
```

`--editor-url` prints only the credential-bearing URL to standard output; it
does not open a browser. Errors go to standard error and return a nonzero
status. A URL from either command is short-lived and single-use for the initial
browser exchange, so do not paste it into tickets, shell history, or messages.
If the command reports that no daemon can provide a URL, start the service and
try again. A failed editor listener does not stop the transcription daemon.

## Local authentication and sessions

The daemon tries loopback port `49172` first. If that port is occupied, the OS
assigns another available loopback port and the fresh URL includes the actual
port. There is no configuration setting for this port. The server binds to
`127.0.0.1`, not to the network interfaces.

The CLI obtains the bootstrap credential through Macrowhisper's same-user Unix
socket. The socket is checked for ownership and type, and the daemon checks the
peer UID before issuing a credential. The browser receives the bootstrap token
in a URL fragment, exchanges it with the local server, and removes the fragment
from the address bar with `history.replaceState`; the token is not sent as a
request path or query parameter.

The exchange creates an origin-scoped bearer session. The editor keeps that
session in the browser tab's `sessionStorage`, sends it explicitly on protected
requests, and does not use cookies or local storage for the credential. Sessions
last up to eight hours and are invalidated when the editor server or daemon is
restarted. Reloading the clean URL in the same tab normally keeps the session;
opening a new tab, using a bookmark, or letting the session expire requires a
fresh `macrowhisper --editor` or `macrowhisper --editor-url` link.

Reads and writes require the authenticated session. Writes additionally
require the exact loopback `Host`, the editor `Origin`, and JSON content. The
editor has no remote-access, action-execution, shell-evaluation, or arbitrary
file-read API. The folder-picker bridge can only present one native directory
panel and return the path the user explicitly selects; it cannot list or read a
supplied path. **Reveal** is similarly bounded: it accepts no browser
path and can reveal only the configuration currently selected by the manager.
This protects against unrelated websites and users; it is not a sandbox against
software already running as the same macOS user.

## Editing and saving

There is no global Save button. Discrete choices are submitted immediately.
Text fields and textareas—including numeric text fields—save when focus leaves
the control; ordinary numeric Defaults also save on Enter. The interface shows
`Unsaved`, `Saving…`, and a brief `Saved`
acknowledgement that clears after roughly two seconds; a failed request keeps
the draft and offers Revert or Retry until it is resolved. **Revert** discards
the local draft and restores the last successfully saved value without writing
to the configuration. Invalid numeric drafts stay local and show a concise
field-level error beneath their editor; they are not sent as malformed JSON.
Textarea placeholder
tools are part of the same editing boundary, so choosing a placeholder does not
save halfway through an insertion.

The standalone Vite development preview uses deliberately different language:
it shows **Preview mode**, **Updating preview…**, and **Updated in preview**.
Its persistent notice and Editor details both explain that the sample values
stay in memory, reset on reload, and do not write `macrowhisper.json`. The live
editor alone uses **Connected** and **Saved** for an acknowledged canonical
configuration write.

Long Defaults sections are divided by quiet internal headings so related
decisions scan together without adding nested panels. Root timing values remain
visible beside their related behaviors because they can still be inherited by
action-level overrides. **Return delay** also controls the Return press forced
by one-shot CLI auto-return, even when the default **Press Return after insert**
setting is off.

The compact status control at the bottom of the navigation stays quiet while
the editor is connected, changes to Saving or Not saved when a write needs
attention, and gives disconnected or runtime-fallback states semantic warning
color in addition to text. Open it for the current configuration filename,
**Copy path**, **Reveal**, and Appearance. The full path remains available from
the filename tooltip and Copy path without occupying the normal panel. Healthy
connection copy is omitted because the trigger already communicates that state.
When the editor is disconnected, using runtime fallback, or cannot save, the
panel adds an explanation and **Copy diagnostics**. Those diagnostics include
the full path, schema version, revision, generation, fingerprint, and disk state
for troubleshooting; the revision is concurrency metadata, not editable history.

Folder path controls also offer **Choose…**. In a connected editor this opens a
native macOS directory picker through the local daemon. Choosing a directory
saves its path immediately; cancelling leaves the current value and any typed
draft unchanged. You can still type or paste a path. The Superwhisper folder is
the parent that contains its recordings, while **Move recording** accepts the
destination directory. Paths under the current user's home folder are stored
in the shorter `~/…` form.

Every mutation includes the revision that was read and is applied as one typed,
validated transaction. The revision identifies the daemon/configuration
generation, accepted version, and on-disk fingerprint. This prevents an older
browser response from silently replacing a newer change.

The editor distinguishes three related concepts in its labels: **Defaults** are
the user's shared configuration, removing an entry under **Action overrides**
resumes inheritance from those Defaults, and **Built-in** identifies the value
Macrowhisper ships with for the specific root setting being edited. Built-in
action templates remain named action modes; they do not become the Built-in
value of an unrelated setting.
Ordinary dropdowns place the Built-in value first, then separate it visually
and semantically from explicit values. Searchable action pickers use the same
grouping for built-in, inheritance, no-action, and configured-action choices.
Eligible text and numeric root fields with an unambiguous shipped fallback offer
**Use built-in** only while they differ from that behavior. This control removes
the custom value and saves the change; it is distinct from Revert. Configuration
values retain their JSON meaning:

- `null` or an omitted action override means inherit from Defaults;
- `null` or an omitted ordinary numeric Default means use its shipped value;
- a blank ordinary numeric Default saves that built-in state, while `0` remains
  an explicit numeric zero;
- History retention displays its value in days; leaving it blank means keep
  forever;
- `""` means an intentional empty string, not inheritance;
- `false`, `0`, and empty payloads are not converted by truthiness rules; and
- built-in action values such as `.autoPaste` and `.none` remain distinct from
  custom text and preserve stored sibling settings. Stored conditions are also
  retained, but the protected built-in payload behavior governs until the
  action returns to **Insert custom text**.

Insert names are unique across all five action groups. Rename updates inbound
`activeAction` and `nextAction` references in the same transaction. Deletion is
blocked while Defaults or another action still points at the Insert.

Collapsed action sections summarize the behavior that is actually configured.
Placeholder review, Action overrides, Conditions, Triggers, and Chaining form
one coordinated disclosure set: opening one closes the previously open section,
and choosing another action resets the set. Opening a settings section shows
configured entries first and offers an explicit Add control for another
exception. Conditions offer **Payload** plus eligible settings that this action
explicitly configures; inherited-only settings do not appear in that menu. A
newly added override or condition asks for an explicit value before it changes
the configuration. Its choices identify the value that currently comes from
**Defaults**, but choosing that value still saves an explicit override. When an
inherited icon or recording destination is custom, choosing **Custom** starts
from that inherited value so it can be pinned unchanged or edited. Numeric
overrides similarly open an editable **Custom** field prefilled from Defaults,
whether the user chooses the displayed current value or **Custom** directly.
The Add override menu and established override rows use the same alphabetical
label order. Newly added rows keep their insertion order while Action overrides
stays open, including when a later row receives its value before an earlier
one. Closing the section, switching to another disclosure, or leaving the
action discards untouched rows that still have no value and returns saved rows
to alphabetical order. These untouched rows are local editing state: they are
not written to the configuration and also disappear after reload.
Removing an override resumes inheritance from **Defaults**; removing a condition
removes that inside/outside rule. When a setting's condition does not match, the
setting uses **Defaults**; when a Payload condition does not match, the payload
is skipped. If a saved condition targets a setting the action no longer
configures, the editor keeps and displays it, explains that it currently has no
effect, and links to the place where the target can be configured.

The normal Conditions interface never exposes pipe-separated tokens. Repeated,
contradictory, malformed, or unsupported condition expressions remain
byte-for-byte intact and enter an exceptional recovery state instead of being
silently simplified. The saved expression is shown there for diagnosis, and a
deliberate recovery action can replace it with the equivalent supported visual
rules. Trigger expressions keep their existing advanced editing behavior.

The placeholder menu presents categorized result, captured-context, workflow,
recording-folder, and Date sources as compact full-width rows. Each row keeps
the value name and its purpose together in a clear hierarchy without repeating
raw placeholder syntax; common Date formats remain direct choices. The menu
opens without preselecting a value. Pointer movement stays visually neutral;
keyboard navigation adds a quiet selection state only after an arrow, Home, or
End key. Either click or keyboard activation inserts the chosen value. Beneath
the payload, a stable review row reports every
complete placeholder occurrence without reacting to caret movement. Inserting
a placeholder updates the count but leaves review collapsed. Expand the row and
choose one occurrence to inspect it; repeated placeholders are edited
independently. Choose the selected occurrence again to close its inspector while
leaving the occurrence list visible.

The occurrence inspector exposes the runtime's supported transforms and
ordered regex replacements. Replacement patterns and values accept multiple
lines, stages can be reordered with compact symbolic controls, and capture
groups may be reused or transformed with the syntax documented in
[Placeholders and context](placeholders-and-context.md).
The replacement helper edits semantic values rather than JSON serialization.
An actual Return stays visible as a line break. Typing `\n` also means a line
break, while `\\n` means the literal characters `\n`. The surrounding Custom
text uses a hybrid presentation: ordinary action text shows semantic line
breaks as real lines, while every complete `{{...}}` placeholder stays inline
and shows its canonical `\n` spelling. If you press Return while hand-writing a
complete placeholder, the editor leaves it under the caret until editing ends,
then saves it as `\n` and collapses that placeholder back to one line. An
unfinished placeholder remains ordinary multiline text until its closing
braces are present. In ordinary text, `\\n` remains the visible spelling for a
literal backslash followed by `n`. When the configuration is saved, JSON adds
its own escaping automatically; users never need to type JSON's extra
backslashes into the editor.
The inspector source selector uses the same built-in and direct Date choices as
the insertion menu. Custom metadata keys, dot paths, and XML tags appear as
fixed source identities: changing the source remains a deliberate raw-text
edit, while the inspector still offers the same transform and replacement
controls. `raw:` and `json:` prefixes are preserved through inspector edits and
remain manually editable in the payload. Optional indexes for action results
and recording folders accept only digits; an invalid hand-written value stays
intact and is flagged until corrected. Structurally unsupported syntax stays
visible as an exact raw occurrence and is never rewritten by the visual
inspector. The raw payload remains canonical, and the editor never expands
placeholders against private live app or clipboard context.

## Changes made elsewhere and invalid files

The editor checks the current snapshot periodically. Clean fields can follow an
external JSON edit, while a dirty field keeps its draft and original baseline.
If the revision changes before a write, the server returns a conflict instead
of overwriting the other edit. Review the current value, then explicitly reload
or reapply the draft. A revision detects ordinary concurrent changes, but it is
not a filesystem compare-and-swap against a process that writes during the
final read/replace window.

An invalid, empty, future-version, or otherwise unsupported file is
reported separately from the runtime configuration. The daemon may continue
using its in-memory fallback, but opening the editor never turns that fallback
into an automatic replacement of the broken file. The editor shows the disk
diagnostic and blocks unsafe writes; use the existing workflow first:

```bash
macrowhisper --get-config
macrowhisper --validate-config
macrowhisper --update-config
```

Version 1 and 2 configurations also remain read-only in the editor. The sidebar
status changes to **Update required**, and a persistent explanation offers
**Update to version 3**, **Copy update command**, and the existing configuration
path controls. The update is explicit even when `autoUpdateConfig` is `false`:
it migrates that file once without enabling future automatic updates, refreshes
the snapshot, and unlocks editing. The same operation is available as
`macrowhisper --update-config`.

A failed disk write likewise keeps the draft and reports a retryable error.
Changing the selected configuration path with `--set-config` or
`--reset-config` starts a new configuration generation; refresh the editor
before applying a draft from the previous path.

## Installation and resources

Node.js is needed to build the editor during development or a release, not to
run an installed editor. Release archives and installations use this layout:

```text
bin/macrowhisper
share/macrowhisper/macrowhisper-schema.json
share/macrowhisper/editor/index.html
share/macrowhisper/editor/assets/...
```

Homebrew installs the executable under its `bin` directory and the schema and
editor under the matching `share/macrowhisper` directory. The script installer
uses the same layout: if `BIN_DIR` is `/usr/local/bin` (the default), resources
go to `/usr/local/share/macrowhisper`; if it is a custom absolute path such as
`/Users/me/Tools/bin`, resources go to
`/Users/me/Tools/share/macrowhisper`. Paths containing spaces are supported.
The installer verifies the archive checksum and required paths, stages the
complete resource tree, and replaces only the owned binary and resource root.
When upgrading an older script installation, it also removes the obsolete
owned schema beside the binary so that the shared schema cannot be shadowed by
a stale copy; a failed replacement restores all prior owned files.

For a signed local build, follow the [development guide](development/README.md#signed-xcode-build-for-manual-testing).
It builds the frontend first and leaves the editor beside the signed binary;
it does not install files, start or modify a service, or overwrite a Homebrew
installation.

## Limitations

URL, Shortcut, Shell, and AppleScript type-specific editing is the next editor
slice. Until that work lands, use the [action reference](actions.md) and the
canonical JSON file or CLI for those actions. The editor also does not execute
actions, preview private runtime context, or replace manual validation and
backup practices.
