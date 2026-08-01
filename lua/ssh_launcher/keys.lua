---@mod ssh_launcher.keys Private key inspection and hygiene
---
--- Everything here is read-only against key *metadata*: headers, file modes and
--- `ssh-keygen -l` output. Key material is never read into a buffer, never
--- logged and never copied anywhere.

local util = require("ssh_launcher.util")
local log = require("ssh_launcher.log")

local M = {}

M.MODE_KEY = tonumber("600", 8)
M.MODE_DIR = tonumber("700", 8)

---@class ssh_launcher.KeyInfo
---@field path string expanded path
---@field exists boolean
---@field readable boolean
---@field is_dir boolean
---@field mode string|nil octal
---@field too_open boolean
---@field format "openssh"|"pem"|"putty"|"public"|"certificate"|"unknown"
---@field encrypted boolean|nil nil = unknown
---@field type string|nil ED25519 / RSA / ECDSA / DSA
---@field bits integer|nil
---@field fingerprint string|nil
---@field comment string|nil
---@field size integer|nil
---@field has_public boolean matching `.pub` next to it

---@type table<string, { info: ssh_launcher.KeyInfo, mtime: integer|nil, at: integer }>
local cache = {}

local function cache_key(path)
  local st = util.stat(path)
  return st and st.mtime and st.mtime.sec or 0
end

--------------------------------------------------------------------------------
-- Format sniffing
--------------------------------------------------------------------------------

---@param head string
---@return string format, boolean|nil encrypted
local function sniff(head)
  if head:match("^%-%-%-%-%-BEGIN OPENSSH PRIVATE KEY%-%-%-%-%-") then
    return "openssh", nil -- needs ssh-keygen to tell
  end
  if head:match("^%-%-%-%-%-BEGIN [%u%s]*PRIVATE KEY%-%-%-%-%-") then
    local encrypted = head:find("Proc%-Type:%s*4,ENCRYPTED") ~= nil or head:find("DEK%-Info:") ~= nil
    return "pem", encrypted
  end
  if head:match("^PuTTY%-User%-Key%-File") then
    local encrypted = head:find("Encryption:%s*aes") ~= nil
    return "putty", encrypted
  end
  if head:match("^%-%-%-%-%-BEGIN CERTIFICATE%-%-%-%-%-") then
    return "certificate", false
  end
  if head:match("^ssh%-%a") or head:match("^ecdsa%-") or head:match("^sk%-") then
    return "public", false
  end
  return "unknown", nil
end

--- Ask ssh-keygen whether the key can be opened with an empty passphrase.
--- This is the only reliable test for the modern OpenSSH container format.
---@param path string
---@return boolean|nil encrypted
local function probe_encrypted(path)
  if not util.has_executable("ssh-keygen") then
    return nil
  end
  local res = util.system_sync({ "ssh-keygen", "-y", "-P", "", "-f", path }, 3000)
  if res.ok then
    return false
  end
  local err = (res.stderr or ""):lower()
  if err:find("incorrect passphrase") or err:find("load failed") or err:find("invalid format") then
    -- "load failed" also covers unreadable/garbage files; the caller has
    -- already established the file parses as a key container.
    return true
  end
  return nil
end

--------------------------------------------------------------------------------
-- Inspection
--------------------------------------------------------------------------------

