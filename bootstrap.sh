#!/usr/bin/env bash
# Bootstrap — handle the host-level apt prereqs that setup.py can't install
# itself (it's written in Python + PyYAML + jsonschema, which have to exist
# before it can run at all).
#
# Split into prepare / install so a prepare run on a connected machine can
# produce a shareable cache/bootstrap/debs/ directory that coworkers pick
# up for an offline install.
#
# Usage:
#   ./bootstrap.sh                 # default: full (prepare + install)
#   ./bootstrap.sh prepare         # download .debs into cache/bootstrap/debs/
#   ./bootstrap.sh install         # install from that cache (or from apt if empty)
#   ./bootstrap.sh full            # prepare + install
#
# After bootstrap finishes, run setup.py yourself:
#   python3 setup.py --mode full
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CACHE_DEBS="$HERE/cache/bootstrap/debs"

REQUIRED_APT=(
    # Python runtime + libs setup.py imports
    python3
    python3-yaml
    python3-jsonschema
    python3-pip         # pipx/pip_system prepare use pip to pre-download wheels
    # TLS / signing / network
    ca-certificates
    curl
    gnupg
    # git_sources prepare uses `git clone --mirror`
    git
    # neovim_offline prepare runs stage.sh which wants these before apt's
    # install phase has run:
    unzip
    gcc
    make
)

command -v sudo >/dev/null 2>&1 || {
    echo "bootstrap: sudo is required" >&2
    exit 1
}

MODE="${1:-full}"
case "$MODE" in
    prepare|install|full) ;;
    -h|--help)
        sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'
        exit 0
        ;;
    *)
        echo "bootstrap: unknown mode '$MODE' (try: prepare, install, full)" >&2
        exit 2
        ;;
esac

# ---------------------------------------------------------------------------
do_prepare() {
    echo "bootstrap: prepare — caching apt prereqs under $CACHE_DEBS"
    sudo install -d -m 0755 "$CACHE_DEBS" "$CACHE_DEBS/partial"

    echo "bootstrap: apt-get update (required so --download-only can resolve)"
    sudo env DEBIAN_FRONTEND=noninteractive apt-get update

    # Download the .debs + their full transitive dep closure into our
    # cache dir:
    #   --download-only         don't unpack
    #   --reinstall             force include pkgs already installed on this
    #                           host so the cache is portable to a fresh one
    #   --no-install-recommends match the install-time behavior
    #   Dir::Cache::Archives    private download dir for this invocation;
    #                           keeps /var/cache/apt/archives clean
    echo "bootstrap: downloading ${#REQUIRED_APT[@]} pkgs (+deps) to cache"
    sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y \
        --download-only --reinstall --no-install-recommends \
        -o "Dir::Cache::Archives=$CACHE_DEBS" \
        "${REQUIRED_APT[@]}"

    # apt owns the files now; make them readable so coworkers who receive
    # the cache dir as a non-root user can still rsync/copy it around.
    sudo chmod -R a+rX "$CACHE_DEBS"
    local count
    count="$(find "$CACHE_DEBS" -maxdepth 1 -name '*.deb' | wc -l)"
    echo "bootstrap: cached $count .deb files"
}

# ---------------------------------------------------------------------------
do_install() {
    local missing=()
    for pkg in "${REQUIRED_APT[@]}"; do
        if ! dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null \
             | grep -q 'install ok installed'; then
            missing+=("$pkg")
        fi
    done

    if ((${#missing[@]} == 0)); then
        echo "bootstrap: all required packages already installed"
        return 0
    fi
    echo "bootstrap: missing packages: ${missing[*]}"

    # Cached debs? Install offline. Otherwise fall back to apt (needs net).
    if compgen -G "$CACHE_DEBS"/*.deb >/dev/null; then
        echo "bootstrap: installing from cached .debs at $CACHE_DEBS"
        # `dpkg -i` doesn't resolve deps, but feeding it every cached .deb
        # in one invocation lets it order them itself. Any stragglers get
        # resolved by `apt-get install -f` with the same archive cache
        # pointed at our local dir, so it can do that without network.
        sudo dpkg -i "$CACHE_DEBS"/*.deb || true
        sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y -f \
            --no-download \
            -o "Dir::Cache::Archives=$CACHE_DEBS"
    else
        echo "bootstrap: cache empty — installing via apt (needs network)"
        sudo env DEBIAN_FRONTEND=noninteractive apt-get update
        sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y \
            --no-install-recommends "${missing[@]}"
    fi
}

# ---------------------------------------------------------------------------
case "$MODE" in
    prepare) do_prepare ;;
    install) do_install ;;
    full)    do_prepare; do_install ;;
esac

cat <<HINT

bootstrap: done.

Next step — run setup.py yourself (not exec'd by bootstrap any more):
    python3 $HERE/setup.py --mode full

    # or match bootstrap's mode:
    python3 $HERE/setup.py --mode prepare    # download everything into ./cache/
    python3 $HERE/setup.py --mode install    # install from ./cache/
HINT
