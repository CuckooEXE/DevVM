#!/usr/bin/env bash
# End-to-end VM test harness.
#
# Boots a fresh Debian Trixie cloud image under QEMU, rsyncs the DevVMSetup
# repo in, runs ./bootstrap.sh --mode full, then drops the invoking user
# into an interactive SSH session on the VM for hands-on validation.
#
# Usage:
#   tests/run-vm.sh [command] [--fresh] [--skip-install] [--memory N] [--cpus N]
#
# Commands (default = `up`):
#   up           Boot VM, install DevVMSetup, open SSH shell. Re-entrant: if a
#                VM is already running, skips boot and just opens SSH.
#   boot         Boot VM only; don't install or open SSH.
#   ssh          SSH into the running VM.
#   sync         Re-rsync the host repo into the running VM. Use this after
#                editing files on the host without restarting the VM.
#   console      Tail the serial-console log (great for debugging boot hangs).
#   status       Report whether the VM is running, its PID, and SSH port.
#   destroy      Kill QEMU and remove the overlay disk. Base image + SSH keys
#                are kept so subsequent `up` is fast.
#   clean        Like `destroy`, but also deletes the cached base image and
#                generated SSH keys — full reset.
#
# Flags:
#   --fresh          Force re-creation of the overlay disk (discard VM state).
#   --skip-install   `up` only: boot + rsync repo + ssh, don't auto-run
#                    bootstrap.sh. Use this to drive the installer by hand.
#   --memory N       Guest RAM in GiB (default 8).
#   --cpus N         Guest vCPUs (default 4).
#   --port N         Host port forwarded to guest :22 (default 2222).
#   --config PATH    vmconfig.yaml to copy into the VM (default: repo root).
#
# Prereqs on the host (Debian 13 Trixie):
#   sudo apt install qemu-system-x86 qemu-utils cloud-image-utils
#
# Everything the test creates lives under tests/.vm/ (gitignored).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
VM_DIR="$SCRIPT_DIR/.vm"
CLOUD_INIT_DIR="$SCRIPT_DIR/cloud-init"

# --- defaults --------------------------------------------------------------
DEFAULT_CPUS=4
DEFAULT_MEM=8           # GiB
DEFAULT_PORT=2222
DEFAULT_DISK_SIZE=40    # GiB
BASE_IMAGE_URL="https://cloud.debian.org/images/cloud/trixie/latest/debian-13-generic-amd64.qcow2"
BASE_IMAGE_SHA_URL="https://cloud.debian.org/images/cloud/trixie/latest/SHA512SUMS"
BASE_IMAGE_NAME="debian-13-generic-amd64.qcow2"

# --- parsed args -----------------------------------------------------------
COMMAND="up"
FRESH=0
SKIP_INSTALL=0
MEM="$DEFAULT_MEM"
CPUS="$DEFAULT_CPUS"
PORT="$DEFAULT_PORT"
CONFIG_YAML="$REPO_DIR/vmconfig.yaml"

# --- terminal colors (only if stdout is a tty) -----------------------------
if [[ -t 1 ]]; then
    C_BLUE=$'\033[1;34m'; C_YEL=$'\033[1;33m'; C_RED=$'\033[1;31m'
    C_GRN=$'\033[1;32m'; C_RST=$'\033[0m'
else
    C_BLUE=""; C_YEL=""; C_RED=""; C_GRN=""; C_RST=""
fi
log()  { printf '%s[run-vm]%s %s\n' "$C_BLUE" "$C_RST" "$*" >&2; }
warn() { printf '%s[warn]%s %s\n'  "$C_YEL"  "$C_RST" "$*" >&2; }
die()  { printf '%s[fail]%s %s\n'  "$C_RED"  "$C_RST" "$*" >&2; exit 1; }
ok()   { printf '%s[ok]%s %s\n'    "$C_GRN"  "$C_RST" "$*" >&2; }

# --- argv parsing ----------------------------------------------------------
while (( $# )); do
    case "$1" in
        up|boot|ssh|sync|console|status|destroy|clean) COMMAND="$1"; shift ;;
        --fresh)        FRESH=1; shift ;;
        --skip-install) SKIP_INSTALL=1; shift ;;
        --memory)       MEM="$2"; shift 2 ;;
        --cpus)         CPUS="$2"; shift 2 ;;
        --port)         PORT="$2"; shift 2 ;;
        --config)       CONFIG_YAML="$2"; shift 2 ;;
        -h|--help)      sed -n '2,33p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) die "unknown argument: $1 (try --help)" ;;
    esac
done

