#!/usr/bin/env bash
# vm-manager — thin libvirt + cloud-init wrapper for dev/test VMs.
#
# Bootstraps from a cloud-image qcow2 + a generated cloud-init seed ISO,
# manages snapshots/clones/power, and wraps `virsh domifaddr` for SSH.
# Designed for `qemu:///system` with the `default` network + pool.
#
# Requires: libvirt-clients, virtinst, cloud-image-utils, qemu-utils,
# genisoimage (or xorriso). Run as a member of the `libvirt` group;
# disk-creation steps escalate via sudo as needed.
set -euo pipefail

SCRIPT_NAME="vm-manager"

# ─── defaults / env knobs ────────────────────────────────────────────
LIBVIRT_URI="${LIBVIRT_URI:-qemu:///system}"
POOL="${VM_MANAGER_POOL:-default}"
NETWORK="${VM_MANAGER_NETWORK:-default}"
DEFAULT_MEM_MIB=4096
DEFAULT_VCPUS=2
DEFAULT_DISK_GIB=40
# `--osinfo detect=on,require=off` lets virt-install sniff the cloud
# image's metadata and pick the right machine knobs without us having
# to know the guest distro up front.
DEFAULT_OS_VARIANT="detect=on,require=off"

# Use `"${SUDO[@]}" cmd` so it's a no-op when running as root and
# expands to `sudo cmd` otherwise.
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

pool_path() {
    virsh_q pool-dumpxml "$POOL" 2>/dev/null \
        | sed -n 's|.*<path>\(.*\)</path>.*|\1|p' \
        | head -n1
}

# True if the named pool has zero volumes.
pool_is_empty() {
    local pool="$1"
    local n
    n=$(virsh_q vol-list "$pool" --details 2>/dev/null | awk 'NR>2 && NF' | wc -l)
    [[ "$n" -eq 0 ]]
}

# True if no defined domain references the named network.
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

# Tear down a pool if it's non-default and empty. Idempotent.
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

# Tear down a network if it's non-default and unused.
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

# Echo, one per line: pool names that hold a disk attached to <name>.
# Must be called BEFORE undefine — disk volume metadata vanishes after.
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

# Echo, one per line: networks attached to <name>.
domain_networks_used() {
    local name="$1"
    virsh_q dumpxml "$name" 2>/dev/null \
        | grep -oE "<source[^>]+network=['\"][^'\"]+['\"]" \
        | sed -E "s/.*network=['\"]([^'\"]+)['\"].*/\1/" \
        | sort -u
}

# Output: each *.pub key on its own line, blanks dropped, deduped.
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

