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
| Defaults | Review shared behavior in concise section summaries, then open one area at a time to change paths, timing, clipboard, recording, and chain controls. The first visit starts fully collapsed; the browser remembers the last open section or an intentionally collapsed overview. |
| Inserts | Create, duplicate, rename, edit, and delete Insert actions; add only the overrides, triggers, conditions, and links that differ from normal behavior. |
| URLs, Shortcuts, Shell, AppleScript | Names and counts come from the authenticated live snapshot, but the type-specific panels remain read-only until their editor slice is implemented. In the standalone Vite preview, these values are fixtures. |

Names from every action group can still appear in the Defaults and Insert
pickers. This lets an Insert link to an existing action without pretending that
the type-specific editor is finished. The runtime action behavior itself is
unchanged. Manual JSON editing and the existing CLI remain available for URL,
Shortcut, Shell, and AppleScript actions.

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
supplied path. This protects against unrelated websites and users; it is not a
sandbox against software already running as the same macOS user.

## Editing and saving

There is no global Save button. Discrete choices are submitted immediately.
Text fields and textareas—including numeric text fields—save when focus leaves
the control; ordinary numeric Defaults also save on Enter. The interface shows
`Unsaved`, `Saving…`, and a brief `Saved`
acknowledgement that clears after roughly two seconds; a failed request keeps
the draft and offers Revert or Retry until it is resolved. **Revert** discards
the local draft and restores the last successfully saved value without writing
to the configuration. Textarea placeholder
tools are part of the same editing boundary, so choosing a placeholder does not
save halfway through an insertion.

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
the user's shared configuration, **Use Defaults** removes an action-level
override, and **Built-in** identifies the value Macrowhisper ships with for the
specific root setting being edited. Built-in action templates remain named
action modes; they do not become the Built-in value of an unrelated setting.
Dropdowns place the Built-in value first, then separate it visually and
semantically from explicit values or configured actions.
Eligible text and numeric root fields with an unambiguous shipped fallback offer
**Use built-in** only while they differ from that behavior. This control removes
the custom value and saves the change; it is distinct from Revert. Configuration
values retain their JSON meaning:

- `null` or an omitted action override means inherit from Defaults;
- `null` or an omitted ordinary numeric Default means use its shipped value;
- a blank ordinary numeric Default saves that built-in state, while `0` remains
  an explicit numeric zero;
- `""` means an intentional empty string, not inheritance;
- `false`, `0`, and empty payloads are not converted by truthiness rules; and
- built-in action values such as `.autoPaste` and `.none` remain distinct from
  custom text and preserve stored sibling settings.

Insert names are unique across all five action groups. Rename updates inbound
`activeAction` and `nextAction` references in the same transaction. Deletion is
blocked while Defaults or another action still points at the Insert.

Collapsed action sections summarize the behavior that is actually configured.
Opening Insertion behavior, Conditions, or Triggers shows configured entries
first and offers an explicit Add control for another exception. Removing an
override restores **Use Defaults**; removing a condition restores **Always**.
Unsupported or ambiguous raw condition and trigger expressions remain available
for deliberate raw editing and are never silently simplified.

The placeholder menu inserts sources at the caret; Date offers its format as
part of insertion. Put the caret in a recognized placeholder to edit that
placeholder's source, transform, and ordered regex replacements in the inline
inspector below the payload. The raw payload remains canonical and available
for syntax the inspector cannot represent. The editor never expands
placeholders against private live app or clipboard context.

## Changes made elsewhere and invalid files

The editor checks the current snapshot periodically. Clean fields can follow an
external JSON edit, while a dirty field keeps its draft and original baseline.
If the revision changes before a write, the server returns a conflict instead
of overwriting the other edit. Review the current value, then explicitly reload
or reapply the draft. A revision detects ordinary concurrent changes, but it is
not a filesystem compare-and-swap against a process that writes during the
final read/replace window.

An invalid, empty, legacy, future-version, or otherwise unsupported file is
reported separately from the runtime configuration. The daemon may continue
using its in-memory fallback, but opening the editor never turns that fallback
into an automatic replacement of the broken file. The editor shows the disk
diagnostic and blocks unsafe writes; use the existing workflow first:

```bash
macrowhisper --get-config
macrowhisper --validate-config
macrowhisper --update-config
```

Legacy configurations remain read-only in the editor until they have been
migrated. A failed disk write likewise keeps the draft and reports a retryable
error. Changing the selected configuration path with `--set-config` or
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
