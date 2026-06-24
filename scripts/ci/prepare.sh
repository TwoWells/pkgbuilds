#!/bin/bash
set -e

# prepare.sh: Determines which packages need building.
# Outputs: 'matrix', 'removed', 'run_publish', 'has_work' to $GITHUB_OUTPUT
# All packages build on the single ubuntu-latest 'build' job.

# Source common variables
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/common.sh"

echo "==> Preparing build matrix..."

# Ensure we have the builder user (setup.sh should have run)
if ! id -u builder > /dev/null 2>&1; then
    echo "Error: builder user not found. Run setup.sh first."
    exit 1
fi

mkdir -p repo

# Check for manual publish flag in commit message
if echo "$COMMIT_MESSAGE" | grep -qi "\[publish\]"; then
    echo "Manual publish requested via commit message."
    MANUAL_PUBLISH=true
elif git log -1 --pretty=%B 2> /dev/null | grep -qi "\[publish\]"; then
    echo "Manual publish requested via git log."
    MANUAL_PUBLISH=true
fi

# 1. Download Repository Database
echo "==> Downloading repository database..."

MIGRATED=false
# Attempt to download current DB
if ! err=$(gh release download --repo "$GITHUB_REPOSITORY" --pattern "${REPO_NAME}.db.tar.gz" --dir repo 2>&1); then
    # Check if failure is due to missing release or asset
    if echo "$err" | grep -qiE "not found|no release found|no assets"; then
        echo "No new database found ($err). Checking for old '${OLD_REPO_NAME}' database for migration..."

        # Check for old DB
        if gh release download --repo "$GITHUB_REPOSITORY" --pattern "${OLD_REPO_NAME}.db.tar.gz" --dir repo 2> /dev/null; then
            echo "Found old database. Migrating to '${REPO_NAME}'..."
            mv "repo/${OLD_REPO_NAME}.db.tar.gz" "repo/${REPO_NAME}.db.tar.gz"
            # Also try to get the old files db if it exists
            if gh release download --repo "$GITHUB_REPOSITORY" --pattern "${OLD_REPO_NAME}.files.tar.gz" --dir repo 2> /dev/null; then
                mv "repo/${OLD_REPO_NAME}.files.tar.gz" "repo/${REPO_NAME}.files.tar.gz"
            fi

            # To migrate successfully, we need the actual package files for repo-add
            echo "Downloading existing packages for database migration..."
            gh release download --repo "$GITHUB_REPOSITORY" --pattern '*.pkg.tar.zst' --dir repo 2> /dev/null || true
            MIGRATED=true
        else
            echo "No existing database found. Starting fresh."
        fi
    else
        # Some other error occurred (network, auth, etc.)
        echo "::error::Failed to download database: $err"
        exit 1
    fi
else
    # Also try to get the files db
    gh release download --repo "$GITHUB_REPOSITORY" --pattern "${REPO_NAME}.files.tar.gz" --dir repo 2> /dev/null || true

    # If manual publish requested, download packages so they can be re-indexed/signed
    if [ "$MANUAL_PUBLISH" = "true" ]; then
        echo "Downloading existing packages for manual publish..."
        gh release download --repo "$GITHUB_REPOSITORY" --pattern '*.pkg.tar.zst' --dir repo 2> /dev/null || true
    fi
fi

# Extract DB to read versions
mkdir -p repo/db_content
if [ -f "repo/${REPO_NAME}.db.tar.gz" ]; then
    tar -xf "repo/${REPO_NAME}.db.tar.gz" -C repo/db_content
fi

# 2. Map Current DB Versions
touch db_versions.txt
find repo/db_content -name desc | while read -r desc_file; do
    name=$(grep -A1 "%NAME%" "$desc_file" | tail -n1)
    ver=$(grep -A1 "%VERSION%" "$desc_file" | tail -n1)
    echo "$name $ver" >> db_versions.txt
done
echo "Current DB versions:"
cat db_versions.txt

# Clean up extracted content to avoid artifact upload issues (colons in filenames)
rm -rf repo/db_content

