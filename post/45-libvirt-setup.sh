#!/usr/bin/env bash
# Add invoking user to the libvirt group + autostart the default NAT
# network and storage pool. All steps idempotent. Pairs with the
# bin/vm-manager.sh tool installed by post/55-vm-manager-install.sh.
set -euo pipefail

USER="${USER:-$(id -un)}"

if ! getent group libvirt >/dev/null; then
    echo "post/45-libvirt-setup: libvirt group missing (libvirt-daemon-system not installed?)"
    exit 0
fi

if id -nG "$USER" | tr ' ' '\n' | grep -qx libvirt; then
    echo "post/45-libvirt-setup: $USER already in libvirt group"
else
    echo "post/45-libvirt-setup: adding $USER to libvirt group"
    sudo usermod -aG libvirt "$USER"
    echo "(log out/in or run 'newgrp libvirt' for libvirt group to take effect)"
fi

# Default NAT network — defined by libvirt-daemon-system but inactive
# out of the box. Mark it autostart and start it now so vm-manager's
# `bootstrap` works on first run.
if sudo virsh net-info default >/dev/null 2>&1; then
    sudo virsh net-autostart default >/dev/null 2>&1 || true
    if [[ "$(sudo virsh net-info default | awk '/^Active:/ {print $2}')" != "yes" ]]; then
        echo "post/45-libvirt-setup: starting default network"
        sudo virsh net-start default >/dev/null 2>&1 || true
    fi
fi

# Default storage pool — same story: defined, but not always active.
if sudo virsh pool-info default >/dev/null 2>&1; then
    sudo virsh pool-autostart default >/dev/null 2>&1 || true
    if [[ "$(sudo virsh pool-info default | awk '/^State:/ {print $2}')" != "running" ]]; then
        echo "post/45-libvirt-setup: starting default pool"
        sudo virsh pool-start default >/dev/null 2>&1 || true
    fi
fi
