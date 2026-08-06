#!/bin/bash

# Track the nvidia-utils version in the Arch repos, and defer the .run
# checksum to Arch's packagers: their nvidia-utils recipe pins a sha512 for
# the same installer, so the bump copies that reviewed claim instead of
# hashing our own download. The packaging repo is fetched with git because
# plain HTTP against gitlab.archlinux.org hits the Anubis anti-bot wall.
echo "Checking nvidia-proprietary-dkms via Arch repos (nvidia-utils)..."

_json=$(curl -s "https://archlinux.org/packages/extra/x86_64/nvidia-utils/json/")
latest_ver=$(printf '%s' "$_json" | jq -r .pkgver)
latest_rel=$(printf '%s' "$_json" | jq -r .pkgrel)

if [ -z "$latest_ver" ] || [ "$latest_ver" == "null" ]; then
    echo "Failed to check version for nvidia-proprietary-dkms"
else
    _clone=$(mktemp -d)
    if git clone --quiet --depth 1 --branch "${latest_ver}-${latest_rel}" \
        "https://gitlab.archlinux.org/archlinux/packaging/packages/nvidia-utils.git" \
        "$_clone" 2> /dev/null; then
        # The .run lives in the arch-specific fields, not plain source=.
        src=$(sed -n 's/^[[:space:]]*source_x86_64 = //p' "$_clone/.SRCINFO")
        sum=$(sed -n 's/^[[:space:]]*sha512sums_x86_64 = //p' "$_clone/.SRCINFO")
        if [[ "$src" == *"/NVIDIA-Linux-x86_64-${latest_ver}.run" ]] &&
            [[ "$sum" =~ ^[0-9a-f]{128}$ ]]; then
            UPDATE_PIN_SUMS="'$sum'" perform_update "nvidia-proprietary-dkms" "$latest_ver"
        else
            echo "::error::Arch .SRCINFO for nvidia-utils ${latest_ver}-${latest_rel} did not yield a usable x86_64 .run checksum — skipping bump"
        fi
    else
        echo "::error::Failed to clone Arch packaging repo at tag ${latest_ver}-${latest_rel} — skipping bump"
    fi
    rm -rf "$_clone"
fi