# 3. Scan Local Packages
# Find directories containing PKGBUILD
ALL_PACKAGES=$(find . -maxdepth 3 -name PKGBUILD -printf '%h\n' | sed 's|^\./||' | sort | tr '\n' ' ' | xargs)
echo "All packages: $ALL_PACKAGES"

# Filter to only packages with .local marker (for building)
LOCAL_PACKAGES=""
for pkg in $ALL_PACKAGES; do
    if [ -f "$pkg/.local" ]; then
        LOCAL_PACKAGES="$LOCAL_PACKAGES $pkg"
    fi
done
LOCAL_PACKAGES=$(echo "$LOCAL_PACKAGES" | xargs)
echo "Local packages (with .local marker): $LOCAL_PACKAGES"

PACKAGES_TO_BUILD=()
REMOVED_PACKAGES=()

# Check for forced rebuild
if [ "$FORCE_REBUILD" = "true" ]; then
    echo "Force rebuild active: building all local packages."
    for pkg in $LOCAL_PACKAGES; do
        PACKAGES_TO_BUILD+=("$pkg")
    done
else
    # Standard change detection (only for .local packages)
    for pkg in $LOCAL_PACKAGES; do
        echo "Checking $pkg..."

        # Parse PKGBUILD using makepkg (as builder)
        echo "Parsing PKGBUILD for $pkg..."
        if ! srcinfo=$(su builder -c "cd $pkg && makepkg --printsrcinfo" 2>&1); then
            echo "::error::Failed to parse PKGBUILD for $pkg. Error output:"
            echo "$srcinfo"
            exit 1
        fi

        p_name=$(echo "$srcinfo" | grep -P '^\t?pkgname =' | cut -d= -f2 | xargs)
        p_ver=$(echo "$srcinfo" | grep -P '^\t?pkgver =' | cut -d= -f2 | xargs)
        p_rel=$(echo "$srcinfo" | grep -P '^\t?pkgrel =' | cut -d= -f2 | xargs)
        p_epoch=$(echo "$srcinfo" | grep -P '^\t?epoch =' | cut -d= -f2 | xargs)

        if [ -n "$p_epoch" ]; then
            local_ver="${p_epoch}:${p_ver}-${p_rel}"
        else
            local_ver="${p_ver}-${p_rel}"
        fi

        # Find version in DB using actual package name (not directory path)
        db_ver=$(grep "^$p_name " db_versions.txt | cut -d' ' -f2 || echo "")

        if [ -z "$db_ver" ]; then
            echo "New package: $pkg ($local_ver)"
            PACKAGES_TO_BUILD+=("$pkg")
        else
            # Compare versions
            cmp_res=$(vercmp "$local_ver" "$db_ver")
            if [ "$cmp_res" -ne 0 ]; then
                echo "Update needed for $pkg: DB($db_ver) -> Local($local_ver)"
                PACKAGES_TO_BUILD+=("$pkg")
            else
                echo "$pkg is up to date ($local_ver)"
            fi
        fi
    done
fi

# 4. Detect removed packages
while read -r line; do
    [ -z "$line" ] && continue
    db_name=$(echo "$line" | cut -d' ' -f1)
    # Check if db_name exists in ALL_PACKAGES (compare using basename since paths are now pkgs/name)
    found=false
    for pkg in $ALL_PACKAGES; do
        pkg_basename=$(basename "$pkg")
        if [ "$pkg_basename" = "$db_name" ]; then
            found=true
            break
        fi
    done
    if [ "$found" = "false" ]; then
        echo "Package $db_name is in DB but not local (will be removed)."
        REMOVED_PACKAGES+=("$db_name")
    fi
done < db_versions.txt

