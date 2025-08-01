#!/usr/bin/env sh

#
# This script will install the latest pre-built macrowhisper release from GitHub.
# Depends on curl, shasum, tar, cp, cut.
#
# ARG1:   Optional - directory in which to store the binary; must be an absolute path.
#         Fallback: /usr/local/bin
#
#

BIN_DIR="$1"

if [ -z "$BIN_DIR" ]; then
    BIN_DIR="/usr/local/bin"
fi

if [ "${BIN_DIR%%/*}" ]; then
    echo "Error: Binary target directory '${BIN_DIR}' is not an absolute path."
    exit 1
fi

if [ ! -d "$BIN_DIR" ]; then
    echo "Creating binary target directory '${BIN_DIR}'..."
    mkdir -p "$BIN_DIR"
    if [ $? -ne 0 ]; then
        echo "Error: Failed to create binary target directory '${BIN_DIR}'."
        exit 1
    fi
fi

if [ ! -w "$BIN_DIR" ]; then
    echo "Error: User does not have write permission for binary target directory '${BIN_DIR}'."
    exit 1
fi

AUTHOR="ognistik"
NAME="macrowhisper"
VERSION="1.2.2"
EXPECTED_HASH="aec1d8bc9a7648559b133f5cade391b61125c9da38160c4aa194796bcdbfa3b6"
TMP_DIR="./${AUTHOR}-${NAME}-v${VERSION}-installer"

mkdir "$TMP_DIR"
pushd "$TMP_DIR" || { echo "Failed to enter temp directory"; exit 1; }

echo "Downloading macrowhisper v${VERSION}..."
curl --location --remote-name https://github.com/${AUTHOR}/${NAME}/releases/download/v${VERSION}/${NAME}-${VERSION}-macos.tar.gz

if [ ! -f "${NAME}-${VERSION}-macos.tar.gz" ]; then
    echo "Error: Failed to download the release file."
    popd
    rm -rf $TMP_DIR
    exit 1
fi

FILE_HASH=$(shasum -a 256 ./${NAME}-${VERSION}-macos.tar.gz | cut -d " " -f 1)

if [ "$FILE_HASH" = "$EXPECTED_HASH" ]; then
    echo "Hash verified. Preparing files..."
    tar -xzf ${NAME}-${VERSION}-macos.tar.gz
    
    # Remove existing binary if it exists
    if [ -f "${BIN_DIR}/${NAME}" ]; then
        echo "Removing existing macrowhisper binary..."
        rm "${BIN_DIR}/${NAME}"
    fi
    
    # Install the new binary
    cp -v ./${NAME} ${BIN_DIR}/${NAME}
    chmod +x ${BIN_DIR}/${NAME}
    
    echo "Finished copying files."
    echo ""
    echo "macrowhisper has been successfully installed to ${BIN_DIR}/${NAME}"
    echo ""
    echo "To get started:"
    echo "  1. Configure macrowhisper by running:"
    echo "     macrowhisper --reveal-config"
    echo ""
    echo "  2. Verify correct Superwhisper folder path and/or other basic settings"
    echo ""
    echo "  3. Install as a system service (to run in background):"
    echo "     macrowhisper --start-service"
    echo ""
    echo "  Or run macrowhisper directly:"
    echo "     macrowhisper"
    echo ""
    echo "  For help and available commands:"
    echo "     macrowhisper --help"
    echo ""
    echo "IMPORTANT: If upgrading from a previous version, restart the service:"
    echo "  macrowhisper --restart-service"
    echo ""
    echo "For more information and documentation, visit:"
    echo "https://github.com/ognistik/macrowhisper"
else
    echo "Hash does not match the expected value. Aborting installation."
    echo "Expected hash: $EXPECTED_HASH"
    echo "  Actual hash: $FILE_HASH"
    echo ""
    echo "This may indicate a corrupted download or a security issue."
    echo "Please try again or report this issue at:"
    echo "https://github.com/ognistik/macrowhisper/issues"
fi

popd
rm -rf "$TMP_DIR" 