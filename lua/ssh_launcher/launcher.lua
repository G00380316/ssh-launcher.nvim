local M = {}

local function tbl_index_of(tbl, val)
  for i, v in ipairs(tbl) do
    if v == val then return i end
  end
  return nil
end

local function load_hosts()
  local path = vim.fn.stdpath("data") .. "/ssh_launcher/hosts.json"
  local f = io.open(path, "r")
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
    local index = tbl_index_of(entries, choice) -- ✅ Using our custom function
    local h = hosts[index]
    if not h then return end
    local cmd = string.format("ssh -i %s %s@%s", h.key, h.user, h.host)
    vim.cmd("tabnew | terminal " .. cmd)
  end)
end

return M

