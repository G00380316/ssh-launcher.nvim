---@mod ssh_launcher.ui.manager Host manager
---
--- The main window: every saved host, its health, and one keystroke to each
--- action. Rows are plain text — the icons and colours are decoration on top of
--- information that is already readable without them.

local util = require("ssh_launcher.util")
local log = require("ssh_launcher.log")
local config = require("ssh_launcher.config")
local Host = require("ssh_launcher.host")
local store = require("ssh_launcher.store")
local diagnostics = require("ssh_launcher.diagnostics")
local probe = require("ssh_launcher.probe")
local keys = require("ssh_launcher.keys")
local agent = require("ssh_launcher.agent")
local connect = require("ssh_launcher.connect")
local sshconfig = require("ssh_launcher.sshconfig")
local parser = require("ssh_launcher.parser")
local theme = require("ssh_launcher.ui.theme")
local float = require("ssh_launcher.ui.float")
local render = require("ssh_launcher.ui.render")
local dialog = require("ssh_launcher.ui.dialog")

local M = {}

local ns = vim.api.nvim_create_namespace("ssh_launcher_manager")
local preview_ns = vim.api.nvim_create_namespace("ssh_launcher_preview")

---@class ssh_launcher.Manager
local Manager = {}
Manager.__index = Manager

---@type ssh_launcher.Manager|nil
local instance = nil

--------------------------------------------------------------------------------
-- Row model
--------------------------------------------------------------------------------

---@param h ssh_launcher.Host
---@return string status, string severity
local function status_of(h, issues)
  local worst = diagnostics.worst(issues)
  if worst == "error" then
    return "error", "error"
  end
  local p = probe.cached(h.host, h.port)
  if p then
    return p.status, worst or "none"
  end
  return "unknown", worst or "none"
end

local STATUS_MARKER = {
  error = "err",
  up = "up",
  refused = "dn",
  timeout = "??",
  dns = "dn",
  unknown = "  ",
  checking = "..",
}

---@param h ssh_launcher.Host
---@return string
local function key_cell(h)
  if util.blank(h.identity_file) then
    return "agent"
  end
  return util.basename(util.expand(h.identity_file))
end

--------------------------------------------------------------------------------
-- Manager
--------------------------------------------------------------------------------

function Manager:load()
  local all = store.all({ external = self.show_external })
  self.all_hosts = all

  local filtered = all
  if self.filter ~= "" then
    local needle = self.filter:lower()
    filtered = vim.tbl_filter(function(h)
      return Host.search_text(h):find(needle, 1, true) ~= nil
    end, all)
  end

  self.hosts = store.sorted(filtered, self.sort)

  -- Diagnostics are cached per host id: they are cheap but not free, and the
  -- list redraws on every cursor move.
  self.issues_by_id = self.issues_by_id or {}
  for _, h in ipairs(self.hosts) do
    if self.issues_by_id[h.id] == nil then
      self.issues_by_id[h.id] = diagnostics.check(h, { hosts = all })
    end
  end
end

---@return integer[] widths
function Manager:columns()
  local width = self.win:valid() and vim.api.nvim_win_get_width(self.win.win) or 80
  local a11y = config.get().a11y
  local avail = width - 2

  local cols = {
    status = a11y.text_markers and 6 or 3,
    mark = 2,
    last = 6,
    key = 14,
    tags = 18,
  }

  local enabled = {}
  for _, name in ipairs(config.get().ui.columns) do
    enabled[name] = true
  end

  local fixed = cols.mark + (enabled.status and cols.status or 0)
  local optional_order = { "tags", "key", "last" }
  local used = {}
  for _, name in ipairs(optional_order) do
    if enabled[name] then
      used[name] = true
      fixed = fixed + cols[name] + 1
    end
  end

  -- Shed optional columns until name+target have room to breathe.
  local min_flex = 40
  for _, name in ipairs({ "tags", "key", "last" }) do
    if avail - fixed < min_flex and used[name] then
      used[name] = false
      fixed = fixed - cols[name] - 1
    end
  end

  local flex = math.max(avail - fixed, 24)
  local name_w = math.max(14, math.floor(flex * 0.42))
  local target_w = math.max(10, flex - name_w - 1)

  return {
    status = enabled.status and cols.status or 0,
    name = name_w,
    target = target_w,
    key = used.key and cols.key or 0,
    tags = used.tags and cols.tags or 0,
    last = used.last and cols.last or 0,
  }
end

