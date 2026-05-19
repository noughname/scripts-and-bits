#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration — all settings can be overridden via environment variables
# ---------------------------------------------------------------------------
WSLK_KERNEL_REPO="${WSLK_KERNEL_REPO:-https://github.com/Nevuly/WSL2-Linux-Kernel-Rolling}"
WSLK_KERNEL_VERSION="${WSLK_KERNEL_VERSION:-wsl-7.0-rolling}"
WSLK_OUTPUT_DIR="${WSLK_OUTPUT_DIR:-%USERPROFILE%\.wsl-kernel}"
WSLK_ARCH="${WSLK_ARCH:-x86}"
WSLK_KCONFIG_CONFIG="${WSLK_KCONFIG_CONFIG:-arch/${WSLK_ARCH}/configs/config-wsl-${WSLK_ARCH}-rt}"

WSLK_SKIP_WSL_CHECK="${WSLK_SKIP_WSL_CHECK:-false}"
WSLK_SKIP_DEPS="${WSLK_SKIP_DEPS:-false}"
WSLK_SKIP_REPO_CLONE="${WSLK_SKIP_REPO_CLONE:-false}"
WSLK_FULL_CLONE="${WSLK_FULL_CLONE:-false}"
WSLK_SKIP_MODULES_SCRIPT_CHECK="${WSLK_SKIP_MODULES_SCRIPT_CHECK:-false}"
WSLK_SKIP_RESTART="${WSLK_SKIP_RESTART:-false}"
WSLK_DRY_RUN="${WSLK_DRY_RUN:-false}"

# Default clone target relative to cwd; set externally to override
KERNEL_SRC_DIR="${KERNEL_SRC_DIR:-wsl-kernel-src}"

# ---------------------------------------------------------------------------
# Shared state — set by step functions, consumed by later steps or resolvers
# ---------------------------------------------------------------------------
KERNEL_RELEASE=""
KERNEL_NAME=""
MODULES_NAME=""
MODULES_VHDX_PATH=""
WIN_OUTPUT_DIR=""

