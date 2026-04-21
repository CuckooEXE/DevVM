#!/usr/bin/env bash
# test2.sh — run the provisioner against a config inside a debian:trixie
# container, then drop into an interactive shell as the provisioned user
# so you can poke around by hand.
#
# Usage:
#   ./test/test2.sh                               # uses test/vmconfig.test.yaml
#   ./test/test2.sh test/vmconfig.test.yaml       # explicit
#   ./test/test2.sh vmconfig.yaml                 # full production config (slow + large)
#
# Notes:
#   - The image (devvmsetup-test) is built with USER tester, so the container
#     runs as tester and there's no `su` (and therefore no password prompt).
#   - /var/run/docker.sock is mounted so the `docker` installer can pull
#     images against the host's daemon (pulled images persist on the host).
#   - `--group-add <sock-gid>` gives tester permission on the mounted socket.
#   - Container runs with --rm; exit the shell to tear it down. While it's
#     up, you can attach from another terminal via:
#       docker exec -it devvmsetup-inspect bash
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
ROOT="$PWD"

CONFIG_REL="${1:-test/vmconfig.test.yaml}"
[[ -f "$ROOT/$CONFIG_REL" ]]       || { echo "config not found: $ROOT/$CONFIG_REL" >&2; exit 1; }
[[ -f "$ROOT/test/Dockerfile" ]]   || { echo "test/Dockerfile missing" >&2; exit 1; }
command -v docker >/dev/null       || { echo "docker CLI not on PATH" >&2; exit 1; }

echo "==> building devvmsetup-test image (cached after first run)"
docker build -q -t devvmsetup-test test/ >/dev/null

echo "==> DevVMSetup inspect container"
echo "    config:      $CONFIG_REL"
echo "    docker.sock: /var/run/docker.sock (entrypoint wires tester into host-docker group)"
echo "    name:        devvmsetup-inspect (attach from another terminal: docker exec -it devvmsetup-inspect bash)"
echo

docker run --rm -it \
    --name devvmsetup-inspect \
    -v "$ROOT:/src:ro" \
    -v /var/run/docker.sock:/var/run/docker.sock \
    -e CONFIG_REL="$CONFIG_REL" \
    devvmsetup-test \
    bash -c '
set -eu

echo "==> running bootstrap.sh --mode full --config $CONFIG_REL"
set +e
cd "$HOME/DevVMSetup" && ./bootstrap.sh --mode full --config "$CONFIG_REL"
BOOT_RC=$?
set -e

echo
echo "==================================================================="
if (( BOOT_RC == 0 )); then
    echo "  Provisioning SUCCEEDED (exit 0)."
else
    echo "  !! Provisioning FAILED (exit $BOOT_RC) — dropping to shell anyway."
fi
echo "  Try:"
echo "    jq --version           # apt"
echo "    ruff --version         # pipx (via ~/.local/bin)"
echo "    hyperfine --version    # github_releases"
echo "    zig version            # tarballs"
echo "    rustc --version        # rustup (via ~/.cargo/bin)"
echo "    docker image ls        # docker (mounted host socket)"
echo "    ls ~/test-clone-gtfobins   # git_sources"
echo "    cat ~/DevVMSetup/vmconfig.lock    # pinned versions"
echo "  Exit the shell to tear down the container."
echo "==================================================================="
exec bash -l
'
