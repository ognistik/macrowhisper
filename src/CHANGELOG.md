# Changelog

## 2026-03-05

### Responsiveness recovery
- Reverted selected-text accessibility capture to the previous focused-element flow (fast path `AXSelectedText` + single-range fallback).
- Removed selected-text candidate expansion that traversed window/web-area trees.
- Enforced strict browser allowlist for active URL capture (`triggerUrls`, `{{frontAppUrl}}`, and `ACTIVE URL` in `{{appContext}}`).
- Removed unknown-app URL fallback crawling to avoid latency spikes in non-browser apps.

### Notes
- Supported browser allowlist: Safari, Chrome, Firefox, Edge, Opera, Brave, Vivaldi, Arc, Chromium.
- Unsupported browsers/apps now return empty URL quickly; add support by opening an issue.
