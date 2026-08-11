#!/usr/bin/env bash
# install-matugen-aarch64.sh — Install matugen from source (cargo) on aarch64.
#
# Why: the illogical-impulse RPM repo (end-4/ii-package-builds, packages-fedora
# release) only publishes x86_64 builds, and matugen has no Fedora official or
# COPR aarch64 package. matugen is a Rust project, so building from source with
# cargo is architecture-independent.
#
# Idempotent: exits early if matugen is already available.
# Runs as the invoking (non-root) user; sudo is only used for dnf and the
# /usr/local/bin symlink.

set -uo pipefail

log()  { echo; echo "==> $*"; }
warn() { echo -e "\033[0;31m[WARN] $*\033[0m" >&2; }

# ── Early exit if matugen already exists ──────────────────────────────────────
if command -v matugen >/dev/null 2>&1; then
    log "matugen already installed — skipping."
    exit 0
fi

# ── Rust toolchain + build dependencies ───────────────────────────────────────
# gtk4-devel / libadwaita-devel / libsoup3-devel / libportal-gtk4 are the same
# deps the installer already pulls in the [groups.python] section of feddeps.toml;
# we re-check them here so this script also works standalone.
log "Ensuring Rust toolchain and build dependencies..."
sudo dnf install -y rust cargo gcc gtk4-devel libadwaita-devel libsoup3-devel libportal-gtk4

# ── Build matugen from source ─────────────────────────────────────────────────
# --locked pins to the committed lockfile (reproducible builds).
# This compiles several Rust crates and can take several minutes.
log "Building matugen from source (cargo install — this can take several minutes)..."
if ! cargo install matugen --locked; then
    warn "cargo install matugen failed."
    exit 1
fi

# ── Expose the binary system-wide ─────────────────────────────────────────────
# The installer and the shell scripts expect `matugen` on PATH; ~/.cargo/bin
# is not always on PATH for all shells/autostart entries.
MATUGEN_BIN="$HOME/.cargo/bin/matugen"
if [[ -x "$MATUGEN_BIN" ]] && [[ ! -e /usr/local/bin/matugen ]]; then
    log "Linking $MATUGEN_BIN to /usr/local/bin/matugen"
    sudo ln -s "$MATUGEN_BIN" /usr/local/bin/matugen
fi

log "matugen installed successfully."