---@param h ssh_launcher.Host
---@param widths table
---@return ssh_launcher.Line
function Manager:row(h, widths)
  local issues = self.issues_by_id[h.id] or {}
  local status = status_of(h, issues)
  local marked = self.marks[h.id] == true
  local a11y = config.get().a11y

  local chunks = {}

  chunks[#chunks + 1] = {
    marked and (theme.icon("marked") .. " ") or "  ",
    marked and theme.hl("Marked") or theme.hl("Muted"),
  }

  if widths.status > 0 then
    local icon_name = status == "error" and "error" or (theme.STATUS_ICON[status] or "unknown")
    local hl = theme.hl(status == "error" and "Error" or (theme.STATUS_HL[status] or "Muted"))
    local cell = theme.icon(icon_name)
    if a11y.text_markers then
      cell = cell .. " " .. util.pad(STATUS_MARKER[status] or "  ", 3)
    end
    chunks[#chunks + 1] = { util.fit(cell, widths.status), hl }
  end

  local name_hl = theme.hl("Name")
  if h.readonly then
    name_hl = theme.hl("ReadOnly")
  elseif Host.is_production(h) then
    name_hl = theme.hl("Production")
  end

  local name = Host.label(h)
  if Host.is_production(h) then
    name = theme.icon("production") .. " " .. name
  end
  if h.readonly then
    name = name .. " " .. theme.icon("readonly")
  end
  chunks[#chunks + 1] = { util.fit(name, widths.name) .. " ", name_hl }
  chunks[#chunks + 1] = { util.fit(Host.target(h), widths.target) .. " ", theme.hl("Target") }

  if widths.key > 0 then
    local cell = key_cell(h)
    local hl = theme.hl("Key")
    for _, issue in ipairs(issues) do
      if issue.field == "identity_file" and issue.severity == "error" then
        hl = theme.hl("Error")
        break
      end
    end
    chunks[#chunks + 1] = { util.fit(cell, widths.key) .. " ", hl }
  end

  if widths.tags > 0 then
    local tags = table.concat(h.tags or {}, ",")
    chunks[#chunks + 1] = { util.fit(tags, widths.tags) .. " ", theme.hl("Tag") }
  end

  if widths.last > 0 then
    chunks[#chunks + 1] = { util.fit(util.ago(h.last_used_at), widths.last, "right"), theme.hl("Muted") }
  end

  return chunks
end

function Manager:draw()
  if not self.win:valid() then
    return
  end
  local widths = self:columns()
  local lines = {}
  self.line_to_host = {}

  local header = {}
  header[#header + 1] = { "  ", theme.hl("Muted") }
  if widths.status > 0 then
    header[#header + 1] = { util.fit("", widths.status), theme.hl("Header") }
  end
  header[#header + 1] = { util.fit("NAME", widths.name) .. " ", theme.hl("Header") }
  header[#header + 1] = { util.fit("TARGET", widths.target) .. " ", theme.hl("Header") }
  if widths.key > 0 then
    header[#header + 1] = { util.fit("KEY", widths.key) .. " ", theme.hl("Header") }
  end
  if widths.tags > 0 then
    header[#header + 1] = { util.fit("TAGS", widths.tags) .. " ", theme.hl("Header") }
  end
  if widths.last > 0 then
    header[#header + 1] = { util.fit("USED", widths.last, "right"), theme.hl("Header") }
  end
  lines[#lines + 1] = header

  if #self.hosts == 0 then
    lines[#lines + 1] = { { "" } }
    if self.filter ~= "" then
      lines[#lines + 1] = { { ("  Nothing matches %q."):format(self.filter), theme.hl("Muted") } }
      lines[#lines + 1] = { { "  Press <Esc> to clear the filter.", theme.hl("Muted") } }
    else
      lines[#lines + 1] = { { "  No hosts saved yet.", theme.hl("Value") } }
      lines[#lines + 1] = { { "" } }
      lines[#lines + 1] = {
        { "  a", theme.hl("KeyHint") },
        { "  add one by hand", theme.hl("Muted") },
      }
      lines[#lines + 1] = {
        { "  p", theme.hl("KeyHint") },
        { "  paste an ssh command from the clipboard", theme.hl("Muted") },
      }
      lines[#lines + 1] = {
        { "  i", theme.hl("KeyHint") },
        { "  import everything from ~/.ssh/config", theme.hl("Muted") },
      }
    end
  else
    for i, h in ipairs(self.hosts) do
      lines[#lines + 1] = self:row(h, widths)
      self.line_to_host[i + 1] = h
    end
  end

  render.draw(self.win.buf, ns, lines)
  if self.filter ~= "" then
    render.highlight_matches(self.win.buf, ns, self.filter, theme.hl("Match"))
  end

  local total = #self.all_hosts
  local title = ("Hosts  %d"):format(#self.hosts)
  if #self.hosts ~= total then
    title = ("Hosts  %d/%d"):format(#self.hosts, total)
  end
  if self.filter ~= "" then
    title = title .. ("   %s%s"):format(theme.icon("search"), self.filter)
  end
  local marked = vim.tbl_count(self.marks)
  if marked > 0 then
    title = title .. ("   %d marked"):format(marked)
  end
  self.win:set_title(title)

  local footer = ("sort: %s  ·  <CR> connect  a add  p paste  e edit  d delete  / filter  ? help"):format(self.sort)
  self.win:set_footer(footer)
end

---@return ssh_launcher.Host|nil
function Manager:current()
  if not self.win:valid() then
    return nil
  end
  local lnum = vim.api.nvim_win_get_cursor(self.win.win)[1]
  return self.line_to_host and self.line_to_host[lnum] or nil
end

---@return ssh_launcher.Host[]
function Manager:targets()
  local marked = {}
  for _, h in ipairs(self.hosts) do
    if self.marks[h.id] then
      marked[#marked + 1] = h
    end
  end
  if #marked > 0 then
    return marked
  end
  local current = self:current()
  return current and { current } or {}
end

--------------------------------------------------------------------------------
-- Preview
--------------------------------------------------------------------------------

function Manager:draw_preview()
  if not self.preview or not self.preview:valid() then
    return
  end
  local h = self:current()
  local lines = {}

  if not h then
    lines[#lines + 1] = { { "  Select a host to see its details.", theme.hl("Muted") } }
  else
    local issues = self.issues_by_id[h.id] or {}
    local p = probe.cached(h.host, h.port)

    lines[#lines + 1] = {
      { "  " .. Host.label(h), theme.hl("Name") },
      { "  " .. Host.target(h), theme.hl("Target") },
    }

    local facts = {}
    facts[#facts + 1] = ("source: %s"):format(h.origin or h.source)
    if h.identity_file then
      local info = keys.info(h.identity_file)
      facts[#facts + 1] = ("key: %s%s"):format(
        util.contract(h.identity_file),
        info.exists and (info.type and (" (" .. info.type .. ")") or "") or " (missing)"
      )
    else
      facts[#facts + 1] = "key: from ssh-agent / ssh_config"
    end
    if h.proxy_jump then
      facts[#facts + 1] = ("via: %s"):format(h.proxy_jump)
    end
    if h.forwards and #h.forwards > 0 then
      facts[#facts + 1] = ("forwards: %s"):format(Host.forwards_to_string(h.forwards))
    end
    facts[#facts + 1] = ("used: %s (%d time%s)"):format(
      util.datetime(h.last_used_at),
      h.use_count or 0,
      (h.use_count or 0) == 1 and "" or "s"
    )
    if p then
      local detail = p.status == "up" and ("%s, %dms"):format(probe.LABEL.up, p.latency_ms or 0)
        or probe.LABEL[p.status]
      facts[#facts + 1] = ("network: %s"):format(detail or p.status)
    end
    lines[#lines + 1] = { { "  " .. table.concat(facts, "   ·   "), theme.hl("Muted") } }

    lines[#lines + 1] = { { "" } }
    lines[#lines + 1] = {
      { "  $ ", theme.hl("Muted") },
      { Host.command_string(h), theme.hl("Value") },
    }

    if #issues > 0 then
      lines[#lines + 1] = { { "" } }
      local shown = 0
      for _, issue in ipairs(issues) do
        if shown >= 4 then
          break
        end
        shown = shown + 1
        local hl = theme.hl(theme.SEVERITY_HL[issue.severity] or "Info")
        lines[#lines + 1] = {
          { "  " .. theme.icon(theme.SEVERITY_ICON[issue.severity] or "info") .. " ", hl },
          { theme.word(issue.severity) .. ": ", hl },
          { issue.message, theme.hl("Value") },
          { issue.fix and "   [f fixes this]" or "", theme.hl("KeyHint") },
        }
      end
      if #issues > shown then
        lines[#lines + 1] = { { ("  … %d more — press D"):format(#issues - shown), theme.hl("Muted") } }
      end
    end
  end

  render.draw(self.preview.buf, preview_ns, lines)
end

--------------------------------------------------------------------------------
-- Actions
--------------------------------------------------------------------------------

function Manager:refresh(opts)
  opts = opts or {}
  if opts.reload then
    store.reset()
    store.invalidate_external()
    sshconfig.invalidate()
    keys.invalidate()
    self.issues_by_id = {}
  end
  local line = self.win:valid() and vim.api.nvim_win_get_cursor(self.win.win)[1] or 2
  self:load()
  self:draw()
  self.win:set_cursor(math.min(line, #self.hosts + 1))
  self:draw_preview()
end

function Manager:invalidate_host(id)
  if id then
    self.issues_by_id[id] = nil
  else
    self.issues_by_id = {}
  end
end

function Manager:probe_all(force)
  if not config.get().diagnostics.check_reachability then
    return
  end
  local pending = self.hosts
  if #pending == 0 then
    return
  end
  local redraw = util.debounce(function()
    if self.win:valid() then
      self:draw()
      self:draw_preview()
    end
  end, 120)

  probe.check_many(pending, {
    force = force,
    on_each = function()
      redraw()
    end,
  }, function()
    redraw()
  end)
end

--- Incremental filtering. Reading keys directly keeps the list updating on
--- every keystroke, which `vim.ui.input` cannot do.
function Manager:filter_interactive()
  local buffer = self.filter
  log.announce("filter: type to narrow, Enter to keep, Esc to cancel")

  while true do
    self.filter = buffer
    self:load()
    self:draw()
    self:draw_preview()
    self.win:set_footer(("%s%s│   <CR> keep   <Esc> cancel"):format(theme.icon("search"), buffer))
    vim.cmd("redraw")

    local ok, char = pcall(vim.fn.getcharstr)
    if not ok then
      break
    end

    if char == "\27" then -- Esc
      buffer = self.saved_filter or ""
      break
    elseif char == "\r" or char == "\n" then
      break
    elseif char == "\8" or char == "\127" or char == vim.keycode("<BS>") or char == "\128kb" then
      buffer = buffer:sub(1, -2)
    elseif char == vim.keycode("<C-u>") then
      buffer = ""
    elseif char == vim.keycode("<C-w>") then
      buffer = buffer:gsub("%S+%s*$", "")
    elseif #char == 1 and char:byte() >= 32 then
      buffer = buffer .. char
    elseif #char > 1 and char:byte() >= 32 then
      buffer = buffer .. char -- multibyte
    end
  end

  self.filter = buffer
  self.saved_filter = buffer
  self:load()
  self:draw()
  self:draw_preview()
  log.announce(buffer == "" and "filter cleared" or ("%d hosts match %s"):format(#self.hosts, buffer))
end

function Manager:choose_sort()
  dialog.choose({
    title = "Sort hosts by",
    default = util.index_of({ "frecency", "name", "recent", "host" }, self.sort) or 1,
    choices = {
      { label = "Most used and most recent", value = "frecency", key = "f" },
      { label = "Name", value = "name", key = "n" },
      { label = "Last connected", value = "recent", key = "r" },
      { label = "Address", value = "host", key = "h" },
    },
    on_choice = function(value)
      if value then
        self.sort = value
        self:refresh()
        log.announce("sorted by " .. value)
      end
    end,
  })
end

---@param strategy string|nil
function Manager:connect(strategy)
  local h = self:current()
  if not h then
    return
  end
  self.win:close()
  -- Let the window teardown settle before opening the session window, for the
  -- same reason the picker integrations defer: whatever restores the layout
  -- must finish before we add to it.
  vim.schedule(function()
    connect.connect(h, { strategy = strategy })
  end)
end

function Manager:add(paste)
  local form = require("ssh_launcher.ui.form")
  form.create({
    paste = paste,
    on_save = function(h)
      self:invalidate_host(h.id)
      self:refresh({ reload = true })
    end,
  })
end

function Manager:add_from_clipboard()
  local res, reg = parser.from_clipboard()
  if not res then
    log.info("nothing connection-shaped in the clipboard — opening an empty form")
    return self:add()
  end
  log.info(("found %s in register %s"):format(parser.describe(res), reg))
  self:add(vim.fn.getreg(reg))
end

function Manager:edit()
  local h = self:current()
  if not h then
    return
  end
  require("ssh_launcher.ui.form").edit(h, {
    on_save = function(saved)
      self:invalidate_host(saved.id)
      self:refresh({ reload = true })
    end,
  })
end

function Manager:duplicate()
  local h = self:current()
  if not h then
    return
  end
  local copy = Host.clone(h)
  local saved, err = store.add(copy)
  if not saved then
    return log.error(err or "could not duplicate")
  end
  self:refresh({ reload = true })
  log.info(("duplicated as %q"):format(saved.name))
end

function Manager:rename()
  local h = self:current()
  if not h or h.readonly then
    if h then
      log.warn("that host comes from ssh_config and cannot be renamed here")
    end
    return
  end
  dialog.input({ prompt = "New name: ", default = h.name }, function(name)
    if not name then
      return
    end
    store.update(h.id, { name = name })
    self:invalidate_host(h.id)
    self:refresh({ reload = true })
  end)
end

function Manager:delete()
  local targets = self:targets()
  if #targets == 0 then
    return
  end

  local deletable = vim.tbl_filter(function(h)
    return not h.readonly
  end, targets)
  local skipped = #targets - #deletable

  if #deletable == 0 then
    return log.warn("those hosts come from ssh_config; edit that file to remove them")
  end

  local function do_delete()
    local ids = vim.tbl_map(function(h)
      return h.id
    end, deletable)
    local removed = store.remove_many(ids)
    self.marks = {}
    self:invalidate_host()
    self:refresh({ reload = true })
    log.info(("deleted %d host%s"):format(removed, removed == 1 and "" or "s"))
    log.announce(("deleted %d hosts"):format(removed))
  end

  if not config.get().ui.confirm_delete then
    return do_delete()
  end

  local lines = {}
  for i, h in ipairs(deletable) do
    if i > 8 then
      lines[#lines + 1] = { { ("  … and %d more"):format(#deletable - 8), theme.hl("Muted") } }
      break
    end
    lines[#lines + 1] = {
      { "  " .. Host.label(h), theme.hl("Name") },
      { "  " .. Host.target(h), theme.hl("Muted") },
    }
  end
  if skipped > 0 then
    lines[#lines + 1] = { { ("  (%d read-only host(s) will be kept)"):format(skipped), theme.hl("Muted") } }
  end

  dialog.confirm({
    title = ("Delete %d host%s?"):format(#deletable, #deletable == 1 and "" or "s"),
    lines = lines,
    yes = "Delete",
    destructive = true,
    default_no = true,
  }, function(confirmed)
    if confirmed then
      do_delete()
    end
  end)
end

function Manager:toggle_mark()
  local h = self:current()
  if not h then
    return
  end
  self.marks[h.id] = not self.marks[h.id] or nil
  self:draw()
  local line = vim.api.nvim_win_get_cursor(self.win.win)[1]
  self.win:set_cursor(line + 1)
end

function Manager:show_diagnostics()
  local h = self:current()
  if not h then
    return
  end
  local diag_ns = vim.api.nvim_create_namespace("ssh_launcher_diag_view")
  local issues = diagnostics.check(h, { hosts = self.all_hosts })
  local win

  ---@return ssh_launcher.Line[] lines, ssh_launcher.Issue[] fixable
  local function build()
    local lines = {}
    local fixable = {}

    lines[#lines + 1] = { { Host.label(h), theme.hl("Name") }, { "   " .. Host.target(h), theme.hl("Target") } }
    lines[#lines + 1] = { { "" } }

    if #issues == 0 then
      lines[#lines + 1] = { { theme.icon("ok") .. "  Nothing wrong with this host.", theme.hl("Ok") } }
    end

    for _, issue in ipairs(issues) do
      local hl = theme.hl(theme.SEVERITY_HL[issue.severity] or "Info")
      lines[#lines + 1] = {
        { theme.icon(theme.SEVERITY_ICON[issue.severity] or "info") .. "  ", hl },
        { theme.word(issue.severity):upper() .. "  ", hl },
        { issue.message, theme.hl("Value") },
        { "   " .. issue.code, theme.hl("Muted") },
      }
      if issue.detail then
        for line in (issue.detail .. "\n"):gmatch("(.-)\n") do
          if line ~= "" then
            lines[#lines + 1] = { { "     " .. line, theme.hl("Muted") } }
          end
        end
      end
      if issue.fix then
        fixable[#fixable + 1] = issue
        local n = #fixable
        lines[#lines + 1] = {
          { ("     [%d] "):format(n), theme.hl("KeyHint") },
          { issue.fix.label, theme.hl("KeyHint") },
          -- Say which repairs `f` will and will not perform, rather than
          -- leaving the user to discover it.
          { issue.fix.auto == false and "   (needs your confirmation)" or "", theme.hl("Muted") },
        }
      end
      lines[#lines + 1] = { { "" } }
    end

    return lines, fixable
  end

  local lines, fixable = build()

  local width = 0
  for _, line in ipairs(lines) do
    width = math.max(width, util.width((render.flatten(line))))
  end

  win = float.open({
    title = ("%s Diagnostics"):format(theme.icon("info")),
    footer = "1-9 apply one fix   f apply all safe fixes   q close",
    width = math.min(math.max(width + 6, 60), math.floor(vim.o.columns * 0.9)),
    height = math.min(#lines + 2, math.floor(vim.o.lines * 0.8)),
    cursorline = false,
  })
  render.draw(win.buf, diag_ns, lines)

  local function redraw()
    issues = diagnostics.check(h, { hosts = self.all_hosts })
    lines, fixable = build()
    render.draw(win.buf, diag_ns, lines)
  end

  for n = 1, 9 do
    win:map("n", tostring(n), function()
      local issue = fixable[n]
      if not issue then
        return
      end
      local patched, msg, applied = diagnostics.apply_fix(h, issue)
      if not applied then
        return log.error(msg)
      end
      log.info(msg)
      if not h.readonly and not vim.deep_equal(Host.serialize(patched), Host.serialize(h)) then
        store.update(h.id, patched)
        h = store.get(h.id) or patched
      end
      keys.invalidate()
      self:invalidate_host(h.id)
      self:load()
      self:draw()
      self:draw_preview()
      redraw()
    end, ("Apply fix %d"):format(n))
  end

  win:map("n", "f", function()
    win:close()
    self:autofix()
  end, "Apply every safe fix")

  -- Also check the network, then fold whatever it finds into the same view.
  diagnostics.check_async(h, function(extra)
    if #extra == 0 or not win:valid() then
      return
    end
    vim.list_extend(issues, extra)
    lines, fixable = build()
    render.draw(win.buf, diag_ns, lines)
  end)
end

function Manager:autofix()
  local targets = self:targets()
  if #targets == 0 then
    return
  end
  local total = 0
  for _, h in ipairs(targets) do
    local fixed, applied = diagnostics.autofix(h, { hosts = self.all_hosts })
    if #applied > 0 then
      total = total + #applied
      if not h.readonly then
        store.update(h.id, fixed)
      end
      log.info(("%s: %s"):format(Host.label(h), table.concat(applied, "; ")))
    end
  end
  if total == 0 then
    log.info("nothing to fix automatically")
  else
    log.announce(("applied %d fixes"):format(total))
  end
  keys.invalidate()
  self:invalidate_host()
  self:refresh({ reload = true })
end

function Manager:yank_command()
  local h = self:current()
  if not h then
    return
  end
  local cmd = Host.command_string(h)
  vim.fn.setreg("+", cmd)
  vim.fn.setreg('"', cmd)
  log.info("copied: " .. util.truncate(cmd, 60))
end

function Manager:import()
  dialog.choose({
    title = "Import hosts",
    choices = {
      { label = "From ~/.ssh/config", value = "sshconfig", key = "s" },
      { label = "From a JSON file", value = "json", key = "j" },
      { label = "From the clipboard", value = "clipboard", key = "c" },
    },
    on_choice = function(value)
      if value == "sshconfig" then
        local hosts = sshconfig.hosts(true)
        if #hosts == 0 then
          return log.warn("no hosts found in ~/.ssh/config")
        end
        local added, skipped = store.import(hosts)
        log.info(
          ("imported %d host%s from ssh_config (%d already known)"):format(added, added == 1 and "" or "s", skipped)
        )
        self:refresh({ reload = true })
      elseif value == "json" then
        dialog.input({ prompt = "JSON file: ", default = "", completion = "file" }, function(path)
          if not path then
            return
          end
          local raw = util.read_file(path)
          if not raw then
            return log.error(("cannot read %s"):format(path))
          end
          local hosts = parser.parse_many(raw)
          if #hosts == 0 then
            return log.error("no hosts found in that file")
          end
          local added, skipped = store.import(hosts)
          log.info(("imported %d host%s (%d duplicates skipped)"):format(added, added == 1 and "" or "s", skipped))
          self:refresh({ reload = true })
        end)
      elseif value == "clipboard" then
        local text = vim.fn.getreg("+")
        if util.blank(text) then
          text = vim.fn.getreg('"')
        end
        local hosts = parser.parse_many(text)
        if #hosts == 0 then
          return log.error("no hosts found in the clipboard")
        end
        local added, skipped = store.import(hosts)
        log.info(("imported %d host%s (%d duplicates skipped)"):format(added, added == 1 and "" or "s", skipped))
        self:refresh({ reload = true })
      end
    end,
  })
end

function Manager:export()
  local targets = self:targets()
  if #targets == 0 then
    targets = store.list()
  end

  dialog.choose({
    title = ("Export %d host%s"):format(#targets, #targets == 1 and "" or "s"),
    choices = {
      { label = "Into the managed block of ~/.ssh/config", value = "sshconfig", key = "s" },
      { label = "Preview the ssh_config block", value = "preview", key = "p" },
      { label = "To a JSON file", value = "json", key = "j" },
      { label = "To the clipboard as JSON", value = "clipboard", key = "c" },
    },
    on_choice = function(value)
      if value == "sshconfig" then
        dialog.confirm({
          title = "Write to ~/.ssh/config?",
          lines = {
            { { "Only the ssh-launcher managed block is rewritten;", theme.hl("Value") } },
            { { "everything else in the file is left untouched, and", theme.hl("Value") } },
            { { "a .ssh-launcher.bak copy is made first.", theme.hl("Value") } },
          },
          yes = "Write it",
        }, function(confirmed)
          if not confirmed then
            return
          end
          local ok = sshconfig.export(targets)
          if ok then
            log.info(("exported %d host%s to ~/.ssh/config"):format(#targets, #targets == 1 and "" or "s"))
            self:refresh({ reload = true })
          end
        end)
      elseif value == "preview" then
        local _, content = sshconfig.export(targets, { dry_run = true })
        local win = float.text(vim.split(content, "\n", { plain = true }), {
          title = "~/.ssh/config after export",
          width = 0.8,
          height = 0.8,
        })
        vim.bo[win.buf].filetype = "sshconfig"
      elseif value == "json" then
        dialog.input({ prompt = "Write JSON to: ", default = "hosts.json", completion = "file" }, function(path)
          if not path then
            return
          end
          local ok, err = util.write_file_atomic(path, store.export_json(targets), tonumber("600", 8))
          if ok then
            log.info(("wrote %s"):format(path))
          else
            log.error(("could not write %s: %s"):format(path, err or "?"))
          end
        end)
      elseif value == "clipboard" then
        local json = store.export_json(targets)
        vim.fn.setreg("+", json)
        vim.fn.setreg('"', json)
        log.info(("copied %d host%s as JSON"):format(#targets, #targets == 1 and "" or "s"))
      end
    end,
  })
end

function Manager:agent_menu()
  local loaded, err = agent.list_sync()
  local lines = { { { "  " .. agent.summary(), theme.hl("Value") } } }
  for _, k in ipairs(loaded or {}) do
    lines[#lines + 1] = {
      { "  " .. theme.icon("key") .. " ", theme.hl("Key") },
      { ("%s %s"):format(k.type or "?", util.truncate(k.comment, 40)), theme.hl("Value") },
    }
  end
  if err then
    lines[#lines + 1] = { { "  " .. err, theme.hl("Warn") } }
  end

  local current = self:current()
  local choices = {}
  if current and current.identity_file then
    choices[#choices + 1] = {
      label = ("Add %s"):format(util.contract(current.identity_file)),
      value = "add_current",
      key = "a",
    }
  end
  choices[#choices + 1] = { label = "Add another key…", value = "add", key = "o" }
  choices[#choices + 1] = { label = "Remove all identities", value = "clear", key = "r", destructive = true }
  choices[#choices + 1] = { label = "Close", value = nil, key = "c" }

  dialog.choose({
    title = ("%s ssh-agent"):format(theme.icon("key")),
    lines = lines,
    choices = choices,
    on_choice = function(value)
      if value == "add_current" then
        agent.add(current.identity_file, { apple_keychain = true }, function()
          self:invalidate_host()
          self:refresh()
        end)
      elseif value == "add" then
        local found = keys.discover()
        dialog.choose({
          title = "Add which key?",
          choices = vim.tbl_map(function(info)
            return { label = util.contract(info.path), value = info.path }
          end, found),
          on_choice = function(path)
            if path then
              agent.add(path, { apple_keychain = true })
            end
          end,
        })
      elseif value == "clear" then
        agent.remove(nil, function(ok, msg)
          if ok then
            log.info("removed every identity from the agent")
          else
            log.error(msg)
          end
        end)
      end
    end,
  })
end

function Manager:copy_id()
  local h = self:current()
  if not h then
    return
  end
  dialog.confirm({
    title = ("%s Install your key on %s?"):format(theme.icon("key"), Host.label(h)),
    lines = {
      { { "ssh-copy-id appends your public key to the remote", theme.hl("Value") } },
      { { "authorized_keys. It will ask for the remote password.", theme.hl("Value") } },
    },
    yes = "Run ssh-copy-id",
  }, function(confirmed)
    if confirmed then
      keys.copy_id(h, function(ok, msg)
        if ok then
          log.info(msg)
        else
          log.error(msg)
        end
      end)
    end
  end)
end

function Manager:keygen()
  dialog.input({ prompt = "New key path: ", default = "~/.ssh/id_ed25519", completion = "file" }, function(path)
    if not path then
      return
    end
    dialog.choose({
      title = "Key type",
      choices = {
        { label = "ed25519 (recommended)", value = "ed25519", key = "e" },
        { label = "ecdsa", value = "ecdsa", key = "c" },
        { label = "rsa 4096", value = "rsa", key = "r" },
      },
      on_choice = function(type_)
        if not type_ then
          return
        end
        keys.generate({
          path = path,
          type = type_,
          comment = ("%s@%s"):format(vim.env.USER or "user", vim.uv.os_gethostname()),
        }, function(ok, msg)
          if ok then
            log.info(msg)
          else
            log.error(msg)
          end
        end)
      end,
    })
  end)
end

--------------------------------------------------------------------------------
-- Construction
--------------------------------------------------------------------------------

---@param opts table|nil
---@return ssh_launcher.Manager
function M.open(opts)
  opts = opts or {}

  if instance and instance.win and instance.win:valid() then
    instance.win:focus()
    return instance
  end

  local self = setmetatable({}, Manager)
  instance = self

  local cfg = config.get()
  self.filter = opts.filter or ""
  self.saved_filter = self.filter
  self.sort = opts.sort or cfg.ui.sort
  self.marks = {}
  self.issues_by_id = {}
  self.show_external = cfg.ssh_config.include
  self.line_to_host = {}

  local use_preview = cfg.ui.preview and vim.o.lines >= 24
  local total_h = math.floor((vim.o.lines - vim.o.cmdheight - 1) * cfg.ui.height)
  local preview_h = use_preview and math.max(7, math.floor(total_h * 0.32)) or 0
  local list_h = total_h - preview_h - (use_preview and 3 or 0)
  local width = math.floor(vim.o.columns * cfg.ui.width)
  local col = math.floor((vim.o.columns - width) / 2)
  local row = math.max(0, math.floor(((vim.o.lines - vim.o.cmdheight - 1) - total_h) / 2))

  self.win = float.open({
    title = "Hosts",
    footer = "loading…",
    width = width,
    height = list_h,
    row = row,
    col = col,
    cursorline = true,
    close_keys = false,
    filetype = "ssh-launcher",
    on_close = function()
      if self.preview then
        self.preview:close()
      end
      if instance == self then
        instance = nil
      end
    end,
  })

  if use_preview then
    self.preview = float.open({
      title = "Details",
      width = width,
      height = preview_h,
      row = row + list_h + 2,
      col = col,
      enter = false,
      cursorline = false,
      close_keys = false,
      filetype = "ssh-launcher-preview",
      wrap = true,
    })
    -- The list owns the keyboard; the preview is a display surface only.
    vim.bo[self.preview.buf].modifiable = false
  end

  local group = vim.api.nvim_create_augroup("SshLauncherManager" .. self.win.buf, { clear = true })

  local preview_update = util.debounce(function()
    self:draw_preview()
  end, 40)

  vim.api.nvim_create_autocmd("CursorMoved", {
    group = group,
    buffer = self.win.buf,
    desc = "ssh-launcher: update the detail pane",
    callback = function()
      preview_update()
      local h = self:current()
      if h and config.get().a11y.announce then
        -- Screen readers announce the line itself; this adds the state that is
        -- otherwise only conveyed by an icon.
        local issues = self.issues_by_id[h.id] or {}
        local status = status_of(h, issues)
        vim.api.nvim_echo({
          { ("%s  %s  %s"):format(Host.label(h), Host.target(h), probe.LABEL[status] or status), "None" },
        }, false, {})
      end
    end,
  })

  vim.api.nvim_create_autocmd("VimResized", {
    group = group,
    callback = function()
      vim.schedule(function()
        if self.win:valid() then
          self:draw()
          self:draw_preview()
        end
      end)
    end,
  })

  store.on_change("manager", function()
    if self.win:valid() then
      self:invalidate_host()
      self:load()
      self:draw()
    end
  end)

  local km = cfg.keymaps
  local map = function(lhs, fn, desc)
    self.win:map("n", lhs, fn, desc)
  end

  map(km.connect, function()
    self:connect()
  end, "Connect")
  map(km.connect_split, function()
    self:connect("split")
  end, "Connect in a split")
  map(km.connect_vsplit, function()
    self:connect("vsplit")
  end, "Connect in a vertical split")
  map(km.connect_tab, function()
    self:connect("tab")
  end, "Connect in a tab")

  map(km.add, function()
    self:add()
  end, "Add a host")
  map(km.paste_add, function()
    self:add_from_clipboard()
  end, "Add from the clipboard")
  map(km.edit, function()
    self:edit()
  end, "Edit")
  map(km.duplicate, function()
    self:duplicate()
  end, "Duplicate")
  map(km.rename, function()
    self:rename()
  end, "Rename")
  map(km.delete, function()
    self:delete()
  end, "Delete")
  map(km.toggle_mark, function()
    self:toggle_mark()
  end, "Mark")
  map(km.clear_marks, function()
    self.marks = {}
    self:draw()
  end, "Clear marks")

  map(km.diagnose, function()
    self:show_diagnostics()
  end, "Diagnose")
  map(km.fix, function()
    self:autofix()
  end, "Fix")
  map(km.probe, function()
    log.info("checking reachability…")
    self:probe_all(true)
  end, "Re-probe")
  map(km.agent, function()
    self:agent_menu()
  end, "ssh-agent")
  map(km.copy_id, function()
    self:copy_id()
  end, "ssh-copy-id")
  map(km.keygen, function()
    self:keygen()
  end, "Generate a key")

  map(km.filter, function()
    self:filter_interactive()
  end, "Filter")
  map(km.clear_filter, function()
    if self.filter ~= "" then
      self.filter = ""
      self.saved_filter = ""
      self:refresh()
    else
      self.win:close()
    end
  end, "Clear filter or close")
  map(km.sort, function()
    self:choose_sort()
  end, "Sort")
  map(km.refresh, function()
    self:refresh({ reload = true })
    self:probe_all(true)
    log.info("reloaded")
  end, "Reload")
  map(km.import, function()
    self:import()
  end, "Import")
  map(km.export, function()
    self:export()
  end, "Export")
  map(km.yank_command, function()
    self:yank_command()
  end, "Copy the ssh command")
  map(km.sessions, function()
    connect.pick_session()
  end, "Sessions")
  map(km.open_terminal, function()
    self.win:close()
    require("ssh_launcher.terminal").run({ vim.env.SHELL or "sh" }, { title = "shell" })
  end, "Local terminal")
  map(km.help, function()
    require("ssh_launcher.ui.help").show("manager")
  end, "Help")
  map(km.quit, function()
    self.win:close()
  end, "Close")

  self:load()
  self:draw()
  self.win:set_cursor(2)
  self:draw_preview()
  self:probe_all(false)

  log.announce(("host manager: %d hosts. Press ? for help."):format(#self.hosts))
  return self
end

function M.close()
  if instance and instance.win then
    instance.win:close()
  end
end

---@return ssh_launcher.Manager|nil
function M.instance()
  return instance
end

return M
