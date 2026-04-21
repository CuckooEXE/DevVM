-- Keep LazyVim defaults; only add a couple of helpful filetype overrides.

local aug = vim.api.nvim_create_augroup("UserFiletypes", { clear = true })

-- 2-space indent for web/config files
vim.api.nvim_create_autocmd("FileType", {
  group = aug,
  pattern = {
    "lua", "javascript", "typescript", "javascriptreact", "typescriptreact",
    "json", "jsonc", "yaml", "html", "css", "scss", "markdown", "toml",
  },
  callback = function()
    vim.bo.shiftwidth = 2
    vim.bo.tabstop = 2
    vim.bo.softtabstop = 2
    vim.bo.expandtab = true
  end,
})

-- Makefile and Go want real tabs
vim.api.nvim_create_autocmd("FileType", {
  group = aug,
  pattern = { "make", "go" },
  callback = function()
    vim.bo.expandtab = false
    vim.bo.shiftwidth = 4
    vim.bo.tabstop = 4
  end,
})

-- Detect Taskfile.yml / Taskfile.yaml as yaml (LazyVim/vim already does, but be explicit)
vim.filetype.add({
  filename = {
    ["Taskfile.yml"] = "yaml",
    ["Taskfile.yaml"] = "yaml",
    ["Taskfile.dist.yml"] = "yaml",
  },
  pattern = {
    [".*%.tasks%.ya?ml"] = "yaml",
  },
})
