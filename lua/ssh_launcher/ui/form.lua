---@mod ssh_launcher.ui.form Host editor
---
--- The editor is a normal, editable buffer of `Label: value` lines. That single
--- decision buys a lot:
---
--- * every Vim motion, register, undo and completion mechanism just works;
--- * pasting is native — `p` into the Paste line and the fields fill in;
--- * a screen reader sees the whole record as text, not as widget state;
--- * problems are reported through `vim.diagnostic`, so they appear in the
---   user's own diagnostic UI, navigate with `]d`, and float with `<C-d>`.

local util = require("ssh_launcher.util")
local log = require("ssh_launcher.log")
local config = require("ssh_launcher.config")
local Host = require("ssh_launcher.host")
local store = require("ssh_launcher.store")
local parser = require("ssh_launcher.parser")
local diagnostics = require("ssh_launcher.diagnostics")
local keys = require("ssh_launcher.keys")
local theme = require("ssh_launcher.ui.theme")
local float = require("ssh_launcher.ui.float")
local dialog = require("ssh_launcher.ui.dialog")

local M = {}

local ns = vim.api.nvim_create_namespace("ssh_launcher_form")
local diag_ns = vim.api.nvim_create_namespace("ssh_launcher_form_diagnostics")

local PASTE_LABEL = "Paste"
local LABEL_WIDTH = 12

---@class ssh_launcher.Form
---@field host ssh_launcher.Host
---@field original ssh_launcher.Host
---@field is_new boolean
---@field win ssh_launcher.Float
---@field issues ssh_launcher.Issue[]
local Form = {}
Form.__index = Form

--------------------------------------------------------------------------------
-- Serialization between host table and buffer text
--------------------------------------------------------------------------------

