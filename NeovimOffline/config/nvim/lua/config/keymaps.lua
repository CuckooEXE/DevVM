-- LazyVim auto-loads lua/config/keymaps.lua AFTER its own defaults, so these override where needed.
-- LazyVim already maps gd, K, <leader>cr, <leader>ca, <leader>cf. We add VSCode-style extras.

local map = vim.keymap.set

-- Extra "goto" aliases for muscle memory
map("n", "<leader>gd", vim.lsp.buf.definition, { desc = "Goto Definition" })
map("n", "<leader>gD", vim.lsp.buf.declaration, { desc = "Goto Declaration" })
map("n", "<leader>gi", vim.lsp.buf.implementation, { desc = "Goto Implementation" })
map("n", "<leader>gr", vim.lsp.buf.references, { desc = "Goto References" })
map("n", "<leader>gt", vim.lsp.buf.type_definition, { desc = "Goto Type Definition" })

-- VSCode-style completion trigger (LazyVim uses blink.cmp by default; Ctrl-Space triggers it)
map("i", "<C-Space>", function()
  local ok, cmp = pcall(require, "blink.cmp")
  if ok then cmp.show() end
end, { desc = "Trigger completion" })

-- VSCode-style save/quit
map({ "n", "i", "v" }, "<C-s>", "<Esc>:w<CR>", { desc = "Save" })

-- Quick window nav (already LazyVim default, repeated for clarity)
map("n", "<C-h>", "<C-w>h", { desc = "Window left" })
map("n", "<C-j>", "<C-w>j", { desc = "Window down" })
map("n", "<C-k>", "<C-w>k", { desc = "Window up" })
map("n", "<C-l>", "<C-w>l", { desc = "Window right" })

-- Move lines (VSCode Alt-Up/Down)
map("n", "<A-j>", ":m .+1<CR>==", { desc = "Move line down" })
map("n", "<A-k>", ":m .-2<CR>==", { desc = "Move line up" })
map("v", "<A-j>", ":m '>+1<CR>gv=gv", { desc = "Move selection down" })
map("v", "<A-k>", ":m '<-2<CR>gv=gv", { desc = "Move selection up" })

-- Clear search highlight
map("n", "<Esc>", ":nohlsearch<CR>", { desc = "Clear highlight", silent = true })
