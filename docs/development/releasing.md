# Releasing Macrowhisper

[Documentation index](../README.md)

The release helper keeps builds inside the repository, signs and notarizes the
standalone executable, packages the executable with its JSON schema, and prepares
the installer, Homebrew formula, and GitHub release.

Run the commands in this guide from the repository root. For the signed local
binary used for manual testing, including its stable output path and signature
checks, see the [development build and test guide](README.md).

## One-time setup

Copy `.release.env.example` to `.release.env`, fill in the signing identity and
Keychain notary profile, and make sure `.release.env` is listed in
`.git/info/exclude`.

The Homebrew formula is expected at `../homebrew-formulae/macrowhisper.rb` by
default. Set `HOMEBREW_FORMULA` in `.release.env` if it lives elsewhere.

The draft preflight contacts Apple's notary service before building. If Apple
reports that a required agreement is missing or expired, accept the pending team
agreement in the Apple developer account before retrying.

## Release workflow

Start from a clean working tree:

```sh
scripts/release.sh prepare 2.1.1
```

Review the new changelog section and shorten the generated `description` in
`versions.json`. Preview the exact user-facing update dialog with:

```sh
scripts/release.sh preview
```

Run a non-mutating preflight if desired:

```sh
scripts/release.sh draft 2.1.1 --dry-run
```

The dry run still performs external preflight checks, including GitHub CLI
authentication/release lookup and an Apple notary profile history request. It
does not build, sign, notarize, package, create a GitHub draft, or update the
formula.

Build, sign, notarize, package, and create the GitHub draft:

```sh
scripts/release.sh draft 2.1.1
```

The final archive contains exactly:

```text
macrowhisper
macrowhisper-schema.json
```

Review the draft release, its `v2.1.1` title and tag, the release notes, and the
uploaded archive. Publishing is a separate, explicit action:

```sh
scripts/release.sh publish 2.1.1
```

The publish command asks for confirmation, publishes the GitHub draft, promotes
the release commit to `main`, and commits and pushes the Homebrew formula update.

## Recovery notes

Draft preparation uses a temporary `release/vVERSION` branch so `versions.json`
does not notify users before the release exists. If draft creation is interrupted,
inspect that branch and `.build/release/vVERSION` before rerunning or cleaning up.

The final archive, release notes, checksum, and notarization response remain under
`.build/release/vVERSION` for inspection.
