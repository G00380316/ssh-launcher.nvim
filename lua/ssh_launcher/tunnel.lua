---@mod ssh_launcher.tunnel Background port forwards
---
--- A host's `-L`/`-R`/`-D` forwards without an interactive session parked open
--- to hold them up. Each tunnel is an `ssh -N` process owned by this Neovim
--- instance and stopped when it exits, so nothing is left listening on a port
--- after the editor closes.
---
--- Tunnels need authentication to be non-interactive: the key must be
--- unencrypted or already in the agent. That is checked before spawning rather
--- than leaving a process to hang on a passphrase prompt nobody can see.

local util = require("ssh_launcher.util")
local log = require("ssh_launcher.log")
local Host = require("ssh_launcher.host")
local agent = require("ssh_launcher.agent")

local M = {}

---@class ssh_launcher.Tunnel
---@field id string
---@field host ssh_launcher.Host
---@field forward ssh_launcher.Forward
---@field proc vim.SystemObj
---@field started_at integer
---@field stopped boolean
---@field error string|nil

---@type table<string, ssh_launcher.Tunnel>
local tunnels = {}
local seq = 0

---@param h ssh_launcher.Host
---@param forward ssh_launcher.Forward
---@return string
local function key_for(h, forward)
  return ("%s|%s|%s"):format(h.id, forward.kind, forward.spec)
end

---@return ssh_launcher.Tunnel[]
function M.list()
  local out = {}
  for _, t in pairs(tunnels) do
    if not t.stopped then
      out[#out + 1] = t
    end
  end
  table.sort(out, function(a, b)
    return a.started_at < b.started_at
  end)
  return out
end

---@param host_id string
---@return ssh_launcher.Tunnel[]
function M.for_host(host_id)
  return vim.tbl_filter(function(t)
    return t.host.id == host_id
  end, M.list())
end

---@param h ssh_launcher.Host
---@param forward ssh_launcher.Forward
---@return boolean
function M.is_open(h, forward)
  local t = tunnels[key_for(h, forward)]
  return t ~= nil and not t.stopped
end

---@param forward ssh_launcher.Forward
---@return string
function M.describe(forward)
  local arrow = ({ ["local"] = "→", remote = "←", dynamic = "⇄" })[forward.kind] or "→"
  return ("%s %s %s"):format(forward.kind, arrow, forward.spec)
end

--- Can this host authenticate without asking a human anything?
---@param h ssh_launcher.Host
---@return boolean ok, string|nil reason
function M.can_run_unattended(h)
  local state = agent.unlock_state(h.identity_file)
  if state.needed then
    return false, state.detail
  end
  return true, nil
end

--- Raise one forward.
---@param h ssh_launcher.Host
---@param forward ssh_launcher.Forward
---@param cb fun(ok: boolean, msg: string)|nil
function M.open(h, forward, cb)
  cb = cb or function() end

  if M.is_open(h, forward) then
    return cb(false, ("%s is already up"):format(M.describe(forward)))
  end

  local ok, reason = M.can_run_unattended(h)
  if not ok then
    -- A backgrounded ssh cannot prompt: it would hang holding the port.
    return cb(false, ("cannot raise a tunnel unattended — %s"):format(reason))
  end

  -- `-N` means "no remote command"; the process exists only for the forward.
  local argv = Host.build_argv(h, { extra_args = { "-N" }, no_multiplex = true })
  local flag = ({ ["local"] = "-L", remote = "-R", dynamic = "-D" })[forward.kind]
  if not flag then
    return cb(false, ("unknown forward kind %q"):format(tostring(forward.kind)))
  end
  -- Insert the forward before the target, which build_argv puts last.
  table.insert(argv, #argv, flag)
  table.insert(argv, #argv, forward.spec)
  -- BatchMode makes a missing credential fail immediately instead of hanging.
  table.insert(argv, #argv, "-o")
  table.insert(argv, #argv, "BatchMode=yes")

  seq = seq + 1
  local id = ("t%d"):format(seq)
  local key = key_for(h, forward)

  log.debug("tunnel exec: " .. table.concat(argv, " "))

  local started, proc = pcall(vim.system, argv, { text = true }, function(res)
    vim.schedule(function()
      local t = tunnels[key]
      if not t then
        return
      end
      t.stopped = true
      if res.code ~= 0 and not t.closed_by_us then
        t.error = util.nonblank(res.stderr) or ("ssh exited %d"):format(res.code)
        log.warn(("tunnel %s for %s stopped: %s"):format(M.describe(forward), Host.label(h), t.error))
      end
    end)
  end)

  if not started then
    return cb(false, ("could not start ssh: %s"):format(tostring(proc)))
  end

  tunnels[key] = {
    id = id,
    host = h,
    forward = forward,
    proc = proc,
    started_at = util.now(),
    stopped = false,
  }

  -- ssh exits within milliseconds if the forward cannot be bound, so a short
  -- grace period distinguishes "up" from "refused" without polling.
  vim.defer_fn(function()
    local t = tunnels[key]
    if t and t.stopped then
      cb(false, t.error or "the tunnel closed immediately")
    else
      cb(true, ("%s up for %s"):format(M.describe(forward), Host.label(h)))
    end
  end, 350)
end

---@param h ssh_launcher.Host
---@param forward ssh_launcher.Forward
---@return boolean ok
function M.close(h, forward)
  local key = key_for(h, forward)
  local t = tunnels[key]
  if not t or t.stopped then
    return false
  end
  t.closed_by_us = true
  t.stopped = true
  pcall(function()
    t.proc:kill(15)
  end)
  tunnels[key] = nil
  return true
end

--- Raise every forward a host declares.
---@param h ssh_launcher.Host
---@param cb fun(opened: integer, failed: string[])|nil
function M.open_all(h, cb)
  local forwards = h.forwards or {}
  if #forwards == 0 then
    if cb then
      cb(0, { "this host declares no port forwards" })
    end
    return
  end

  local opened, failures, remaining = 0, {}, #forwards
  for _, forward in ipairs(forwards) do
    M.open(h, forward, function(ok, msg)
      if ok then
        opened = opened + 1
      else
        failures[#failures + 1] = msg
      end
      remaining = remaining - 1
      if remaining == 0 and cb then
        cb(opened, failures)
      end
    end)
  end
end

---@param h ssh_launcher.Host
---@return integer closed
function M.close_all(h)
  local closed = 0
  for _, t in ipairs(M.for_host(h.id)) do
    if M.close(t.host, t.forward) then
      closed = closed + 1
    end
  end
  return closed
end

--- Stop every tunnel. Registered on VimLeavePre so none outlives the editor.
---@return integer closed
function M.shutdown()
  local closed = 0
  for _, t in ipairs(M.list()) do
    if M.close(t.host, t.forward) then
      closed = closed + 1
    end
  end
  return closed
end

local installed = false

--- Install the exit hook once.
function M.setup()
  if installed then
    return
  end
  installed = true
  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = vim.api.nvim_create_augroup("SshLauncherTunnels", { clear = true }),
    desc = "ssh-launcher: stop background tunnels",
    callback = function()
      M.shutdown()
    end,
  })
end

return M
