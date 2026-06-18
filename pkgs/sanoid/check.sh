#!/bin/bash
set -e
PKG_FILE="$1"

echo "Testing sanoid..."
if [ -z "$PKG_FILE" ]; then
    echo "Error: Package file not provided"
    exit 1
fi

# Install the package (pulls perl + perl-config-inifiles + perl-capture-tiny).
sudo pacman -U --noconfirm "$PKG_FILE"

# Version check. This also implicitly verifies the Perl runtime deps load,
# and runs without ZFS present (sanoid only needs zfs at snapshot time).
for bin in sanoid syncoid findoid; do
    if "$bin" --version; then
        echo "$bin --version passed."
    else
        echo "Error: $bin --version failed."
        exit 1
    fi
done

# Confirm the systemd units packaged correctly.
for unit in sanoid.service sanoid.timer sanoid-prune.service; do
    if [ -f "/usr/lib/systemd/system/$unit" ]; then
        echo "unit present: $unit"
    else
        echo "Error: missing unit $unit"
        exit 1
    fi
done
