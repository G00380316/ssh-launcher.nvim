local M = {}

function M.setup()
    vim.api.nvim_create_user_command("SshLauncher", function()
        require("ssh_launcher.launcher").launch_ssh()
    end, {})

    vim.api.nvim_create_user_command("SshAddKey", function()
        require("ssh_launcher.addkey").add_key()
    end, {})

    vim.api.nvim_create_user_command("SshEditKey", function()
        require("ssh_launcher.editkey").edit_key()
    end, {})
end

return M
