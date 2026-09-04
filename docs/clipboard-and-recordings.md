# Clipboard and Recordings

[← Documentation index](README.md) · [Placeholders and context](placeholders-and-context.md) · [Runtime](runtime.md)

## Clipboard Behavior

Most users can skip this section. It matters mainly for debugging and advanced setups.

### Why Macrowhisper handles the clipboard carefully

Superwhisper and Macrowhisper may touch the clipboard near the same time. Macrowhisper's clipboard system exists to reduce race conditions and prevent stale clipboard values from leaking into later actions.

### The main timing values

- a short wait for Superwhisper clipboard sync before the first action in a chain: `0.1s`
- a recent-activity window to avoid unnecessary waiting: `0.5s`
- a startup replay guard that extends `5.0s` after the recording folder appears; when buffered history is available, the same-content check also examines up to `3.0s` before that point. Same-content replays in the guard are ignored while different content remains eligible. The guard stays active after audio starts and closes when action execution starts. A separate `1.0s` adjacent-transient rule applies only when the session began outside an input field
- the user-controlled pre-recording capture window from `clipboardBuffer`

Capture is bounded to 50 clipboard operations per session and 100 entries in the app-wide rolling history; older observations are dropped.

### The settings that matter most

- `restoreClipboard`
- `clipboardBuffer`
- `clipboardStacking`
- `clipboardAttachments`
- `clipboardIgnore`

How they work together:

- `clipboardBuffer = 0` turns off pre-recording clipboard capture
- `clipboardStacking = false` lets the most recent eligible clipboard operation control both text context and attachment handoff
- `clipboardStacking = true` returns all eligible text snippets and accumulates eligible attachment operations in order
- an action-level `clipboardStacking` value overrides the default for the full chain; `null` or omission inherits the default
- `clipboardAttachments = false` preserves the existing string-only `{{clipboardContext}}` projection
- `clipboardAttachments = true` enables supported attachment handoff for the full root action chain; `null` or omission inherits the default
- `restoreClipboard = true` permits original-clipboard restoration at finalization; ordinary action chains restore on their final step even when no ESC is simulated, while auto-return uses the effective ESC path

Use `macrowhisper --reset-clipboard` when you copied the wrong content or no longer want previously captured clipboard context sent to the action. During a recording it resets that recording's shared clipboard-context session; outside a recording it resets the pre-recording buffer. Any new copy made afterward can be captured normally.

For CLI execution (`--exec-action` and `--run-auto`):

- Macrowhisper captures one clipboard snapshot at chain start
- it restores once at the end, not after every insert step
- it only restores if a step in that CLI chain actually wrote to the clipboard
- pure URL / shell / AppleScript / Shortcut chains do not perform a fake restore write

#### Attachment handoff

Attachment handoff is manual-paste-only and is separate from both the string `{{clipboardContext}}` value and the original-clipboard snapshot. `clipboardAttachments = true` enables supported file/image handoff even when the action does not contain `{{clipboardContext}}`. The placeholder remains string-only; an attachment-only clipboard operation therefore expands to an empty value when the placeholder is present.

The effective root action setting applies to the full chain. When attachments are enabled, any successfully executed action path is eligible; no context-placeholder consumer is required. On successful completion, an eligible attachment handoff is the final clipboard outcome even when the final step has `restoreClipboard: false`. Failed, cancelled, or structurally invalid chains never hand attachments off. If stacking is disabled and a text copy follows an attachment copy, the later text operation wins, no older attachment is handed off, and normal clipboard-restoration behavior applies.

Clipboard stacking is operation-based: one stable pasteboard operation (`NSPasteboard.changeCount`) is one history operation, with its ordered representations kept together. With stacking disabled, only the latest eligible operation is selected. With stacking enabled, text operations contribute to the string context and attachment operations contribute to one ordered file handoff. Reset boundaries, `clipboardIgnore`, the pre-recording buffer, internal-write suppression, overlap handling, and chain execution-group ownership apply to both.

For reliable multi-attachment paste, final handoff publishes every attachment in one eager Finder-compatible filename array. AppKit synthesizes the public file-URL flavors from that array without depending on lazy NSURL pasteboard writers. Existing files remain borrowed URLs. Raw images stay in bounded memory during capture and are written only when a successful action reaches final handoff: PNG representations are validated and atomically materialized unchanged, while TIFF-only data is transcoded to PNG because many upload targets do not consistently accept TIFF files. If `clipboardBuffer` is active and at least one configured action can enable attachments, bounded raw image bytes may be retained during pre-recording monitoring, but no cache file is created unless a later successful action hands that image off. If the final clipboard commit cannot be completed safely, the attempted generation is discarded.

