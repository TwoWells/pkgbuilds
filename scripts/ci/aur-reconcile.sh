#!/bin/bash
set -e

# aur-reconcile.sh: detect drift between local .aur-marked packages and what
# aur.archlinux.org actually serves; dispatch build.yml (whose aur-publish
# leg is idempotent — already-current packages are no-ops) when anything is
# behind. This is the durable retry for publishes that failed transiently.
#
# The AUR is read anonymously via `git clone` — the git transport passes the
# Anubis anti-bot wall that blocks plain HTTP fetches of the RPC endpoint.
# An empty repository (no .SRCINFO) means the name has never been published:
# that counts as drift. A clone FAILURE means the AUR itself is unreachable:
# skip quietly and let the next scheduled pass retry.
#
# (epoch is ignored in the comparison: no .aur package uses one — extend
# this if that changes.)

DRIFT=()
UNREACHABLE=()

for marker in pkgs/*/.aur; do
    pkg_dir=$(dirname "$marker")
    pkgname=$(basename "$pkg_dir")

    local_ver=$(grep '^pkgver=' "$pkg_dir/PKGBUILD" | cut -d= -f2)
    local_rel=$(grep '^pkgrel=' "$pkg_dir/PKGBUILD" | cut -d= -f2)

    tmp=$(mktemp -d)
    if git clone --quiet --depth 1 "https://aur.archlinux.org/${pkgname}.git" "$tmp" 2> /dev/null; then
        aur_ver=$(sed -n 's/^[[:space:]]*pkgver = //p' "$tmp/.SRCINFO" 2> /dev/null)
        aur_rel=$(sed -n 's/^[[:space:]]*pkgrel = //p' "$tmp/.SRCINFO" 2> /dev/null)
        if [ "$local_ver-$local_rel" == "$aur_ver-$aur_rel" ]; then
            echo "$pkgname: in sync ($local_ver-$local_rel)"
        else
            echo "::warning::$pkgname: local $local_ver-$local_rel, AUR ${aur_ver:-<unpublished>}${aur_rel:+-$aur_rel} — will republish"
            DRIFT+=("$pkgname")
        fi
    else
        echo "::warning::$pkgname: AUR clone failed (unreachable?) — leaving for the next pass"
        UNREACHABLE+=("$pkgname")
    fi
    rm -rf "$tmp"
done

echo ""
if [ ${#DRIFT[@]} -gt 0 ]; then
    echo "==> Drift detected (${DRIFT[*]}) — dispatching build.yml."
    gh workflow run build.yml --ref "${GITHUB_REF_NAME:-main}"
elif [ ${#UNREACHABLE[@]} -gt 0 ]; then
    echo "==> No confirmed drift; AUR unreachable for: ${UNREACHABLE[*]} — the next scheduled pass retries."
else
    echo "==> All .aur packages are in sync with the AUR."
fi
