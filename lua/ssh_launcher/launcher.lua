local M = {}

local config_path = vim.fn.stdpath("config") .. "/ssh_launcher/hosts.json"

local function get_index(tbl, val)
  for i, v in ipairs(tbl) do
    if v == val then return i end
  end
  return nil
end

local function load_hosts()
    local f = io.open(config_path, "r")
    if not f then return {} end
    local content = f:read("*a")
    f:close()
    local ok, result = pcall(vim.json.decode, content)
    return ok and result or {}
end

function M.launch_ssh()
    local hosts = load_hosts()
    if not next(hosts) then
        vim.notify("No SSH hosts saved. Use :SshAddKey to add one.", vim.log.levels.WARN)
        return
    end

    local entries = vim.tbl_map(function(h)
        return string.format("%s (%s@%s)", h.name, h.user, h.host)
    end, hosts)

    vim.ui.select(entries, { prompt = "Select SSH host:" }, function(choice)
        if not choice then return end
        local index = get_index(entries, choice)
        local h = hosts[index]
        if not h then return end
        local cmd = string.format("ssh -i %s -o StrictHostKeyChecking=no %s@%s", h.key, h.user, h.host)
        vim.cmd("tabnew | terminal " .. cmd)
    end)
end

return M
