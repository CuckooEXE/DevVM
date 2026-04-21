-- LazyVim auto-loads lua/config/options.lua before plugins load.
-- Sensible defaults that lean VSCode-ish.

local opt = vim.opt

opt.relativenumber = true
opt.number = true
opt.signcolumn = "yes"
opt.wrap = false
opt.scrolloff = 8
opt.sidescrolloff = 8
opt.cursorline = true
opt.mouse = "a"
opt.clipboard = "unnamedplus"
opt.termguicolors = true
opt.splitright = true
opt.splitbelow = true
opt.ignorecase = true
opt.smartcase = true
opt.undofile = true
opt.confirm = true
opt.updatetime = 250
opt.timeoutlen = 400

-- Default indent: 4 spaces (Python, Java, C/C++). Filetype-specific overrides via LazyVim extras.
opt.expandtab = true
opt.shiftwidth = 4
opt.tabstop = 4
opt.softtabstop = 4

-- Fold using treesitter. nvim-treesitter main branch removed the old
-- `nvim_treesitter#foldexpr()` vim function; use the built-in instead.
opt.foldmethod = "expr"
opt.foldexpr = "v:lua.vim.treesitter.foldexpr()"
opt.foldenable = false

vim.g.mapleader = " "
vim.g.maplocalleader = "\\"
