# NeovimOffline — LazyVim for air-gapped Linux

A self-contained bundle that installs [Neovim](https://neovim.io/) + [LazyVim](https://www.lazyvim.org/)
on a Debian/Ubuntu x86_64 machine with **zero network access**. Everything is
pre-downloaded on a connected "staging" machine, then copied to the offline
target where a single `./install.sh` does the rest.

**Languages supported out of the box:** C, C++, CMake, Python, Java, Zig, Rust,
Go, Lua, Shell, JSON, YAML, TOML, Markdown, Taskfile, Makefile,
JavaScript/TypeScript/HTML/CSS, Docker.

## What's in the box

The tracked source tree is tiny:

```
NeovimOffline/
├── config/nvim/      the LazyVim config that gets copied to ~/.config/nvim
├── stage.sh          builder — run on the ONLINE machine
└── install.sh        deployer — run on the OFFLINE machine
```

Everything the staging step downloads and produces lands under the shared
`cache/neovim_offline/` dir instead of cluttering this source tree:

```
<repo>/cache/neovim_offline/
├── bin/              nvim + node tarballs
├── jdk/              OpenJDK 21 (for jdtls Java LSP)
├── share/nvim/
│   ├── lazy/         every plugin, pre-cloned
│   ├── mason/        every LSP, DAP, formatter, pre-installed
│   └── site/         treesitter parsers
├── .stage/           scratch XDG_{CONFIG,DATA}_HOME for staging
└── .downloads/       raw downloads (tree-sitter CLI, etc.)
```

Both `stage.sh` and `install.sh` honour the `BUNDLE_DIR` env var (defaults
to the cache path above; falls back to the script directory when run
outside a DevVMSetup repo). Set it explicitly to ship a portable self-
contained bundle:

```
BUNDLE_DIR=/tmp/nvim-bundle ./stage.sh      # stage into a throwaway dir
BUNDLE_DIR=/media/usb/nvim ./install.sh     # deploy from external media
```

## Workflow

### Step 1 — Build the bundle (on a connected machine)

On this staging machine (Debian 13, online, has `git`, `curl`, `gcc`, `make`,
`python3`, `unzip`):

```bash
./stage.sh
```

This takes 10–30 minutes depending on bandwidth. It:

1. Downloads Neovim, Node.js, and JDK tarballs into the bundle.
2. Extracts them to a scratch `.stage/` dir and runs Neovim headlessly against
   the staged config, triggering `:Lazy sync`, `:MasonInstall`, and
   `:TSInstallSync` against every plugin/package/parser we need.
3. Copies the resulting `lazy/` and `mason/` trees into `share/nvim/`.

The Nerd Font used by LazyVim icons is installed by the parent
`DevVMSetup` pipeline (`post/05-fonts.sh`), not this bundle.

Re-runnable — each step (`./stage.sh fetch|plugins|mason|ts|copy`) is
idempotent. If a download fails, just re-run it.

### Step 2 — Move the bundle to the offline machine

```bash
# Any method works. Examples:
tar czf NeovimOffline.tar.gz NeovimOffline
# … copy NeovimOffline.tar.gz via USB / rsync / sneakernet …
tar xzf NeovimOffline.tar.gz
```

### Step 3 — Install on the offline machine

```bash
cd NeovimOffline
./install.sh --dry        # preview file operations
./install.sh              # real run
```

Installs into your `$HOME` (no root needed):

- `~/.local/share/nvim-runtime/` — Neovim runtime
- `~/.local/share/node/` — Node.js (for JS-based LSPs)
- `~/.local/share/jdk-21/` — OpenJDK 21 (for jdtls)
- `~/.config/nvim/` — LazyVim config
- `~/.local/share/nvim/{lazy,mason}` — plugins + LSPs
- Appends `PATH` + `JAVA_HOME` exports to `~/.bashrc` / `~/.zshrc`

Open a new shell, run `nvim`. No network is touched.

## VSCode → Neovim cheat sheet

| VSCode                    | LazyVim                     | Notes                              |
|---------------------------|-----------------------------|------------------------------------|
| Ctrl+click on symbol      | `gd`                        | goto definition                    |
| Ctrl+Shift+F12 / peek ref | `gr`                        | find references                    |
| hover panel               | `K`                         | show docstring                     |
| F2 (rename)               | `<leader>cr`                | rename symbol                      |
| Ctrl+. (quick fix)        | `<leader>ca`                | code actions                       |
| Shift+Alt+F (format)      | `<leader>cf`                | format buffer                      |
| Ctrl+P (file picker)      | `<leader>ff`                | find files                         |
| Ctrl+Shift+F (search)     | `<leader>/`                 | grep all files                     |
| Ctrl+Shift+O (symbols)    | `<leader>ss`                | symbols in current file            |
| Ctrl+B (sidebar)          | `<leader>e`                 | file explorer                      |
| Ctrl+` (terminal)         | `<C-/>` or `<leader>ft`     | floating terminal                  |
| Ctrl+/ (comment)          | `gcc` / `gc` (visual)       | toggle line/block comment          |
| F5 debug                  | `<F5>`                      | DAP continue                       |
| F9 breakpoint             | `<F9>`                      | DAP toggle breakpoint              |
| F10 / F11 step            | `<F10>` / `<F11>`           | step over / step into              |
| Ctrl+Space completion     | `<C-Space>` (insert)        | trigger completion menu            |
| Ctrl+S save               | `<C-s>`                     | save (added by keymaps.lua)        |
| Alt+↑/↓ move line         | `<A-k>` / `<A-j>`           | move line up/down                  |

`<leader>` = Space. Press it and wait — `which-key.nvim` shows a menu of all
available bindings. That's the fastest way to discover keymaps.

## Terminal font

Set your terminal emulator's font to **"JetBrainsMono Nerd Font"** (any
weight — Regular works) so LazyVim's icons render. Without a Nerd Font you'll
see boxes/question marks where icons should be. The font is installed
system-wide by `DevVMSetup/post/05-fonts.sh` (not by this bundle).

## Updating the bundle

Updates are intentionally a batch operation:

1. On the staging machine: `cd NeovimOffline && ./stage.sh`
   (delete `.stage/` first if you want a fully clean rebuild)
2. Copy the updated bundle to the offline machine.
3. `./install.sh --force` on the offline machine.

Do **not** run `:Lazy update` or `:MasonUpdate` on the offline machine — they
will fail (no internet) and may leave plugin state inconsistent. The config
already disables these checks; don't re-enable them.

## Adding a new language later

On the staging machine, edit `config/nvim/lua/plugins/extras.lua` and add the
`lazyvim.plugins.extras.lang.<name>` import. Then:

```bash
./stage.sh plugins    # pull in new plugin specs
./stage.sh mason      # install new LSP/formatter if the extra adds one
./stage.sh ts         # pull in the new treesitter parser
./stage.sh copy
```

Re-deploy on the offline machine.

## Troubleshooting

**"command not found: nvim"** — `source ~/.bashrc` (or open a new shell). The
installer appended `$HOME/.local/bin` to `PATH`.

**Icons show as `???` or squares** — the terminal isn't using a Nerd Font. Set
the font in your terminal's profile settings.

**`:Mason` shows a package as "not installed"** — the stage machine probably
failed to download it. Re-run `./stage.sh mason` on the stage machine and
re-sync the bundle.

**`:LspInfo` shows the server isn't attaching** — some LSPs need root markers
(e.g., `jdtls` needs a Gradle/Maven/`.project` file, `gopls` needs `go.mod`,
`rust-analyzer` needs `Cargo.toml`). Open a file inside a real project.

**Zig LSP (`zls`)** — Mason does NOT bundle `zls` reliably; the config at
`config/nvim/lua/plugins/lsp-fallbacks.lua` looks for `/opt/zls/zls` (matches
the user's prior Zig install layout) and falls back to `zls` on PATH. Install
`zls` system-wide from your Zig toolchain and it'll attach.

## Layout summary

All bundle-relative paths below are under `$BUNDLE_DIR` (i.e.
`cache/neovim_offline/` by default) except `config/nvim/`, which is
tracked under `NeovimOffline/`:

| Target path                          | Source                         |
|--------------------------------------|--------------------------------|
| `~/.local/share/nvim-runtime/`       | `bin/nvim-linux-*.tar.gz`      |
| `~/.local/share/node/`               | `bin/node-*.tar.xz`            |
| `~/.local/share/jdk-21/`             | `jdk/OpenJDK21*.tar.gz`        |
| `~/.config/nvim/`                    | `NeovimOffline/config/nvim/`   |
| `~/.local/share/nvim/lazy/`          | `share/nvim/lazy/`             |
| `~/.local/share/nvim/mason/`         | `share/nvim/mason/`            |
