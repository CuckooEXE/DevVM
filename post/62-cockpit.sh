#!/usr/bin/env bash
# Enable Cockpit's socket-activated web console on https://<host>:9090.
#
# The `cockpit` apt package installs the service but leaves cockpit.socket
# disabled. This flips it on (and starts it now if systemd is running).
# Idempotent; degrades gracefully in containers / chroots without systemd.
set -euo pipefail

if ! command -v systemctl >/dev/null 2>&1; then
    echo "post/62-cockpit: systemctl not present; skipping" >&2
    exit 0
fi

# No systemd as PID 1 (build container, chroot) -> can't manage units.
if ! systemctl is-system-running >/dev/null 2>&1 \
     && [ ! -d /run/systemd/system ]; then
    echo "post/62-cockpit: systemd not running; enable cockpit.socket manually" >&2
    exit 0
fi

if ! systemctl list-unit-files cockpit.socket >/dev/null 2>&1; then
    echo "post/62-cockpit: cockpit.socket not found; is the cockpit package installed?" >&2
    exit 0
fi

sudo systemctl enable --now cockpit.socket
echo "post/62-cockpit: cockpit listening on https://<host>:9090"
