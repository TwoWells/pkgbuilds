# Provenance & Checksum Policy

How this repository decides which upstream bytes it trusts — for every
package it builds into the `twowells` pacman repository and publishes to
the AUR. This repo distributes **TwoWells products** (catenary, lattice,
themis); the maintainer's personal packages live in
[m-wells/pkgbuilds](https://github.com/m-wells/pkgbuilds) under the same
policy.

## Principles

1. **Checksums are normative, not descriptive.** A pin states what the
   artifact _must_ be, not what some download happened to hash to. When a
   downloaded artifact disagrees with its pin, the build fails
   (`scripts/lint.sh`) — that mismatch is a security signal to investigate,
   never something to re-hash and paper over. There is no auto-repair.
2. **Pins are written at bump time, from the most authoritative source
   available.** The update watcher (`scripts/check-updates.sh` +
   `scripts/lib/common.sh`) writes the new version _and_ its checksum in the
   same commit. Wherever a published claim exists — a registry digest, a
   release sidecar, another distro's reviewed recipe — the watcher copies
   the claim instead of hashing its own download.
3. **Weaker anchors are explicit and loud.** Where no published claim
   exists, the hash of a single bump-time download is pinned
   (trust-on-first-use) and then frozen; the pin's provenance is visible in
   the bump commit, and any later disagreement hard-fails.

## Trust classes

| Class  | Anchor                    | Meaning                                                                                                                                                                                                                                 |
| ------ | ------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **1**  | Published claim           | The expected hash is published by a party we already trust: a package registry (PyPI, MetaCPAN), a release `.sha256` sidecar, or Arch's packaging repo. Registries guarantee artifact immutability, so a later mismatch is unambiguous. |
| **1b** | Content-addressed         | The source is a git repository pinned by commit (`git+…#commit=`); git's object model verifies the tree, so the checksum array is legitimately `SKIP`.                                                                                  |
| **2**  | Trust-on-first-use (TOFU) | No published claim exists. The watcher hashes the artifact once, at bump time, and the pin is frozen thereafter. Last resort — every class-2 entry should have a path out.                                                              |

## Package inventory

| Package              | Upstream artifact             | Trust anchor                                                                           |
| -------------------- | ----------------------------- | -------------------------------------------------------------------------------------- |
| catenary             | GitHub tag archive (codeload) | Class 2 — TOFU at bump. _Class 1 pending: upstream will ship a src tarball + sidecar._ |
| catenary-bin         | GitHub release asset          | Class 1 — release `.sha256` sidecar                                                    |
| lattice-markdown     | GitHub tag archive (codeload) | Class 2 — TOFU at bump. _Class 1 pending, as above._                                   |
| lattice-markdown-bin | GitHub release asset          | Class 1 — release `.sha256` sidecar                                                    |
| themis               | GitHub tag archive (codeload) | Class 2 — TOFU at bump. _Class 1 pending, as above._                                   |
| themis-bin           | GitHub release asset          | Class 1 — release `.sha256` sidecar                                                    |

Secondary `LICENSE` sources (the `-bin` packages fetch the license from
the upstream tag, since their primary artifact doesn't
carry it): these are **static pins** — the URL moves with each version but
the bytes only change when the license text does. The watcher preserves
them untouched; if the text ever changes, verification hard-fails and a
human re-pins deliberately.

## Machinery map

- **Pinning** — `scripts/lib/common.sh`: `check_github_release_sidecar`
  (release sidecars) drives every `-bin` package; `check_pypi` /
  `check_cpan` (registry digests) and `check_github_release_pinned`
  (commit pins) are kept as twins with m-wells/pkgbuilds' copy. All pin
  paths verify their rewrite landed; a substitution that matches nothing
  fails.
- **Verification** — `scripts/lint.sh` runs `makepkg --verifysource` for
  every package on every build; any mismatch fails the run.
- **Hygiene** — `.pre-commit-config.yaml`: `forbid-checksum-skip` rejects
  `SKIP` sums except for the explicitly excluded commit-pinned packages;
  shellcheck/shfmt/bash -n cover the PKGBUILDs and scripts.
- **AUR reconciliation** — `.github/workflows/reconcile.yml` compares what
  aur.archlinux.org serves against local state on a schedule and re-drives
  the (idempotent) publish on drift, so a transient AUR outage can't leave
  a release silently unpublished.
- **Failure visibility** — a failed `aur-publish` opens or updates a
  GitHub issue (`aur-publish-alert` job in `build.yml`), distinguishing
  retryable outages from real push rejections.

## Adding a package

Pick the strongest anchor available, in this order:

1. **Registry digest** (PyPI, MetaCPAN, npm): use `check_pypi` /
   `check_cpan` — the digest rides the same API response as the version.
2. **Release `.sha256` sidecar**: use `check_github_release_sidecar`. For
   TwoWells upstreams the release contract requires sidecars — see
   CONTRIBUTING.md.
3. **Another distro's reviewed pin** (e.g. Arch's packaging repo) when the
   upstream publishes nothing: copy their claim — m-wells/pkgbuilds'
   nvidia watcher is the reference implementation.
4. **Commit pin** for tag-only upstreams with no stable artifacts: use
   `check_github_release_pinned`, set `_commit=` + `SKIP` in the PKGBUILD,
   and add the PKGBUILD to `forbid-checksum-skip`'s exclude list.
5. **TOFU** only when none of the above exists — document why in the
   PKGBUILD, and add the package to the inventory above with its path out.

Every new package gets a row in the inventory table.

## When verification fails

Do not "fix the checksum." Establish which side changed:

- Fetch the artifact from a second network path and compare hashes.
- Compare against the anchor (registry digest, sidecar, Arch's recipe).
- For codeload archives, remember GitHub regenerates them — a format
  change is possible (it has happened) and looks identical to tampering
  until you diff the contents.

Only after the cause is understood, re-pin with `make checksums
PKG=<name>` (local, deliberate, reviewed) or wait for the upstream fix.
