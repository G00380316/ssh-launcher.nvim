---@mod ssh_launcher.parser Smart paste / connection-string parsing
---
--- Turning "whatever the user has in their clipboard" into a host record.
--- Understood inputs:
---
---   ssh -i ~/.ssh/k.pem -p 2222 ec2-user@10.0.0.4
---   ssh -o ProxyJump=bastion deploy@app-01 'journalctl -fu api'
---   ssh://deploy@app-01.internal:2222/srv/app
---   deploy@app-01:2222
---   scp -i key.pem file.tar deploy@app-01:/tmp/
---   rsync -e "ssh -p 2222" ./dist deploy@app-01:/srv
---   Host prod \n  HostName 10.0.0.4 \n  User deploy      (ssh_config block)
---   { "host": "10.0.0.4", "user": "deploy" }            (JSON, incl. exports)
---   Host: 10.0.0.4  User: deploy  Port: 2222            (label/value lines)
---   10.0.0.4
---
--- Nothing here executes anything: input is only ever inspected as text.

local util = require("ssh_launcher.util")

local M = {}

---@class ssh_launcher.ParseResult
---@field host table partial host fields
---@field kind string what the input looked like
---@field confidence number 0..1
---@field notes string[] human-readable explanation of what was extracted
---@field warnings string[] security-relevant observations

--------------------------------------------------------------------------------
-- Tokenizer
--------------------------------------------------------------------------------

