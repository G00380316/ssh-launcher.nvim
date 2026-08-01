---@mod ssh_launcher.launcher Compatibility shim (1.x)
---
--- Kept so configurations that call the 1.x module functions directly keep
--- working. New code should use |ssh_launcher| instead.
---@deprecated

local M = {}

--- @deprecated use `require("ssh_launcher").open()`
function M.launch_ssh()
  require("ssh_launcher").open()
end

--- @deprecated use `require("ssh_launcher").connect(target)`
---@param target string|table|nil
function M.connect(target)
  require("ssh_launcher").connect(target)
end

return M
