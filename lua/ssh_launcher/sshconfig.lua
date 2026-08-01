---@mod ssh_launcher.sshconfig OpenSSH client config integration
---
--- Reads `~/.ssh/config` (following `Include`) so existing fleets show up
--- immediately with zero data entry, and writes saved hosts back into a clearly
--- delimited managed block so plain `ssh <name>` works outside Neovim too.
---
--- The managed block is the only region ever rewritten; everything a human put
--- in the file is preserved byte for byte.

local util = require("ssh_launcher.util")
local log = require("ssh_launcher.log")
local config = require("ssh_launcher.config")

local M = {}

--- Directive -> host field. Anything not listed lands in `options`.
local DIRECTIVES = {
  hostname = "host",
  user = "user",
  port = "port",
  identityfile = "identity_file",
  proxyjump = "proxy_jump",
  forwardagent = "forward_agent",
  compression = "compression",
  requesttty = "request_tty",
  remotecommand = "remote_command",
  stricthostkeychecking = "strict_host_key_checking",
  identitiesonly = "identities_only",
}

local BOOLS = { forward_agent = true, compression = true, identities_only = true }

---@param value string
---@return boolean
local function yes(value)
  local v = (value or ""):lower()
  return v == "yes" or v == "true" or v == "1"
end

--- Split `Key value` honouring `Key=value` and quoted values.
---@param line string
---@return string|nil key, string|nil value
local function split_directive(line)
  local body = line:gsub("^%s+", ""):gsub("%s+$", "")
  if body == "" or body:sub(1, 1) == "#" then
    return nil, nil
  end
  local key, value = body:match("^([%w_]+)%s*=%s*(.+)$")
  if not key then
    key, value = body:match("^([%w_]+)%s+(.+)$")
  end
  if not key then
    return body, ""
  end
  return key, util.unquote(util.trim(value))
end

--------------------------------------------------------------------------------
-- Parsing
--------------------------------------------------------------------------------

