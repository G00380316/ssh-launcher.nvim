---@mod ssh_launcher.remote Remote files
---
--- Browsing, editing and transferring files on a saved host. The built-in
--- adapter uses the same identity, jump host, port and ssh options as terminal
--- sessions. Oil and netrw remain available for users who prefer their native
--- remote adapters.

local util = require("ssh_launcher.util")
local log = require("ssh_launcher.log")
local Host = require("ssh_launcher.host")

local M = {}

--- `[user@]host[:port]` in the shape URL adapters expect.
---@param h ssh_launcher.Host
---@param with_port boolean|nil
---@return string
local function authority(h, with_port)
  local hostname = h.host:find(":", 1, true) and ("[%s]"):format(h.host) or h.host
  local target = h.user and ("%s@%s"):format(h.user, hostname) or hostname
  if with_port and h.port and h.port ~= 22 then
    target = ("%s:%d"):format(target, h.port)
  end
  return target
end

---@param name string
---@return boolean
local function adapter_available(name)
  if name == "builtin" then
    return util.has_executable(require("ssh_launcher.config").get().ssh.binary)
  elseif name == "oil" then
    local ok, oil = pcall(require, "oil")
    return ok and oil ~= nil
  elseif name == "netrw" then
    return vim.fn.exists(":Explore") == 2 or vim.g.loaded_netrwPlugin == 1
  end
  return false
end

--- Which remote-file adapter will be used. The built-in implementation is the
--- default because, unlike URL adapters, it can carry every saved host option.
---@return string|nil name
function M.adapter()
  local wanted = (require("ssh_launcher.config").get().remote or {}).adapter or "builtin"
  if wanted ~= "auto" and adapter_available(wanted) then
    return wanted
  end

  local order = wanted == "auto" and { "oil", "netrw", "builtin" } or { "builtin", "oil", "netrw" }
  for _, name in ipairs(order) do
    if adapter_available(name) then
      if wanted ~= "auto" and wanted ~= name then
        log.warn(("remote.adapter = %q is unavailable; using %s"):format(wanted, name))
      end
      return name
    end
  end
  return nil
end

--- Quote data for the remote POSIX shell. Remote commands necessarily pass
--- through that shell; keeping all user-controlled paths inside a single-quoted
--- word prevents them from becoming syntax there.
---@param value string
---@return string
function M.shell_quote(value)
  return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end

--- Build an unattended SSH command without inheriting an interactive host's
--- landing command, TTY, forwards or agent forwarding.
---@param h ssh_launcher.Host
---@param command string
---@return string[]
function M.command_argv(h, command)
  local command_host = vim.deepcopy(h)
  command_host.remote_dir = nil
  command_host.remote_command = command
  command_host.request_tty = false
  command_host.forwards = {}
  command_host.forward_agent = false
  return Host.build_argv(command_host, { batch = true })
end

---@param h ssh_launcher.Host
---@param command string
---@param opts table|nil
---@param cb fun(res: ssh_launcher.SystemResult)
local function run(h, command, opts, cb)
  opts = opts or {}
  opts.timeout = opts.timeout or (require("ssh_launcher.config").get().remote or {}).timeout or 30000
  util.system(M.command_argv(h, command), opts, cb)
end

--- The portable directory script intentionally uses shell tests instead of
--- `find -printf`: the latter is absent on BSD/macOS hosts. Its NUL-separated
--- protocol preserves spaces, tabs and newlines in filenames.
---@param path string
---@return string
function M.list_command(path)
  return table.concat({
    "path=" .. M.shell_quote(path),
    [[case "$path" in '~') path=$HOME ;; '~/'*) path="$HOME/${path#\~/}" ;; -*) path="./$path" ;; esac]],
    [[cd -P "$path" 2>/dev/null || { printf '%s\n' "cannot open directory: $path" >&2; exit 3; }]],
    [[printf '%s\000' "$PWD"]],
    [[for entry in .[!.]* ..?* *; do]],
    [[  { [ -e "$entry" ] || [ -L "$entry" ]; } || continue]],
    [[  if [ -d "$entry" ]; then kind=d; elif [ -f "$entry" ]; then kind=f; elif [ -L "$entry" ]; then kind=l; else kind=o; fi]],
    [[  printf '%s\000%s\000' "$kind" "$entry"]],
    [[done]],
  }, "\n")
end

---@class ssh_launcher.RemoteEntry
---@field name string
---@field type "directory"|"file"|"link"|"other"

