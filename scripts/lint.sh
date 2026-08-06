#!/bin/bash
set -e

# lint.sh: Runs syntax checks on all PKGBUILDs and verifies every source
# against its pinned checksum. A mismatch HARD-FAILS the run: pins are
# written at bump time from an authoritative claim (see PROVENANCE.md), so a
# disagreeing artifact is a security signal to investigate — never something
# to re-hash and paper over.

echo "==> Linting PKGBUILDs..."

# Find all directories containing PKGBUILD
ALL_PACKAGES=$(find . -maxdepth 3 -name PKGBUILD -printf '%h\n' | sed 's|\./||' | sort)

FAILURE=0

run_verifysource() {
    local pkg="$1"
    if [ "$(id -u)" -eq 0 ]; then
        if id -u builder > /dev/null 2>&1; then
            su builder -c "cd $pkg && makepkg --verifysource -f"
        else
            echo "::warning::Running as root and 'builder' user not found. Skipping source verification."
            return 0
        fi
    else
        (cd "$pkg" && makepkg --verifysource -f)
    fi
}

for pkg in $ALL_PACKAGES; do
    echo "Checking $pkg/PKGBUILD..."

    # 1. Shell syntax check
    if ! bash -n "$pkg/PKGBUILD"; then
        echo "::error file=$pkg/PKGBUILD::Bash syntax error"
        FAILURE=1
    fi

    # 2. Source verification (checksum check)
    echo "Verifying sources for $pkg..."
    if ! run_verifysource "$pkg"; then
        echo "::error file=$pkg/PKGBUILD::Source verification FAILED — the artifact does not match its pinned checksum. This is a security signal: find out why the upstream bytes changed before touching the pin (see PROVENANCE.md). Never re-pin just to make the build pass."
        FAILURE=1
    fi

    # 3. namcap check (if available)
    if command -v namcap > /dev/null; then
        if ! namcap -r PKGBUILD "$pkg/PKGBUILD" > /dev/null; then
            :
        fi
    fi
done

if [ $FAILURE -eq 1 ]; then
    echo "Linting failed."
    exit 1
fi

echo "Linting passed."