---@param text string
---@param opts { origin: string|nil }|nil
---@return table[] hosts
function M.parse_text(text, opts)
  opts = opts or {}
  local cfg = config.get()
  local hosts = {}
  ---@type table|nil
  local current = nil
  local in_match = false

  local function finish()
    if current then
      if util.blank(current.host) then
        current.host = current.name
      end
      hosts[#hosts + 1] = current
      current = nil
    end
  end

  for line in (text .. "\n"):gmatch("(.-)\r?\n") do
    local key, value = split_directive(line)
    if key then
      local lkey = key:lower()
      if lkey == "host" then
        finish()
        in_match = false
        -- `Host a b c` declares aliases; the first non-negated one names the entry.
        local aliases = {}
        for alias in (value or ""):gmatch("%S+") do
          aliases[#aliases + 1] = alias
        end
        local primary = nil
        for _, alias in ipairs(aliases) do
          if alias:sub(1, 1) ~= "!" then
            local wild = alias:find("[%*%?]") ~= nil
            if not (wild and cfg.ssh_config.skip_wildcards) then
              primary = alias
              break
            end
          end
        end
        if primary then
          current = {
            name = primary,
            aliases = #aliases > 1 and aliases or nil,
            tags = {},
            options = {},
            forwards = {},
            source = "ssh_config",
            readonly = true,
          }
        end
      elseif lkey == "match" then
        finish()
        -- `Match` blocks are conditional; representing them as a static host
        -- would be a lie, so they are skipped entirely.
        in_match = true
      elseif current and not in_match then
        local field = DIRECTIVES[lkey]
        if field then
          if field == "port" then
            current.port = tonumber(value)
          elseif BOOLS[field] then
            current[field] = yes(value)
          elseif field == "request_tty" then
            current.request_tty = yes(value)
          else
            if field == "identity_file" and current.identity_file then
              -- multiple IdentityFile lines: keep the first, note the rest
              current.options["IdentityFile_" .. tostring(#vim.tbl_keys(current.options) + 1)] = value
            else
              current[field] = value
            end
          end
        elseif lkey == "localforward" or lkey == "remoteforward" or lkey == "dynamicforward" then
          local kind = ({ localforward = "local", remoteforward = "remote", dynamicforward = "dynamic" })[lkey]
          current.forwards[#current.forwards + 1] = { kind = kind, spec = (value:gsub("%s+", ":")) }
        elseif lkey == "tag" then
          for tag in value:gmatch("%S+") do
            current.tags[#current.tags + 1] = tag:lower()
          end
        else
          current.options[key] = value
        end
      end
    end
  end
  finish()

  if opts.origin then
    for _, h in ipairs(hosts) do
      h.origin = opts.origin
    end
  end
  return hosts
end

---@param path string
---@param seen table<string, boolean>|nil
---@param depth integer|nil
---@return table[] hosts
function M.parse_file(path, seen, depth)
  seen = seen or {}
  depth = depth or 0
  local p = util.expand(path)
  if seen[p] or depth > 8 then
    return {}
  end
  seen[p] = true

  local content = util.read_file(p)
  if not content then
    return {}
  end

  local cfg = config.get()
  local hosts = M.parse_text(content, { origin = util.contract(p) })

  if cfg.ssh_config.follow_includes then
    for line in (content .. "\n"):gmatch("(.-)\r?\n") do
      local key, value = split_directive(line)
      if key and key:lower() == "include" and value then
        for pattern in value:gmatch("%S+") do
          local expanded = util.expand(pattern)
          if not expanded:match("^[/~]") then
            expanded = util.join(util.dirname(p), expanded)
          end
          local matches = vim.fn.glob(expanded, true, true)
          for _, file in ipairs(matches) do
            if util.is_file(file) then
              vim.list_extend(hosts, M.parse_file(file, seen, depth + 1))
            end
          end
        end
      end
    end
  end

  return hosts
end

---@type { hosts: table[], mtime: integer|nil }|nil
local cache = nil

--- Hosts declared in ssh_config, normalized and marked read-only.
---@param force boolean|nil
---@return ssh_launcher.Host[]
function M.hosts(force)
  local cfg = config.get()
  local path = util.expand(cfg.ssh_config.path)
  local st = util.stat(path)
  local mtime = st and st.mtime and st.mtime.sec or nil

  if cache and not force and cache.mtime == mtime then
    return cache.hosts
  end

  local Host = require("ssh_launcher.host")
  local raw = util.is_file(path) and M.parse_file(path) or {}
  local out = {}
  local seen_names = {}

  for _, entry in ipairs(raw) do
    if not util.blank(entry.name) and not seen_names[entry.name] then
      seen_names[entry.name] = true
      local h = Host.normalize(entry)
      h.id = "ssh_config:" .. entry.name
      h.source = "ssh_config"
      h.readonly = true
      h.origin = entry.origin
      out[#out + 1] = h
    end
  end

  cache = { hosts = out, mtime = mtime }
  return out
end

function M.invalidate()
  cache = nil
end

--------------------------------------------------------------------------------
-- Effective configuration (`ssh -G`)
--------------------------------------------------------------------------------

--- Ask ssh itself what it would do for a target. This is the ground truth for
--- "will this actually work" and catches settings inherited from wildcards.
---@param target string
---@param cb fun(settings: table<string,string>|nil, err: string|nil)
function M.resolve(target, cb)
  if util.blank(target) then
    return cb(nil, "no target")
  end
  util.system({ config.get().ssh.binary, "-G", target }, { timeout = 4000 }, function(res)
    if not res.ok then
      return cb(nil, util.trim(res.stderr) ~= "" and util.trim(res.stderr) or ("ssh -G exited %d"):format(res.code))
    end
    local settings = {}
    for line in (res.stdout .. "\n"):gmatch("(.-)\n") do
      local k, v = line:match("^(%S+)%s+(.*)$")
      if k then
        local lk = k:lower()
        if settings[lk] then
          settings[lk] = settings[lk] .. "\n" .. v
        else
          settings[lk] = v
        end
      end
    end
    cb(settings, nil)
  end)
end

--------------------------------------------------------------------------------
-- Export
--------------------------------------------------------------------------------

---@param h ssh_launcher.Host
---@return string
function M.host_to_block(h)
  local known = require("ssh_launcher.host").KNOWN_SSH_OPTION_SET
  local lines = {}
  local alias = (h.name or h.host):gsub("%s+", "-")
  lines[#lines + 1] = ("Host %s"):format(alias)
  lines[#lines + 1] = ("  HostName %s"):format(h.host)
  if h.user then
    lines[#lines + 1] = ("  User %s"):format(h.user)
  end
  if h.port and h.port ~= 22 then
    lines[#lines + 1] = ("  Port %d"):format(h.port)
  end
  if h.identity_file then
    lines[#lines + 1] = ("  IdentityFile %s"):format(h.identity_file)
    if h.identities_only ~= false then
      lines[#lines + 1] = "  IdentitiesOnly yes"
    end
  end
  if h.proxy_jump then
    lines[#lines + 1] = ("  ProxyJump %s"):format(h.proxy_jump)
  end
  for _, f in ipairs(h.forwards or {}) do
    local key = ({ ["local"] = "LocalForward", remote = "RemoteForward", dynamic = "DynamicForward" })[f.kind]
    if key then
      -- ssh_config wants a space between the two halves of a forward spec.
      local spec = f.spec
      if f.kind ~= "dynamic" then
        local listen, rest = spec:match("^([^:]+:?%d*):([^:]+:%d+)$")
        if listen and rest then
          spec = listen .. " " .. rest
        end
      end
      lines[#lines + 1] = ("  %s %s"):format(key, spec)
    end
  end
  if h.forward_agent ~= nil then
    lines[#lines + 1] = ("  ForwardAgent %s"):format(h.forward_agent and "yes" or "no")
  end
  if h.compression then
    lines[#lines + 1] = "  Compression yes"
  end
  if h.strict_host_key_checking then
    lines[#lines + 1] = ("  StrictHostKeyChecking %s"):format(h.strict_host_key_checking)
  end
  if h.remote_command then
    lines[#lines + 1] = ("  RemoteCommand %s"):format(h.remote_command)
    lines[#lines + 1] = "  RequestTTY yes"
  end
  for k, v in pairs(h.options or {}) do
    local canonical = known[k:lower()]
    if canonical then
      lines[#lines + 1] = ("  %s %s"):format(canonical, v)
    end
  end
  if h.tags and #h.tags > 0 then
    lines[#lines + 1] = ("  # tags: %s"):format(table.concat(h.tags, ", "))
  end
  return table.concat(lines, "\n")
end

--- Write hosts into the managed block of `~/.ssh/config`.
---@param hosts ssh_launcher.Host[]
---@param opts { path: string|nil, dry_run: boolean|nil }|nil
---@return boolean ok, string content_or_err
function M.export(hosts, opts)
  opts = opts or {}
  local cfg = config.get()
  local path = util.expand(opts.path or cfg.ssh_config.path)
  local begin_marker = cfg.ssh_config.block_begin
  local end_marker = cfg.ssh_config.block_end

  local blocks = {}
  for _, h in ipairs(hosts) do
    if not util.blank(h.host) then
      blocks[#blocks + 1] = M.host_to_block(h)
    end
  end

  local managed = table.concat({
    begin_marker,
    "# Generated by ssh-launcher.nvim. Edits inside this block are overwritten.",
    "",
    table.concat(blocks, "\n\n"),
    "",
    end_marker,
  }, "\n")

  local existing = util.read_file(path) or ""
  local out
  local bpat = vim.pesc(begin_marker)
  local epat = vim.pesc(end_marker)
  if existing:find(bpat) and existing:find(epat) then
    out = existing:gsub(bpat .. ".-" .. epat, (managed:gsub("%%", "%%%%")), 1)
  else
    local sep = (existing ~= "" and not existing:match("\n$")) and "\n\n" or "\n"
    out = existing .. sep .. managed .. "\n"
  end

  if opts.dry_run then
    return true, out
  end

  -- Never clobber a hand-written config without a copy next to it.
  if existing ~= "" then
    util.write_file_atomic(path .. ".ssh-launcher.bak", existing, tonumber("600", 8))
  end

  local ok, err = util.write_file_atomic(path, out, tonumber("600", 8))
  if not ok then
    log.error(("cannot write %s: %s"):format(util.contract(path), err or "unknown error"))
    return false, err or "write failed"
  end
  M.invalidate()
  return true, out
end

return M
