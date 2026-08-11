#!/usr/bin/env bash
# verify-asahi.sh — Pre-flight verification for running the end-4 KDE port
# installer on aarch64 (Fedora Asahi Remix on Apple Silicon).
#
# Read-only by default: reports the environment and which packages resolve on
# aarch64. Optional flags:
#   --enable   enable the COPR repositories the installer depends on
#   --dryrun   test-resolve every package group from feddeps.toml (repoquery)
#   --all      same as --enable --dryrun
#
# Expected findings on aarch64:
#   - matugen is NOT available from any repo (x86_64 RPM only)
#     → the installer builds it from source via install-matugen-aarch64.sh
#   - hyprland / hyprsunset / hyprshot / slurp / hypridle are skipped by the
#     installer on aarch64 (KDE-native equivalents exist)

set -uo pipefail

CYAN="\033[0;36m"; GREEN="\033[0;32m"; YELLOW="\033[1;33m"; RED="\033[0;31m"; RST="\033[0m"
info() { echo -e "${CYAN}[INFO]  $*${RST}"; }
ok()   { echo -e "${GREEN}[OK]    $*${RST}"; }
warn() { echo -e "${YELLOW}[WARN]  $*${RST}"; }
err()  { echo -e "${RED}[ERR]   $*${RST}"; }

DO_ENABLE=false
DO_DRYRUN=false
for arg in "$@"; do
    case "$arg" in
        --enable) DO_ENABLE=true ;;
        --dryrun) DO_DRYRUN=true ;;
        --all)    DO_ENABLE=true; DO_DRYRUN=true ;;
        *) err "Unknown argument: $arg"; exit 1 ;;
    esac
done

# ── 1. Environment report ─────────────────────────────────────────────────────
echo "════════════════════════════════════════════════════════"
echo "  end-4 KDE port — aarch64 / Asahi pre-flight check"
echo "════════════════════════════════════════════════════════"

info "Architecture: $(uname -m)"
if [ -f /etc/os-release ]; then
    . /etc/os-release
    info "Distribution: $PRETTY_NAME"
fi
PLASMA_VER="$(plasmashell --version 2>/dev/null | awk '{print $2}')"
if [ -n "$PLASMA_VER" ]; then
    info "Plasma: $PLASMA_VER"
    # KWin wlr-layer-shell support (needed by the Quickshell bar) landed in Plasma 6.3
    if [[ "$(printf '%s\n' "6.3" "$PLASMA_VER" | sort -V | head -1)" == "6.3" ]]; then
        ok "Plasma >= 6.3 — KWin wlr-layer-shell available."
    else
        warn "Plasma < 6.3 — wlr-layer-shell panels may not work."
    fi
else
    warn "plasmashell not found on PATH."
fi

# ── 2. COPR repositories ──────────────────────────────────────────────────────
# Mirrors feddeps.toml [copr].repos + alternateved/keyd (used by
# src/keyboardshortcuts/register.sh).
COPRS=(
    "ririko66z/dots-hyprland"
    "sdegler/hyprland"
    "deltacopy/darkly"
    "alternateved/eza"
    "atim/starship"
    "errornointernet/quickshell"
    "alternateved/keyd"
)

echo
echo "── COPR repositories ────────────────────────────────────"
MISSING_COPRS=()
for copr in "${COPRS[@]}"; do
    # dnf copr enable writes /etc/yum.repos.d/_copr:owner:project.repo
    # (some dnf versions use underscores instead of colons)
    if ls /etc/yum.repos.d/*"${copr}"*.repo >/dev/null 2>&1 || \
       ls /etc/yum.repos.d/*"$(echo "$copr" | tr '/:' '__')"*.repo >/dev/null 2>&1; then
        ok "enabled: $copr"
    else
        warn "missing: $copr"
        MISSING_COPRS+=("$copr")
    fi
done

if [ "${#MISSING_COPRS[@]}" -gt 0 ]; then
    if [ "$DO_ENABLE" == true ]; then
        for copr in "${MISSING_COPRS[@]}"; do
            info "Enabling $copr ..."
            sudo dnf copr enable "$copr" -y || err "Failed to enable $copr"
        done
    else
        warn "Run with --enable to enable the missing COPRs (needs sudo)."
    fi
fi

# ── 3. Package availability on aarch64 ────────────────────────────────────────
# Needs yq to read feddeps.toml (same dependency as installDP_fedora.sh).
if [ "$DO_DRYRUN" == true ]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    DEPS_FILE="$SCRIPT_DIR/../sdata/fedora-dist/feddeps.toml"

    if ! command -v yq >/dev/null 2>&1; then
        err "yq not found — install it first: sudo dnf install -y yq"
        exit 1
    fi

    echo
    echo "── Package availability (aarch64) ────────────────────"
    UNAVAILABLE=()

    check_pkg() {
        local pkg="$1"
        local out
        out="$(dnf repoquery --available "$pkg" 2>/dev/null)"
        if [ -z "$out" ]; then
            echo "    ✗ $pkg — NOT available"
            UNAVAILABLE+=("$pkg")
            return 1
        fi
        # Any aarch64 or noarch binary means dnf can install it.
        if echo "$out" | grep -qE '\.(aarch64|noarch)([[:space:]]|$)'; then
            echo "    ✓ $pkg"
        elif echo "$out" | grep -q '\.src'; then
            echo "    ~ $pkg — source package only, no binary (installer will prompt)"
            UNAVAILABLE+=("$pkg")
        else
            echo "    ~ $pkg — only: $(echo "$out" | head -1)"
            UNAVAILABLE+=("$pkg")
        fi
    }

    groups="$(yq -r '.groups | keys[]?' "$DEPS_FILE")"
    for group in $groups; do
        echo "  [$group]"
        while IFS= read -r pkg; do
            [ -z "$pkg" ] && continue
            check_pkg "$pkg"
        done < <(yq -r ".groups.\"$group\".packages[]?" "$DEPS_FILE")
    done

    echo
    if [ "${#UNAVAILABLE[@]}" -gt 0 ]; then
        warn "Not directly resolvable on aarch64: ${UNAVAILABLE[*]}"
        echo "  → matugen: only a source RPM exists — the installer builds it from"
        echo "    source (install-matugen-aarch64.sh)."
        echo "  → hyprland-ecosystem packages (hyprland, hyprsunset, hyprshot, slurp,"
        echo "    hypridle, grub2-breeze-theme) are skipped by the installer on aarch64."
        echo "  → source-only packages (e.g. eza) usually also have binaries in other"
        echo "    repos; dnf install will pick them up."
        echo "  → zlib-devel: renamed to zlib-ng-compat-devel on Fedora 41+, but"
        echo "    'dnf install zlib-devel' usually still works via Obsoletes —"
        echo "    verify with: sudo dnf install --assumeno zlib-devel"
    else
        ok "All packages resolve on aarch64."
    fi
fi

echo
echo "────────────────────────────────────────────────────────"
info "Next: bash setup.sh  (or run the step scripts individually)"
