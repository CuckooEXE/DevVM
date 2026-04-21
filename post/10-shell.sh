#!/usr/bin/env bash
# Make zsh the default shell and wire up common plugins (idempotent).
set -euo pipefail

# $USER/$HOME aren't guaranteed to be set when called via subprocess (normally
# populated by login/PAM). Fall back to id -un / getent.
USER="${USER:-$(id -un)}"
HOME="${HOME:-$(getent passwd "$USER" | cut -d: -f6)}"

if ! command -v zsh >/dev/null 2>&1; then
    echo "post/10-shell: zsh not installed, skipping" >&2
    exit 0
fi

current_shell="$(getent passwd "$USER" | cut -d: -f7)"
zsh_path="$(command -v zsh)"

if [[ "$current_shell" != "$zsh_path" ]]; then
    echo "post/10-shell: changing shell for $USER to $zsh_path"
    sudo chsh -s "$zsh_path" "$USER"
else
    echo "post/10-shell: shell already $zsh_path"
fi

ZSHRC="$HOME/.zshrc"
touch "$ZSHRC"

# zsh-autosuggestions (Debian package installs to this path)
AUTOSUG="/usr/share/zsh-autosuggestions/zsh-autosuggestions.zsh"
if [[ -f "$AUTOSUG" ]]; then
    MARK='# >>> DevVMSetup zsh-autosuggestions >>>'
    if ! grep -qF "$MARK" "$ZSHRC"; then
        cat >> "$ZSHRC" <<EOF

$MARK
source $AUTOSUG
# <<< DevVMSetup zsh-autosuggestions <<<
EOF
        echo "post/10-shell: enabled zsh-autosuggestions in $ZSHRC"
    fi
fi
