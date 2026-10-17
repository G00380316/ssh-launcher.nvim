---@mod ssh_launcher.remote Remote files
---
--- Browsing, editing and transferring files on a saved host. The built-in
--- adapter uses the same identity, jump host, port and ssh options as terminal
--- sessions. Oil and netrw remain available for users who prefer their native
--- remote adapters. The scp layer at the bottom is what |ssh_launcher.transfer|
--- drives for `:Ssh upload` and `:Ssh download`.

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
--- The scripts here are POSIX `sh`, but ssh hands a command to the account's
--- *login* shell, which is often zsh, fish or bash with its own rules. zsh turns
--- an unmatched glob into a fatal error and ties `path` to `$PATH`, so the same
--- text that lists a directory under `sh` fails — or loses `cat` — under zsh.
--- Handing the login shell a one-line `exec sh -c` means it never parses ours.
---@param h ssh_launcher.Host
---@param command string
---@return string[]
function M.command_argv(h, command)
  local command_host = vim.deepcopy(h)
  command_host.remote_dir = nil
  command_host.remote_command = "exec sh -c " .. M.shell_quote(command)
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
---
--- With `detailed`, each entry also carries `size mtime` from whichever of GNU
--- (`stat -c`) or BSD (`stat -f`) `stat` the host has; a host with neither, or
--- an entry that cannot be statted, simply has no metadata.
---@param path string
---@param detailed boolean|nil
---@return string
function M.list_command(path, detailed)
  local emit = [[  printf '%s\000%s\000' "$kind" "$entry"]]
  if detailed then
    emit = table.concat({
      [[  meta=$(stat -L -c '%s %Y' -- "./$entry" 2>/dev/null || stat -L -f '%z %m' -- "./$entry" 2>/dev/null || true)]],
      [[  printf '%s\000%s\000%s\000' "$kind" "$meta" "$entry"]],
    }, "\n")
  end
  return table.concat({
    "path=" .. M.shell_quote(path),
    [[case "$path" in '~') path=$HOME ;; '~/'*) path="$HOME/${path#\~/}" ;; -*) path="./$path" ;; esac]],
    [[cd -P "$path" 2>/dev/null || { printf '%s\n' "cannot open directory: $path" >&2; exit 3; }]],
    [[printf '%s\000' "$PWD"]],
    [[for entry in .[!.]* ..?* *; do]],
    [[  { [ -e "$entry" ] || [ -L "$entry" ]; } || continue]],
    [[  if [ -d "$entry" ]; then kind=d; elif [ -f "$entry" ]; then kind=f; elif [ -L "$entry" ]; then kind=l; else kind=o; fi]],
    emit,
    [[done]],
  }, "\n")
end

---@class ssh_launcher.RemoteEntry
---@field name string
---@field type "directory"|"file"|"link"|"other"
---@field size integer|nil bytes, in detailed listings
---@field mtime integer|nil seconds since the epoch, in detailed listings

--- Decode the private NUL-separated listing protocol.
---@param output string
---@param detailed boolean|nil the output came from `list_command(path, true)`
---@return string|nil path, ssh_launcher.RemoteEntry[]|nil entries, string|nil err
function M.parse_listing(output, detailed)
  output = output or ""
  local stride = detailed and 3 or 2
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
  if #fields % stride ~= 0 then
    return nil, nil, "the host returned a truncated directory listing"
  end

  local kinds = { d = "directory", f = "file", l = "link", o = "other" }
  local entries = {}
  for i = 1, #fields, stride do
    local entry = { type = kinds[fields[i]] or "other", name = fields[i + stride - 1] }
    if detailed then
      -- Anything that is not exactly "<bytes> <epoch>" means the host's stat
      -- spoke a dialect we did not expect; no metadata beats wrong metadata.
      local size, mtime = fields[i + 1]:match("^(%d+) (%d+)$")
      entry.size, entry.mtime = tonumber(size), tonumber(mtime)
    end
    entries[#entries + 1] = entry
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
---@param opts { detailed: boolean|nil }|nil `detailed` adds size and mtime
function M.list(h, path, cb, opts)
  local detailed = opts and opts.detailed
  run(h, M.list_command(path, detailed), { text = false }, function(res)
    if not res.ok then
      return cb(nil, nil, result_error(res, "could not list the remote directory"))
    end
    local resolved, entries, err = M.parse_listing(res.stdout, detailed)
    cb(resolved, entries, err)
  end)
end

--- Create a directory (and any missing parents) on the host.
---@param h ssh_launcher.Host
---@param path string
---@param cb fun(ok: boolean, err: string|nil)
function M.mkdir(h, path, cb)
  local command = table.concat({
    "path=" .. M.shell_quote(path),
    [[case "$path" in '~') path=$HOME ;; '~/'*) path="$HOME/${path#\~/}" ;; -*) path="./$path" ;; esac]],
    [[mkdir -p "$path"]],
  }, "; ")
  run(h, command, nil, function(res)
    if res.ok then
      cb(true, nil)
    else
      cb(false, result_error(res, "could not create the remote directory"))
    end
  end)
