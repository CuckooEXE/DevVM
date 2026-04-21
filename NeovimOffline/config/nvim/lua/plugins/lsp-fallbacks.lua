-- Language servers that are NOT available via Mason on this target — wire them
-- up directly from the system/toolchain paths the user already has.

return {
  {
    "neovim/nvim-lspconfig",
    opts = {
      servers = {
        -- Zig: zls ships with the user's Zig toolchain. Prefer /opt/zls if
        -- present, otherwise fall back to the first zls on PATH.
        zls = {
          cmd = (vim.fn.executable("/opt/zls/zls") == 1) and { "/opt/zls/zls" } or { "zls" },
          filetypes = { "zig", "zir" },
          root_dir = function(fname)
            local util = require("lspconfig.util")
            return util.root_pattern("build.zig", ".git")(fname) or vim.fn.getcwd()
          end,
        },
      },
    },
  },
}
