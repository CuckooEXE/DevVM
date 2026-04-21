#!/usr/bin/env bash
# Add invoking user to the wireshark group so they can capture without sudo.
# Requires the debconf answer "wireshark-common/install-setuid = true", which
# installers/apt.py pre-seeds automatically.
set -euo pipefail

USER="${USER:-$(id -un)}"

if ! getent group wireshark >/dev/null; then
    echo "post/35-wireshark-group: wireshark group missing (wireshark not installed?)"
    exit 0
fi

if id -nG "$USER" | tr ' ' '\n' | grep -qx wireshark; then
    echo "post/35-wireshark-group: $USER already in wireshark group"
else
    echo "post/35-wireshark-group: adding $USER to wireshark group"
    sudo usermod -aG wireshark "$USER"
    echo "(log out/in or run 'newgrp wireshark' for this to take effect)"
fi
