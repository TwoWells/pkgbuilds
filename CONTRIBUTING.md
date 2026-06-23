# Contributing to pkgbuilds

This guide provides instructions for building, testing, and adding packages to this repository.

For detailed documentation, see the [wiki](https://github.com/TwoWells/pkgbuilds/wiki):

- [CI/CD Pipeline](https://github.com/TwoWells/pkgbuilds/wiki/CI-CD) — build pipeline, auto-repair, atomic releases
- [Build Patterns](https://github.com/TwoWells/pkgbuilds/wiki/Build-Patterns) — npm, Python, AppImage, and binary packaging

## Development Environment

These instructions assume you are using Arch Linux.

### Make targets

A `Makefile` wraps the common workflows (run `make help` for the full list).
Per-package targets take `PKG=<name>`:

```bash
make build PKG=themis     # makepkg -sf
make test PKG=themis-bin  # build, then run check.sh smoke test
make checksums PKG=themis # updpkgsums
make srcinfo PKG=themis   # regenerate .SRCINFO
```

Repo-wide: `make fmt` (shfmt), `make shellcheck`, `make lint` (full CI lint),
and `make pre-commit`. These mirror the CI and pre-commit configuration, so
passing them locally matches what CI runs.

### Building Packages Locally

```bash
cd pkgs/[package-name]
makepkg -s
```

Common flags:

- `-s`: Install missing dependencies automatically
- `-f`: Force rebuild (overwrite existing package)

### Updating Checksums

If you change source URLs or manually bump versions, re-pin the checksums.
`SKIP` is rejected by the `forbid-checksum-skip` pre-commit hook, so checksums
must be real:

```bash
make checksums PKG=<name>   # or: cd pkgs/<name> && updpkgsums
```

## Repository Structure

```text
pkgs/
├── gemini-cli/
│   ├── PKGBUILD
│   ├── .local           # ← build + publish to GitHub releases
│   └── check.sh
├── keeper-secrets-manager-helper/
│   ├── PKGBUILD
│   └── .aur             # ← push to AUR only
└── some-package/
    ├── PKGBUILD
    ├── .local           # ← can have both markers
    ├── .aur
    └── check.sh
```

### Target Markers

| Marker   | Behavior                             |
| -------- | ------------------------------------ |
| `.local` | Build and publish to GitHub releases |
| `.aur`   | Push PKGBUILD to AUR                 |

> **Repository name:** the pacman repo and its database are named
> `markwells-dev` (`markwells-dev.db`), set via `REPO_NAME` in
> `scripts/lib/common.sh`. This is intentionally _not_ the GitHub org name
> (`TwoWells`): the org was renamed, the published database was not. Do not
> rename it to match the org — that breaks installed users' `pacman.conf` and
> the `[markwells-dev]` Server/database lookups.

## Adding a New Package

1. Create directory in `pkgs/` (name must match `pkgname`)
2. Add `PKGBUILD` following appropriate [build pattern](https://github.com/TwoWells/pkgbuilds/wiki/Build-Patterns)
3. Add target marker (`.local`, `.aur`, or both)
4. Add `check.sh` smoke test (for `.local` packages)
5. Add version check script in `scripts/packages/[pkgname].sh`

## Automated Updates

Version checks run via GitHub Actions. Add a script in `scripts/packages/`:

```bash
# scripts/packages/example.sh
check_example() {
  local latest=$(curl -s "https://api.example.com/version")
  perform_update "example" "$latest"
}
check_example
```

Common version sources:

- **npm**: `npm view @scope/package version`
- **PyPI**: `curl -s https://pypi.org/pypi/package/json | jq -r .info.version`
- **GitHub**: `curl -s https://api.github.com/repos/org/repo/releases/latest | jq -r .tag_name`
