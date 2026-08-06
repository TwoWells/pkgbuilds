#!/bin/bash
# shellcheck disable=SC2034

# Configuration
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# REPO_NAME is the pacman repository + database name (twowells.db) — the
# TwoWells product channel. Renamed from markwells-dev in the 2026-08 split,
# when the personal packages (and the markwells-dev name with them) moved to
# m-wells/pkgbuilds; adoption was judged low enough for the rename to break
# no one. OLD_REPO_NAME drives prepare.sh's one-time in-place migration of
# the existing database.
REPO_NAME="twowells"
OLD_REPO_NAME="markwells-dev"
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

    # Update checksums. A caller holding an authoritative published claim
    # bypasses hash-the-download entirely (see PROVENANCE.md):
    #   UPDATE_PIN_COMMIT — rewrite the _commit= line for a git source
    #                       (content-addressed; the checksum array stays SKIP)
    #   UPDATE_PIN_SUMS   — inner checksum-array text to pin verbatim,
    #                       e.g. "'<hash>'" (copied from e.g. Arch's .SRCINFO)
    #   UPDATE_PIN_ALGO   — optional algorithm of the pinned values; converts
    #                       the array name when it differs (sha512 → sha256)
    if [ -n "$UPDATE_PIN_COMMIT" ]; then
        sed -i "s/^_commit=.*/_commit=$UPDATE_PIN_COMMIT/" "$pkgbuild"
        if ! grep -q "^_commit=$UPDATE_PIN_COMMIT" "$pkgbuild"; then
            echo "::error::Commit pin failed for $pkg_name. Reverting changes..."
            git checkout "$pkgbuild"
            return 1
        fi
    elif [ -n "$UPDATE_PIN_SUMS" ]; then
        if ! set_checksum_array "$pkgbuild" "$UPDATE_PIN_SUMS" "$UPDATE_PIN_ALGO"; then
            echo "::error::Checksum pin failed for $pkg_name. Reverting changes..."
            git checkout "$pkgbuild"
            return 1
        fi
    elif ! "$REPO_ROOT/scripts/update-checksums.sh" "$pkgbuild"; then
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

# Overwrite a PKGBUILD's checksum array with externally-claimed values.
# $2 is the inner array text, e.g. "'<hash>'" or "'<h1>' '<h2>'".
# $3 (optional) names the algorithm of the pinned values; when it differs
# from what the file uses, the array name is converted too (sha512 → sha256
# happens when a registry publishes only sha256).
set_checksum_array() {
    local pkgbuild="$1"
    local values="$2"
    local want="${3:-}"

    local have="sha256"
    if grep -q "^sha512sums=" "$pkgbuild"; then
        have="sha512"
    fi
    local algo="${want:-$have}"

    # Pass via env vars so perl handles quoting safely, and verify the
    # rewrite took — a substitution that matches nothing also exits 0.
    NEWSUMS="${algo}sums=($values)" HAVE="$have" \
        perl -i -0777 -pe 's/$ENV{HAVE}sums=\(.*?\)/$ENV{NEWSUMS}/s' "$pkgbuild"
    grep -qF "${algo}sums=($values)" "$pkgbuild"
}

# Compose an UPDATE_PIN_SUMS value: replace the first checksum entry with $2
# and preserve any trailing entries — e.g. a tag-pinned LICENSE hash, which
# only changes when the license text does (and then hard-fails verification
# until a human re-pins it deliberately). Only safe when the trailing entries
# already use the algorithm being pinned.
pin_first_checksum() {
    local pkgbuild="$1"
    local first="$2"

    local inner tail
    inner=$(perl -0777 -ne 'print $2 if /(sha256|sha512)sums=\((.*?)\)/s' "$pkgbuild")
    tail=$(printf '%s' "$inner" | tr '\n' ' ' | sed -E "s/^[[:space:]]*'[^']*'[[:space:]]*//; s/[[:space:]]+/ /g; s/[[:space:]]+$//")
    if [ -n "$tail" ]; then
        printf "'%s' %s" "$first" "$tail"
    else
        printf "'%s'" "$first"
    fi
}

# Version check helpers for common package sources

