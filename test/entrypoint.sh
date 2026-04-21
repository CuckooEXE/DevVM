#!/usr/bin/env bash
# Runtime container prep for the devvmsetup-test image. Runs as `tester`
# (USER tester in Dockerfile); tester has passwordless sudo.
#
# If a host Docker socket is bind-mounted at /var/run/docker.sock, this
# entrypoint transparently wires `tester` into a group matching the
# socket's GID so `docker` works without sudo — even when the caller
# forgot to pass `--group-add`. Skipped when the socket isn't mounted
# or tester is already in the right group.
set -eu

# --- docker.sock group match ------------------------------------------------
#
# This block runs only on the first invocation of the entrypoint. We create
# a matching group (if needed), add tester to it, then re-exec ourselves
# via `sudo -u tester` so the new process inherits the updated supplementary
# groups. `ENTRYPOINT_REGROUPED=1` prevents an infinite loop.
if [[ -z "${ENTRYPOINT_REGROUPED:-}" && -S /var/run/docker.sock ]]; then
    sock_gid="$(stat -c '%g' /var/run/docker.sock)"
    if [[ "$sock_gid" != "0" ]] && ! id -G | tr ' ' '\n' | grep -qx "$sock_gid"; then
        if ! getent group "$sock_gid" >/dev/null 2>&1; then
            sudo groupadd -g "$sock_gid" hostdocker
        fi
        gname="$(getent group "$sock_gid" | cut -d: -f1)"
        sudo usermod -aG "$gname" tester
        # Re-exec via sudo so the new group membership takes effect. sudo
        # forks a fresh process which re-reads /etc/group, pulling in the
        # group we just added.
        export ENTRYPOINT_REGROUPED=1
        exec sudo --preserve-env=ENTRYPOINT_REGROUPED -u tester -- "$0" "$@"
    fi
fi

# --- /src bind-mount copy ---------------------------------------------------
if [[ -d /src && ! -d /home/tester/DevVMSetup ]]; then
    sudo cp -r /src /home/tester/DevVMSetup
    sudo chown -R tester:tester /home/tester/DevVMSetup
fi

cd /home/tester

# Default: interactive login shell as tester (no `su`, so no password prompt).
if (( $# == 0 )); then
    exec bash -l
fi
exec "$@"
