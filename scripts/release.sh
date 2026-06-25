#!/bin/sh
set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
PROJECT_PATH="$ROOT_DIR/src/macrowhisper.xcodeproj"
SCHEME="macrowhisper"
MAIN_SWIFT="$ROOT_DIR/src/macrowhisper/main.swift"
CHANGELOG="$ROOT_DIR/CHANGELOG.md"
VERSIONS_JSON="$ROOT_DIR/versions.json"
INSTALL_SCRIPT="$ROOT_DIR/scripts/install.sh"
SCHEMA_PATH="$ROOT_DIR/src/macrowhisper-schema.json"
ENV_FILE="$ROOT_DIR/.release.env"
GITHUB_REPO="${GITHUB_REPO:-ognistik/macrowhisper}"
FORMULA_PATH="${HOMEBREW_FORMULA:-$ROOT_DIR/../homebrew-formulae/macrowhisper.rb}"
RELEASE_ROOT="$ROOT_DIR/.build/release"

usage() {
  cat <<'EOF'
Usage:
  scripts/release.sh prepare VERSION
  scripts/release.sh preview [--binary PATH]
  scripts/release.sh draft VERSION [--dry-run]
  scripts/release.sh publish VERSION [--yes]

Commands:
  prepare   Update the changelog, app version, and versions.json locally.
  preview   Show the update dialog using version and description from versions.json.
  draft     Build, sign, notarize, package, update download metadata, and create
            a GitHub draft release named and tagged vVERSION.
  publish   Publish the reviewed GitHub draft, promote the release commit to
            main, and commit/push the Homebrew formula update.

VERSION must use three numeric components, for example 2.0.4 (without a v).
EOF
}

fail() {
  echo "Error: $*" >&2
  exit 1
}

info() {
  echo "==> $*"
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "Missing required command: $1"
}

validate_version() {
  case "$1" in
    ''|*[!0-9.]*|.*|*.|*..*) fail "Invalid version '$1'. Expected a value such as 2.0.4." ;;
  esac

  old_ifs=$IFS
  IFS=.
  set -- $1
  IFS=$old_ifs
  [ "$#" -eq 3 ] || fail "Invalid version '$1'. Expected exactly three numeric components."
}

ensure_repo() {
  git -C "$ROOT_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
    || fail "Not a Git repository: $ROOT_DIR"
}

ensure_on_main() {
  branch="$(git -C "$ROOT_DIR" branch --show-current)"
  [ "$branch" = "main" ] || fail "Release preparation must start on main; current branch is '${branch:-detached}'."
}

ensure_clean_start() {
  [ -z "$(git -C "$ROOT_DIR" status --porcelain)" ] \
    || fail "The Macrowhisper working tree must be clean before prepare."
}

ensure_local_file_ignored() {
  path="$1"
  git -C "$ROOT_DIR" check-ignore -q "$path" \
    || fail "$path is not ignored. Add it to .git/info/exclude before continuing."
}

json_value() {
  key="$1"
  /usr/bin/plutil -extract "$key" raw -o - "$VERSIONS_JSON"
}

app_source_version() {
  sed -n 's/^let APP_VERSION = "\([0-9][0-9.]*\)"$/\1/p' "$MAIN_SWIFT" | head -n 1
}

release_heading() {
  version="$1"
  printf '## [v%s](https://github.com/ognistik/macrowhisper/releases/tag/v%s)' "$version" "$version"
}

extract_release_section() {
  version="$1"
  heading="$(release_heading "$version")"
  awk -v heading="$heading" '
    index($0, heading) == 1 { in_release = 1; next }
    in_release && $0 == "---" { exit }
    in_release { print }
  ' "$CHANGELOG" | sed '/./,$!d'
}

seed_update_description() {
  version="$1"
  extract_release_section "$version" | awk '
    /^###[[:space:]]/ { next }
    { print }
  ' | sed '/./,$!d'
}

