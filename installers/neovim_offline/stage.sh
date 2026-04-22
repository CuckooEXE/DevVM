#!/usr/bin/env bash
# stage.sh — Build the offline LazyVim bundle on this (connected) machine.
#
# Usage:   ./stage.sh           # full run
#          ./stage.sh fetch     # download tarballs only
#          ./stage.sh plugins   # bootstrap plugins (assumes fetch done)
#          ./stage.sh mason     # install mason packages (assumes plugins done)
#          ./stage.sh ts        # compile treesitter parsers
#          ./stage.sh copy      # copy staged results into the bundle
#          ./stage.sh clean     # remove build artifacts (.stage, .downloads,
#                                 share/nvim/{lazy,mason,site}). Tarballs in
#                                 bin/, jdk/ are kept — delete those manually
#                                 to force a re-fetch.
#
# Running with no argument does all steps in order. Each step is idempotent;
# re-running skips work already completed.
#
# Layout:
#   SOURCE_DIR  = installers/neovim_offline/   (tracked — scripts + config/nvim)
#   BUNDLE_DIR  = cache/neovim_offline/        (artifacts — bin/, jdk/, share/)
#
# Override BUNDLE_DIR with the env var of the same name to stage somewhere
# other than the repo's cache (e.g. to a portable directory for offline
# transport).

set -euo pipefail

SOURCE_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG_DIR="$SOURCE_DIR/config"

# Resolve BUNDLE_DIR. Priority:
#   1. explicit env var  (set by installers/neovim_offline/__init__.py)
#   2. $repo_root/cache/neovim_offline if we can find a repo root
#   3. fall back to SOURCE_DIR for standalone/air-gap bundles
if [[ -z "${BUNDLE_DIR:-}" ]]; then
  candidate="$SOURCE_DIR"
  while [[ "$candidate" != "/" ]]; do
    if [[ -f "$candidate/setup.py" && -f "$candidate/vmconfig.yaml" ]]; then
      BUNDLE_DIR="$candidate/cache/neovim_offline"
      break
    fi
    candidate="$(cd "$candidate/.." && pwd)"
  done
  BUNDLE_DIR="${BUNDLE_DIR:-$SOURCE_DIR}"
fi
mkdir -p "$BUNDLE_DIR"

STAGE="$BUNDLE_DIR/.stage"        # scratch dir for XDG_{CONFIG,DATA}_HOME
STAGE_CFG="$STAGE/config"
STAGE_DATA="$STAGE/data"
STAGE_STATE="$STAGE/state"
STAGE_CACHE="$STAGE/cache"
DL="$BUNDLE_DIR/.downloads"        # cache downloads so re-runs don't re-fetch

# Pinned versions — edit these to update the bundle.
NVIM_VERSION="v0.12.1"
NODE_VERSION="v22.11.0"
JDK_VERSION="21.0.5+11"
JDK_FILE="OpenJDK21U-jdk_x64_linux_hotspot_21.0.5_11.tar.gz"
TS_CLI_VERSION="v0.26.8"   # Only needed on the staging machine to compile parsers.

