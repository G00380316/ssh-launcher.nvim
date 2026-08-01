---@mod ssh_launcher.ui.float Floating window primitive
---
--- A small wrapper that every window in the plugin is built from. It handles
--- geometry, borders, resize, cleanup, and the keyboard contract users expect
--- from a modal Neovim UI.

local util = require("ssh_launcher.util")
local config = require("ssh_launcher.config")
local theme = require("ssh_launcher.ui.theme")

---@class ssh_launcher.Float
---@field buf integer
---@field win integer|nil
---@field opts table
local Float = {}
Float.__index = Float

local M = { Float = Float }

---@param value number|nil fraction (<=1) or absolute columns
---@param total integer
---@param fallback number
---@return integer
local function dimension(value, total, fallback)
  value = value or fallback
  if value <= 1 then
    return math.max(1, math.floor(total * value))
  end
  return math.max(1, math.min(math.floor(value), total))
end

---@return integer columns, integer lines
local function editor_size()
  return vim.o.columns, vim.o.lines - vim.o.cmdheight - 1
end

---@param opts table
---@return table win_config
local function geometry(opts)
  local columns, lines = editor_size()
  local width = dimension(opts.width, columns, 0.8)
  local height = dimension(opts.height, lines, 0.8)

  width = math.min(width, columns - 2)
  height = math.min(height, lines - 2)

  local row = opts.row
  local col = opts.col
  if row == nil then
    row = math.max(0, math.floor((lines - height) / 2))
  end
  if col == nil then
    col = math.max(0, math.floor((columns - width) / 2))
  end

  local cfg = {
    relative = opts.relative or "editor",
    width = width,
    height = height,
    row = row,
    col = col,
    border = theme.border(opts.border),
    zindex = opts.zindex or 50,
    noautocmd = opts.noautocmd,
  }

  if opts.style ~= false then
    cfg.style = "minimal"
  end

  if opts.title then
    cfg.title = type(opts.title) == "string" and (" " .. opts.title .. " ") or opts.title
    cfg.title_pos = opts.title_pos or "left"
  end
  if opts.footer and cfg.border ~= "none" then
    cfg.footer = type(opts.footer) == "string" and (" " .. opts.footer .. " ") or opts.footer
    cfg.footer_pos = opts.footer_pos or "right"
  end
  return cfg
end

---@class ssh_launcher.FloatOpts
---@field title string|nil
---@field footer string|nil
---@field width number|nil
---@field height number|nil
---@field row integer|nil
---@field col integer|nil
---@field border string|nil
---@field enter boolean|nil
---@field filetype string|nil
---@field buf integer|nil reuse an existing buffer (e.g. a terminal)
---@field lines string[]|nil
---@field modifiable boolean|nil
---@field cursorline boolean|nil
---@field wrap boolean|nil
---@field on_close fun()|nil
---@field close_keys string[]|false|nil
---@field win_options table|nil

---@param opts ssh_launcher.FloatOpts
---@return ssh_launcher.Float
function M.open(opts)
  opts = opts or {}
  local self = setmetatable({ opts = opts }, Float)

  self.buf = opts.buf
  self.owns_buf = false
  if not self.buf or not vim.api.nvim_buf_is_valid(self.buf) then
    self.buf = vim.api.nvim_create_buf(false, true)
    self.owns_buf = true
    vim.bo[self.buf].bufhidden = "wipe"
    vim.bo[self.buf].buftype = "nofile"
    vim.bo[self.buf].swapfile = false
  end

  if opts.filetype then
    vim.bo[self.buf].filetype = opts.filetype
  end
  if opts.lines then
    self:set_lines(opts.lines)
  end
  vim.bo[self.buf].modifiable = opts.modifiable == true

  local enter = opts.enter ~= false
  self.win = vim.api.nvim_open_win(self.buf, enter, geometry(opts))

  local ui_cfg = config.get().ui
  local win_options = vim.tbl_extend("force", {
    wrap = opts.wrap == true,
    cursorline = opts.cursorline ~= false,
    cursorlineopt = "line",
    number = false,
    relativenumber = false,
    signcolumn = "no",
    foldenable = false,
    spell = false,
    list = false,
    winblend = ui_cfg.winblend,
    winhighlight = table.concat({
      "Normal:" .. theme.hl("Normal"),
      "FloatBorder:" .. theme.hl("Border"),
      "FloatTitle:" .. theme.hl("Title"),
      "FloatFooter:" .. theme.hl("Footer"),
      "CursorLine:" .. theme.hl("Cursor"),
      "Search:" .. theme.hl("Match"),
    }, ","),
  }, opts.win_options or {})

  for key, value in pairs(win_options) do
    local ok = pcall(function()
      vim.wo[self.win][0][key] = value
    end)
    if not ok then
      pcall(function()
        vim.wo[self.win][key] = value
      end)
    end
  end

  self.augroup = vim.api.nvim_create_augroup("SshLauncherFloat" .. self.buf, { clear = true })

  vim.api.nvim_create_autocmd("VimResized", {
    group = self.augroup,
    desc = "Keep the ssh-launcher window centred",
    callback = function()
      self:resize()
    end,
  })

  vim.api.nvim_create_autocmd("WinClosed", {
    group = self.augroup,
    pattern = tostring(self.win),
    once = true,
    callback = function()
      self:_cleanup()
    end,
  })

  if opts.close_keys ~= false then
    for _, key in ipairs(opts.close_keys or { "q", "<Esc>" }) do
      self:map("n", key, function()
        self:close()
      end, "Close")
    end
  end

  return self
