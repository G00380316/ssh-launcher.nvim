# ssh-launcher.nvim

A minimal SSH launcher plugin for Neovim with UI selection and `ssh-add` support.

## ✨ Features

- `:SshLauncher` – Select from your defined SSH connections
- `:SshAddKey` – Adds your private key to the SSH agent
- Open connections in Neovim terminal
- Easily extendable list of servers

## 📦 Installation (Lazy.nvim)

```lua
{
  "G00380316/ssh-launcher.nvim",
  lazy = true,
  cmd = { "SshLauncher", "SshAddKey" },
  config = function()
    require("ssh_launcher").setup()
  end,
}

