#!/usr/bin/env bash
# vm-manager — libvirt-backed VM lifecycle manager for dev/test VMs.
#
# Create VMs from a cloud-image qcow2 (imported + resized) or an installer
# ISO (blank disk + boot media), manage snapshots, transfer files, and get
# a shell/console/GUI. Targets `qemu:///system` with the `default` network
# + storage pool by default.
#
# Requires: libvirt-clients, virtinst, qemu-utils, and — for --cloud-init —
# cloud-image-utils (cloud-localds) or genisoimage. `gui` uses virt-manager
# (falls back to virt-viewer); `ssh`/`push`/`pull` use openssh + rsync.
# Run as a member of the `libvirt` group; disk steps escalate via sudo.
set -euo pipefail

SCRIPT_NAME="vm-manager"

# Resolve the real directory of this script (following symlinks), so we can
# locate the bundled cloud-init/ dir whether run from the repo or from the
# installed /usr/local/bin/vm-manager symlink/copy.
_src="${BASH_SOURCE[0]}"
while [[ -h "$_src" ]]; do
    _dir="$(cd -P "$(dirname "$_src")" && pwd)"
    _src="$(readlink "$_src")"
    [[ "$_src" != /* ]] && _src="$_dir/$_src"
done
SCRIPT_REAL_DIR="$(cd -P "$(dirname "$_src")" && pwd)"

# ─── defaults / env knobs ────────────────────────────────────────────
LIBVIRT_URI="${LIBVIRT_URI:-qemu:///system}"
POOL="${VM_MANAGER_POOL:-default}"
NETWORK="${VM_MANAGER_NETWORK:-default}"
DEFAULT_MEM_MIB=4096
DEFAULT_VCPUS=2
DEFAULT_DISK_GIB=40
# `--osinfo detect=on,require=off` lets virt-install sniff the image's
# metadata and pick machine knobs without us knowing the guest distro.
DEFAULT_OS_VARIANT="detect=on,require=off"

# Use `"${SUDO[@]}" cmd` so it's a no-op as root and expands to `sudo cmd`
# otherwise.
if [[ $EUID -eq 0 ]]; then
    SUDO=()
else
    SUDO=(sudo)
fi

# ─── small helpers ───────────────────────────────────────────────────
log()  { printf '[%s] %s\n' "$SCRIPT_NAME" "$*" >&2; }
err()  { printf '[%s] error: %s\n' "$SCRIPT_NAME" "$*" >&2; exit 1; }
warn() { printf '[%s] warning: %s\n' "$SCRIPT_NAME" "$*" >&2; }

require_cmd() { command -v "$1" >/dev/null 2>&1 || err "$1 not on PATH"; }

# Person driving the script — sudo invoker takes precedence over $EUID.
real_user() { printf '%s' "${SUDO_USER:-$(id -un)}"; }
real_home() { getent passwd "$(real_user)" | cut -d: -f6; }

virsh_q() { virsh -c "$LIBVIRT_URI" "$@"; }

vm_exists() { virsh_q dominfo "$1" >/dev/null 2>&1; }

vm_running() {
    [[ "$(virsh_q domstate "$1" 2>/dev/null || true)" == "running" ]]
}

pool_path() {
    virsh_q pool-dumpxml "$POOL" 2>/dev/null \
        | sed -n 's|.*<path>\(.*\)</path>.*|\1|p' \
        | head -n1
}

# Normalize a disk-size argument (e.g. 40, 100G, 80GB) to a bare GiB int.
normalize_gib() {
    local v="$1"
    v="${v%[Bb]}"        # trailing B / b
    v="${v%[Gg]}"        # trailing G / g
    [[ "$v" =~ ^[0-9]+$ ]] \
        || err "invalid disk size '$1' (use e.g. 40 or 100G)"
    printf '%s' "$v"
}

# Best-effort guest IPv4: DHCP lease table first (no guest agent needed),
# then the qemu-guest-agent source (static IPs / non-libvirt networks).
guest_ip() {
    local name="$1" ip=""
    ip=$(virsh_q domifaddr "$name" 2>/dev/null \
            | awk '/ipv4/ {print $4}' | cut -d/ -f1 | head -n1) || true
    if [[ -z "$ip" ]]; then
        ip=$(virsh_q domifaddr "$name" --source agent 2>/dev/null \
                | awk '/ipv4/ {print $4}' | cut -d/ -f1 | head -n1) || true
    fi
    printf '%s' "$ip"
}

# Output: each *.pub key on its own line, blanks dropped, deduped.
# shellcheck disable=SC2120  # arg is optional; callers may omit it
collect_ssh_keys() {
    local src="${1:-$(real_home)/.ssh}"
    [[ -d "$src" ]] || return 0
    local keys=()
    shopt -s nullglob
    for f in "$src"/*.pub; do keys+=("$f"); done
    shopt -u nullglob
    (( ${#keys[@]} > 0 )) || return 0
    awk 'NF && !seen[$0]++' "${keys[@]}"
}

# ─── pool / network pruning (used by delete + prune) ─────────────────
pool_is_empty() {
    local pool="$1" n
    n=$(virsh_q vol-list "$pool" --details 2>/dev/null | awk 'NR>2 && NF' | wc -l)
    [[ "$n" -eq 0 ]]
}

network_unused() {
    local net="$1" doms d
    doms="$(virsh_q list --all --name 2>/dev/null | awk 'NF')"
    [[ -z "$doms" ]] && return 0
    while IFS= read -r d; do
        [[ -n "$d" ]] || continue
        if virsh_q dumpxml "$d" 2>/dev/null \
                | grep -qE "<source[^>]+network=['\"]${net}['\"]"; then
            return 1
        fi
    done <<< "$doms"
    return 0
}

maybe_prune_pool() {
    local pool="$1"
    [[ "$pool" == "default" ]] && return 0
    virsh_q pool-info "$pool" >/dev/null 2>&1 || return 0
    if pool_is_empty "$pool"; then
        log "pruning empty pool '$pool'"
        virsh_q pool-destroy  "$pool" >/dev/null 2>&1 || true
        virsh_q pool-undefine "$pool" >/dev/null 2>&1 || true
    fi
}

maybe_prune_network() {
    local net="$1"
    [[ "$net" == "default" ]] && return 0
    virsh_q net-info "$net" >/dev/null 2>&1 || return 0
    if network_unused "$net"; then
        log "pruning unused network '$net'"
        virsh_q net-destroy  "$net" >/dev/null 2>&1 || true
        virsh_q net-undefine "$net" >/dev/null 2>&1 || true
    fi
}

domain_pools_used() {
    local name="$1" path pool
    virsh_q dumpxml "$name" 2>/dev/null \
        | grep -oE "<source [^>]*file=['\"][^'\"]+['\"]" \
        | sed -E "s/.*file=['\"]([^'\"]+)['\"].*/\1/" \
        | while IFS= read -r path; do
              [[ -n "$path" ]] || continue
              pool="$(virsh_q vol-pool "$path" 2>/dev/null | awk 'NF' | head -n1)"
              [[ -n "$pool" ]] && printf '%s\n' "$pool"
          done | sort -u
}

domain_networks_used() {
    local name="$1"
    virsh_q dumpxml "$name" 2>/dev/null \
        | grep -oE "<source[^>]+network=['\"][^'\"]+['\"]" \
        | sed -E "s/.*network=['\"]([^'\"]+)['\"].*/\1/" \
        | sort -u
}

# ─── cloud-init seed ─────────────────────────────────────────────────
# Resolve the default cloud-init dir: env override, then the installed
# share dir, then the repo-relative dir next to this script.
default_cloud_init_dir() {
    if [[ -n "${VM_MANAGER_CLOUD_INIT_DIR:-}" ]]; then
        printf '%s' "$VM_MANAGER_CLOUD_INIT_DIR"; return 0
    fi
    local d
    for d in "$SCRIPT_REAL_DIR/../share/vm-manager/cloud-init" \
             "$SCRIPT_REAL_DIR/../cloud-init"; do
        if [[ -d "$d" ]]; then (cd "$d" && pwd); return 0; fi
    done
    return 1
}

# Render a cloud-init source file, substituting @@TOKENS@@. The pubkey is
# escaped for sed's replacement side (it can carry '/', '&', '\', etc.).
render_ci() {
    local file="$1" hostname="$2" guser="$3" instance="$4" pub="$5"
    local pub_esc
    pub_esc="$(printf '%s' "$pub" | sed -e 's/[&|\\]/\\&/g')"
    sed \
        -e "s|@@SSH_PUBKEY@@|${pub_esc}|g" \
        -e "s|@@HOSTNAME@@|${hostname}|g" \
        -e "s|@@USERNAME@@|${guser}|g" \
        -e "s|@@INSTANCE_ID@@|${instance}|g" \
        "$file"
}

# Build a NoCloud seed ISO from a cloud-init dir into $out_iso.
# Honors user-data[.tmpl], meta-data[.tmpl] (synthesized if absent), and an
# optional network-config.
build_seed_iso() {
    local ci_dir="$1" name="$2" hostname="$3" guser="$4" out_iso="$5"
    [[ -d "$ci_dir" ]] || err "cloud-init dir not found: $ci_dir"
    require_cmd cloud-localds

    local pub
    pub="$(collect_ssh_keys | head -n1)" || true
    [[ -z "$pub" ]] && warn "no SSH pubkey found for $(real_user); guest may be key-less"

    local tmp
    tmp="$(mktemp -d -t "$SCRIPT_NAME-seed-XXXXXX")"

    # user-data is mandatory.
    if [[ -f "$ci_dir/user-data.tmpl" ]]; then
        render_ci "$ci_dir/user-data.tmpl" "$hostname" "$guser" "$name" "$pub" > "$tmp/user-data"
    elif [[ -f "$ci_dir/user-data" ]]; then
        render_ci "$ci_dir/user-data" "$hostname" "$guser" "$name" "$pub" > "$tmp/user-data"
    else
        rm -rf "$tmp"
        err "cloud-init dir '$ci_dir' has no user-data or user-data.tmpl"
    fi

    # meta-data: render if present, else synthesize a minimal one.
    if [[ -f "$ci_dir/meta-data.tmpl" ]]; then
        render_ci "$ci_dir/meta-data.tmpl" "$hostname" "$guser" "$name" "$pub" > "$tmp/meta-data"
    elif [[ -f "$ci_dir/meta-data" ]]; then
        render_ci "$ci_dir/meta-data" "$hostname" "$guser" "$name" "$pub" > "$tmp/meta-data"
    else
        printf 'instance-id: %s\nlocal-hostname: %s\n' "$name" "$hostname" > "$tmp/meta-data"
    fi

    local lds_args=("$out_iso" "$tmp/user-data" "$tmp/meta-data")
    if [[ -f "$ci_dir/network-config" ]]; then
        render_ci "$ci_dir/network-config" "$hostname" "$guser" "$name" "$pub" > "$tmp/network-config"
        lds_args=(--network-config "$tmp/network-config" "${lds_args[@]}")
    fi

    cloud-localds "${lds_args[@]}"
    rm -rf "$tmp"
}

# ─── help ────────────────────────────────────────────────────────────
cmd_help() {
cat <<EOF
$SCRIPT_NAME — libvirt VM lifecycle manager.

Usage:
  $SCRIPT_NAME create <name> <image.qcow2|installer.iso> [flags]
  $SCRIPT_NAME delete <name> [-y|--yes] [--prune]
  $SCRIPT_NAME snapshot create  <name> <snap>
  $SCRIPT_NAME snapshot list    <name>
  $SCRIPT_NAME snapshot delete  <name> <snap>
  $SCRIPT_NAME snapshot restore <name> <snap>
  $SCRIPT_NAME ssh     <name> [ssh args...]
  $SCRIPT_NAME gui     <name>
  $SCRIPT_NAME console <name>
  $SCRIPT_NAME push    <name> <src> <dst>
  $SCRIPT_NAME pull    <name> <src> <dst>
  $SCRIPT_NAME power   <on|off|force-off|reboot|reset|pause|resume|status> <name>
  $SCRIPT_NAME clone   <name> <new-name>
  $SCRIPT_NAME prune   [-y|--yes] [-n|--dry-run]

create flags:
      --cpu N              vCPUs                 (default: $DEFAULT_VCPUS)
      --mem MIB            RAM in MiB            (default: $DEFAULT_MEM_MIB)
      --disk SIZE          virtual disk (e.g. 100G / 40)   (default: ${DEFAULT_DISK_GIB}G)
      --cloud-init [DIR]   seed cloud-init from DIR
                           (default: bundled cloud-init/; \$VM_MANAGER_CLOUD_INIT_DIR)
      --user NAME          guest username token  (default: invoking user)
      --hostname NAME      guest hostname        (default: <name>)
      --os-variant ID      virt-install --osinfo (default: $DEFAULT_OS_VARIANT)

  The image type is inferred from the extension: *.qcow2/*.img/*.raw are
  imported + resized; *.iso boots as installer media on a fresh blank disk.

env knobs:
  LIBVIRT_URI              (default: qemu:///system)
  VM_MANAGER_POOL          storage pool name     (default: default)
  VM_MANAGER_NETWORK       libvirt network name  (default: default)
  VM_MANAGER_CLOUD_INIT_DIR  default --cloud-init dir

Examples:
  $SCRIPT_NAME create dev01 ~/images/debian-13-genericcloud-amd64.qcow2 --cloud-init
  $SCRIPT_NAME create win ~/isos/win.iso --cpu 4 --mem 8192 --disk 120G
  $SCRIPT_NAME snapshot create dev01 clean-baseline
  $SCRIPT_NAME push dev01 ./exploit.py /tmp/exploit.py
  $SCRIPT_NAME ssh dev01
EOF
}

# ─── create ──────────────────────────────────────────────────────────
cmd_create() {
    local name="" source=""
    local mem="$DEFAULT_MEM_MIB" vcpus="$DEFAULT_VCPUS" disk_gib="$DEFAULT_DISK_GIB"
    local guest_user="" hostname="" os_variant="$DEFAULT_OS_VARIANT"
    local cloud_init=0 cloud_init_dir=""

    [[ $# -ge 2 ]] || err "create: need <name> <image.qcow2|installer.iso>"
    name="$1"; source="$2"; shift 2

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --cpu|-c|--vcpus)   vcpus="$2"; shift 2 ;;
            --mem|-m|--memory)  mem="$2"; shift 2 ;;
            --disk|-d|--disk-size) disk_gib="$(normalize_gib "$2")"; shift 2 ;;
            --cloud-init)
                cloud_init=1
                # Optional inline dir: consume the next token only if it
                # isn't another flag. (No positionals follow flags here.)
                if [[ $# -ge 2 && "$2" != -* ]]; then
                    cloud_init_dir="$2"; shift 2
                else
                    shift
                fi
                ;;
            --cloud-init-dir)   cloud_init=1; cloud_init_dir="$2"; shift 2 ;;
            --user|-u)          guest_user="$2"; shift 2 ;;
            --hostname)         hostname="$2"; shift 2 ;;
            --os-variant)       os_variant="$2"; shift 2 ;;
            -h|--help)          cmd_help; return 0 ;;
            *)                  err "create: unknown flag '$1'" ;;
        esac
    done

    : "${guest_user:=$(real_user)}"
    : "${hostname:=$name}"

    [[ -r "$source" ]] || err "image not readable: $source"
    require_cmd virsh
    require_cmd virt-install
    require_cmd qemu-img

    local kind
    case "${source,,}" in
        *.iso)                       kind=iso ;;
        *.qcow2|*.img|*.raw|*.qed)   kind=disk ;;
        *) err "can't infer image type from '$source' (want .qcow2/.img/.raw or .iso)" ;;
    esac

    if vm_exists "$name"; then
        err "VM '$name' already exists (delete it first: $SCRIPT_NAME delete $name)"
    fi

    local pool_dir
    pool_dir="$(pool_path)" || true
    [[ -n "$pool_dir" && -d "$pool_dir" ]] \
        || err "pool '$POOL' has no usable target path (try: virsh pool-start $POOL)"

    local disk="$pool_dir/$name.qcow2"
    local seed_dest="$pool_dir/$name-seed.iso"
    local iso_dest="$pool_dir/$name-cdrom.iso"
    [[ -e "$disk" ]] && err "disk already exists: $disk"

    # Resolve cloud-init dir up front so we fail fast before staging disks.
    if (( cloud_init )); then
        if [[ -z "$cloud_init_dir" ]]; then
            cloud_init_dir="$(default_cloud_init_dir)" \
                || err "no cloud-init dir found (pass --cloud-init <DIR> or set VM_MANAGER_CLOUD_INIT_DIR)"
        fi
        [[ -d "$cloud_init_dir" ]] || err "cloud-init dir not found: $cloud_init_dir"
    elif [[ "$kind" == disk ]]; then
        warn "no --cloud-init: '$name' will have no injected user/SSH key (cloud images have no default login)"
    fi

    # Rollback partial state on failure; set CREATE_OK=1 at the very end.
    local CREATE_OK=0
    cleanup_create() {
        local rc=$?
        if (( CREATE_OK != 1 )); then
            warn "create aborted; rolling back"
            virsh_q destroy  "$name" >/dev/null 2>&1 || true
            virsh_q undefine "$name" --remove-all-storage >/dev/null 2>&1 || true
            "${SUDO[@]}" rm -f "$disk" "$seed_dest" "$iso_dest" 2>/dev/null || true
        fi
        exit "$rc"
    }
    trap cleanup_create EXIT

    # ─── stage the primary disk ──────────────────────────────────────
    if [[ "$kind" == disk ]]; then
        log "importing disk $disk from $source (resize → ${disk_gib}G)"
        "${SUDO[@]}" qemu-img convert -O qcow2 -p "$source" "$disk"
        "${SUDO[@]}" qemu-img resize "$disk" "${disk_gib}G"
    else
        log "creating blank disk $disk (${disk_gib}G)"
        "${SUDO[@]}" qemu-img create -q -f qcow2 "$disk" "${disk_gib}G"
    fi

    # ─── build install args ──────────────────────────────────────────
    local install_args=(
        --connect "$LIBVIRT_URI"
        --name "$name"
        --memory "$mem"
        --vcpus "$vcpus"
        --osinfo "$os_variant"
        --disk "path=$disk,format=qcow2,bus=virtio"
        --network "network=$NETWORK,model=virtio"
        --graphics spice
        --noautoconsole
    )

    if (( cloud_init )); then
        log "seeding cloud-init from $cloud_init_dir"
        local seed_tmp
        seed_tmp="$(mktemp -t "$SCRIPT_NAME-seed-XXXXXX.iso")"
        build_seed_iso "$cloud_init_dir" "$name" "$hostname" "$guest_user" "$seed_tmp"
        "${SUDO[@]}" install -m 0644 "$seed_tmp" "$seed_dest"
        rm -f "$seed_tmp"
        install_args+=(--disk "path=$seed_dest,device=cdrom")
    fi

    if [[ "$kind" == iso ]]; then
        # Copy the installer into the pool so qemu:///system can read it
        # regardless of where the source lived.
        log "staging installer ISO → $iso_dest"
        "${SUDO[@]}" install -m 0644 "$source" "$iso_dest"
        install_args+=(--disk "path=$iso_dest,device=cdrom,boot.order=1")
        install_args+=(--disk "path=$disk,boot.order=2")  # ensure HD is bootable post-install
    else
        install_args+=(--import)
    fi

    log "defining + starting '$name' (${mem}MiB / ${vcpus}vCPU / ${disk_gib}G / $kind)"
    "${SUDO[@]}" virt-install "${install_args[@]}"

    CREATE_OK=1
    if [[ "$kind" == iso ]]; then
        log "'$name' booted from installer. Run '$SCRIPT_NAME gui $name' to complete setup."
    elif (( cloud_init )); then
        log "'$name' booted; cloud-init running. Try '$SCRIPT_NAME ssh $name' in ~30s."
    else
        log "'$name' booted. Use '$SCRIPT_NAME console $name' to log in."
    fi
}

# ─── snapshot ────────────────────────────────────────────────────────
cmd_snapshot() {
    local sub="${1:-}"
    case "$sub" in
        create)
            shift
            [[ $# -ge 2 ]] || err "snapshot create: need <name> <snap>"
            vm_exists "$1" || err "VM '$1' doesn't exist"
            virsh_q snapshot-create-as --domain "$1" --name "$2"
            ;;
        list)
            shift
            [[ $# -ge 1 ]] || err "snapshot list: need <name>"
            vm_exists "$1" || err "VM '$1' doesn't exist"
            virsh_q snapshot-list --domain "$1"
            ;;
        delete|rm)
            shift
            [[ $# -ge 2 ]] || err "snapshot delete: need <name> <snap>"
            vm_exists "$1" || err "VM '$1' doesn't exist"
            virsh_q snapshot-delete --domain "$1" --snapshotname "$2"
            ;;
        restore|revert)
            shift
            [[ $# -ge 2 ]] || err "snapshot restore: need <name> <snap>"
            vm_exists "$1" || err "VM '$1' doesn't exist"
            virsh_q snapshot-revert --domain "$1" --snapshotname "$2"
            ;;
        ""|-h|--help) cmd_help ;;
        *) err "snapshot: unknown subcommand '$sub' (use create|list|delete|restore)" ;;
    esac
}

# ─── ssh ─────────────────────────────────────────────────────────────
cmd_ssh() {
    [[ $# -ge 1 ]] || err "ssh: need <name>"
    local name="$1"; shift
    vm_exists "$name" || err "VM '$name' doesn't exist"
    vm_running "$name" || err "VM '$name' is not running (try '$SCRIPT_NAME power on $name')"
    require_cmd ssh

    local ip; ip="$(guest_ip "$name")"
    [[ -n "$ip" ]] \
        || err "no IP for '$name' yet (wait for DHCP, or install qemu-guest-agent in the guest)"
    local user; user="$(real_user)"
    log "ssh $user@$ip $*"
    exec ssh "$user@$ip" "$@"
}

# ─── gui ─────────────────────────────────────────────────────────────
cmd_gui() {
    [[ $# -ge 1 ]] || err "gui: need <name>"
    local name="$1"
    vm_exists "$name" || err "VM '$name' doesn't exist"
    if command -v virt-manager >/dev/null 2>&1; then
        log "opening virt-manager console for '$name'"
        exec virt-manager --connect "$LIBVIRT_URI" --show-domain-console "$name"
    elif command -v virt-viewer >/dev/null 2>&1; then
        warn "virt-manager not found; using virt-viewer"
        exec virt-viewer --connect "$LIBVIRT_URI" "$name"
    else
        err "neither virt-manager nor virt-viewer found (apt install virt-manager)"
    fi
}

# ─── console ─────────────────────────────────────────────────────────
cmd_console() {
    [[ $# -ge 1 ]] || err "console: need <name>"
    local name="$1"; shift
    vm_exists "$name" || err "VM '$name' doesn't exist"
    log "attaching serial console to '$name' (escape: Ctrl-])"
    exec virsh_q console "$name" "$@"
}

# ─── push / pull ─────────────────────────────────────────────────────
_transfer() {
    local dir="$1" name="$2" a="$3" b="$4"   # dir = push|pull
    vm_exists "$name" || err "VM '$name' doesn't exist"
    vm_running "$name" || err "VM '$name' is not running (try '$SCRIPT_NAME power on $name')"

    local ip; ip="$(guest_ip "$name")"
    [[ -n "$ip" ]] || err "no IP for '$name' yet (wait for DHCP / qemu-guest-agent)"
    local user; user="$(real_user)"

    local tool
    if command -v rsync >/dev/null 2>&1; then tool=rsync
    elif command -v scp >/dev/null 2>&1; then tool=scp
    else err "need rsync or scp on PATH"; fi

    if [[ "$dir" == push ]]; then
        log "$tool $a → $user@$ip:$b"
        if [[ "$tool" == rsync ]]; then exec rsync -avz -e ssh "$a" "$user@$ip:$b"
        else exec scp -r "$a" "$user@$ip:$b"; fi
    else
        log "$tool $user@$ip:$a → $b"
        if [[ "$tool" == rsync ]]; then exec rsync -avz -e ssh "$user@$ip:$a" "$b"
        else exec scp -r "$user@$ip:$a" "$b"; fi
    fi
}

cmd_push() {
    [[ $# -ge 3 ]] || err "push: need <name> <src> <dst>"
    _transfer push "$1" "$2" "$3"
}

cmd_pull() {
    [[ $# -ge 3 ]] || err "pull: need <name> <src> <dst>"
    _transfer pull "$1" "$2" "$3"
}

# ─── power ───────────────────────────────────────────────────────────
cmd_power() {
    local action="${1:-}" name="${2:-}"
    [[ -n "$action" && -n "$name" ]] || err "power: need <action> <name>"
    vm_exists "$name" || err "VM '$name' doesn't exist"
    case "$action" in
        on|start)           virsh_q start    "$name" ;;
        off|shutdown)       virsh_q shutdown "$name" ;;
        force-off|destroy)  virsh_q destroy  "$name" ;;
        reboot)             virsh_q reboot   "$name" ;;
        reset)              virsh_q reset    "$name" ;;
        pause|suspend)      virsh_q suspend  "$name" ;;
        resume)             virsh_q resume   "$name" ;;
        status|state)       virsh_q domstate "$name" ;;
        *) err "power: unknown action '$action' (on|off|force-off|reboot|reset|pause|resume|status)" ;;
    esac
}

# ─── clone ───────────────────────────────────────────────────────────
cmd_clone() {
    [[ $# -ge 2 ]] || err "clone: need <name> <new-name>"
    require_cmd virt-clone
    local src="$1" dst="$2"
    vm_exists "$src" || err "source VM '$src' doesn't exist"
    vm_exists "$dst" && err "target VM '$dst' already exists"
    "${SUDO[@]}" virt-clone --connect "$LIBVIRT_URI" \
        --original "$src" --name "$dst" --auto-clone
}

# ─── delete ──────────────────────────────────────────────────────────
cmd_delete() {
    local name="" force=0 prune=0
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -y|--yes|--force) force=1; shift ;;
            --prune)          prune=1; shift ;;
            -h|--help)        cmd_help; return 0 ;;
            -*)               err "delete: unknown flag '$1'" ;;
            *)
                [[ -z "$name" ]] || err "delete: too many args"
                name="$1"; shift ;;
        esac
    done
    [[ -n "$name" ]] || err "delete: need <name>"
    vm_exists "$name" || err "VM '$name' doesn't exist"

    if (( force == 0 )); then
        printf '[%s] delete VM %q and all its disks/snapshots? [y/N] ' "$SCRIPT_NAME" "$name" >&2
        local ans; read -r ans
        [[ "$ans" =~ ^[Yy]$ ]] || { log "aborted"; return 1; }
    fi

    # Capture pool/network refs + pool dir BEFORE undefine — domain XML and
    # volume metadata vanish after --remove-all-storage.
    local pool_dir; pool_dir="$(pool_path)" || true
    local pools_used=() nets_used=() line
    if (( prune == 1 )); then
        while IFS= read -r line; do [[ -n "$line" ]] && pools_used+=("$line"); done \
            < <(domain_pools_used "$name")
        while IFS= read -r line; do [[ -n "$line" ]] && nets_used+=("$line"); done \
            < <(domain_networks_used "$name")
    fi

    local state; state="$(virsh_q domstate "$name" 2>/dev/null || true)"
    case "$state" in
        running|paused|"in shutdown")
            log "destroying running VM '$name'"
            virsh_q destroy "$name" >/dev/null 2>&1 || true
            ;;
    esac

    # Internal qcow2 snapshots block undefine; clean them first.
    local snaps
    snaps="$(virsh_q snapshot-list --name --domain "$name" 2>/dev/null | awk 'NF')"
    if [[ -n "$snaps" ]]; then
        log "deleting $(printf '%s\n' "$snaps" | wc -l) snapshot(s)"
        while IFS= read -r snap; do
            virsh_q snapshot-delete --domain "$name" --snapshotname "$snap" \
                >/dev/null 2>&1 || true
        done <<< "$snaps"
    fi

    log "undefining VM '$name' + removing all storage"
    local extra=(--managed-save --snapshots-metadata --checkpoints-metadata --remove-all-storage)
    virsh_q undefine "$name" "${extra[@]}" --nvram 2>/dev/null \
        || virsh_q undefine "$name" "${extra[@]}"

    # Best-effort sweep of seed/installer media create left in the pool dir
    # (these aren't always tracked as removable domain storage).
    if [[ -n "$pool_dir" ]]; then
        "${SUDO[@]}" rm -f "$pool_dir/$name-seed.iso" "$pool_dir/$name-cdrom.iso" 2>/dev/null || true
    fi

    if (( prune == 1 )); then
        local p n
        for p in "${pools_used[@]}"; do maybe_prune_pool "$p"; done
        for n in "${nets_used[@]}";  do maybe_prune_network "$n"; done
    fi
}

# ─── prune ───────────────────────────────────────────────────────────
cmd_prune() {
    local force=0 dry=0
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -y|--yes|--force) force=1; shift ;;
            -n|--dry-run)     dry=1; shift ;;
            -h|--help)        cmd_help; return 0 ;;
            *)                err "prune: unknown flag '$1'" ;;
        esac
    done

    local empty_pools=() unused_nets=() p n
    while IFS= read -r p; do
        [[ -n "$p" && "$p" != "default" ]] || continue
        pool_is_empty "$p" && empty_pools+=("$p")
    done < <(virsh_q pool-list --all --name 2>/dev/null | awk 'NF')

    while IFS= read -r n; do
        [[ -n "$n" && "$n" != "default" ]] || continue
        network_unused "$n" && unused_nets+=("$n")
    done < <(virsh_q net-list --all --name 2>/dev/null | awk 'NF')

    if (( ${#empty_pools[@]} == 0 && ${#unused_nets[@]} == 0 )); then
        log "nothing to prune"; return 0
    fi

    log "candidates:"
    (( ${#empty_pools[@]} > 0 )) && log "  empty pools:     ${empty_pools[*]}"
    (( ${#unused_nets[@]} > 0 )) && log "  unused networks: ${unused_nets[*]}"
    (( dry == 1 )) && return 0

    if (( force == 0 )); then
        printf '[%s] tear them all down? [y/N] ' "$SCRIPT_NAME" >&2
        local ans; read -r ans
        [[ "$ans" =~ ^[Yy]$ ]] || { log "aborted"; return 1; }
    fi

    for p in "${empty_pools[@]}"; do maybe_prune_pool "$p"; done
    for n in "${unused_nets[@]}"; do maybe_prune_network "$n"; done
}

# ─── dispatch ────────────────────────────────────────────────────────
main() {
    if [[ $# -eq 0 ]]; then cmd_help; return 0; fi
    local cmd="$1"; shift
    case "$cmd" in
        help|-h|--help)  cmd_help ;;
        create)          cmd_create "$@" ;;
        bootstrap)       warn "'bootstrap' renamed to 'create'"; cmd_create "$@" ;;
        delete|destroy)  cmd_delete "$@" ;;
        snapshot|snap)   cmd_snapshot "$@" ;;
        ssh)             cmd_ssh "$@" ;;
        gui)             cmd_gui "$@" ;;
        console)         cmd_console "$@" ;;
        push)            cmd_push "$@" ;;
        pull)            cmd_pull "$@" ;;
        power)           cmd_power "$@" ;;
        clone)           cmd_clone "$@" ;;
        prune)           cmd_prune "$@" ;;
        *) err "unknown command '$cmd' — run '$SCRIPT_NAME help'" ;;
    esac
}

main "$@"
