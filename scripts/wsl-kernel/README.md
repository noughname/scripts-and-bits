# wsl-kernel.sh

Build and install a custom WSL2 kernel from source in a single script.

The script clones a WSL2 kernel repo, builds it, packages the modules into a
VHDX, copies everything to the Windows filesystem, and updates `.wslconfig` so
WSL picks up the new kernel on next launch.

---

## Quick start

```sh
curl -O https://raw.githubusercontent.com/q415540/scripts-and-bits/refs/heads/main/scripts/wsl-kernel/wsl-kernel.sh && chmod +x wsl-kernel.sh
./wsl-kernel.sh
```

Running without arguments launches **interactive configuration** — you will be
prompted for the repo, branch/tag, and architecture before the build starts.

> **Note:** The newest available branch is not necessarily the stable release.
> For example, `wsl-7.1-rolling` may be listed while `wsl-7.0-rolling` is still the
> recommended stable version. Check the upstream repo before selecting.

To skip all prompts and accept defaults (useful in CI):

```sh
./wsl-kernel.sh --non-interactive --version wsl-7.0-rolling
```

---

## Build pipeline

The script runs these steps in order. Each can be run individually with
`--step <name>`.

| # | Step name | What it does |
|---|-----------|--------------|
| 1 | `install-deps` | Install build tools via `apt`/`dnf` |
| 2 | `clone` | `git clone` the kernel repo into `KERNEL_SRC_DIR` |
| 3 | `build-kernel` | `make` the kernel image |
| 4 | `build-modules` | `make modules_install` then build `modules.vhdx` |
| 5 | `copy` | Copy `bzImage` and `modules.vhdx` to the Windows output dir |
| 6 | `fix-permissions` | Grant RX on the VHDX to WSL service principals (see below) |
| 7 | `configure-wsl` | Write `kernel=` and `kernelModules=` into `~/.wslconfig` |
| 8 | `restart-wsl` | `wsl.exe --shutdown` — new kernel is active on next launch |

---

## CLI flags

```
Usage: wsl-kernel.sh [OPTIONS]

Build and install a custom WSL2 kernel from source.
CLI flags take precedence over environment variables.

Options:
  --step <name>          Run a single step instead of the full pipeline.
                         Valid steps: install-deps, clone, build-kernel,
                                      build-modules, copy, fix-permissions,
                                      configure-wsl, restart-wsl
  --repo <url>           Kernel repo URL
                         [env: WSLK_KERNEL_REPO, default: https://github.com/Nevuly/WSL2-Linux-Kernel-Rolling]
  --version <branch>     Branch or tag to build
                         [env: WSLK_KERNEL_VERSION, default: auto-detected via git ls-remote]
  --arch <arch>          Target architecture
                         [env: WSLK_ARCH, default: x86]
  --output-dir <path>    Windows output directory
                         [env: WSLK_OUTPUT_DIR, default: %USERPROFILE%\.wsl-kernel]
  --src-dir <path>       Kernel source directory
                         [env: KERNEL_SRC_DIR, default: wsl-kernel-src]
  --config <path>        Kernel config path (relative to source tree)
                         [env: WSLK_KCONFIG_CONFIG, default: arch/<ARCH>/configs/config-wsl-<ARCH>-rt]
  --full-clone           Full clone instead of --depth 1
                         [env: WSLK_FULL_CLONE, default: false]
  --skip-deps            Skip package installation
                         [env: WSLK_SKIP_DEPS, default: false]
  --skip-clone           Skip git clone; source dir must already exist
                         [env: WSLK_SKIP_REPO_CLONE, default: false]
  --skip-restart         Skip WSL shutdown after install
                         [env: WSLK_SKIP_RESTART, default: false]
  --skip-wsl-check       Skip WSL environment detection
                         [env: WSLK_SKIP_WSL_CHECK, default: false]
  --skip-modules-check   Skip gen_modules_vhdx.sh download check
                         [env: WSLK_SKIP_MODULES_SCRIPT_CHECK, default: false]
  --dry-run              Print actions without executing
                         [env: WSLK_DRY_RUN, default: false]
  -y, --yes              Skip all Y/N confirmation prompts
  --non-interactive      Disable all interactive prompts (implies --yes)
  -h, --help             Show this help message and exit
```

All flags have an equivalent environment variable (shown in `--help` output).

---

## Implementation notes

### Source directory defaults to `wsl-kernel-src`

`KERNEL_SRC_DIR` defaults to `wsl-kernel-src` in the current directory,
as the `/tmp` folder may run out of space during the build and cause a failure.
This also avoids potential permission issues when cloning into a user home directory.

### Kernel version auto-detection

When `WSLK_KERNEL_VERSION` is not set, the script runs `git ls-remote --heads`
against `WSLK_KERNEL_REPO` at startup and picks the newest branch whose name
starts with `wsl-`. This keeps the default in sync with the upstream repo
without hardcoding a specific version.

### Sudo keepalive

The script calls `sudo -v` once before the first step and then refreshes the
ticket every 55 seconds in a background subshell for the duration of the build.
This avoids repeated password prompts during a long kernel build.

The keepalive process is registered in the `trap cleanup EXIT` handler and is
killed when the script exits (success or failure).

### `modules.vhdx` and the E_ACCESSDENIED bug

WSL requires the modules VHDX to be readable by the WSL service process and the
Windows app container principals. Files stored in a user's home directory are
**not** readable by those accounts by default, which causes:

```
Access is denied. Error code: Wsl/Service/CreateInstance/CreateVm/HCS/E_ACCESSDENIED
```

The `fix-permissions` step explicitly grants `Read+Execute` to:

- `S-1-5-32-545` — `BUILTIN\Users`
- `S-1-15-2-1` — `ALL APPLICATION PACKAGES`
- `S-1-15-2-2` — `ALL RESTRICTED APPLICATION PACKAGES`

See [microsoft/WSL#40482](https://github.com/microsoft/WSL/issues/40482) for
the upstream discussion.

### `gen_modules_vhdx.sh`

The VHDX is built by `Microsoft/scripts/gen_modules_vhdx.sh`, which is included
in any properly structured WSL kernel tree. If the script is absent from the
cloned repo (e.g. when pointing at a vanilla kernel), the script downloads it
from the official Microsoft WSL2-Linux-Kernel repository as a fallback.

The script runs as root (`sudo bash`) because it needs `losetup`, `mkfs`, and
`mount`/`umount` to create the VHDX image. Any temporary files left in `/tmp`
by the script are cleaned up in the `trap cleanup EXIT` handler.

### `.wslconfig` patching

The `configure-wsl` step edits `~/.wslconfig` (on the Windows side) using an
`awk` one-pass rewrite. It handles three cases:

1. No `[wsl2]` section → appends one
2. `[wsl2]` section present, keys absent → inserts keys at end of section
3. Keys already present → updates them in place

The existing file is backed up to `~/.wslconfig.bak` before any modification.
A `.tmp` file is used for the atomic write and is registered with the cleanup
trap so it is removed even on failure.
