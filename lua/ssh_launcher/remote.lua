---@mod ssh_launcher.remote Remote files
---
--- Browsing and transferring files on a saved host, using whichever remote
--- adapter the user already has. Paths are passed as argv elements, so a
--- filename containing a space or a quote is not a command injection.

local util = require("ssh_launcher.util")
local log = require("ssh_launcher.log")
local Host = require("ssh_launcher.host")

local M = {}

--- `[user@]host[:port]` in the shape URL adapters expect.
---@param h ssh_launcher.Host
---@param with_port boolean|nil
---@return string
local function authority(h, with_port)
  local target = h.user and ("%s@%s"):format(h.user, h.host) or h.host
  if with_port and h.port and h.port ~= 22 then
    target = ("%s:%d"):format(target, h.port)
  end
  return target
end

--- Which remote-file adapter is available, most capable first.
---@return string|nil name
function M.adapter()
  local ok, oil = pcall(require, "oil")
  if ok and oil then
    -- oil.nvim ships an ssh adapter and handles ports in the URL.
    return "oil"
  end
  if vim.fn.exists(":Explore") == 2 or vim.g.loaded_netrwPlugin == 1 then
    return "netrw"
  end
  return nil
end

--- Open a remote directory for browsing.
---@param h ssh_launcher.Host
---@param path string|nil defaults to the host's remote_dir, then the home dir
---@return boolean ok
function M.browse(h, path)
  path = util.nonblank(path) or h.remote_dir or "."
  local adapter = M.adapter()

  if adapter == "oil" then
    local url = ("oil-ssh://%s/%s"):format(authority(h, true), (path:gsub("^/", "")))
    local ok, err = pcall(vim.cmd.edit, url)
    if ok then
      log.announce(("browsing %s on %s"):format(path, Host.label(h)))
      return true
    end
    log.error(("oil could not open %s: %s"):format(url, tostring(err)))
    return false
  end

  if adapter == "netrw" then
    if h.port and h.port ~= 22 then
      -- netrw takes the port from a global, not the URL.
      vim.g.netrw_port = tostring(h.port)
    end
    -- The double slash is netrw's marker for an absolute remote path.
    local url = ("scp://%s/%s"):format(authority(h), (path:gsub("^/", "//")))
    local ok, err = pcall(vim.cmd.edit, url)
    if ok then
      log.announce(("browsing %s on %s"):format(path, Host.label(h)))
      return true
    end
    log.error(("netrw could not open %s: %s"):format(url, tostring(err)))
    return false
  end

  log.error("no remote file adapter available — install oil.nvim, or enable netrw")
  return false
end

---@param h ssh_launcher.Host
---@return string[] argv prefix carrying this host's port and identity
local function scp_prefix(h)
  local cfg = require("ssh_launcher.config").get()
  local argv = { "scp" }
  if h.port and h.port ~= 22 then
    argv[#argv + 1] = "-P" -- scp spells it with a capital
    argv[#argv + 1] = tostring(h.port)
  end
  if h.identity_file then
    argv[#argv + 1] = "-i"
    argv[#argv + 1] = util.expand(h.identity_file)
    if h.identities_only ~= false then
      argv[#argv + 1] = "-o"
      argv[#argv + 1] = "IdentitiesOnly=yes"
    end
  end
  if h.proxy_jump then
    argv[#argv + 1] = "-J"
    argv[#argv + 1] = h.proxy_jump
  end
  local strict = h.strict_host_key_checking or cfg.ssh.strict_host_key_checking
  if strict == "no" and not cfg.diagnostics.allow_insecure then
    strict = "accept-new"
  end
  argv[#argv + 1] = "-o"
  argv[#argv + 1] = ("StrictHostKeyChecking=%s"):format(strict)
  return argv
end

--- The scp argv for a transfer. Every path is its own element, so a filename
--- containing a space, a quote or a semicolon is data rather than syntax.
---@param direction "get"|"put"
---@param h ssh_launcher.Host
---@param remote_path string
---@param local_path string
---@return string[]
function M.scp_argv(direction, h, remote_path, local_path)
  local argv = scp_prefix(h)
  argv[#argv + 1] = "-p" -- keep timestamps and mode
  local remote = ("%s:%s"):format(authority(h), remote_path)

  if direction == "get" then
    argv[#argv + 1] = remote
    argv[#argv + 1] = util.expand(local_path)
  else
    argv[#argv + 1] = util.expand(local_path)
    argv[#argv + 1] = remote
  end
  return argv
end

---@param direction "get"|"put"
---@param h ssh_launcher.Host
---@param remote_path string
---@param local_path string
---@param cb fun(ok: boolean, msg: string)|nil
local function transfer(direction, h, remote_path, local_path, cb)
  cb = cb or function() end

  if not util.has_executable("scp") then
    return cb(false, "scp is not installed")
  end
  if util.blank(remote_path) or util.blank(local_path) then
    return cb(false, "both a remote and a local path are needed")
  end

  local argv = M.scp_argv(direction, h, remote_path, local_path)

  -- scp may need a passphrase and prints progress, so it runs in a terminal
  -- rather than being swallowed by a background job.
  require("ssh_launcher.terminal").run(argv, {
    title = ("scp %s %s"):format(direction, Host.label(h)),
    strategy = "float",
    width = 0.7,
    height = 12,
    close_on_exit = true,
    on_exit = function(code)
      if code == 0 then
        local msg = direction == "get" and ("fetched %s"):format(remote_path) or ("uploaded to %s"):format(remote_path)
        log.info(msg)
        cb(true, msg)
      else
        cb(false, ("scp exited with %d"):format(code))
      end
    end,
  })
end

--- Copy a file down from the host.
---@param h ssh_launcher.Host
---@param remote_path string
---@param local_path string
---@param cb fun(ok: boolean, msg: string)|nil
function M.get(h, remote_path, local_path, cb)
  transfer("get", h, remote_path, local_path, cb)
end

--- Copy a file up to the host.
---@param h ssh_launcher.Host
---@param local_path string
---@param remote_path string
---@param cb fun(ok: boolean, msg: string)|nil
function M.put(h, local_path, remote_path, cb)
  transfer("put", h, remote_path, local_path, cb)
end

--- Ask for the two paths, then transfer. Defaults are chosen so the common
--- case — send the file I am editing — is two keystrokes.
---@param h ssh_launcher.Host
---@param direction "get"|"put"
function M.prompt_transfer(h, direction)
  local dialog = require("ssh_launcher.ui.dialog")
  local current = vim.api.nvim_buf_get_name(0)
  local base = current ~= "" and util.basename(current) or ""
  local remote_default = util.join(h.remote_dir or ".", base)

  if direction == "put" then
    dialog.input({ prompt = "Local file: ", default = current, completion = "file" }, function(local_path)
      if not local_path then
        return
      end
      dialog.input({ prompt = ("Copy to %s: "):format(Host.label(h)), default = remote_default }, function(remote_path)
        if remote_path then
          M.put(h, local_path, remote_path)
        end
      end)
    end)
  else
    dialog.input({ prompt = ("Fetch from %s: "):format(Host.label(h)), default = remote_default }, function(remote_path)
      if not remote_path then
        return
      end
      local suggestion = util.join(vim.fn.getcwd(), util.basename(remote_path))
      dialog.input({ prompt = "Save as: ", default = suggestion, completion = "file" }, function(local_path)
        if local_path then
          M.get(h, remote_path, local_path)
        end
      end)
    end)
  end
end

return M
