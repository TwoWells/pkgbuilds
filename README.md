# pkgbuilds

[![Build packages](https://github.com/TwoWells/pkgbuilds/actions/workflows/build.yml/badge.svg)](https://github.com/TwoWells/pkgbuilds/actions/workflows/build.yml)
[![Check for Updates](https://github.com/TwoWells/pkgbuilds/actions/workflows/watch.yml/badge.svg)](https://github.com/TwoWells/pkgbuilds/actions/workflows/watch.yml)

Personal Arch Linux package repository with automated builds and version tracking.

## Usage

```bash
# Import the maintainer's signing key
sudo pacman-key --keyserver keys.openpgp.org --recv-keys ED9FEE0BB96D6A5E
sudo pacman-key --lsign-key ED9FEE0BB96D6A5E

# Add to /etc/pacman.conf (before [core] for priority over official packages)
[markwells-dev]
SigLevel = Required DatabaseOptional
Server = https://github.com/TwoWells/pkgbuilds/releases/latest/download

# Sync and install
sudo pacman -Sy
sudo pacman -S <package-name>
```

## Packages

See the [`pkgs/`](./pkgs) directory for the current list — each subdirectory is
one package, named after its `pkgname`. Its `PKGBUILD` records the upstream
source and version.

## How It Works

- **PKGBUILDs** are stored in this repo
- **Versions are checked** every 30 minutes and updated automatically
- **GitHub Actions** builds only changed packages in a clean Arch Linux container
- **Packages are signed** with GPG and published atomically to GitHub Releases
- **pacman** syncs directly from the release assets

For CI/CD pipeline details, see the [wiki](https://github.com/TwoWells/pkgbuilds/wiki/CI-CD).

## Adding a New Package

1. Create a directory in `pkgs/` with a `PKGBUILD` (directory name must match `pkgname`):

   ```
   pkgs/my-package/
   └── PKGBUILD    # pkgname=my-package
   ```

2. Add an update script in `scripts/packages/<pkgname>.sh`:

```bash
check_pkgname() {

  # check logic here, call perform_update

}

check_pkgname
```

Common datasources:

- `npm` - for npm packages
- `github-releases` - for GitHub releases

3. Commit and push - the package will be automatically detected and built

## Known Issues

### rpi-imager URL opening

Clicking links within the `rpi-imager` application may fail. This occurs because the AppImage's bundled libraries can break PAM when calling `runuser` to launch a browser. This is an upstream issue; avoid attempting downstream fixes in the wrapper script as they have proven unreliable.

## Contributing

For detailed instructions on how to add new packages, build them locally, and understand the project structure, please see [CONTRIBUTING.md](./CONTRIBUTING.md).
