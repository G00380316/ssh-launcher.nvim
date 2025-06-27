local M = {}

local servers = require("ssh_launcher.servers")

function M.setup()
  vim.api.nvim_create_user_command("SshLauncher", function()
    M.pick_server()
  end, {})

  vim.api.nvim_create_user_command("SshAddKey", function()
    vim.fn.system("ssh-add")
    print("SSH agent key added.")
  end, {})
end

function M.pick_server()
  if not vim.ui.select then
    print("Your Neovim build doesn't support vim.ui.select.")
    return
  end

  local names = vim.tbl_map(function(s) return s.name end, servers)

  vim.ui.select(names, { prompt = "Select SSH Host:" }, function(choice)
    if not choice then return end
    for _, s in ipairs(servers) do
      if s.name == choice then
        M.connect(s)
        return
      end
    end
  end)
end

function M.connect(server)
  local cmd = string.format("ssh -i %s %s@%s", server.identity_file or "~/.ssh/id_rsa", server.user, server.host)

  vim.cmd("terminal " .. cmd)
end

return M

