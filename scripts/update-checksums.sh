#!/bin/bash
# Updates checksums in a PKGBUILD file (supports sha256sums and sha512sums)
# Usage: update-checksums.sh path/to/PKGBUILD

set -e

PKGBUILD_PATH="$1"
PKGBUILD_DIR="$(dirname "$PKGBUILD_PATH")"
PKGBUILD_FILE="$(basename "$PKGBUILD_PATH")"

# Ensure we are in the correct directory for local file sources
cd "$PKGBUILD_DIR"

# Source the PKGBUILD to get variables
# shellcheck source=/dev/null
source "$PKGBUILD_FILE"

# Determine checksum type
if grep -q "sha512sums=" "$PKGBUILD_FILE"; then
    algo="sha512"
    sum_cmd="sha512sum"
else
    algo="sha256"
    sum_cmd="sha256sum"
fi

echo "Updating $algo checksums for $PKGBUILD_PATH..."

# Calculate checksums for each source
sums=()
# shellcheck disable=SC2154
for src in "${source[@]}"; do
    # Handle source with custom filename (filename::url)
    if [[ "$src" == *::* ]]; then
        url="${src#*::}"
    else
        url="$src"
    fi

    # Expand variables in URL
    url=$(eval echo "$url")

    # git sources are content-addressed by their #commit= fragment — there is
    # no tarball to hash, and makepkg requires SKIP for them.
    if [[ "$url" == git+* ]]; then
        sums+=("'SKIP'")
        continue
    fi

    echo "Fetching: $url" >&2
    if [[ "$url" == http* ]]; then
        # Determine the local filename (matches what makepkg expects)
        if [[ "$src" == *::* ]]; then
            local_name="${src%%::*}"
        else
            local_name="$(basename "$url")"
        fi

        # Download to the PKGBUILD directory so makepkg finds it on
        # subsequent --verifysource without re-downloading
        if ! curl -sLf "$url" -o "$local_name"; then
            echo "Error: Failed to download $url" >&2
            rm -f "$local_name"
            exit 1
        fi
        sha=$($sum_cmd "$local_name" | cut -d' ' -f1)
    else
        # Local file
        if [ -f "$url" ]; then
            sha=$($sum_cmd "$url" | cut -d' ' -f1)
        else
            echo "Error: Local file $url not found" >&2
            exit 1
        fi
    fi
    sums+=("'$sha'")
done

# Update PKGBUILD
checksums=$(
    IFS=$'\n'
    echo "${sums[*]}" | tr '\n' ' ' | sed 's/ $//'
)

# Replace the existing checksum array (handles multi-line).
# Pass via env vars so perl handles quoting safely — bash-level escaping in a
# double-quoted program is how this substitution once matched nothing for
# years while exiting 0.
NEWSUMS="${algo}sums=($checksums)" ALGO="$algo" \
    perl -i -0777 -pe 's/$ENV{ALGO}sums=\(.*?\)/$ENV{NEWSUMS}/s' "$PKGBUILD_FILE"

# The rewrite must be provable, not assumed: a substitution that matched
# nothing exits 0 too.
if ! grep -qF "${algo}sums=($checksums)" "$PKGBUILD_FILE"; then
    echo "Error: rewrite of ${algo}sums in $PKGBUILD_PATH did not take" >&2
    exit 1
fi

echo "Updated $algo checksums in $PKGBUILD_PATH" >&2
