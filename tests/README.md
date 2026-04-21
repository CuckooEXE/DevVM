# End-to-end VM test

`tests/run-vm.sh` boots a fresh Debian 13 Trixie cloud image under QEMU, runs
`bootstrap.sh --mode full` inside it, and drops you into an interactive SSH
shell on the provisioned VM so you can validate by hand.

## Prereqs (Debian 13 host)

```
sudo apt install qemu-system-x86 qemu-utils cloud-image-utils openssh-client rsync curl
sudo adduser "$USER" kvm          # one-time; then log out/in
```

Without `/dev/kvm` access the harness falls back to TCG emulation — it still
works, just ~10× slower.

## Quick start

```
tests/run-vm.sh                   # full flow: boot, install, drop into shell
```

First run takes a while (downloads ~400 MB base image, then the installer
inside the VM fetches another ~3-4 GB of packages, GitHub releases, docker
images, etc.). Re-runs are faster — the base image is cached and only the
overlay disk is recreated.

## Commands

| Command   | What it does                                                       |
|-----------|--------------------------------------------------------------------|
| `up`      | default — boot + install + SSH. Re-entrant.                        |
| `boot`    | boot only (no installer, no SSH shell).                            |
| `ssh`     | SSH into an already-running VM.                                    |
| `sync`    | rsync the host repo into the running VM (after editing on host).   |
| `console` | tail the QEMU serial-console log (useful for debugging boot hangs).|
| `status`  | is the VM running?                                                 |
| `destroy` | power off + remove overlay disk. Keeps base image + SSH keys.      |
| `clean`   | like `destroy` plus wipes everything under `tests/.vm/`.           |

## Flags

| Flag             | Default | Purpose                                          |
|------------------|---------|--------------------------------------------------|
| `--fresh`        |         | force re-creation of the overlay disk            |
| `--skip-install` |         | `up`: rsync repo + SSH, don't auto-run bootstrap |
| `--memory N`     | 8       | guest RAM in GiB                                 |
| `--cpus N`       | 4       | guest vCPUs                                      |
| `--port N`       | 2222    | host port forwarded to guest :22                 |
| `--config PATH`  | repo vmconfig.yaml | substitute a different config to run  |

## What happens inside

1. Download the Debian Trixie generic cloud image (once, cached to `.vm/`).
2. Create a qcow2 overlay disk — all VM state lives here, base image is
   read-only.
3. Build a cloud-init seed ISO that:
   - creates user `tester` with passwordless sudo,
   - installs the harness-generated SSH key,
   - grows root fs to 40 GiB,
   - starts sshd.
4. Launch QEMU with the overlay, the seed ISO, virtio disk/net, and a
   host-forward of `127.0.0.1:2222 → guest:22`.
5. Wait for cloud-init to finish.
6. Rsync this repo to `~tester/DevVMSetup/` (skipping caches and `tests/.vm`).
7. Run `./bootstrap.sh --mode full` over SSH — this is the real end-to-end.
8. `exec ssh` into an interactive shell on the provisioned VM.

## Validating after install

Good sanity checks to run inside the SSH shell:

```bash
# Basic tools
rg --version && fd --version && bat --version && eza --version
atuin --version && lazygit --version && starship --version

# VSCode + extensions (X11 forwarding not wired — use --help, or `code --list-extensions`)
code --list-extensions | wc -l

# Docker images pulled (incl. locally-built binwalk)
docker image ls

# Agnoster prompt — open a login shell
zsh -i -c 'echo $ZSH_THEME'

# JetBrainsMono Nerd Font installed system-wide
fc-list | grep -i jetbrains

# cstool / kstool on PATH
cstool && kstool
```

## Cleanup

```
tests/run-vm.sh destroy    # frees the 40 GiB overlay, keeps base image
tests/run-vm.sh clean      # full wipe (re-downloads base on next run)
```
