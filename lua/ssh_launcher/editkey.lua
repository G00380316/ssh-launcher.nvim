local M = {}

local config_path = vim.fn.stdpath("data") .. "/ssh_launcher/hosts.json"
local config_file = data_dir .. "/hosts.json"

local function load_hosts()
    local f = io.open(config_path, "r")
    if not f then return {} end
    local content = f:read("*a")
    f:close()
    local ok, result = pcall(vim.json.decode, content)
    return ok and result or {}
end

-- helper to write to config
local function save_hosts(hosts)
    vim.fn.mkdir(data_dir, "p")
    local f = io.open(config_file, "w")
    if f then
        f:write(vim.json.encode(hosts))
        f:close()
        return true
    end
    return false
end

function M.edit_key()
    local hosts = load_hosts()
    if #hosts == 0 then
        vim.notify("No SSH hosts to edit.", vim.log.levels.WARN)
        return
    end

    vim.ui.select(hosts, {
        prompt = "Select SSH host to edit:",
        format_item = function(item) return item.name end,
    }, function(choice)
        if not choice then return end

        vim.ui.input({ prompt = "Name: ", default = choice.name }, function(name)
            if name and name ~= "" then choice.name = name end

            vim.ui.input({ prompt = "User: ", default = choice.user }, function(user)
                if user and user ~= "" then choice.user = user end

                vim.ui.input({ prompt = "Host: ", default = choice.host }, function(host)
                    if host and host ~= "" then choice.host = host end

                    vim.ui.input({ prompt = "SSH key path: ", default = choice.key }, function(key)
                        if key and key ~= "" then choice.key = key end

                        if save_hosts(hosts) then
                            vim.notify("SSH host updated: " .. choice.name, vim.log.levels.INFO)
                        else
                            vim.notify("Failed to save SSH config.", vim.log.levels.ERROR)
                        end
                    end)
                end)
            end)
        end)
    end)
end

return M