end

--- Escape the characters scp would otherwise read as a glob in a remote path
--- that is a literal name — a file called `report[1].txt` or `*`.
---@param path string
---@return string
function M.glob_escape(path)
  return (path:gsub("[%*%?%[%]\\]", "\\%0"))
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

--- Make sure background SSH commands can authenticate, offering to load a
--- locked key into ssh-agent first. `proceed` runs once that is settled.
---@param h ssh_launcher.Host
---@param proceed fun()
function M.with_auth(h, proceed)
  with_auth(h, proceed)
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
---@param batch boolean|nil never prompt, and give up on a dead connection
---@return string[] argv prefix carrying this host's port and identity
local function scp_prefix(h, batch)
  local cfg = require("ssh_launcher.config").get()
  local argv = { "scp" }
  if batch then
    -- A transfer nobody is watching must fail rather than wait on a prompt or
    -- a connection that has silently gone away.
    for _, option in ipairs({ "BatchMode=yes", "ConnectTimeout=10", "ServerAliveInterval=15", "ServerAliveCountMax=4" }) do
      argv[#argv + 1] = "-o"
      argv[#argv + 1] = option
    end
  end
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

  -- The same compression and `-o` options a session on this host would use, so
  -- a transfer behaves like the terminal it came from. ssh keeps the first
  -- value it sees for an option, which is why the options above win.
  local compression = h.compression
  if compression == nil then
    compression = cfg.ssh.compression
  end
  if compression then
    argv[#argv + 1] = "-C"
  end
  for _, options in ipairs({ cfg.ssh.default_options or {}, h.options or {} }) do
    for key, value in pairs(options) do
      argv[#argv + 1] = "-o"
      argv[#argv + 1] = ("%s=%s"):format(key, value)
    end
  end
  return argv
end

--- A local path in the form scp can only read as a file. scp decides a
--- name is remote when a colon appears before the first slash, so `a:b` would
--- be sent to host `a`; a leading `./` removes the ambiguity.
---@param path string
---@return string
local function local_operand(path)
  local expanded = util.expand(path)
  if expanded:find("^[^/]*:") then
    return "./" .. expanded
  end
  return expanded
end

--- The scp argv for a transfer. Every path is its own element, so a filename
--- containing a space, a quote or a semicolon is data rather than syntax.
---
--- Uploads recurse only when something being sent is a directory. Downloads
--- always recurse: the remote side cannot be inspected cheaply, and `-r` is
--- harmless on a single file.
---@param direction "get"|"put"
---@param h ssh_launcher.Host
---@param remote_path string|string[] a download may name several remote paths
---@param local_paths string|string[]
---@param opts { batch: boolean|nil }|nil
---@return string[]
function M.scp_argv(direction, h, remote_path, local_paths, opts)
  local sources = type(local_paths) == "table" and local_paths or { local_paths }
  local argv = scp_prefix(h, opts and opts.batch)
  argv[#argv + 1] = "-p" -- keep timestamps and mode

  local recursive = direction == "get"
  for _, path in ipairs(sources) do
    recursive = recursive or util.is_dir(path)
  end
  if recursive then
    argv[#argv + 1] = "-r"
  end
  -- Nothing after this can be mistaken for an option, whatever it is named.
  argv[#argv + 1] = "--"

  local target = authority(h)
  if direction == "get" then
    for _, path in ipairs(type(remote_path) == "table" and remote_path or { remote_path }) do
      argv[#argv + 1] = ("%s:%s"):format(target, path)
    end
    argv[#argv + 1] = local_operand(sources[1])
  else
    for _, path in ipairs(sources) do
      argv[#argv + 1] = local_operand(path)
    end
    argv[#argv + 1] = ("%s:%s"):format(target, remote_path)
  end
  return argv
end

--- Copy in the background, for an interface that shows its own progress.
---
--- Unlike |ssh_launcher.remote.put| and |ssh_launcher.remote.get| this opens no
--- terminal, so it cannot ask for a passphrase: the key must already be usable
--- (see |ssh_launcher.remote.with_auth|). Returns a handle whose `cancel()`
--- stops the transfer; `cb` then reports `"cancelled"`.
---@param direction "get"|"put"
---@param h ssh_launcher.Host
---@param remote_path string|string[] the destination for a put, the sources for a get
---@param local_paths string|string[] the sources for a put, the destination for a get
---@param cb fun(ok: boolean, err: string|nil)
---@return { cancel: fun() }
function M.copy(direction, h, remote_path, local_paths, cb)
  local handle = { cancel = function() end }
  if not util.has_executable("scp") then
    vim.schedule(function()
      cb(false, "scp is not installed")
    end)
    return handle
  end

  local cancelled = false
  local argv = M.scp_argv(direction, h, remote_path, local_paths, { batch = true })
  local started, proc = pcall(vim.system, argv, { text = true }, function(res)
    vim.schedule(function()
      if cancelled then
        return cb(false, "cancelled")
      elseif res.code == 0 then
        return cb(true, nil)
      end
      local err = result_error(res, "scp failed")
      if not M.is_permission_error(err) then
        return cb(false, err)
      end
      M.offer_sudo(h, err, function()
        if cancelled then
          return cb(false, "cancelled")
        end
        -- The caller holds on to `handle`; cancelling it now stops the sudo copy.
        handle.cancel = M.copy_elevated(direction, h, remote_path, local_paths, cb).cancel
      end, function()
        cb(false, err)
      end)
    end)
  end)
  if not started then
    vim.schedule(function()
      cb(false, tostring(proc))
    end)
    return handle
  end

  handle.cancel = function()
    cancelled = true
    pcall(function()
      proc:kill(15)
    end)
  end
  return handle
end

--------------------------------------------------------------------------------
-- Protected paths
--------------------------------------------------------------------------------

--- The line in which scp was refused a file or directory, if it was. ssh being
--- refused the login reads "Permission denied (publickey,password)" and is
--- not this: sudo cannot help with that.
---@param text string|nil
---@return string|nil line
function M.is_permission_error(text)
  for line in tostring(text or ""):gmatch("[^\r\n]+") do
    local _, stop = line:find("Permission denied", 1, true)
    if (stop and not line:find("^%s*%(", stop + 1)) or line:find("Operation not permitted", 1, true) then
      return util.trim(line)
    end
  end
  return nil
end

--- A `case` line expanding `~` in the shell variable `var`, and keeping a
--- leading `-` from being read as an option.
---@param var string
---@return string
local function expand_var(var)
  return (([[case "$V" in '~') V=$HOME ;; '~/'*) V="$HOME/${V#\~/}" ;; -*) V="./$V" ;; esac]]):gsub("V", var))
end

---@param password string|nil
---@return string
local function sudo(password)
  -- `-n` fails at once rather than waiting on a prompt nobody can answer;
  -- with a password, `-S` reads it from stdin and `-p ''` keeps it quiet.
  return password and "sudo -S -p '' --" or "sudo -n --"
end

local STAGE = [[umask 077; d=$(mktemp -d "${TMPDIR:-/tmp}/ssh-launcher.XXXXXX") && printf '%s' "$d"]]

--- Run as root: move staged uploads into place with scp's rules — into `dest`
--- when it is a directory, otherwise as `dest` itself. A file that already
--- exists is rewritten in place so it keeps its owner and mode; anything new
--- belongs to root, as with `sudo cp`.
local PLACE = table.concat({
  "tmp=$1; dest=$2; shift 2",
  [[if [ -d "$dest" ]; then into=1; else]],
  [[  case "$dest" in */) printf '%s: No such directory\n' "$dest" >&2; exit 1 ;; esac]],
  [[  [ $# -eq 1 ] || { printf '%s: Not a directory\n' "$dest" >&2; exit 1; }]],
  [[  into=0]],
  [[fi]],
  [[for name; do]],
  [[  src="$tmp/$name"]],
  [[  if [ $into = 1 ]; then target="${dest%/}/$name"; else target=$dest; fi]],
  [[  if [ -d "$src" ] && [ -d "$target" ]; then cp -R "$src/." "$target/" || exit 1]],
  [[  elif [ -f "$src" ] && [ -f "$target" ]; then cat "$src" > "$target" || exit 1]],
  [[  else cp -R "$src" "$target" || exit 1; fi]],
  [[done]],
}, "\n")

--- Run as root: copy what each source matches into the staging directory,
--- print the names, and hand the copies to the login user so scp can read them.
--- A source is `L<path>` for a literal name or `G<pattern>` for a glob; shells
--- disagree on backslash escapes in a pattern held in a variable, so escaped
--- names are unescaped before they get here.
local COLLECT = table.concat({
  "tmp=$1; uid=$2; gid=$3; shift 3",
  "IFS=",
  [[for arg; do]],
  [[  pattern=${arg#?}]],
  [[  found=0]],
  [[  case "$arg" in L*) set -f ;; *) set +f ;; esac]],
  [[  for src in $pattern; do]],
  [[    { [ -e "$src" ] || [ -L "$src" ]; } || continue]],
  [[    found=1]],
  [[    case "$src" in ?*/) src=${src%/} ;; esac]],
  [[    name=${src##*/}]],
  [[    cp -Rp "$src" "$tmp/$name" || exit 1]],
  [[    printf '%s\000' "$name"]],
  [[  done]],
  [[  [ $found = 1 ] || { printf '%s: No such file or directory\n' "$pattern" >&2; exit 1; }]],
  [[done]],
  [[chown -R "$uid:$gid" "$tmp" && chmod -R u+rwX "$tmp"]],
}, "\n")

--- The remote command that puts staged `names` in `dest` as root.
---@param tmp string staging directory
---@param dest string
---@param names string[]
---@param password string|nil
---@return string
function M.place_command(tmp, dest, names, password)
  local args = { M.shell_quote(tmp), '"$dest"' }
  for _, name in ipairs(names) do
    args[#args + 1] = M.shell_quote(name)
  end
  return table.concat({
    "dest=" .. M.shell_quote(dest),
    expand_var("dest"),
    ("%s sh -c %s sh %s"):format(sudo(password), M.shell_quote(PLACE), table.concat(args, " ")),
  }, "\n")
end

--- The remote command that stages `patterns` as root. Its output is the
--- staging directory then each name, NUL-terminated.
---@param patterns string[] scp-style remote paths; globs expand as root
---@param password string|nil
---@return string
function M.collect_command(patterns, password)
  local lines = {
    "umask 077",
    [[tmp=$(mktemp -d "${TMPDIR:-/tmp}/ssh-launcher.XXXXXX") || exit 1]],
    "set --",
  }
  for _, pattern in ipairs(patterns) do
    -- A glob character not escaped by |ssh_launcher.remote.glob_escape| makes it a pattern.
    local is_glob = pattern:gsub("\\.", ""):find("[%*%?%[]") ~= nil
    local value = is_glob and pattern or pattern:gsub("\\(.)", "%1")
    lines[#lines + 1] = "p=" .. M.shell_quote(value)
    lines[#lines + 1] = expand_var("p")
    lines[#lines + 1] = ([[set -- "$@" "%s$p"]]):format(is_glob and "G" or "L")
  end
  lines[#lines + 1] = [[printf '%s\000' "$tmp"]]
  lines[#lines + 1] = ([[%s sh -c %s sh "$tmp" "$(id -u)" "$(id -g)" "$@" || { rm -rf "$tmp"; exit 1; }]]):format(
    sudo(password),
    M.shell_quote(COLLECT)
  )
  return table.concat(lines, "\n")
end

---@param err string
---@return boolean
local function wants_password(err)
  for _, needle in ipairs({ "password is required", "terminal is required", "no tty present", "askpass" }) do
    if err:find(needle, 1, true) then
      return true
    end
  end
  return false
end

--- Ask for the sudo password on a host. Replace it to use another secret
--- prompt; `cb(nil)` means the user gave none. The password is never stored.
---@param h ssh_launcher.Host
---@param cb fun(password: string|nil)
function M.ask_sudo_password(h, cb)
  vim.schedule(function()
    local ok, value = pcall(vim.fn.inputsecret, ("[sudo] password on %s: "):format(Host.label(h)))
    cb((ok and value ~= "") and value or nil)
  end)
end

---@param argv string[]
---@param stdin string|nil
---@param cb fun(ok: boolean, stdout: string, err: string)
---@return vim.SystemObj|nil
local function spawn(argv, stdin, cb)
  local ok, proc = pcall(vim.system, argv, { text = false, stdin = stdin }, function(res)
    vim.schedule(function()
      cb(res.code == 0, res.stdout or "", result_error(res, "the command failed"))
    end)
  end)
  if not ok then
    vim.schedule(function()
      cb(false, "", tostring(proc))
    end)
    return nil
  end
  return proc
end

--- Copy through sudo on the host, for paths the login user cannot write or
--- read. scp cannot run as another user, so the files pass through a private
--- staging directory the login user owns: an upload is copied there and put
--- in place by root; a download is copied there by root, handed to the login
--- user, and fetched. The staging directory is removed however it ends.
---
--- If sudo wants a password it is asked for once (|ssh_launcher.remote.ask_sudo_password|)
--- and passed on stdin. Arguments are those of |ssh_launcher.remote.copy|.
---@param direction "get"|"put"
---@param h ssh_launcher.Host
---@param remote_path string|string[]
---@param local_paths string|string[]
---@param cb fun(ok: boolean, err: string|nil)
---@return { cancel: fun() }
function M.copy_elevated(direction, h, remote_path, local_paths, cb)
  local sources = type(local_paths) == "table" and local_paths or { local_paths }
  local cancelled, proc, staged = false, nil, nil

  local function done(ok, err)
    local function report()
      if cancelled then
        return cb(false, "cancelled")
      end
      cb(ok, err)
    end
    if not staged then
      return report()
    end
    -- Report once the staging directory is gone, so nothing is left behind
    -- by the time anyone looks.
    local dir = staged
    staged = nil
    spawn(M.command_argv(h, "rm -rf -- " .. M.shell_quote(dir)), nil, report)
  end

  local function step(argv, stdin, next_step)
    if cancelled then
      return done(false, "cancelled")
    end
    proc = spawn(argv, stdin, function(ok, stdout, err)
      proc = nil
      if cancelled then
        return done(false, "cancelled")
      end
      next_step(ok, stdout, err)
    end)
  end

  local function as_root(build, next_step, password)
    step(M.command_argv(h, build(password)), password and (password .. "\n") or nil, function(ok, stdout, err)
      if ok then
        return next_step(stdout)
      end
      if not password and wants_password(err) then
        return M.ask_sudo_password(h, function(given)
          if not given then
            return done(false, "sudo needs a password and none was given")
          end
          as_root(build, next_step, given)
        end)
      end
      if password and (err:find("incorrect password", 1, true) or err:find("Sorry, try again", 1, true)) then
        err = "sudo did not accept the password"
      end
      done(false, err)
    end)
  end

  if direction == "put" then
    step(M.command_argv(h, STAGE), nil, function(ok, stdout, err)
      if not ok or util.blank(stdout) then
        return done(false, ok and "could not make a staging directory on the host" or err)
      end
      staged = util.trim(stdout)
      step(
        M.scp_argv("put", h, M.glob_escape(staged) .. "/", sources, { batch = true }),
        nil,
        function(sent, _, scp_err)
          if not sent then
            return done(false, scp_err)
          end
          local names = {}
          for _, path in ipairs(sources) do
            names[#names + 1] = util.basename((path:gsub("/+$", "")))
          end
          as_root(function(password)
            return M.place_command(staged, remote_path --[[@as string]], names, password)
          end, function()
            done(true, nil)
          end)
        end
      )
    end)
  else
    local patterns = type(remote_path) == "table" and remote_path or { remote_path }
    as_root(function(password)
      return M.collect_command(patterns, password)
    end, function(stdout)
      local fields = vim.split(stdout, "\0", { plain = true })
      staged = util.nonblank(fields[1])
      local remote_sources = {}
      for i = 2, #fields do
        if fields[i] ~= "" then
          remote_sources[#remote_sources + 1] = M.glob_escape(staged .. "/" .. fields[i])
        end
      end
      if not staged or #remote_sources == 0 then
        return done(false, "nothing was copied")
      end
      step(M.scp_argv("get", h, remote_sources, sources[1], { batch = true }), nil, function(ok, _, err)
        done(ok, (not ok) and err or nil)
      end)
    end)
  end

  return {
    cancel = function()
      cancelled = true
      if proc then
        pcall(function()
          proc:kill(15)
        end)
      end
    end,
  }
end

--- scp was refused a protected path: offer to redo the copy with sudo, as
--- `remote.sudo` allows. `proceed` runs on a yes, `decline` otherwise.
---@param h ssh_launcher.Host
---@param err string what scp said
---@param proceed fun()
---@param decline fun()
function M.offer_sudo(h, err, proceed, decline)
  local cfg = require("ssh_launcher.config").get()
  if (cfg.remote or {}).sudo == "never" then
    return decline()
  end
  require("ssh_launcher.ui.dialog").confirm({
    title = "Permission denied — retry with sudo?",
    lines = {
      M.is_permission_error(err) or util.trim(err),
      "",
      ("The copy can be redone as root on %s, through a private"):format(Host.label(h)),
      "staging directory that is removed afterwards.",
    },
    yes = "Retry with sudo",
    no = "Cancel",
    destructive = true,
  }, function(confirmed)
    if confirmed then
      proceed()
    else
      decline()
    end
  end)
end

---@param paths string[]
---@return string
local function describe_sources(paths)
  if #paths == 1 then
    return util.basename(paths[1])
  end
  return ("%d items"):format(#paths)
end

---@param direction "get"|"put"
---@param h ssh_launcher.Host
---@param remote_path string
---@param local_paths string|string[]
---@param cb fun(ok: boolean, msg: string)|nil
local function transfer(direction, h, remote_path, local_paths, cb)
  cb = cb or function() end
  local sources = type(local_paths) == "table" and local_paths or { local_paths }

  if not util.has_executable("scp") then
    return cb(false, "scp is not installed")
  end
  if util.blank(remote_path) or #sources == 0 or util.blank(sources[1]) then
    return cb(false, "both a remote and a local path are needed")
  end
  if direction == "get" and #sources > 1 then
    return cb(false, "a download has exactly one local destination")
  end

  local argv = M.scp_argv(direction, h, remote_path, sources)
  local label = Host.label(h)

  -- scp may need a passphrase and prints progress, so it runs in a terminal
  -- rather than being swallowed by a background job.
  require("ssh_launcher.terminal").run(argv, {
    title = ("scp %s %s"):format(direction, label),
    strategy = "float",
    width = 0.7,
    height = 12,
    close_on_exit = true,
    on_exit = function(code, term)
      local function succeeded(how)
        local msg
        if direction == "get" then
          msg = ("downloaded %s:%s to %s"):format(label, remote_path, util.contract(util.expand(sources[1])))
        else
          msg = ("uploaded %s to %s:%s"):format(describe_sources(sources), label, remote_path)
        end
        msg = msg .. (how or "")
        log.info(msg)
        cb(true, msg)
      end
      if code == 0 then
        return succeeded()
      end

      local failure = ("scp exited with %d"):format(code)
      local denied = M.is_permission_error(term and term.output)
      if not denied then
        return cb(false, failure)
      end
      M.offer_sudo(h, denied, function()
        with_auth(h, function()
          log.announce(("copying with sudo on %s…"):format(label))
          M.copy_elevated(direction, h, remote_path, sources, function(ok, err)
            if ok then
              return succeeded(" (with sudo)")
            end
            log.error(("sudo copy failed: %s"):format(err or "unknown error"))
            cb(false, err or failure)
          end)
        end)
      end, function()
        cb(false, denied)
      end)
    end,
  })
end

--- Copy a file or directory down from the host.
---@param h ssh_launcher.Host
---@param remote_path string
---@param local_path string
---@param cb fun(ok: boolean, msg: string)|nil
function M.get(h, remote_path, local_path, cb)
  transfer("get", h, remote_path, local_path, cb)
end

--- Copy files or directories up to the host. With several sources the remote
--- path is a directory; current scp creates it if missing, older ones refuse.
---@param h ssh_launcher.Host
---@param local_paths string|string[]
---@param remote_path string
---@param cb fun(ok: boolean, msg: string)|nil
function M.put(h, local_paths, remote_path, cb)
  transfer("put", h, remote_path, local_paths, cb)
end

return M