# --- paths derived from VM_DIR --------------------------------------------
BASE_IMAGE="$VM_DIR/$BASE_IMAGE_NAME"
DISK_IMAGE="$VM_DIR/disk.qcow2"
SEED_ISO="$VM_DIR/seed.iso"
SSH_KEY="$VM_DIR/ssh_key"
SSH_PUBKEY="$SSH_KEY.pub"
PIDFILE="$VM_DIR/qemu.pid"
SERIAL_LOG="$VM_DIR/serial.log"
MONITOR_SOCK="$VM_DIR/qemu-monitor.sock"

mkdir -p "$VM_DIR"

ssh_opts=(
    -i "$SSH_KEY"
    -p "$PORT"
    -o StrictHostKeyChecking=no
    -o UserKnownHostsFile=/dev/null
    -o LogLevel=ERROR
    -o ConnectTimeout=5
)

# ---------------------------------------------------------------------------
preflight() {
    local missing=()
    for bin in qemu-system-x86_64 qemu-img ssh ssh-keygen rsync curl sha512sum; do
        command -v "$bin" >/dev/null 2>&1 || missing+=("$bin")
    done
    # ISO builder: prefer cloud-localds (cloud-image-utils), fall back to
    # genisoimage or xorriso. Record which one we'll use.
    ISO_TOOL=""
    for t in cloud-localds genisoimage xorriso; do
        if command -v "$t" >/dev/null 2>&1; then ISO_TOOL="$t"; break; fi
    done
    [[ -n "$ISO_TOOL" ]] || missing+=("cloud-localds (or genisoimage/xorriso)")

    if (( ${#missing[@]} )); then
        warn "missing tools: ${missing[*]}"
        warn "install with:  sudo apt install qemu-system-x86 qemu-utils cloud-image-utils openssh-client rsync curl"
        die  "preflight failed"
    fi

    if [[ -r /dev/kvm && -w /dev/kvm ]]; then
        ACCEL="kvm"
        CPU_ARG="-cpu host"
    else
        warn "/dev/kvm not accessible — falling back to TCG (expect ~10x slower setup)"
        warn "fix with:  sudo adduser \$USER kvm   # then log out/in"
        ACCEL="tcg"
        CPU_ARG="-cpu max"
    fi
}

# ---------------------------------------------------------------------------
ensure_ssh_key() {
    if [[ ! -f "$SSH_KEY" ]]; then
        log "generating SSH keypair at $SSH_KEY"
        ssh-keygen -t ed25519 -N '' -C 'devvmsetup-test' -f "$SSH_KEY" >/dev/null
    fi
}

# ---------------------------------------------------------------------------
ensure_base_image() {
    if [[ -f "$BASE_IMAGE" ]]; then
        log "base image cached: $BASE_IMAGE"
        return
    fi
    log "downloading Debian Trixie cloud image (~400 MB) → $BASE_IMAGE"
    curl -fL --progress-bar -o "$BASE_IMAGE.part" "$BASE_IMAGE_URL"
    mv "$BASE_IMAGE.part" "$BASE_IMAGE"

    log "verifying SHA512 against upstream SHA512SUMS"
    local sums
    sums="$(curl -fsSL "$BASE_IMAGE_SHA_URL")"
    local expected
    expected="$(printf '%s\n' "$sums" | awk -v f="$BASE_IMAGE_NAME" '$2==f {print $1; exit}')"
    if [[ -z "$expected" ]]; then
        warn "couldn't find $BASE_IMAGE_NAME in SHA512SUMS; skipping verification"
        return
    fi
    local actual
    actual="$(sha512sum "$BASE_IMAGE" | awk '{print $1}')"
    if [[ "$expected" != "$actual" ]]; then
        rm -f "$BASE_IMAGE"
        die "SHA512 mismatch for $BASE_IMAGE_NAME"
    fi
    ok "base image verified"
}

# ---------------------------------------------------------------------------
ensure_overlay() {
    if (( FRESH )) && [[ -f "$DISK_IMAGE" ]]; then
        log "--fresh: removing existing overlay $DISK_IMAGE"
        rm -f "$DISK_IMAGE"
    fi
    if [[ -f "$DISK_IMAGE" ]]; then
        log "overlay disk present: $DISK_IMAGE"
        return
    fi
    log "creating overlay qcow2 (backing: $BASE_IMAGE_NAME, size: ${DEFAULT_DISK_SIZE}G)"
    qemu-img create -q -f qcow2 -F qcow2 -b "$BASE_IMAGE" "$DISK_IMAGE" "${DEFAULT_DISK_SIZE}G"
}

# ---------------------------------------------------------------------------
build_seed_iso() {
    local tmp
    tmp="$(mktemp -d)"
    trap 'rm -rf "$tmp"' RETURN

    local pub
    pub="$(cat "$SSH_PUBKEY")"
    sed "s|@@SSH_PUBKEY@@|${pub//|/\\|}|" \
        "$CLOUD_INIT_DIR/user-data.tmpl" > "$tmp/user-data"
    cp "$CLOUD_INIT_DIR/meta-data" "$tmp/meta-data"

    log "building cloud-init seed via $ISO_TOOL"
    case "$ISO_TOOL" in
        cloud-localds)
            cloud-localds "$SEED_ISO" "$tmp/user-data" "$tmp/meta-data"
            ;;
        genisoimage)
            genisoimage -quiet -output "$SEED_ISO" -volid cidata \
                -joliet -rock "$tmp/user-data" "$tmp/meta-data"
            ;;
        xorriso)
            xorriso -as mkisofs -quiet -o "$SEED_ISO" -V cidata \
                -J -r "$tmp/user-data" "$tmp/meta-data"
            ;;
    esac
}

