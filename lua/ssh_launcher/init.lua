local M = {}

function M.setup()
    vim.api.nvim_create_user_command("SshLauncher", function()
        require("sshlauncher.launcher").launch_ssh()
    end, {})

    vim.api.nvim_create_user_command("SshAddKey", function()
        require("sshlauncher.addkey").add_key()
    end, {})
end

return M
