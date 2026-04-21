#!/usr/bin/env bash
# install.sh — Deploy or remove the LazyVim offline bundle.
#
# Usage:   ./install.sh               # install (default)
#          ./install.sh install       # install (explicit)
#          ./install.sh uninstall     # remove everything install.sh put in place
#          ./install.sh <cmd> --dry   # preview file operations, do nothing
#          ./install.sh <cmd> --force # skip confirmation prompts

set -euo pipefail

BUNDLE="$(cd "$(dirname "$0")" && pwd)"
DRY=0
FORCE=0
ACTION="install"

for arg in "$@"; do
  case "$arg" in
    install|uninstall) ACTION="$arg" ;;
    --dry|-n) DRY=1 ;;
    --force|-f) FORCE=1 ;;
    -h|--help) grep '^#' "$0" | head -20; exit 0 ;;
    *) echo "unknown arg: $arg" >&2; exit 2 ;;
  esac
done

NVIM_VERSION="v0.12.1"
NODE_VERSION="v22.11.0"

log()  { printf '\033[1;34m[%s]\033[0m %s\n' "$ACTION" "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[fail]\033[0m %s\n' "$*" >&2; exit 1; }
run()  {
  if (( DRY )); then
    printf '  dry-run: %s\n' "$*"
  else
    "$@"
  fi
}

# --- Sanity checks ---------------------------------------------------------
[[ "$(uname -s)" == "Linux" ]] || die "This bundle is Linux-only."
[[ "$(uname -m)" == "x86_64" ]] || die "This bundle targets x86_64."
if [[ "$ACTION" == "install" ]]; then
  for tool in tar unzip curl fc-cache; do
    command -v "$tool" >/dev/null || die "Missing required tool: $tool"
  done
fi

# --- Target paths (shared by install / uninstall) --------------------------
CFG="$HOME/.config/nvim"
DATA="$HOME/.local/share/nvim"
LOCAL_BIN="$HOME/.local/bin"
NVIM_ROOT="$HOME/.local/share/nvim-runtime"
NODE_ROOT="$HOME/.local/share/node"
JDK_ROOT="$HOME/.local/share/jdk-21"
FONT_DIR="$HOME/.local/share/fonts/JetBrainsMono"

# ===========================================================================
# install
# ===========================================================================
do_install() {
  log "Target paths:"
  log "  config:     $CFG"
  log "  data:       $DATA"
  log "  nvim:       $NVIM_ROOT  (symlink -> $LOCAL_BIN/nvim)"
  log "  node:       $NODE_ROOT"
  log "  jdk-21:     $JDK_ROOT"
  log "  fonts:      $FONT_DIR"

  # --- Existing config guard -----------------------------------------------
  if [[ -e "$CFG" ]]; then
    if (( FORCE )); then
      warn "Removing existing $CFG (--force)"
      run rm -rf "$CFG"
    else
      warn "Existing $CFG detected."
      read -r -p "  Back it up to ${CFG}.backup.$$ and proceed? [y/N] " ans
      case "$ans" in
        y|Y|yes) run mv "$CFG" "${CFG}.backup.$$" ;;
        *) die "Aborted. Re-run with --force to overwrite." ;;
      esac
    fi
  fi

  # --- 1. Neovim -----------------------------------------------------------
  log "Installing Neovim $NVIM_VERSION -> $NVIM_ROOT"
  run mkdir -p "$NVIM_ROOT" "$LOCAL_BIN"
  run tar --strip-components=1 -xzf "$BUNDLE/bin/nvim-linux-x86_64.tar.gz" -C "$NVIM_ROOT"
  run ln -sfn "$NVIM_ROOT/bin/nvim" "$LOCAL_BIN/nvim"

  # --- 2. Node.js ----------------------------------------------------------
  log "Installing Node.js $NODE_VERSION -> $NODE_ROOT"
  run mkdir -p "$NODE_ROOT"
  run tar --strip-components=1 -xJf "$BUNDLE/bin/node-${NODE_VERSION}-linux-x64.tar.xz" -C "$NODE_ROOT"
  for bin in node npm npx; do
    run ln -sfn "$NODE_ROOT/bin/$bin" "$LOCAL_BIN/$bin"
  done

  # --- 3. JDK --------------------------------------------------------------
  log "Installing Temurin JDK 21 -> $JDK_ROOT"
  run mkdir -p "$JDK_ROOT"
  local jdk_archive
  jdk_archive=$(ls "$BUNDLE/jdk/"OpenJDK21*.tar.gz 2>/dev/null | head -1)
  [[ -n "$jdk_archive" ]] || die "No JDK archive found in $BUNDLE/jdk/"
  run tar --strip-components=1 -xzf "$jdk_archive" -C "$JDK_ROOT"

  # --- 4. Config -----------------------------------------------------------
  log "Copying LazyVim config -> $CFG"
  run mkdir -p "$(dirname "$CFG")"
  run cp -a "$BUNDLE/config/nvim" "$CFG"

  # --- 5. Plugins, Mason data, treesitter parsers --------------------------
  log "Copying plugins + mason + site (treesitter) -> $DATA"
  run mkdir -p "$DATA"
  # Preserve anything the user already has (undo/shada) but replace the
  # subtrees we own.
  run rm -rf "$DATA/lazy" "$DATA/mason" "$DATA/site"
  run cp -a "$BUNDLE/share/nvim/lazy"  "$DATA/lazy"
  run cp -a "$BUNDLE/share/nvim/mason" "$DATA/mason"
  if [[ -d "$BUNDLE/share/nvim/site" ]]; then
    run cp -a "$BUNDLE/share/nvim/site" "$DATA/site"
  else
    warn "No site/ in bundle — treesitter parsers will be absent."
  fi

  # --- 6. Fonts ------------------------------------------------------------
  log "Installing JetBrainsMono Nerd Font"
  run mkdir -p "$FONT_DIR"
  run unzip -oq "$BUNDLE/fonts/JetBrainsMono.zip" -d "$FONT_DIR"
  run fc-cache -f "$FONT_DIR"

  # --- 7. Shell rc ---------------------------------------------------------
  add_rc() {
    local rc="$1"
    [[ -f "$rc" ]] || return 0
    if ! grep -q 'NeovimOffline bundle' "$rc" 2>/dev/null; then
      log "Appending PATH + JAVA_HOME exports to $rc"
      if (( ! DRY )); then
        cat >> "$rc" <<EOF

# --- NeovimOffline bundle -----------------------------------------------
export PATH="\$HOME/.local/bin:\$PATH"
export JAVA_HOME="$JDK_ROOT"
export PATH="\$JAVA_HOME/bin:\$PATH"
# -----------------------------------------------------------------------
EOF
      fi
    else
      log "$rc already has bundle markers; skipping."
    fi
  }
  add_rc "$HOME/.bashrc"
  add_rc "$HOME/.zshrc"

  # --- 8. Done -------------------------------------------------------------
  cat <<'DONE'

