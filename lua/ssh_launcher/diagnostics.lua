---@mod ssh_launcher.diagnostics Misconfiguration detection
---
--- A rules engine over a host record. Every rule answers three questions:
--- what is wrong, why it matters, and — wherever possible — how to fix it with
--- one keystroke.
---
--- Rules are cheap and synchronous by default (stat, file headers, string
--- shape). Anything that touches the network lives in |ssh_launcher.diagnostics.check_async|.

local util = require("ssh_launcher.util")
local config = require("ssh_launcher.config")
local keys = require("ssh_launcher.keys")
local agent = require("ssh_launcher.agent")
local probe = require("ssh_launcher.probe")

local M = {}

---@class ssh_launcher.Fix
---@field label string imperative, e.g. "chmod 600 the key"
---@field apply fun(h: ssh_launcher.Host): ssh_launcher.Host|nil, string returns patched host (or nil if only side effects) and a message
---@field auto boolean|nil false for fixes that must not run unattended — ones
---  that start an interactive process, or that guess at the user's intent.
---  |ssh_launcher.diagnostics.autofix| skips them; they stay one keystroke away
---  in the diagnostics view.

---@class ssh_launcher.Issue
---@field code string
---@field severity "error"|"warn"|"info"|"hint"
---@field field string|nil
---@field message string
---@field detail string|nil
---@field fix ssh_launcher.Fix|nil

M.SEVERITY_ORDER = { error = 4, warn = 3, info = 2, hint = 1 }

M.VIM_SEVERITY = {
  error = vim.diagnostic.severity.ERROR,
  warn = vim.diagnostic.severity.WARN,
  info = vim.diagnostic.severity.INFO,
  hint = vim.diagnostic.severity.HINT,
}

--------------------------------------------------------------------------------
-- Rule helpers
--------------------------------------------------------------------------------

---@class ssh_launcher.RuleContext
---@field host ssh_launcher.Host
---@field hosts ssh_launcher.Host[]
---@field issues ssh_launcher.Issue[]
---@field cfg table