check_pypi() {
    local pkg_name="$1"
    local pypi_name="${2:-$pkg_name}"
    echo "Checking $pkg_name via PyPI..."

    local json latest_ver sdist_sha
    json=$(curl -s "https://pypi.org/pypi/${pypi_name}/json")
    latest_ver=$(printf '%s' "$json" | jq -r .info.version)

    if [ -z "$latest_ver" ] || [ "$latest_ver" == "null" ]; then
        echo "Failed to check version for $pkg_name"
        return 0
    fi

    # The same response publishes the sdist's sha256, and PyPI files are
    # immutable — pin the registry's claim, never a hash of our own download.
    sdist_sha=$(printf '%s' "$json" | jq -r '[.urls[] | select(.packagetype == "sdist")][0].digests.sha256 // empty')
    if ! [[ "$sdist_sha" =~ ^[0-9a-f]{64}$ ]]; then
        echo "::error::PyPI returned no sdist sha256 for ${pypi_name} ${latest_ver} — skipping bump"
        return 1
    fi

    UPDATE_PIN_SUMS="$(pin_first_checksum "$REPO_ROOT/pkgs/$pkg_name/PKGBUILD" "$sdist_sha")" \
    UPDATE_PIN_ALGO="sha256" \
        perform_update "$pkg_name" "$latest_ver"
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

    local json latest_ver dist_sha
    json=$(curl -s "https://fastapi.metacpan.org/v1/release/${dist_name}")
    latest_ver=$(printf '%s' "$json" | jq -r .version)

    if [ -z "$latest_ver" ] || [ "$latest_ver" == "null" ]; then
        echo "Failed to check version for $pkg_name"
        return 0
    fi

    # The same response publishes the release tarball's sha256, and CPAN
    # artifacts are immutable — pin the claim. This also converts a legacy
    # sha512 pin to sha256 on the first bump that lands after it.
    dist_sha=$(printf '%s' "$json" | jq -r '.checksum_sha256 // empty')
    if ! [[ "$dist_sha" =~ ^[0-9a-f]{64}$ ]]; then
        echo "::error::MetaCPAN returned no sha256 for ${dist_name} ${latest_ver} — skipping bump"
        return 1
    fi

    UPDATE_PIN_SUMS="'$dist_sha'" UPDATE_PIN_ALGO="sha256" \
        perform_update "$pkg_name" "$latest_ver"
}

# For -bin packages whose release asset ships a .sha256 sidecar (all TwoWells
# upstreams publish one per asset — that is what the sidecars are for): pin
# the sidecar's claim for the first source, preserving trailing pins (the
# tag-pinned LICENSE). $3 is the exact asset name on the release.
check_github_release_sidecar() {
    local pkg_name="$1"
    local repo="$2"
    local asset="$3"
    local strip_v="${4:-true}"
    echo "Checking $pkg_name via GitHub releases (sidecar-pinned)..."

    local tag
    tag=$(curl -s "https://api.github.com/repos/${repo}/releases/latest" | jq -r .tag_name)
    if [ -z "$tag" ] || [ "$tag" == "null" ]; then
        echo "Failed to check version for $pkg_name"
        return 0
    fi

    local sidecar sha
    if ! sidecar=$(curl -sLf "https://github.com/${repo}/releases/download/${tag}/${asset}.sha256"); then
        echo "::error::No .sha256 sidecar for ${repo}@${tag} asset ${asset} — skipping bump"
        return 1
    fi
    sha="${sidecar%% *}"
    if ! [[ "$sha" =~ ^[0-9a-f]{64}$ ]]; then
        echo "::error::Sidecar for ${asset} (${repo}@${tag}) does not contain a sha256 — skipping bump"
        return 1
    fi

    local ver="$tag"
    [ "$strip_v" = "true" ] && ver="${tag#v}"
    UPDATE_PIN_SUMS="$(pin_first_checksum "$REPO_ROOT/pkgs/$pkg_name/PKGBUILD" "$sha")" \
        perform_update "$pkg_name" "$ver"
}

# Like check_github_release, but for upstreams whose releases carry no stable
# artifact or published digest (GitHub tag tarballs are not byte-stable):
# resolves the release tag to a commit and pins the PKGBUILD's _commit= line,
# so git's content addressing verifies the source and sums stay SKIP.
check_github_release_pinned() {
    local pkg_name="$1"
    local repo="$2"
    local strip_v="${3:-true}"
    echo "Checking $pkg_name via GitHub releases (commit-pinned)..."

    local tag
    tag=$(curl -s "https://api.github.com/repos/${repo}/releases/latest" | jq -r .tag_name)
    if [ -z "$tag" ] || [ "$tag" == "null" ]; then
        echo "Failed to check version for $pkg_name"
        return 0
    fi

    local commit
    commit=$(curl -s "https://api.github.com/repos/${repo}/commits/${tag}" | jq -r .sha)
    if ! [[ "$commit" =~ ^[0-9a-f]{40}$ ]]; then
        echo "::error::Could not resolve ${repo}@${tag} to a commit for $pkg_name"
        return 1
    fi

    local ver="$tag"
    [ "$strip_v" = "true" ] && ver="${tag#v}"
    UPDATE_PIN_COMMIT="$commit" perform_update "$pkg_name" "$ver"
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
