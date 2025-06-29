# ssh-launcher.nvim

A minimal SSH launcher plugin for Neovim with UI selection and `ssh-add` support.

## ✨ Features

* `:SshLauncher` – Select from your defined SSH connections
* `:SshAddKey` – Adds your private key to the SSH agent
* Prompted SSH config creation (name, user, host, key path)
* JSON schema validation
* Edit and delete SSH configs interactively
* Opens connections in Neovim terminal tab
* Saved SSH configs stored at `~/.local/nvim/ssh_launcher/hosts.json`

## 📦 Installation (Lazy.nvim)

```lua
{
  "G00380316/ssh-launcher.nvim",
  lazy = true,
  cmd = { "SshLauncher", "SshAddKey", "SshEditKey" },
  config = function()
    require("ssh_launcher").setup()
  end,
}
```

## 🚀 Usage

* `:SshAddKey` – Launches a UI prompt to add a new SSH connection.
* `:SshEditKey` – Opens a UI selection for saved connections and starts a terminal SSH session.
* `:SshLauncher` – Opens a UI selection for saved connections and starts a terminal SSH session.

## 🛠 Planned Features

* [ ] Add/edit/delete SSH configs from UI
* [ ] Telescope integration
* [ ] Encrypted config (GPG)

## 📁 Config Format

```json
[
  {
    "name": "AWS EC2",
    "user": "ec2-user",
    "host": "1.2.3.4",
    "key": "~/.ssh/my-key.pem"
  }
]
```

## 📌 Notes

* SSH connections are opened in a new Neovim terminal tab.
* Configuration stored locally at `~/.local/nvim/ssh_launcher/hosts.json`
* Ensure the private key path is accessible and permissions are correct.

---

Feel free to contribute or submit issues at [github.com/G00380316/ssh-launcher.nvim](https://github.com/G00380316/ssh-launcher.nvim)