# ─── help ────────────────────────────────────────────────────────────
cmd_help() {
cat <<EOF
$SCRIPT_NAME — manage dev/test VMs via libvirt.

Usage:
  $SCRIPT_NAME help
  $SCRIPT_NAME bootstrap <name> <base-image.qcow2> [flags]
  $SCRIPT_NAME ssh <name> [ssh args...]
  $SCRIPT_NAME snapshot create  <name> <snap>
  $SCRIPT_NAME snapshot restore <name> <snap>
  $SCRIPT_NAME snapshot list    <name>
  $SCRIPT_NAME clone create <name> <new-name>
  $SCRIPT_NAME power <on|off|force-off|reboot|reset|pause|resume|status> <name>
  $SCRIPT_NAME delete <name> [-y|--yes] [--prune]
  $SCRIPT_NAME prune [-y|--yes] [-n|--dry-run]

bootstrap flags:
  -m, --memory MIB         RAM in MiB           (default: $DEFAULT_MEM_MIB)
  -c, --vcpus  N           vCPUs                (default: $DEFAULT_VCPUS)
  -d, --disk-size GIB      virtual disk, GiB    (default: $DEFAULT_DISK_GIB)
  -u, --user NAME          guest username       (default: invoking user)
  -p, --password PASS      guest password       (default: locked, SSH-only)
      --hostname NAME      guest hostname       (default: <name>)
      --ssh-keys-from DIR  glob 'DIR/*.pub' for authorized_keys
                           (default: ~/.ssh of invoking user)
      --no-ssh-keys        skip SSH key injection
      --os-variant ID      virt-install --osinfo (default: $DEFAULT_OS_VARIANT)

env knobs:
  LIBVIRT_URI            (default: qemu:///system)
  VM_MANAGER_POOL        storage pool name      (default: default)
  VM_MANAGER_NETWORK     libvirt network name   (default: default)

Examples:
  $SCRIPT_NAME bootstrap dev01 ~/images/debian-13-genericcloud-amd64.qcow2
  $SCRIPT_NAME bootstrap rev-bench ~/images/kali.qcow2 -m 8192 -c 4 -d 80
  $SCRIPT_NAME ssh dev01
  $SCRIPT_NAME snapshot create dev01 clean-baseline
  $SCRIPT_NAME power off dev01
EOF
}

# ─── bootstrap ───────────────────────────────────────────────────────
cmd_bootstrap() {
    local name="" base=""
    local mem="$DEFAULT_MEM_MIB" vcpus="$DEFAULT_VCPUS" disk_gib="$DEFAULT_DISK_GIB"
    local guest_user="" password="" hostname=""
    local ssh_keys_from="" no_ssh_keys=0
    local os_variant="$DEFAULT_OS_VARIANT"

    [[ $# -ge 2 ]] || err "bootstrap: need <name> <base-image.qcow2>"
    name="$1"; base="$2"; shift 2

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -m|--memory)        mem="$2"; shift 2 ;;
            -c|--vcpus)         vcpus="$2"; shift 2 ;;
            -d|--disk-size)     disk_gib="$2"; shift 2 ;;
            -u|--user)          guest_user="$2"; shift 2 ;;
            -p|--password)      password="$2"; shift 2 ;;
            --hostname)         hostname="$2"; shift 2 ;;
            --ssh-keys-from)    ssh_keys_from="$2"; shift 2 ;;
            --no-ssh-keys)      no_ssh_keys=1; shift ;;
            --os-variant)       os_variant="$2"; shift 2 ;;
            -h|--help)          cmd_help; return 0 ;;
            *)                  err "bootstrap: unknown flag '$1'" ;;
        esac
    done

    : "${guest_user:=$(real_user)}"
    : "${hostname:=$name}"

    [[ -r "$base" ]] || err "base image not readable: $base"
    require_cmd virsh
    require_cmd virt-install
    require_cmd cloud-localds
    require_cmd qemu-img

    if vm_exists "$name"; then
        err "VM '$name' already exists (use 'power off' + 'virsh undefine $name')"
    fi

    local pool_dir
    pool_dir="$(pool_path)" || true
    [[ -n "$pool_dir" && -d "$pool_dir" ]] \
        || err "pool '$POOL' has no usable target path (try: virsh pool-start $POOL)"

    local disk="$pool_dir/$name.qcow2"
    local seed_dest="$pool_dir/$name-seed.iso"
    [[ -e "$disk" ]] && err "disk already exists: $disk"
    [[ -e "$seed_dest" ]] && err "seed iso already exists: $seed_dest"

    # Cleanup partial state on failure. Set BOOTSTRAP_OK=1 at the very
    # end so a successful run skips the rollback.
    local tmp BOOTSTRAP_OK=0
    tmp="$(mktemp -d -t "$SCRIPT_NAME-XXXXXX")"
    cleanup_bootstrap() {
        local rc=$?
        if (( BOOTSTRAP_OK != 1 )); then
            warn "bootstrap aborted; rolling back"
            virsh_q destroy  "$name" >/dev/null 2>&1 || true
            virsh_q undefine "$name" --remove-all-storage >/dev/null 2>&1 || true
            "${SUDO[@]}" rm -f "$disk" "$seed_dest" 2>/dev/null || true
        fi
        rm -rf "$tmp"
        exit "$rc"
    }
    trap cleanup_bootstrap EXIT

    # ─── 1. stage the disk: full copy of base, then resize ───────────
    log "creating disk $disk from $base (${disk_gib}G)"
    "${SUDO[@]}" qemu-img convert -O qcow2 -p "$base" "$disk"
    "${SUDO[@]}" qemu-img resize "$disk" "${disk_gib}G"

    # ─── 2. write cloud-init user-data + meta-data ───────────────────
    local user_data="$tmp/user-data" meta_data="$tmp/meta-data"

    {
        echo "#cloud-config"
        echo "hostname: $hostname"
        echo "manage_etc_hosts: true"
        echo "users:"
        echo "  - name: $guest_user"
        echo "    sudo: 'ALL=(ALL) NOPASSWD:ALL'"
        echo "    shell: /bin/bash"
        if (( no_ssh_keys == 0 )); then
            local key_src="${ssh_keys_from:-$(real_home)/.ssh}"
            local keys
            keys="$(collect_ssh_keys "$key_src")" || true
            if [[ -z "$keys" ]]; then
                warn "no *.pub keys found in $key_src; '$guest_user' will be SSH-key-less"
            else
                echo "    ssh_authorized_keys:"
                while IFS= read -r line; do
                    [[ -n "$line" ]] || continue
                    # Quote with double-quotes; `"` inside ssh keys is
                    # not a thing in practice, but escape just in case.
                    printf '      - "%s"\n' "${line//\"/\\\"}"
                done <<< "$keys"
            fi
        fi
        if [[ -n "$password" ]]; then
            echo "    lock_passwd: false"
            echo "ssh_pwauth: true"
            echo "chpasswd:"
            echo "  expire: false"
            echo "  list: |"
            echo "    $guest_user:$password"
        else
            echo "    lock_passwd: true"
            echo "ssh_pwauth: false"
        fi
    } > "$user_data"

    {
        echo "instance-id: $name"
        echo "local-hostname: $hostname"
    } > "$meta_data"

    # ─── 3. build the seed ISO + place it in the pool dir ────────────
    local seed_tmp="$tmp/seed.iso"
    cloud-localds "$seed_tmp" "$user_data" "$meta_data"
    "${SUDO[@]}" install -m 0644 "$seed_tmp" "$seed_dest"

    # ─── 4. virt-install --import ────────────────────────────────────
    log "defining + starting VM '$name' (${mem}MiB / ${vcpus}vCPU / ${disk_gib}G)"
    "${SUDO[@]}" virt-install \
        --connect "$LIBVIRT_URI" \
        --name "$name" \
        --memory "$mem" \
        --vcpus "$vcpus" \
        --osinfo "$os_variant" \
        --disk "path=$disk,format=qcow2,bus=virtio" \
        --disk "path=$seed_dest,device=cdrom" \
        --network "network=$NETWORK,model=virtio" \
        --import \
        --noautoconsole \
        --graphics none

    BOOTSTRAP_OK=1
    log "VM '$name' booted; cloud-init still running. Try '$SCRIPT_NAME ssh $name' in ~30s."
}

