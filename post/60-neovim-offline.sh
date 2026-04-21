#!/usr/bin/env bash
# Install the bundled NeovimOffline package (LazyVim + plugins + LSPs) into
# the invoking user's HOME. Requires the bundle to be staged first (run
# `./NeovimOffline/stage.sh` on a connected machine before copying the VM).
set -euo pipefail

USER="${USER:-$(id -un)}"
HOME="${HOME:-$(getent passwd "$USER" | cut -d: -f6)}"

BUNDLE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/NeovimOffline"

if [[ ! -d "$BUNDLE" ]]; then
    echo "post/60-neovim-offline: $BUNDLE missing; skipping"
    exit 0
fi

if [[ ! -f "$BUNDLE/install.sh" ]]; then
    echo "post/60-neovim-offline: $BUNDLE/install.sh missing; skipping"
    exit 0
fi

# install.sh needs these (see its Sanity checks block).
for tool in tar unzip curl fc-cache; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "post/60-neovim-offline: $tool missing on PATH — skipping"
        echo "(add fontconfig to apt.packages for fc-cache)"
        exit 0
    fi
done

# Bundle must be staged. Empty or missing plugin/mason trees mean `stage.sh`
# was never run — offline install would fail or leave the user with an
# empty LazyVim. Bail out cleanly with a pointer instead.
if [[ ! -d "$BUNDLE/share/nvim/lazy" ]] || [[ -z "$(ls -A "$BUNDLE/share/nvim/lazy" 2>/dev/null || true)" ]]; then
    echo "post/60-neovim-offline: bundle not staged (empty share/nvim/lazy)"
    echo "  Run ./NeovimOffline/stage.sh on a connected machine first."
    exit 0
fi

# Idempotency: `nvim-runtime` dir exists ⇒ install.sh already ran successfully.
if [[ -d "$HOME/.local/share/nvim-runtime" ]] && [[ -d "$HOME/.config/nvim" ]]; then
    echo "post/60-neovim-offline: already installed ($HOME/.config/nvim, $HOME/.local/share/nvim-runtime). Skipping."
    echo "  (To re-run: delete those dirs or run NeovimOffline/install.sh --force manually.)"
    exit 0
fi

echo "post/60-neovim-offline: running $BUNDLE/install.sh --force"
cd "$BUNDLE" && ./install.sh --force
