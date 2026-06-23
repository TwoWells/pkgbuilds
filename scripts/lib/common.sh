#!/bin/bash
# shellcheck disable=SC2034

# Configuration
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# REPO_NAME is the pacman repository + database name (markwells-dev.db). It is
# intentionally NOT GITHUB_ORG: the org was renamed to TwoWells, but the
# published database is still markwells-dev. Do not rename it to match the org —
# that breaks every installed user's pacman.conf and the [markwells-dev]
# Server/database lookups. OLD_REPO_NAME is the pre-rename name, kept so old
# databases can still be migrated.
REPO_NAME="markwells-dev"
OLD_REPO_NAME="mark-wells-dev"
GITHUB_ORG="TwoWells"
GITHUB_REPO="pkgbuilds"

get_local_version() {
    local pkgbuild="$1"
    grep "^pkgver=" "$pkgbuild" | cut -d'=' -f2
}

perform_update() {
    local pkg_name="$1"
    local new_ver="$2"
    local pkg_dir="$3" # Optional, defaults to pkgs/pkg_name

    [ -z "$pkg_dir" ] && pkg_dir="pkgs/$pkg_name"
    local pkgbuild="$REPO_ROOT/$pkg_dir/PKGBUILD"

    if [ ! -f "$pkgbuild" ]; then
        echo "Error: PKGBUILD not found at $pkgbuild"
        return 1
    fi

    local old_ver
    old_ver=$(get_local_version "$pkgbuild")

    if [ "$old_ver" == "$new_ver" ]; then
        # echo "$pkg_name is up to date ($old_ver)"
        return 0
    fi

    echo "Updating $pkg_name from $old_ver to $new_ver..."

    # Update version
    sed -i "s/^pkgver=.*/pkgver=$new_ver/" "$pkgbuild"

    # Reset pkgrel to 1
    sed -i "s/^pkgrel=.*/pkgrel=1/" "$pkgbuild"

    # Update checksums
    if ! "$REPO_ROOT/scripts/update-checksums.sh" "$pkgbuild"; then
        echo "::error::Checksum update failed for $pkg_name. Reverting changes..."
        git checkout "$pkgbuild"
        return 1
    fi

    # Commit changes
    if [ -n "$CI" ]; then
        git config --global user.name "Updater Bot"
        git config --global user.email "bot@noreply.github.com"
    fi

    git add "$pkgbuild"
    git commit -m "chore($pkg_name): update to $new_ver"
}

# Version check helpers for common package sources

check_pypi() {
    local pkg_name="$1"
    local pypi_name="${2:-$pkg_name}"
    echo "Checking $pkg_name via PyPI..."

    local latest_ver
    latest_ver=$(curl -s "https://pypi.org/pypi/${pypi_name}/json" | jq -r .info.version)

    if [ -n "$latest_ver" ] && [ "$latest_ver" != "null" ]; then
        perform_update "$pkg_name" "$latest_ver"
    else
        echo "Failed to check version for $pkg_name"
    fi
}

check_npm() {
    local pkg_name="$1"
    local npm_name="${2:-$pkg_name}"
    echo "Checking $pkg_name via npm..."

    # URL-encode scoped package names (@scope/pkg -> @scope%2Fpkg)
    local encoded_name="${npm_name/@/%40}"
    encoded_name="${encoded_name/\//%2F}"

    local latest_ver
    latest_ver=$(curl -s "https://registry.npmjs.org/${encoded_name}/latest" | jq -r .version)

    if [ -n "$latest_ver" ] && [ "$latest_ver" != "null" ]; then
        perform_update "$pkg_name" "$latest_ver"
    else
        echo "Failed to check version for $pkg_name"
    fi
}

check_cpan() {
    local pkg_name="$1"
    local dist_name="$2" # CPAN distribution name, e.g. Config-IniFiles
    echo "Checking $pkg_name via CPAN (MetaCPAN)..."

    local latest_ver
    latest_ver=$(curl -s "https://fastapi.metacpan.org/v1/release/${dist_name}" | jq -r .version)

    if [ -n "$latest_ver" ] && [ "$latest_ver" != "null" ]; then
        perform_update "$pkg_name" "$latest_ver"
    else
        echo "Failed to check version for $pkg_name"
    fi
}

check_github_release() {
    local pkg_name="$1"
    local repo="$2"
    local strip_v="${3:-true}"
    echo "Checking $pkg_name via GitHub releases..."

    local latest_ver
    latest_ver=$(curl -s "https://api.github.com/repos/${repo}/releases/latest" | jq -r .tag_name)

    if [ -n "$latest_ver" ] && [ "$latest_ver" != "null" ]; then
        [ "$strip_v" = "true" ] && latest_ver="${latest_ver#v}"
        perform_update "$pkg_name" "$latest_ver"
    else
        echo "Failed to check version for $pkg_name"
    fi
}