Some image copies, including an application icon copied from Finder's Get Info window, expose TIFF through the pasteboard as a whole even though the individual item advertises only an icon format. Macrowhisper captures that supported PNG/TIFF representation when it can be attributed to a single item, then uses the same image handoff and PNG conversion described above. File URLs retain priority over image previews, and a pasteboard-level fallback never replaces or duplicates an ordered list of multiple items.

If image data arrives after an initially empty or unavailable read of an accepted copy, monitoring can fill in that same operation without requiring another copy. This preserves its original capture time and app attribution, works during recording with `clipboardBuffer: 0`, and does not restore image data deliberately dropped by retention limits.

Generated images are stored in a private `~/Library/Caches/Macrowhisper/ClipboardAttachments` generation, stay available while the clipboard references an existing generated file (including across a service restart), and remain cached for 24 hours after clipboard ownership ends. A 1 GiB cleanup ceiling removes the oldest unreferenced generations first; active and valid current-clipboard generations remain protected even if that temporarily leaves the cache above the ceiling. Cleanup revalidates clipboard ownership before deletion and does not let a stale path to a missing file preserve debris indefinitely. A private ownership marker identifies managed generations; cleanup also reclaims expired empty UUID directories that can be left if generation creation is interrupted, while nonempty unmarked and non-UUID directories are left alone.

Each managed generation directory is one cleanup unit. Files that another tool creates inside that directory share its retention and are removed with it. A file moved or copied outside the generation is never a cache-cleanup target. Original-clipboard restoration remains representation-native and does not use this materialization path.

Faithful supported representations are ordered text, file URLs, PNG, and TIFF. Files remain URLs and are not read into memory. Images are bounded to 64 MiB each and 192 MiB in aggregate; the oldest pre-recording image data is evicted before active-session or original-snapshot data. An oversized attachment remains classified as an attachment, never falls back to incidental text, and produces a privacy-safe diagnostic without handing off that unavailable item. If a complete original snapshot cannot be retained within those bounds, Macrowhisper refuses a misleading partial/text-only restoration, leaves the current clipboard untouched, and records a diagnostic. Arbitrary private pasteboard types are out of scope.

Pure CLI execution and `--copy-action` do not perform attachment handoff. CLI original-clipboard restoration may still preserve the supported representations.

### `clipboardIgnore` example

```json
"clipboardIgnore": "Arc|Bitwarden|com.apple.passwords"
```

This prevents noisy clipboard events from those apps from polluting `{{clipboardContext}}`.

Macrowhisper also respects clipboard items marked as concealed.

### Best practices

1. Keep Superwhisper clipboard restoration off.
2. Start with `clipboardBuffer: 5` if you use `{{clipboardContext}}`.
3. Turn on `clipboardStacking` globally or only for the actions that actually need several clipboard items.
4. Use `clipboardIgnore` for password managers and other noisy apps.
5. If clipboard behavior feels racy, try a small `actionDelay` such as `0.05` to `0.2`.

### Async execution and clipboard

The short version:

- Macrowhisper is optimized to stay responsive
- shell, AppleScript, and Shortcut actions launch asynchronously by default
- if you need Macrowhisper to wait, set `scriptAsync: false`
- when restoration is effective, it happens according to `restoreClipboardDelay` on the final chain step

Because Superwhisper always interacts with the clipboard, the safest way to pass earlier clipboard content into scripts is usually to use `{{clipboardContext}}` instead of reading the live clipboard during script execution.

---

## Recording File Handling

### `moveTo`

Supported values:

- a folder path: move the processed recording folder there, overriding the default
- `.delete`: delete the processed folder, overriding the default
- `""` at the action level: keep the folder in place, even when `defaults.moveTo` is nonempty
- `null` or omission at the action level: inherit from `defaults.moveTo`

### `history`

`defaults.history` controls retention cleanup:

- `null`: keep everything
- `0`: keep only the newest recording folder
- positive integer: keep the last N days

Cleanup is scheduled asynchronously after about 30 seconds, and requests are coalesced so it runs at most once per 24 hours in the running process; see [runtime recovery and cleanup](runtime.md#recovery-and-cleanup).

---
