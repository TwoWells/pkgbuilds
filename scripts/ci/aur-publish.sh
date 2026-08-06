#!/bin/bash
set -e

# aur-publish.sh: Pushes packages with .aur marker to AUR
# Requires: AUR_SSH_PRIVATE_KEY environment variable
#
# Failure classes (see PROVENANCE.md):
#   retryable — AUR unreachable or in a maintenance window. Still exits red
#               (so the alert job fires), and reconcile.yml re-drives the
#               publish once the AUR is back.
#   rejected  — the AUR refused the operation (non-fast-forward, permissions,
#               broken .SRCINFO). Needs a human; retrying cannot help.

echo "==> Publishing to AUR..."

# Setup SSH for AUR
mkdir -p ~/.ssh
chmod 700 ~/.ssh

echo "$AUR_SSH_PRIVATE_KEY" > ~/.ssh/aur
chmod 600 ~/.ssh/aur

# Add AUR host key to known_hosts
ssh-keyscan -t ed25519 aur.archlinux.org >> ~/.ssh/known_hosts 2> /dev/null
chmod 644 ~/.ssh/known_hosts

# Use GIT_SSH_COMMAND to force SSH options
export GIT_SSH_COMMAND="ssh -i ~/.ssh/aur -o UserKnownHostsFile=~/.ssh/known_hosts -o StrictHostKeyChecking=no"

# Configure git
git config --global user.name "${AUR_USERNAME}"
git config --global user.email "${AUR_EMAIL}"
git config --global init.defaultBranch master

# Find packages with .aur marker
AUR_PACKAGES=$(find pkgs -maxdepth 2 -name '.aur' -printf '%h\n' | sort)

if [ -z "$AUR_PACKAGES" ]; then
    echo "No packages with .aur marker found."
    exit 0
fi

PUBLISHED=()
RETRYABLE=()
REJECTED=()
LAST_ERR=""

# Transient AUR failures: the maintenance banner or plain connectivity loss.
is_transient() {
    printf '%s' "$1" | grep -qiE 'down due to maintenance|connection (refused|timed out|reset)|could not resolve|operation timed out|remote end hung up|temporarily unavailable'
}

# Run a git command against the AUR, retrying transient failures with
# backoff. Leaves the failure text in LAST_ERR for classification.
aur_git() {
    local attempt
    for attempt in 1 2 3; do
        if LAST_ERR=$("$@" 2>&1); then
            return 0
        fi
        is_transient "$LAST_ERR" || return 1
        echo "Transient AUR error (attempt $attempt/3): retrying in $((attempt * 20))s..."
        sleep $((attempt * 20))
    done
    return 1
}

for pkg_dir in $AUR_PACKAGES; do
    pkgname=$(basename "$pkg_dir")
    echo "==> Processing $pkgname..."

    # Generate .SRCINFO
    echo "Generating .SRCINFO..."
    if ! su builder -c "cd $pkg_dir && makepkg --printsrcinfo > .SRCINFO"; then
        echo "::error::Failed to generate .SRCINFO for $pkgname"
        REJECTED+=("$pkgname")
        continue
    fi

    aur_repo="/tmp/aur-$pkgname"
    rm -rf "$aur_repo"

    # A clone failure is an infrastructure signal, never "package missing":
    # aurweb serves an empty repository for a name that has no package yet.
    # (The old fallback here ran `git init`, which made an AUR outage
    # indistinguishable from a batch of first-time publishes.)
    if ! aur_git git clone "ssh://aur@aur.archlinux.org/${pkgname}.git" "$aur_repo"; then
        if is_transient "$LAST_ERR"; then
            echo "::warning::$pkgname: AUR unreachable — reconcile.yml retries this. ($LAST_ERR)"
            RETRYABLE+=("$pkgname")
        else
            echo "::error::$pkgname: clone failed for a non-transient reason: $LAST_ERR"
            REJECTED+=("$pkgname")
        fi
        continue
    fi

    # Copy PKGBUILD and .SRCINFO
    cp "$pkg_dir/PKGBUILD" "$aur_repo/"
    cp "$pkg_dir/.SRCINFO" "$aur_repo/"

    # Copy any additional sources (patches, install files, etc.)
    for f in "$pkg_dir"/*.install "$pkg_dir"/*.patch "$pkg_dir"/*.sh; do
        [ -f "$f" ] && cp "$f" "$aur_repo/"
    done

    # Commit and push
    cd "$aur_repo"
    git add -A

    if git diff --cached --quiet; then
        echo "No changes for $pkgname"
    else
        # Get version for commit message
        version=$(grep -m1 "pkgver = " .SRCINFO | cut -d= -f2 | xargs)
        git commit -m "Update to $version"

        # The AUR only accepts master (empty clones inherit
        # init.defaultBranch=master from the config above).
        if aur_git git push origin master; then
            echo "::notice::Published $pkgname to AUR"
            PUBLISHED+=("$pkgname")
        elif is_transient "$LAST_ERR"; then
            echo "::warning::$pkgname: AUR unreachable during push — reconcile.yml retries this. ($LAST_ERR)"
            RETRYABLE+=("$pkgname")
        else
            echo "::error::$pkgname: push REJECTED: $LAST_ERR"
            REJECTED+=("$pkgname")
        fi
    fi
    cd - > /dev/null
done

# Summary
echo ""
echo "==> AUR Publish Summary"
echo "Published: ${PUBLISHED[*]:-none}"
echo "Retryable (AUR unreachable — reconcile re-drives): ${RETRYABLE[*]:-none}"
echo "Rejected (needs a human): ${REJECTED[*]:-none}"

if [ ${#REJECTED[@]} -gt 0 ] || [ ${#RETRYABLE[@]} -gt 0 ]; then
    exit 1
fi
