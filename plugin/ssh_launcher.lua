-- ssh-launcher.nvim
--
-- Commands are defined eagerly so the plugin works without calling setup(),
-- but nothing else happens at startup: the heavy modules are only required the
-- first time a command actually runs.

if vim.g.loaded_ssh_launcher then
  return
end
vim.g.loaded_ssh_launcher = true

if vim.fn.has("nvim-0.10") == 0 then
  vim.notify_once("ssh-launcher.nvim requires Neovim 0.10 or newer", vim.log.levels.WARN)
  return
end

vim.api.nvim_create_user_command("Ssh", function(cmd)
  require("ssh_launcher")._dispatch(cmd)
end, {
  nargs = "*",
  bang = true,
  complete = function(arglead, cmdline)
    return require("ssh_launcher")._complete(arglead, cmdline)
  end,
  desc = "ssh-launcher: manage and open SSH connections",
})

for _, name in ipairs({
  "SshLauncher",
  "SshConnect",
  "SshAddKey",
  "SshEditKey",
  "SshAgent",
  "SshSessions",
  "SshDiagnose",
}) do
  vim.api.nvim_create_user_command(name, function(cmd)
    local ssh = require("ssh_launcher")
    ssh.ensure_setup()
    ssh._legacy[name](cmd.args)
  end, {
    nargs = "*",
    complete = function(arglead)
      return require("ssh_launcher")._complete(arglead, "Ssh connect " .. arglead)
    end,
    desc = "ssh-launcher: " .. name,
  })
end