prepare_release() {
  version="$1"
  validate_version "$version"
  ensure_repo
  ensure_on_main
  ensure_clean_start

  current_version="$(app_source_version)"
  [ -n "$current_version" ] || fail "Could not read APP_VERSION from $MAIN_SWIFT"
  [ "$current_version" != "$version" ] || fail "APP_VERSION is already $version."
  awk -v current="$current_version" -v candidate="$version" '
    BEGIN {
      split(current, a, "."); split(candidate, b, ".")
      for (i = 1; i <= 3; i++) {
        if ((b[i] + 0) > (a[i] + 0)) exit 0
        if ((b[i] + 0) < (a[i] + 0)) exit 1
      }
      exit 1
    }
  ' || fail "Version $version must be newer than $current_version."
  ! grep -Fq "$(release_heading "$version")" "$CHANGELOG" \
    || fail "The changelog already contains v$version."
  grep -q '^## UNRELEASED$' "$CHANGELOG" || fail "CHANGELOG.md has no UNRELEASED section."

  release_date="$(date '+%Y/%m/%d')"
  tmp_changelog="$(mktemp "${TMPDIR:-/tmp}/macrowhisper-changelog.XXXXXX")"
  tmp_main="$(mktemp "${TMPDIR:-/tmp}/macrowhisper-main.XXXXXX")"
  trap 'rm -f "$tmp_changelog" "$tmp_main"' EXIT INT TERM

  awk -v version="$version" -v release_date="$release_date" '
    $0 == "## UNRELEASED" && !done {
      print
      print ""
      print "---"
      print "## [v" version "](https://github.com/ognistik/macrowhisper/releases/tag/v" version ") - " release_date
      done = 1
      next
    }
    { print }
  ' "$CHANGELOG" > "$tmp_changelog"

  sed "s/^let APP_VERSION = \"$current_version\"$/let APP_VERSION = \"$version\"/" \
    "$MAIN_SWIFT" > "$tmp_main"

  cp "$tmp_changelog" "$CHANGELOG"
  cp "$tmp_main" "$MAIN_SWIFT"
  rm -f "$tmp_changelog" "$tmp_main"
  trap - EXIT INT TERM

  description="$(seed_update_description "$version")"
  [ -n "$description" ] || description="Bug fixes and improvements. See the full release notes for details."
  /usr/bin/plutil -replace version -string "$version" "$VERSIONS_JSON"
  /usr/bin/plutil -replace description -string "$description" "$VERSIONS_JSON"
  /usr/bin/plutil -convert json -r "$VERSIONS_JSON"
  info "Prepared v$version"
  echo "Review these files before continuing:"
  echo "  $CHANGELOG"
  echo "  $MAIN_SWIFT"
  echo "  $VERSIONS_JSON"
  echo
  echo "Refine the short update-dialog description, then preview it with:"
  echo "  scripts/release.sh preview"
}

preview_release() {
  binary="${MACROWHISPER_BIN:-}"
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --binary)
        [ "$#" -ge 2 ] || fail "Missing value for --binary"
        binary="$2"
        shift 2
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *) fail "Unknown preview option: $1" ;;
    esac
  done

  require_command /usr/bin/plutil
  version="$(json_value version)"
  description="$(json_value description)"
  validate_version "$version"
  [ -n "$description" ] || fail "versions.json has an empty description."

  if [ -z "$binary" ]; then
    binary="$(command -v macrowhisper 2>/dev/null || true)"
  fi
  [ -n "$binary" ] || fail "Could not find macrowhisper. Pass --binary PATH or set MACROWHISPER_BIN."
  [ -x "$binary" ] || fail "Macrowhisper is not executable: $binary"

  info "Previewing the update dialog for v$version"
  "$binary" \
    --test-update-dialog \
    --test-version "$version" \
    --test-description "$description"
}

load_release_env() {
  if [ -f "$ENV_FILE" ]; then
    ensure_local_file_ignored .release.env
    # shellcheck disable=SC1090
    . "$ENV_FILE"
  fi
  : "${DEVELOPER_ID_APPLICATION:?DEVELOPER_ID_APPLICATION is missing from .release.env}"
  : "${NOTARYTOOL_PROFILE:?NOTARYTOOL_PROFILE is missing from .release.env}"
  export DEVELOPER_ID_APPLICATION NOTARYTOOL_PROFILE
  FORMULA_PATH="${HOMEBREW_FORMULA:-$FORMULA_PATH}"
}

verify_prepared_release() {
  version="$1"
  validate_version "$version"
  [ "$(app_source_version)" = "$version" ] || fail "APP_VERSION does not equal $version. Run prepare first."
  [ "$(json_value version)" = "$version" ] || fail "versions.json does not contain version $version."
  [ -n "$(json_value description)" ] || fail "versions.json has an empty description."
  grep -Fq "$(release_heading "$version")" "$CHANGELOG" || fail "CHANGELOG.md has no v$version section."
  /usr/bin/plutil -convert json -o /dev/null -- "$VERSIONS_JSON"
  /usr/bin/plutil -convert json -o /dev/null -- "$SCHEMA_PATH"
}

