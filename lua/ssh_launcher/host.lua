---@mod ssh_launcher.host Host model
---
--- The canonical shape of a saved connection, plus normalization and argv
--- construction. Argv is always built as a *list* — the ssh command line is
--- never assembled into a shell string, so a hostname containing `;` or `$()`
--- cannot execute anything.

local util = require("ssh_launcher.util")
local config = require("ssh_launcher.config")

local M = {}

---@class ssh_launcher.Forward
---@field kind "local"|"remote"|"dynamic"
---@field spec string e.g. "8080:localhost:80" or "1080"

---@class ssh_launcher.Host
---@field id string stable identifier
---@field name string human label, unique-ish
---@field host string hostname or IP (never contains user or port)
---@field user string|nil
---@field port integer|nil
---@field identity_file string|nil
---@field identities_only boolean|nil
---@field proxy_jump string|nil `[user@]host[:port]`, may reference another saved name
---@field tags string[]
---@field forwards ssh_launcher.Forward[]
---@field options table<string,string> extra `-o Key=Value`
---@field strict_host_key_checking string|nil per-host override
---@field forward_agent boolean|nil
---@field compression boolean|nil
---@field request_tty boolean|nil
---@field remote_command string|nil
---@field remote_dir string|nil cd here on connect
---@field notes string|nil
---@field source "store"|"ssh_config"|"project"|"extra"
---@field readonly boolean|nil
---@field created_at integer|nil
---@field updated_at integer|nil
---@field last_used_at integer|nil
---@field use_count integer|nil

--- Field metadata drives the editor form, the vimdoc table and validation.
--- Order here is the order shown to the user.
---@type { key: string, label: string, type: string, help: string, example: string|nil }[]
M.FIELDS = {
  { key = "name", label = "Name", type = "string", help = "Label shown in the picker.", example = "prod-api-eu" },
  { key = "host", label = "Host", type = "string", help = "Hostname or IP. No user, no port.", example = "10.0.4.12" },
  {
    key = "user",
    label = "User",
    type = "string",
    help = "Remote user. Empty = ssh_config default.",
    example = "ubuntu",
  },
  { key = "port", label = "Port", type = "number", help = "TCP port. Empty = 22.", example = "22" },
  {
    key = "identity_file",
    label = "Key",
    type = "path",
    help = "Private key path. Empty = agent / ssh_config.",
    example = "~/.ssh/id_ed25519",
  },
  {
    key = "proxy_jump",
    label = "Jump",
    type = "string",
    help = "Bastion to hop through ([user@]host[:port] or a saved host name).",
    example = "bastion.corp.net",
  },
  {
    key = "tags",
    label = "Tags",
    type = "list",
    help = "Comma separated. Used for filtering and policy.",
    example = "prod, eu-west-1",
  },
  {
    key = "forwards",
    label = "Forwards",
    type = "forwards",
    help = "Comma separated: L 8080:localhost:80, R 9000:localhost:9000, D 1080",
    example = "L 5432:db.internal:5432",
  },
  {
    key = "remote_dir",
    label = "Remote dir",
    type = "string",
    help = "cd here after connecting.",
    example = "/srv/app",
  },
  {
    key = "remote_command",
    label = "Command",
    type = "string",
    help = "Run instead of a login shell.",
    example = "journalctl -fu api",
  },
  {
    key = "options",
    label = "Options",
    type = "map",
    help = "Extra ssh -o pairs, comma separated Key=Value.",
    example = "SetEnv=FOO=bar",
  },
  { key = "notes", label = "Notes", type = "string", help = "Free text. Never store secrets here.", example = nil },
}

M.FIELD_BY_KEY = {}
for _, f in ipairs(M.FIELDS) do
  M.FIELD_BY_KEY[f.key] = f
end

