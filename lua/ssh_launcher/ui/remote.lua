---@mod ssh_launcher.ui.remote Built-in remote workspace
---
--- A deliberately small file browser backed by ssh_launcher.remote. Directory
--- buffers navigate like a local explorer; files are ordinary listed `acwrite`
--- buffers whose `:write` sends the current text back over SSH.

local util = require("ssh_launcher.util")
local log = require("ssh_launcher.log")
local Host = require("ssh_launcher.host")
local remote = require("ssh_launcher.remote")
local render = require("ssh_launcher.ui.render")
local theme = require("ssh_launcher.ui.theme")

local M = {}

local ns = vim.api.nvim_create_namespace("ssh_launcher_remote")

---@class ssh_launcher.RemoteBrowser
---@field buf integer
---@field host ssh_launcher.Host
---@field path string
---@field entries table<integer, ssh_launcher.RemoteEntry|{name:string,type:"parent"}>
---@field _listing ssh_launcher.RemoteEntry[]
---@field loading boolean

---@type table<integer, { host: ssh_launcher.Host, path: string, writing: boolean }>
local files = {}

---@param buf integer
---@param lhs string|string[]
---@param rhs function
---@param desc string
local function map(buf, lhs, rhs, desc)
  for _, key in ipairs(type(lhs) == "table" and lhs or { lhs }) do
    vim.keymap.set("n", key, rhs, { buffer = buf, nowait = true, silent = true, desc = "SSH: " .. desc })
  end
end

---@param h ssh_launcher.Host
---@param path string
---@return string
local function file_uri(h, path)
  local id = tostring(h.id or h.host):gsub("[^%w_.-]", function(char)
    return ("%%%02X"):format(char:byte())
  end)
  local encoded = path:gsub("%%", "%%25"):gsub("#", "%%23"):gsub("?", "%%3F")
  return ("ssh-launcher://%s%s"):format(id, encoded:sub(1, 1) == "/" and encoded or "/" .. encoded)
end

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

