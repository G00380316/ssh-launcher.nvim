---@mod ssh_launcher.transfer Sending and fetching files
---
--- What `:Ssh upload` and `:Ssh download` (and the manager's `U`/`W`) do before
--- and after scp runs: turn what the user typed into real paths, choose
--- defaults, and refuse the mistakes that are cheap to catch up front — a typo'd
--- file, a missing destination directory, an unintended overwrite, a stray
--- upload to production. The copy itself is |ssh_launcher.remote|.

local util = require("ssh_launcher.util")
local log = require("ssh_launcher.log")
local Host = require("ssh_launcher.host")
local config = require("ssh_launcher.config")

local M = {}

---@class ssh_launcher.TransferOpts
---@field force boolean|nil skip the production and overwrite confirmations
---@field on_done fun(ok: boolean, msg: string)|nil

---@param opts ssh_launcher.TransferOpts
---@param msg string
local function fail(opts, msg)
  log.error(msg)
  if opts.on_done then
    opts.on_done(false, msg)
  end
end

---@param value string
---@return boolean
local function has_glob(value)
  return value:find("[%*%?%[]") ~= nil
end

--- Absolute form of a local path: `~` and variables expanded, no trailing slash.
--- Always absolute so a relative name can never be read as an scp option.
---@param path string
---@return string
function M.absolute(path)
  local full = vim.fn.fnamemodify(util.expand(path), ":p")
  if #full > 1 then
    full = full:gsub("/+$", "")
  end
  return full
end

--- The file in the current buffer, if it is one.
---@return string|nil path, string|nil err
local function current_file()
  local name = vim.api.nvim_buf_get_name(0)
  if name == "" or vim.bo.buftype ~= "" then
    return nil, "the current buffer is not a file"
  end
  return name, nil
end

--- Turn what was typed into existing local paths.
---
--- `~` and `$VAR` expand, `%` is the current file, and a pattern such as
--- `logs/*.gz` matches files. A name that exists literally always wins over a
--- pattern reading, so a file called `a[1].txt` can still be sent.
---@param inputs string[]
---@return string[]|nil paths, string|nil err
function M.resolve_local(inputs)
  local paths, seen = {}, {}
  local function add(path)
    local abs = M.absolute(path)
    if not seen[abs] then
      seen[abs] = true
      paths[#paths + 1] = abs
    end
  end

  for _, input in ipairs(inputs) do
    local path = input
    if path == "%" then
      local current, err = current_file()
      if not current then
        return nil, err
      end
      path = current
    end
    path = util.expand(path)

    if util.exists(path) then
      add(path)
    elseif has_glob(path) then
      local matches = vim.fn.glob(path, true, true)
      if #matches == 0 then
        return nil, ("nothing matches %s"):format(input)
      end
      for _, match in ipairs(matches) do
        add(match)
      end
    else
      return nil, ("no such file or directory: %s"):format(input)
    end
  end

  if #paths == 0 then
    return nil, "there is nothing to send"
  end
  return paths, nil
end

--- Where an upload lands when no destination is given: the host's landing
--- directory, or the login directory. The trailing slash makes scp insist it
--- is a directory, so a mistyped `remote_dir` is an error instead of a file.
---@param h ssh_launcher.Host
---@return string
function M.default_remote(h)
  local dir = util.nonblank(h.remote_dir) or "."
  return (dir:gsub("/+$", "")) .. "/"
end

--- Warn about buffers whose unsaved edits the upload will not include.
---@param paths string[]
local function warn_unsaved(paths)
  local wanted = {}
  for _, path in ipairs(paths) do
    wanted[path] = true
  end
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) and vim.bo[buf].modified then
      local name = vim.api.nvim_buf_get_name(buf)
      if wanted[name] then
        log.warn(("%s has unsaved changes — sending the saved version"):format(util.basename(name)))
      end
    end
  end
end

--- Ask before sending anything to a production-tagged host.
---@param h ssh_launcher.Host
---@param paths string[]
---@param remote_path string
---@param opts ssh_launcher.TransferOpts
---@param proceed fun()
function M.gate_production(h, paths, remote_path, opts, proceed)
  if opts.force or not config.get().security.confirm_production or not Host.is_production(h) then
    return proceed()
  end
  local lines = {}
  for i, path in ipairs(paths) do
    if i > 5 then
      lines[#lines + 1] = ("…and %d more"):format(#paths - 5)
      break
    end
    lines[#lines + 1] = util.contract(path)
  end
  lines[#lines + 1] = ""
  lines[#lines + 1] = ("to %s:%s"):format(Host.target(h), remote_path)
  lines[#lines + 1] = "This host is tagged as production."
  require("ssh_launcher.ui.dialog").confirm({
    title = ("Upload to %s?"):format(Host.label(h)),
    lines = lines,
    yes = "Upload to production",
    no = "Cancel",
    destructive = true,
    default_no = true,
  }, function(confirmed)
    if confirmed then
      proceed()
    end
  end)
end

--- Send local files or directories to a host.
---
--- With no `inputs` the user is asked. With no `remote_path` the files go to the
--- host's landing directory.
---@param h ssh_launcher.Host
---@param inputs string[]|nil local paths as typed
---@param remote_path string|nil
---@param opts ssh_launcher.TransferOpts|nil
function M.upload(h, inputs, remote_path, opts)
  opts = opts or {}
  if not inputs or #inputs == 0 then
    return M.prompt(h, "put", opts)
  end

  local paths, err = M.resolve_local(inputs)
  if not paths then
    return fail(opts, err)
  end
  remote_path = util.nonblank(remote_path) or M.default_remote(h)

  warn_unsaved(paths)
  M.gate_production(h, paths, remote_path, opts, function()
    require("ssh_launcher.remote").put(h, paths, remote_path, function(ok, msg)
      if opts.on_done then
        opts.on_done(ok, msg)
      end
    end)
  end)
end

--- The path a download will create, when that can be known: the remote name
--- inside an existing destination directory, or the destination itself.
---@param remote_path string
---@param dest string absolute
---@return string|nil
local function landing(remote_path, dest)
  if not util.is_dir(dest) then
    return dest
  end
  if has_glob(remote_path) then
    return nil
  end
  local name = util.basename((remote_path:gsub("/+$", "")))
  if name == "" or name == "." or name == ".." or name == "~" then
    return nil
  end
  return util.join(dest, name)
end

--- Fetch a file or directory from a host.
---
--- With no `remote_path` the user is asked. With no `local_path` the download
--- goes into the current directory. Nothing local is overwritten without asking.
---@param h ssh_launcher.Host
---@param remote_path string|nil
---@param local_path string|nil
---@param opts ssh_launcher.TransferOpts|nil
function M.download(h, remote_path, local_path, opts)
  opts = opts or {}
  if util.blank(remote_path) then
    return M.prompt(h, "get", opts)
  end

  local typed = util.nonblank(local_path)
  local dest = M.absolute(typed or vim.fn.getcwd())

  if not util.exists(dest) then
    if typed and typed:find("/$") then
      return fail(opts, ("no such directory: %s"):format(typed))
    end
    local parent = util.dirname(dest)
    if not util.is_dir(parent) then
      return fail(opts, ("no such directory: %s"):format(util.contract(parent)))
    end
  end

  local function proceed()
    require("ssh_launcher.remote").get(h, remote_path, dest, function(ok, msg)
      if opts.on_done then
        opts.on_done(ok, msg)
      end
    end)
  end

  local target = landing(remote_path, dest)
  if opts.force or not target or not util.exists(target) then
    return proceed()
  end

  require("ssh_launcher.ui.dialog").confirm({
    title = "Overwrite local file?",
    lines = { util.contract(target), "", ("already exists; %s would replace it."):format(Host.label(h)) },
    yes = "Overwrite",
    no = "Cancel",
    destructive = true,
    default_no = true,
  }, function(confirmed)
    if confirmed then
      proceed()
    end
  end)
end

--- Ask for the paths, then transfer. Defaults make the common case — send the
--- file I am editing — two keystrokes.
---@param h ssh_launcher.Host
---@param direction "get"|"put"
---@param opts ssh_launcher.TransferOpts|nil
function M.prompt(h, direction, opts)
  opts = opts or {}
  local dialog = require("ssh_launcher.ui.dialog")
  local current = current_file()
  local base = current and util.basename(current) or ""
  local landing_dir = util.nonblank(h.remote_dir) or "."

  if direction == "put" then
    dialog.input({ prompt = "Local path: ", default = current or "", completion = "file" }, function(value)
      if not value then
        return
      end
      local paths, err = M.resolve_local({ value })
      if not paths then
        return fail(opts, err)
      end
      -- A single file can be named on arrival; anything else lands in a directory.
      local default = M.default_remote(h)
      if #paths == 1 and not util.is_dir(paths[1]) then
        default = util.join(landing_dir, util.basename(paths[1]))
      end
      dialog.input({ prompt = ("Copy to %s: "):format(Host.label(h)), default = default }, function(remote_path)
        if remote_path then
          M.upload(h, paths, remote_path, opts)
        end
      end)
    end)
  else
    dialog.input({
      prompt = ("Fetch from %s: "):format(Host.label(h)),
      default = util.join(landing_dir, base),
    }, function(remote_path)
      if not remote_path then
        return
      end
      local suggestion = util.join(vim.fn.getcwd(), util.basename((remote_path:gsub("/+$", ""))))
      dialog.input({ prompt = "Save as: ", default = suggestion, completion = "file" }, function(local_path)
        if local_path then
          M.download(h, remote_path, local_path, opts)
        end
      end)
    end)
  end
end

return M
