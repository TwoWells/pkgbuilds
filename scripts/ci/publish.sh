#!/bin/bash
set -e

# publish.sh: Signs packages and updates the repository database.
# Usage: ./publish.sh

# Source common variables
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/common.sh"

echo "==> Finalizing repository..."

# Configure GPG for non-interactive use
GPG_TTY=$(tty 2> /dev/null || echo /dev/tty)
export GPG_TTY
mkdir -p ~/.gnupg
chmod 700 ~/.gnupg
echo "allow-loopback-pinentry" >> ~/.gnupg/gpg-agent.conf
echo "pinentry-mode loopback" >> ~/.gnupg/gpg.conf
gpgconf --kill gpg-agent 2> /dev/null || true

# Ensure GPG key is imported (handled by YAML step usually, but check)
if ! gpg --list-secret-keys > /dev/null 2>&1; then
    echo "Error: GPG key not found. Ensure it was imported."
    exit 1
fi

mkdir -p repo

# 1. Gather Artifacts
if [ -d "repo-artifacts" ]; then
    find repo-artifacts -name "*.pkg.tar.zst" -exec mv {} repo/ \; 2> /dev/null || true
fi

# 2. Handle Removals
if [ -n "$REMOVED_JSON" ] && [ "$REMOVED_JSON" != "[]" ]; then
    echo "Processing removals: $REMOVED_JSON"
    REMOVED_LIST=$(echo "$REMOVED_JSON" | jq -r '.[]')

    if [ -f "repo/${REPO_NAME}.db.tar.gz" ]; then
        repo-remove "repo/${REPO_NAME}.db.tar.gz" $REMOVED_LIST
    else
        echo "Warning: Database not found, cannot remove packages."
    fi

    # Also drop the removed packages' files: migration and manual-publish
    # runs bulk-download every historical *.pkg.tar.zst into repo/, and the
    # blanket repo-add below would resurrect the entries just removed.
    for name in $REMOVED_LIST; do
        rm -f repo/"${name}"-[0-9]*.pkg.tar.zst repo/"${name}"-[0-9]*.pkg.tar.zst.sig
    done
fi

# 3. Sign and Add New Packages
cd repo

# Sign packages
for pkg in *.pkg.tar.zst; do
    [ -f "$pkg" ] || continue
    if [ ! -f "${pkg}.sig" ]; then
        echo "Signing $pkg..."
        if [ -n "$GPG_PASSPHRASE" ]; then
            echo "$GPG_PASSPHRASE" | gpg --batch --yes --pinentry-mode loopback --passphrase-fd 0 --detach-sign --no-armor "$pkg"
        else
            gpg --batch --yes --pinentry-mode loopback --detach-sign --no-armor "$pkg"
        fi
    fi
done

# Update Database
if [ -f "${REPO_NAME}.db.tar.gz" ] || ls *.pkg.tar.zst 1> /dev/null 2>&1; then
    echo "Updating database..."

    PKGS_TO_ADD=""
    if ls *.pkg.tar.zst 1> /dev/null 2>&1; then
        PKGS_TO_ADD="*.pkg.tar.zst"
    fi

    # Run repo-add without --sign first to ensure it's built
    repo-add "${REPO_NAME}.db.tar.gz" $PKGS_TO_ADD

    # Manually sign the database files because repo-add --sign often fails in CI
    for db_file in "${REPO_NAME}.db.tar.gz" "${REPO_NAME}.files.tar.gz"; do
        [ -f "$db_file" ] || continue
        echo "Manually signing $db_file..."
        rm -f "${db_file}.sig"
        if [ -n "$GPG_PASSPHRASE" ]; then
            echo "$GPG_PASSPHRASE" | gpg --batch --yes --pinentry-mode loopback --passphrase-fd 0 --detach-sign --no-armor "$db_file"
        else
            gpg --batch --yes --pinentry-mode loopback --detach-sign --no-armor "$db_file"
        fi
    done

    # Ensure files exist for pacman's default expectations (no symlinks for GitHub Releases)
    # Remove first to avoid "same file" errors if they were already copies/links
    rm -f "${REPO_NAME}.db" "${REPO_NAME}.files"
    cp -f "${REPO_NAME}.db.tar.gz" "${REPO_NAME}.db"
    cp -f "${REPO_NAME}.files.tar.gz" "${REPO_NAME}.files"

    # Sync signatures to the copied names
    [ -f "${REPO_NAME}.db.tar.gz.sig" ] && cp -f "${REPO_NAME}.db.tar.gz.sig" "${REPO_NAME}.db.sig"
    [ -f "${REPO_NAME}.files.tar.gz.sig" ] && cp -f "${REPO_NAME}.files.tar.gz.sig" "${REPO_NAME}.files.sig"
fi

# Final check: remove any 0-byte sig files which cause gh upload to fail
find . -name "*.sig" -size 0 -delete

echo "==> Repository updated successfully."