---@param state ssh_launcher.RemoteBrowser
---@param message string|nil
local function draw_browser(state, message)
  if not vim.api.nvim_buf_is_valid(state.buf) then
    return
  end

  local lines = {
    {
      { "Remote  ", theme.hl("Label") },
      { Host.label(state.host), theme.hl("Name") },
      { "  " .. Host.target(state.host), theme.hl("Target") },
    },
    { { "Path    ", theme.hl("Label") }, { state.path, theme.hl("Value") } },
    {
      { "<CR> open  ", theme.hl("KeyHint") },
      { "- parent  ", theme.hl("KeyHint") },
      { "r refresh  ", theme.hl("KeyHint") },
      { "q close", theme.hl("KeyHint") },
    },
    { { "" } },
  }

  state.entries = {}
  if message then
    lines[#lines + 1] = { { message, state.loading and theme.hl("Muted") or theme.hl("Error") } }
  else
    if state.path ~= "/" then
      lines[#lines + 1] = { { "[..]  parent directory", theme.hl("Muted") } }
      state.entries[#lines] = { name = "..", type = "parent" }
    end
    for _, entry in ipairs(state._listing or {}) do
      local marker = ({ directory = "[d]", file = "[f]", link = "[@]", other = "[?]" })[entry.type] or "[?]"
      local suffix = entry.type == "directory" and "/" or ""
      lines[#lines + 1] = {
        { marker .. "  ", entry.type == "directory" and theme.hl("Key") or theme.hl("Muted") },
        { util.single_line(entry.name) .. suffix, entry.type == "directory" and theme.hl("Name") or theme.hl("Value") },
      }
      state.entries[#lines] = entry
    end
    if #(state._listing or {}) == 0 then
      lines[#lines + 1] = { { "(empty directory)", theme.hl("Muted") } }
    end
  end

  render.draw(state.buf, ns, lines)
  vim.bo[state.buf].modifiable = false
end

---@param state ssh_launcher.RemoteBrowser
local function refresh(state)
  if state.loading or not vim.api.nvim_buf_is_valid(state.buf) then
    return
  end
  state.loading = true
  draw_browser(state, "loading remote directory…")
  remote.list(state.host, state.path, function(path, entries, err)
    if not vim.api.nvim_buf_is_valid(state.buf) then
      return
    end
    state.loading = false
    if err then
      draw_browser(state, err .. "  (press r to retry)")
      log.error(("%s: %s"):format(Host.label(state.host), err))
      return
    end
    state.path = path
    state._listing = entries
    draw_browser(state)
    local first = state.path == "/" and 5 or 6
    local win = vim.fn.bufwinid(state.buf)
    if win ~= -1 then
      pcall(vim.api.nvim_win_set_cursor, win, { math.min(first, vim.api.nvim_buf_line_count(state.buf)), 0 })
    end
    log.announce(("browsing %s on %s"):format(path, Host.label(state.host)))
  end)
end

---@param data string
---@return string[]|nil lines, string|nil fileformat, boolean|nil endofline, string|nil err
function M.decode(data)
  if data:find("\0", 1, true) then
    return nil, nil, nil, "binary files cannot be edited in the remote text buffer"
  end
  local fileformat = data:find("\r\n", 1, true) and "dos" or "unix"
  if fileformat == "dos" then
    data = data:gsub("\r\n", "\n")
  end
  local endofline = data:sub(-1) == "\n"
  local lines = vim.split(data, "\n", { plain = true })
  if endofline then
    table.remove(lines)
  end
  if #lines == 0 then
    lines = { "" }
  end
  return lines, fileformat, endofline, nil
end

---@param buf integer
---@return string
function M.encode(buf)
  local separator = vim.bo[buf].fileformat == "dos" and "\r\n" or "\n"
  local data = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), separator)
  if vim.bo[buf].endofline then
    data = data .. separator
  end
  return data
end

---@param buf integer
local function save_file(buf)
  local state = files[buf]
  if not state or state.writing or not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  state.writing = true
  local tick = vim.api.nvim_buf_get_changedtick(buf)
  local data = M.encode(buf)
  log.info(("writing %s to %s…"):format(state.path, Host.label(state.host)))
  remote.write(state.host, state.path, data, function(ok, err)
    if not vim.api.nvim_buf_is_valid(buf) then
      return
    end
    state.writing = false
    if not ok then
      log.error(("could not write %s: %s"):format(state.path, err or "unknown error"))
      return
    end
    if vim.api.nvim_buf_get_changedtick(buf) == tick then
      vim.bo[buf].modified = false
      log.info(("wrote %s on %s"):format(state.path, Host.label(state.host)))
    else
      log.warn(("wrote %s, but the buffer has newer unsaved changes"):format(state.path))
    end
  end)
end

---@param h ssh_launcher.Host
---@param path string
---@param opts { command: "edit"|"split"|"vsplit"|"tabedit"|nil }|nil
function M.edit(h, path, opts)
  opts = opts or {}
  if path:find("[%z\1-\31\127]") then
    return log.error("remote paths containing control characters cannot be opened as editor buffers")
  end

  local uri = file_uri(h, path)
  local existing = vim.fn.bufnr(uri)
  if existing >= 0 and vim.api.nvim_buf_is_valid(existing) then
    if opts.command and opts.command ~= "edit" then
      vim.cmd(opts.command)
    end
    vim.api.nvim_win_set_buf(0, existing)
    return existing
  end

  if opts.command and opts.command ~= "edit" then
    vim.cmd(opts.command)
  end
  local buf = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_name(buf, uri)
  vim.api.nvim_win_set_buf(0, buf)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "hide"
  vim.bo[buf].swapfile = false
  vim.b[buf].ssh_launcher_remote = true
  vim.b[buf].ssh_launcher_remote_path = path
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "loading " .. path .. "…" })
  vim.bo[buf].modifiable = false

  remote.read(h, path, function(data, err)
    if not vim.api.nvim_buf_is_valid(buf) then
      return
    end
    if err then
      vim.bo[buf].modifiable = true
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "Could not open remote file", "", err })
      vim.bo[buf].modifiable = false
      map(buf, "r", function()
        vim.api.nvim_buf_delete(buf, { force = true })
        M.edit(h, path, { command = "edit" })
      end, "Retry")
      map(buf, "q", function()
        vim.api.nvim_buf_delete(buf, { force = true })
      end, "Close")
      log.error(("could not open %s: %s"):format(path, err))
      return
    end
    local lines, fileformat, endofline, decode_err = M.decode(data)
    if decode_err then
      vim.bo[buf].modifiable = true
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, { decode_err })
      vim.bo[buf].modifiable = false
      map(buf, "q", function()
        vim.api.nvim_buf_delete(buf, { force = true })
      end, "Close")
      log.error(decode_err)
      return
    end

    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].buftype = "acwrite"
    vim.bo[buf].fileformat = fileformat
    vim.bo[buf].fixendofline = false
    vim.bo[buf].endofline = endofline
    vim.bo[buf].modified = false
    files[buf] = { host = h, path = path, writing = false }

    local detected = vim.filetype.match({ filename = path, buf = buf })
    if detected then
      vim.bo[buf].filetype = detected
    end
    vim.api.nvim_create_autocmd("BufWriteCmd", {
      buffer = buf,
      desc = "Write an ssh-launcher remote file",
      callback = function()
        save_file(buf)
      end,
    })
    vim.api.nvim_create_autocmd("BufWipeout", {
      buffer = buf,
      once = true,
      callback = function()
        files[buf] = nil
      end,
    })
    log.announce(("editing %s on %s; :write saves it remotely"):format(path, Host.label(h)))
  end)
  return buf
