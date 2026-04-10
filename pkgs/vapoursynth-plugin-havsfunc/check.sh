#!/bin/bash
set -e
PKG_FILE="$1"

echo "Testing vapoursynth-plugin-havsfunc..."
if [ -z "$PKG_FILE" ]; then
    echo "Error: Package file not provided"
    exit 1
fi

sudo pacman -U --noconfirm "$PKG_FILE"

site_packages="$(python -c 'import site; print(site.getsitepackages()[0])')"

for f in havsfunc.py adjust.py; do
    if [ -f "$site_packages/$f" ]; then
        echo "$f installed at $site_packages/$f"
    else
        echo "Error: $f not found at $site_packages/$f"
        exit 1
    fi
done
