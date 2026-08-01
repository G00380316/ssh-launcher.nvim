-- luacheck configuration for ssh-launcher.nvim
std = "luajit"
cache = true

read_globals = {
  "vim",
}

globals = {
  "vim.g",
  "vim.b",
  "vim.w",
  "vim.o",
  "vim.bo",
  "vim.wo",
  "vim.env",
}

-- Neovim callbacks routinely ignore arguments they are handed.
unused_args = false

exclude_files = {
  ".luarocks",
}

files["tests/*.lua"] = {
  max_line_length = false,
}

max_line_length = 140
