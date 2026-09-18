vim.keymap.set("n", "<leader>e", "<Cmd>Explore<CR>")

local fzf = require("fzf-lua")

vim.keymap.set("n", "<leader><leader>", fzf.files)
vim.keymap.set("n", "<leader>/", fzf.live_grep)

local opts = { noremap = true, silent = true }

vim.keymap.set("n", "gd", "<cmd>lua vim.lsp.buf.definition()<CR>", opts)
vim.keymap.set("n", "<Leader>fo", ":lua vim.lsp.buf.format()<CR>", opts)

vim.keymap.set("i", "<M-a>", "<C-o>^", { desc = "Move to start of code" })
vim.keymap.set("i", "<M-e>", "<End>",  { desc = "Move to end of line" })