end

---@param state ssh_launcher.RemoteBrowser
---@param command "edit"|"split"|"vsplit"|"tabedit"|nil
local function open_entry(state, command)
  local entry = state.entries[vim.api.nvim_win_get_cursor(0)[1]]
  if not entry then
    return
  end
  if entry.type == "parent" then
    state.path = parent_path(state.path)
    return refresh(state)
  end
  local path = child_path(state.path, entry.name)
  if entry.type == "directory" then
    state.path = path
    return refresh(state)
  end
  M.edit(state.host, path, { command = command })
end

---@param h ssh_launcher.Host
---@param path string
---@return integer buf
function M.browse(h, path)
  local buf = vim.api.nvim_create_buf(false, true)
  local state = { buf = buf, host = h, path = path, entries = {}, loading = false, _listing = {} }
  vim.api.nvim_buf_set_name(buf, ("ssh-launcher-browser://%s/%d"):format(h.id or h.host, buf))
  vim.api.nvim_win_set_buf(0, buf)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "hide"
  vim.bo[buf].swapfile = false
  vim.bo[buf].modifiable = false
  vim.bo[buf].filetype = "ssh-launcher-remote"
  vim.bo[buf].buflisted = false
  vim.b[buf].ssh_launcher_remote = true

  map(buf, { "<CR>", "l", "e" }, function()
    open_entry(state, "edit")
  end, "Open")
  map(buf, "<C-x>", function()
    open_entry(state, "split")
  end, "Open in split")
  map(buf, "<C-v>", function()
    open_entry(state, "vsplit")
  end, "Open in vertical split")
  map(buf, "<C-t>", function()
    open_entry(state, "tabedit")
  end, "Open in tab")
  map(buf, { "-", "h" }, function()
    state.path = parent_path(state.path)
    refresh(state)
  end, "Parent directory")
  map(buf, { "r", "R" }, function()
    refresh(state)
  end, "Refresh")
  map(buf, { "q", "<C-c>" }, function()
    vim.api.nvim_buf_delete(buf, { force = true })
  end, "Close")
  refresh(state)
  return buf
end

return M
