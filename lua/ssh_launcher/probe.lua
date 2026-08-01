---@mod ssh_launcher.probe Non-blocking reachability checks
---
--- DNS resolution and a bare TCP connect, both on libuv, both cached. Nothing
--- here ever blocks the editor: a slow or blackholed host costs the UI nothing.

local util = require("ssh_launcher.util")

local uv = util.uv
local M = {}

M.STATUS = {
  UNKNOWN = "unknown",
  CHECKING = "checking",
  UP = "up",
  REFUSED = "refused",
  TIMEOUT = "timeout",
  DNS = "dns",
  ERROR = "error",
}

--- Human wording for each status, so the UI never has to encode meaning in
--- colour alone.
M.LABEL = {
  unknown = "not checked",
  checking = "checking…",
  up = "reachable",
  refused = "connection refused",
  timeout = "timed out",
  dns = "name does not resolve",
  error = "unreachable",
}

---@class ssh_launcher.ProbeResult
---@field status string
---@field detail string|nil
---@field latency_ms integer|nil
---@field at integer
---@field addresses string[]|nil

---@type table<string, ssh_launcher.ProbeResult>
local cache = {}

---@type table<string, fun(res: ssh_launcher.ProbeResult)[]>
local inflight = {}

--- Results older than this are re-checked on demand.
M.ttl = 60

---@param host string
---@param port integer|nil
---@return string
local function key_for(host, port)
  return ("%s:%d"):format(host or "", port or 22)
end

---@param host string
---@param port integer|nil
---@return ssh_launcher.ProbeResult|nil
function M.cached(host, port)
  local entry = cache[key_for(host, port)]
  if not entry then
    return nil
  end
  if util.now() - entry.at > M.ttl then
    return nil
  end
  return entry
end

function M.invalidate(host, port)
  if host then
    cache[key_for(host, port)] = nil
  else
    cache = {}
  end
end

---@param host string
---@param port integer|nil
---@param result ssh_launcher.ProbeResult
local function finish(host, port, result)
  local k = key_for(host, port)
  result.at = util.now()
  cache[k] = result
  local waiters = inflight[k] or {}
  inflight[k] = nil
  for _, cb in ipairs(waiters) do
    local ok, err = pcall(cb, result)
    if not ok then
      require("ssh_launcher.log").debug("probe callback failed: " .. tostring(err))
    end
  end
end

--- Resolve a name without blocking.
---@param host string
---@param cb fun(addresses: string[]|nil, err: string|nil)
function M.resolve(host, cb)
  if util.blank(host) then
    return cb(nil, "no host")
  end
  -- Literal addresses need no resolver.
  if host:match("^%d+%.%d+%.%d+%.%d+$") or host:match("^[%x:]+:[%x:]*$") then
    return cb({ host }, nil)
  end
  uv.getaddrinfo(
    host,
    nil,
    { socktype = "stream" },
    vim.schedule_wrap(function(err, res)
      if err or not res or #res == 0 then
        return cb(nil, err or "no addresses")
      end
      local addrs, seen = {}, {}
      for _, entry in ipairs(res) do
        if entry.addr and not seen[entry.addr] then
          seen[entry.addr] = true
          addrs[#addrs + 1] = entry.addr
        end
      end
      cb(addrs, nil)
    end)
  )
end

--- TCP-connect to `host:port` and report what happened.
---@param host string
---@param port integer|nil
---@param opts { timeout: integer|nil, force: boolean|nil }|nil
---@param cb fun(res: ssh_launcher.ProbeResult)
function M.check(host, port, opts, cb)
  opts = opts or {}
  port = port or 22
  cb = cb or function() end

  if util.blank(host) then
    return cb({ status = M.STATUS.ERROR, detail = "no host", at = util.now() })
  end

  local k = key_for(host, port)
  if not opts.force then
    local hit = M.cached(host, port)
    if hit then
      return cb(hit)
    end
  end

  if inflight[k] then
    table.insert(inflight[k], cb)
    return
  end
  inflight[k] = { cb }

  local timeout = opts.timeout or require("ssh_launcher.config").get().diagnostics.probe_timeout
  local started = uv.now()

  M.resolve(host, function(addrs, rerr)
    if not addrs then
      return finish(host, port, {
        status = M.STATUS.DNS,
        detail = tostring(rerr or "no addresses"),
        at = util.now(),
      })
    end

    local sock = uv.new_tcp()
    if not sock then
      return finish(host, port, { status = M.STATUS.ERROR, detail = "no socket", at = util.now() })
    end

    local settled = false
    local timer = uv.new_timer()

    local function done(result)
      if settled then
        return
      end
      settled = true
      if timer and not timer:is_closing() then
        timer:stop()
        timer:close()
      end
      if sock and not sock:is_closing() then
        sock:close()
      end
      result.addresses = addrs
      vim.schedule(function()
        finish(host, port, result)
      end)
    end

    timer:start(timeout, 0, function()
      done({ status = M.STATUS.TIMEOUT, detail = ("no answer within %dms"):format(timeout), at = 0 })
    end)

    local ok, err = pcall(sock.connect, sock, addrs[1], port, function(cerr)
      if cerr then
        local status = tostring(cerr):find("ECONNREFUSED") and M.STATUS.REFUSED or M.STATUS.ERROR
        return done({ status = status, detail = tostring(cerr), at = 0 })
      end
      done({
        status = M.STATUS.UP,
        latency_ms = uv.now() - started,
        at = 0,
      })
    end)

    if not ok then
      done({ status = M.STATUS.ERROR, detail = tostring(err), at = 0 })
    end
  end)
end

--- Probe many hosts with a bounded number of sockets in flight.
---@param hosts ssh_launcher.Host[]
---@param opts { concurrency: integer|nil, force: boolean|nil, on_each: fun(h: ssh_launcher.Host, res: ssh_launcher.ProbeResult)|nil }|nil
---@param cb fun()|nil called once every host has settled
function M.check_many(hosts, opts, cb)
  opts = opts or {}
  local concurrency = opts.concurrency or 16
  local index = 0
  local active = 0
  local remaining = #hosts

  if remaining == 0 then
    if cb then
      cb()
    end
    return
  end

  local function pump()
    while active < concurrency and index < #hosts do
      index = index + 1
      local h = hosts[index]
      active = active + 1
      M.check(h.host, h.port, { force = opts.force }, function(res)
        active = active - 1
        remaining = remaining - 1
        if opts.on_each then
          pcall(opts.on_each, h, res)
        end
        if remaining == 0 then
          if cb then
            cb()
          end
        else
          pump()
        end
      end)
    end
  end

  pump()
end

return M