# ─── ssh ─────────────────────────────────────────────────────────────
cmd_ssh() {
    [[ $# -ge 1 ]] || err "ssh: need <name>"
    local name="$1"; shift

    vm_exists "$name" || err "VM '$name' doesn't exist"
    [[ "$(virsh_q domstate "$name" 2>/dev/null || true)" == "running" ]] \
        || err "VM '$name' is not running (try 'power on $name')"

    # Lease table first (works without qemu-guest-agent), then agent
    # (works for static IPs / non-libvirt-managed networks).
    local ip=""
    ip=$(virsh_q domifaddr "$name" 2>/dev/null \
            | awk '/ipv4/ {print $4}' | cut -d/ -f1 | head -n1) || true
    if [[ -z "$ip" ]]; then
        ip=$(virsh_q domifaddr "$name" --source agent 2>/dev/null \
                | awk '/ipv4/ {print $4}' | cut -d/ -f1 | head -n1) || true
    fi
    [[ -n "$ip" ]] \
        || err "no IP for '$name' yet (wait for DHCP, or install qemu-guest-agent in the guest)"

    local user
    user="$(real_user)"
    log "ssh $user@$ip $*"
    exec ssh "$user@$ip" "$@"
}

# ─── snapshot ────────────────────────────────────────────────────────
cmd_snapshot() {
    local sub="${1:-}"
    case "$sub" in
        create)
            shift
            [[ $# -ge 2 ]] || err "snapshot create: need <name> <snap>"
            virsh_q snapshot-create-as --domain "$1" --name "$2"
            ;;
        restore)
            shift
            [[ $# -ge 2 ]] || err "snapshot restore: need <name> <snap>"
            virsh_q snapshot-revert --domain "$1" --snapshotname "$2"
            ;;
        list)
            shift
            [[ $# -ge 1 ]] || err "snapshot list: need <name>"
            virsh_q snapshot-list --domain "$1"
            ;;
        ""|-h|--help) cmd_help ;;
        *) err "snapshot: unknown subcommand '$sub' (use create|restore|list)" ;;
    esac
}

# ─── clone ───────────────────────────────────────────────────────────
cmd_clone() {
    local sub="${1:-}"
    case "$sub" in
        create)
            shift
            [[ $# -ge 2 ]] || err "clone create: need <name> <new-name>"
            require_cmd virt-clone
            local src="$1" dst="$2"
            vm_exists "$src" || err "source VM '$src' doesn't exist"
            vm_exists "$dst" && err "target VM '$dst' already exists"
            "${SUDO[@]}" virt-clone --connect "$LIBVIRT_URI" \
                --original "$src" --name "$dst" --auto-clone
            ;;
        ""|-h|--help) cmd_help ;;
        *) err "clone: unknown subcommand '$sub' (use create)" ;;
    esac
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
        local ans
        read -r ans
        [[ "$ans" =~ ^[Yy]$ ]] || { log "aborted"; return 1; }
    fi

    # Capture pool/network references BEFORE undefine — domain XML and
    # volume metadata disappear after `undefine --remove-all-storage`.
    local pools_used=() nets_used=() line
    if (( prune == 1 )); then
        while IFS= read -r line; do
            [[ -n "$line" ]] && pools_used+=("$line")
        done < <(domain_pools_used "$name")
        while IFS= read -r line; do
            [[ -n "$line" ]] && nets_used+=("$line")
        done < <(domain_networks_used "$name")
    fi

    # Force-off if running/paused so undefine can proceed.
    local state
    state="$(virsh_q domstate "$name" 2>/dev/null || true)"
    case "$state" in
        running|paused|"in shutdown")
            log "destroying running VM '$name'"
            virsh_q destroy "$name" >/dev/null 2>&1 || true
            ;;
    esac

    # Internal qcow2 snapshots block undefine; clean them up first.
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
    # `--nvram` is required for UEFI domains (else undefine refuses) but
    # may be rejected on older libvirt for non-UEFI domains. Try with,
    # fall back without.
    virsh_q undefine "$name" "${extra[@]}" --nvram 2>/dev/null \
        || virsh_q undefine "$name" "${extra[@]}"

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
        log "nothing to prune"
        return 0
    fi

    log "candidates:"
    (( ${#empty_pools[@]} > 0 )) && log "  empty pools:    ${empty_pools[*]}"
    (( ${#unused_nets[@]} > 0 )) && log "  unused networks: ${unused_nets[*]}"

    if (( dry == 1 )); then
        return 0
    fi

    if (( force == 0 )); then
        printf '[%s] tear them all down? [y/N] ' "$SCRIPT_NAME" >&2
        local ans
        read -r ans
        [[ "$ans" =~ ^[Yy]$ ]] || { log "aborted"; return 1; }
    fi

    for p in "${empty_pools[@]}"; do maybe_prune_pool "$p"; done
    for n in "${unused_nets[@]}"; do maybe_prune_network "$n"; done
}

# ─── dispatch ────────────────────────────────────────────────────────
main() {
    if [[ $# -eq 0 ]]; then
        cmd_help
        return 0
    fi
    local cmd="$1"; shift
    case "$cmd" in
        help|-h|--help)  cmd_help ;;
        bootstrap)       cmd_bootstrap "$@" ;;
        ssh)             cmd_ssh "$@" ;;
        snapshot)        cmd_snapshot "$@" ;;
        clone)           cmd_clone "$@" ;;
        power)           cmd_power "$@" ;;
        delete|destroy)  cmd_delete "$@" ;;
        prune)           cmd_prune "$@" ;;
        *) err "unknown command '$cmd' — run '$SCRIPT_NAME help'" ;;
    esac
}

main "$@"