verify_notary_access() {
  error_log="$(mktemp "${TMPDIR:-/tmp}/macrowhisper-notary.XXXXXX")"
  if ! xcrun notarytool history \
    --keychain-profile "$NOTARYTOOL_PROFILE" \
    --output-format json \
    >/dev/null 2>"$error_log"; then
    sed -n '1,12p' "$error_log" >&2
    rm -f "$error_log"
    fail "Apple notarization preflight failed. Check the Keychain profile and Apple Developer team agreements."
  fi
  rm -f "$error_log"
}

replace_installer_metadata() {
  version="$1"
  hash="$2"
  /usr/bin/perl -0pi -e "s/^VERSION=\"[0-9.]+\"/VERSION=\"$version\"/m; s/^EXPECTED_HASH=\"[0-9a-f]+\"/EXPECTED_HASH=\"$hash\"/m" "$INSTALL_SCRIPT"
  grep -q "^VERSION=\"$version\"$" "$INSTALL_SCRIPT" || fail "Failed to update installer version."
  grep -q "^EXPECTED_HASH=\"$hash\"$" "$INSTALL_SCRIPT" || fail "Failed to update installer hash."
}

replace_formula_metadata() {
  version="$1"
  hash="$2"
  [ -f "$FORMULA_PATH" ] || fail "Homebrew formula not found: $FORMULA_PATH"
  formula_repo="$(git -C "$(dirname "$FORMULA_PATH")" rev-parse --show-toplevel)"
  [ -z "$(git -C "$formula_repo" status --porcelain)" ] || fail "The Homebrew formula repository must be clean."

  /usr/bin/perl -0pi -e "s#releases/download/v[0-9.]+/macrowhisper-[0-9.]+-macos\\.tar\\.gz#releases/download/v$version/macrowhisper-$version-macos.tar.gz#g; s/^  sha256 \"[0-9a-f]+\"/  sha256 \"$hash\"/m; s/macrowhisper version [0-9.]+/macrowhisper version $version/g" "$FORMULA_PATH"
  grep -q "releases/download/v$version/macrowhisper-$version-macos.tar.gz" "$FORMULA_PATH" || fail "Failed to update formula URL."
  grep -q "sha256 \"$hash\"" "$FORMULA_PATH" || fail "Failed to update formula hash."
  grep -q "macrowhisper version $version" "$FORMULA_PATH" || fail "Failed to update formula test."
}

generate_release_notes() {
  version="$1"
  output="$2"
  extract_release_section "$version" > "$output"
  [ -s "$output" ] || fail "Could not extract release notes for v$version."
  cat >> "$output" <<'EOF'

---
## How to Update
### If Installed through Homebrew

```sh
brew update
brew upgrade macrowhisper
macrowhisper --restart-service
```

### If Installed with Script

```sh
curl -L https://raw.githubusercontent.com/ognistik/macrowhisper/main/scripts/install.sh | sh
macrowhisper --restart-service
```
EOF
}