# Temporary paths registered for trap-based cleanup
_DOWNLOADED_SCRIPT=""
_WSLCONFIG_TMP=""

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
# Cleanup — registered via trap, removes any temp files created during the run
# ---------------------------------------------------------------------------
cleanup() {
    [[ -n "${_DOWNLOADED_SCRIPT:-}" ]] && rm -f "$_DOWNLOADED_SCRIPT"
    [[ -n "${_WSLCONFIG_TMP:-}" ]]     && rm -f "$_WSLCONFIG_TMP"
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
resolve_win_userprofile() {
    cmd.exe /c "echo %USERPROFILE%" 2>/dev/null | tr -d '\r\n'
}

# Compute KERNEL_RELEASE (cached) and derive artifact names.
# Safe to call multiple times — reuses the cached value after the first call.
# Call this in any step that needs KERNEL_RELEASE, KERNEL_NAME, MODULES_NAME,
# or MODULES_VHDX_PATH.
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
# Call this in any step that needs WIN_OUTPUT_DIR.
resolve_win_output_dir() {
    if [[ -z "$WIN_OUTPUT_DIR" ]]; then
        local win_output_dir_expanded
        win_output_dir_expanded=$(cmd.exe /c "echo ${WSLK_OUTPUT_DIR}" 2>/dev/null | tr -d '\r\n')
        WIN_OUTPUT_DIR=$(wslpath -u "$win_output_dir_expanded")
        mkdir -p "$WIN_OUTPUT_DIR"
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
    # Prefer WSL's injected wslinfo command when available.
    if [[ -x /usr/bin/wslinfo && -L /usr/bin/wslinfo ]]; then
        if /usr/bin/wslinfo --version >/dev/null 2>&1 \
            || /usr/bin/wslinfo --wsl-version >/dev/null 2>&1 \
            || /usr/bin/wslinfo --networking-mode >/dev/null 2>&1; then
            return 0
        fi
        log_error "Detected /usr/bin/wslinfo, but WSL checks failed."
        exit 1
    fi
}

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
            log_error "Unsupported distro: ${ID:-unknown}. Install build dependencies manually and set WSLK_SKIP_DEPS=true"
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
        log_warn "$KERNEL_SRC_DIR already exists; skipping clone. Delete it or set KERNEL_SRC_DIR to a new path to re-clone."
        return 0
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
        log "gen_modules_vhdx.sh not found in repo; downloading from upstream..."
        _DOWNLOADED_SCRIPT=$(mktemp)
        curl -fsSL \
            "https://raw.githubusercontent.com/Nevuly/WSL2-Linux-Kernel-Rolling/refs/heads/master/.github/scripts/gen_modules_vhdx.sh" \
            -o "$_DOWNLOADED_SCRIPT"
        script="$_DOWNLOADED_SCRIPT"
    fi

    if [[ -f "$MODULES_VHDX_PATH" ]]; then
        log "Removing existing $MODULES_VHDX_PATH..."
        sudo rm -f "$MODULES_VHDX_PATH"
    fi

    # gen_modules_vhdx.sh requires root (losetup/mount/umount)
    sudo bash "$script" "$KERNEL_SRC_DIR/$modules_dir" "$KERNEL_RELEASE" "$MODULES_VHDX_PATH" || return 1
    log "Modules vhdx built: $MODULES_VHDX_PATH"

    log "Cleaning up /tmp directories..."
    sudo find /tmp -maxdepth 2 -type f \( -name "modules.img" -o -name "modules_img" \) \
        -exec sh -c 'sudo umount "$(dirname "$1")" 2>/dev/null; sudo umount "$1" 2>/dev/null; sudo rm -rf "$(dirname "$1")"' _ {} \; 2>/dev/null || true
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
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Build and install a custom WSL2 kernel from source.

Options:
  --step <name>   Run a single step instead of the full pipeline.
                  Valid steps: install-deps, clone, build-kernel,
                               build-modules, copy, fix-permissions,
                               configure-wsl, restart-wsl
  --dry-run       Print what would be done without executing anything.
                  Can also be set via WSLK_DRY_RUN=true.
  -h, --help      Show this help message and exit.

Environment variables:
  WSLK_KERNEL_REPO              Git repo URL
                                      (default: https://github.com/Nevuly/WSL2-Linux-Kernel-Rolling)
  WSLK_KERNEL_VERSION           Branch or tag to build
                                      (default: wsl-7.0-rolling)
  WSLK_OUTPUT_DIR               Windows output directory for kernel/modules
                                      (default: %USERPROFILE%\\.wsl-kernel)
  WSLK_ARCH                     Target architecture
                                      (default: x86)
  WSLK_KCONFIG_CONFIG           Kernel config path (relative to source tree)
                                      (default: arch/<ARCH>/configs/config-wsl-<ARCH>-rt)
  WSLK_SKIP_WSL_CHECK           Skip WSL environment detection check (default: false)
  WSLK_SKIP_DEPS                Skip package installation (default: false)
  WSLK_SKIP_REPO_CLONE          Skip git clone; KERNEL_SRC_DIR must already exist
                                      (default: false)
  WSLK_FULL_CLONE               Full clone instead of shallow --depth 1
                                      (default: false)
  WSLK_SKIP_MODULES_SCRIPT_CHECK  Skip download of gen_modules_vhdx.sh if absent
                                      (default: false)
  WSLK_SKIP_RESTART             Skip WSL shutdown after install (default: false)
  WSLK_DRY_RUN                  Print actions without executing (default: false)
  KERNEL_SRC_DIR                    Path to kernel source tree
                                      (default: wsl-kernel-src, relative to cwd)
EOF
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
_STEP=""

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --step)
                [[ $# -lt 2 ]] && { log_error "--step requires an argument"; exit 1; }
                _STEP="$2"; shift 2 ;;
            --dry-run)
                WSLK_DRY_RUN="true"; shift ;;
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

    if [[ "$WSLK_DRY_RUN" == "false" ]]; then
        resolve_build_names
        log "Custom WSL kernel installed: $KERNEL_NAME"
    else
        log "[DRY-RUN] All steps completed — no changes were made"
    fi
}

main "$@"
