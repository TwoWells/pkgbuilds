#!/bin/bash
set -e
PKG_FILE="$1"

echo "Testing perl-config-inifiles..."
if [ -z "$PKG_FILE" ]; then
    echo "Error: Package file not provided"
    exit 1
fi

# Install the package (pulls perl + perl-io-stringy).
sudo pacman -U --noconfirm "$PKG_FILE"

# Verify the module loads — this implicitly confirms the IO::Scalar
# (perl-io-stringy) runtime dependency resolved.
if perl -MConfig::IniFiles -e 'print "Config::IniFiles loaded OK\n"'; then
    echo "module load passed."
else
    echo "Error: Config::IniFiles failed to load."
    exit 1
fi