--- Options that ssh accepts. Used to catch typos in the `Options` field.
--- Not exhaustive on purpose: unknown keys warn, they never block.
M.KNOWN_SSH_OPTIONS = {
  "AddKeysToAgent",
  "AddressFamily",
  "BatchMode",
  "BindAddress",
  "BindInterface",
  "CanonicalDomains",
  "CanonicalizeFallbackLocal",
  "CanonicalizeHostname",
  "CanonicalizeMaxDots",
  "CanonicalizePermittedCNAMEs",
  "CASignatureAlgorithms",
  "CertificateFile",
  "CheckHostIP",
  "Ciphers",
  "ClearAllForwardings",
  "Compression",
  "ConnectionAttempts",
  "ConnectTimeout",
  "ControlMaster",
  "ControlPath",
  "ControlPersist",
  "DynamicForward",
  "EnableEscapeCommandline",
  "EscapeChar",
  "ExitOnForwardFailure",
  "FingerprintHash",
  "ForkAfterAuthentication",
  "ForwardAgent",
  "ForwardX11",
  "ForwardX11Timeout",
  "ForwardX11Trusted",
  "GatewayPorts",
  "GlobalKnownHostsFile",
  "GSSAPIAuthentication",
  "GSSAPIDelegateCredentials",
  "HashKnownHosts",
  "HostbasedAcceptedAlgorithms",
  "HostbasedAuthentication",
  "HostKeyAlgorithms",
  "HostKeyAlias",
  "Hostname",
  "IdentitiesOnly",
  "IdentityAgent",
  "IdentityFile",
  "IgnoreUnknown",
  "Include",
  "IPQoS",
  "KbdInteractiveAuthentication",
  "KbdInteractiveDevices",
  "KexAlgorithms",
  "KnownHostsCommand",
  "LocalCommand",
  "LocalForward",
  "LogLevel",
  "LogVerbose",
  "MACs",
  "NoHostAuthenticationForLocalhost",
  "NumberOfPasswordPrompts",
  "PasswordAuthentication",
  "PermitLocalCommand",
  "PermitRemoteOpen",
  "PKCS11Provider",
  "Port",
  "PreferredAuthentications",
  "ProxyCommand",
  "ProxyJump",
  "ProxyUseFdpass",
  "PubkeyAcceptedAlgorithms",
  "PubkeyAuthentication",
  "RekeyLimit",
  "RemoteCommand",
  "RemoteForward",
  "RequestTTY",
  "RequiredRSASize",
  "RevokedHostKeys",
  "SecurityKeyProvider",
  "SendEnv",
  "ServerAliveCountMax",
  "ServerAliveInterval",
  "SessionType",
  "SetEnv",
  "StdinNull",
  "StreamLocalBindMask",
  "StreamLocalBindUnlink",
  "StrictHostKeyChecking",
  "SyslogFacility",
  "TCPKeepAlive",
  "Tag",
  "Tunnel",
  "TunnelDevice",
  "UpdateHostKeys",
  "User",
  "UserKnownHostsFile",
  "VerifyHostKeyDNS",
  "VisualHostKey",
  "XAuthLocation",
}

M.KNOWN_SSH_OPTION_SET = {}
for _, o in ipairs(M.KNOWN_SSH_OPTIONS) do
  M.KNOWN_SSH_OPTION_SET[o:lower()] = o
end

--------------------------------------------------------------------------------
-- Construction / normalization
--------------------------------------------------------------------------------

---@return ssh_launcher.Host
function M.blank()
  return {
    id = util.uid(),
    name = "",
    host = "",
    user = nil,
    port = nil,
    identity_file = nil,
    tags = {},
    forwards = {},
    options = {},
    source = "store",
    created_at = util.now(),
    updated_at = util.now(),
    use_count = 0,
  }
end

