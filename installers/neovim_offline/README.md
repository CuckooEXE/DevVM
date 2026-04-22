# neovim_offline — LazyVim for air-gapped Linux

LazyVim + every plugin + every Mason LSP/DAP/formatter + pre-compiled
treesitter parsers + OpenJDK 21 (for jdtls), packaged to install without
network access.

**Languages out of the box:** C, C++, CMake, Python, Java, Zig, Rust, Go,
Lua, Shell, JSON, YAML, TOML, Markdown, Makefile, JS/TS/HTML/CSS, Docker.

## Layout

Source (this package, tracked):

```
installers/neovim_offline/
├── __init__.py          # hooks into setup.py
├── stage.sh             # builder (online)
├── install.sh           # deployer (offline)
└── config/nvim/         # LazyVim config copied to ~/.config/nvim
```

Artifacts (gitignored via `cache/`):

```
<repo>/cache/neovim_offline/
├── bin/                 nvim + node tarballs
├── jdk/                 OpenJDK 21
├── share/nvim/
│   ├── lazy/            every plugin, pre-cloned
│   ├── mason/           every LSP/DAP/formatter, pre-installed
│   └── site/            treesitter parsers
├── .stage/              scratch XDG_{CONFIG,DATA}_HOME for headless nvim
└── .downloads/          tree-sitter CLI
```

The Nerd Font LazyVim icons need is installed separately (system-wide)
by the top-level `fonts` section of `vmconfig.yaml`.

## Canonical flow

Both scripts are driven by `setup.py` via this package's `prepare` /
`install` functions — you don't normally invoke them directly.

```bash
python3 setup.py --mode prepare --only neovim_offline   # stage into cache
python3 setup.py --mode install --only neovim_offline   # deploy to $HOME
```

Prepare needs a few things on `PATH` before `stage.sh` runs: a C
toolchain (for treesitter parser compilation), `unzip`, `python3-venv`
(Mason's pypi installer), `golang-go` + `libc6-dev` (Mason's golang
installer uses cgo). All of these are in `bootstrap.sh`'s
`REQUIRED_APT`, so running `./bootstrap.sh full` before
`setup.py --mode prepare` covers them.

Install deploys into the invoking user's `$HOME`:

- `~/.local/share/nvim-runtime/` — Neovim runtime
- `~/.local/share/node/` — Node.js (for JS-based LSPs)
- `~/.local/share/jdk-21/` — OpenJDK 21 (for jdtls)
- `~/.config/nvim/` — LazyVim config
- `~/.local/share/nvim/{lazy,mason,site}` — plugins + LSPs + parsers
- Appends `PATH` + `JAVA_HOME` exports to `~/.bashrc` / `~/.zshrc`

## Running the scripts by hand

Both scripts honour the `BUNDLE_DIR` env var. Resolution order:

1. explicit `BUNDLE_DIR=...` (what `installers/neovim_offline/__init__.py`
   sets when `setup.py` drives the scripts).
2. else walk up from the script dir looking for `setup.py` +
   `vmconfig.yaml`, and use `$repo_root/cache/neovim_offline`.
3. else fall back to the script's own directory (for a self-contained,
   portable bundle that doesn't live inside a DevVMSetup repo).

```bash
BUNDLE_DIR=/tmp/nvim-bundle ./stage.sh            # stage into tmp
BUNDLE_DIR=/media/usb/nvim  ./install.sh --force  # deploy from USB
```

`./stage.sh` subcommands (each idempotent): `fetch`, `plugins`, `mason`,
`ts`, `copy`, `clean`. No argument runs them all in order.

`./install.sh` subcommands: `install` (default), `uninstall`. Flags:
`--dry` (preview file ops), `--force` (skip confirmation prompts).

## Updating the bundle

Delete `cache/neovim_offline/.stage/` if you want a clean rebuild, then
re-run `python3 setup.py --mode prepare --only neovim_offline`. Ship the
resulting `cache/neovim_offline/` to the offline target, then
`python3 setup.py --mode install --only neovim_offline` there.

Do **not** run `:Lazy update` or `:MasonUpdate` on the offline machine
— they'll fail with no network and may leave plugin state inconsistent.
The config already disables these checks.

## Adding a new language

Edit `config/nvim/lua/plugins/extras.lua` and add the
`lazyvim.plugins.extras.lang.<name>` import, then re-stage:

```bash
python3 setup.py --mode prepare --only neovim_offline --refresh
```

## VSCode → Neovim cheat sheet

| VSCode                     | LazyVim                     |
|----------------------------|-----------------------------|
| Ctrl+click on symbol       | `gd`                        |
| Ctrl+Shift+F12 / peek ref  | `gr`                        |
| hover panel                | `K`                         |
| F2 (rename)                | `<leader>cr`                |
| Ctrl+. (quick fix)         | `<leader>ca`                |
| Shift+Alt+F (format)       | `<leader>cf`                |
| Ctrl+P (file picker)       | `<leader>ff`                |
| Ctrl+Shift+F (search)      | `<leader>/`                 |
| Ctrl+B (sidebar)           | `<leader>e`                 |
| Ctrl+`  (terminal)         | `<C-/>` or `<leader>ft`     |
| Ctrl+/ (comment)           | `gcc` / `gc` (visual)       |
| F5/F9/F10/F11 debug        | same (DAP)                  |
| Ctrl+Space completion      | `<C-Space>` (insert)        |
| Alt+↑/↓ move line          | `<A-k>` / `<A-j>`            |

`<leader>` = Space. Press it and wait — `which-key.nvim` shows all
available bindings.

## Troubleshooting

**"command not found: nvim"** — `source ~/.bashrc` (or open a new shell)
so the installer-appended `$HOME/.local/bin` is on `PATH`.

**Icons show as `???` or squares** — set terminal font to **JetBrainsMono
Nerd Font** (installed system-wide by the `fonts` section).

**`:Mason` shows a package as "not installed"** — the stage machine
failed to download it. Re-run the prepare step:
`python3 setup.py --mode prepare --only neovim_offline --refresh`.

**`:LspInfo` shows the server isn't attaching** — some LSPs need project
markers (`jdtls` → Gradle/Maven/`.project`, `gopls` → `go.mod`,
`rust-analyzer` → `Cargo.toml`). Open a file inside a real project.

**Zig LSP (`zls`)** — Mason doesn't bundle `zls` reliably; the config at
`config/nvim/lua/plugins/lsp-fallbacks.lua` checks `/opt/zls/zls` and
falls back to `zls` on `PATH`. Install `zls` system-wide from your Zig
toolchain.
