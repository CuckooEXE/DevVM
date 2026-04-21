#!/usr/bin/env bash
# Install the Dracula color scheme into ~/.config/terminator/config.
#
# The dracula/terminator repo ships a snippet that belongs inside the
# [profiles] section of the Terminator config. We generate a minimal
# config that sets Dracula as the default profile and pairs it with the
# JetBrainsMono Nerd Font installed by the `fonts` section of setup.py.
#
# Idempotent: skips if the snippet is already present. We never touch an
# existing config that doesn't have our marker, to avoid clobbering the
# user's tweaks.
set -euo pipefail

USER="${USER:-$(id -un)}"
HOME="${HOME:-$(getent passwd "$USER" | cut -d: -f6)}"

if ! command -v terminator >/dev/null 2>&1; then
    echo "post/06-dracula-terminator: terminator not installed; skipping"
    exit 0
fi

CONFIG_DIR="$HOME/.config/terminator"
CONFIG="$CONFIG_DIR/config"
MARK='# >>> DevVMSetup dracula >>>'

if [[ -f "$CONFIG" ]] && grep -qF "$MARK" "$CONFIG"; then
    echo "post/06-dracula-terminator: Dracula profile already in $CONFIG"
    exit 0
fi

if [[ -f "$CONFIG" ]]; then
    echo "post/06-dracula-terminator: $CONFIG exists without our marker — leaving untouched"
    echo "  (to apply Dracula: delete $CONFIG and re-run this script)"
    exit 0
fi

mkdir -p "$CONFIG_DIR"

# Colors verbatim from https://github.com/dracula/terminator (MIT-licensed).
# The config format is terminator's own INI-like dialect — indentation
# with two spaces is significant.
cat > "$CONFIG" <<'EOF'
# >>> DevVMSetup dracula >>>
[global_config]
[keybindings]
[profiles]
  [[default]]
    background_color = "#282a36"
    background_darkness = 0.88
    background_type = transparent
    cursor_color = "#bbbbbb"
    font = JetBrainsMono Nerd Font 11
    foreground_color = "#f8f8f2"
    show_titlebar = False
    scrollback_infinite = True
    palette = "#000000:#ff5555:#50fa7b:#f1fa8c:#bd93f9:#ff79c6:#8be9fd:#bbbbbb:#555555:#ff5555:#50fa7b:#f1fa8c:#bd93f9:#ff79c6:#8be9fd:#ffffff"
    use_system_font = False
[layouts]
  [[default]]
    [[[child1]]]
      parent = window0
      type = Terminal
    [[[window0]]]
      parent = ""
      type = Window
[plugins]
# <<< DevVMSetup dracula <<<
EOF

echo "post/06-dracula-terminator: installed Dracula profile at $CONFIG"
