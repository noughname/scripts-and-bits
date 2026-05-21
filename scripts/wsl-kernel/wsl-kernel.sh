#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration — all settings can be overridden via env vars or CLI flags
# ---------------------------------------------------------------------------
WSLK_KERNEL_REPO="${WSLK_KERNEL_REPO:-https://github.com/Nevuly/WSL2-Linux-Kernel-Rolling}"
WSLK_KERNEL_VERSION="${WSLK_KERNEL_VERSION:-}"          # empty → auto-detected or prompted
WSLK_OUTPUT_DIR="${WSLK_OUTPUT_DIR:-%USERPROFILE%\.wsl-kernel}"
WSLK_ARCH="${WSLK_ARCH:-x86}"
WSLK_KCONFIG_CONFIG="${WSLK_KCONFIG_CONFIG:-}"          # empty → derived from WSLK_ARCH in main()

WSLK_SKIP_WSL_CHECK="${WSLK_SKIP_WSL_CHECK:-false}"
WSLK_SKIP_DEPS="${WSLK_SKIP_DEPS:-false}"
WSLK_SKIP_REPO_CLONE="${WSLK_SKIP_REPO_CLONE:-false}"
WSLK_FULL_CLONE="${WSLK_FULL_CLONE:-false}"
WSLK_SKIP_MODULES_SCRIPT_CHECK="${WSLK_SKIP_MODULES_SCRIPT_CHECK:-false}"
WSLK_SKIP_RESTART="${WSLK_SKIP_RESTART:-false}"
WSLK_DRY_RUN="${WSLK_DRY_RUN:-false}"

# Clone target; defaults to /tmp to avoid home-directory permission issues
KERNEL_SRC_DIR="${KERNEL_SRC_DIR:-/tmp/wsl-kernel}"

# ---------------------------------------------------------------------------
# Runtime flags — set by CLI args only
# ---------------------------------------------------------------------------
_STEP=""
_YES="false"
_NON_INTERACTIVE="false"

# ---------------------------------------------------------------------------
# Shared state — populated by resolvers, consumed by step functions
# ---------------------------------------------------------------------------
KERNEL_RELEASE=""
KERNEL_NAME=""
MODULES_NAME=""
MODULES_VHDX_PATH=""
WIN_OUTPUT_DIR=""

# Resource handles for trap-based cleanup
_DOWNLOADED_SCRIPT=""
_WSLCONFIG_TMP=""
_SUDO_KEEPALIVE_PID=""
_MODULES_BUILT="false"  # set to true after gen_modules_vhdx.sh runs

# ---------------------------------------------------------------------------
# Logging — RFC 3339 timestamps, colour-coded levels
# ---------------------------------------------------------------------------
_log() {
    local level="$1" color="$2"
    shift 2
    local ts
    ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    printf "%s ${color}[%-5s]\033[0m %s\n" "$ts" "$level" "$*"
}
log()       { _log "INFO"  "\033[0;32m" "$@"; }
log_warn()  { _log "WARN"  "\033[0;33m" "$@" >&2; }
log_error() { _log "ERROR" "\033[0;31m" "$@" >&2; }