log()  { printf '\033[1;34m[stage]\033[0m %s\n' "$*" >&2; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[fail]\033[0m %s\n' "$*" >&2; exit 1; }

mkdir -p "$DL" "$STAGE_CFG" "$STAGE_DATA" "$STAGE_STATE" "$STAGE_CACHE"
mkdir -p "$BUNDLE_DIR/bin" "$BUNDLE_DIR/jdk" "$BUNDLE_DIR/share/nvim"
log "bundle dir: $BUNDLE_DIR"

# ----------------------------------------------------------------------
# Step: fetch — download all tarballs into $BUNDLE_DIR/bin, $BUNDLE_DIR/jdk, $BUNDLE_DIR/fonts
# ----------------------------------------------------------------------
do_fetch() {
  log "Fetching Neovim $NVIM_VERSION …"
  local nvim_tar="nvim-linux-x86_64.tar.gz"
  if [[ ! -s "$BUNDLE_DIR/bin/$nvim_tar" ]]; then
    curl -fL --retry 3 -o "$BUNDLE_DIR/bin/$nvim_tar" \
      "https://github.com/neovim/neovim/releases/download/${NVIM_VERSION}/${nvim_tar}"
  fi

  log "Fetching Node.js $NODE_VERSION …"
  local node_tar="node-${NODE_VERSION}-linux-x64.tar.xz"
  if [[ ! -s "$BUNDLE_DIR/bin/$node_tar" ]]; then
    curl -fL --retry 3 -o "$BUNDLE_DIR/bin/$node_tar" \
      "https://nodejs.org/dist/${NODE_VERSION}/${node_tar}"
  fi

  log "Fetching Temurin JDK 21 …"
  if [[ ! -s "$BUNDLE_DIR/jdk/$JDK_FILE" ]]; then
    curl -fL --retry 3 -o "$BUNDLE_DIR/jdk/$JDK_FILE" \
      "https://github.com/adoptium/temurin21-binaries/releases/download/jdk-${JDK_VERSION}/${JDK_FILE}"
  fi

  log "Fetching tree-sitter CLI ${TS_CLI_VERSION} (staging-only) …"
  if [[ ! -s "$DL/tree-sitter-linux-x64.gz" ]]; then
    curl -fL --retry 3 -o "$DL/tree-sitter-linux-x64.gz" \
      "https://github.com/tree-sitter/tree-sitter/releases/download/${TS_CLI_VERSION}/tree-sitter-linux-x64.gz"
  fi

  log "Fetch complete."
}

# ----------------------------------------------------------------------
# Extract nvim/node/jdk into $STAGE so we can run headless installs here.
# ----------------------------------------------------------------------
extract_toolchain() {
  local nvim_root="$STAGE/nvim"
  local node_root="$STAGE/node"
  local jdk_root="$STAGE/jdk"
  local node_tar="node-${NODE_VERSION}-linux-x64.tar.xz"

  if [[ ! -x "$nvim_root/bin/nvim" ]]; then
    log "Extracting nvim to $nvim_root"
    mkdir -p "$nvim_root"
    tar --strip-components=1 -xzf "$BUNDLE_DIR/bin/nvim-linux-x86_64.tar.gz" -C "$nvim_root"
  fi

  if [[ ! -x "$node_root/bin/node" ]]; then
    log "Extracting node to $node_root"
    mkdir -p "$node_root"
    tar --strip-components=1 -xJf "$BUNDLE_DIR/bin/$node_tar" -C "$node_root"
  fi

  if [[ ! -x "$jdk_root/bin/java" ]]; then
    log "Extracting jdk to $jdk_root"
    mkdir -p "$jdk_root"
    tar --strip-components=1 -xzf "$BUNDLE_DIR/jdk/$JDK_FILE" -C "$jdk_root"
  fi

  local ts_cli_root="$STAGE/ts-cli"
  if [[ ! -x "$ts_cli_root/tree-sitter" && -s "$DL/tree-sitter-linux-x64.gz" ]]; then
    log "Extracting tree-sitter CLI to $ts_cli_root"
    mkdir -p "$ts_cli_root"
    gunzip -c "$DL/tree-sitter-linux-x64.gz" > "$ts_cli_root/tree-sitter"
    chmod +x "$ts_cli_root/tree-sitter"
  fi

  export PATH="$nvim_root/bin:$node_root/bin:$jdk_root/bin:$ts_cli_root:$PATH"
  export JAVA_HOME="$jdk_root"
  export XDG_CONFIG_HOME="$STAGE_CFG"
  export XDG_DATA_HOME="$STAGE_DATA"
  export XDG_STATE_HOME="$STAGE_STATE"
  export XDG_CACHE_HOME="$STAGE_CACHE"

  # Symlink our config into the staging XDG_CONFIG_HOME.
  mkdir -p "$STAGE_CFG"
  rm -rf "$STAGE_CFG/nvim"
  ln -sfn "$CONFIG_DIR/nvim" "$STAGE_CFG/nvim"

  log "nvim $(nvim --version | head -1)"
  log "node $(node --version)  npm $(npm --version)"
  log "java $(java -version 2>&1 | head -1)"
}

# ----------------------------------------------------------------------
# Step: plugins — :Lazy sync, headless
# ----------------------------------------------------------------------
do_plugins() {
  extract_toolchain
  log "Cloning all lazy.nvim plugin specs (this clones ~60 repos) …"
  log "  → streaming nvim output; full log at $STAGE/plugins.log"
  # First pass bootstraps LazyVim itself and eager plugins. stdbuf -oL
  # forces line-buffered stdout so progress reaches the terminal as it
  # happens instead of appearing in one burst at the end.
  stdbuf -oL -eL nvim --headless "+Lazy! sync" "+qa" 2>&1 \
    | tee "$STAGE/plugins.log" || true
  # Second pass forces install of every lazy-loaded spec (the first pass
  # skips them because they're not loaded yet).
  stdbuf -oL -eL nvim --headless "+Lazy! install" "+qa" 2>&1 \
    | tee -a "$STAGE/plugins.log" || true

  if [[ ! -d "$STAGE_DATA/nvim/lazy/LazyVim" ]]; then
    die "LazyVim plugin didn't install. Check network and lua/config/lazy.lua."
  fi
  log "Plugin install OK — $(ls "$STAGE_DATA/nvim/lazy" | wc -l) plugins installed."
}

# ----------------------------------------------------------------------
# Step: mason — install every LSP/DAP/formatter we need
# ----------------------------------------------------------------------
MASON_PKGS=(
  # C / C++ / CMake
  clangd codelldb cmake-language-server neocmakelsp
  # Python
  basedpyright ruff debugpy black isort
  # Java
  jdtls java-debug-adapter java-test
  # Lua
  lua-language-server stylua
  # Shell
  bash-language-server shellcheck shfmt
  # Config formats
  json-lsp yaml-language-server taplo
  # Markdown
  marksman prettier markdownlint-cli2
  # Go
  gopls delve goimports
  # Web / JS / TS
  typescript-language-server html-lsp css-lsp eslint-lsp
  tailwindcss-language-server emmet-language-server
)

do_mason() {
  extract_toolchain
  log "Installing ${#MASON_PKGS[@]} Mason packages (bypassing LazyVim to avoid install races)"

  # Write the package list into a helper file Lua can read, avoiding any
  # shell-quoting pitfalls with the Mason install logic.
  local helper="$STAGE/mason_install.lua"
  {
    echo 'local pkgs = {'
    for p in "${MASON_PKGS[@]}"; do printf '  "%s",\n' "$p"; done
    echo '}'
    cat <<'LUA'
-- Run under `nvim --clean`: no init.lua, no LazyVim, no lazy.nvim. That
-- eliminates a whole class of races: LazyVim's lsp-extras register a
-- `mason-registry.refresh` callback that calls `pkg:install()` on every
-- package in its ensure_installed list *without* a pre-check, which then
-- asserts ("Package is already installing") as soon as our loop or any
-- other caller has already queued one of those packages. The assert fires
-- inside mason's async runtime, which wedges the task scheduler and
-- leaves pending installs stuck forever. Running clean sidesteps all of
-- that — we only need mason.nvim itself to drive installs.

-- Locate the staged mason.nvim and bolt it onto the runtimepath manually.
-- The stage step lives at $XDG_DATA_HOME/nvim/lazy/mason.nvim/ (that's
-- where `do_plugins` put it via `:Lazy! sync`). stdpath("data") respects
-- XDG_DATA_HOME, which extract_toolchain has exported for us.
local data = vim.fn.stdpath("data")
local mason_dir = data .. "/lazy/mason.nvim"
if vim.fn.isdirectory(mason_dir) == 0 then
  print("ABORT: mason.nvim not found at " .. mason_dir
        .. " — run `./stage.sh plugins` first")
  vim.cmd("cq 1")
end
vim.opt.rtp:prepend(mason_dir)
-- Some mason versions ship plugin/*.lua auto-load hooks. Without
-- lazy.nvim those don't fire, so source them by hand.
for _, f in ipairs(vim.fn.glob(mason_dir .. "/plugin/*.lua", false, true)) do
  local ok, err = pcall(dofile, f)
  if not ok then print("warn: failed to source " .. f .. ": " .. tostring(err)) end
end

require("mason").setup()
local registry = require("mason-registry")

-- registry.refresh is async-with-optional-callback. Wait up to 2 min for
-- the github.com/mason-org/mason-registry metadata download to complete.
local refreshed = false
registry.refresh(function() refreshed = true end)
vim.wait(120000, function() return refreshed end, 500)
print("registry refreshed: " .. tostring(refreshed))
if not refreshed then
  print("ABORT: registry refresh failed — check network to github.com")
  vim.cmd("cq 1")
end

-- Per-package diagnostics: track state + a rolling tail of stdout/stderr
-- so we can report which packages are actually stuck and what their
-- installer is saying. Populated by event listeners on each install
-- handle (defensive: listener API varies between mason versions).
local diag = {}   -- name -> { state = "queued"|..., tail = {...}, done = bool }
local TAIL_MAX = 20

local function diag_state(name)
  return (diag[name] or {}).state or "?"
end

local function push_tail(name, line)
  local d = diag[name] or { state = "?", tail = {}, done = false }
  if #d.tail >= TAIL_MAX then table.remove(d.tail, 1) end
  table.insert(d.tail, line)
  diag[name] = d
end

-- Subscribe to every event we can, best-effort. mason-core's handles
-- have historically exposed `:on(event, cb)` for `state:change`,
-- `stdout`, `stderr`, and `closed`. Older versions may not have all of
-- them, so every hookup is wrapped in pcall.
local function hook_handle(name, h)
  if type(h) ~= "table" or type(h.on) ~= "function" then return end
  pcall(function()
    h:on("state:change", function(...)
      local args = {...}
      -- The signature varies (old/new or just new); take the last arg.
      local new = tostring(args[#args] or "")
      diag[name].state = new
      print(string.format("  [%-40s] state → %s", name, new))
    end)
  end)
  local function sink(label)
    return function(data)
      if type(data) ~= "string" then data = tostring(data) end
      for line in data:gmatch("[^\n]+") do
        push_tail(name, label .. ": " .. line)
        -- Echo live too; extremely verbose but useful for hangs.
        print(string.format("  [%-40s] %s: %s", name, label, line))
      end
    end
  end
  pcall(function() h:on("stdout", sink("out")) end)
  pcall(function() h:on("stderr", sink("err")) end)
  pcall(function()
    h:on("closed", function()
      diag[name].done = true
      diag[name].state = "closed"
      print(string.format("  [%-40s] closed", name))
    end)
  end)
end

-- Kick off installs. With LazyVim out of the picture, we are the only
-- caller of pkg:install(), so no race to worry about.
local handles = {}
for _, name in ipairs(pkgs) do
  local ok, pkg = pcall(registry.get_package, name)
  if not ok then
    print("UNKNOWN: " .. name)
  elseif pkg:is_installed() then
    print("skip (already installed): " .. name)
  elseif pkg:is_installing() then
    -- Possible if a stale install from a previous (crashed) run survived
    -- in mason's state. Let it finish rather than restarting it.
    print("skip (already installing from earlier run): " .. name)
    diag[name] = { state = "already_installing", tail = {}, done = false }
  else
    print("installing: " .. name)
    local h = pkg:install()
    handles[name] = h
    diag[name] = { state = "queued", tail = {}, done = false }
    hook_handle(name, h)
  end
end

-- Wait up to 30 minutes for every handle to settle. Report every 15 s
-- with per-package detail — name, current state, last few output lines
-- — so hung installs are immediately visible.
local deadline = vim.loop.now() + 30 * 60 * 1000
local last_report = 0
while vim.loop.now() < deadline do
  local pending = {}
  for _, name in ipairs(pkgs) do
    local ok, pkg = pcall(registry.get_package, name)
    if ok and not pkg:is_installed() then table.insert(pending, name) end
  end
  if #pending == 0 then break end
  if vim.loop.now() - last_report > 15000 then
    print(string.format("  ... %d/%d still pending:", #pending, #pkgs))
    for _, name in ipairs(pending) do
      local d = diag[name] or {}
      print(string.format("    - %-40s state=%s", name, diag_state(name)))
      local tail = d.tail or {}
      local start = math.max(1, #tail - 4)
      for i = start, #tail do
        print(string.format("        │ %s", tail[i]))
      end
    end
    last_report = vim.loop.now()
  end
  vim.wait(2000)
end

local missing = {}
for _, name in ipairs(pkgs) do
  local ok, pkg = pcall(registry.get_package, name)
  if not ok or not pkg:is_installed() then
    table.insert(missing, name)
  end
end
if #missing > 0 then
  print("MISSING: " .. table.concat(missing, ", "))
  vim.cmd("cq 1")
else
  print("ALL OK")
  vim.cmd("qa")
end
LUA
  } > "$helper"

  # Use +luafile (not -l) so init.lua loads first and mason is on rtp.
  # Stream output live: Mason downloads ~500 MB of LSP servers (jdtls alone
  # is ~200 MB) and can run for 10–30 min. Without live output the terminal
  # looks hung; with it you see the Lua helper's 15-second progress pings
  # ("  ... N/32 still pending") and per-package "installing: …" lines.
  log "  → streaming nvim output; full log at $STAGE/mason.log"
  # `--clean` = no user init, no plugins, no shada. We set up rtp manually
  # in the helper Lua. Bypasses LazyVim's racing ensure_installed callback.
  stdbuf -oL -eL nvim --headless --clean "+luafile $helper" 2>&1 \
    | tee "$STAGE/mason.log" || {
    warn "Some Mason packages failed. Re-run: ./stage.sh mason"
    warn "Full log: $STAGE/mason.log"
    return 1
  }
  log "All Mason packages installed."
}

# ----------------------------------------------------------------------
# Step: ts — compile treesitter parsers
# ----------------------------------------------------------------------
TS_LANGS=(
  bash c cpp cmake css diff dockerfile go gomod gosum gowork html java
  javascript jsdoc json json5 lua luadoc luap make markdown markdown_inline
  python query regex rust scss sql toml tsx typescript vim vimdoc xml yaml
  zig
)

do_ts() {
  extract_toolchain
  log "Installing ${#TS_LANGS[@]} treesitter parsers (compiles with gcc, bypassing LazyVim) …"

  # nvim-treesitter main-branch only exposes async :TSInstall — drive it
  # through Lua so we can block on the returned Task.
  local helper="$STAGE/ts_install.lua"
  {
    echo 'local langs = {'
    for l in "${TS_LANGS[@]}"; do printf '  "%s",\n' "$l"; done
    echo '}'
    cat <<'LUA'
-- Run under `nvim --clean` so LazyVim's treesitter ensure_installed hook
-- doesn't register a competing install task. (Same class of race as the
-- mason step — LazyVim's lsp extras auto-install parsers on startup; if
-- those tasks interleave with ours, nvim-treesitter's async runtime can
-- error and leave parsers half-compiled.)

-- Bolt nvim-treesitter onto the runtimepath directly. It lives at
-- $XDG_DATA_HOME/nvim/lazy/nvim-treesitter/ after `do_plugins`.
local data = vim.fn.stdpath("data")
local ts_dir = data .. "/lazy/nvim-treesitter"
if vim.fn.isdirectory(ts_dir) == 0 then
  print("ABORT: nvim-treesitter not found at " .. ts_dir
        .. " — run `./stage.sh plugins` first")
  vim.cmd("cq 1")
end
vim.opt.rtp:prepend(ts_dir)
for _, f in ipairs(vim.fn.glob(ts_dir .. "/plugin/*.lua", false, true)) do
  local ok, err = pcall(dofile, f)
  if not ok then print("warn: failed to source " .. f .. ": " .. tostring(err)) end
end

local install = require("nvim-treesitter.install").install
local task = install(langs, { summary = true, force = true })
local ok, err = pcall(function() task:wait(30 * 60 * 1000) end)
if not ok then
  print("install task error: " .. tostring(err))
end

local install_dir = require("nvim-treesitter.config").get_install_dir("parser")
local missing = {}
for _, l in ipairs(langs) do
  if vim.fn.filereadable(install_dir .. "/" .. l .. ".so") == 0 then
    table.insert(missing, l)
  end
end
if #missing > 0 then
  print("MISSING: " .. table.concat(missing, ", "))
  vim.cmd("cq 1")
else
  print("ALL OK (" .. #langs .. " parsers in " .. install_dir .. ")")
  vim.cmd("qa")
end
LUA
  } > "$helper"

  log "  → streaming nvim output; full log at $STAGE/ts.log"
  stdbuf -oL -eL nvim --headless --clean "+luafile $helper" 2>&1 \
    | tee "$STAGE/ts.log" || {
    warn "Some treesitter parsers failed. Re-run: ./stage.sh ts"
    warn "Full log: $STAGE/ts.log"
    return 1
  }
}

# ----------------------------------------------------------------------
# Step: copy — move staged data into the bundle
# ----------------------------------------------------------------------
do_copy() {
  log "Copying staged data into bundle …"
  rm -rf "$BUNDLE_DIR/share/nvim/lazy" "$BUNDLE_DIR/share/nvim/mason" "$BUNDLE_DIR/share/nvim/site"
  cp -a "$STAGE_DATA/nvim/lazy"  "$BUNDLE_DIR/share/nvim/lazy"
  cp -a "$STAGE_DATA/nvim/mason" "$BUNDLE_DIR/share/nvim/mason"
  # nvim-treesitter (main branch) installs compiled parsers + queries into
  # stdpath('data')/site/{parser,parser-info,queries}, not under lazy/.
  if [[ -d "$STAGE_DATA/nvim/site" ]]; then
    cp -a "$STAGE_DATA/nvim/site" "$BUNDLE_DIR/share/nvim/site"
  else
    warn "No site/ dir at $STAGE_DATA/nvim/site — treesitter parsers may be missing."
  fi
  log "Bundle size: $(du -sh "$BUNDLE_DIR" | cut -f1)"
  log "Done. Run ./install.sh on the offline machine."
}

# ----------------------------------------------------------------------
# Step: clean — remove build artifacts produced by stage.sh
# ----------------------------------------------------------------------
do_clean() {
  local targets=(
    "$BUNDLE_DIR/.stage"
    "$BUNDLE_DIR/.downloads"
    "$BUNDLE_DIR/share/nvim/lazy"
    "$BUNDLE_DIR/share/nvim/mason"
    "$BUNDLE_DIR/share/nvim/site"
  )

  local found=()
  for t in "${targets[@]}"; do
    [[ -e "$t" ]] && found+=("$t")
  done

  if (( ${#found[@]} == 0 )); then
    log "Nothing to clean."
    return 0
  fi

  log "The following will be removed:"
  for t in "${found[@]}"; do
    printf '  %s  (%s)\n' "$t" "$(du -sh "$t" 2>/dev/null | cut -f1)" >&2
  done
  log "(Downloaded tarballs under bin/, jdk/ are kept.)"

  read -r -p "Proceed? [y/N] " ans
  case "$ans" in
    y|Y|yes) ;;
    *) die "Aborted." ;;
  esac

  for t in "${found[@]}"; do
    log "rm -rf $t"
    rm -rf "$t"
  done
  log "Clean complete."
}

# ----------------------------------------------------------------------
# Dispatcher
# ----------------------------------------------------------------------
case "${1:-all}" in
  fetch)   do_fetch ;;
  plugins) do_plugins ;;
  mason)   do_mason ;;
  ts)      do_ts ;;
  copy)    do_copy ;;
  clean)   do_clean ;;
  all)     do_fetch; do_plugins; do_mason; do_ts; do_copy ;;
  *)       die "Unknown step: $1" ;;
esac
