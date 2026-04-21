#!/usr/bin/env bash
# Bootstrap from a bare Debian Trixie install. Installs the minimum needed
# for setup.py to run, then hands off.
set -euo pipefail

REQUIRED_APT=(
    python3
    python3-yaml
    python3-jsonschema
    python3-pip         # pipx/pip_system prepare use pip to pre-download wheels
    ca-certificates
    curl
    gnupg
    git                 # git_sources prepare uses `git clone --mirror`
    # The prepare phase runs before apt.install, so anything prepare steps
    # invoke has to already be on PATH. neovim_offline's stage.sh in
    # particular wants unzip (Nerd Font zip, mason artifacts) and a full
    # C toolchain (nvim-treesitter compiles parsers with gcc+make).
    unzip
    gcc
    make
)

here() { cd "$(dirname "${BASH_SOURCE[0]}")" && pwd; }
HERE="$(here)"

if ! command -v sudo >/dev/null 2>&1; then
    echo "bootstrap: sudo is required" >&2
    exit 1
fi

missing=()
for pkg in "${REQUIRED_APT[@]}"; do
    if ! dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q 'install ok installed'; then
        missing+=("$pkg")
    fi
done

if ((${#missing[@]} > 0)); then
    echo "bootstrap: installing ${missing[*]}"
    sudo apt-get update
    sudo apt-get install -y --no-install-recommends "${missing[@]}"
fi

exec python3 "$HERE/setup.py" --root "$HERE" "$@"
