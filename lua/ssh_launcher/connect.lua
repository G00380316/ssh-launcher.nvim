---@mod ssh_launcher.connect Launching and tracking sessions
---
--- The path from "a saved host" to "a live shell", with three gates in front of
--- it: misconfiguration is caught before ssh is even started, production hosts
--- ask for confirmation, and an already-open session is reused rather than
--- dialled twice.

local util = require("ssh_launcher.util")
local log = require("ssh_launcher.log")
local config = require("ssh_launcher.config")
local Host = require("ssh_launcher.host")
local store = require("ssh_launcher.store")
local diagnostics = require("ssh_launcher.diagnostics")
local terminal = require("ssh_launcher.terminal")
local history = require("ssh_launcher.history")
local theme = require("ssh_launcher.ui.theme")
local dialog = require("ssh_launcher.ui.dialog")

local M = {}

---@class ssh_launcher.Session
---@field id string
---@field host ssh_launcher.Host
---@field handle ssh_launcher.TerminalHandle
---@field started_at integer
---@field ended_at integer|nil
---@field exit_code integer|nil

---@type table<string, ssh_launcher.Session>
local sessions = {}

local session_seq = 0

--------------------------------------------------------------------------------
-- Session registry
--------------------------------------------------------------------------------

---@return ssh_launcher.Session[]
function M.sessions()
  local out = {}
  for _, s in pairs(sessions) do
    out[#out + 1] = s
  end
  table.sort(out, function(a, b)
    return a.started_at > b.started_at
  end)
  return out
end

---@return ssh_launcher.Session[]
function M.live_sessions()
  return vim.tbl_filter(function(s)
    return s.ended_at == nil and terminal.is_running(s.handle)
  end, M.sessions())
end

---@param host_id string
---@return ssh_launcher.Session|nil
function M.session_for(host_id)
  for _, s in pairs(sessions) do
    if s.host.id == host_id and s.ended_at == nil and terminal.is_running(s.handle) then
      return s
    end
  end
  return nil
end

---@param id string
function M.close_session(id)
  local s = sessions[id]
  if not s then
    return false
  end
  terminal.close(s.handle)
  sessions[id] = nil
  return true
end

function M.prune_sessions()
  for id, s in pairs(sessions) do
    if s.ended_at and not vim.api.nvim_buf_is_valid(s.handle.buf) then
      sessions[id] = nil
    end
  end
end

--------------------------------------------------------------------------------
-- Pre-flight
--------------------------------------------------------------------------------

---@param issues ssh_launcher.Issue[]
---@return ssh_launcher.Line[]
local function issue_lines(issues)
  local lines = {}
  for _, issue in ipairs(issues) do
    local hl = theme.hl(theme.SEVERITY_HL[issue.severity] or "Info")
    lines[#lines + 1] = {
      { "  " .. theme.icon(theme.SEVERITY_ICON[issue.severity] or "info") .. " ", hl },
      -- The severity word is spelled out; the glyph alone would be invisible
      -- to anyone not seeing colour.
      { ("%s: "):format(theme.word(issue.severity)), hl },
      { issue.message, theme.hl("Value") },
      { ("  (%s)"):format(issue.code), theme.hl("Muted") },
    }
    if issue.detail then
      for detail_line in (issue.detail .. "\n"):gmatch("(.-)\n") do
        if detail_line ~= "" then
          lines[#lines + 1] = { { "      " .. detail_line, theme.hl("Muted") } }
        end
      end
    end
  end
  return lines
end

---@param h ssh_launcher.Host
---@param opts table
---@param proceed fun(host: ssh_launcher.Host)
local function gate_diagnostics(h, opts, proceed)
  local cfg = config.get()
  local mode = opts.diagnostics_mode or cfg.diagnostics.on_connect

  if opts.force or mode == "off" or not cfg.diagnostics.enable then
    return proceed(h)
  end

  local issues = diagnostics.check(h)
  local errors = vim.tbl_filter(function(i)
    return i.severity == "error"
  end, issues)

  if #errors == 0 then
    local warns = vim.tbl_filter(function(i)
      return i.severity == "warn"
    end, issues)
    if #warns > 0 and mode == "warn" then
      log.warn(("%s: %s"):format(Host.label(h), diagnostics.summary(issues)))
    end
    return proceed(h)
  end

  if mode == "warn" then
    log.warn(("%s has %d problem(s); connecting anyway"):format(Host.label(h), #errors))
    return proceed(h)
  end

  local fixable = false
  for _, issue in ipairs(errors) do
    if issue.fix then
      fixable = true
      break
    end
  end

  local lines = {
    { { ("%s cannot be dialled as configured:"):format(Host.label(h)), theme.hl("Value") } },
    { { "" } },
  }
  vim.list_extend(lines, issue_lines(issues))

  local choices = {}
  if fixable then
    choices[#choices + 1] = { label = "Fix the problems, then connect", value = "fix", key = "f" }
  end
  choices[#choices + 1] = { label = "Edit this host", value = "edit", key = "e" }
  choices[#choices + 1] = { label = "Connect anyway", value = "force", key = "a" }
  choices[#choices + 1] = { label = "Cancel", value = nil, key = "c" }

  dialog.choose({
    title = ("%s  %s"):format(theme.icon("error"), diagnostics.summary(issues)),
    lines = lines,
    choices = choices,
    on_choice = function(value)
      if value == "fix" then
        local fixed, applied = diagnostics.autofix(h)
        if #applied > 0 then
          log.info("applied: " .. table.concat(applied, "; "))
          if not h.readonly and h.source == "store" then
            store.update(h.id, fixed)
          end
        end
        local remaining = diagnostics.check(fixed)
        local still_broken = vim.tbl_filter(function(i)
          return i.severity == "error"
        end, remaining)
        if #still_broken > 0 then
          log.error(("still %d unresolved problem(s); opening the editor"):format(#still_broken))
          return require("ssh_launcher.ui.form").edit(fixed)
        end
        return proceed(fixed)
      elseif value == "edit" then
        return require("ssh_launcher.ui.form").edit(h)
      elseif value == "force" then
        return proceed(h)
      end
    end,
  })
end

---@param h ssh_launcher.Host
---@param opts table
---@param proceed fun(host: ssh_launcher.Host)
local function gate_production(h, opts, proceed)
  local cfg = config.get()
  if opts.force or not cfg.security.confirm_production or not Host.is_production(h) then
    return proceed(h)
  end

  dialog.confirm({
    title = ("%s Production host"):format(theme.icon("production")),
    lines = {
      { { ("You are about to open a shell on %s."):format(Host.label(h)), theme.hl("Value") } },
      { { ("Target: %s"):format(Host.target(h)), theme.hl("Target") } },
      { { "" } },
      { { "This host is tagged as production.", theme.hl("Warn") } },
    },
    yes = "Connect to production",
    no = "Cancel",
    destructive = true,
    default_no = true,
  }, function(confirmed)
    if confirmed then
      proceed(h)
    else
      log.info("cancelled")
    end
  end)
end

---@param h ssh_launcher.Host
---@param opts table
---@param proceed fun(host: ssh_launcher.Host)
local function gate_reuse(h, opts, proceed)
  local cfg = config.get()
  if opts.new or not cfg.terminal.reuse then
    return proceed(h)
  end
  local existing = M.session_for(h.id)
  if not existing then
    return proceed(h)
  end

  dialog.choose({
    title = ("%s Already connected"):format(theme.icon("session")),
    lines = {
      {
        {
          ("A session to %s has been open for %s."):format(Host.label(h), util.ago(existing.started_at)),
          theme.hl("Value"),
        },
      },
    },
    choices = {
      { label = "Go to that session", value = "focus", key = "g" },
      { label = "Open a second connection", value = "new", key = "n" },
      { label = "Cancel", value = nil, key = "c" },
    },
    on_choice = function(value)
      if value == "focus" then
        terminal.focus(existing.handle, opts.strategy)
      elseif value == "new" then
        proceed(h)
      end
    end,
  })
end

--------------------------------------------------------------------------------
-- Launch
--------------------------------------------------------------------------------

---@param h ssh_launcher.Host
---@param opts table
local function launch(h, opts)
  local argv = Host.build_argv(h, { extra_args = opts.extra_args })
  log.debug("exec: " .. table.concat(argv, " "))

  session_seq = session_seq + 1
  local id = ("s%d"):format(session_seq)
  local started = util.now()

  local handle = terminal.run(argv, {
    title = Host.label(h),
    strategy = opts.strategy,
    height = opts.height,
    on_exit = function(code)
      local session = sessions[id]
      if session then
        session.ended_at = util.now()
        session.exit_code = code
      end
      history.record({
        host_id = h.id,
        name = Host.label(h),
        target = Host.target(h),
        outcome = code == 0 and "closed" or "failed",
        exit_code = code,
        duration = util.now() - started,
      })
      if code ~= 0 then
        -- ssh's own exit codes are famously unhelpful; translate the common ones.
        local explain = {
          [255] = "ssh could not establish the connection (auth failure, unreachable host, or a bad option)",
          [130] = "interrupted",
        }
        if explain[code] then
          log.warn(("%s: %s"):format(Host.label(h), explain[code]))
        end
      end
    end,
  })

  if not handle then
    history.record({
      host_id = h.id,
      name = Host.label(h),
      target = Host.target(h),
      outcome = "failed",
    })
    return
  end

  sessions[id] = { id = id, host = h, handle = handle, started_at = started }

  if h.source == "store" then
    store.touch(h.id)
  end
  history.record({
    host_id = h.id,
    name = Host.label(h),
    target = Host.target(h),
    outcome = "started",
  })
  log.announce(("connecting to %s"):format(Host.target(h)))
end

---@class ssh_launcher.ConnectOpts
---@field strategy string|nil window placement override
---@field force boolean|nil skip every gate
---@field new boolean|nil always open a fresh session
---@field extra_args string[]|nil
---@field diagnostics_mode string|nil

--- Connect to a host, running the pre-flight gates first.
---@param h ssh_launcher.Host
---@param opts ssh_launcher.ConnectOpts|nil
function M.connect(h, opts)
  opts = opts or {}
  if not h then
    log.error("no host given")
    return
  end
  if util.blank(h.host) then
    log.error(("%s has no address"):format(Host.label(h)))
    return
  end

  gate_reuse(h, opts, function(h1)
    gate_diagnostics(h1, opts, function(h2)
      gate_production(h2, opts, function(h3)
        launch(h3, opts)
      end)
    end)
  end)
end

--- Connect by saved name (used by `:Ssh connect <name>`).
---@param name string
---@param opts ssh_launcher.ConnectOpts|nil
function M.connect_by_name(name, opts)
  local h = store.get_by_name(name)
  if not h then
    log.error(("no saved host matches %q"):format(name))
    return
  end
  M.connect(h, opts)
end

--- Connect to an ad-hoc target parsed from text, without saving it.
---@param text string
---@param opts ssh_launcher.ConnectOpts|nil
function M.connect_text(text, opts)
  local parser = require("ssh_launcher.parser")
  local res = parser.parse(text)
  if not res or util.blank(res.host.host) then
    log.error(("could not read a connection out of %q"):format(util.truncate(text, 40)))
    return
  end
  for _, warning in ipairs(res.warnings) do
    log.warn(warning)
  end
  local h = Host.normalize(res.host)
  h.source = "store"
  h.id = "adhoc:" .. h.id
  M.connect(h, opts)
end

--- Show open sessions and jump to one.
function M.pick_session()
  M.prune_sessions()
  local live = M.live_sessions()
  if #live == 0 then
    log.info("no open ssh sessions")
    return
  end
  dialog.choose({
    title = ("%s Open sessions"):format(theme.icon("session")),
    choices = vim.tbl_map(function(s)
      return {
        label = Host.label(s.host),
        value = s.id,
        desc = ("%s · open %s"):format(Host.target(s.host), util.ago(s.started_at)),
      }
    end, live),
    on_choice = function(id)
      if not id then
        return
      end
      local s = sessions[id]
      if s then
        terminal.focus(s.handle)
      end
    end,
  })
end

return M
