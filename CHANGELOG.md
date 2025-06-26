# CHANGELOG

## UNRELEASED
### Changed
* Improved trigger logic for "and"
  * *Fixed `and` logic bug where empty triggers would incorrectly match everything. Now `and` and `or` both ignore empty triggers, only evaluating those with actual values.*

---
## [v1.1.2](https://github.com/ognistik/macrowhisper/releases/tag/v1.1.2)
### Changed
* Removed extra notification for syntax errors on JSON files.
* Fix for repeated update dialogs

---
## [v1.1.1](https://github.com/ognistik/macrowhisper/releases/tag/v1.1.1) - 2025/06/25
### Changed
* The configuration file watcher has been improved.
    It now supports apps that create new files and delete originals during editing, in addition to direct file modifications. This means better compatibility with more text editors beyond VS Code or similar.

---
## [v1.1.0](https://github.com/ognistik/macrowhisper/releases/tag/v1.1.0) - 2025/06/24
* The CLI app goes live!