--- Inspect a key path. Results are cached per (path, mtime).
---@param path string|nil
---@param opts { deep: boolean|nil }|nil `deep` runs ssh-keygen (a few ms)
---@return ssh_launcher.KeyInfo
function M.info(path, opts)
  opts = opts or {}
  local expanded = util.expand(path or "")

  ---@type ssh_launcher.KeyInfo
  local info = {
    path = expanded,
    exists = false,
    readable = false,
    is_dir = false,
    mode = nil,
    too_open = false,
    format = "unknown",
    encrypted = nil,
    has_public = false,
  }

  if util.blank(path) then
    return info
  end

  local mtime = cache_key(expanded)
  local hit = cache[expanded]
  if hit and hit.mtime == mtime and (not opts.deep or hit.info.fingerprint ~= nil or hit.info.format ~= "openssh") then
    return hit.info
  end

  local st = util.stat(expanded)
  if not st then
    cache[expanded] = { info = info, mtime = mtime, at = util.now() }
    return info
  end

  info.exists = true
  info.is_dir = st.type == "directory"
  info.size = st.size
  if info.is_dir then
    cache[expanded] = { info = info, mtime = mtime, at = util.now() }
    return info
  end

  local open, mode = util.is_world_accessible(expanded)
  info.mode = mode
  info.too_open = open == true

  local head = util.read_head(expanded, 512)
  info.readable = head ~= nil
  if head then
    info.format, info.encrypted = sniff(head)
    local comment = head:match("^ssh%-%a+%s+%S+%s+(.-)\n")
    if comment then
      info.comment = util.trim(comment)
    end
  end

  info.has_public = util.is_file(expanded .. ".pub")

  if opts.deep and util.has_executable("ssh-keygen") and info.format ~= "unknown" then
    local res = util.system_sync({ "ssh-keygen", "-l", "-f", expanded }, 3000)
    if res.ok then
      local bits, fp, rest = res.stdout:match("^(%d+)%s+(%S+)%s+(.*)$")
      info.bits = tonumber(bits)
      info.fingerprint = fp
      if rest then
        local comment, type_ = rest:match("^(.-)%s*%((%u[%w%-]*)%)%s*$")
        info.comment = util.nonblank(comment) or info.comment
        info.type = type_
      end
    end
    if info.format == "openssh" and info.encrypted == nil then
      info.encrypted = probe_encrypted(expanded)
    end
  end

  cache[expanded] = { info = info, mtime = mtime, at = util.now() }
  return info
end

function M.invalidate(path)
  if path then
    cache[util.expand(path)] = nil
  else
    cache = {}
  end
end

--------------------------------------------------------------------------------
-- Discovery
--------------------------------------------------------------------------------

