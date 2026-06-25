# Releasing Macrowhisper

The release helper keeps builds inside the repository, signs and notarizes the
standalone executable, packages the executable with its JSON schema, and prepares
the installer, Homebrew formula, and GitHub release.

## Local test builds

Use a local Xcode build when you only need a binary to test. This does not sign,
notarize, package, update release metadata, or create a GitHub release.

From the repository root, build a debug binary:

```sh
xcodebuild -project src/macrowhisper.xcodeproj -scheme macrowhisper -configuration Debug -derivedDataPath .build/local-xcode build
```

Run the generated binary from:

```sh
.build/local-xcode/Build/Products/Debug/macrowhisper
```

For a release-optimized local binary, use the same build command with the
`Release` configuration:

```sh
xcodebuild -project src/macrowhisper.xcodeproj -scheme macrowhisper -configuration Release -derivedDataPath .build/local-xcode build
```

Run the generated release binary from:

```sh
.build/local-xcode/Build/Products/Release/macrowhisper
```

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
scripts/release.sh prepare 2.0.4
```

Review the new changelog section and shorten the generated `description` in
`versions.json`. Preview the exact user-facing update dialog with:

```sh
scripts/release.sh preview
```

Run a non-mutating preflight if desired:

```sh
scripts/release.sh draft 2.0.4 --dry-run
```

Build, sign, notarize, package, and create the GitHub draft:

```sh
scripts/release.sh draft 2.0.4
```

The final archive contains exactly:

```text
macrowhisper
macrowhisper-schema.json
```

Review the draft release, its `v2.0.4` title and tag, the release notes, and the
uploaded archive. Publishing is a separate, explicit action:

```sh
scripts/release.sh publish 2.0.4
```

The publish command asks for confirmation, publishes the GitHub draft, promotes
the release commit to `main`, and commits and pushes the Homebrew formula update.

## Recovery notes

Draft preparation uses a temporary `release/vVERSION` branch so `versions.json`
does not notify users before the release exists. If draft creation is interrupted,
inspect that branch and `.build/release/vVERSION` before rerunning or cleaning up.

The final archive, release notes, checksum, and notarization response remain under
`.build/release/vVERSION` for inspection.
