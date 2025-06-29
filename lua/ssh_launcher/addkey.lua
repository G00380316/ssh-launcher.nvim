local M = {}

local config_dir = vim.fn.stdpath("config") .. "/ssh_launcher"
local config_file = config_dir .. "/hosts.json"

-- helper to read existing config
local function load_hosts()
    local f = io.open(config_file, "r")
    if not f then return {} end
    local content = f:read("*a")
    f:close()
    local ok, result = pcall(vim.json.decode, content)
    return ok and result or {}
end

-- helper to write to config
local function save_hosts(hosts)
    vim.fn.mkdir(config_dir, "p")
    local f = io.open(config_file, "w")
    if f then
        f:write(vim.json.encode(hosts))
        f:close()
        return true
    end
    return false
end

-- recursively prompt for all fields
function M.add_key()
    local new = {}
    vim.ui.input({ prompt = "Name for this host (e.g. AWS EC2): " }, function(name)
        if not name then return end
        new.name = name

        vim.ui.input({ prompt = "SSH user (e.g. ec2-user): " }, function(user)
            if not user then return end
            new.user = user

            vim.ui.input({ prompt = "Host/IP address (e.g. 54.76.182.198): " }, function(host)
                if not host then return end
                new.host = host

                vim.ui.input({ prompt = "Path to SSH key (e.g. ~/.ssh/key.pem): " }, function(key)
                    if not key then return end
                    new.key = key

                    local hosts = load_hosts()
                    table.insert(hosts, new)
                    if save_hosts(hosts) then
                        vim.notify("Saved SSH config for " .. new.name, vim.log.levels.INFO)
                    else
                        vim.notify("Failed to save SSH config.", vim.log.levels.ERROR)
                    end
                end)
            end)
        end)
    end)
end

return M