─── Done ──────────────────────────────────────────────────────────────────

Open a new shell (or `source ~/.bashrc` / `source ~/.zshrc`) and run:

    nvim test.c

First launch will be quick — no plugins to download, no LSPs to install.

VSCode → Neovim cheat sheet:

    gd         goto definition           (was: Ctrl+click)
    gr         goto references
    K          hover docstring           (was: hover panel)
    <leader>ca code action / quick fix   (was: Ctrl+. )
    <leader>cr rename symbol             (was: F2)
    <leader>cf format file               (was: Shift+Alt+F)
    <leader>e  file explorer             (was: sidebar)
    <leader>ff find files                (was: Ctrl+P)
    <leader>/  search in files           (was: Ctrl+Shift+F)
    <F5>       debug continue
    <F9>       toggle breakpoint
    <F10>      step over
    <F11>      step into
    Ctrl-Space autocomplete menu         (insert mode)
    <leader>   = Space.  <Esc> or jk (insert) to leave insert mode.

To see every LazyVim keymap: `<leader>` then wait — WhichKey shows menus.

DONE
}

# ===========================================================================
# uninstall
# ===========================================================================
do_uninstall() {
  local targets=()
  [[ -e "$CFG"       ]] && targets+=("$CFG")
  [[ -e "$NVIM_ROOT" ]] && targets+=("$NVIM_ROOT")
  [[ -e "$NODE_ROOT" ]] && targets+=("$NODE_ROOT")
  [[ -e "$JDK_ROOT"  ]] && targets+=("$JDK_ROOT")
  [[ -e "$FONT_DIR"  ]] && targets+=("$FONT_DIR")
  for sub in lazy mason site; do
    [[ -e "$DATA/$sub" ]] && targets+=("$DATA/$sub")
  done

  local rc_dirty=0
  for rc in "$HOME/.bashrc" "$HOME/.zshrc"; do
    [[ -f "$rc" ]] || continue
    grep -q 'NeovimOffline bundle' "$rc" && rc_dirty=1
  done

  if (( ${#targets[@]} == 0 && rc_dirty == 0 )); then
    log "Nothing installed — nothing to remove."
    return 0
  fi

  warn "The following will be removed:"
  for t in "${targets[@]}"; do
    printf '  %s\n' "$t"
  done
  (( rc_dirty )) && warn "Plus: NeovimOffline block in ~/.bashrc / ~/.zshrc"
  warn "Plus: nvim/node/npm/npx symlinks in $LOCAL_BIN (only if they point into the bundle)"

  if (( ! FORCE )); then
    read -r -p "Proceed? [y/N] " ans
    case "$ans" in
      y|Y|yes) ;;
      *) die "Aborted." ;;
    esac
  fi

  # Symlinks first, so we can resolve their targets before the trees go away.
  for bin in nvim node npm npx; do
    local link="$LOCAL_BIN/$bin"
    [[ -L "$link" ]] || continue
    local target
    target="$(readlink "$link" 2>/dev/null || true)"
    case "$target" in
      "$NVIM_ROOT"/*|"$NODE_ROOT"/*)
        log "rm $link"
        run rm -f "$link"
        ;;
    esac
  done

  for t in "${targets[@]}"; do
    log "rm -rf $t"
    run rm -rf "$t"
  done

  # Strip shell rc block between the markers that install.sh writes.
  for rc in "$HOME/.bashrc" "$HOME/.zshrc"; do
    [[ -f "$rc" ]] || continue
    grep -q 'NeovimOffline bundle' "$rc" || continue
    log "Stripping NeovimOffline block from $rc (backup: ${rc}.nvim-offline-bak)"
    if (( ! DRY )); then
      sed -i.nvim-offline-bak '/^# --- NeovimOffline bundle/,/^# ---------*$/d' "$rc"
    fi
  done

  if command -v fc-cache >/dev/null; then
    log "Refreshing font cache"
    run fc-cache -f || true
  fi

  log "Uninstall complete. Open a new shell to drop the removed PATH/JAVA_HOME exports."
}

case "$ACTION" in
  install)   do_install ;;
  uninstall) do_uninstall ;;
esac