--- Split a command line into argv, honouring quotes and backslash escapes.
--- Line continuations (`\` at end of line) are joined first.
---@param str string
---@return string[]
function M.tokenize(str)
  local s = str:gsub("\\\r?\n%s*", " ")
  local tokens = {}
  local i, n = 1, #s
  local current, has_current = {}, false

  local function flush()
    if has_current then
      tokens[#tokens + 1] = table.concat(current)
      current, has_current = {}, false
    end
  end

  while i <= n do
    local c = s:sub(i, i)
    if c == " " or c == "\t" or c == "\n" or c == "\r" then
      flush()
      i = i + 1
    elseif c == '"' or c == "'" then
      local quote = c
      has_current = true
      i = i + 1
      while i <= n do
        local d = s:sub(i, i)
        if d == "\\" and quote == '"' and i < n then
          current[#current + 1] = s:sub(i + 1, i + 1)
          i = i + 2
        elseif d == quote then
          i = i + 1
          break
        else
          current[#current + 1] = d
          i = i + 1
        end
      end
    elseif c == "\\" and i < n then
      has_current = true
      current[#current + 1] = s:sub(i + 1, i + 1)
      i = i + 2
    else
      has_current = true
      current[#current + 1] = c
      i = i + 1
    end
  end
  flush()
  return tokens
end

--------------------------------------------------------------------------------
-- Recognisers
--------------------------------------------------------------------------------

local IPV4 = "^%d+%.%d+%.%d+%.%d+$"

---@param s string
---@return boolean
local function is_ipv4(s)
  if not s:match(IPV4) then
    return false
  end
  for octet in s:gmatch("%d+") do
    if tonumber(octet) > 255 then
      return false
    end
  end
  return true
end

---@param s string
---@return boolean
local function is_ipv6(s)
  if not s:find(":") then
    return false
  end
  return s:match("^[%x:]+$") ~= nil and select(2, s:gsub(":", "")) >= 2
end

--- Does this look like something ssh could dial?
---@param s string
---@return boolean
function M.is_hostname(s)
  if util.blank(s) then
    return false
  end
  s = util.trim(s)
  if is_ipv4(s) or is_ipv6(s) then
    return true
  end
  if #s > 253 then
    return false
  end
  if not s:match("^[%w_][%w_%-%.]*$") then
    return false
  end
  -- Reject things that are almost certainly not hosts (bare words with no dot
  -- are accepted, because ssh_config aliases and /etc/hosts entries are common).
  if s:match("%.%.") or s:match("^%-") or s:match("%-$") then
    return false
  end
  return true
end

--- ssh flags that consume the following token as their argument.
local FLAGS_WITH_ARG = {
  ["-b"] = true, ["-c"] = true, ["-D"] = true, ["-E"] = true, ["-e"] = true,
  ["-F"] = true, ["-I"] = true, ["-i"] = true, ["-J"] = true, ["-L"] = true,
  ["-l"] = true, ["-m"] = true, ["-O"] = true, ["-o"] = true, ["-p"] = true,
  ["-Q"] = true, ["-R"] = true, ["-S"] = true, ["-W"] = true, ["-w"] = true,
  ["-B"] = true, ["-P"] = true,
}

local FLAGS_NO_ARG = {
  ["-4"] = true, ["-6"] = true, ["-A"] = true, ["-a"] = true, ["-C"] = true,
  ["-f"] = true, ["-G"] = true, ["-g"] = true, ["-K"] = true, ["-k"] = true,
  ["-M"] = true, ["-N"] = true, ["-n"] = true, ["-q"] = true, ["-s"] = true,
  ["-T"] = true, ["-t"] = true, ["-V"] = true, ["-v"] = true, ["-X"] = true,
  ["-x"] = true, ["-Y"] = true, ["-y"] = true, ["-r"] = true, ["-3"] = true,
}

---@param spec string
---@return string user, string host, integer|nil port
local function split_target(spec)
  local user, rest = spec:match("^([^@]+)@(.+)$")
  local host = rest or spec
  local port

  local v6, v6port = host:match("^%[([%x:%.]+)%]:?(%d*)$")
  if v6 then
    host = v6
    port = tonumber(v6port)
  else
    local _, colons = host:gsub(":", "")
    if colons == 1 then
      local h, p = host:match("^(.-):(%d+)$")
      if h and p then
        host, port = h, tonumber(p)
      end
    end
  end
  return user, host, port
end

--------------------------------------------------------------------------------
-- ssh command line
--------------------------------------------------------------------------------

---@param tokens string[]
---@param result ssh_launcher.ParseResult
---@return boolean matched
local function parse_ssh_argv(tokens, result)
  local h = result.host
  local i = 1
  local target_seen = false
  local command_parts = {}

  -- Drop shell prompt noise and wrappers.
  while tokens[i] do
    local t = tokens[i]
    if t == "$" or t == "#" or t == ">" or t == "PS>" or t == "sudo" or t == "time" or t == "exec" then
      i = i + 1
    else
      break
    end
  end

  local binary = tokens[i]
  if not binary then
    return false
  end
  local base = util.basename(binary):gsub("%.exe$", "")
  local is_scp = base == "scp" or base == "sftp" or base == "rsync"
  if base ~= "ssh" and not is_scp and base ~= "autossh" and base ~= "mosh" then
    return false
  end
  result.kind = is_scp and (base .. "-command") or "ssh-command"
  i = i + 1

  local function consume_option(pair)
    local k, v = pair:match("^%s*([%w_]+)%s*=%s*(.*)$")
    if not k then
      return
    end
    local lk = k:lower()
    if lk == "port" then
      h.port = tonumber(v)
    elseif lk == "user" then
      h.user = v
    elseif lk == "hostname" then
      h.host = v
    elseif lk == "identityfile" then
      h.identity_file = v
    elseif lk == "proxyjump" then
      h.proxy_jump = v
    elseif lk == "stricthostkeychecking" then
      h.strict_host_key_checking = v
      if v:lower() == "no" then
        result.warnings[#result.warnings + 1] =
          "the pasted command disables host-key checking (StrictHostKeyChecking=no); it was not carried over"
        h.strict_host_key_checking = nil
      end
    elseif lk == "forwardagent" then
      h.forward_agent = (v:lower() == "yes")
    elseif lk == "localforward" then
      h.forwards = h.forwards or {}
      h.forwards[#h.forwards + 1] = { kind = "local", spec = (v:gsub("%s+", ":")) }
    elseif lk == "remoteforward" then
      h.forwards = h.forwards or {}
      h.forwards[#h.forwards + 1] = { kind = "remote", spec = (v:gsub("%s+", ":")) }
    elseif lk == "dynamicforward" then
      h.forwards = h.forwards or {}
      h.forwards[#h.forwards + 1] = { kind = "dynamic", spec = v }
    else
      h.options = h.options or {}
      h.options[k] = v
    end
  end

  while tokens[i] do
    local t = tokens[i]

    if t:sub(1, 1) == "-" and #t > 1 then
      local flag = t:sub(1, 2)
      local attached = #t > 2 and t:sub(3) or nil

      if FLAGS_WITH_ARG[flag] then
        local value = attached
        if not value then
          i = i + 1
          value = tokens[i]
        end
        if value then
          if flag == "-i" then
            h.identity_file = util.unquote(value)
          elseif flag == "-p" or (is_scp and flag == "-P") then
            h.port = tonumber(value)
          elseif flag == "-l" then
            h.user = value
          elseif flag == "-J" then
            h.proxy_jump = value
          elseif flag == "-o" then
            consume_option(value)
          elseif flag == "-L" or flag == "-R" or flag == "-D" then
            h.forwards = h.forwards or {}
            local kind = ({ ["-L"] = "local", ["-R"] = "remote", ["-D"] = "dynamic" })[flag]
            h.forwards[#h.forwards + 1] = { kind = kind, spec = value }
          elseif flag == "-e" and base == "rsync" then
            -- rsync -e "ssh -p 2222 -i key"
            local inner = M.tokenize(value)
            table.insert(inner, 1, "ssh")
            parse_ssh_argv(inner, result)
          end
        end
        i = i + 1
      elseif FLAGS_NO_ARG[flag] and not attached then
        if flag == "-A" then
          h.forward_agent = true
          result.warnings[#result.warnings + 1] =
            "the pasted command enables agent forwarding (-A); anyone with root on the remote can then use your keys"
        elseif flag == "-C" then
          h.compression = true
        end
        i = i + 1
      elseif t:match("^%-%-") then
        i = i + 1
      else
        -- Unknown short flag; skip it rather than mis-reading it as a target.
        i = i + 1
      end
    elseif not target_seen then
      local spec = util.unquote(t)
      if is_scp then
        -- Only the remote side of an scp pair carries `host:path`.
        local hostpart, path = spec:match("^([^/][^:]*):(.*)$")
        if hostpart then
          local u, hh, p = split_target(hostpart)
          h.user = h.user or u
          h.host = hh
          h.port = h.port or p
          if path and path ~= "" and not h.remote_dir then
            h.remote_dir = path:match("/$") and path:gsub("/$", "") or util.dirname(path)
            if h.remote_dir == "." then
              h.remote_dir = nil
            end
          end
          target_seen = true
        end
      else
        local u, hh, p = split_target(spec)
        if hh and hh ~= "" then
          h.user = h.user or u
          h.host = hh
          h.port = h.port or p
          target_seen = true
        end
      end
      i = i + 1
    else
      command_parts[#command_parts + 1] = t
      i = i + 1
      while tokens[i] do
        command_parts[#command_parts + 1] = tokens[i]
        i = i + 1
      end
    end
  end

  if #command_parts > 0 and not is_scp then
    h.remote_command = table.concat(command_parts, " ")
  end

  if not h.host or h.host == "" then
    return false
  end
  result.confidence = 1.0
  return true
end

--------------------------------------------------------------------------------
-- Other single-line shapes
--------------------------------------------------------------------------------

---@param text string
---@param result ssh_launcher.ParseResult
---@return boolean
local function parse_uri(text, result)
  local scheme, rest = text:match("^(%a[%w+.-]*)://(.+)$")
  if not scheme then
    return false
  end
  scheme = scheme:lower()
  if scheme ~= "ssh" and scheme ~= "sftp" and scheme ~= "scp" then
    return false
  end
  local authority, path = rest:match("^([^/]+)(/?.*)$")
  if not authority then
    return false
  end
  local u, hh, p = split_target(authority)
  if not hh or hh == "" then
    return false
  end
  result.host.user = u
  result.host.host = hh
  result.host.port = p
  if path and path ~= "" and path ~= "/" then
    result.host.remote_dir = (path:gsub("/$", ""))
  end
  result.kind = scheme .. "-uri"
  result.confidence = 0.95
  return true
end

---@param text string
---@param result ssh_launcher.ParseResult
---@return boolean
local function parse_target(text, result)
  if text:find("%s") then
    return false
  end
  local u, hh, p = split_target(text)
  if not hh or not M.is_hostname(hh) then
    return false
  end
  result.host.user = u
  result.host.host = hh
  result.host.port = p
  if u then
    result.kind = "target"
    result.confidence = 0.9
  else
    result.kind = "hostname"
    -- A bare word could be anything; a dotted name or IP is far more convincing.
    result.confidence = (hh:find("%.") or is_ipv4(hh)) and 0.75 or 0.45
  end
  return true
end

--- `host: 10.0.0.1`, `user = deploy`, `Port 2222` — one pair per line, which is
--- also exactly the shape of this plugin's own editor form.
---@param text string
---@param result ssh_launcher.ParseResult
---@return boolean
local function parse_pairs(text, result)
  local aliases = {
    name = "name",
    label = "name",
    host = "host",
    hostname = "host",
    server = "host",
    ip = "host",
    address = "host",
    user = "user",
    username = "user",
    login = "user",
    port = "port",
    key = "identity_file",
    keyfile = "identity_file",
    identity = "identity_file",
    identityfile = "identity_file",
    ["private key"] = "identity_file",
    ["key path"] = "identity_file",
    jump = "proxy_jump",
    bastion = "proxy_jump",
    proxyjump = "proxy_jump",
    ["proxy jump"] = "proxy_jump",
    tags = "tags",
    tag = "tags",
    forwards = "forwards",
    ["remote dir"] = "remote_dir",
    dir = "remote_dir",
    command = "remote_command",
    cmd = "remote_command",
    notes = "notes",
    note = "notes",
    options = "options",
    password = "__password",
    passphrase = "__password",
    secret = "__password",
  }

  local found = 0
  for line in (text .. "\n"):gmatch("(.-)\r?\n") do
    local key, value = line:match("^%s*([%a][%a%s_]-)%s*[:=]%s*(.-)%s*$")
    if key and value and value ~= "" then
      local field = aliases[key:lower()]
      if field == "__password" then
        result.warnings[#result.warnings + 1] =
          "a password/passphrase was present in the pasted text; it was discarded and never written to disk"
        found = found + 1
      elseif field then
        if field == "port" then
          result.host.port = tonumber(value)
        else
          result.host[field] = util.unquote(value)
        end
        found = found + 1
      end
    end
  end

  if found == 0 or util.blank(result.host.host) then
    return false
  end
  result.kind = "fields"
  result.confidence = 0.85
  return true
end

---@param text string
---@param result ssh_launcher.ParseResult
---@return boolean
local function parse_json(text, result)
  local trimmed = util.trim(text)
  if not (trimmed:sub(1, 1) == "{" or trimmed:sub(1, 1) == "[") then
    return false
  end
  local ok, decoded = pcall(vim.json.decode, trimmed, { luanil = { object = true, array = true } })
  if not ok or type(decoded) ~= "table" then
    return false
  end
  local obj = decoded
  if util.is_list(decoded) then
    obj = decoded[1]
  elseif decoded.hosts and util.is_list(decoded.hosts) then
    obj = decoded.hosts[1]
  end
  if type(obj) ~= "table" then
    return false
  end
  for k, v in pairs(obj) do
    result.host[k] = v
  end
  if obj.key and not obj.identity_file then
    result.host.identity_file = obj.key
    result.host.key = nil
  end
  if util.blank(result.host.host) then
    return false
  end
  result.kind = "json"
  result.confidence = 1.0
  return true
end

--------------------------------------------------------------------------------
-- Danger detection
--------------------------------------------------------------------------------

--- Recognise material that must never be pasted into a host record.
---@param text string
---@return string|nil warning
function M.detect_secret(text)
  if text:find("%-%-%-%-%-BEGIN [%u ]*PRIVATE KEY%-%-%-%-%-") then
    return "That looks like a private key. Save it to a file (chmod 600) and point the Key field at the path — "
      .. "ssh-launcher never stores key material."
  end
  if text:match("^%s*ssh%-%a+%s+AAAA") or text:match("^%s*ecdsa%-%a[%w%-]*%s+AAAA") then
    return "That is a public key, not a connection string. The Key field wants the matching private key path."
  end
  return nil
end

--------------------------------------------------------------------------------
-- Public API
--------------------------------------------------------------------------------

---@param text string|nil
---@return ssh_launcher.ParseResult|nil
function M.parse(text)
  if util.blank(text) then
    return nil
  end
  text = text:gsub("\r\n", "\n")
  local trimmed = util.trim(text)

  ---@type ssh_launcher.ParseResult
  local result = { host = {}, kind = "unknown", confidence = 0, notes = {}, warnings = {} }

  local secret = M.detect_secret(trimmed)
  if secret then
    result.kind = "secret"
    result.warnings[#result.warnings + 1] = secret
    return result
  end

  -- Multi-line ssh_config blocks are delegated to the real config parser.
  if trimmed:match("^[Hh]ost%s+%S") and trimmed:find("\n") then
    local ok, sshconfig = pcall(require, "ssh_launcher.sshconfig")
    if ok then
      local hosts = sshconfig.parse_text(trimmed)
      if #hosts > 0 then
        result.host = hosts[1]
        result.kind = "ssh-config"
        result.confidence = 0.95
        if #hosts > 1 then
          result.notes[#result.notes + 1] = ("%d host blocks found; showing the first"):format(#hosts)
        end
        return result
      end
    end
  end

  if parse_json(trimmed, result) then
    return result
  end

  -- Strip prompt decorations that survive a copy from a terminal.
  local line = trimmed:gsub("^%s*[%$#>]%s+", "")
  local first_line = line:match("^[^\n]*") or line

  if first_line:lower():match("^%a[%w+.-]*://") and parse_uri(util.trim(first_line), result) then
    return result
  end

  if first_line:find("%s") or first_line:lower():match("^%a+%.?e?x?e?%s") then
    local tokens = M.tokenize(line)
    if parse_ssh_argv(tokens, result) then
      return result
    end
  end

  if parse_pairs(text, result) then
    return result
  end

  if parse_target(util.trim(first_line), result) then
    return result
  end

  -- Last resort: find a `user@host` anywhere in the blob.
  local embedded = trimmed:match("([%w%._%-]+@[%w%.%-]+[%w])")
  if embedded and not embedded:find("@[%w%.%-]+%.%a%a+$") then
    -- avoid grabbing e-mail addresses; require it to look like a host
    if parse_target(embedded, result) then
      result.confidence = 0.5
      result.notes[#result.notes + 1] = "extracted a target from surrounding text"
      return result
    end
  end

  return nil
end

--- Parse a blob that may describe several hosts (config blocks, JSON arrays,
--- one connection string per line).
---@param text string|nil
---@return table[] hosts
function M.parse_many(text)
  if util.blank(text) then
    return {}
  end
  text = text:gsub("\r\n", "\n")
  local trimmed = util.trim(text)

  if trimmed:match("^[Hh]ost%s+%S") then
    local ok, sshconfig = pcall(require, "ssh_launcher.sshconfig")
    if ok then
      local hosts = sshconfig.parse_text(trimmed)
      if #hosts > 0 then
        return hosts
      end
    end
  end

  if trimmed:sub(1, 1) == "[" or trimmed:sub(1, 1) == "{" then
    local ok, decoded = pcall(vim.json.decode, trimmed, { luanil = { object = true, array = true } })
    if ok and type(decoded) == "table" then
      local list = util.is_list(decoded) and decoded or decoded.hosts
      if list and util.is_list(list) then
        local out = {}
        for _, item in ipairs(list) do
          if type(item) == "table" then
            if item.key and not item.identity_file then
              item.identity_file = item.key
              item.key = nil
            end
            out[#out + 1] = item
          end
        end
        if #out > 0 then
          return out
        end
      end
    end
  end

  local out = {}
  for raw_line in (text .. "\n"):gmatch("(.-)\n") do
    if util.trim(raw_line) ~= "" and not raw_line:match("^%s*#") then
      local res = M.parse(raw_line)
      if res and res.confidence >= 0.7 and not util.blank(res.host.host) then
        out[#out + 1] = res.host
      end
    end
  end
  if #out > 0 then
    return out
  end

  local single = M.parse(text)
  if single and not util.blank(single.host.host) then
    return { single.host }
  end
  return {}
end

--- Cheap predicate for "should we offer to paste the clipboard?".
---@param text string|nil
---@return boolean
function M.looks_like_connection(text)
  if util.blank(text) or #text > 4096 then
    return false
  end
  local res = M.parse(text)
  return res ~= nil and res.kind ~= "secret" and res.confidence >= 0.7
end

--- Describe a parse result in one line for a confirmation prompt.
---@param res ssh_launcher.ParseResult
---@return string
function M.describe(res)
  local h = res.host
  local bits = {}
  if h.user then
    bits[#bits + 1] = ("user %s"):format(h.user)
  end
  if h.host then
    bits[#bits + 1] = ("host %s"):format(h.host)
  end
  if h.port then
    bits[#bits + 1] = ("port %d"):format(h.port)
  end
  if h.identity_file then
    bits[#bits + 1] = ("key %s"):format(util.contract(h.identity_file))
  end
  if h.proxy_jump then
    bits[#bits + 1] = ("via %s"):format(h.proxy_jump)
  end
  return table.concat(bits, ", ")
end

--- Read the clipboard and, if it holds a connection, return the parse.
---@return ssh_launcher.ParseResult|nil, string|nil register
function M.from_clipboard()
  for _, reg in ipairs({ "+", "*", '"' }) do
    local ok, contents = pcall(vim.fn.getreg, reg)
    if ok and type(contents) == "string" and not util.blank(contents) then
      local res = M.parse(contents)
      if res and res.kind ~= "secret" and res.confidence >= 0.7 then
        return res, reg
      end
    end
  end
  return nil, nil
end

return M
