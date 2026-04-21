#!/usr/bin/env bash
# Install JetBrainsMono Nerd Font system-wide under /usr/share/fonts.
# Idempotent: skips download + extraction if the font is already present.
set -euo pipefail

USER="${USER:-$(id -un)}"
HOME="${HOME:-$(getent passwd "$USER" | cut -d: -f6)}"

FONT_DIR="/usr/share/fonts/truetype/jetbrains-mono-nerd"
FONT_URL="https://github.com/ryanoasis/nerd-fonts/releases/latest/download/JetBrainsMono.zip"
MARKER="$FONT_DIR/.devvmsetup-installed"

if [[ -f "$MARKER" ]]; then
    echo "post/05-fonts: JetBrainsMono Nerd Font already installed at $FONT_DIR"
    exit 0
fi

for tool in curl unzip fc-cache; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "post/05-fonts: required tool missing: $tool" >&2
        exit 1
    fi
done

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

echo "post/05-fonts: downloading JetBrainsMono Nerd Font"
curl -fL --retry 3 -o "$tmpdir/JetBrainsMono.zip" "$FONT_URL"

echo "post/05-fonts: extracting .ttf fonts to $FONT_DIR"
sudo install -d -m 0755 "$FONT_DIR"
unzip -oq "$tmpdir/JetBrainsMono.zip" '*.ttf' -d "$tmpdir/extracted"
# Drop the *Windows Compatible* variants; they're only useful on Windows and
# just double the font-cache size.
sudo install -m 0644 -D -t "$FONT_DIR" "$tmpdir"/extracted/*.ttf
sudo touch "$MARKER"

echo "post/05-fonts: rebuilding font cache"
sudo fc-cache -f "$FONT_DIR"

echo "post/05-fonts: done"