---@param value any
---@return string[]
function M.to_tags(value)
  if type(value) == "table" then
    local out = {}
    for _, v in ipairs(value) do
      local t = util.trim(tostring(v)):lower()
      if t ~= "" then
        out[#out + 1] = t
      end
    end
    return out
  end
  if type(value) ~= "string" or util.trim(value) == "" then
    return {}
  end
  local out = {}
  for piece in value:gmatch("[^,%s]+") do
    out[#out + 1] = piece:lower()
  end
  return out
end

--- Parse a forwards description into structured entries.
--- Accepts `L 8080:localhost:80`, `-L 8080:...`, `8080:localhost:80` (implies
--- local), `D 1080`, `R 9000:localhost:9000`.
---@param value any
---@return ssh_launcher.Forward[]
function M.to_forwards(value)
  if type(value) == "table" then
    local out = {}
    for _, f in ipairs(value) do
      if type(f) == "table" and f.spec then
        out[#out + 1] = { kind = f.kind or "local", spec = util.trim(f.spec) }
      elseif type(f) == "string" then
        vim.list_extend(out, M.to_forwards(f))
      end
    end
    return out
  end
  if type(value) ~= "string" or util.trim(value) == "" then
    return {}
  end
  local out = {}
  for chunk in value:gmatch("[^,]+") do
    chunk = util.trim(chunk)
    if chunk ~= "" then
      local kind, spec = chunk:match("^%-?([LRDlrd])%s*(.+)$")
      if kind then
        local map = { l = "local", r = "remote", d = "dynamic" }
        out[#out + 1] = { kind = map[kind:lower()], spec = util.trim(spec) }
      else
        out[#out + 1] = { kind = "local", spec = chunk }
      end
    end
  end
  return out
end

---@param forwards ssh_launcher.Forward[]|nil
---@return string
function M.forwards_to_string(forwards)
  if not forwards or #forwards == 0 then
    return ""
  end
  local letter = { ["local"] = "L", remote = "R", dynamic = "D" }
  local parts = {}
  for _, f in ipairs(forwards) do
    parts[#parts + 1] = ("%s %s"):format(letter[f.kind] or "L", f.spec)
  end
  return table.concat(parts, ", ")
end

---@param value any
---@return table<string,string>
function M.to_options(value)
  if type(value) == "table" then
    local out = {}
    for k, v in pairs(value) do
      out[tostring(k)] = tostring(v)
    end
    return out
  end
  if type(value) ~= "string" or util.trim(value) == "" then
    return {}
  end
  local out = {}
  -- Split on commas that are not inside a value like `SetEnv=A=1`.
  for chunk in value:gmatch("[^,]+") do
    local k, v = chunk:match("^%s*([%w_]+)%s*=%s*(.-)%s*$")
    if k then
      out[k] = v
    end
  end
  return out
end

---@param options table<string,string>|nil
---@return string
function M.options_to_string(options)
  if not options or vim.tbl_isempty(options) then
    return ""
  end
  local keys = vim.tbl_keys(options)
  table.sort(keys)
  local parts = {}
  for _, k in ipairs(keys) do
    parts[#parts + 1] = ("%s=%s"):format(k, options[k])
  end
  return table.concat(parts, ", ")
end

--- Pull `user@`, `:port`, `ssh://` and `[v6]` out of whatever landed in `host`.
--- Users paste `ec2-user@1.2.3.4:2222` into the Host box constantly; rather
--- than rejecting it we understand it.
---@param h ssh_launcher.Host
---@return string[] notes describing what was rewritten
local function untangle_host(h)
  local notes = {}
  local value = util.trim(h.host or "")
  if value == "" then
    return notes
  end

  local scheme = value:match("^(%a[%w+.-]*)://")
  if scheme then
    value = value:gsub("^%a[%w+.-]*://", "")
    notes[#notes + 1] = ("removed %s:// scheme"):format(scheme)
  end

  -- strip any trailing path / query the user pasted along
  local path = value:match("^[^/]*(/.*)$")
  if path then
    value = value:sub(1, #value - #path)
    if not h.remote_dir or h.remote_dir == "" then
      h.remote_dir = path
      notes[#notes + 1] = ("moved path %s to remote dir"):format(path)
    end
  end

  local user, rest = value:match("^([^@/]+)@(.+)$")
  if user and rest then
    value = rest
    if util.blank(h.user) then
      h.user = user
      notes[#notes + 1] = ("moved user %s out of the host field"):format(user)
    end
  end

  -- bracketed IPv6, optionally with a port
  local v6, v6port = value:match("^%[([%x:%.]+)%]:?(%d*)$")
  if v6 then
    value = v6
    if v6port ~= "" and not h.port then
      h.port = tonumber(v6port)
      notes[#notes + 1] = ("moved port %s out of the host field"):format(v6port)
    end
  else
    -- host:port, but only when there is exactly one colon (bare IPv6 has more)
    local _, colons = value:gsub(":", "")
    if colons == 1 then
      local hostpart, portpart = value:match("^(.-):(%d+)$")
      if hostpart and portpart then
        value = hostpart
        if not h.port then
          h.port = tonumber(portpart)
          notes[#notes + 1] = ("moved port %s out of the host field"):format(portpart)
        end
      end
    end
  end

  h.host = util.trim(value)
  return notes
end

--- Coerce an arbitrary table into a valid host. Always returns a new table; the
--- input is never mutated.
---@param partial table
---@return ssh_launcher.Host host, string[] notes
function M.normalize(partial)
  local h = vim.deepcopy(partial or {})

  h.id = h.id or util.uid()
  h.source = h.source or "store"
  h.name = util.trim(h.name or "")
  h.host = util.trim(h.host or "")
  h.user = util.nonblank(h.user)

  if type(h.port) == "string" then
    h.port = tonumber(util.trim(h.port))
  end
  if h.port and (h.port ~= math.floor(h.port)) then
    h.port = math.floor(h.port)
  end

  -- v1 schema used `key`; keep reading it forever.
  if h.key and util.blank(h.identity_file) then
    h.identity_file = h.key
  end
  h.key = nil
  h.identity_file = util.nonblank(h.identity_file)

  h.proxy_jump = util.nonblank(h.proxy_jump)
  h.remote_command = util.nonblank(h.remote_command)
  h.remote_dir = util.nonblank(h.remote_dir)
  h.notes = util.nonblank(h.notes)

  h.tags = M.to_tags(h.tags)
  h.forwards = M.to_forwards(h.forwards)
  h.options = M.to_options(h.options)

  h.created_at = tonumber(h.created_at) or util.now()
  h.updated_at = tonumber(h.updated_at) or h.created_at
  h.last_used_at = tonumber(h.last_used_at)
  h.use_count = tonumber(h.use_count) or 0

  local notes = untangle_host(h)

  if h.name == "" and h.host ~= "" then
    h.name = h.user and ("%s@%s"):format(h.user, h.host) or h.host
    notes[#notes + 1] = "derived a name from the target"
  end

  if h.identity_file == nil and h.identities_only == nil then
    h.identities_only = nil
  end

  return h, notes
end

---@param h ssh_launcher.Host
---@return ssh_launcher.Host
function M.clone(h)
  local copy = vim.deepcopy(h)
  copy.id = util.uid()
  copy.name = (h.name or "host") .. " (copy)"
  copy.created_at = util.now()
  copy.updated_at = util.now()
  copy.last_used_at = nil
  copy.use_count = 0
  copy.source = "store"
  copy.readonly = nil
  return copy
end

--------------------------------------------------------------------------------
-- Presentation
--------------------------------------------------------------------------------

--- `user@host` with the port appended when non-default.
---@param h ssh_launcher.Host
---@return string
function M.target(h)
  local host = h.host or ""
  if host:find(":") and not host:find("^%[") then
    host = "[" .. host .. "]"
  end
  local s = h.user and ("%s@%s"):format(h.user, host) or host
  if h.port and h.port ~= 22 then
    s = ("%s:%d"):format(s, h.port)
  end
  return s
end

---@param h ssh_launcher.Host
---@return string
function M.label(h)
  if util.blank(h.name) then
    return M.target(h)
  end
  return h.name
end

---@param h ssh_launcher.Host
---@return boolean
function M.is_production(h)
  local tags = config.get().security.production_tags
  for _, t in ipairs(h.tags or {}) do
    if vim.tbl_contains(tags, t) then
      return true
    end
  end
  local name = (h.name or ""):lower()
  for _, t in ipairs(tags) do
    if name:find(t, 1, true) then
      return true
    end
  end
  return false
end

--- Everything a fuzzy filter should match against.
---@param h ssh_launcher.Host
---@return string
function M.search_text(h)
  return table
    .concat({
      h.name or "",
      h.host or "",
      h.user or "",
      table.concat(h.tags or {}, " "),
      h.notes or "",
      h.identity_file or "",
    }, " ")
    :lower()
end

--------------------------------------------------------------------------------
-- Command construction
--------------------------------------------------------------------------------

---@param h ssh_launcher.Host
---@return string|nil
local function remote_payload(h)
  if h.remote_command and h.remote_dir then
    return ("cd %s && %s"):format(vim.fn.shellescape(h.remote_dir), h.remote_command)
  end
  if h.remote_command then
    return h.remote_command
  end
  if h.remote_dir then
    -- Land in the directory but keep an interactive login shell.
    return ("cd %s && exec ${SHELL:-/bin/sh} -l"):format(vim.fn.shellescape(h.remote_dir))
  end
  return nil
end

--- Build the ssh argv for a host.
---
--- Returned as a list so it can be handed straight to `jobstart`/`termopen`
--- without a shell. Callers that need a displayable string use
--- |ssh_launcher.host.command_string|.
---@param h ssh_launcher.Host
---@param opts { extra_args: string[]|nil, no_multiplex: boolean|nil, batch: boolean|nil }|nil
---@return string[] argv
function M.build_argv(h, opts)
  opts = opts or {}
  local cfg = config.get()
  local argv = { cfg.ssh.binary }

  local function opt(key, value)
    argv[#argv + 1] = "-o"
    argv[#argv + 1] = ("%s=%s"):format(key, value)
  end

  if h.port and h.port ~= 22 then
    argv[#argv + 1] = "-p"
    argv[#argv + 1] = tostring(h.port)
  end

  if h.identity_file and h.identity_file ~= "" then
    argv[#argv + 1] = "-i"
    argv[#argv + 1] = util.expand(h.identity_file)
    -- Without this, ssh offers every agent key first and large agents trip the
    -- server's MaxAuthTries before the right key is ever tried.
    if h.identities_only ~= false then
      opt("IdentitiesOnly", "yes")
    end
  end

  local strict = h.strict_host_key_checking or cfg.ssh.strict_host_key_checking
  if strict == "no" and not cfg.diagnostics.allow_insecure then
    strict = "accept-new"
  end
  opt("StrictHostKeyChecking", strict)

  if cfg.ssh.connect_timeout then
    opt("ConnectTimeout", tostring(cfg.ssh.connect_timeout))
  end
  if cfg.ssh.server_alive_interval and cfg.ssh.server_alive_interval > 0 then
    opt("ServerAliveInterval", tostring(cfg.ssh.server_alive_interval))
    opt("ServerAliveCountMax", tostring(cfg.ssh.server_alive_count_max))
  end

  if cfg.ssh.control_master and not opts.no_multiplex then
    util.mkdirp(util.dirname(util.expand(cfg.ssh.control_path)), tonumber("700", 8))
    opt("ControlMaster", "auto")
    opt("ControlPath", util.expand(cfg.ssh.control_path))
    opt("ControlPersist", tostring(cfg.ssh.control_persist))
  end

  local forward_agent = h.forward_agent
  if forward_agent == nil then
    forward_agent = cfg.ssh.forward_agent
  end
  if forward_agent then
    argv[#argv + 1] = "-A"
  end

  local compression = h.compression
  if compression == nil then
    compression = cfg.ssh.compression
  end
  if compression then
    argv[#argv + 1] = "-C"
  end

  if h.proxy_jump and h.proxy_jump ~= "" then
    argv[#argv + 1] = "-J"
    argv[#argv + 1] = h.proxy_jump
  end

  for _, f in ipairs(h.forwards or {}) do
    if f.spec and f.spec ~= "" then
      local flag = ({ ["local"] = "-L", remote = "-R", dynamic = "-D" })[f.kind]
      if flag then
        argv[#argv + 1] = flag
        argv[#argv + 1] = f.spec
      end
    end
  end

  for key, value in pairs(cfg.ssh.default_options or {}) do
    opt(key, value)
  end
  for key, value in pairs(h.options or {}) do
    opt(key, value)
  end

  if opts.batch then
    opt("BatchMode", "yes")
  end

  for _, a in ipairs(cfg.ssh.extra_args or {}) do
    argv[#argv + 1] = a
  end
  for _, a in ipairs(opts.extra_args or {}) do
    argv[#argv + 1] = a
  end

  local payload = remote_payload(h)
  local request_tty = h.request_tty
  if request_tty == nil then
    request_tty = cfg.ssh.request_tty
  end
  if request_tty and payload then
    -- A remote command otherwise runs without a TTY and interactive tools break.
    argv[#argv + 1] = "-t"
  end

  argv[#argv + 1] = h.user and ("%s@%s"):format(h.user, h.host) or h.host

  if payload then
    argv[#argv + 1] = payload
  end

  return argv
end

--- A copy-pasteable rendering of the argv. Display only — never executed.
---@param h ssh_launcher.Host
---@param opts table|nil
---@return string
function M.command_string(h, opts)
  local argv = M.build_argv(h, opts)
  local parts = {}
  for _, a in ipairs(argv) do
    if a:match("^[%w@%%_%-%.:/=,%+]+$") then
      parts[#parts + 1] = a
    else
      parts[#parts + 1] = vim.fn.shellescape(a)
    end
  end
  return table.concat(parts, " ")
end

--- Argv for a non-interactive probe (`ssh -G`-style dry runs, scp helpers).
---@param h ssh_launcher.Host
---@return string[]
function M.resolve_argv(h)
  local argv = M.build_argv(h, { batch = true, no_multiplex = true })
  table.insert(argv, 2, "-G")
  return argv
end

--- Strip volatile/derived fields before writing to disk.
---@param h ssh_launcher.Host
---@return table
function M.serialize(h)
  local out = {
    id = h.id,
    name = h.name,
    host = h.host,
    user = h.user,
    port = h.port,
    identity_file = h.identity_file,
    identities_only = h.identities_only,
    proxy_jump = h.proxy_jump,
    tags = (h.tags and #h.tags > 0) and h.tags or nil,
    forwards = (h.forwards and #h.forwards > 0) and h.forwards or nil,
    options = (h.options and not vim.tbl_isempty(h.options)) and h.options or nil,
    strict_host_key_checking = h.strict_host_key_checking,
    forward_agent = h.forward_agent,
    compression = h.compression,
    request_tty = h.request_tty,
    remote_command = h.remote_command,
    remote_dir = h.remote_dir,
    notes = h.notes,
    created_at = h.created_at,
    updated_at = h.updated_at,
    last_used_at = h.last_used_at,
    use_count = (h.use_count and h.use_count > 0) and h.use_count or nil,
  }
  return out
end

return M
