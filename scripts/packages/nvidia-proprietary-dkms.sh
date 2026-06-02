#!/bin/bash

# Track the nvidia-utils version in the Arch repos
echo "Checking nvidia-proprietary-dkms via Arch repos (nvidia-utils)..."

latest_ver=$(curl -s "https://archlinux.org/packages/extra/x86_64/nvidia-utils/json/" | jq -r .pkgver)

if [ -n "$latest_ver" ] && [ "$latest_ver" != "null" ]; then
    perform_update "nvidia-proprietary-dkms" "$latest_ver"
else
    echo "Failed to check version for nvidia-proprietary-dkms"
fi