---@param ctx ssh_launcher.RuleContext
---@param issue ssh_launcher.Issue
local function add(ctx, issue)
  local cfg = ctx.cfg.diagnostics
  if vim.tbl_contains(cfg.disabled or {}, issue.code) then
    return
  end
  local override = (cfg.severity_overrides or {})[issue.code]
  if override then
    issue.severity = override
  end
  if issue.severity == "off" then
    return
  end
  ctx.issues[#ctx.issues + 1] = issue
end

---@param spec string
---@return boolean ok, string|nil why
local function valid_forward(kind, spec)
  if util.blank(spec) then
    return false, "empty specification"
  end
  if kind == "dynamic" then
    -- [bind_address:]port
    if spec:match("^%d+$") or spec:match("^[%w%.%-%[%]:]+:%d+$") then
      return true, nil
    end
    return false, "expected [bind_address:]port, e.g. 1080"
  end
  -- [bind_address:]port:host:hostport
  local parts = vim.split(spec, ":", { plain = true })
  if #parts == 3 or #parts == 4 then
    local listen = tonumber(parts[#parts - 2])
    local dest = tonumber(parts[#parts])
    if listen and dest then
      return true, nil
    end
  end
  return false, "expected [bind:]port:host:hostport, e.g. 8080:localhost:80"
end

--------------------------------------------------------------------------------
-- Rules
--------------------------------------------------------------------------------

---@param ctx ssh_launcher.RuleContext
local function rule_name(ctx)
  local h = ctx.host
  if util.blank(h.name) then
    add(ctx, {
      code = "SSH080",
      severity = "error",
      field = "name",
      message = "Name is empty",
      detail = "The name is how you find this host in the picker and how it is exported to ssh_config.",
      fix = {
        label = "name it after the target",
        apply = function(host)
          local patched = vim.deepcopy(host)
          patched.name = require("ssh_launcher.host").target(host)
          return patched, ("named it %q"):format(patched.name)
        end,
      },
    })
  end

  for _, other in ipairs(ctx.hosts) do
    if other.id ~= h.id then
      if not util.blank(other.name) and other.name:lower() == (h.name or ""):lower() then
        if other.source == "ssh_config" then
          add(ctx, {
            code = "SSH083",
            severity = "hint",
            field = "name",
            message = ("%q is also a Host alias in ssh_config"):format(h.name),
            detail = "Not an error, but `ssh "
              .. h.name
              .. "` outside Neovim will use the ssh_config entry, "
              .. "which may point somewhere else.",
          })
        else
          add(ctx, {
            code = "SSH081",
            severity = "warn",
            field = "name",
            message = ("Another saved host is also called %q"):format(h.name),
            detail = "Duplicate names make `:Ssh connect <name>` ambiguous.",
          })
        end
        break
      end
    end
  end

  local Host = require("ssh_launcher.host")
  local target = Host.target(h)
  for _, other in ipairs(ctx.hosts) do
    if other.id ~= h.id and other.source ~= "ssh_config" and Host.target(other) == target and target ~= "" then
      add(ctx, {
        code = "SSH082",
        severity = "hint",
        field = "host",
        message = ("%q points at the same target"):format(other.name),
        detail = "Two entries for one machine is fine when they differ in key, forwards or command.",
      })
      break
    end
  end
end

---@param ctx ssh_launcher.RuleContext
local function rule_host(ctx)
  local h = ctx.host
  local parser = require("ssh_launcher.parser")

  if util.blank(h.host) then
    add(ctx, {
      code = "SSH001",
      severity = "error",
      field = "host",
      message = "Host is empty",
      detail = "There is nothing to connect to. Paste an address, `user@host`, or a whole `ssh …` command.",
    })
    return
  end

  if h.host:find("%s") then
    add(ctx, {
      code = "SSH002",
      severity = "error",
      field = "host",
      message = "Host contains whitespace",
      detail = "A hostname cannot contain spaces. If you pasted a full command, use the Paste field instead.",
      fix = {
        label = "re-parse the value",
        apply = function(host)
          local res = parser.parse(host.host)
          if not res then
            return nil, "could not make sense of it"
          end
          local patched = vim.tbl_extend("force", vim.deepcopy(host), res.host)
          return patched, "re-parsed the host field"
        end,
      },
    })
    return
  end

  if h.host:find("@") then
    add(ctx, {
      code = "SSH003",
      severity = "warn",
      field = "host",
      message = "Host still contains a user part",
      detail = "`user@host` belongs in two separate fields.",
      fix = {
        label = "split user out of host",
        apply = function(host)
          local patched = vim.deepcopy(host)
          local user, rest = host.host:match("^([^@]+)@(.+)$")
          patched.user = patched.user or user
          patched.host = rest
          return patched, ("moved %q into the user field"):format(user)
        end,
      },
    })
    return
  end

  if h.host:match("^%a[%w+.-]*://") then
    add(ctx, {
      code = "SSH004",
      severity = "warn",
      field = "host",
      message = "Host contains a URL scheme",
      fix = {
        label = "strip the scheme",
        apply = function(host)
          local patched = vim.deepcopy(host)
          patched.host = host.host:gsub("^%a[%w+.-]*://", "")
          return patched, "removed the scheme"
        end,
      },
    })
    return
  end

  if not parser.is_hostname(h.host) then
    add(ctx, {
      code = "SSH006",
      severity = "error",
      field = "host",
      message = ("%q is not a valid hostname or IP"):format(util.truncate(h.host, 40)),
      detail = "Allowed: letters, digits, dots, dashes and underscores; or an IPv4/IPv6 literal.",
    })
    return
  end

  if not h.host:find("%.") and not h.host:match("^%d") and not h.host:find(":") then
    add(ctx, {
      code = "SSH007",
      severity = "hint",
      field = "host",
      message = ("%q is a short name"):format(h.host),
      detail = "It will only resolve via /etc/hosts, a search domain, or an ssh_config alias.",
    })
  end
end

---@param ctx ssh_launcher.RuleContext
local function rule_user(ctx)
  local h = ctx.host
  if util.blank(h.user) then
    add(ctx, {
      code = "SSH010",
      severity = "hint",
      field = "user",
      message = "No user set",
      detail = ("ssh will fall back to ssh_config, then to your local username (%s)."):format(
        vim.env.USER or vim.env.USERNAME or "?"
      ),
    })
    return
  end
  if h.user:find("[%s@:/]") then
    add(ctx, {
      code = "SSH011",
      severity = "error",
      field = "user",
      message = "User contains an invalid character",
      detail = "Spaces, `@`, `:` and `/` are not valid in a login name.",
    })
  end
  if h.user == "root" then
    add(ctx, {
      code = "SSH012",
      severity = "hint",
      field = "user",
      message = "Connecting as root",
      detail = "Most hardened fleets set `PermitRootLogin no`. Prefer a named account plus sudo.",
    })
  end
end

---@param ctx ssh_launcher.RuleContext
local function rule_port(ctx)
  local h = ctx.host
  if h.port == nil then
    return
  end
  if type(h.port) ~= "number" or h.port ~= math.floor(h.port) then
    add(ctx, {
      code = "SSH020",
      severity = "error",
      field = "port",
      message = "Port is not a whole number",
    })
    return
  end
  if h.port < 1 or h.port > 65535 then
    add(ctx, {
      code = "SSH020",
      severity = "error",
      field = "port",
      message = ("Port %d is outside 1-65535"):format(h.port),
    })
  end
end

---@param ctx ssh_launcher.RuleContext
local function rule_key(ctx)
  local h = ctx.host
  local cfg = ctx.cfg

  if util.blank(h.identity_file) then
    local loaded = agent.list_sync()
    if loaded and #loaded == 0 then
      add(ctx, {
        code = "SSH041",
        severity = "hint",
        field = "identity_file",
        message = "No key set and the agent holds no identities",
        detail = "The connection will fall back to keyboard/password authentication, which many servers refuse.",
        fix = (function()
          local default = keys.default_key()
          if not default then
            return nil
          end
          return {
            label = ("use %s"):format(util.contract(default)),
            -- Choosing which key identifies you is the user's call, not ours.
            auto = false,
            apply = function(host)
              local patched = vim.deepcopy(host)
              patched.identity_file = default
              return patched, ("set the key to %s"):format(util.contract(default))
            end,
          }
        end)(),
      })
    end
    return
  end

  local info = keys.info(h.identity_file, { deep = cfg.diagnostics.check_key_format })
  local shown = util.contract(h.identity_file)

  if not info.exists then
    local suggestion = nil
    local base = util.basename(util.expand(h.identity_file))
    for _, candidate in ipairs(keys.discover()) do
      if util.basename(candidate.path) == base or candidate.path:find(base, 1, true) then
        suggestion = candidate.path
        break
      end
    end
    add(ctx, {
      code = "SSH030",
      severity = "error",
      field = "identity_file",
      message = ("Key %s does not exist"):format(shown),
      detail = suggestion and ("A file with a similar name exists at %s."):format(util.contract(suggestion))
        or "Check the path, or generate a key with `G` in the manager.",
      fix = suggestion and {
        label = ("use %s"):format(util.contract(suggestion)),
        auto = false, -- a name-similarity guess needs a human to confirm it
        apply = function(host)
          local patched = vim.deepcopy(host)
          patched.identity_file = util.contract(suggestion)
          return patched, ("pointed the key at %s"):format(util.contract(suggestion))
        end,
      } or nil,
    })
    return
  end

  if info.is_dir then
    add(ctx, {
      code = "SSH031",
      severity = "error",
      field = "identity_file",
      message = ("%s is a directory"):format(shown),
      detail = "The Key field wants a private key file, not the directory holding it.",
    })
    return
  end

  if not info.readable then
    add(ctx, {
      code = "SSH037",
      severity = "error",
      field = "identity_file",
      message = ("%s cannot be read"):format(shown),
      detail = "Check ownership: the key must be readable by you.",
    })
    return
  end

  if info.format == "public" or h.identity_file:match("%.pub$") then
    local private = keys.private_counterpart(h.identity_file)
    add(ctx, {
      code = "SSH032",
      severity = "error",
      field = "identity_file",
      message = ("%s is a public key"):format(shown),
      detail = "ssh authenticates with the private half. The public half belongs in the server's authorized_keys.",
      fix = private and {
        label = ("use %s"):format(util.contract(private)),
        apply = function(host)
          local patched = vim.deepcopy(host)
          patched.identity_file = private
          return patched, ("switched to the private key %s"):format(util.contract(private))
        end,
      } or nil,
    })
    return
  end

  if info.format == "certificate" then
    add(ctx, {
      code = "SSH039",
      severity = "warn",
      field = "identity_file",
      message = ("%s is an X.509 certificate"):format(shown),
      detail = "OpenSSH cannot authenticate with this. You want the private key it was issued for.",
    })
  end

  if info.format == "putty" then
    add(ctx, {
      code = "SSH035",
      severity = "error",
      field = "identity_file",
      message = ("%s is a PuTTY .ppk key"):format(shown),
      detail = ("OpenSSH cannot read it. Convert once with:\n" .. "    puttygen %s -O private-openssh -o %s"):format(
        shown,
        (shown:gsub("%.ppk$", "")) .. ".pem"
      ),
    })
  end

  if info.format == "unknown" then
    add(ctx, {
      code = "SSH038",
      severity = "warn",
      field = "identity_file",
      message = ("%s does not look like a private key"):format(shown),
      detail = "No recognisable key header was found in the first bytes of the file.",
    })
  end

  if cfg.diagnostics.check_permissions and info.too_open then
    add(ctx, {
      code = "SSH033",
      severity = "error",
      field = "identity_file",
      message = ("Key %s is mode %s — too open"):format(shown, info.mode or "?"),
      detail = "ssh refuses private keys that group or others can read: " .. "'WARNING: UNPROTECTED PRIVATE KEY FILE'.",
      fix = cfg.security.offer_permission_fix and {
        label = "chmod 600",
        apply = function(host)
          local ok, msg = keys.fix_permissions(host.identity_file)
          if not ok then
            return nil, msg
          end
          return nil, msg
        end,
      } or nil,
    })
  end

  if cfg.diagnostics.check_permissions then
    local dir = keys.ssh_dir_status()
    if dir.too_open then
      add(ctx, {
        code = "SSH034",
        severity = "warn",
        field = "identity_file",
        message = ("%s is mode %s — should be 0700"):format(util.contract(dir.path), dir.mode or "?"),
        detail = "A readable ~/.ssh exposes your known_hosts, config and public keys to every local account.",
        fix = {
          label = "chmod 700 ~/.ssh",
          apply = function()
            local ok, err = util.chmod(dir.path, keys.MODE_DIR)
            if not ok then
              return nil, ("chmod failed: %s"):format(err or "unknown error")
            end
            return nil, ("set %s to 0700"):format(util.contract(dir.path))
          end,
        },
      })
    end
  end

  if info.encrypted == true then
    local loaded = agent.has_key(h.identity_file)
    if loaded == false then
      add(ctx, {
        code = "SSH036",
        severity = "warn",
        field = "identity_file",
        message = ("%s is passphrase-protected and not loaded in the agent"):format(shown),
        detail = "You will be asked for the passphrase on every connection until you `ssh-add` it.",
        fix = {
          label = "ssh-add this key",
          -- Opens a terminal that asks for a passphrase; never do that behind
          -- the user's back during a bulk repair.
          auto = false,
          apply = function(host)
            agent.add(host.identity_file, { apple_keychain = true })
            return nil, "running ssh-add…"
          end,
        },
      })
    end
  end

  if info.type == "DSA" then
    add(ctx, {
      code = "SSH042",
      severity = "warn",
      field = "identity_file",
      message = "DSA keys are disabled in OpenSSH 9.8+",
      detail = "Generate an ed25519 key instead (`G` in the manager).",
    })
  elseif info.type == "RSA" and info.bits and info.bits < 2048 then
    add(ctx, {
      code = "SSH042",
      severity = "warn",
      field = "identity_file",
      message = ("%d-bit RSA is below the modern minimum"):format(info.bits),
      detail = "OpenSSH 9.x rejects RSA keys under 1024 bits and many servers require 2048+.",
    })
  end

  -- A key checked into a repository is a live credential in version control.
  local expanded = util.expand(h.identity_file)
  local home_ssh = util.expand("~/.ssh")
  if expanded:sub(1, #home_ssh) ~= home_ssh then
    local dir = util.dirname(expanded)
    if util.is_dir(util.join(dir, ".git")) or util.is_dir(util.join(util.dirname(dir), ".git")) then
      add(ctx, {
        code = "SSH040",
        severity = "warn",
        field = "identity_file",
        message = ("%s sits inside a git working tree"):format(shown),
        detail = "One `git add -A` away from publishing a private key. Move it to ~/.ssh.",
      })
    elseif util.is_world_accessible(dir) then
      add(ctx, {
        code = "SSH040",
        severity = "warn",
        field = "identity_file",
        message = ("%s lives in a world-readable directory"):format(shown),
        detail = "Any local account can copy the key regardless of the key's own mode.",
      })
    end
  end
end

---@param ctx ssh_launcher.RuleContext
local function rule_jump(ctx)
  local h = ctx.host
  if util.blank(h.proxy_jump) then
    return
  end

  local Host = require("ssh_launcher.host")
  if h.proxy_jump == h.host or h.proxy_jump == Host.target(h) then
    add(ctx, {
      code = "SSH050",
      severity = "error",
      field = "proxy_jump",
      message = "The jump host is this host",
      detail = "ssh would have to connect through itself to reach itself.",
      fix = {
        label = "clear the jump host",
        apply = function(host)
          local patched = vim.deepcopy(host)
          patched.proxy_jump = nil
          return patched, "removed the jump host"
        end,
      },
    })
    return
  end

  for _, spec in ipairs(vim.split(h.proxy_jump, ",", { plain = true })) do
    spec = util.trim(spec)
    local hostpart = spec:match("^[^@]*@?([^:]+)") or spec
    if hostpart == "" or hostpart:find("%s") then
      add(ctx, {
        code = "SSH052",
        severity = "error",
        field = "proxy_jump",
        message = ("%q is not a valid jump specification"):format(spec),
        detail = "Expected `[user@]host[:port]`, or several separated by commas.",
      })
    else
      local saved = nil
      for _, other in ipairs(ctx.hosts) do
        if other.id ~= h.id and (other.name or ""):lower() == spec:lower() then
          saved = other
          break
        end
      end
      if saved then
        add(ctx, {
          code = "SSH051",
          severity = "hint",
          field = "proxy_jump",
          message = ("Jump host %q resolves through ssh_config, not this plugin"):format(spec),
          detail = ("ssh will look up %q in ~/.ssh/config. Expand it to %s to be explicit."):format(
            spec,
            require("ssh_launcher.host").target(saved)
          ),
          fix = {
            label = "expand to the full target",
            auto = false, -- changes which machine is dialled; needs a decision
            apply = function(host)
              local patched = vim.deepcopy(host)
              patched.proxy_jump = require("ssh_launcher.host").target(saved)
              return patched, ("expanded the jump host to %s"):format(patched.proxy_jump)
            end,
          },
        })
      end
    end
  end
end

---@param ctx ssh_launcher.RuleContext
local function rule_forwards(ctx)
  for _, f in ipairs(ctx.host.forwards or {}) do
    local ok, why = valid_forward(f.kind, f.spec)
    if not ok then
      add(ctx, {
        code = "SSH060",
        severity = "error",
        field = "forwards",
        message = ("Invalid %s forward %q"):format(f.kind, f.spec),
        detail = why,
      })
    elseif f.spec:match("^%*:") or f.spec:match("^0%.0%.0%.0:") then
      add(ctx, {
        code = "SSH061",
        severity = "warn",
        field = "forwards",
        message = ("Forward %q binds every interface"):format(f.spec),
        detail = "Anyone who can reach your machine reaches the tunnelled service. Bind 127.0.0.1 instead.",
        fix = {
          label = "bind to localhost",
          apply = function(host)
            local patched = vim.deepcopy(host)
            for _, ff in ipairs(patched.forwards) do
              if ff.spec == f.spec then
                ff.spec = ff.spec:gsub("^%*:", "127.0.0.1:"):gsub("^0%.0%.0%.0:", "127.0.0.1:")
              end
            end
            return patched, "bound the forward to 127.0.0.1"
          end,
        },
      })
    end
  end
end

---@param ctx ssh_launcher.RuleContext
local function rule_options(ctx)
  local h = ctx.host
  local Host = require("ssh_launcher.host")

  for key, value in pairs(h.options or {}) do
    if not Host.KNOWN_SSH_OPTION_SET[key:lower()] then
      local suggestion
      local lower = key:lower()
      for known_lower, canonical in pairs(Host.KNOWN_SSH_OPTION_SET) do
        if known_lower:sub(1, math.min(4, #lower)) == lower:sub(1, math.min(4, #lower)) then
          suggestion = canonical
          break
        end
      end
      add(ctx, {
        code = "SSH070",
        severity = "warn",
        field = "options",
        message = ("ssh does not know the option %q"):format(key),
        detail = suggestion and ("Did you mean %s?"):format(suggestion)
          or "ssh will refuse to start with a bad option.",
        fix = suggestion and {
          label = ("rename to %s"):format(suggestion),
          apply = function(host)
            local patched = vim.deepcopy(host)
            patched.options[suggestion] = patched.options[key]
            patched.options[key] = nil
            return patched, ("renamed %s to %s"):format(key, suggestion)
          end,
        } or nil,
      })
    end

    if type(value) == "string" and value:lower():match("password") and #value > 12 then
      add(ctx, {
        code = "SSH073",
        severity = "error",
        field = "options",
        message = ("Option %s looks like it contains a secret"):format(key),
        detail = "This file is plain JSON on disk. Never put credentials in it.",
      })
    end
  end

  local strict = h.strict_host_key_checking
  if strict == "no" then
    add(ctx, {
      code = "SSH071",
      severity = ctx.cfg.diagnostics.allow_insecure and "warn" or "error",
      field = "options",
      message = "Host-key checking is disabled for this host",
      detail = "`StrictHostKeyChecking=no` accepts any key, any time — that is a machine-in-the-middle "
        .. "waiting to happen. Use `accept-new` to trust on first use but still detect changes.",
      fix = {
        label = "switch to accept-new",
        apply = function(host)
          local patched = vim.deepcopy(host)
          patched.strict_host_key_checking = "accept-new"
          return patched, "set StrictHostKeyChecking to accept-new"
        end,
      },
    })
  end

  if h.forward_agent and ctx.cfg.security.warn_agent_forwarding then
    add(ctx, {
      code = "SSH072",
      severity = "warn",
      field = "options",
      message = "Agent forwarding is enabled",
      detail = "Anyone with root on the remote host can use your loaded keys while you are connected. "
        .. "Prefer ProxyJump for reaching machines behind a bastion.",
      fix = {
        label = "disable agent forwarding",
        apply = function(host)
          local patched = vim.deepcopy(host)
          patched.forward_agent = false
          return patched, "disabled agent forwarding"
        end,
      },
    })
  end
end

---@param ctx ssh_launcher.RuleContext
local function rule_secrets(ctx)
  if not ctx.cfg.security.forbid_secret_storage then
    return
  end
  local h = ctx.host
  local haystacks = { notes = h.notes, remote_command = h.remote_command }
  for field, text in pairs(haystacks) do
    if type(text) == "string" then
      local lowered = text:lower()
      if lowered:match("password%s*[:=]") or lowered:match("passwd%s*[:=]") or lowered:match("secret%s*[:=]") then
        add(ctx, {
          code = "SSH100",
          severity = "error",
          field = field,
          message = "This field looks like it contains a credential",
          detail = "Host records are stored as plain JSON. Use the agent or a secret manager instead.",
        })
      end
    end
  end
end

---@param ctx ssh_launcher.RuleContext
local function rule_known_hosts(ctx)
  if not ctx.cfg.diagnostics.check_known_hosts then
    return
  end
  local h = ctx.host
  if util.blank(h.host) then
    return
  end
  local known = keys.is_known_host(h.host, h.port)
  if known == false then
    add(ctx, {
      code = "SSH090",
      severity = "hint",
      field = "host",
      message = "No known_hosts entry yet",
      detail = "The first connection will show a fingerprint. Verify it out-of-band before accepting.",
    })
  end
end

---@param ctx ssh_launcher.RuleContext
local function rule_policy(ctx)
  local Host = require("ssh_launcher.host")
  if ctx.cfg.security.confirm_production and Host.is_production(ctx.host) then
    add(ctx, {
      code = "SSH120",
      severity = "info",
      field = "tags",
      message = "Tagged as production",
      detail = "Connecting asks for confirmation first. Disable with `security.confirm_production = false`.",
    })
  end
end

local RULES = {
  rule_name,
  rule_host,
  rule_user,
  rule_port,
  rule_key,
  rule_jump,
  rule_forwards,
  rule_options,
  rule_secrets,
  rule_known_hosts,
  rule_policy,
}

--------------------------------------------------------------------------------
-- Public API
--------------------------------------------------------------------------------

--- Run every synchronous rule.
---@param host ssh_launcher.Host
---@param opts { hosts: ssh_launcher.Host[]|nil }|nil
---@return ssh_launcher.Issue[]
function M.check(host, opts)
  opts = opts or {}
  local cfg = config.get()
  if not cfg.diagnostics.enable then
    return {}
  end

  local hosts = opts.hosts
  if hosts == nil then
    local ok, store = pcall(require, "ssh_launcher.store")
    hosts = ok and store.all() or {}
  end

  ---@type ssh_launcher.RuleContext
  local ctx = { host = host, hosts = hosts, issues = {}, cfg = cfg }

  for _, rule in ipairs(RULES) do
    local ok, err = pcall(rule, ctx)
    if not ok then
      require("ssh_launcher.log").debug(("diagnostic rule failed: %s"):format(err))
    end
  end

  table.sort(ctx.issues, function(a, b)
    local sa, sb = M.SEVERITY_ORDER[a.severity] or 0, M.SEVERITY_ORDER[b.severity] or 0
    if sa ~= sb then
      return sa > sb
    end
    return a.code < b.code
  end)

  return ctx.issues
end

--- Network-dependent rules. Calls back with the *additional* issues so the
--- caller can merge them into a list it already rendered.
---@param host ssh_launcher.Host
---@param cb fun(issues: ssh_launcher.Issue[])
function M.check_async(host, cb)
  local cfg = config.get()
  if not cfg.diagnostics.enable or util.blank(host.host) then
    return cb({})
  end
  if not (cfg.diagnostics.check_dns or cfg.diagnostics.check_reachability) then
    return cb({})
  end

  probe.check(host.host, host.port, {}, function(res)
    local issues = {}
    if res.status == probe.STATUS.DNS and cfg.diagnostics.check_dns then
      issues[#issues + 1] = {
        code = "SSH110",
        severity = "warn",
        field = "host",
        message = ("%s does not resolve"):format(host.host),
        detail = (res.detail or "") .. "\nCheck the spelling, your VPN, or add it to /etc/hosts.",
      }
    elseif cfg.diagnostics.check_reachability then
      if res.status == probe.STATUS.REFUSED then
        issues[#issues + 1] = {
          code = "SSH111",
          severity = "warn",
          field = "port",
          message = ("Nothing is listening on %s:%d"):format(host.host, host.port or 22),
          detail = "The name resolves and the machine answered, but the port is closed. "
            .. "Wrong port, or sshd is not running.",
        }
      elseif res.status == probe.STATUS.TIMEOUT then
        issues[#issues + 1] = {
          code = "SSH111",
          severity = "hint",
          field = "host",
          message = ("%s:%d did not answer in time"):format(host.host, host.port or 22),
          detail = "Typical for a firewalled host or one that needs a VPN.",
        }
      end
    end
    cb(issues)
  end)
end

--- Highest severity present.
---@param issues ssh_launcher.Issue[]
---@return string|nil
function M.worst(issues)
  local worst, rank = nil, 0
  for _, i in ipairs(issues or {}) do
    local r = M.SEVERITY_ORDER[i.severity] or 0
    if r > rank then
      worst, rank = i.severity, r
    end
  end
  return worst
end

---@param issues ssh_launcher.Issue[]
---@return table<string, integer>
function M.counts(issues)
  local counts = { error = 0, warn = 0, info = 0, hint = 0 }
  for _, i in ipairs(issues or {}) do
    counts[i.severity] = (counts[i.severity] or 0) + 1
  end
  return counts
end

---@param issues ssh_launcher.Issue[]
---@return string
function M.summary(issues)
  local c = M.counts(issues)
  local parts = {}
  if c.error > 0 then
    parts[#parts + 1] = ("%d error%s"):format(c.error, c.error == 1 and "" or "s")
  end
  if c.warn > 0 then
    parts[#parts + 1] = ("%d warning%s"):format(c.warn, c.warn == 1 and "" or "s")
  end
  if c.hint + c.info > 0 then
    parts[#parts + 1] = ("%d hint%s"):format(c.hint + c.info, (c.hint + c.info) == 1 and "" or "s")
  end
  if #parts == 0 then
    return "no problems found"
  end
  return table.concat(parts, ", ")
end

--- Apply one specific fix, including the ones `autofix` refuses to run on its
--- own. The caller is the user pressing a key, so intent is explicit.
---@param host ssh_launcher.Host
---@param issue ssh_launcher.Issue
---@return ssh_launcher.Host host, string message, boolean ok
function M.apply_fix(host, issue)
  if not issue.fix then
    return host, "that problem has no automatic fix", false
  end
  local ok, patched, msg = pcall(issue.fix.apply, host)
  if not ok then
    return host, ("fix failed: %s"):format(tostring(patched)), false
  end
  return patched or host, msg or issue.fix.label, true
end

--- Every issue that carries a fix, in display order.
---@param issues ssh_launcher.Issue[]
---@return ssh_launcher.Issue[]
function M.fixable(issues)
  return vim.tbl_filter(function(i)
    return i.fix ~= nil
  end, issues or {})
end

--- Apply every *safe* fixable issue in order, re-checking as we go so that
--- fixes which invalidate each other cannot fight. Fixes marked
--- `auto = false` — interactive ones, and ones that guess at intent — are left
--- for the user to trigger explicitly.
---@param host ssh_launcher.Host
---@param opts { hosts: ssh_launcher.Host[]|nil, max_passes: integer|nil }|nil
---@return ssh_launcher.Host host, string[] applied
function M.autofix(host, opts)
  opts = opts or {}
  local current = vim.deepcopy(host)
  local applied = {}
  local passes = opts.max_passes or 8
  -- A fix that cannot actually change anything (a failing chmod, say) would
  -- otherwise be retried on every pass.
  local attempted = {}

  for _ = 1, passes do
    local issues = M.check(current, opts)
    local acted = false
    for _, issue in ipairs(issues) do
      local tag = issue.code .. "/" .. tostring(issue.field)
      if issue.fix and issue.fix.auto ~= false and not attempted[tag] then
        attempted[tag] = true
        local ok, patched, msg = pcall(issue.fix.apply, current)
        if ok then
          if patched then
            current = patched
          end
          applied[#applied + 1] = msg or issue.fix.label
          acted = true
          break -- re-check from the top; state has changed
        end
      end
    end
    if not acted then
      break
    end
  end

  return current, applied
end

--- Convert issues to `vim.diagnostic` items anchored on form buffer lines.
---@param issues ssh_launcher.Issue[]
---@param line_for_field fun(field: string|nil): integer|nil 0-indexed
---@return vim.Diagnostic[]
function M.to_vim_diagnostics(issues, line_for_field)
  local out = {}
  for _, issue in ipairs(issues) do
    local line = line_for_field(issue.field) or 0
    local message = issue.message
    if issue.detail then
      message = message .. "\n" .. issue.detail
    end
    if issue.fix then
      message = message .. ("\n[fix available: %s]"):format(issue.fix.label)
    end
    out[#out + 1] = {
      lnum = line,
      col = 0,
      severity = M.VIM_SEVERITY[issue.severity] or vim.diagnostic.severity.INFO,
      message = message,
      source = "ssh-launcher",
      code = issue.code,
      user_data = { issue = issue },
    }
  end
  return out
end

return M
