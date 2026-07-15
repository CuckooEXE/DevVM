# End-to-end VM test

`tests/run-vm.sh` boots a fresh Debian 13 Trixie cloud image under QEMU,
runs `./bootstrap.sh full && python3 setup.py --mode full` inside it, and
drops you into an interactive SSH shell on the provisioned VM for hands-on
validation.

## Prereqs (Debian 13 host)

```
sudo apt install qemu-system-x86 qemu-utils cloud-image-utils openssh-client rsync curl
sudo apt install qemu-system-modules-spice virt-viewer   # for the `gui` command
sudo adduser "$USER" kvm          # one-time; then log out/in
```

Without `/dev/kvm` access the harness falls back to TCG emulation — it
still works, just ~10× slower.

## Quick start

```
tests/run-vm.sh                   # full flow: boot, install, drop into shell
```

First run takes a while (downloads ~400 MB base image, then the installer
inside the VM fetches multiple GB of apt packages, GitHub releases, docker
images, etc.). Re-runs are faster — the base image is cached; only the
qcow2 overlay is recreated.

## Commands

| Command      | What it does                                                               |
|--------------|----------------------------------------------------------------------------|
| `up`         | default — boot + install + SSH. Re-entrant.                                |
| `boot`       | boot only (no installer, no SSH shell).                                    |
| `ssh`        | SSH into an already-running VM.                                            |
| `sync`       | rsync the host repo into the running VM (after editing files on host).    |
| `pull-cache` | rsync the VM's `cache/` back to the host (e.g. after prepare ran in VM).  |
| `push-cache` | rsync the host's `cache/` into the VM (e.g. to seed an offline install). |
| `gui`        | open the VM's graphical console in a SPICE viewer (see below).            |
| `console`    | tail the QEMU serial-console log (useful for debugging boot hangs).       |
| `status`     | is the VM running?                                                         |
| `destroy`    | power off + remove overlay disk. Keeps base image + SSH keys.             |
| `clean`      | like `destroy` plus wipes everything under `tests/.vm/`.                  |

## Flags

| Flag             | Default | Purpose                                               |
|------------------|---------|-------------------------------------------------------|
| `--fresh`        |         | force re-creation of the overlay disk                |
| `--skip-install` |         | `up`: rsync repo + SSH, don't auto-run bootstrap      |
| `--memory N`     | 8       | guest RAM in GiB                                      |
| `--cpus N`       | 4       | guest vCPUs                                           |
| `--port N`       | 2222    | host port forwarded to guest :22                      |
| `--spice-port N` | 5930    | host port for the SPICE graphical display             |
| `--config PATH`  | repo vmconfig.yaml | substitute a different config into the VM |

## Graphical console (`gui`)

The VM always serves its virtio-vga display over SPICE on
`spice://127.0.0.1:5930` (localhost-only, no ticket). `tests/run-vm.sh gui`
attaches `remote-viewer` (falling back to `spicy`) to it, so you can watch
the console during boot and drive the desktop after the installer sets one
up.

A note on **virt-manager**: virt-manager only lists libvirt-managed
domains, so it cannot attach to this hand-launched QEMU process directly.
`remote-viewer` ships in the `virt-viewer` package alongside virt-manager
and embeds the exact same SPICE console widget — same window, same
keyboard/clipboard integration. Any other SPICE client pointed at
`spice://127.0.0.1:5930` works too.

Clipboard sharing activates once `spice-vdagent` is installed in the guest
(the QEMU side of the channel is already wired up).

If QEMU reports no SPICE support at launch, install the display module and
restart the VM (the overlay disk is kept, so nothing is reinstalled):

```
sudo apt install qemu-system-modules-spice
```

## What happens inside `up`

1. Download the Debian Trixie generic cloud image (once, cached to
   `tests/.vm/`).
2. Create a qcow2 overlay disk (100 GiB, backing-file) — all VM state
   lives here; the base image stays read-only.
3. Render the cloud-init seed ISO from `tests/cloud-init/user-data.tmpl`
   + `meta-data`, substituting the harness-generated SSH pubkey. The
   rendered `user-data`, `meta-data`, and `seed.iso` all stay in
   `tests/.vm/` for post-mortem debugging.
4. Launch QEMU with the overlay, the seed ISO, virtio disk/net, a
   host-forward of `127.0.0.1:2222 → guest:22`, and a SPICE display on
   `127.0.0.1:5930`.
5. Wait for cloud-init to finish (`cloud-init status --wait`).
6. Rsync this repo to `~tester/DevVMSetup/` (excluding `.git/`,
   `__pycache__/`, `cache/`, `tests/.vm/`).
7. Run `./bootstrap.sh full && python3 setup.py --mode full` over SSH —
   the real end-to-end.
8. `exec ssh` into an interactive shell on the provisioned VM.

## Validating after install

Good sanity checks to run inside the SSH shell:

```bash
# Rust + Go + Python + Node toolchains
rustc --version && go version && python3 --version && node --version

# Core CLIs installed from github_releases
rg --version && fd --version && bat --version && eza --version
atuin --version && lazygit --version && starship --version

# pipx-installed tools
pipx list | head

# VSCodium + extensions
codium --list-extensions | wc -l   # should be ~22

# Docker images pulled (incl. locally-built binwalk)
docker image ls

# Agnoster prompt — open a login shell
zsh -i -c 'echo $ZSH_THEME'      # → agnoster

# JetBrainsMono Nerd Font installed system-wide
fc-list | grep -i jetbrains | head

# kstool / cstool on PATH
cstool x64 "48 83 ec 08"
kstool --version

# nikto / Responder / enum4linux-ng (installed from git)
nikto -h https://example.com | head
responder --help 2>&1 | head
enum4linux-ng --help 2>&1 | head

# Go toolchain (installed from tarballs)
go version && gofmt --help >/dev/null && echo gofmt-ok

# Node.js + npm (apt)
node --version && npm --version

# AI coding agents
claude --version         # from the claude-code apt repo
opencode --version       # from github_releases (offline-cacheable)
```

## Shuffling the cache between host and VM

```bash
# ran `setup.py --mode prepare` in the VM? pull the populated cache back:
tests/run-vm.sh pull-cache

# prepared on the host, want to test install in the VM? push the cache in:
tests/run-vm.sh push-cache
```

Both are rsync-based, so re-runs are incremental.

## Cleanup

```
tests/run-vm.sh destroy    # frees the overlay, keeps base image + SSH keys
tests/run-vm.sh clean      # full wipe (re-downloads base on next run)
```
