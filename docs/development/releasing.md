# Releasing Macrowhisper

[Documentation index](../README.md)

The release helper keeps builds inside the repository, signs and notarizes the
standalone executable, packages the executable with its JSON schema, and prepares
the installer, Homebrew formula, and GitHub release.

Run the commands in this guide from the repository root. For the signed local
binary used for manual testing, including its stable output path and signature
checks, see the [development build and test guide](README.md).

## One-time setup

The release commands require Xcode's build tools, a Developer ID Application
signing identity, a Keychain notary profile, authenticated GitHub CLI access,
and the sibling Homebrew formula repository. The script checks its required
commands before drafting a release.

Copy `.release.env.example` to `.release.env`, fill in the signing identity and
Keychain notary profile, and make sure `.release.env` is listed in
`.git/info/exclude`.

The Homebrew formula is expected at `../homebrew-formulae/macrowhisper.rb` by
default. Set `HOMEBREW_FORMULA` in `.release.env` if it lives elsewhere.

The draft preflight contacts Apple's notary service before building. If Apple
reports that a required agreement is missing or expired, accept the pending team
agreement in the Apple developer account before retrying.

## Release workflow

Start on `main` with a clean working tree and a clean Homebrew formula
repository. `prepare` rejects any other branch, an equal or older version, or
a version already in the changelog. The changelog must have an `UNRELEASED`
section. Choose the intended new version as three numeric components without
the `v` prefix; `2.1.2` below is an example, not a fixed release target:

```sh
RELEASE_VERSION=2.1.2
scripts/release.sh prepare "$RELEASE_VERSION"
```

`prepare` moves the current unreleased notes into a dated version section,
updates `APP_VERSION` in `src/macrowhisper/main.swift`, and updates the version
and seeded description in the root `versions.json`. Review those three files
and shorten the description for the update dialog. These are local changes;
preparation does not build or publish anything.

Preview the exact user-facing update dialog with:

```sh
scripts/release.sh preview
```

The preview uses `macrowhisper` from `PATH`. To choose an existing local binary,
pass `--binary /absolute/path/to/macrowhisper` or set `MACROWHISPER_BIN`.

Run a non-mutating preflight if desired:

```sh
scripts/release.sh draft "$RELEASE_VERSION" --dry-run
```

The dry run still performs external preflight checks, including GitHub CLI
authentication/release lookup and an Apple notary profile history request. It
does not build, sign, notarize, package, create a GitHub draft, or update the
formula.

Before drafting, the only allowed Macrowhisper working-tree changes are the
prepared `CHANGELOG.md`, `versions.json`, and `src/macrowhisper/main.swift`.
Do not push the prepared metadata to `main` before the release exists.

Build, sign, notarize, package, and create the GitHub draft:

```sh
scripts/release.sh draft "$RELEASE_VERSION"
```

The draft builds a universal `arm64`/`x86_64` Release executable, signs and
notarizes it, verifies its reported version, and packages it with the schema.
It updates the installer version/checksum and the sibling Homebrew formula,
then creates and pushes `release/vVERSION` with a release commit and creates
the GitHub draft against that branch. The formula changes remain uncommitted
until publication.

The final archive contains exactly:

```text
macrowhisper
macrowhisper-schema.json
```

Review the draft release, its `vVERSION` title and tag, the release notes, and the
uploaded archive. Publishing is a separate, explicit action:

```sh
scripts/release.sh publish "$RELEASE_VERSION"
```

Publish from the clean `release/vVERSION` branch, with exactly the expected
formula file modified in the sibling repository. The command asks for
confirmation unless `--yes` is supplied. It checks that remote `main` remains
an ancestor of the release branch, publishes the draft, fast-forwards and
pushes `main`, commits and pushes the formula update, and deletes the temporary
local and remote release branches.

## Recovery notes

The temporary `release/vVERSION` branch keeps published `main` metadata from
notifying users before the release exists. If drafting is interrupted, inspect
the current branch, both repositories' changes, any GitHub draft, and
`.build/release/vVERSION` before rerunning or cleaning up. The branch is created
late in drafting, after building and updating the local formula. A failed run
can therefore leave local changes even when no release branch exists yet.

Drafting recreates its version-specific build directory and rejects an existing
release branch or GitHub release. Publishing performs several external steps
in sequence; if it fails partway through, inspect which steps completed before
retrying. Do not assume the entire operation rolled back.

The final archive, release notes, checksum, and notarization response remain under
`.build/release/vVERSION` for inspection.