--- Find plausible private keys in `~/.ssh` (and any configured extra dirs).
---@param dirs string[]|nil
---@return ssh_launcher.KeyInfo[]
function M.discover(dirs)
  dirs = dirs or { "~/.ssh" }
  local out = {}
  local seen = {}

  for _, dir in ipairs(dirs) do
    local expanded = util.expand(dir)
    for _, entry in ipairs(util.scandir(expanded)) do
      if entry.type == "file" or entry.type == "link" then
        local name = entry.name
        local skip = name:match("%.pub$")
          or name == "config"
          or name == "known_hosts"
          or name == "known_hosts.old"
          or name == "authorized_keys"
          or name:match("^%.")
          or name:match("%.bak$")
        if not skip then
          local path = util.join(expanded, name)
          if not seen[path] then
            seen[path] = true
            local info = M.info(path)
            if info.exists and (info.format == "openssh" or info.format == "pem" or info.format == "putty") then
              out[#out + 1] = info
            end
          end
        end
      end
    end
  end

  table.sort(out, function(a, b)
    return a.path < b.path
  end)
  return out
end

--- Best-guess key for a host, used when the user leaves the field empty.
---@return string|nil path
function M.default_key()
  for _, candidate in ipairs({ "~/.ssh/id_ed25519", "~/.ssh/id_ecdsa", "~/.ssh/id_rsa" }) do
    if util.is_file(candidate) then
      return candidate
    end
  end
  local found = M.discover()
  return found[1] and util.contract(found[1].path) or nil
end

--------------------------------------------------------------------------------
-- Repair
--------------------------------------------------------------------------------

--- `chmod 600` a key and `chmod 700` its directory. ssh refuses to use keys
--- that others can read, which is the single most common "it works in my
--- terminal but not here" failure.
---@param path string
---@return boolean ok, string message
function M.fix_permissions(path)
  local expanded = util.expand(path)
  if not util.is_file(expanded) then
    return false, ("%s does not exist"):format(util.contract(expanded))
  end
  local ok, err = util.chmod(expanded, M.MODE_KEY)
  if not ok then
    return false, ("chmod 600 failed: %s"):format(err or "unknown error")
  end
  local dir = util.dirname(expanded)
  local dir_open = util.is_world_accessible(dir)
  local msg = ("set %s to 0600"):format(util.contract(expanded))
  if dir_open then
    local dok = util.chmod(dir, M.MODE_DIR)
    if dok then
      msg = msg .. (" and %s to 0700"):format(util.contract(dir))
    end
  end
  M.invalidate(expanded)
  return true, msg
end

--- Given a `.pub` path, the matching private key if it exists.
---@param path string
---@return string|nil
function M.private_counterpart(path)
  local expanded = util.expand(path)
  local stripped = expanded:gsub("%.pub$", "")
  if stripped ~= expanded and util.is_file(stripped) then
    return util.contract(stripped)
  end
  return nil
end

--------------------------------------------------------------------------------
-- Generation / distribution
--------------------------------------------------------------------------------

---@param opts { path: string, type: string|nil, bits: integer|nil, comment: string|nil }
---@param cb fun(ok: boolean, msg: string)
function M.generate(opts, cb)
  local path = util.expand(opts.path)
  if util.exists(path) then
    return cb(false, ("%s already exists; refusing to overwrite a key"):format(util.contract(path)))
  end
  util.mkdirp(util.dirname(path), M.MODE_DIR)

  local argv = { "ssh-keygen", "-t", opts.type or "ed25519", "-f", path, "-C", opts.comment or "" }
  if (opts.type or "ed25519") == "rsa" then
    argv[#argv + 1] = "-b"
    argv[#argv + 1] = tostring(opts.bits or 4096)
  end
  -- No `-N ''` here: an empty passphrase is a policy decision the user must
  -- make deliberately, so generation runs in a terminal where ssh-keygen can
  -- prompt for one.
  require("ssh_launcher.terminal").run(argv, {
    title = "ssh-keygen",
    on_exit = function(code)
      M.invalidate(path)
      if code == 0 then
        cb(true, ("created %s"):format(util.contract(path)))
      else
        cb(false, ("ssh-keygen exited with %d"):format(code))
      end
    end,
  })
end

--- Install a key on a remote host with `ssh-copy-id`. Interactive by nature
--- (it asks for the remote password), so it runs in a terminal window.
---@param h ssh_launcher.Host
---@param cb fun(ok: boolean, msg: string)|nil
function M.copy_id(h, cb)
  if not util.has_executable("ssh-copy-id") then
    local msg = "ssh-copy-id is not installed"
    log.error(msg)
    if cb then
      cb(false, msg)
    end
    return
  end

  local key = h.identity_file or M.default_key()
  if not key then
    local msg = "no key to copy; generate one first (G in the manager)"
    log.error(msg)
    if cb then
      cb(false, msg)
    end
    return
  end

  local pub = util.expand(key) .. ".pub"
  if not util.is_file(pub) then
    local msg = ("%s not found; ssh-copy-id needs the public half"):format(util.contract(pub))
    log.error(msg)
    if cb then
      cb(false, msg)
    end
    return
  end

  local argv = { "ssh-copy-id", "-i", pub }
  if h.port and h.port ~= 22 then
    argv[#argv + 1] = "-p"
    argv[#argv + 1] = tostring(h.port)
  end
  argv[#argv + 1] = h.user and ("%s@%s"):format(h.user, h.host) or h.host

  require("ssh_launcher.terminal").run(argv, {
    title = ("ssh-copy-id → %s"):format(require("ssh_launcher.host").target(h)),
    on_exit = function(code)
      if cb then
        cb(code == 0, code == 0 and "key installed" or ("ssh-copy-id exited with %d"):format(code))
      end
    end,
  })
end

--------------------------------------------------------------------------------
-- known_hosts
--------------------------------------------------------------------------------

---@return string[]
local function known_hosts_files()
  local files = { "~/.ssh/known_hosts", "~/.ssh/known_hosts2" }
  local out = {}
  for _, f in ipairs(files) do
    if util.is_file(f) then
      out[#out + 1] = util.expand(f)
    end
  end
  return out
end

---@type { signature: string, plain: table<string, boolean>, hashed: boolean, probed: table<string, boolean> }|nil
local known_index = nil

--- Build an in-memory index of known_hosts.
---
--- Shelling out to `ssh-keygen -F` once per host does not scale: a fleet of a
--- few hundred entries would fork a few hundred processes every time the list
--- redraws. Instead the files are read once per modification and searched in
--- memory; `ssh-keygen` is only consulted when the file actually contains
--- hashed entries, and each answer is then cached.
---@return table
local function known_hosts_index()
  local files = known_hosts_files()
  local parts = {}
  for _, file in ipairs(files) do
    local st = util.stat(file)
    parts[#parts + 1] = ("%s:%s:%s"):format(file, st and st.mtime.sec or 0, st and st.size or 0)
  end
  local signature = table.concat(parts, "|")

  if known_index and known_index.signature == signature then
    return known_index
  end

  local index = { signature = signature, plain = {}, hashed = false, probed = {} }
  for _, file in ipairs(files) do
    local content = util.read_file(file)
    if content then
      for line in (content .. "\n"):gmatch("(.-)\n") do
        if line ~= "" and line:sub(1, 1) ~= "#" then
          local hosts = line:match("^@?[%w%-]*%s*([^%s]+)") or line:match("^([^%s]+)")
          if hosts then
            if hosts:sub(1, 3) == "|1|" then
              index.hashed = true
            else
              -- One entry may list several comma-separated names.
              for name in hosts:gmatch("[^,]+") do
                index.plain[name:lower()] = true
              end
            end
          end
        end
      end
    end
  end

  known_index = index
  return index
end

--- Is there a known_hosts entry for this host?
---@param host string
---@param port integer|nil
---@return boolean|nil known, boolean hashed
function M.is_known_host(host, port)
  if util.blank(host) then
    return nil, false
  end
  local files = known_hosts_files()
  if #files == 0 then
    return false, false
  end

  local target = (port and port ~= 22) and ("[%s]:%d"):format(host, port) or host
  local index = known_hosts_index()

  if index.plain[target:lower()] then
    return true, false
  end
  if not index.hashed then
    return false, false
  end

  -- Hashed entries are opaque; only ssh-keygen can match them.
  local cached = index.probed[target]
  if cached ~= nil then
    return cached, true
  end
  if not util.has_executable("ssh-keygen") then
    return nil, true
  end
  local res = util.system_sync({ "ssh-keygen", "-F", target }, 2000)
  local found = res.code == 0 and util.trim(res.stdout) ~= ""
  index.probed[target] = found
  return found, true
end

--- Drop the known_hosts index (after `ssh-keygen -R`, or a manual edit).
function M.invalidate_known_hosts()
  known_index = nil
end

---@param h ssh_launcher.Host
---@return boolean ok, string msg
function M.forget_host_key(h)
  if not util.has_executable("ssh-keygen") then
    return false, "ssh-keygen is not installed"
  end
  local target = (h.port and h.port ~= 22) and ("[%s]:%d"):format(h.host, h.port) or h.host
  local res = util.system_sync({ "ssh-keygen", "-R", target }, 4000)
  if res.ok then
    M.invalidate_known_hosts()
    return true, ("removed host keys for %s from known_hosts"):format(target)
  end
  return false, util.trim(res.stderr) ~= "" and util.trim(res.stderr) or "ssh-keygen -R failed"
end

--- Directory hygiene for `~/.ssh` itself.
---@return { path: string, mode: string|nil, too_open: boolean }
function M.ssh_dir_status()
  local dir = util.expand("~/.ssh")
  local open, mode = util.is_world_accessible(dir)
  return { path = dir, mode = mode, too_open = open == true }
end

return M
