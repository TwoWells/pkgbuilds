#!/bin/bash
set -e
PKG_FILE="$1"

echo "Testing keeper-commander..."
if [ -z "$PKG_FILE" ]; then
    echo "Error: Package file not provided"
    exit 1
fi

# Install the package
sudo pacman -U --noconfirm "$PKG_FILE"

# Run version check
# Note: 'keeper' is the command name.
# This implicitly tests that all runtime dependencies (websockets, etc) are loadable.
if keeper --version; then
    echo "keeper --version passed."
else
    echo "Error: keeper --version failed."
    exit 1
fi
