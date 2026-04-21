local lazypath = vim.fn.stdpath("data") .. "/lazy/lazy.nvim"
if not (vim.uv or vim.loop).fs_stat(lazypath) then
  local ok = pcall(function()
    local out = vim.fn.system({
      "git", "clone", "--filter=blob:none", "--branch=stable",
      "https://github.com/folke/lazy.nvim.git", lazypath,
    })
    if vim.v.shell_error ~= 0 then error(out) end
  end)
  if not ok then
    vim.api.nvim_echo({
      { "lazy.nvim not found and offline clone failed.\n", "ErrorMsg" },
      { "Expected it to be pre-installed at " .. lazypath .. "\n" },
    }, true, {})
    return
  end
end
vim.opt.rtp:prepend(lazypath)

require("lazy").setup({
  spec = {
    { "LazyVim/LazyVim", import = "lazyvim.plugins" },
    { import = "plugins" },
  },
  defaults = { lazy = false, version = false },
  install = { missing = false, colorscheme = { "tokyonight", "habamax" } },
  checker = { enabled = false, notify = false },
  change_detection = { enabled = false, notify = false },
  performance = {
    rtp = {
      disabled_plugins = {
        "gzip", "tarPlugin", "tohtml", "tutor", "zipPlugin",
      },
    },
  },
})
