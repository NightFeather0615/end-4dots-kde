#!/usr/bin/env bash
# installDP_fedora.sh — Install Fedora dependencies with failsafes for the end-4 KDE port.
# Idempotent: checks packages. Failproof: interactive prompts on error.

set -uo pipefail

# Keep sudo alive for this script
sudo -v || exit 1
(while true; do sudo -n true; sleep 55; done) 2>/dev/null &
SUDO_LOOP_PID=$!
trap 'kill $SUDO_LOOP_PID 2>/dev/null || true' EXIT

# ── Resolve paths ─────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(cd "$SCRIPT_DIR/../.." && pwd)}"
DEPS_DATA_FILE="$SCRIPT_DIR/feddeps.toml"

# ── Architecture detection ────────────────────────────────────────────────────
# The local RPM repo (end-4/ii-package-builds, packages-fedora release) only
# publishes x86_64 builds. On aarch64 (e.g. Asahi Linux on Apple Silicon) we
# skip it and install matugen from source via install-matugen-aarch64.sh.
MACHINE_ARCH="$(uname -m)"
IS_AARCH64=false
if [[ "$MACHINE_ARCH" == "aarch64" || "$MACHINE_ARCH" == "arm64" ]]; then
    IS_AARCH64=true
fi

# Packages that belong to the Hyprland compositor ecosystem and are either
# unused on KDE Plasma or superseded by KDE-native equivalents. Skipped only
# on aarch64 so the x86_64 install path stays unchanged.
# - hyprland / hyprland-guiutils / hyprland-qt-support: Hyprland stack, not run on KDE
# - hyprsunset: superseded by KWin Night Light DBus bridge (services/Hyprsunset.qml)
# - hypridle: KDE ships its own idle daemon
# - hyprshot / slurp: KDE build uses spectacle + ImageMagick (ScreenshotAction.qml)
# - grub2-breeze-theme: Asahi Linux boots via U-Boot, no GRUB
AARCH64_SKIP_PKGS=(
    "hyprland"
    "hyprland-guiutils"
    "hyprland-qt-support"
    "hyprsunset"
    "hypridle"
    "hyprshot"
    "slurp"
    "grub2-breeze-theme"
)

# ── Helpers ───────────────────────────────────────────────────────────────────
log()  { echo; echo "==> $*"; }
warn() { echo -e "\033[0;31m[WARN] $*\033[0m" >&2; }
err()  { echo -e "\033[0;31m[ERR]  $*\033[0m" >&2; }

# Init local RPM repo and download rpms from releases there.
init_local_repo() {
    if [[ "$IS_AARCH64" == true ]]; then
        log "Skipping local RPM repo — aarch64: ii-package-builds only ships x86_64 RPMs."
        return 0
    fi
    local url="https://api.github.com/repos/end-4/ii-package-builds/releases/tags/packages-fedora"
    local path="$HOME/.cache/illogical-impulse-repo"

    sudo rm -rf -- "$path"
    mkdir -p "$path"

    # Minimal logic from install-deps.sh
    for file in $(curl -s "$url" | jq -r '.assets[].browser_download_url'); do
        local name
        name=$(basename "$file")
        echo "Downloading $file"
        curl --max-time 10 -L --fail --show-error --progress-bar -o "$path/$name" "$file"
    done
    sudo createrepo_c "$path"
}