# 5. Sort packages by dependencies (base packages first)
# This ensures packages are built in the right order for the local repo
sort_by_dependencies() {
    local packages=("$@")
    local sorted=()
    local remaining=("${packages[@]}")

    # Get all package names from our local packages
    declare -A local_pkg_names
    for pkg in "${packages[@]}"; do
        local name
        name=$(su builder -c "cd $pkg && makepkg --printsrcinfo" 2> /dev/null | grep -P '^\t?pkgname =' | cut -d= -f2 | xargs)
        local_pkg_names["$name"]="$pkg"
    done

    # Simple topological sort: packages with no local deps first
    while [ ${#remaining[@]} -gt 0 ]; do
        local made_progress=false
        local still_remaining=()

        for pkg in "${remaining[@]}"; do
            local deps
            deps=$(su builder -c "cd $pkg && makepkg --printsrcinfo" 2> /dev/null | awk '/^\s+depends\s+=\s+/{ print $3 }')

            local has_unsorted_dep=false
            for dep in $deps; do
                # Strip version constraints
                dep_name="${dep%%[<>=]*}"
                # Check if this dep is a local package that hasn't been sorted yet
                if [ -n "${local_pkg_names[$dep_name]}" ]; then
                    local dep_pkg="${local_pkg_names[$dep_name]}"
                    # Check if dep_pkg is still in remaining
                    for r in "${remaining[@]}"; do
                        if [ "$r" = "$dep_pkg" ] && [ "$r" != "$pkg" ]; then
                            has_unsorted_dep=true
                            break
                        fi
                    done
                fi
                [ "$has_unsorted_dep" = true ] && break
            done

            if [ "$has_unsorted_dep" = false ]; then
                sorted+=("$pkg")
                made_progress=true
            else
                still_remaining+=("$pkg")
            fi
        done

        remaining=("${still_remaining[@]}")

        # Prevent infinite loop (circular deps)
        if [ "$made_progress" = false ] && [ ${#remaining[@]} -gt 0 ]; then
            echo "::warning::Circular dependency detected, adding remaining packages unsorted"
            sorted+=("${remaining[@]}")
            break
        fi
    done

    printf '%s\n' "${sorted[@]}"
}

if [ ${#PACKAGES_TO_BUILD[@]} -gt 0 ]; then
    echo "==> Sorting packages by dependencies..."
    mapfile -t SORTED_PACKAGES < <(sort_by_dependencies "${PACKAGES_TO_BUILD[@]}")
    PACKAGES_TO_BUILD=("${SORTED_PACKAGES[@]}")
    echo "Build order: ${PACKAGES_TO_BUILD[*]}"
fi

# 6. Output results to GitHub Actions
# Convert arrays to JSON safely
if [ ${#PACKAGES_TO_BUILD[@]} -eq 0 ]; then
    matrix_json="[]"
else
    matrix_json=$(printf '%s\n' "${PACKAGES_TO_BUILD[@]}" | jq -R . | jq -s -c .)
fi

if [ ${#REMOVED_PACKAGES[@]} -eq 0 ]; then
    removed_json="[]"
else
    removed_json=$(printf '%s\n' "${REMOVED_PACKAGES[@]}" | jq -R . | jq -s -c .)
fi

# Use heredoc for multi-line values in GITHUB_OUTPUT
{
    echo "matrix<<EOF"
    echo "$matrix_json"
    echo "EOF"
    echo "removed<<EOF"
    echo "$removed_json"
    echo "EOF"
} >> "$GITHUB_OUTPUT"

# Determine flags
if [ ${#PACKAGES_TO_BUILD[@]} -gt 0 ] || [ ${#REMOVED_PACKAGES[@]} -gt 0 ] || [ "$MIGRATED" = "true" ] || [ "$MANUAL_PUBLISH" = "true" ]; then
    echo "has_work=true" >> "$GITHUB_OUTPUT"
    echo "run_publish=true" >> "$GITHUB_OUTPUT"
else
    echo "has_work=false" >> "$GITHUB_OUTPUT"
    # If FIX_SIGNATURES is set, we still need to run publish
    if [ "$FIX_SIGNATURES" = "true" ]; then
        echo "run_publish=true" >> "$GITHUB_OUTPUT"
        echo "Fix signatures requested."
    else
        echo "run_publish=false" >> "$GITHUB_OUTPUT"
    fi
fi

echo "Preparation complete."
echo "Matrix: $matrix_json"
echo "Removed: $removed_json"
