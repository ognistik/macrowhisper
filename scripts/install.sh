#!/usr/bin/env sh
set -eu

#
# Install the latest pre-built macrowhisper release from GitHub.
# Depends on curl, shasum, tar, awk, sed, find, mktemp, mkdir, mv, cp, rm,
# chmod, dirname.
#
# ARG1:   Optional directory in which to install the binary; must be absolute.
#         Fallback: /usr/local/bin
#

BIN_DIR="${1:-/usr/local/bin}"

case "$BIN_DIR" in
    /*) ;;
    *)
        echo "Error: Binary target directory '$BIN_DIR' is not an absolute path." >&2
        exit 1
        ;;
esac

if [ ! -d "$BIN_DIR" ]; then
    echo "Creating binary target directory '$BIN_DIR'..."
    mkdir -p "$BIN_DIR" || {
        echo "Error: Failed to create binary target directory '$BIN_DIR'." >&2
        exit 1
    }
fi

if [ ! -w "$BIN_DIR" ]; then
    echo "Error: User does not have write permission for binary target directory '$BIN_DIR'." >&2
    exit 1
fi

# The resource root is inferred from the selected bin directory. This keeps
# /usr/local/bin, /opt/homebrew/bin, and custom prefixes consistent with the
# Homebrew layout without relying on the current working directory.
PREFIX_DIR="$(dirname "$BIN_DIR")"
SHARE_PARENT="$PREFIX_DIR/share"
RESOURCE_DIR="$SHARE_PARENT/macrowhisper"
TARGET_BINARY="$BIN_DIR/macrowhisper"

AUTHOR="ognistik"
NAME="macrowhisper"
SCHEMA_NAME="macrowhisper-schema.json"
VERSION="2.2.0"
EXPECTED_HASH="9ffe70fe0254f1cebb3cf12a27f132accbe5165f5c6934b156c41dc9cc023dfb"
ARCHIVE_URL="https://github.com/$AUTHOR/$NAME/releases/download/v$VERSION/$NAME-$VERSION-macos.tar.gz"

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/${AUTHOR}-${NAME}-installer.XXXXXX")"
STAGE_DIR=""
OLD_BINARY_MOVED=0
OLD_RESOURCE_MOVED=0
OLD_LEGACY_SCHEMA_MOVED=0
NEW_BINARY_INSTALLED=0
NEW_RESOURCE_INSTALLED=0
INSTALL_COMPLETE=0

restore_previous_install() {
    [ "$INSTALL_COMPLETE" -eq 0 ] || return 0

    if [ "$NEW_BINARY_INSTALLED" -eq 1 ] && { [ -e "$TARGET_BINARY" ] || [ -L "$TARGET_BINARY" ]; }; then
        rm -f "$TARGET_BINARY" || true
    fi
    if [ "$NEW_RESOURCE_INSTALLED" -eq 1 ] && { [ -e "$RESOURCE_DIR" ] || [ -L "$RESOURCE_DIR" ]; }; then
        rm -rf "$RESOURCE_DIR" || true
    fi
    if [ "$OLD_BINARY_MOVED" -eq 1 ] && [ ! -e "$TARGET_BINARY" ] && [ ! -L "$TARGET_BINARY" ]; then
        mv "$STAGE_DIR/backup/bin" "$TARGET_BINARY" || true
    fi
    if [ "$OLD_RESOURCE_MOVED" -eq 1 ] && [ ! -e "$RESOURCE_DIR" ] && [ ! -L "$RESOURCE_DIR" ]; then
        mv "$STAGE_DIR/backup/share" "$RESOURCE_DIR" || true
    fi
    if [ "$OLD_LEGACY_SCHEMA_MOVED" -eq 1 ] && [ ! -e "$LEGACY_SCHEMA" ] && [ ! -L "$LEGACY_SCHEMA" ]; then
        mv "$STAGE_DIR/backup/legacy-schema" "$LEGACY_SCHEMA" || true
    fi
}

cleanup() {
    status=$?
    if [ "$status" -ne 0 ]; then
        restore_previous_install
    fi
    if [ -n "$STAGE_DIR" ] && { [ -e "$STAGE_DIR" ] || [ -L "$STAGE_DIR" ]; }; then
        rm -rf "$STAGE_DIR"
    fi
    rm -rf "$TMP_DIR"
    exit "$status"
}

trap cleanup EXIT HUP INT TERM

ARCHIVE_PATH="$TMP_DIR/$NAME-$VERSION-macos.tar.gz"
EXTRACT_DIR="$TMP_DIR/extracted"
mkdir -p "$EXTRACT_DIR"

echo "Downloading $NAME v$VERSION..."
curl --fail --location --silent --show-error --output "$ARCHIVE_PATH" "$ARCHIVE_URL"

FILE_HASH="$(shasum -a 256 "$ARCHIVE_PATH" | awk '{print $1}')"
if [ "$FILE_HASH" != "$EXPECTED_HASH" ]; then
    echo "Hash does not match the expected value. Aborting installation." >&2
    echo "Expected hash: $EXPECTED_HASH" >&2
    echo "  Actual hash: $FILE_HASH" >&2
    echo "This may indicate a corrupted download or a security issue." >&2
    exit 1
fi

echo "Hash verified. Checking release layout..."
ARCHIVE_ENTRIES="$(tar -tzf "$ARCHIVE_PATH" | sed 's#/$##')"
[ -n "$ARCHIVE_ENTRIES" ] || { echo "Error: Release archive is empty." >&2; exit 1; }
while IFS= read -r entry; do
    case "$entry" in
        ../*|*/../*|*/..|./*|*/./*)
            echo "Error: Unsafe path in release archive: $entry" >&2
            exit 1
            ;;
    esac
    case "$entry" in
        bin|bin/macrowhisper|share|share/macrowhisper|share/macrowhisper/macrowhisper-schema.json|share/macrowhisper/editor|share/macrowhisper/editor/index.html|share/macrowhisper/editor/assets|share/macrowhisper/editor/assets/*) ;;
        *)
            echo "Error: Unexpected release archive entry: $entry" >&2
            exit 1
            ;;
    esac
done <<EOF
$ARCHIVE_ENTRIES
EOF

tar -xzf "$ARCHIVE_PATH" -C "$EXTRACT_DIR"
PACKAGE_DIR="$EXTRACT_DIR"
PACKAGE_BINARY="$PACKAGE_DIR/bin/$NAME"
PACKAGE_SHARE="$PACKAGE_DIR/share/$NAME"
PACKAGE_SCHEMA="$PACKAGE_SHARE/$SCHEMA_NAME"
PACKAGE_EDITOR="$PACKAGE_SHARE/editor"
LEGACY_SCHEMA="$BIN_DIR/$SCHEMA_NAME"

[ -f "$PACKAGE_BINARY" ] || { echo "Error: Release binary is missing from the archive." >&2; exit 1; }
[ -f "$PACKAGE_SCHEMA" ] || { echo "Error: Release schema is missing from the archive." >&2; exit 1; }
[ -f "$PACKAGE_EDITOR/index.html" ] || { echo "Error: Editor entry point is missing from the archive." >&2; exit 1; }
[ -d "$PACKAGE_EDITOR/assets" ] || { echo "Error: Editor assets directory is missing from the archive." >&2; exit 1; }
[ -n "$(find "$PACKAGE_EDITOR/assets" -type f -print -quit)" ] \
    || { echo "Error: Editor assets directory is empty." >&2; exit 1; }
[ -z "$(find "$PACKAGE_DIR" -type l -print -quit)" ] \
    || { echo "Error: Release resources must not contain symlinks." >&2; exit 1; }

mkdir -p "$SHARE_PARENT"
if [ ! -w "$SHARE_PARENT" ]; then
    echo "Error: User does not have write permission for resource directory '$SHARE_PARENT'." >&2
    exit 1
fi

# Stage the complete resource tree and keep existing owned files in a
# recoverable sibling until both the binary and resources have been replaced.
STAGE_DIR="$(mktemp -d "$SHARE_PARENT/.macrowhisper-install.XXXXXX")"
mkdir -p "$STAGE_DIR/bin" "$STAGE_DIR/share"
cp "$PACKAGE_BINARY" "$STAGE_DIR/bin/$NAME"
chmod 755 "$STAGE_DIR/bin/$NAME"
cp -R "$PACKAGE_SHARE" "$STAGE_DIR/share/$NAME"

mkdir -p "$STAGE_DIR/backup"
if [ -e "$TARGET_BINARY" ] || [ -L "$TARGET_BINARY" ]; then
    [ -f "$TARGET_BINARY" ] || [ -L "$TARGET_BINARY" ] \
        || { echo "Error: Existing binary target is not a regular file: '$TARGET_BINARY'." >&2; exit 1; }
    mv "$TARGET_BINARY" "$STAGE_DIR/backup/bin"
    OLD_BINARY_MOVED=1
fi
if [ -e "$RESOURCE_DIR" ] || [ -L "$RESOURCE_DIR" ]; then
    [ -d "$RESOURCE_DIR" ] || { echo "Error: Existing resource target is not a directory: '$RESOURCE_DIR'." >&2; exit 1; }
    [ ! -L "$RESOURCE_DIR" ] || { echo "Error: Refusing to replace symlinked resource target: '$RESOURCE_DIR'." >&2; exit 1; }
    mv "$RESOURCE_DIR" "$STAGE_DIR/backup/share"
    OLD_RESOURCE_MOVED=1
fi
if [ -e "$LEGACY_SCHEMA" ] || [ -L "$LEGACY_SCHEMA" ]; then
    [ -f "$LEGACY_SCHEMA" ] || [ -L "$LEGACY_SCHEMA" ] \
        || { echo "Error: Existing legacy schema target is not a regular file: '$LEGACY_SCHEMA'." >&2; exit 1; }
    mv "$LEGACY_SCHEMA" "$STAGE_DIR/backup/legacy-schema"
    OLD_LEGACY_SCHEMA_MOVED=1
fi

mv "$STAGE_DIR/bin/$NAME" "$TARGET_BINARY"
NEW_BINARY_INSTALLED=1
mv "$STAGE_DIR/share/$NAME" "$RESOURCE_DIR"
NEW_RESOURCE_INSTALLED=1
INSTALL_COMPLETE=1

echo "Installed $NAME v$VERSION to $TARGET_BINARY"
echo "Installed schema and editor resources to $RESOURCE_DIR"
echo ""
echo "To open the local configuration editor, start the daemon and run:"
echo "  $TARGET_BINARY --editor"
echo ""
echo "For more information and documentation, visit:"
echo "https://github.com/ognistik/macrowhisper"