# ── Main ─────────────────────────────────────────────────────────────────────
main() {
    if ! command -v dnf >/dev/null 2>&1; then
        err "dnf not found. This script requires Fedora 42 or later."
        exit 1
    fi

    # Ensure yq and createrepo_c are present
    if ! command -v yq >/dev/null 2>&1 || ! command -v createrepo_c >/dev/null 2>&1; then
        log "Installing build tools (yq, createrepo_c)..."
        sudo dnf install -y yq createrepo_c jq || true
    fi

    # Install COPR repositories
    log "Enabling COPR repositories..."
    local copr_repos_json
    copr_repos_json=$(yq -o=j '.copr.repos // []' "$DEPS_DATA_FILE")
    local copr_repos_array=()
    eval "$(jq -r '@sh "copr_repos_array+=(\(.[]))"' <<<"$copr_repos_json")"
    for copr in "${copr_repos_array[@]}"; do
        sudo dnf copr enable "$copr" -y || true
    done

    # Init local repo
    log "Initializing local RPM repository..."
    init_local_repo

    # Install packages
    log "Starting to install packages from $DEPS_DATA_FILE ..."
    local deps_data
    deps_data=$(yq -o=j '.' "$DEPS_DATA_FILE")

    local INSTALLED=0
    local SKIPPED=0
    local FAILED=0
    local FAILED_PKGS=()

    while IFS= read -r deps_list_key; do
        [[ -z "$deps_list_key" ]] && continue
        echo
        echo "=================================================="
        echo "Processing group: $deps_list_key"
        echo "=================================================="

        local install_opts
        install_opts=$(echo "$deps_data" | yq -r ".groups.\"$deps_list_key\" | select(has(\"install_opts\")) | .install_opts[]" 2>/dev/null || echo "")
        
        local package_list
        package_list=$(echo "$deps_data" | yq -r ".groups.\"$deps_list_key\".packages | unique | .[]" 2>/dev/null || echo "")

        if [[ "$deps_list_key" == 'illogical-impulse' ]]; then
            if [[ "$IS_AARCH64" == true ]]; then
                # matugen has no aarch64 RPM (ii-package-builds is x86_64-only);
                # it is installed from source by install-matugen-aarch64.sh.
                log "Skipping group illogical-impulse on aarch64 — matugen is built from source (cargo)."
                continue
            fi
            install_opts="$install_opts --repofrompath=illogical-impulse,file://$HOME/.cache/illogical-impulse-repo --nogpgcheck"
        fi

        # On aarch64, filter out Hyprland-ecosystem packages that KDE doesn't need.
        if [[ "$IS_AARCH64" == true ]]; then
            local filtered=()
            for pkg in $package_list; do
                if [[ " ${AARCH64_SKIP_PKGS[*]} " == *" $pkg "* ]]; then
                    echo "  [SKIP] $pkg — not needed on KDE Plasma (aarch64 build)"
                    (( SKIPPED++ )) || true
                else
                    filtered+=("$pkg")
                fi
            done
            package_list="${filtered[*]}"
        fi

        for pkg in $package_list; do
            [[ -z "$pkg" ]] && continue
            
            # Idempotency check:
            if dnf list --installed "$pkg" >/dev/null 2>&1; then
                echo "  [SKIP] $pkg is already installed."
                (( SKIPPED++ )) || true
                continue
            fi

            # Availability check
            if ! dnf info $install_opts "$pkg" >/dev/null 2>&1; then
                warn "Package $pkg is not available in repositories."
                # We still try to install to trigger interactive prompt or we can prompt right here
            fi

            while true; do
                if sudo dnf install -y $install_opts "$pkg" </dev/tty; then
                    echo "  [OK]  $pkg installed successfully."
                    (( INSTALLED++ )) || true
                    break
                else
                    err "$pkg installation FAILED."
                    echo -e "\033[1;33mWhat would you like to do? [r]etry, [i]gnore, [e]xit:\033[0m "
                    read -r -t 60 step_action || step_action="i"
                    case "${step_action,,}" in
                        r|retry)
                            echo "Retrying $pkg..."
                            ;;
                        e|exit)
                            err "Aborting installation."
                            exit 1
                            ;;
                        *)
                            echo "Ignoring error and continuing with remaining packages..."
                            (( FAILED++ )) || true
                            FAILED_PKGS+=("$pkg")
                            break
                            ;;
                    esac
                fi
            done
        done
    done < <(echo "$deps_data" | yq -r '.groups | keys[]? | select(length > 0)')

    echo
    echo "======================================================"
    echo "  Installation summary"
    echo "======================================================"
    echo "  Installed : $INSTALLED"
    echo "  Skipped   : $SKIPPED (already present)"
    echo "  Failed    : $FAILED"
    if (( ${#FAILED_PKGS[@]} )); then
        echo
        echo "  Failed packages:"
        for p in "${FAILED_PKGS[@]}"; do
            echo "    - $p"
        done
        echo
        echo "  Re-run this script to retry failed packages."
    fi
    echo "======================================================"
}

main "$@"
