#!/usr/bin/env bash
# Install Oh My Zsh system-wide under /usr/local/share/oh-my-zsh, then point
# the invoking user's ~/.zshrc at it with ZSH_THEME="agnoster".
#
# Running "system-wide" here means:
#   - the repo lives in /usr/local/share/oh-my-zsh (one copy, all users)
#   - each user gets their own $ZSH_CUSTOM at ~/.oh-my-zsh-custom so
#     plugin/theme drop-ins don't need root
#
# Idempotent: re-running updates nothing if the repo is present and the
# .zshrc already has the OMZ block.
set -euo pipefail

USER="${USER:-$(id -un)}"
HOME="${HOME:-$(getent passwd "$USER" | cut -d: -f6)}"

if ! command -v zsh >/dev/null 2>&1; then
    echo "post/15-oh-my-zsh: zsh not installed; skipping"
    exit 0
fi

OMZ_DIR="/usr/local/share/oh-my-zsh"
OMZ_REPO="https://github.com/ohmyzsh/ohmyzsh.git"

if [[ ! -d "$OMZ_DIR/.git" ]]; then
    echo "post/15-oh-my-zsh: cloning Oh My Zsh to $OMZ_DIR"
    sudo git clone --depth 1 "$OMZ_REPO" "$OMZ_DIR"
    sudo chmod -R a+rX "$OMZ_DIR"
else
    echo "post/15-oh-my-zsh: Oh My Zsh already at $OMZ_DIR"
fi

ZSHRC="$HOME/.zshrc"
touch "$ZSHRC"
MARK='# >>> DevVMSetup oh-my-zsh >>>'

if grep -qF "$MARK" "$ZSHRC"; then
    echo "post/15-oh-my-zsh: $ZSHRC already sources oh-my-zsh"
    exit 0
fi

# Prepend (not append): OMZ's sourcing sets the prompt and exports
# variables that later blocks (atuin, zsh-autosuggestions) might want to
# layer on top of. Keeping OMZ first is the conventional order.
tmp="$(mktemp)"
cat > "$tmp" <<EOF
$MARK
export ZSH="$OMZ_DIR"
export ZSH_CUSTOM="\$HOME/.oh-my-zsh-custom"
ZSH_THEME="agnoster"
plugins=(git)
# Don't let OMZ check for its own updates — the repo is managed by the
# provisioner and lives in a system path the user can't write to.
DISABLE_AUTO_UPDATE=true
DISABLE_UPDATE_PROMPT=true
mkdir -p "\$ZSH_CUSTOM"
source "\$ZSH/oh-my-zsh.sh"
# <<< DevVMSetup oh-my-zsh <<<

EOF
cat "$ZSHRC" >> "$tmp"
mv "$tmp" "$ZSHRC"

mkdir -p "$HOME/.oh-my-zsh-custom"
echo "post/15-oh-my-zsh: wired Oh My Zsh (theme=agnoster) into $ZSHRC"