draft_release() {
  version="$1"
  shift
  dry_run=0
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --dry-run) dry_run=1; shift ;;
      *) fail "Unknown draft option: $1" ;;
    esac
  done

  ensure_repo
  verify_prepared_release "$version"
  load_release_env

  require_command git
  require_command gh
  require_command xcodebuild
  require_command codesign
  require_command xcrun
  require_command zip
  require_command unzip
  require_command tar
  require_command shasum
  require_command lipo
  require_command spctl
  require_command ruby

  [ -f "$SCHEMA_PATH" ] || fail "Schema file not found: $SCHEMA_PATH"
  [ -f "$FORMULA_PATH" ] || fail "Formula file not found: $FORMULA_PATH"
  gh auth status >/dev/null 2>&1 || fail "GitHub CLI is not authenticated."
  verify_notary_access
  ! gh release view "v$version" --repo "$GITHUB_REPO" >/dev/null 2>&1 \
    || fail "A GitHub release for v$version already exists."

  changed_files="$(git -C "$ROOT_DIR" status --porcelain | sed 's/^...//')"
  for changed_file in $changed_files; do
    case "$changed_file" in
      CHANGELOG.md|versions.json|src/macrowhisper/main.swift) ;;
      *) fail "Unexpected changed file before draft: $changed_file" ;;
    esac
  done

  if [ "$dry_run" -eq 1 ]; then
    info "Draft preflight passed for v$version"
    echo "No build, signing, notarization, GitHub, or formula changes were made."
    return
  fi

  release_dir="$RELEASE_ROOT/v$version"
  derived_data="$release_dir/DerivedData"
  staging_dir="$release_dir/staging"
  payload_dir="$release_dir/payload"
  verify_dir="$release_dir/verify"
  binary_path="$staging_dir/macrowhisper"
  notarization_zip="$release_dir/macrowhisper.zip"
  archive_path="$release_dir/macrowhisper-$version-macos.tar.gz"
  notary_result="$release_dir/notary-result.json"
  release_notes="$release_dir/release-notes.md"
  release_branch="release/v$version"

  rm -rf "$release_dir"
  mkdir -p "$staging_dir" "$payload_dir" "$verify_dir"

  info "Building universal Release binary"
  xcodebuild \
    -quiet \
    -project "$PROJECT_PATH" \
    -scheme "$SCHEME" \
    -configuration Release \
    -destination 'generic/platform=macOS' \
    -derivedDataPath "$derived_data" \
    clean build \
    ARCHS='arm64 x86_64' \
    ONLY_ACTIVE_ARCH=NO

  built_binary="$derived_data/Build/Products/Release/macrowhisper"
  [ -f "$built_binary" ] || fail "Built binary not found: $built_binary"
  cp "$built_binary" "$binary_path"
  chmod 755 "$binary_path"

  architectures="$(lipo -archs "$binary_path")"
  case " $architectures " in *' arm64 '*) ;; *) fail "Release binary is missing arm64: $architectures" ;; esac
  case " $architectures " in *' x86_64 '*) ;; *) fail "Release binary is missing x86_64: $architectures" ;; esac

  info "Signing Release binary"
  codesign \
    --force \
    --timestamp \
    --options runtime \
    --sign "$DEVELOPER_ID_APPLICATION" \
    "$binary_path"
  codesign --verify --strict --verbose=2 "$binary_path"

  info "Creating notarization ZIP"
  (cd "$staging_dir" && zip -q "$notarization_zip" macrowhisper)

  info "Submitting ZIP for notarization"
  xcrun notarytool submit \
    "$notarization_zip" \
    --keychain-profile "$NOTARYTOOL_PROFILE" \
    --wait \
    --output-format json \
    > "$notary_result"

  notary_status="$(/usr/bin/plutil -extract status raw -o - "$notary_result")"
  notary_id="$(/usr/bin/plutil -extract id raw -o - "$notary_result")"
  if [ "$notary_status" != "Accepted" ]; then
    xcrun notarytool log "$notary_id" --keychain-profile "$NOTARYTOOL_PROFILE" >&2 || true
    fail "Notarization was not accepted. Status: $notary_status"
  fi

  info "Extracting and verifying notarized submission"
  unzip -q "$notarization_zip" -d "$verify_dir"
  codesign --verify --strict --verbose=2 "$verify_dir/macrowhisper"
  if ! spctl -a -vvv -t install "$verify_dir/macrowhisper"; then
    echo "Warning: spctl did not assess the standalone executable, but notarization was accepted and its signature verified." >&2
  fi

  actual_version="$("$verify_dir/macrowhisper" --version | sed -n 's/^macrowhisper version //p')"
  [ "$actual_version" = "$version" ] || fail "Built binary reports version '$actual_version', expected '$version'."
  "$verify_dir/macrowhisper" --help >/dev/null

  cp "$verify_dir/macrowhisper" "$payload_dir/macrowhisper"
  cp "$SCHEMA_PATH" "$payload_dir/macrowhisper-schema.json"

  info "Creating final distribution archive"
  COPYFILE_DISABLE=1 tar -czf "$archive_path" -C "$payload_dir" macrowhisper macrowhisper-schema.json
  archive_entries="$(tar -tzf "$archive_path")"
  [ "$archive_entries" = "macrowhisper
macrowhisper-schema.json" ] || fail "Unexpected archive contents:\n$archive_entries"
  hash="$(shasum -a 256 "$archive_path" | awk '{print $1}')"

  replace_installer_metadata "$version" "$hash"
  replace_formula_metadata "$version" "$hash"
  generate_release_notes "$version" "$release_notes"

  sh -n "$INSTALL_SCRIPT"
  ruby -c "$FORMULA_PATH" >/dev/null

  [ -z "$(git -C "$ROOT_DIR" branch --list "$release_branch")" ] \
    || fail "Local branch already exists: $release_branch"
  ! git -C "$ROOT_DIR" ls-remote --exit-code --heads origin "$release_branch" >/dev/null 2>&1 \
    || fail "Remote branch already exists: $release_branch"

  info "Creating release commit and GitHub draft"
  git -C "$ROOT_DIR" switch -c "$release_branch"
  git -C "$ROOT_DIR" add CHANGELOG.md versions.json scripts/install.sh src/macrowhisper/main.swift
  git -C "$ROOT_DIR" commit -m "Prepare v$version release"
  git -C "$ROOT_DIR" push -u origin "$release_branch"

  gh release create "v$version" \
    "$archive_path" \
    --repo "$GITHUB_REPO" \
    --draft \
    --title "v$version" \
    --target "$release_branch" \
    --notes-file "$release_notes"

  info "Draft v$version is ready for review"
  echo "Archive: $archive_path"
  echo "SHA-256: $hash"
  echo "Update dialog: scripts/release.sh preview"
  echo "Publish after review: scripts/release.sh publish $version"
}