end

function Float:_cleanup()
  if self.closed then
    return
  end
  self.closed = true
  pcall(vim.api.nvim_del_augroup_by_id, self.augroup)
  if self.opts.on_close then
    pcall(self.opts.on_close)
  end
end

---@return boolean
function Float:valid()
  return self.win ~= nil and vim.api.nvim_win_is_valid(self.win)
end

function Float:resize()
  if not self:valid() then
    return
  end
  local cfg = geometry(self.opts)
  -- `style` cannot be passed to nvim_win_set_config on an existing window.
  cfg.style = nil
  cfg.noautocmd = nil
  pcall(vim.api.nvim_win_set_config, self.win, cfg)
end

---@param opts table partial geometry/title updates
function Float:reconfigure(opts)
  self.opts = vim.tbl_extend("force", self.opts, opts or {})
  self:resize()
end

---@param lines string[]
function Float:set_lines(lines)
  if not vim.api.nvim_buf_is_valid(self.buf) then
    return
  end
  local was_modifiable = vim.bo[self.buf].modifiable
  vim.bo[self.buf].modifiable = true
  vim.api.nvim_buf_set_lines(self.buf, 0, -1, false, lines)
  vim.bo[self.buf].modifiable = was_modifiable
end

---@param footer string
function Float:set_footer(footer)
  if not self:valid() then
    return
  end
  local cfg = vim.api.nvim_win_get_config(self.win)
  if cfg.border == "none" then
    return
  end
  cfg.footer = " " .. footer .. " "
  cfg.footer_pos = self.opts.footer_pos or "right"
  pcall(vim.api.nvim_win_set_config, self.win, cfg)
end

---@param title string
function Float:set_title(title)
  if not self:valid() then
    return
  end
  local cfg = vim.api.nvim_win_get_config(self.win)
  cfg.title = " " .. title .. " "
  cfg.title_pos = self.opts.title_pos or "left"
  pcall(vim.api.nvim_win_set_config, self.win, cfg)
end

---@param mode string|string[]
---@param lhs string|string[]|false|nil
---@param rhs function|string
---@param desc string|nil
function Float:map(mode, lhs, rhs, desc)
  if lhs == false or lhs == nil then
    return
  end
  local list = type(lhs) == "table" and lhs or { lhs }
  for _, key in ipairs(list) do
    vim.keymap.set(mode, key, rhs, {
      buffer = self.buf,
      nowait = true,
      silent = true,
      desc = desc and ("ssh-launcher: " .. desc) or nil,
    })
  end
end

function Float:focus()
  if self:valid() then
    vim.api.nvim_set_current_win(self.win)
  end
end

function Float:close()
  if self:valid() then
    local win = self.win
    self.win = nil
    pcall(vim.api.nvim_win_close, win, true)
  end
  self:_cleanup()
end

---@return integer
function Float:cursor_line()
  if not self:valid() then
    return 1
  end
  return vim.api.nvim_win_get_cursor(self.win)[1]
end

---@param line integer 1-indexed
function Float:set_cursor(line)
  if not self:valid() then
    return
  end
  local count = vim.api.nvim_buf_line_count(self.buf)
  line = math.max(1, math.min(line, count))
  pcall(vim.api.nvim_win_set_cursor, self.win, { line, 0 })
end

--------------------------------------------------------------------------------
-- Convenience windows
--------------------------------------------------------------------------------

--- A read-only text window, sized to its content.
---@param lines string[]
---@param opts ssh_launcher.FloatOpts|nil
---@return ssh_launcher.Float
function M.text(lines, opts)
  opts = opts or {}
  local width = 0
  for _, l in ipairs(lines) do
    width = math.max(width, util.width(l))
  end
  local columns, rows = editor_size()
  opts.width = opts.width or math.min(width + 4, math.floor(columns * 0.9))
  opts.height = opts.height or math.min(#lines, math.floor(rows * 0.8))
  opts.lines = lines
  opts.cursorline = opts.cursorline ~= false
  return M.open(opts)
end

return M
