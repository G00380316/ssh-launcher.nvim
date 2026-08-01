---@mod ssh_launcher.editkey Compatibility shim (1.x)
---@deprecated

local M = {}

--- @deprecated use `require("ssh_launcher").edit(name)`
---@param name string|nil
function M.edit_key(name)
  require("ssh_launcher").edit(name)
end

return M
