---@mod ssh_launcher.fleet Running one command across many hosts
---
--- Marked hosts, one command, results collected per host. Runs non-interactively
--- (`BatchMode=yes`), because a prompt from the eleventh host of twenty is a
--- prompt nobody will ever see.
---
--- Nothing here is a shell: the command is passed to ssh as a single argument
--- and interpreted by the *remote* shell, exactly as `ssh host 'cmd'` does.

local util = require("ssh_launcher.util")
local log = require("ssh_launcher.log")
local Host = require("ssh_launcher.host")
local config = require("ssh_launcher.config")

local M = {}

---@class ssh_launcher.FleetResult
---@field host ssh_launcher.Host
---@field code integer
---@field stdout string
---@field stderr string
---@field duration_ms integer
---@field skipped string|nil why the host was not attempted

--- Hosts that cannot run a command unattended, with the reason.
---@param hosts ssh_launcher.Host[]
---@return table<string, string> reason_by_host_id
function M.blocked(hosts)
  local agent = require("ssh_launcher.agent")
  local blocked = {}
  for _, h in ipairs(hosts) do
    local state = agent.unlock_state(h.identity_file)
    if state.needed then
      blocked[h.id] = state.detail
    end
  end
  return blocked
end

--- Run `command` on every host.
---@param hosts ssh_launcher.Host[]
---@param command string
---@param opts { concurrency: integer|nil, timeout: integer|nil, on_each: fun(res: ssh_launcher.FleetResult)|nil }|nil
---@param cb fun(results: ssh_launcher.FleetResult[])
function M.run(hosts, command, opts, cb)
  opts = opts or {}
  local concurrency = opts.concurrency or 8
  local timeout = opts.timeout or 60000

  if #hosts == 0 or util.blank(command) then
    return cb({})
  end

  local blocked = M.blocked(hosts)
  local results = {}
  local index, active, remaining = 0, 0, #hosts

  local function finish(res)
    results[#results + 1] = res
    if opts.on_each then
      pcall(opts.on_each, res)
    end
    remaining = remaining - 1
    if remaining == 0 then
      -- Report in the order given, not the order they happened to return.
      local position = {}
      for i, h in ipairs(hosts) do
        position[h.id] = i
      end
      table.sort(results, function(a, b)
        return (position[a.host.id] or 0) < (position[b.host.id] or 0)
      end)
      cb(results)
    end
  end

  local function pump()
    while active < concurrency and index < #hosts do
      index = index + 1
      local h = hosts[index]

      if blocked[h.id] then
        finish({ host = h, code = -1, stdout = "", stderr = "", duration_ms = 0, skipped = blocked[h.id] })
      else
        active = active + 1
        local started = util.uv.now()
        -- `batch` adds BatchMode=yes; the command becomes ssh's final argument.
        local argv = Host.build_argv(h, { batch = true })
        argv[#argv + 1] = command

        local ok, err = pcall(vim.system, argv, { text = true, timeout = timeout }, function(res)
          vim.schedule(function()
            active = active - 1
            finish({
              host = h,
              code = res.code or -1,
              stdout = res.stdout or "",
              stderr = res.stderr or "",
              duration_ms = util.uv.now() - started,
            })
            pump()
          end)
        end)

        if not ok then
          active = active - 1
          finish({
            host = h,
            code = -1,
            stdout = "",
            stderr = tostring(err),
            duration_ms = 0,
          })
        end
      end
    end
  end

  pump()
end

--- Render results as buffer lines.
---@param command string
---@param results ssh_launcher.FleetResult[]
---@return string[]
function M.format(command, results)
  local ok_count, fail_count, skipped_count = 0, 0, 0
  for _, r in ipairs(results) do
    if r.skipped then
      skipped_count = skipped_count + 1
    elseif r.code == 0 then
      ok_count = ok_count + 1
    else
      fail_count = fail_count + 1
    end
  end

  local lines = {
    ("$ %s"):format(command),
    ("%d host%s — %d ok, %d failed, %d skipped"):format(
      #results,
      #results == 1 and "" or "s",
      ok_count,
      fail_count,
      skipped_count
    ),
    "",
  }

  for _, r in ipairs(results) do
    local status
    if r.skipped then
      status = "SKIPPED"
    elseif r.code == 0 then
      status = "ok"
    else
      status = ("exit %d"):format(r.code)
    end

    lines[#lines + 1] = ("── %s  (%s)  %s  %dms"):format(
      Host.label(r.host),
      Host.target(r.host),
      status,
      r.duration_ms
    )

    if r.skipped then
      lines[#lines + 1] = "   " .. r.skipped
    end
    for _, stream in ipairs({ r.stdout, r.stderr }) do
      for line in (stream or ""):gmatch("([^\n]*)\n?") do
        if util.trim(line) ~= "" then
          lines[#lines + 1] = "   " .. line
        end
      end
    end
    lines[#lines + 1] = ""
  end

  return lines
end

--- Run a command across hosts and show the results in a window.
---@param hosts ssh_launcher.Host[]
---@param command string
---@param opts table|nil
function M.run_and_show(hosts, command, opts)
  opts = opts or {}
  local float = require("ssh_launcher.ui.float")

  local win = float.text({ ("$ %s"):format(command), "", ("running on %d host(s)…"):format(#hosts) }, {
    title = "Fleet command",
    width = 0.85,
    height = 0.8,
    wrap = false,
  })

  local done = 0
  M.run(hosts, command, {
    concurrency = opts.concurrency or config.get().fleet.concurrency,
    timeout = opts.timeout or config.get().fleet.timeout,
    on_each = function()
      done = done + 1
      if win:valid() then
        win:set_footer(("%d/%d complete"):format(done, #hosts))
      end
    end,
  }, function(results)
    if not win:valid() then
      return
    end
    win:set_lines(M.format(command, results))
    win:set_footer("q close")
    local failed = 0
    for _, r in ipairs(results) do
      if r.code ~= 0 then
        failed = failed + 1
      end
    end
    log.announce(("fleet command finished: %d of %d failed"):format(failed, #results))
  end)

  return win
end

return M
