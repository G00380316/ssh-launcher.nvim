---@mod ssh_launcher.log Notifications and diagnostics logging
---
--- All user-facing messaging funnels through here so that verbosity, screen
--- reader announcements and the debug log stay consistent across modules.

local util = require("ssh_launcher.util")

local M = {}

local TITLE = "ssh-launcher"

---@type integer
M.level = vim.log.levels.INFO

---@type string|nil
M.file = nil

local function logfile()
  if M.file then
    return M.file
  end
  M.file = util.join(vim.fn.stdpath("log") --[[@as string]], "ssh-launcher.log")
  return M.file
end

---@param level integer
---@param msg string
local function to_file(level, msg)
  if M.level > vim.log.levels.DEBUG then
    return
  end
  local names = { [0] = "TRACE", "DEBUG", "INFO", "WARN", "ERROR" }
  local line = ("%s [%s] %s\n"):format(os.date("%Y-%m-%d %H:%M:%S"), names[level] or "?", msg)
  local ok, fd = pcall(io.open, logfile(), "a")
  if ok and fd then
    fd:write(line)
    fd:close()
  end
end

---@return ssh_launcher.Config|nil
local function settings()
  local cfg = package.loaded["ssh_launcher.config"]
  if cfg and cfg.get then
    return cfg.get()
  end
  return nil
end

--- Mask targets in user-facing text.
---
--- `:messages` is copied into bug reports and shared screens, and a fleet's
--- internal hostnames are worth as much to an attacker as its topology map.
--- Enough of each name is kept to tell two hosts apart.
---@param msg string
---@return string
function M.redact(msg)
  local cfg = settings()
  if not cfg or not cfg.security.redact_in_logs then
    return msg
  end

  local function mask(word)
    if #word <= 2 then
      return word:sub(1, 1) .. "…"
    end
    return word:sub(1, 1) .. ("…"):rep(1) .. word:sub(-1)
  end

  -- user@host first, so the host half is not masked twice.
  msg = msg:gsub("([%w%._%-]+)@([%w%.%-]+)", function(user, host)
    return mask(user) .. "@" .. mask(host)
  end)
  msg = msg:gsub("(%d+)%.(%d+)%.(%d+)%.(%d+)", function(a)
    return a .. ".x.x.x"
  end)
  return msg
end

---@param msg string
---@param level integer|nil
---@param opts table|nil
function M.notify(msg, level, opts)
  level = level or vim.log.levels.INFO
  msg = M.redact(msg)
  to_file(level, msg)
  if level < M.level then
    return
  end
  vim.schedule(function()
    vim.notify(msg, level, vim.tbl_extend("keep", opts or {}, { title = TITLE, icon = "" }))
  end)
end

function M.trace(msg)
  M.notify(msg, vim.log.levels.TRACE)
end

function M.debug(msg)
  M.notify(msg, vim.log.levels.DEBUG)
end

function M.info(msg)
  M.notify(msg, vim.log.levels.INFO)
end

function M.warn(msg)
  M.notify(msg, vim.log.levels.WARN)
end

function M.error(msg)
  M.notify(msg, vim.log.levels.ERROR)
end

--- Emit a message that assistive technology reads immediately.
---
--- `vim.notify` is frequently replaced by float-based UIs that screen readers
--- never see. When `a11y.announce` is on we additionally echo to the message
--- area, which is the one surface every screen reader observes.
---@param msg string
---@param hl string|nil
function M.announce(msg, hl)
  local cfg = settings()
  if cfg and not cfg.a11y.announce then
    return
  end
  local text = M.redact(msg)
  vim.schedule(function()
    vim.api.nvim_echo({ { text, hl or "None" } }, false, {})
  end)
end

--- Report an internal failure without ever destroying the user's editing
--- session: errors are surfaced, not raised.
---@param ok boolean
---@param err any
---@param context string
---@return boolean ok
function M.report(ok, err, context)
  if ok then
    return true
  end
  M.error(("%s: %s"):format(context, tostring(err)))
  return false
end

--- pcall wrapper that reports and swallows.
---@param fn function
---@param context string
---@return boolean ok, any result
function M.safe(fn, context, ...)
  local res = { pcall(fn, ...) }
  if not res[1] then
    M.error(("%s: %s"):format(context, tostring(res[2])))
    return false, nil
  end
  return true, res[2]
end

return M
