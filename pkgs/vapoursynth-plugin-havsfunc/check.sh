#!/bin/bash
set -e
PKG_FILE="$1"

echo "Testing vapoursynth-plugin-havsfunc..."
if [ -z "$PKG_FILE" ]; then
    echo "Error: Package file not provided"
    exit 1
fi

sudo pacman -U --noconfirm "$PKG_FILE"

python -c "import havsfunc; print('havsfunc imported successfully')"
python -c "import adjust; print('adjust imported successfully')"
