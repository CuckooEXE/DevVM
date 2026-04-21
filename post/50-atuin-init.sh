#!/usr/bin/env bash
# Wire atuin into zsh + bash shells, idempotently.
# Assumes the atuin binary has already been installed by the github_releases section.
set -euo pipefail

USER="${USER:-$(id -un)}"
HOME="${HOME:-$(getent passwd "$USER" | cut -d: -f6)}"

if ! command -v atuin >/dev/null 2>&1; then
    echo "post/50-atuin-init: atuin binary not on PATH; skipping" >&2
    exit 0
fi

ZSHRC="$HOME/.zshrc"
BASHRC="$HOME/.bashrc"
MARK='# >>> DevVMSetup atuin >>>'

append_init() {
    local rcfile="$1" shell_name="$2"
    [[ -f "$rcfile" ]] || touch "$rcfile"
    if grep -qF "$MARK" "$rcfile"; then
        echo "post/50-atuin-init: $rcfile already has atuin init"
        return
    fi
    cat >> "$rcfile" <<EOF

$MARK
eval "\$(atuin init $shell_name)"
# <<< DevVMSetup atuin <<<
EOF
    echo "post/50-atuin-init: added atuin init to $rcfile"
}

append_init "$ZSHRC" zsh
append_init "$BASHRC" bash