publish_release() {
  version="$1"
  shift
  assume_yes=0
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --yes) assume_yes=1; shift ;;
      *) fail "Unknown publish option: $1" ;;
    esac
  done

  validate_version "$version"
  ensure_repo
  load_release_env
  require_command git
  require_command gh

  tag="v$version"
  release_branch="release/v$version"
  is_draft="$(gh release view "$tag" --repo "$GITHUB_REPO" --json isDraft --jq .isDraft)" \
    || fail "Could not find GitHub draft $tag."
  [ "$is_draft" = "true" ] || fail "$tag is not a draft release."

  current_branch="$(git -C "$ROOT_DIR" branch --show-current)"
  [ "$current_branch" = "$release_branch" ] || fail "Switch to $release_branch before publishing."
  [ -z "$(git -C "$ROOT_DIR" status --porcelain)" ] || fail "Macrowhisper release branch is not clean."

  formula_repo="$(git -C "$(dirname "$FORMULA_PATH")" rev-parse --show-toplevel)"
  formula_relative="${FORMULA_PATH#"$formula_repo"/}"
  git -C "$formula_repo" ls-files --error-unmatch "$formula_relative" >/dev/null 2>&1 \
    || fail "Formula is not tracked by its repository: $FORMULA_PATH"
  formula_changed_files="$(git -C "$formula_repo" status --porcelain | sed 's/^...//')"
  [ "$formula_changed_files" = "$formula_relative" ] \
    || fail "Expected exactly one uncommitted formula update; found:\n${formula_changed_files:-none}"

  if [ "$assume_yes" -ne 1 ]; then
    printf 'Publish %s and push release metadata? [y/N] ' "$tag"
    read -r answer
    case "$answer" in y|Y|yes|YES) ;; *) echo "Cancelled."; exit 0 ;; esac
  fi

  git -C "$ROOT_DIR" fetch origin main
  git -C "$ROOT_DIR" merge-base --is-ancestor origin/main "$release_branch" \
    || fail "origin/main is no longer an ancestor of $release_branch. Resolve the branch before publishing metadata."

  info "Publishing GitHub release $tag"
  gh release edit "$tag" --repo "$GITHUB_REPO" --draft=false --latest

  info "Promoting release commit to main"
  git -C "$ROOT_DIR" switch main
  git -C "$ROOT_DIR" merge --ff-only "$release_branch"
  git -C "$ROOT_DIR" push origin main

  info "Publishing Homebrew formula update"
  git -C "$formula_repo" add "$FORMULA_PATH"
  git -C "$formula_repo" commit -m "Update macrowhisper to $tag"
  git -C "$formula_repo" push origin HEAD

  git -C "$ROOT_DIR" push origin --delete "$release_branch"
  git -C "$ROOT_DIR" branch -d "$release_branch"

  info "$tag is published"
}

command_name="${1:-}"
case "$command_name" in
  prepare)
    [ "$#" -eq 2 ] || { usage >&2; exit 1; }
    prepare_release "$2"
    ;;
  preview)
    shift
    preview_release "$@"
    ;;
  draft)
    [ "$#" -ge 2 ] || { usage >&2; exit 1; }
    version="$2"
    shift 2
    draft_release "$version" "$@"
    ;;
  publish)
    [ "$#" -ge 2 ] || { usage >&2; exit 1; }
    version="$2"
    shift 2
    publish_release "$version" "$@"
    ;;
  -h|--help|help)
    usage
    ;;
  *)
    usage >&2
    exit 1
    ;;
esac
