# Makefile — local dev helpers for the pkgbuilds repo.
#
# These targets wrap the same tools CI (scripts/) and pre-commit already use, so
# running them locally reproduces CI behavior instead of drifting from it.
# Per-package targets take PKG=<name>:
#
#     make build     PKG=themis        # makepkg -sf
#     make test      PKG=themis-bin    # build, then run check.sh (smoke test)
#     make checksums PKG=themis        # updpkgsums
#     make srcinfo   PKG=themis        # regenerate .SRCINFO
#
# Repo-wide:  make fmt | fmt-check | shellcheck | syntax | lint | pre-commit
#
# Requires an Arch Linux environment (makepkg, updpkgsums, shfmt, shellcheck,
# namcap) for the build/lint/format targets.

SHELL := /bin/bash

# Every PKGBUILD and every shell script — the set pre-commit formats/checks.
# Enumerate via git so .gitignore is respected: makepkg build artifacts under
# pkg/ and src/, and vendored node_modules, are excluded. --others keeps new,
# not-yet-staged files in scope (mirroring pre-commit), while ignored files stay
# out.
SOURCES    := $(shell git ls-files --cached --others --exclude-standard)
PKGBUILDS  := $(filter %/PKGBUILD,$(SOURCES))
SH_SCRIPTS := $(filter %.sh,$(SOURCES))
SHELL_SRC  := $(PKGBUILDS) $(SH_SCRIPTS)

# Flags kept in lockstep with .pre-commit-config.yaml.
SHFMT_FLAGS         := -i 4 -sr
SHELLCHECK_SCRIPT   := --severity=warning
SHELLCHECK_PKGBUILD := --shell=bash --exclude=SC2034,SC2148,SC2154,SC2164

.DEFAULT_GOAL := help

.PHONY: help list fmt fmt-check shellcheck syntax lint pre-commit \
        build test checksums srcinfo watch clean _require-pkg

help: ## Show this help
	@echo "pkgbuilds — make targets (per-package ones take PKG=<name>):"
	@grep -E '^[a-zA-Z0-9_-]+:.*?## ' $(MAKEFILE_LIST) \
		| awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-12s\033[0m %s\n", $$1, $$2}'

list: ## List discovered package directories
	@find pkgs -mindepth 1 -maxdepth 2 -name PKGBUILD -printf '%h\n' | sort

fmt: ## Format all PKGBUILDs/scripts in place (shfmt, same flags as pre-commit)
	shfmt -w $(SHFMT_FLAGS) $(SHELL_SRC)

fmt-check: ## Report formatting diffs without writing (shfmt -d)
	shfmt -d $(SHFMT_FLAGS) $(SHELL_SRC)

shellcheck: ## Lint scripts + PKGBUILDs with shellcheck (pre-commit rules)
	shellcheck $(SHELLCHECK_SCRIPT) $(SH_SCRIPTS)
	shellcheck $(SHELLCHECK_PKGBUILD) $(PKGBUILDS)

syntax: ## Bash syntax check (bash -n) over all PKGBUILDs and scripts
	@for f in $(SHELL_SRC); do bash -n "$$f" && echo "ok: $$f"; done

lint: ## Run the full CI lint (bash -n + source verification + namcap auto-repair)
	bash scripts/lint.sh

pre-commit: ## Run every pre-commit hook across the repo
	pre-commit run --all-files

build: _require-pkg ## Build one package (PKG=<name>): makepkg -sf
	cd pkgs/$(PKG) && makepkg -sf

test: _require-pkg ## Build one package and run its check.sh smoke test (PKG=<name>)
	cd pkgs/$(PKG) && makepkg -sf
	@pkgfile=$$(find pkgs/$(PKG) -maxdepth 1 -name '*.pkg.tar.zst' | head -n1); \
	if [ -z "$$pkgfile" ]; then echo "Error: no built package found in pkgs/$(PKG)" >&2; exit 1; fi; \
	if [ -f pkgs/$(PKG)/check.sh ]; then \
		echo "==> Running pkgs/$(PKG)/check.sh $$pkgfile"; \
		bash pkgs/$(PKG)/check.sh "$$pkgfile"; \
	else \
		echo "==> No check.sh for $(PKG); build-only verification (package built OK)."; \
	fi

checksums: _require-pkg ## Refresh sha sums for one package (PKG=<name>): updpkgsums
	cd pkgs/$(PKG) && updpkgsums

srcinfo: _require-pkg ## (Re)generate .SRCINFO for one package (PKG=<name>)
	cd pkgs/$(PKG) && makepkg --printsrcinfo > .SRCINFO

watch: ## Run the version-update watchers locally (scripts/check-updates.sh)
	bash scripts/check-updates.sh

clean: ## Remove makepkg build artifacts (src/, pkg/, built pkgs, downloaded sources)
	@find pkgs -mindepth 1 -maxdepth 2 -type d \( -name src -o -name pkg \) -exec rm -rf {} +
	@find pkgs -maxdepth 2 -type f \
		\( -name '*.pkg.tar.zst' -o -name '*.pkg.tar.zst.sig' \
		-o -name '*.pkg.tar.xz' -o -name '*.tar.gz' -o -name '*.tgz' \
		-o -name '*.run' -o -name 'LICENSE-*' \) -delete
	@echo "Removed build artifacts and downloaded sources."

_require-pkg:
	@if [ -z "$(PKG)" ]; then echo "Error: set PKG=<name>, e.g. make $(MAKECMDGOALS) PKG=themis" >&2; exit 1; fi
	@test -f pkgs/$(PKG)/PKGBUILD || { echo "Error: pkgs/$(PKG)/PKGBUILD not found" >&2; exit 1; }