--- Decode the private NUL-separated listing protocol.
---@param output string
---@return string|nil path, ssh_launcher.RemoteEntry[]|nil entries, string|nil err
function M.parse_listing(output)
  output = output or ""
  local fields, from = {}, 1
  while from <= #output do
    local stop = output:find("\0", from, true)
    if not stop then
      return nil, nil, "the host returned a truncated directory listing"
    end
    fields[#fields + 1] = output:sub(from, stop - 1)
    from = stop + 1
  end
  local path = table.remove(fields, 1)
  if util.blank(path) then
    return nil, nil, "the host returned an invalid directory listing"
  end
  if #fields % 2 ~= 0 then
    return nil, nil, "the host returned a truncated directory listing"
  end

  local kinds = { d = "directory", f = "file", l = "link", o = "other" }
  local entries = {}
  for i = 1, #fields, 2 do
    entries[#entries + 1] = { type = kinds[fields[i]] or "other", name = fields[i + 1] }
  end
  table.sort(entries, function(a, b)
    if (a.type == "directory") ~= (b.type == "directory") then
      return a.type == "directory"
    end
    return a.name:lower() < b.name:lower()
  end)
  return path, entries, nil
end

---@param res ssh_launcher.SystemResult
---@param fallback string
---@return string
local function result_error(res, fallback)
  local message = util.nonblank(res.stderr) or util.nonblank(res.stdout) or fallback
  return (util.trim(message):gsub("%s+$", ""))
end

--- List a directory and resolve it to its absolute remote path.
---@param h ssh_launcher.Host
---@param path string
---@param cb fun(path: string|nil, entries: ssh_launcher.RemoteEntry[]|nil, err: string|nil)
function M.list(h, path, cb)
  run(h, M.list_command(path), { text = false }, function(res)
    if not res.ok then
      return cb(nil, nil, result_error(res, "could not list the remote directory"))
    end
    local resolved, entries, err = M.parse_listing(res.stdout)
    cb(resolved, entries, err)
  end)
end

--- Read a remote file as bytes. The UI decides whether those bytes are safe to
--- represent in a text buffer.
---@param h ssh_launcher.Host
---@param path string
---@param cb fun(data: string|nil, err: string|nil)
function M.read(h, path, cb)
  local q = M.shell_quote(path)
  local command = ('path=%s; case "$path" in -*) path="./$path" ;; esac; cat "$path"'):format(q)
  run(h, command, { text = false }, function(res)
    if res.ok then
      cb(res.stdout, nil)
    else
      cb(nil, result_error(res, "could not read the remote file"))
    end
  end)
end

--- Atomically replace a remote file where possible. Existing permissions are
--- copied to the temporary file; symlinks are written through rather than
--- replaced. New files are created private.
---@param h ssh_launcher.Host
---@param path string
---@param data string
---@param cb fun(ok: boolean, err: string|nil)
function M.write(h, path, data, cb)
  local command = table.concat({
    "path=" .. M.shell_quote(path),
    [[case "$path" in -*) path="./$path" ;; esac]],
    [[if [ -L "$path" ]; then cat > "$path"; exit $?; fi]],
    [[dir=${path%/*}; [ "$dir" = "$path" ] && dir=.]],
    [[base=${path##*/}]],
    [[tmp="$dir/.${base}.ssh-launcher.$$"]],
    [[trap 'rm -f "$tmp"' 0 HUP INT TERM]],
    [[umask 077]],
    [[if [ -e "$path" ]; then cp -p "$path" "$tmp" || exit 4; else : > "$tmp" || exit 4; fi]],
    [[cat > "$tmp" || exit 5]],
    [[mv -f "$tmp" "$path" || exit 6]],
    [[trap - 0 HUP INT TERM]],
  }, "; ")
  run(h, command, { stdin = data, text = false }, function(res)
    if res.ok then
      cb(true, nil)
    else
      cb(false, result_error(res, "could not write the remote file"))
    end
  end)
end

---@param h ssh_launcher.Host
---@param proceed fun()
local function with_auth(h, proceed)
  local cfg = require("ssh_launcher.config").get()
  local state = require("ssh_launcher.agent").unlock_state(h.identity_file)
  if not state.needed or cfg.ssh.auto_add_keys == "never" then
    return proceed()
  end

  local agent = require("ssh_launcher.agent")
  local function unlock()
    agent.add(h.identity_file, { apple_keychain = true }, function(ok)
      if ok then
        -- ssh-add's terminal closes immediately after its on_exit callback.
        -- Open the browser on the following tick, in the restored editor
        -- window, rather than inside the terminal that is about to disappear.
        vim.schedule(proceed)
      else
        log.error("remote files need the host key unlocked in ssh-agent")
      end
    end)
  end
  local function start_and_unlock()
    if state.reason ~= "no-agent" then
      return unlock()
    end
    agent.start(function(ok, msg)
      if not ok then
        return log.error(msg)
      end
      unlock()
    end)
  end

  if cfg.ssh.auto_add_keys == "always" then
    return start_and_unlock()
  end
  require("ssh_launcher.ui.dialog").confirm({
    title = "Unlock the key for remote files?",
    lines = { state.detail, "", "The file browser runs SSH commands in the background." },
    yes = "Unlock and browse",
    no = "Cancel",
    default_no = false,
  }, function(confirmed)
    if confirmed then
      start_and_unlock()
    end
  end)
end

--- Open a remote directory for browsing.
---@param h ssh_launcher.Host
---@param path string|nil defaults to the host's remote_dir, then the home dir
---@return boolean ok
function M.browse(h, path)
  path = util.nonblank(path) or h.remote_dir or "."
  local adapter = M.adapter()

  if adapter == "builtin" then
    with_auth(h, function()
      require("ssh_launcher.ui.remote").browse(h, path)
    end)
    return true
  end

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

  log.error("no remote file adapter available — check that OpenSSH is installed")
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
