---@mod ssh_launcher.ui.commander Two-pane file transfer
---
--- This machine on the left, a saved host on the right. Browse either side,
--- select files with `<Space>`, and `c` copies them to whatever directory the
--- other pane is showing: from the local pane that is an upload, from the remote
--- pane a download. Nothing is typed unless you want to jump somewhere.
---
--- Transfers run in the background and report in the status line, so both
--- directories stay visible and usable while they go. Because they cannot ask
--- for a passphrase, a locked key is unlocked when the window opens — the same
--- rule as the remote file browser.
---
--- Which way a copy goes is always on screen: the active pane is titled FROM
--- and the other TO, and the line under them spells out what `c` would do —
--- "Upload a.txt  ~/proj -> box:/srv/app" — before it is pressed.
---
--- Everything on screen is buffer text: `[x]` marks a selection, a leading
--- arrow marks the active pane. Colour only adds emphasis.

local util = require("ssh_launcher.util")
local log = require("ssh_launcher.log")
local Host = require("ssh_launcher.host")
local config = require("ssh_launcher.config")
local remote = require("ssh_launcher.remote")
local render = require("ssh_launcher.ui.render")
local theme = require("ssh_launcher.ui.theme")
local float = require("ssh_launcher.ui.float")

local uv = vim.uv

local M = {}

local ns = vim.api.nvim_create_namespace("ssh_launcher_commander")

--- A stand-in row for `../`, so the way up is always the first line.
local PARENT = { name = "..", type = "parent" }

---@type ssh_launcher.Commander|nil
local instance = nil

--------------------------------------------------------------------------------
-- Paths and listings
--------------------------------------------------------------------------------

---@param path string
---@param name string
---@return string
local function child_path(path, name)
  return path == "/" and ("/" .. name) or (path:gsub("/+$", "") .. "/" .. name)
end

---@param path string
---@return string
local function parent_path(path)
  if path == "/" then
    return "/"
  end
  local parent = path:gsub("/+$", ""):match("^(.*)/[^/]+$")
  return parent == "" and "/" or (parent or ".")
end

--- `path` shortened from the left to fit `max` cells, keeping the part that
--- distinguishes it.
---@param path string
---@param max integer
---@return string
local function tail(path, max)
  path = util.contract(path)
  if util.width(path) <= max then
    return path
  end
  local rest = path
  while util.width(rest) > max - 1 do
    local slash = rest:find("/", 2, true)
    if not slash then
      return util.truncate(rest, max)
    end
    rest = rest:sub(slash)
  end
  return "…" .. rest
end

---@param entries table[]
local function sort_entries(entries)
  table.sort(entries, function(a, b)
    if (a.type == "directory") ~= (b.type == "directory") then
      return a.type == "directory"
    end
    return a.name:lower() < b.name:lower()
  end)
end

