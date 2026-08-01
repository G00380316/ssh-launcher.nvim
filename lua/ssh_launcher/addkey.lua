---@mod ssh_launcher.addkey Compatibility shim (1.x)
---
--- 1.x prompted for four fields in sequence. The editor replaces that with a
--- single form that also accepts a pasted connection string.
---@deprecated

local M = {}

--- @deprecated use `require("ssh_launcher").add(text)`
---@param text string|nil optional connection string to seed the form
function M.add_key(text)
  require("ssh_launcher").add(text)
end

return M
