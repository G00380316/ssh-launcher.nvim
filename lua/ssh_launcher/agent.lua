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

---@class ssh_launcher.UnlockState
---@field needed boolean whether ssh-add would help before connecting
---@field reason string|nil "no-agent" | "not-loaded"
---@field detail string human-readable explanation
---@field key string|nil the key that needs loading

--- Would this host's key benefit from `ssh-add` before dialling?
---
--- Only true when the key is actually passphrase-protected *and* absent from
--- the agent. An unencrypted key works straight off disk, so prompting about it
--- would be pure noise.
---@param identity_file string|nil
---@return ssh_launcher.UnlockState
function M.unlock_state(identity_file)
  local none = { needed = false, detail = "nothing to unlock" }
  if util.blank(identity_file) then
    return none
  end

  local keys = require("ssh_launcher.keys")
  local info = keys.info(identity_file, { deep = true })
  if not info.exists or info.encrypted ~= true then
    return none
  end

  local running = M.running()
  if not running then
    return {
      needed = true,
      reason = "no-agent",
      key = identity_file,
      detail = ("%s needs a passphrase and no ssh-agent is running"):format(util.contract(identity_file)),
    }
  end

  local loaded = M.has_key(identity_file)
  if loaded == false then
    return {
      needed = true,
      reason = "not-loaded",
      key = identity_file,
      detail = ("%s needs a passphrase and is not loaded in the agent"):format(util.contract(identity_file)),
    }
  end

  return none
end

--- Start an ssh-agent and adopt it for this Neovim session.
---
--- The variables are exported into `vim.env` only, so the agent serves this
--- editor and anything it spawns. It is killed again on exit — leaving a
--- stray agent holding unlocked keys after Neovim closes would be worse than
--- not offering this at all.
---@param cb fun(ok: boolean, msg: string)
function M.start(cb)
  if not util.has_executable("ssh-agent") then
    return cb(false, "ssh-agent is not installed")
  end
  util.system({ "ssh-agent", "-s" }, { timeout = 5000 }, function(res)
    if not res.ok then
      return cb(false, util.nonblank(res.stderr) or "ssh-agent failed to start")
    end

    local sock = res.stdout:match("SSH_AUTH_SOCK=([^;]+)")
    local pid = res.stdout:match("SSH_AGENT_PID=([^;]+)")
    if not sock then
      return cb(false, "could not read SSH_AUTH_SOCK from ssh-agent")
    end

    vim.env.SSH_AUTH_SOCK = sock
    if pid then
      vim.env.SSH_AGENT_PID = pid
      vim.api.nvim_create_autocmd("VimLeavePre", {
        group = vim.api.nvim_create_augroup("SshLauncherAgent", { clear = true }),
        desc = "ssh-launcher: stop the agent it started",
        callback = function()
          -- Wait for it: an async call started at VimLeavePre can lose the race
          -- with the editor exiting, and the agent would outlive the session
          -- holding unlocked keys.
          pcall(function()
            vim.system({ "ssh-agent", "-k" }, { env = { SSH_AGENT_PID = pid } }):wait(2000)
          end)
        end,
      })
    end

    M.invalidate()
    cb(true, ("started an ssh-agent for this Neovim session (pid %s)"):format(pid or "?"))
  end)
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
    -- A passphrase prompt is a small, transient thing: a float that clears
    -- itself once the key is in, and stays put if it was rejected.
    strategy = opts.strategy or "float",
    width = 0.6,
    height = 10,
    close_on_exit = true,
    on_exit = function(code)
      require("ssh_launcher.keys").invalidate(path)
      M.invalidate()
      local ok = code == 0
      local msg = ok and ("added %s to the agent"):format(util.contract(path))
        or ("ssh-add %s"):format(require("ssh_launcher.terminal").describe_exit(code))
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