---@return { label: string, key: string|nil, help: string }[]
local function field_rows()
  local rows = {
    {
      label = PASTE_LABEL,
      key = nil,
      help = "Drop an ssh command, user@host, URL or config block here",
    },
  }
  for _, f in ipairs(Host.FIELDS) do
    rows[#rows + 1] = { label = f.label, key = f.key, help = f.help }
  end
  return rows
end

local ROWS = field_rows()

local LABEL_TO_KEY = {}
for _, row in ipairs(ROWS) do
  LABEL_TO_KEY[row.label:lower()] = row.key or "__paste"
end

---@param h ssh_launcher.Host
---@param key string
---@return string
local function value_for(h, key)
  if key == "tags" then
    return table.concat(h.tags or {}, ", ")
  elseif key == "forwards" then
    return Host.forwards_to_string(h.forwards)
  elseif key == "options" then
    return Host.options_to_string(h.options)
  elseif key == "port" then
    return h.port and tostring(h.port) or ""
  elseif key == "identity_file" then
    return h.identity_file and util.contract(h.identity_file) or ""
  end
  return h[key] and tostring(h[key]) or ""
end

---@param h ssh_launcher.Host
---@param paste string|nil
---@return string[] lines, table<string, integer> line_of_field 0-indexed
local function to_lines(h, paste)
  local lines = {}
  local line_of = {}

  local function comment(text)
    lines[#lines + 1] = "# " .. text
  end

  comment("Edit the values after the colons. Empty means 'use the ssh default'.")
  comment("<C-s> save   <C-a> save & connect   <C-f> fix all   <C-k> pick key   ? help   q close")
  lines[#lines + 1] = ""

  for _, row in ipairs(ROWS) do
    local key = row.key
    local value = key and value_for(h, key) or (paste or "")
    lines[#lines + 1] = ("%s: %s"):format(util.pad(row.label, LABEL_WIDTH), value)
    line_of[key or "__paste"] = #lines - 1
  end

  return lines, line_of
end

---@param buf integer
---@return table fields, string|nil paste, table<string, integer> line_of
local function from_buffer(buf)
  local fields = {}
  local paste = nil
  local line_of = {}
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)

  for i, line in ipairs(lines) do
    if line:sub(1, 1) ~= "#" then
      local label, value = line:match("^%s*([%a][%a%s]-)%s*:%s?(.*)$")
      if label then
        local key = LABEL_TO_KEY[label:lower()]
        if key == "__paste" then
          paste = util.nonblank(value)
          line_of["__paste"] = i - 1
        elseif key then
          fields[key] = util.trim(value)
          line_of[key] = i - 1
        end
      end
    end
  end

  return fields, paste, line_of
end

---@param fields table
---@param base ssh_launcher.Host
---@return ssh_launcher.Host
local function to_host(fields, base)
  local h = vim.deepcopy(base)
  for key, value in pairs(fields) do
    if key == "port" then
      h.port = tonumber(value)
    elseif key == "tags" then
      h.tags = Host.to_tags(value)
    elseif key == "forwards" then
      h.forwards = Host.to_forwards(value)
    elseif key == "options" then
      h.options = Host.to_options(value)
    else
      h[key] = value
    end
  end
  return (Host.normalize(h))
end

--------------------------------------------------------------------------------
-- Form behaviour
--------------------------------------------------------------------------------

---@return boolean
function Form:in_insert()
  return vim.fn.mode():sub(1, 1) == "i"
end

--- Read the buffer into `self.host`, absorbing anything in the Paste line.
---@return boolean rerender whether the buffer text needs rewriting
function Form:sync_from_buffer()
  local fields, paste, line_of = from_buffer(self.win.buf)
  self.line_of = line_of

  local rerender = false

  if paste then
    local res = parser.parse(paste)
    if res and res.kind == "secret" then
      for _, w in ipairs(res.warnings) do
        log.error(w)
      end
      rerender = true
    elseif res and not util.blank(res.host.host) then
      -- Pasted values win: the user just told us what they want.
      local merged = vim.tbl_extend("force", to_host(fields, self.host), res.host)
      self.host = Host.normalize(merged)
      for _, w in ipairs(res.warnings) do
        log.warn(w)
      end
      local described = parser.describe(res)
      log.info(("read %s from the paste (%s)"):format(described, res.kind))
      log.announce(("filled in %s"):format(described))
      rerender = true
    elseif res then
      log.warn("that paste had no host in it")
      rerender = true
    else
      log.warn(("could not parse %q"):format(util.truncate(paste, 48)))
      rerender = true
    end
  else
    self.host = to_host(fields, self.host)
  end

  -- A missing or duplicated field line means the user edited the structure;
  -- rewriting restores it without losing any values we managed to read.
  for _, row in ipairs(ROWS) do
    if line_of[row.key or "__paste"] == nil then
      rerender = true
    end
  end

  return rerender
end

function Form:render(opts)
  opts = opts or {}
  local lines, line_of = to_lines(self.host, nil)
  self.line_of = line_of

  -- The undo chain is deliberately left intact: a paste expansion should be
  -- undoable with a plain `u`.
  local view = vim.fn.winsaveview()
  vim.bo[self.win.buf].modifiable = true
  vim.api.nvim_buf_set_lines(self.win.buf, 0, -1, false, lines)
  vim.fn.winrestview(view)

  self:decorate()
end

--- Field label / comment highlighting. Done with extmarks rather than a syntax
--- file so it survives the buffer being freely edited.
function Form:decorate()
  local buf = self.win.buf
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)

  for i, line in ipairs(lines) do
    if line:sub(1, 1) == "#" then
      pcall(vim.api.nvim_buf_set_extmark, buf, ns, i - 1, 0, {
        end_col = #line,
        hl_group = theme.hl("Muted"),
        strict = false,
      })
    else
      local label = line:match("^%s*([%a][%a%s]-)%s*:")
      if label then
        local colon = line:find(":")
        pcall(vim.api.nvim_buf_set_extmark, buf, ns, i - 1, 0, {
          end_col = colon,
          hl_group = theme.hl("Label"),
          strict = false,
        })
      end
    end
  end

  -- Inline hints on empty fields, so the format is discoverable without docs.
  if config.get().a11y.virtual_text then
    for _, row in ipairs(ROWS) do
      local key = row.key or "__paste"
      local lnum = self.line_of and self.line_of[key]
      if lnum then
        local text = lines[lnum + 1] or ""
        local value = text:match("^[^:]*:%s?(.*)$") or ""
        if util.trim(value) == "" then
          pcall(vim.api.nvim_buf_set_extmark, buf, ns, lnum, #text, {
            virt_text = { { "  " .. row.help, theme.hl("Muted") } },
            virt_text_pos = "eol",
            hl_mode = "combine",
          })
        end
      end
    end
  end
end

---@param field string|nil
---@return integer
function Form:line_for(field)
  if field and self.line_of and self.line_of[field] then
    return self.line_of[field]
  end
  return self.line_of and self.line_of.name or 0
end

function Form:refresh_diagnostics()
  local cfg = config.get()
  self.issues = diagnostics.check(self.host, { hosts = self.context_hosts })

  local items = diagnostics.to_vim_diagnostics(self.issues, function(field)
    return self:line_for(field)
  end)

  vim.diagnostic.set(diag_ns, self.win.buf, items, {
    virtual_text = cfg.a11y.virtual_text and { spacing = 2, prefix = theme.icon("bullet") } or false,
    underline = true,
    signs = false,
  })

  local counts = diagnostics.counts(self.issues)
  local footer
  if counts.error + counts.warn == 0 then
    footer = ("%s ready to connect"):format(theme.icon("ok"))
  else
    footer = ("%s %s"):format(theme.icon(counts.error > 0 and "error" or "warn"), diagnostics.summary(self.issues))
  end
  self.win:set_footer(footer .. "  ·  <C-d> details")

  if cfg.diagnostics.check_dns or cfg.diagnostics.check_reachability then
    local generation = (self.generation or 0) + 1
    self.generation = generation
    diagnostics.check_async(self.host, function(extra)
      if generation ~= self.generation or not self.win:valid() then
        return
      end
      if #extra == 0 then
        return
      end
      vim.list_extend(self.issues, extra)
      local all = diagnostics.to_vim_diagnostics(self.issues, function(field)
        return self:line_for(field)
      end)
      vim.diagnostic.set(diag_ns, self.win.buf, all, {
        virtual_text = cfg.a11y.virtual_text and { spacing = 2, prefix = theme.icon("bullet") } or false,
        underline = true,
        signs = false,
      })
    end)
  end
end

function Form:update(opts)
  opts = opts or {}
  local rerender = self:sync_from_buffer()
  if (rerender or opts.force) and not self:in_insert() then
    self:render()
  else
    self:decorate()
  end
  self:refresh_diagnostics()
end

---@return boolean
function Form:dirty()
  local a = Host.serialize(self.host)
  local b = Host.serialize(self.original)
  return not vim.deep_equal(a, b)
end

--------------------------------------------------------------------------------
-- Actions
--------------------------------------------------------------------------------

---@param cb fun(saved: ssh_launcher.Host|nil)|nil
function Form:save(cb)
  self:sync_from_buffer()

  local errors = vim.tbl_filter(function(i)
    return i.severity == "error"
  end, diagnostics.check(self.host, { hosts = self.context_hosts }))

  local function persist()
    local saved, err
    if self.is_new then
      saved, err = store.add(self.host)
    elseif self.original.readonly then
      -- ssh_config entries are not ours to rewrite; saving forks a copy.
      local copy = vim.deepcopy(self.host)
      copy.id = util.uid()
      copy.source = "store"
      copy.readonly = nil
      saved, err = store.add(copy)
      if saved then
        log.info(("saved a copy of the ssh_config host %q"):format(saved.name))
      end
    else
      saved, err = store.update(self.original.id, self.host)
    end

    if not saved then
      log.error(("could not save: %s"):format(err or "unknown error"))
      if cb then
        cb(nil)
      end
      return
    end

    self.host = saved
    self.original = vim.deepcopy(saved)
    self.is_new = false
    log.info(("saved %s"):format(Host.label(saved)))
    log.announce(("saved %s"):format(Host.label(saved)))
    if self.on_save then
      pcall(self.on_save, saved)
    end
    if cb then
      cb(saved)
    end
  end

  if #errors == 0 then
    return persist()
  end

  dialog.choose({
    title = ("%s Save with %d problem%s?"):format(theme.icon("warn"), #errors, #errors == 1 and "" or "s"),
    lines = (function()
      local lines = {}
      for _, issue in ipairs(errors) do
        lines[#lines + 1] = {
          { "  " .. theme.word(issue.severity) .. ": ", theme.hl("Error") },
          { issue.message, theme.hl("Value") },
        }
      end
      return lines
    end)(),
    choices = {
      { label = "Fix them for me", value = "fix", key = "f" },
      { label = "Save anyway", value = "save", key = "s" },
      { label = "Keep editing", value = nil, key = "k" },
    },
    on_choice = function(value)
      if value == "fix" then
        self:autofix()
      elseif value == "save" then
        persist()
      end
    end,
  })
end

function Form:autofix()
  self:sync_from_buffer()
  local fixed, applied = diagnostics.autofix(self.host, { hosts = self.context_hosts })
  if #applied == 0 then
    log.info("nothing here can be fixed automatically")
    return
  end
  self.host = fixed
  self:render()
  self:refresh_diagnostics()
  log.info("fixed: " .. table.concat(applied, "; "))
  log.announce(("applied %d fix%s"):format(#applied, #applied == 1 and "" or "es"))
end

function Form:pick_key()
  local found = keys.discover()
  if #found == 0 then
    log.warn("no private keys found in ~/.ssh — press G in the manager to generate one")
    return
  end
  local choices = {}
  for _, info in ipairs(found) do
    local bits = {}
    if info.type then
      bits[#bits + 1] = info.type
    end
    if info.too_open then
      bits[#bits + 1] = "mode " .. (info.mode or "?") .. " (too open)"
    end
    if info.encrypted == true then
      bits[#bits + 1] = "passphrase"
    end
    choices[#choices + 1] = {
      label = util.contract(info.path),
      value = util.contract(info.path),
      desc = #bits > 0 and table.concat(bits, ", ") or nil,
    }
  end
  choices[#choices + 1] = { label = "(no key — use the agent)", value = "", key = "0" }

  dialog.choose({
    title = ("%s Choose a private key"):format(theme.icon("key")),
    choices = choices,
    on_choice = function(value)
      if value == nil then
        return
      end
      self:sync_from_buffer()
      self.host.identity_file = util.nonblank(value)
      self:render()
      self:refresh_diagnostics()
    end,
  })
end

function Form:paste_clipboard()
  local res, reg = parser.from_clipboard()
  if not res then
    log.warn("the clipboard does not contain a connection string")
    return
  end
  self:sync_from_buffer()
  self.host = Host.normalize(vim.tbl_extend("force", self.host, res.host))
  self:render()
  self:refresh_diagnostics()
  log.info(("pasted %s from register %s"):format(parser.describe(res), reg))
end

function Form:close(force)
  if not force and self:dirty() then
    dialog.choose({
      title = "Discard changes?",
      lines = { { { ("%s has unsaved changes."):format(Host.label(self.host)), theme.hl("Value") } } },
      choices = {
        { label = "Save and close", value = "save", key = "s" },
        { label = "Discard", value = "discard", key = "d", destructive = true },
        { label = "Keep editing", value = nil, key = "k" },
      },
      on_choice = function(value)
        if value == "save" then
          self:save(function()
            self.win:close()
          end)
        elseif value == "discard" then
          self.win:close()
        end
      end,
    })
    return
  end
  self.win:close()
end

function Form:show_command()
  self:sync_from_buffer()
  local cmd = Host.command_string(self.host)
  local lines = {
    "This is the exact command that will run:",
    "",
    cmd,
    "",
    "It is executed as an argument list, never through a shell.",
    "",
    "Press y to copy it to the clipboard, q to close.",
  }
  local win = float.text(lines, { title = "Resolved command", wrap = true })
  win:map("n", "y", function()
    vim.fn.setreg("+", cmd)
    vim.fn.setreg('"', cmd)
    log.info("command copied")
    win:close()
  end, "Copy")
end

--------------------------------------------------------------------------------
-- Entry point
--------------------------------------------------------------------------------

---@param host ssh_launcher.Host|nil
---@param opts { is_new: boolean|nil, on_save: fun(h: ssh_launcher.Host)|nil, paste: string|nil }|nil
---@return ssh_launcher.Form
function M.open(host, opts)
  opts = opts or {}
  local self = setmetatable({}, Form)

  local rewrites = {}
  if host then
    self.host, rewrites = Host.normalize(host)
  else
    self.host = Host.blank()
  end
  self.original = vim.deepcopy(self.host)
  self.is_new = opts.is_new == true
  self.on_save = opts.on_save
  self.issues = {}
  self.context_hosts = store.all()

  local title = self.is_new and "New host" or ("Edit %s"):format(Host.label(self.host))
  if self.host.readonly then
    title = title .. (" (%s — saving makes a copy)"):format(self.host.origin or self.host.source)
  end

  local lines = to_lines(self.host, opts.paste)

  self.win = float.open({
    title = title,
    footer = "checking…",
    width = 0.7,
    height = math.min(#lines + 6, math.floor(vim.o.lines * 0.8)),
    modifiable = true,
    cursorline = true,
    close_keys = false,
    lines = lines,
    filetype = "ssh-launcher-form",
  })

  local buf = self.win.buf
  vim.bo[buf].buftype = "acwrite"
  vim.bo[buf].modifiable = true
  vim.bo[buf].modified = false
  pcall(vim.api.nvim_buf_set_name, buf, ("ssh-launcher://host/%s"):format(self.host.id))

  local group = vim.api.nvim_create_augroup("SshLauncherForm" .. buf, { clear = true })

  local debounced = util.debounce(function()
    if self.win:valid() then
      self:update()
    end
  end, 180)

  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI", "TextChangedP" }, {
    group = group,
    buffer = buf,
    desc = "ssh-launcher: re-validate the host being edited",
    callback = debounced,
  })

  vim.api.nvim_create_autocmd("InsertLeave", {
    group = group,
    buffer = buf,
    desc = "ssh-launcher: absorb pasted text and re-validate",
    callback = function()
      self:update()
    end,
  })

  -- `:w` is muscle memory; make it mean "save this host".
  vim.api.nvim_create_autocmd("BufWriteCmd", {
    group = group,
    buffer = buf,
    desc = "ssh-launcher: save the host",
    callback = function()
      self:save(function()
        vim.bo[buf].modified = false
      end)
    end,
  })

  vim.api.nvim_create_autocmd("BufWipeout", {
    group = group,
    buffer = buf,
    once = true,
    callback = function()
      pcall(vim.diagnostic.reset, diag_ns, buf)
    end,
  })

  local map = function(mode, lhs, fn, desc)
    self.win:map(mode, lhs, fn, desc)
  end

  map({ "n", "i" }, "<C-s>", function()
    self:save()
  end, "Save")

  map({ "n", "i" }, "<C-a>", function()
    self:save(function(saved)
      if saved then
        self.win:close()
        require("ssh_launcher.connect").connect(saved)
      end
    end)
  end, "Save and connect")

  map({ "n", "i" }, "<C-f>", function()
    self:autofix()
  end, "Fix everything fixable")

  map({ "n", "i" }, "<C-k>", function()
    self:pick_key()
  end, "Pick a key")

  map({ "n", "i" }, "<C-g>", function()
    self:paste_clipboard()
  end, "Paste from clipboard")

  map("n", "<C-d>", function()
    vim.diagnostic.open_float({ scope = "line", border = theme.border() })
  end, "Show problems on this line")

  map("n", "gx", function()
    self:show_command()
  end, "Show the resolved ssh command")

  map("n", { "q", "<Esc>" }, function()
    self:close()
  end, "Close")

  map("n", "<C-c>", function()
    self:close(true)
  end, "Close without saving")

  map("n", "?", function()
    require("ssh_launcher.ui.help").show("form")
  end, "Help")

  -- Tab walks between values and drops into insert at the end, which is what
  -- everyone tries first in a form.
  local function jump(delta)
    local lnum = vim.api.nvim_win_get_cursor(self.win.win)[1]
    local count = vim.api.nvim_buf_line_count(buf)
    for i = 1, count do
      local candidate = ((lnum - 1 + delta * i) % count) + 1
      local text = vim.api.nvim_buf_get_lines(buf, candidate - 1, candidate, false)[1] or ""
      if text:sub(1, 1) ~= "#" and text:match("^%s*[%a][%a%s]-%s*:") then
        vim.api.nvim_win_set_cursor(self.win.win, { candidate, #text })
        vim.cmd("startinsert!")
        return
      end
    end
  end

  map({ "n", "i" }, "<Tab>", function()
    jump(1)
  end, "Next field")
  map({ "n", "i" }, "<S-Tab>", function()
    jump(-1)
  end, "Previous field")
  map("n", "<CR>", function()
    vim.cmd("startinsert!")
  end, "Edit this field")

  self:update({ force = false })
  self:refresh_diagnostics()

  -- Start on the first empty field so a new host is immediately typeable.
  local start_line = self.line_of and (self.line_of.name or 0) or 0
  if self.is_new and not opts.paste then
    start_line = self.line_of and self.line_of.__paste or start_line
  end
  self.win:set_cursor(start_line + 1)

  -- Loading a record may have had to rewrite it (a stray newline, a `user@` in
  -- the host field). Say so once, on open: a value that changed underneath the
  -- user is exactly the kind of thing that must not happen quietly.
  if #rewrites > 0 then
    log.warn(("opened with changes: %s"):format(table.concat(rewrites, "; ")))
  end

  log.announce(title .. ". Tab moves between fields, Control-S saves.")
  return self
end

---@param host ssh_launcher.Host
---@param opts table|nil
function M.edit(host, opts)
  return M.open(host, vim.tbl_extend("force", { is_new = false }, opts or {}))
end

---@param opts { paste: string|nil, on_save: fun(h)|nil }|nil
function M.create(opts)
  opts = opts or {}
  local seed = nil
  if opts.paste then
    local res = parser.parse(opts.paste)
    if res and not util.blank(res.host.host) then
      seed = Host.normalize(res.host)
      for _, w in ipairs(res.warnings) do
        log.warn(w)
      end
    end
  end
  -- When the text already parsed into a seed, the Paste line starts empty:
  -- leaving the raw text there would just re-apply it on the first redraw.
  local leftover = nil
  if not seed then
    leftover = opts.paste
  end
  return M.open(seed, { is_new = true, on_save = opts.on_save, paste = leftover })
end

return M
