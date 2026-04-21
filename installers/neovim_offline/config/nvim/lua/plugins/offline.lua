-- Offline hardening. Every plugin that would otherwise phone home at runtime
-- is reconfigured to only use what's already on disk. Binaries are pre-staged
-- into ~/.local/share/nvim/mason by the bundle installer; treesitter parsers
-- live under ~/.local/share/nvim/site/parser/ (nvim-treesitter main branch).

return {
  -- mason.nvim — don't auto-update the registry on startup.
  {
    "mason-org/mason.nvim",
    opts = {
      max_concurrent_installers = 1,
      PATH = "prepend",
      ui = { check_outdated_packages_on_open = false },
    },
  },

  -- mason-lspconfig — don't try to install missing servers.
  {
    "mason-org/mason-lspconfig.nvim",
    opts = {
      ensure_installed = {},
      automatic_installation = false,
    },
  },

  -- mason-tool-installer (if LazyVim pulls it in via an extra) — neutered.
  {
    "WhoIsSethDaniel/mason-tool-installer.nvim",
    optional = true,
    opts = {
      ensure_installed = {},
      auto_update = false,
      run_on_start = false,
    },
  },

  -- mason-nvim-dap — LazyVim's dap.core extra enables automatic_installation,
  -- which refreshes the mason registry on first DAP use and breaks offline.
  -- All adapters we need (codelldb, debugpy, delve, java-debug-adapter,
  -- js-debug-adapter) are pre-staged, so disable auto install.
  {
    "jay-babu/mason-nvim-dap.nvim",
    optional = true,
    opts = {
      ensure_installed = {},
      automatic_installation = false,
    },
  },

  -- nvim-treesitter — do not auto-install or auto-update parsers. They ship
  -- pre-compiled in the bundle.
  {
    "nvim-treesitter/nvim-treesitter",
    opts = function(_, opts)
      opts.ensure_installed = {}
      opts.auto_install = false
      opts.sync_install = false
      return opts
    end,
  },

  -- lazydev.nvim — skip the online luvit-meta download (optional dep).
  {
    "folke/lazydev.nvim",
    optional = true,
    opts = { library = {} },
  },

  -- Disable LazyVim's "News" / changelog popup on startup
  {
    "folke/snacks.nvim",
    opts = { dashboard = { preset = { header = "" } } },
  },

  -- blink.cmp — force the pure-Lua fuzzy matcher. The Rust matcher needs
  -- either a `cargo build` (fetches crates) or a prebuilt binary download
  -- from GitHub releases; neither works offline. Lua matcher is ~1ms slower
  -- per completion — unnoticeable in practice.
  {
    "saghen/blink.cmp",
    opts = {
      fuzzy = {
        implementation = "lua",
        prebuilt_binaries = { download = false, ignore_version_mismatch = true },
      },
    },
  },
}