# ---------------------------------------------------------------------------
# Cleanup — registered via trap
# ---------------------------------------------------------------------------
cleanup() {
    # Stop sudo keepalive
    if [[ -n "${_SUDO_KEEPALIVE_PID:-}" ]]; then
        kill "$_SUDO_KEEPALIVE_PID" 2>/dev/null || true
        _SUDO_KEEPALIVE_PID=""
    fi
    # Remove temp files
    [[ -n "${_DOWNLOADED_SCRIPT:-}" ]] && rm -f "$_DOWNLOADED_SCRIPT"
    [[ -n "${_WSLCONFIG_TMP:-}" ]]     && rm -f "$_WSLCONFIG_TMP"
    # Clean up any stale tmp artefacts left by gen_modules_vhdx.sh (only if it ran)
    if [[ "${_MODULES_BUILT:-false}" == "true" ]]; then
        sudo find /tmp -maxdepth 2 -type f \( -name "modules.img" -o -name "modules_img" \) \
            -exec sh -c 'sudo umount "$(dirname "$1")" 2>/dev/null
                         sudo umount "$1"              2>/dev/null
                         sudo rm -rf "$(dirname "$1")"' _ {} \; 2>/dev/null || true
    fi
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Sudo keepalive — authenticate once and refresh every 55 s
# ---------------------------------------------------------------------------
start_sudo_keepalive() {
    sudo -v
    ( while true; do sleep 55; sudo -v 2>/dev/null; done ) &
    _SUDO_KEEPALIVE_PID=$!
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
resolve_win_userprofile() {
    cmd.exe /c "echo %USERPROFILE%" 2>/dev/null | tr -d '\r\n'
}

# Compute KERNEL_RELEASE (cached) and derive artifact names.
# Safe to call multiple times — reuses the cached value after the first call.
resolve_build_names() {
    if [[ -z "$KERNEL_RELEASE" ]]; then
        if [[ ! -d "$KERNEL_SRC_DIR" ]]; then
            log_error "KERNEL_SRC_DIR='$KERNEL_SRC_DIR' does not exist; cannot resolve kernel release"
            return 1
        fi
        KERNEL_RELEASE=$(cd "$KERNEL_SRC_DIR" && make -s kernelrelease)
    fi
    KERNEL_NAME="vmlinux-${KERNEL_RELEASE}-${WSLK_ARCH}"
    MODULES_NAME="modules-${KERNEL_RELEASE}-${WSLK_ARCH}.vhdx"
    MODULES_VHDX_PATH="$KERNEL_SRC_DIR/modules.vhdx"
}

# Resolve and cache the Windows output directory path.
resolve_win_output_dir() {
    if [[ -z "$WIN_OUTPUT_DIR" ]]; then
        local win_output_dir_expanded
        win_output_dir_expanded=$(cmd.exe /c "echo ${WSLK_OUTPUT_DIR}" 2>/dev/null | tr -d '\r\n')
        WIN_OUTPUT_DIR=$(wslpath -u "$win_output_dir_expanded")
        mkdir -p "$WIN_OUTPUT_DIR"
    fi
}

# List branches from a remote repo matching a grep pattern, newest-first.
fetch_available_versions() {
    local repo="$1" pattern="${2:-^wsl-}"
    local branches
    branches=$(git ls-remote --heads "$repo" 2>/dev/null \
        | awk '{print $2}' \
        | sed 's|refs/heads/||' \
        | grep "$pattern") || return 1
    if echo "$branches" | sort -rV >/dev/null 2>&1; then
        echo "$branches" | sort -rV
    else
        echo "$branches" | sort -r
    fi
}

# Return the latest matching branch, or a hardcoded fallback on failure.
detect_latest_version() {
    local repo="$1"
    local latest
    latest=$(fetch_available_versions "$repo" "^wsl-" 2>/dev/null | head -1) || true
    if [[ -z "$latest" ]]; then
        log_warn "Could not detect latest version from $repo; using fallback"
        echo "wsl-7.0-rolling"
    else
        echo "$latest"
    fi
}

# ---------------------------------------------------------------------------
# Interactive helpers
# ---------------------------------------------------------------------------
is_interactive() {
    [[ "$_NON_INTERACTIVE" != "true" ]] && [[ -t 0 ]]
}

# Read text input with an optional default.
# Usage: prompt_input <label> <varname> [default]
prompt_input() {
    local label="$1" varname="$2" default="${3:-}"
    local value=""
    if [[ -n "$default" ]]; then
        read -r -p "  $label [$default]: " value
        value="${value:-$default}"
    else
        read -r -p "  $label: " value
    fi
    printf -v "$varname" '%s' "$value"
}

# Ask a yes/no question. Returns 0 for yes, 1 for no.
# Usage: prompt_yes_no <question> [default: y|n]
prompt_yes_no() {
    local question="$1" default="${2:-y}"
    local answer=""
    if [[ "$default" == "y" ]]; then
        read -r -p "  $question [Y/n]: " answer
        answer="${answer:-y}"
    else
        read -r -p "  $question [y/N]: " answer
        answer="${answer:-n}"
    fi
    [[ "${answer,,}" == "y" || "${answer,,}" == "yes" ]]
}

# Display a numbered list and let the user pick one item.
# Sets varname to the selected value; accepts a manual string if not a valid number.
# Usage: prompt_select <label> <varname> <item1> <item2> ...
prompt_select() {
    local label="$1" varname="$2"
    shift 2
    local -a items=("$@")
    local i
    for (( i=0; i<${#items[@]}; i++ )); do
        printf "    %2d) %s\n" $(( i+1 )) "${items[$i]}"
    done
    local choice=""
    read -r -p "  $label [1]: " choice
    choice="${choice:-1}"
    if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#items[@]} )); then
        printf -v "$varname" '%s' "${items[$(( choice-1 ))]}"
    else
        printf -v "$varname" '%s' "$choice"
    fi
}

# ---------------------------------------------------------------------------
# Pre-flight checks
# ---------------------------------------------------------------------------
check_wsl_environment() {
    if [[ "$WSLK_SKIP_WSL_CHECK" == "true" ]]; then
        log "Skipping WSL environment check"
        return 0
    fi
    # Primary: WSL-injected wslinfo binary (WSL2 with kernel ≥ 5.15.90)
    if [[ -x /usr/bin/wslinfo && -L /usr/bin/wslinfo ]]; then
        if /usr/bin/wslinfo --version >/dev/null 2>&1 \
            || /usr/bin/wslinfo --wsl-version >/dev/null 2>&1 \
            || /usr/bin/wslinfo --networking-mode >/dev/null 2>&1; then
            return 0
        fi
        log_error "Detected /usr/bin/wslinfo but it returned an error — WSL environment may be broken."
        exit 1
    fi
    # Fallback: binfmt_misc WSLInterop entry (present in all WSL2 environments)
    if [[ -f /proc/sys/fs/binfmt_misc/WSLInterop ]]; then
        return 0
    fi
    log_error "Not running inside WSL. Set WSLK_SKIP_WSL_CHECK=true to bypass this check."
    exit 1
}

# ---------------------------------------------------------------------------
# Interactive configuration
# ---------------------------------------------------------------------------
interactive_configure() {
    echo ""
    log "Interactive configuration — press Enter to accept the shown default"
    echo ""

    prompt_input "Kernel repo URL" WSLK_KERNEL_REPO "$WSLK_KERNEL_REPO"

    echo ""
    log "Fetching available branches from $WSLK_KERNEL_REPO..."
    local -a versions=()
    if mapfile -t versions < <(fetch_available_versions "$WSLK_KERNEL_REPO" "^wsl-" 2>/dev/null) \
            && [[ ${#versions[@]} -gt 0 ]]; then
        echo ""
        log "Available branches:"
        local default_idx=1
        local i
        for (( i=0; i<${#versions[@]}; i++ )); do
            if [[ "${versions[$i]}" == "$WSLK_KERNEL_VERSION" ]]; then
                default_idx=$(( i+1 ))
            fi
        done
        for (( i=0; i<${#versions[@]}; i++ )); do
            printf "    %2d) %s\n" $(( i+1 )) "${versions[$i]}"
        done
        local choice=""
        read -r -p "  Select branch [$default_idx]: " choice
        choice="${choice:-$default_idx}"
        if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#versions[@]} )); then
            WSLK_KERNEL_VERSION="${versions[$(( choice-1 ))]}"
        else
            WSLK_KERNEL_VERSION="$choice"
        fi
    else
        log_warn "Could not fetch branch list; enter version manually"
        prompt_input "Kernel version / branch" WSLK_KERNEL_VERSION \
            "${WSLK_KERNEL_VERSION:-wsl-7.0-rolling}"
    fi

    echo ""
    prompt_input "Target architecture" WSLK_ARCH "$WSLK_ARCH"
    prompt_input "Windows output directory" WSLK_OUTPUT_DIR "$WSLK_OUTPUT_DIR"
    echo ""
}

# ---------------------------------------------------------------------------
# Config summary
# ---------------------------------------------------------------------------
show_config_summary() {
    echo ""
    log "Build configuration:"
    printf "    %-32s %s\n" "Kernel repo:"        "$WSLK_KERNEL_REPO"
    printf "    %-32s %s\n" "Kernel version:"     "$WSLK_KERNEL_VERSION"
    printf "    %-32s %s\n" "Architecture:"       "$WSLK_ARCH"
    printf "    %-32s %s\n" "Kernel config:"      "$WSLK_KCONFIG_CONFIG"
    printf "    %-32s %s\n" "Source dir:"         "$KERNEL_SRC_DIR"
    printf "    %-32s %s\n" "Windows output dir:" "$WSLK_OUTPUT_DIR"
    printf "    %-32s %s\n" "Dry run:"            "$WSLK_DRY_RUN"
    echo ""
}

# ---------------------------------------------------------------------------
# Step functions
# ---------------------------------------------------------------------------
install_deps() {
    if [[ "$WSLK_SKIP_DEPS" == "true" ]]; then
        log "Skipping dependency installation"
        return 0
    fi
    if [[ "$WSLK_DRY_RUN" == "true" ]]; then
        log "[DRY-RUN] Would install build dependencies"
        return 0
    fi
    log "Installing build dependencies..."
    if [[ ! -r /etc/os-release ]]; then
        log_error "Cannot read /etc/os-release; unable to detect distro"
        return 1
    fi
    # shellcheck source=/dev/null
    . /etc/os-release
    case "${ID:-}" in
        debian|ubuntu|linuxmint)
            sudo apt-get update -y
            sudo apt-get install -y build-essential flex bison bc dwarves libssl-dev libelf-dev cpio qemu-utils git zstd make
            ;;
        fedora|rhel|centos|rocky|almalinux)
            sudo dnf install -y gcc make flex bison openssl-devel elfutils-libelf-devel bc dwarves python3 git zstd qemu-img e2fsprogs diffutils depmod
            ;;
        *)
            log_error "Unsupported distro: ${ID:-unknown}. Install dependencies manually and set WSLK_SKIP_DEPS=true"
            return 1
            ;;
    esac
    log "Dependencies installed"
}

clone_kernel_repo() {
    if [[ "$WSLK_SKIP_REPO_CLONE" == "true" ]]; then
        if [[ ! -d "$KERNEL_SRC_DIR" ]]; then
            log_error "KERNEL_SRC_DIR='$KERNEL_SRC_DIR' does not exist. Set it to an existing kernel source tree."
            return 1
        fi
        log "Skipping repo clone; using existing KERNEL_SRC_DIR='$KERNEL_SRC_DIR'"
        return 0
    fi
    if [[ -d "$KERNEL_SRC_DIR" ]]; then
        if is_interactive && [[ "$_YES" != "true" ]]; then
            log_warn "$KERNEL_SRC_DIR already exists."
            if prompt_yes_no "Delete and re-clone?" "n"; then
                if [[ "$WSLK_DRY_RUN" == "true" ]]; then
                    log "[DRY-RUN] Would remove $KERNEL_SRC_DIR and re-clone"
                    return 0
                fi
                log "Removing $KERNEL_SRC_DIR..."
                rm -rf "$KERNEL_SRC_DIR"
            else
                log "Keeping existing $KERNEL_SRC_DIR; skipping clone."
                return 0
            fi
        else
            log_warn "$KERNEL_SRC_DIR already exists; skipping clone. Delete it or set KERNEL_SRC_DIR to a new path to re-clone."
            return 0
        fi
    fi
    if [[ "$WSLK_DRY_RUN" == "true" ]]; then
        log "[DRY-RUN] Would clone $WSLK_KERNEL_REPO (branch: $WSLK_KERNEL_VERSION) into $KERNEL_SRC_DIR"
        return 0
    fi
    log "Cloning kernel repo: $WSLK_KERNEL_REPO (branch/tag: $WSLK_KERNEL_VERSION) into $KERNEL_SRC_DIR..."
    local clone_args=(--branch "$WSLK_KERNEL_VERSION")
    if [[ "$WSLK_FULL_CLONE" == "false" ]]; then
        clone_args+=(--depth 1)
    fi
    git clone "${clone_args[@]}" "$WSLK_KERNEL_REPO" "$KERNEL_SRC_DIR"
    log "Kernel repo cloned to $KERNEL_SRC_DIR"
}

build_kernel() {
    if [[ "$WSLK_DRY_RUN" == "true" ]]; then
        log "[DRY-RUN] Would run: make KCONFIG_CONFIG='$WSLK_KCONFIG_CONFIG' -j$(nproc) in $KERNEL_SRC_DIR"
        return 0
    fi
    if [[ ! -d "$KERNEL_SRC_DIR" ]]; then
        log_error "KERNEL_SRC_DIR='$KERNEL_SRC_DIR' does not exist; cannot build kernel"
        return 1
    fi
    log "Building kernel in $KERNEL_SRC_DIR (this may take a while)..."
    ( cd "$KERNEL_SRC_DIR" && make KCONFIG_CONFIG="$WSLK_KCONFIG_CONFIG" -j"$(nproc)" ) || return 1
    resolve_build_names
    log "Kernel built: $KERNEL_RELEASE"
}

build_modules_vhdx() {
    if [[ "$WSLK_DRY_RUN" == "true" ]]; then
        log "[DRY-RUN] Would install modules and build modules.vhdx in $KERNEL_SRC_DIR"
        return 0
    fi
    if [[ ! -d "$KERNEL_SRC_DIR" ]]; then
        log_error "KERNEL_SRC_DIR='$KERNEL_SRC_DIR' does not exist; cannot build modules"
        return 1
    fi
    resolve_build_names || return 1

    log "Installing kernel modules to staging dir..."
    local modules_dir="modules"
    ( cd "$KERNEL_SRC_DIR" && make INSTALL_MOD_PATH="$modules_dir" modules_install ) || return 1

    log "Building modules vhdx..."
    local script="$KERNEL_SRC_DIR/Microsoft/scripts/gen_modules_vhdx.sh"
    if [[ "$WSLK_SKIP_MODULES_SCRIPT_CHECK" == "false" ]] && [[ ! -f "$script" ]]; then
        log "gen_modules_vhdx.sh not found in repo; downloading from official Microsoft WSL2 kernel repo..."
        _DOWNLOADED_SCRIPT=$(mktemp)
        curl -fsSL \
            "https://raw.githubusercontent.com/microsoft/WSL2-Linux-Kernel/refs/heads/linux-msft-wsl-6.6.y/Microsoft/scripts/gen_modules_vhdx.sh" \
            -o "$_DOWNLOADED_SCRIPT"
        script="$_DOWNLOADED_SCRIPT"
    fi

    if [[ -f "$MODULES_VHDX_PATH" ]]; then
        log "Removing existing $MODULES_VHDX_PATH..."
        sudo rm -f "$MODULES_VHDX_PATH"
    fi

    # gen_modules_vhdx.sh requires root (losetup/mount/umount)
    _MODULES_BUILT="true"
    sudo bash "$script" "$KERNEL_SRC_DIR/$modules_dir" "$KERNEL_RELEASE" "$MODULES_VHDX_PATH" || return 1
    log "Modules vhdx built: $MODULES_VHDX_PATH"
    # /tmp cleanup is handled by the trap in cleanup()
}

copy_to_windows() {
    if [[ "$WSLK_DRY_RUN" == "true" ]]; then
        log "[DRY-RUN] Would copy kernel and modules vhdx to Windows output directory"
        return 0
    fi
    resolve_build_names    || return 1
    resolve_win_output_dir || return 1

    local kernel_src="$KERNEL_SRC_DIR/arch/${WSLK_ARCH}/boot/bzImage"
    log "Copying kernel to $WIN_OUTPUT_DIR..."
    cp "$kernel_src" "$WIN_OUTPUT_DIR/$KERNEL_NAME"

    log "Copying modules vhdx to $WIN_OUTPUT_DIR..."
    cp "$MODULES_VHDX_PATH" "$WIN_OUTPUT_DIR/$MODULES_NAME"
    log "Files copied to $WIN_OUTPUT_DIR"
}

configure_wsl() {
    if [[ "$WSLK_DRY_RUN" == "true" ]]; then
        log "[DRY-RUN] Would update .wslconfig with custom kernel and modules paths"
        return 0
    fi
    resolve_build_names    || return 1
    resolve_win_output_dir || return 1

    log "Configuring WSL..."
    local wslconfig
    wslconfig="$(wslpath -u "$(resolve_win_userprofile)")/.wslconfig"
    local kernel_win_path vhdx_win_path
    kernel_win_path=$(wslpath -w "${WIN_OUTPUT_DIR}/${KERNEL_NAME}")
    vhdx_win_path=$(wslpath -w "${WIN_OUTPUT_DIR}/${MODULES_NAME}")

    if [[ -f "$wslconfig" ]]; then
        log "Backing up $wslconfig to ${wslconfig}.bak..."
        cp "$wslconfig" "${wslconfig}.bak"
    fi

    # Double backslashes for .wslconfig format (Windows paths require \\)
    local kernel_escaped="${kernel_win_path//\\/\\\\}"
    local modules_escaped="${vhdx_win_path//\\/\\\\}"

    if ! grep -q '^\[wsl2\]' "$wslconfig" 2>/dev/null; then
        log "No [wsl2] section found; appending to $wslconfig..."
        printf '\n[wsl2]\nkernel=%s\nkernelModules=%s\n' "$kernel_escaped" "$modules_escaped" >> "$wslconfig"
    else
        log "Updating [wsl2] section in $wslconfig..."
        _WSLCONFIG_TMP="${wslconfig}.tmp"
        # Use ENVIRON instead of -v to avoid awk's backslash escape processing
        kernel="$kernel_escaped" modules="$modules_escaped" awk '
            BEGIN { in_wsl2=0; kw=0; mw=0 }
            /^\[wsl2\]/ { in_wsl2=1; print; next }
            /^\[/ {
                if (in_wsl2) {
                    if (!kw) print "kernel=" ENVIRON["kernel"]
                    if (!mw) print "kernelModules=" ENVIRON["modules"]
                }
                in_wsl2=0; kw=0; mw=0; print; next
            }
            in_wsl2 && /^kernel=/        { print "kernel=" ENVIRON["kernel"]; kw=1; next }
            in_wsl2 && /^kernelModules=/ { print "kernelModules=" ENVIRON["modules"]; mw=1; next }
            { print }
            END {
                if (in_wsl2) {
                    if (!kw) print "kernel=" ENVIRON["kernel"]
                    if (!mw) print "kernelModules=" ENVIRON["modules"]
                }
            }
        ' "$wslconfig" > "$_WSLCONFIG_TMP"
        mv "$_WSLCONFIG_TMP" "$wslconfig"
        _WSLCONFIG_TMP=""
    fi
    log "WSL configured to use custom kernel"
}

# Fix modules VHDX permissions
#
# BUG: When the modules VHDX resides in a user home directory (e.g. C:\Users\<username>\...),
# WSL fails to start with:
#   "Access is denied. Error code: Wsl/Service/CreateInstance/CreateVm/HCS/E_ACCESSDENIED"
#
# The WSL service and Windows app container principals do not have read access to files under
# a user's home directory by default. The fix is to explicitly grant Read+Execute (RX) to:
#   S-1-5-32-545  — BUILTIN\Users
#   S-1-15-2-1    — ALL APPLICATION PACKAGES
#   S-1-15-2-2    — ALL RESTRICTED APPLICATION PACKAGES
#
# Related issues:
#   https://github.com/microsoft/wsl/issues/40482
#   https://github.com/microsoft/WSL/issues/40482#issuecomment-4416647787
#   https://github.com/Locietta/xanmod-kernel-WSL2/issues/153
fix_vhdx_permissions() {
    if [[ "$WSLK_DRY_RUN" == "true" ]]; then
        log "[DRY-RUN] Would grant RX on modules VHDX to BUILTIN\\Users, ALL APPLICATION PACKAGES, ALL RESTRICTED APPLICATION PACKAGES"
        return 0
    fi
    resolve_build_names    || return 1
    resolve_win_output_dir || return 1

    local vhdx_win_path
    vhdx_win_path=$(wslpath -w "${WIN_OUTPUT_DIR}/${MODULES_NAME}")
    log "Fixing modules VHDX permissions (WSL E_ACCESSDENIED workaround)..."
    icacls.exe "$vhdx_win_path" /grant "*S-1-5-32-545:(RX)" || return 1
    icacls.exe "$vhdx_win_path" /grant "*S-1-15-2-1:(RX)"   || return 1
    icacls.exe "$vhdx_win_path" /grant "*S-1-15-2-2:(RX)"   || return 1
    log "VHDX permissions fixed"
}

restart_wsl() {
    if [[ "$WSLK_SKIP_RESTART" == "true" ]]; then
        log "Skipping WSL restart"
        return 0
    fi
    if [[ "$WSLK_DRY_RUN" == "true" ]]; then
        log "[DRY-RUN] Would run: wsl.exe --shutdown"
        return 0
    fi
    log "Shutting down WSL (it will restart on next launch)..."
    wsl.exe --shutdown
    log "Done. Start a new WSL session to use the custom kernel"
}

# ---------------------------------------------------------------------------
# Help
# ---------------------------------------------------------------------------
show_help() {
    local B=$'\033[1m'      # bold
    local C=$'\033[0;36m'   # cyan   — flag / var names
    local G=$'\033[0;32m'   # green  — metavar placeholders
    local D=$'\033[2m'      # dim    — defaults / secondary info
    local R=$'\033[0m'      # reset

    cat <<EOF
${B}Usage:${R} $(basename "$0") [OPTIONS]

Build and install a custom WSL2 kernel from source.
CLI flags take precedence over environment variables.

${B}Options:${R}
  ${C}--step${R} ${G}<name>${R}          Run a single step instead of the full pipeline.
                         Valid steps: install-deps, clone, build-kernel,
                                      build-modules, copy, fix-permissions,
                                      configure-wsl, restart-wsl
  ${C}--repo${R} ${G}<url>${R}           Kernel repo URL
                         ${D}[env: WSLK_KERNEL_REPO, default: https://github.com/Nevuly/WSL2-Linux-Kernel-Rolling]${R}
  ${C}--version${R} ${G}<branch>${R}     Branch or tag to build
                         ${D}[env: WSLK_KERNEL_VERSION, default: auto-detected via git ls-remote]${R}
  ${C}--arch${R} ${G}<arch>${R}          Target architecture
                         ${D}[env: WSLK_ARCH, default: x86]${R}
  ${C}--output-dir${R} ${G}<path>${R}    Windows output directory
                         ${D}[env: WSLK_OUTPUT_DIR, default: %USERPROFILE%\\.wsl-kernel]${R}
  ${C}--src-dir${R} ${G}<path>${R}       Kernel source directory
                         ${D}[env: KERNEL_SRC_DIR, default: /tmp/wsl-kernel]${R}
  ${C}--config${R} ${G}<path>${R}        Kernel config path (relative to source tree)
                         ${D}[env: WSLK_KCONFIG_CONFIG, default: arch/<ARCH>/configs/config-wsl-<ARCH>-rt]${R}
  ${C}--full-clone${R}           Full clone instead of --depth 1
                         ${D}[env: WSLK_FULL_CLONE, default: false]${R}
  ${C}--skip-deps${R}            Skip package installation
                         ${D}[env: WSLK_SKIP_DEPS, default: false]${R}
  ${C}--skip-clone${R}           Skip git clone; source dir must already exist
                         ${D}[env: WSLK_SKIP_REPO_CLONE, default: false]${R}
  ${C}--skip-restart${R}         Skip WSL shutdown after install
                         ${D}[env: WSLK_SKIP_RESTART, default: false]${R}
  ${C}--skip-wsl-check${R}       Skip WSL environment detection
                         ${D}[env: WSLK_SKIP_WSL_CHECK, default: false]${R}
  ${C}--skip-modules-check${R}   Skip gen_modules_vhdx.sh download check
                         ${D}[env: WSLK_SKIP_MODULES_SCRIPT_CHECK, default: false]${R}
  ${C}--dry-run${R}              Print actions without executing
                         ${D}[env: WSLK_DRY_RUN, default: false]${R}
  ${C}-y${R}, ${C}--yes${R}              Skip all Y/N confirmation prompts
  ${C}--non-interactive${R}      Disable all interactive prompts ${D}(implies --yes)${R}
  ${C}-h${R}, ${C}--help${R}             Show this help message and exit
EOF
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --step)
                [[ $# -lt 2 ]] && { log_error "--step requires an argument"; exit 1; }
                _STEP="$2"; shift 2 ;;
            --repo)
                [[ $# -lt 2 ]] && { log_error "--repo requires an argument"; exit 1; }
                WSLK_KERNEL_REPO="$2"; shift 2 ;;
            --version)
                [[ $# -lt 2 ]] && { log_error "--version requires an argument"; exit 1; }
                WSLK_KERNEL_VERSION="$2"; shift 2 ;;
            --arch)
                [[ $# -lt 2 ]] && { log_error "--arch requires an argument"; exit 1; }
                WSLK_ARCH="$2"; shift 2 ;;
            --output-dir)
                [[ $# -lt 2 ]] && { log_error "--output-dir requires an argument"; exit 1; }
                WSLK_OUTPUT_DIR="$2"; shift 2 ;;
            --src-dir)
                [[ $# -lt 2 ]] && { log_error "--src-dir requires an argument"; exit 1; }
                KERNEL_SRC_DIR="$2"; shift 2 ;;
            --config)
                [[ $# -lt 2 ]] && { log_error "--config requires an argument"; exit 1; }
                WSLK_KCONFIG_CONFIG="$2"; shift 2 ;;
            --full-clone)         WSLK_FULL_CLONE="true"; shift ;;
            --skip-deps)          WSLK_SKIP_DEPS="true"; shift ;;
            --skip-clone)         WSLK_SKIP_REPO_CLONE="true"; shift ;;
            --skip-restart)       WSLK_SKIP_RESTART="true"; shift ;;
            --skip-wsl-check)     WSLK_SKIP_WSL_CHECK="true"; shift ;;
            --skip-modules-check) WSLK_SKIP_MODULES_SCRIPT_CHECK="true"; shift ;;
            --dry-run)            WSLK_DRY_RUN="true"; shift ;;
            -y|--yes)             _YES="true"; shift ;;
            --non-interactive)    _NON_INTERACTIVE="true"; _YES="true"; shift ;;
            -h|--help)
                show_help; exit 0 ;;
            *)
                log_error "Unknown option: $1"
                show_help
                exit 1 ;;
        esac
    done
}

# ---------------------------------------------------------------------------
# Step dispatcher
# ---------------------------------------------------------------------------
run_step() {
    local name="$1"
    case "$name" in
        install-deps)    install_deps ;;
        clone)           clone_kernel_repo ;;
        build-kernel)    build_kernel ;;
        build-modules)   build_modules_vhdx ;;
        copy)            copy_to_windows ;;
        fix-permissions) fix_vhdx_permissions ;;
        configure-wsl)   configure_wsl ;;
        restart-wsl)     restart_wsl ;;
        *)
            log_error "Unknown step: '$name'. Valid steps: install-deps, clone, build-kernel, build-modules, copy, fix-permissions, configure-wsl, restart-wsl"
            exit 1 ;;
    esac
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
    parse_args "$@"
    check_wsl_environment

    # Resolve kernel version — interactive prompt, auto-detect, or fallback
    if [[ -z "$_STEP" ]] && is_interactive; then
        interactive_configure
    elif [[ -z "$WSLK_KERNEL_VERSION" ]] && [[ "$WSLK_SKIP_REPO_CLONE" != "true" ]]; then
        log "Auto-detecting latest kernel version from $WSLK_KERNEL_REPO..."
        WSLK_KERNEL_VERSION=$(detect_latest_version "$WSLK_KERNEL_REPO")
        log "Using version: $WSLK_KERNEL_VERSION"
    fi
    # Ensure version is always set (fallback guards against edge cases)
    WSLK_KERNEL_VERSION="${WSLK_KERNEL_VERSION:-wsl-7.0-rolling}"

    # Derive config path now that WSLK_ARCH is finalised
    WSLK_KCONFIG_CONFIG="${WSLK_KCONFIG_CONFIG:-arch/${WSLK_ARCH}/configs/config-wsl-${WSLK_ARCH}-rt}"

    # Show config summary and ask for confirmation (full pipeline only)
    if [[ -z "$_STEP" ]]; then
        show_config_summary
        if [[ "$_YES" != "true" ]] && is_interactive; then
            prompt_yes_no "Proceed with the build?" "y" || { log "Aborted by user."; exit 0; }
            echo ""
        fi
    fi

    # Acquire sudo once and keep it alive for the duration of the build
    if [[ "$WSLK_DRY_RUN" != "true" ]]; then
        start_sudo_keepalive
    fi

    if [[ -n "$_STEP" ]]; then
        log "Running single step: $_STEP"
        run_step "$_STEP" || { log_error "Step '$_STEP' failed"; exit 1; }
        log "Step '$_STEP' completed"
        return 0
    fi

    local -a steps=(install-deps clone build-kernel build-modules copy fix-permissions configure-wsl restart-wsl)
    local total="${#steps[@]}"
    local current=0

    for step in "${steps[@]}"; do
        current=$(( current + 1 ))
        log "[$current/$total] $step"
        run_step "$step" || { log_error "[$current/$total] $step failed"; exit 1; }
    done

    if [[ "$WSLK_DRY_RUN" != "true" ]]; then
        resolve_build_names
        log "Custom WSL kernel installed: $KERNEL_NAME"
    else
        log "[DRY-RUN] All steps completed — no changes were made"
    fi
}

main "$@"
