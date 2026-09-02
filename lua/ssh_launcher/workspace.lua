---@mod ssh_launcher.workspace Configured Neovim sessions over SSH
---
--- Packages the current local Neovim configuration, copies it to a private
--- per-session directory on the host, and starts Neovim there. Configuration
--- is temporary; plugin data and caches persist in an isolated remote root so
--- subsequent sessions do not reinstall everything.

local util = require("ssh_launcher.util")
local log = require("ssh_launcher.log")
local Host = require("ssh_launcher.host")
local config = require("ssh_launcher.config")
local remote = require("ssh_launcher.remote")

local M = {}

---@type table<string, boolean>
local confirmed_hosts = {}

---@param config_dir string
---@param archive string
---@param excludes string[]|nil
---@return string[]
function M.bundle_argv(config_dir, archive, excludes)
  local argv = { "tar", "-czhf", archive }
  for _, pattern in ipairs(excludes or {}) do
    argv[#argv + 1] = "--exclude=" .. pattern
  end
  argv[#argv + 1] = "-C"
  argv[#argv + 1] = config_dir
  argv[#argv + 1] = "."
  return argv
end

---@class ssh_launcher.WorkspaceLaunch
---@field token string
---@field archive string remote archive path
---@field path string remote working directory
---@field remote_root string
---@field binary string
---@field args string[]

--- Build the remote bootstrap. Every configurable value is shell-quoted; the
--- remaining shell is fixed plugin code. The EXIT trap removes both the copied
--- configuration and archive even if Neovim crashes or SSH disconnects.
---@param opts ssh_launcher.WorkspaceLaunch
---@return string
function M.launch_command(opts)
  local quote = remote.shell_quote
  local session_name = "session-" .. tostring(opts.token):gsub("[^%w_.-]", "-")
  local nvim = { quote(opts.binary) }
  for _, arg in ipairs(opts.args or {}) do
    nvim[#nvim + 1] = quote(arg)
  end

  return table.concat({
    "set -eu",
    "umask 077",
    "root=" .. quote(opts.remote_root),
    [[case "$root" in '~') root=$HOME ;; '~/'*) root="$HOME/${root#\~/}" ;; esac]],
    "archive=" .. quote(opts.archive),
    'session="$root/sessions/' .. session_name .. '"',
    [[cleanup() { rm -rf "$session"; rm -f "$archive"; }]],
    [[trap cleanup 0]],
    [[trap 'exit 129' HUP]],
    [[trap 'exit 130' INT]],
    [[trap 'exit 143' TERM]],
    [[mkdir -p "$session/config/nvim" "$root/data" "$root/state" "$root/cache"]],
    [[chmod 700 "$root" "$root/sessions" "$session"]],
    [[tar -xzf "$archive" -C "$session/config/nvim"]],
    [[rm -f "$archive"]],
    "workdir=" .. quote(opts.path),
    [[case "$workdir" in '~') workdir=$HOME ;; '~/'*) workdir="$HOME/${workdir#\~/}" ;; -*) workdir="./$workdir" ;; esac]],
    [[cd -P "$workdir"]],
    "nvim_bin=" .. quote(opts.binary),
    [[if ! command -v "$nvim_bin" >/dev/null 2>&1; then]],
    [[  printf '%s\n' "ssh-launcher: $nvim_bin is not installed on this server" >&2]],
    [[  exit 127]],
    [[fi]],
    ([[XDG_CONFIG_HOME="$session/config" XDG_DATA_HOME="$root/data" XDG_STATE_HOME="$root/state" XDG_CACHE_HOME="$root/cache" %s]]):format(
      table.concat(nvim, " ")
    ),
  }, "\n")
end

---@param h ssh_launcher.Host
---@param command string
---@param token string
---@return ssh_launcher.Host
function M.session_host(h, command, token)
  local session = vim.deepcopy(h)
  session.id = (h.id or h.host) .. ":nvim:" .. token
  session.name = Host.label(h) .. " · Neovim"
  session.source = "workspace"
  session.remote_dir = nil
  session.remote_command = command
  session.request_tty = true
  return session
end

