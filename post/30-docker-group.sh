#!/usr/bin/env bash
# Add invoking user to docker group so `docker` works without sudo (idempotent).
set -euo pipefail

USER="${USER:-$(id -un)}"

if ! getent group docker >/dev/null; then
    echo "post/30-docker-group: docker group missing (docker not installed?)"
    exit 0
fi

if id -nG "$USER" | tr ' ' '\n' | grep -qx docker; then
    echo "post/30-docker-group: $USER already in docker group"
else
    echo "post/30-docker-group: adding $USER to docker group"
    sudo usermod -aG docker "$USER"
    echo "(log out/in or run 'newgrp docker' for this to take effect)"
fi
