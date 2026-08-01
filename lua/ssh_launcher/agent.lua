---@mod ssh_launcher.agent ssh-agent integration
---
--- The agent is what makes passphrase-protected keys usable, so a "why is it
--- asking for my passphrase every time" answer needs to be one keystroke away.

local util = require("ssh_launcher.util")
local log = require("ssh_launcher.log")

local M = {}

---@class ssh_launcher.AgentKey
---@field bits integer|nil
---@field fingerprint string
---@field comment string
---@field type string|nil

---@return string|nil
function M.socket()
  return util.nonblank(vim.env.SSH_AUTH_SOCK)
end

--- Is an agent reachable? A stale `SSH_AUTH_SOCK` pointing at a dead socket is
--- extremely common after a reboot, so the socket file is stat'ed too.
---@return boolean running, string reason
function M.running()
  local sock = M.socket()
  if not sock then
    return false, "SSH_AUTH_SOCK is not set"
  end
  local st = util.stat(sock)
  if not st then
    return false, ("SSH_AUTH_SOCK points at %s, which does not exist"):format(util.contract(sock))
  end
  return true, "agent socket present"
end

---@param stdout string
---@return ssh_launcher.AgentKey[]
local function parse_list(stdout)
  local out = {}
  for line in (stdout .. "\n"):gmatch("(.-)\n") do
    local bits, fp, rest = line:match("^(%d+)%s+(%S+)%s+(.*)$")
    if fp then
      local comment, type_ = (rest or ""):match("^(.-)%s*%((%u[%w%-]*)%)%s*$")
      out[#out + 1] = {
        bits = tonumber(bits),
        fingerprint = fp,
        comment = util.trim(comment or rest or ""),
        type = type_,
      }
    end
  end
  return out
end

--- Loaded identities. `ok=false` distinguishes "no agent" from "agent with no
--- keys", which are very different problems.
---@param cb fun(keys: ssh_launcher.AgentKey[]|nil, err: string|nil)
function M.list(cb)
  if not util.has_executable("ssh-add") then
    return cb(nil, "ssh-add is not installed")
  end
  local running, reason = M.running()
  if not running then
    return cb(nil, reason)
  end
  util.system({ "ssh-add", "-l" }, { timeout = 3000 }, function(res)
    -- ssh-add -l: 0 = keys listed, 1 = agent has no identities, 2 = no agent
    if res.code == 0 then
      return cb(parse_list(res.stdout), nil)
    elseif res.code == 1 then
      return cb({}, nil)
    end
    cb(nil, util.nonblank(res.stderr) or "could not talk to the agent")
  end)
end

---@type { at: integer, keys: ssh_launcher.AgentKey[]|nil, err: string|nil }|nil
local list_cache = nil

--- How long a synchronous agent listing stays fresh, in seconds. Short enough
--- that adding a key shows up almost immediately, long enough that validating
--- five hundred hosts forks one process rather than five hundred.
M.cache_ttl = 3

--- Invalidate the cached listing (after ssh-add / ssh-add -d).
function M.invalidate()
  list_cache = nil
end

--- Synchronous variant for diagnostics that must answer immediately.
--- Cached for |ssh_launcher.agent.cache_ttl| seconds.
---@param force boolean|nil
---@return ssh_launcher.AgentKey[]|nil, string|nil
function M.list_sync(force)
  if not force and list_cache and (os.time() - list_cache.at) < M.cache_ttl then
    return list_cache.keys, list_cache.err
  end

  local function remember(keys, err)
    list_cache = { at = os.time(), keys = keys, err = err }
    return keys, err
  end

  if not util.has_executable("ssh-add") then
    return remember(nil, "ssh-add is not installed")
  end
  local running, reason = M.running()
  if not running then
    return remember(nil, reason)
  end
  local res = util.system_sync({ "ssh-add", "-l" }, 2000)
  if res.code == 0 then
    return remember(parse_list(res.stdout), nil)
  elseif res.code == 1 then
    return remember({}, nil)
  end
  return remember(nil, util.nonblank(res.stderr) or "could not talk to the agent")
end

--- Is a specific key loaded? Compares SHA256 fingerprints, which is the only
--- reliable identity (paths and comments both drift).
---@param key_path string
---@return boolean|nil loaded, string|nil reason
function M.has_key(key_path)
  local keys, err = M.list_sync()
  if not keys then
    return nil, err
  end
  local info = require("ssh_launcher.keys").info(key_path, { deep = true })
  if not info.fingerprint then
    return nil, "could not fingerprint the key"
  end
  for _, k in ipairs(keys) do
    if k.fingerprint == info.fingerprint then
      return true, nil
    end
  end
  return false, nil
end

--- Add a key to the agent. Runs in a terminal because ssh-add may prompt for a
--- passphrase, and swallowing that prompt is how plugins earn a bad reputation.
---@param key_path string
---@param opts { lifetime: string|nil, confirm: boolean|nil, apple_keychain: boolean|nil }|nil
---@param cb fun(ok: boolean, msg: string)|nil
function M.add(key_path, opts, cb)
  opts = opts or {}
  local path = util.expand(key_path)
  if not util.is_file(path) then
    local msg = ("%s does not exist"):format(util.contract(path))
    log.error(msg)
    if cb then
      cb(false, msg)
    end
    return
  end

  local argv = { "ssh-add" }
  if opts.lifetime then
    argv[#argv + 1] = "-t"
    argv[#argv + 1] = opts.lifetime
  end
  if opts.confirm then
    argv[#argv + 1] = "-c"
  end
  if opts.apple_keychain and vim.fn.has("mac") == 1 then
    -- macOS stores the passphrase so it is asked for exactly once, ever.
    argv[#argv + 1] = "--apple-use-keychain"
  end
  argv[#argv + 1] = path

  require("ssh_launcher.terminal").run(argv, {
    title = ("ssh-add %s"):format(util.contract(path)),
    height = 8,
    on_exit = function(code)
      require("ssh_launcher.keys").invalidate(path)
      M.invalidate()
      local ok = code == 0
      local msg = ok and ("added %s to the agent"):format(util.contract(path))
        or ("ssh-add exited with %d"):format(code)
      if ok then
        log.info(msg)
      else
        log.warn(msg)
      end
      if cb then
        cb(ok, msg)
      end
    end,
  })
end

---@param key_path string|nil nil removes every identity
---@param cb fun(ok: boolean, msg: string)|nil
function M.remove(key_path, cb)
  local argv = { "ssh-add" }
  if key_path then
    argv[#argv + 1] = "-d"
    argv[#argv + 1] = util.expand(key_path)
  else
    argv[#argv + 1] = "-D"
  end
  util.system(argv, { timeout = 3000 }, function(res)
    M.invalidate()
    local msg = util.nonblank(res.stderr) or util.nonblank(res.stdout) or (res.ok and "done" or "failed")
    if cb then
      cb(res.ok, msg)
    end
  end)
end

--- One-line summary for status displays and `:checkhealth`.
---@return string
function M.summary()
  local running, reason = M.running()
  if not running then
    return reason
  end
  local keys, err = M.list_sync()
  if not keys then
    return err or "agent unreachable"
  end
  if #keys == 0 then
    return "agent running, no identities loaded"
  end
  return ("agent running, %d identit%s loaded"):format(#keys, #keys == 1 and "y" or "ies")
end

return M