# ---------------------------------------------------------------------------
vm_running() {
    [[ -f "$PIDFILE" ]] || return 1
    local pid
    pid="$(cat "$PIDFILE" 2>/dev/null || true)"
    [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null
}

# ---------------------------------------------------------------------------
start_qemu() {
    if vm_running; then
        log "VM already running (pid $(cat "$PIDFILE"))"
        return
    fi

    log "launching QEMU (accel=$ACCEL, cpus=$CPUS, mem=${MEM}G, ssh=127.0.0.1:$PORT)"
    # shellcheck disable=SC2086
    qemu-system-x86_64 \
        -name devvmsetup-test \
        -machine type=q35,accel="$ACCEL" \
        $CPU_ARG \
        -smp "$CPUS" \
        -m "${MEM}G" \
        -drive "if=virtio,file=$DISK_IMAGE,format=qcow2,discard=unmap" \
        -drive "if=virtio,file=$SEED_ISO,format=raw,readonly=on" \
        -netdev "user,id=net0,hostfwd=tcp:127.0.0.1:${PORT}-:22" \
        -device virtio-net-pci,netdev=net0 \
        -display none \
        -serial "file:$SERIAL_LOG" \
        -monitor "unix:$MONITOR_SOCK,server,nowait" \
        -pidfile "$PIDFILE" \
        -daemonize

    log "QEMU pid $(cat "$PIDFILE") — serial log: $SERIAL_LOG"
}

# ---------------------------------------------------------------------------
wait_for_ssh() {
    log "waiting for SSH on 127.0.0.1:$PORT (up to 10 min)…"
    local deadline=$(( $(date +%s) + 600 ))
    while (( $(date +%s) < deadline )); do
        if ssh "${ssh_opts[@]}" -o BatchMode=yes tester@127.0.0.1 true 2>/dev/null; then
            ok "SSH is up"
            return
        fi
        sleep 3
    done
    die "SSH didn't come up within 10 minutes — inspect $SERIAL_LOG"
}

# ---------------------------------------------------------------------------
wait_for_cloud_init() {
    log "waiting for cloud-init to finish inside the VM…"
    # `cloud-init status --wait` blocks until cloud-init is done (or errored).
    # We run it in a loop so a transient ssh drop during boot doesn't abort us.
    local deadline=$(( $(date +%s) + 600 ))
    while (( $(date +%s) < deadline )); do
        if ssh "${ssh_opts[@]}" tester@127.0.0.1 \
            'sudo cloud-init status --wait' 2>/dev/null; then
            ok "cloud-init complete"
            return
        fi
        sleep 5
    done
    warn "cloud-init didn't report done within 10 min; continuing anyway"
}

# ---------------------------------------------------------------------------
sync_repo() {
    log "rsyncing repo → tester@127.0.0.1:DevVMSetup/ (excluding cache/ and tests/.vm/)"
    # Trailing slash on source copies contents; trailing slash on dest means
    # the target directory. --delete keeps the VM copy faithful to the host
    # after edits.
    rsync -a --delete \
        --exclude='.git/' \
        --exclude='__pycache__/' \
        --exclude='cache/' \
        --exclude='tests/.vm/' \
        --exclude='NeovimOffline/.stage/' \
        --exclude='NeovimOffline/.downloads/' \
        --exclude='NeovimOffline/bin/*.tar.gz' \
        --exclude='NeovimOffline/bin/*.tar.xz' \
        --exclude='NeovimOffline/jdk/*.tar.gz' \
        --exclude='NeovimOffline/share/nvim/lazy/' \
        --exclude='NeovimOffline/share/nvim/mason/' \
        --exclude='NeovimOffline/share/nvim/site/' \
        -e "ssh ${ssh_opts[*]}" \
        "$REPO_DIR/" tester@127.0.0.1:DevVMSetup/

    # If the user pointed --config at a non-default yaml, drop it on top.
    if [[ "$CONFIG_YAML" != "$REPO_DIR/vmconfig.yaml" ]]; then
        log "copying custom config: $CONFIG_YAML → vmconfig.yaml"
        scp "${ssh_opts[@]}" "$CONFIG_YAML" \
            "tester@127.0.0.1:DevVMSetup/vmconfig.yaml" >/dev/null
    fi
}

# ---------------------------------------------------------------------------
run_bootstrap() {
    log "running bootstrap.sh --mode full inside the VM (this will take a while)…"
    # -t for pty so apt/sudo prompts render and Ctrl-C propagates. We don't
    # care about exit code here — we want to drop the user into a shell
    # regardless so they can inspect whatever state the installer left.
    if ssh "${ssh_opts[@]}" -t tester@127.0.0.1 \
        'cd DevVMSetup && ./bootstrap.sh --mode full'
    then
        ok "bootstrap finished successfully"
    else
        warn "bootstrap exited non-zero — opening a shell for inspection anyway"
    fi
}

# ---------------------------------------------------------------------------
open_shell() {
    log "opening interactive SSH shell. Type 'exit' to return to the host."
    log "tip: run commands like 'terminator &' or 'code --version' to validate."
    exec ssh "${ssh_opts[@]}" -t tester@127.0.0.1
}

# ---------------------------------------------------------------------------
cmd_up() {
    preflight
    ensure_ssh_key
    ensure_base_image
    ensure_overlay
    build_seed_iso
    start_qemu
    wait_for_ssh
    wait_for_cloud_init
    # Always rsync the repo in — the user needs it whether or not we auto-run
    # bootstrap.sh. `--skip-install` only gates the installer invocation.
    sync_repo
    if (( ! SKIP_INSTALL )); then
        run_bootstrap
    else
        log "--skip-install: repo synced to ~/DevVMSetup; run ./bootstrap.sh --mode full yourself"
    fi
    open_shell
}

cmd_boot() {
    preflight
    ensure_ssh_key
    ensure_base_image
    ensure_overlay
    build_seed_iso
    start_qemu
    wait_for_ssh
    wait_for_cloud_init
    ok "VM booted. SSH: ssh ${ssh_opts[*]} tester@127.0.0.1"
}

cmd_ssh() {
    vm_running || die "VM is not running (did you run 'up' or 'boot' first?)"
    open_shell
}

cmd_sync() {
    vm_running || die "VM is not running (did you run 'up' or 'boot' first?)"
    sync_repo
    ok "repo synced — existing SSH sessions see the new files immediately"
}

cmd_console() {
    [[ -f "$SERIAL_LOG" ]] || die "no serial log at $SERIAL_LOG"
    exec tail -n 200 -F "$SERIAL_LOG"
}

cmd_status() {
    if vm_running; then
        ok "VM running — pid $(cat "$PIDFILE"), ssh 127.0.0.1:$PORT"
        log "serial log: $SERIAL_LOG"
        log "ssh cmd:    ssh ${ssh_opts[*]} tester@127.0.0.1"
    else
        warn "VM not running"
    fi
}

cmd_destroy() {
    if vm_running; then
        local pid
        pid="$(cat "$PIDFILE")"
        log "shutting down QEMU (pid $pid)…"
        # Try graceful ACPI shutdown via monitor first; fall back to kill.
        if command -v socat >/dev/null 2>&1 && [[ -S "$MONITOR_SOCK" ]]; then
            echo "system_powerdown" | socat - "UNIX-CONNECT:$MONITOR_SOCK" \
                >/dev/null 2>&1 || true
            for _ in 1 2 3 4 5 6 7 8 9 10; do
                vm_running || break
                sleep 1
            done
        fi
        vm_running && kill -TERM "$pid" 2>/dev/null || true
        for _ in 1 2 3 4 5; do
            vm_running || break
            sleep 1
        done
        vm_running && kill -KILL "$pid" 2>/dev/null || true
    fi
    rm -f "$PIDFILE" "$DISK_IMAGE" "$SEED_ISO" "$MONITOR_SOCK"
    ok "VM destroyed (base image + SSH keys kept)"
}

cmd_clean() {
    cmd_destroy
    rm -rf "$VM_DIR"
    ok "cleaned everything under $VM_DIR"
}

# ---------------------------------------------------------------------------
case "$COMMAND" in
    up)       cmd_up ;;
    boot)     cmd_boot ;;
    ssh)      cmd_ssh ;;
    sync)     cmd_sync ;;
    console)  cmd_console ;;
    status)   cmd_status ;;
    destroy)  cmd_destroy ;;
    clean)    cmd_clean ;;
    *)        die "unknown command: $COMMAND" ;;
esac
