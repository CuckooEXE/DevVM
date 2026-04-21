-- Enable LazyVim language & feature extras. Each entry pulls in the curated
-- plugin set for that language (LSP setup, formatters, treesitter grammars,
-- and filetype-specific keymaps).
--
-- Reference: https://www.lazyvim.org/extras

return {
  -- Languages
  { import = "lazyvim.plugins.extras.lang.clangd" },      -- C / C++
  { import = "lazyvim.plugins.extras.lang.cmake" },       -- CMake
  { import = "lazyvim.plugins.extras.lang.python" },      -- Python
  { import = "lazyvim.plugins.extras.lang.java" },        -- Java (jdtls)
  { import = "lazyvim.plugins.extras.lang.rust" },        -- Rust
  { import = "lazyvim.plugins.extras.lang.go" },          -- Go
  { import = "lazyvim.plugins.extras.lang.typescript" },  -- JS / TS
  { import = "lazyvim.plugins.extras.lang.json" },
  { import = "lazyvim.plugins.extras.lang.yaml" },
  { import = "lazyvim.plugins.extras.lang.toml" },
  { import = "lazyvim.plugins.extras.lang.markdown" },
  { import = "lazyvim.plugins.extras.lang.docker" },

  -- Formatters / linters
  { import = "lazyvim.plugins.extras.formatting.prettier" },

  -- Completion engine (LazyVim defaults to blink.cmp since ~late 2024).
  -- Kept explicit so the bundle is deterministic.
  { import = "lazyvim.plugins.extras.coding.blink" },

  -- DAP debugging (F5/F9/F10/F11)
  { import = "lazyvim.plugins.extras.dap.core" },

  -- Test runner (neotest) — bonus, works alongside DAP
  { import = "lazyvim.plugins.extras.test.core" },

  -- Editor quality-of-life
  { import = "lazyvim.plugins.extras.editor.inc-rename" },

  -- UI
  { import = "lazyvim.plugins.extras.ui.mini-animate" },
}