--- List a local directory in the shape the remote listing uses.
---@param path string
---@return string|nil resolved, table[]|nil entries, string|nil err
local function list_local(path)
  local resolved = uv.fs_realpath(path)
  if not resolved then
    return nil, nil, ("no such directory: %s"):format(path)
  end
  local handle, err = uv.fs_scandir(resolved)
  if not handle then
    return nil, nil, err or ("cannot read %s"):format(resolved)
  end

  local entries = {}
  while true do
    local name = uv.fs_scandir_next(handle)
    if not name then
      break
    end
    local full = child_path(resolved, name)
    local stat = uv.fs_stat(full) -- follows links, so a link to a directory is one
    local kind = "other"
    if stat then
      kind = (stat.type == "directory" or stat.type == "file") and stat.type or "other"
    else
      local lstat = uv.fs_lstat(full)
      kind = (lstat and lstat.type == "link") and "link" or "other"
    end
    entries[#entries + 1] = { name = name, type = kind, size = stat and stat.size, mtime = stat and stat.mtime.sec }
  end
  sort_entries(entries)
  return resolved, entries, nil
end

--------------------------------------------------------------------------------
-- A pane
--------------------------------------------------------------------------------

---@class ssh_launcher.Pane
---@field c ssh_launcher.Commander
---@field side "local"|"remote"
---@field path string
---@field listing table[]
---@field rows table<integer, table> buffer line -> entry
---@field selected table<string, boolean>
---@field hide_dot boolean
---@field loading boolean
---@field error string|nil
---@field pending table|nil a load requested while one was running
---@field float ssh_launcher.Float
local Pane = {}
Pane.__index = Pane

---@param c ssh_launcher.Commander
---@param side "local"|"remote"
---@param path string
---@return ssh_launcher.Pane
local function new_pane(c, side, path)
  return setmetatable({
    c = c,
    side = side,
    path = path,
    listing = {},
    rows = {},
    selected = {},
    hide_dot = not config.get().commander.show_hidden,
    loading = false,
  }, Pane)
end

---@return string
function Pane:label()
  return self.side == "local" and "Local" or Host.label(self.c.host)
end

--- This pane's directory, named by its machine: `Local:~/proj`,
--- `box:/srv/app`.
---@param max integer cells for the path
---@return string
function Pane:place(max)
  return ("%s:%s"):format(self:label(), tail(self.path, max))
end

---@return ssh_launcher.Pane
function Pane:other()
  return self.c.left == self and self.c.right or self.c.left
end

---@return table[]
function Pane:visible()
  if not self.hide_dot then
    return self.listing
  end
  local out = {}
  for _, entry in ipairs(self.listing) do
    if entry.name:sub(1, 1) ~= "." then
      out[#out + 1] = entry
    end
  end
  return out
end

---@return table|nil
function Pane:current_entry()
  if not self.float:valid() then
    return nil
  end
  return self.rows[vim.api.nvim_win_get_cursor(self.float.win)[1]]
end

--- What a copy would act on: the selection, or else the entry under the cursor.
---@return table[] entries, boolean from_selection
function Pane:targets()
  local out = {}
  for _, entry in ipairs(self.listing) do
    if self.selected[entry.name] then
      out[#out + 1] = entry
    end
  end
  if #out > 0 then
    return out, true
  end
  local entry = self:current_entry()
  if entry and entry.type ~= "parent" and entry.name then
    out[1] = entry
  end
  return out, false
end

---@return integer count, integer bytes
function Pane:selection()
  local count, bytes = 0, 0
  for _, entry in ipairs(self.listing) do
    if self.selected[entry.name] then
      count = count + 1
      if entry.type ~= "directory" then
        bytes = bytes + (entry.size or 0)
      end
    end
  end
  return count, bytes
end

---@param entry table
---@param width integer
---@return ssh_launcher.Line
function Pane:row(entry, width)
  local selected = self.selected[entry.name]
  local is_dir = entry.type == "directory"
  local mark = selected and "[x] " or "    "
  local label = entry.name .. (is_dir and "/" or (entry.type == "link" and "@" or ""))

  -- Two panes on an 80-column terminal are 35 columns each: sizes must fit
  -- there, dates only when the name still has room to breathe.
  local show_size = width >= 28
  local show_date = width >= 48
  local fixed = #mark + (show_size and 8 or 0) + (show_date and 17 or 0)
  local name_width = math.max(8, width - fixed)
  local shown = util.truncate(util.single_line(label), name_width)
  local padded = shown .. string.rep(" ", math.max(0, name_width - util.width(shown)))

  local name_hl = selected and theme.hl("Marked") or (is_dir and theme.hl("Name") or theme.hl("Value"))
  local chunks = {
    { mark, selected and theme.hl("Marked") or theme.hl("Key") },
    { padded, name_hl },
  }
  if show_size then
    local size = (is_dir or not entry.size) and "" or util.human_size(entry.size)
    chunks[#chunks + 1] = { (" %7s"):format(size), theme.hl("Muted") }
  end
  if show_date then
    chunks[#chunks + 1] = { " " .. (entry.mtime and os.date("%Y-%m-%d %H:%M", entry.mtime) or ""), theme.hl("Muted") }
  end
  return chunks
end

--- Title and footer: where this pane is, and what is selected in it.
function Pane:update_chrome()
  if not self.float:valid() then
    return
  end
  local width = vim.api.nvim_win_get_width(self.float.win)
  local active = self.c.active == self
  -- `c` copies out of the active pane into the other, so say so on each.
  local marker = active and (theme.icon("arrow") .. " FROM ") or "  TO "
  local label = self:label()
  local room = math.max(8, width - util.width(marker) - util.width(label) - 8)
  local title = ("%s%s · %s"):format(marker, label, tail(self.path, room))

  -- The active pane's frame stands out; the other recedes.
  local base = self.base_winhighlight or vim.wo[self.float.win].winhighlight
  self.base_winhighlight = base
  local emphasis = active and theme.hl("Key") or theme.hl("Muted")
  vim.wo[self.float.win].winhighlight = table.concat({
    base,
    "FloatBorder:" .. emphasis,
    "FloatTitle:" .. (active and theme.hl("Title") or theme.hl("Muted")),
  }, ",")

  local parts = { ("%d item%s"):format(#self:visible(), #self:visible() == 1 and "" or "s") }
  local count, bytes = self:selection()
  if count > 0 then
    parts[#parts + 1] = ("%d selected%s"):format(count, bytes > 0 and (" · " .. util.human_size(bytes)) or "")
  end
  if self.hide_dot then
    parts[#parts + 1] = "dotfiles hidden"
  end
  local footer = table.concat(parts, " · ")

  self.float.opts.title, self.float.opts.footer = title, footer
  self.float:set_title(title)
  self.float:set_footer(footer)
  -- What `c` would copy depends on the selection and the cursor.
  if active then
    self.c:draw_status()
  end
end

---@param focus string|nil put the cursor on this entry
---@param reset boolean|nil put it on the first entry (a new directory)
function Pane:draw(focus, reset)
  if not self.float:valid() then
    return
  end
  local width = vim.api.nvim_win_get_width(self.float.win)
  local previous = vim.api.nvim_win_get_cursor(self.float.win)[1]

  local lines, rows = {}, {}
  local function add(chunks, entry)
    lines[#lines + 1] = chunks
    rows[#lines] = entry
  end

  local visible = self:visible()
  if self.error and #self.listing == 0 then
    add({ { self.error, theme.hl("Error") } })
    add({ { "press r to try again", theme.hl("Muted") } })
  elseif self.loading and #self.listing == 0 then
    add({ { "loading…", theme.hl("Muted") } })
  else
    if self.path ~= "/" then
      add({ { "    ", theme.hl("Muted") }, { "../", theme.hl("Muted") } }, PARENT)
    end
    for _, entry in ipairs(visible) do
      add(self:row(entry, width), entry)
    end
    if #visible == 0 then
      add({ { "    (empty)", theme.hl("Muted") } })
    end
  end

  self.rows = rows
  render.draw(self.float.buf, ns, lines)

  local target = math.min(previous, #lines)
  if focus then
    for line, entry in pairs(rows) do
      if entry.name == focus then
        target = line
        break
      end
    end
  elseif reset then
    target = rows[1] == PARENT and math.min(2, #lines) or 1
  end
  self.float:set_cursor(math.max(1, target))
  self:update_chrome()
end

--- List `path` into this pane. The pane only moves once the listing succeeds,
--- so an unreadable directory leaves you where you were.
---@param path string
---@param opts { focus: string|nil, reset: boolean|nil, keep_selection: boolean|nil }|nil
function Pane:load(path, opts)
  opts = opts or {}
  if self.loading then
    self.pending = { path = path, opts = opts }
    return
  end
  self.loading = true
  self:draw()

  local function arrived(resolved, entries, err)
    self.loading = false
    if self.c.closed then
      return
    end
    if err then
      self.error = err
      log.error(("%s: %s"):format(self:label(), err))
      self.c:flash(err, "error")
    else
      if resolved ~= self.path and not opts.keep_selection then
        self.selected = {}
      end
      self.path, self.listing, self.error = resolved, entries, nil
      -- Forget selections of entries that have gone, or are no longer shown.
      local present = {}
      for _, entry in ipairs(entries) do
        present[entry.name] = not (self.hide_dot and entry.name:sub(1, 1) == ".")
      end
      for name in pairs(self.selected) do
        if not present[name] then
          self.selected[name] = nil
        end
      end
    end
    if err then
      self:draw()
    else
      self:draw(opts.focus, opts.reset)
    end
    local pending = self.pending
    self.pending = nil
    if pending then
      self:load(pending.path, pending.opts)
    end
  end

  if self.side == "local" then
    local resolved, entries, err = list_local(path)
    arrived(resolved, entries, err)
  else
    remote.list(self.c.host, path, arrived, { detailed = true })
  end
end

function Pane:refresh()
  self:load(self.path, { keep_selection = true })
end

function Pane:open()
  local entry = self:current_entry()
  if not entry then
    return
  end
  if entry.type == "parent" then
    return self:parent()
  end
  local full = child_path(self.path, entry.name)
  if entry.type == "directory" then
    return self:load(full, { reset = true })
  end
  if entry.type ~= "file" then
    return self.c:flash(("%s is not a regular file"):format(entry.name), "warn")
  end

  local c = self.c
  c:close()
  if self.side == "local" then
    vim.cmd.edit(vim.fn.fnameescape(full))
  else
    require("ssh_launcher.ui.remote").edit(c.host, full)
  end
end

function Pane:parent()
  if self.path == "/" then
    return
  end
  self:load(parent_path(self.path), { focus = util.basename(self.path) })
end

function Pane:toggle()
  local entry = self:current_entry()
  if not entry or entry.type == "parent" or not entry.name then
    return
  end
  self.selected[entry.name] = not self.selected[entry.name] or nil
  self:draw()
  local line = vim.api.nvim_win_get_cursor(self.float.win)[1]
  self.float:set_cursor(line + 1) -- ready for the next one
end

function Pane:select_all()
  local visible = self:visible()
  local all = #visible > 0
  for _, entry in ipairs(visible) do
    all = all and self.selected[entry.name] == true
  end
  for _, entry in ipairs(visible) do
    self.selected[entry.name] = (not all) or nil
  end
  self:draw()
end

function Pane:clear()
  self.selected = {}
  self:draw()
end

function Pane:toggle_hidden()
  self.hide_dot = not self.hide_dot
  if self.hide_dot then
    for name in pairs(self.selected) do
      if name:sub(1, 1) == "." then
        self.selected[name] = nil
      end
    end
  end
  self:draw()
end

--- Resolve what the user typed against this pane's directory.
---@param typed string
---@return string
function Pane:resolve(typed)
  if self.side == "local" then
    typed = util.expand(typed)
  end
  local first = typed:sub(1, 1)
  if first == "/" or first == "~" then
    return typed
  end
  return child_path(self.path, typed)
end

function Pane:jump()
  require("ssh_launcher.ui.dialog").input({
    prompt = ("Go to (%s): "):format(self:label()),
    default = self.path:gsub("/+$", "") .. "/",
    completion = self.side == "local" and "dir" or nil,
  }, function(typed)
    if typed then
      self:load(self:resolve(typed), { reset = true })
    end
  end)
end

function Pane:mkdir()
  require("ssh_launcher.ui.dialog").input({
    prompt = ("New directory in %s: "):format(tail(self.path, 40)),
  }, function(name)
    if not name then
      return
    end
    local full = self:resolve(name)
    local focus = name:match("^[^/]+")
    local function made(ok, err)
      if not ok then
        log.error(("could not create %s: %s"):format(name, err or "unknown error"))
        return self.c:flash(("could not create %s"):format(name), "error")
      end
      self:load(self.path, { focus = focus, keep_selection = true })
    end
    if self.side == "local" then
      local ok, err = pcall(vim.fn.mkdir, full, "p")
      made(ok, not ok and tostring(err) or nil)
    else
      remote.mkdir(self.c.host, full, made)
    end
  end)
end

--------------------------------------------------------------------------------
-- The commander
--------------------------------------------------------------------------------

---@class ssh_launcher.TransferJob
---@field direction "put"|"get"
---@field sources string[]
---@field dest string
---@field dest_pane ssh_launcher.Pane
---@field what string "name.txt" or "3 items"
---@field verb string "Uploading"
---@field done string "Uploaded"
---@field target string where it is going, in full
---@field short string the same, shortened for the status line
---@field started integer|nil

---@class ssh_launcher.Commander
---@field host ssh_launcher.Host
---@field left ssh_launcher.Pane
---@field right ssh_launcher.Pane
---@field panes ssh_launcher.Pane[]
---@field active ssh_launcher.Pane
---@field status ssh_launcher.Float
---@field queue ssh_launcher.TransferJob[]
---@field current ssh_launcher.TransferJob|nil
---@field handle { cancel: fun() }|nil
---@field notice { text: string, kind: string }|nil
---@field closed boolean
local Commander = {}
Commander.__index = Commander

---@return table|nil
local function layout()
  local cfg = config.get().commander
  local columns = vim.o.columns
  local rows = vim.o.lines - vim.o.cmdheight - 1

  local function dimension(value, total)
    if value <= 1 then
      return math.floor(total * value)
    end
    return math.min(math.floor(value), total)
  end

  local total_w = math.min(dimension(cfg.width, columns), columns - 2)
  local total_h = math.min(dimension(cfg.height, rows), rows - 2)
  if total_w < 60 or total_h < 8 then
    return nil
  end

  local left_outer = math.floor(total_w / 2)
  local inner_h = total_h - 4 -- two border rows, two status lines
  local row = math.max(0, math.floor((rows - total_h) / 2))
  local col = math.max(0, math.floor((columns - total_w) / 2))
  return {
    left = { row = row, col = col, width = left_outer - 2, height = inner_h },
    right = { row = row, col = col + left_outer, width = total_w - left_outer - 2, height = inner_h },
    status = { row = row + inner_h + 2, col = col, width = total_w, height = 2 },
  }
end

---@param name string
---@return string
local function keys_for(name)
  local keys = config.get().commander.keymaps[name]
  if not keys then
    return "(unbound)"
  end
  return type(keys) == "table" and table.concat(keys, " ") or keys
end

---@param name string
---@return string
local function first_key(name)
  local keys = config.get().commander.keymaps[name]
  if type(keys) == "table" then
    return keys[1] or "?"
  end
  return keys or "?"
end

---@param pane ssh_launcher.Pane
function Commander:set_active(pane)
  self.active = pane
  for _, p in ipairs(self.panes) do
    if p.float:valid() then
      vim.wo[p.float.win].cursorline = (p == pane)
      p:update_chrome()
    end
  end
end

function Commander:switch()
  local other = self.active == self.left and self.right or self.left
  if other.float:valid() then
    vim.api.nvim_set_current_win(other.float.win)
    self:set_active(other)
  end
end

--------------------------------------------------------------------------------
-- Status line
--------------------------------------------------------------------------------

---@param text string
---@param kind "ok"|"error"|"warn"|"info"|nil
function Commander:flash(text, kind)
  local notice = { text = text, kind = kind or "info" }
  self.notice = notice
  self:draw_status()
  vim.defer_fn(function()
    if self.notice == notice then
      self.notice = nil
      self:draw_status()
    end
  end, 8000)
end

--- What `c` would do right now, as the first status line: what is being
--- copied, from where, to where.
---@param width integer
---@return ssh_launcher.Line
function Commander:route(width)
  local source = self.active
  local dest = source:other()
  local copy_key = first_key("copy")
  if dest.error and #dest.listing == 0 then
    return { { " the other pane has no directory to copy into", theme.hl("Warn") } }
  end

  local items, from_selection = source:targets()
  local to = dest:place(math.max(12, math.floor(width * 0.4)))
  local arrow = " " .. theme.icon("arrow") .. " "
  if #items == 0 then
    return {
      { " ", nil },
      { copy_key, theme.hl("KeyHint") },
      { " copies to ", theme.hl("Muted") },
      { to, theme.hl("Target") },
      { ("   move onto a file, or %s to select"):format(first_key("toggle")), theme.hl("Muted") },
    }
  end

  local verb = source.side == "local" and "Upload " or "Download "
  local what
  if from_selection then
    local count, bytes = source:selection()
    what = ("%d selected%s"):format(count, bytes > 0 and (" (" .. util.human_size(bytes) .. ")") or "")
  else
    what = items[1].name .. (items[1].type == "directory" and "/" or "")
  end
  local fixed = 1 + util.width(copy_key) + 1 + #verb + util.width(arrow) + util.width(to) + 2
  what = util.truncate(util.single_line(what), math.max(8, math.min(40, width - fixed - 12)))
  local from_room = width - fixed - util.width(what)
  local chunks = {
    { " ", nil },
    { copy_key, theme.hl("KeyHint") },
    { " " .. verb, theme.hl("Key") },
    { what, theme.hl("Name") },
  }
  -- Where it comes from matters less than where it goes: drop it first.
  if from_room >= 10 then
    chunks[#chunks + 1] = { "  " .. source:place(from_room - 2), theme.hl("Muted") }
  end
  chunks[#chunks + 1] = { arrow, theme.hl("Key") }
  chunks[#chunks + 1] = { to, theme.hl("Target") }
  return chunks
end

function Commander:draw_status()
  if self.closed or not self.status or not self.status:valid() then
    return
  end
  local width = vim.api.nvim_win_get_width(self.status.win)
  local top

  if self.current then
    local job = self.current
    local seconds = math.floor((uv.now() - (job.started or uv.now())) / 1000)
    local queued = #self.queue > 0 and ("  +%d queued"):format(#self.queue) or ""
    local text = ("%s %s to %s"):format(job.verb, job.what, job.short)
    top = {
      { " ", nil },
      { util.truncate(text, math.max(10, width - 24)), theme.hl("Key") },
      { ("  %ds%s"):format(seconds, queued), theme.hl("Muted") },
      { ("   %s cancel"):format(first_key("cancel")), theme.hl("KeyHint") },
    }
  elseif self.notice then
    local hl = ({ ok = "Ok", error = "Error", warn = "Warn" })[self.notice.kind] or "Muted"
    top = { { " " .. util.truncate(self.notice.text, width - 2), theme.hl(hl) } }
  else
    top = self:route(width)
  end

  local hints = {
    { "switch", "switch" },
    { "select", "toggle" },
    { "copy", "copy" },
    { "mkdir", "mkdir" },
    { "path", "jump" },
    { "dotfiles", "hidden" },
    { "help", "help" },
    { "quit", "quit" },
  }
  local bottom = { { " ", nil } }
  for _, hint in ipairs(hints) do
    bottom[#bottom + 1] = { first_key(hint[2]), theme.hl("KeyHint") }
    bottom[#bottom + 1] = { " " .. hint[1] .. "   ", theme.hl("Muted") }
  end
  render.draw(self.status.buf, ns, { top, bottom })
end

function Commander:start_timer()
  if self.timer then
    return
  end
  self.timer = uv.new_timer()
  self.timer:start(
    500,
    500,
    vim.schedule_wrap(function()
      self:draw_status()
    end)
  )
end

function Commander:stop_timer()
  if self.timer then
    self.timer:stop()
    self.timer:close()
    self.timer = nil
  end
end

--------------------------------------------------------------------------------
-- Copying
--------------------------------------------------------------------------------

---@param job ssh_launcher.TransferJob
function Commander:enqueue(job)
  self.queue[#self.queue + 1] = job
  self:pump()
end

function Commander:pump()
  if self.current or #self.queue == 0 then
    return
  end
  local job = table.remove(self.queue, 1)
  job.started = uv.now()
  self.current = job
  if not self.closed then
    self:start_timer()
    self:draw_status()
  end

  local function finish(ok, err)
    local seconds = (uv.now() - job.started) / 1000
    self.current, self.handle = nil, nil

    if ok then
      local message = ("%s %s to %s (%.1fs)"):format(job.done, job.what, job.target, seconds)
      log.info(message)
      self:flash(message, "ok")
    elseif err == "cancelled" then
      log.warn(("%s cancelled — files already copied are left in place"):format(job.what))
      self:flash("cancelled — files already copied are left in place", "warn")
    else
      local reason = util.trim(err or "failed")
      log.error(("%s failed: %s"):format(job.what, reason))
      self:flash(("failed: %s"):format(reason:match("[^\n]+") or reason), "error")
    end

    if not self.closed and job.dest_pane.path == job.dest then
      job.dest_pane:load(job.dest, { keep_selection = true })
    end
    self:pump()
    if not self.current then
      self:stop_timer()
    end
  end

  if job.direction == "put" then
    self.handle = remote.copy("put", self.host, job.dest, job.sources, finish)
  else
    self.handle = remote.copy("get", self.host, job.sources, { job.dest }, finish)
  end
end

--- Stop the running transfer and drop anything queued behind it.
function Commander:cancel()
  if not self.current or not self.handle then
    return self:flash("nothing is transferring", "info")
  end
  self.queue = {}
  self.handle.cancel()
end

--- Copy the selection (or the entry under the cursor) into the other pane.
function Commander:copy()
  local source = self.active
  local dest = source == self.left and self.right or self.left
  local items = source:targets()
  if #items == 0 then
    return self:flash("nothing to copy — move onto a file, or press " .. first_key("toggle") .. " to select", "warn")
  end
  if dest.error and #dest.listing == 0 then
    return self:flash("the other pane has no directory to copy into", "warn")
  end

  local direction = source.side == "local" and "put" or "get"
  local sources, names = {}, {}
  for _, entry in ipairs(items) do
    local full = child_path(source.path, entry.name)
    sources[#sources + 1] = direction == "get" and remote.glob_escape(full) or full
    names[#names + 1] = entry.name
  end

  local job = {
    direction = direction,
    sources = sources,
    dest = dest.path,
    dest_pane = dest,
    what = #items == 1 and items[1].name or ("%d items"):format(#items),
  }
  if direction == "put" then
    job.verb, job.done = "Uploading", "Uploaded"
    job.target = ("%s:%s"):format(Host.label(self.host), dest.path)
    job.short = ("%s:%s"):format(Host.label(self.host), tail(dest.path, 36))
  else
    job.verb, job.done = "Downloading", "Downloaded"
    job.target = util.contract(dest.path)
    job.short = tail(dest.path, 40)
  end

  local function go()
    source.selected = {}
    source:draw()
    local function queue()
      self:enqueue(job)
    end
    if direction == "put" then
      -- Reuse the production confirmation shared with `:Ssh upload`.
      require("ssh_launcher.transfer").gate_production(self.host, sources, dest.path, {}, queue)
    else
      queue()
    end
  end

  local existing = {}
  for _, entry in ipairs(dest.listing) do
    existing[entry.name] = true
  end
  local clashes = vim.tbl_filter(function(name)
    return existing[name]
  end, names)

  if #clashes == 0 or not config.get().commander.confirm_overwrite then
    return go()
  end

  local lines = {}
  for i, name in ipairs(clashes) do
    if i > 6 then
      lines[#lines + 1] = ("…and %d more"):format(#clashes - 6)
      break
    end
    lines[#lines + 1] = name
  end
  lines[#lines + 1] = ""
  lines[#lines + 1] = ("already exist%s in %s."):format(#clashes == 1 and "s" or "", dest:label())
  require("ssh_launcher.ui.dialog").confirm({
    title = "Replace existing files?",
    lines = lines,
    yes = "Replace",
    no = "Cancel",
    destructive = true,
    default_no = true,
  }, function(confirmed)
    if source.float:valid() then
      vim.api.nvim_set_current_win(source.float.win)
    end
    if confirmed then
      go()
    end
  end)
end

--------------------------------------------------------------------------------
-- Help, keys, lifecycle
--------------------------------------------------------------------------------

function Commander:help()
  local rows = {
    { "open", "Open a directory, or edit a file" },
    { "parent", "Go up a directory" },
    { "switch", "Switch between the local and remote pane" },
    { "toggle", "Select / unselect, then move down" },
    { "select_all", "Select everything shown (again to unselect)" },
    { "clear", "Clear the selection" },
    { "copy", "Copy the selection (or the file under the cursor) to the other pane" },
    { "mkdir", "Create a directory in this pane" },
    { "jump", "Go to a path" },
    { "hidden", "Show / hide dotfiles in this pane" },
    { "refresh", "Reload this pane" },
    { "cancel", "Cancel the running transfer and anything queued" },
    { "escape", "Clear the selection, or close" },
    { "quit", "Close" },
  }
  local lines = {
    "c copies FROM the active pane (marked with an arrow) TO the other one:",
    "from Local it uploads, from the host it downloads, into the directory",
    "the other pane is showing. The line under the panes says exactly what",
    "c would copy and where, before you press it.",
    "",
  }
  for _, row in ipairs(rows) do
    lines[#lines + 1] = ("  %-16s %s"):format(keys_for(row[1]), row[2])
  end
  float.text(lines, { title = "Two-pane transfer — keys", footer = "q close" })
end

function Commander:close()
  if self.closed then
    return
  end
  self.closed = true
  self:stop_timer()
  if instance == self then
    instance = nil
  end
  pcall(vim.api.nvim_del_augroup_by_id, self.augroup)
  for _, f in ipairs({ self.left.float, self.right.float, self.status }) do
    if f then
      f:close()
    end
  end
  if self.current then
    log.info("the transfer carries on in the background")
  end
end

function Commander:map()
  local actions = {
    open = {
      "Open",
      function(p)
        p:open()
      end,
    },
    parent = {
      "Parent directory",
      function(p)
        p:parent()
      end,
    },
    switch = {
      "Switch pane",
      function()
        self:switch()
      end,
    },
    toggle = {
      "Select",
      function(p)
        p:toggle()
      end,
    },
    select_all = {
      "Select all",
      function(p)
        p:select_all()
      end,
    },
    clear = {
      "Clear selection",
      function(p)
        p:clear()
      end,
    },
    copy = {
      "Copy to the other pane",
      function()
        self:copy()
      end,
    },
    mkdir = {
      "New directory",
      function(p)
        p:mkdir()
      end,
    },
    jump = {
      "Go to a path",
      function(p)
        p:jump()
      end,
    },
    hidden = {
      "Toggle dotfiles",
      function(p)
        p:toggle_hidden()
      end,
    },
    refresh = {
      "Refresh",
      function(p)
        p:refresh()
      end,
    },
    cancel = {
      "Cancel the transfer",
      function()
        self:cancel()
      end,
    },
    help = {
      "Help",
      function()
        self:help()
      end,
    },
    quit = {
      "Close",
      function()
        self:close()
      end,
    },
    escape = {
      "Clear selection, or close",
      function(p)
        if p:selection() > 0 then
          p:clear()
        else
          self:close()
        end
      end,
    },
  }
  local keymaps = config.get().commander.keymaps
  for _, pane in ipairs(self.panes) do
    for name, action in pairs(actions) do
      pane.float:map("n", keymaps[name], function()
        action[2](pane)
      end, action[1])
    end
  end
end

--- Open the window.
---@param h ssh_launcher.Host
---@param opts { local_path: string|nil, remote_path: string|nil }|nil
---@return ssh_launcher.Commander|nil
function M.open(h, opts)
  opts = opts or {}
  if instance then
    instance:close()
  end

  local geometry = layout()
  if not geometry then
    log.error("the editor window is too small for two panes (needs 60 columns and 8 lines)")
    return nil
  end

  local self = setmetatable({
    host = h,
    queue = {},
    closed = false,
    panes = {},
  }, Commander)
  instance = self

  local local_path = util.expand(opts.local_path or vim.fn.getcwd())
  local remote_path = opts.remote_path or h.remote_dir or "."
  self.left = new_pane(self, "local", local_path)
  self.right = new_pane(self, "remote", remote_path)
  self.panes = { self.left, self.right }
  self.active = self.left

  for index, pane in ipairs(self.panes) do
    local box = index == 1 and geometry.left or geometry.right
    pane.float = float.open(vim.tbl_extend("force", box, {
      title = pane:label(),
      footer = "",
      enter = index == 1,
      close_keys = false,
      filetype = "ssh-launcher-commander",
      on_close = function()
        self:close()
      end,
    }))
  end
  self.status = float.open(vim.tbl_extend("force", geometry.status, {
    border = "none",
    enter = false,
    close_keys = false,
    cursorline = false,
    on_close = function()
      self:close()
    end,
  }))

  self.augroup = vim.api.nvim_create_augroup("SshLauncherCommander", { clear = true })
  for _, pane in ipairs(self.panes) do
    vim.api.nvim_create_autocmd("WinEnter", {
      group = self.augroup,
      buffer = pane.float.buf,
      desc = "ssh-launcher: remember which pane is active",
      callback = function()
        if not self.closed and self.active ~= pane then
          self:set_active(pane)
        end
      end,
    })
    vim.api.nvim_create_autocmd("CursorMoved", {
      group = self.augroup,
      buffer = pane.float.buf,
      desc = "ssh-launcher: keep the copy preview on what is under the cursor",
      callback = function()
        if not self.closed and self.active == pane then
          self:draw_status()
        end
      end,
    })
  end
  vim.api.nvim_create_autocmd("VimResized", {
    group = self.augroup,
    desc = "ssh-launcher: keep the two panes side by side",
    callback = function()
      local fresh = layout()
      if not fresh then
        return self:close()
      end
      self.left.float:reconfigure(fresh.left)
      self.right.float:reconfigure(fresh.right)
      self.status:reconfigure(fresh.status)
      for _, pane in ipairs(self.panes) do
        pane:draw()
      end
      self:draw_status()
    end,
  })

  self:map()
  self:set_active(self.left)
  self:draw_status()
  self.left:load(local_path, { reset = true })
  self.right:load(remote_path, { reset = true })
  log.announce(
    ("two-pane transfer with %s — %s switches pane, %s copies"):format(
      Host.label(h),
      first_key("switch"),
      first_key("copy")
    )
  )
  return self
end

--- Open the window once the host's key is usable for background commands,
--- offering to load a locked key into ssh-agent first.
---@param h ssh_launcher.Host
---@param opts { local_path: string|nil, remote_path: string|nil }|nil
function M.launch(h, opts)
  remote.with_auth(h, function()
    M.open(h, opts)
  end)
end

--- The open window, if any.
---@return ssh_launcher.Commander|nil
function M.instance()
  return instance
end

return M