---@param path string
local function remove_local(path)
  pcall(util.uv.fs_unlink, path)
end

---@param h ssh_launcher.Host
---@param path string
---@param opts table
local function package_and_launch(h, path, opts)
  local cfg = config.get().workspace
  local config_dir = util.expand(opts.config_dir or cfg.config_dir)
  if not util.is_dir(config_dir) then
    return log.error(("Neovim config directory does not exist: %s"):format(config_dir))
  end
  if not util.has_executable("tar") then
    return log.error("tar is required to send the Neovim configuration to the server")
  end
  if not util.has_executable("scp") then
    return log.error("scp is required to send the Neovim configuration to the server")
  end

  local token = util.uid():gsub("[^%w_.-]", "-")
  local archive = vim.fn.tempname() .. ".tar.gz"
  local remote_archive = ("/tmp/ssh-launcher-nvim-%s.tar.gz"):format(token)
  -- Create it private before tar opens it. Chmodding only after tar exits would
  -- leave a short window where a config containing tokens could be mode 0644.
  local fd, archive_err = util.uv.fs_open(archive, "w", tonumber("600", 8))
  if not fd then
    return log.error(("could not create a private config archive: %s"):format(archive_err or "unknown error"))
  end
  util.uv.fs_close(fd)
  log.info(("packaging Neovim config from %s…"):format(util.contract(config_dir)))

  util.system(
    M.bundle_argv(config_dir, archive, opts.excludes or cfg.excludes),
    { timeout = cfg.bundle_timeout },
    function(res)
      if not res.ok then
        remove_local(archive)
        return log.error(("could not package Neovim config: %s"):format(util.nonblank(res.stderr) or "tar failed"))
      end
      pcall(util.uv.fs_chmod, archive, tonumber("600", 8))
      log.info(("sending Neovim config to %s…"):format(Host.label(h)))
      remote.put(h, archive, remote_archive, function(ok, message)
        remove_local(archive)
        if not ok then
          return log.error(("could not send Neovim config: %s"):format(message))
        end

        local command = M.launch_command({
          token = token,
          archive = remote_archive,
          path = path,
          remote_root = opts.remote_root or cfg.remote_root,
          binary = opts.binary or cfg.binary,
          args = opts.args or cfg.args,
        })
        local session_host = M.session_host(h, command, token)
        -- The successful scp has already authenticated and verified this exact
        -- host, and the explicit confirmation below covered production. A fresh
        -- session avoids reusing a plain shell that happens to target the host.
        vim.schedule(function()
          require("ssh_launcher.connect").connect(session_host, {
            strategy = opts.strategy or cfg.strategy,
            new = true,
            force = true,
          })
        end)
      end)
    end
  )
end

---@param h ssh_launcher.Host
---@param path string|nil
---@param opts table|nil
function M.open(h, path, opts)
  opts = opts or {}
  local cfg = config.get().workspace
  path = util.nonblank(path) or h.remote_dir or "."

  local function proceed()
    package_and_launch(h, path, opts)
  end

  local needs_confirmation = cfg.confirm and not confirmed_hosts[h.id or h.host]
  local production = config.get().security.confirm_production and Host.is_production(h)
  if not needs_confirmation and not production then
    return proceed()
  end

  local lines = {
    { { ("Local config: %s"):format(util.contract(util.expand(opts.config_dir or cfg.config_dir))) } },
    { { ("Server:       %s"):format(Host.target(h)) } },
    { { ("Remote dir:   %s"):format(path) } },
    { { "" } },
    { { "The config is private and removed when remote Neovim exits." } },
    { { "Plugin data and caches remain in the isolated workspace directory." } },
  }
  if production then
    lines[#lines + 1] = { { "" } }
    lines[#lines + 1] = { { "This host is tagged as production." } }
  end
  require("ssh_launcher.ui.dialog").confirm({
    title = ("Launch configured Neovim on %s?"):format(Host.label(h)),
    lines = lines,
    yes = "Send config and launch",
    no = "Cancel",
    destructive = production,
    default_no = production,
  }, function(confirmed)
    if confirmed then
      confirmed_hosts[h.id or h.host] = true
      proceed()
    end
  end)
end

return M
