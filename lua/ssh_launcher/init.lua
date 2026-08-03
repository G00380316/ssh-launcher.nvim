---@mod ssh_launcher ssh-launcher.nvim
---
--- A full SSH connection manager for Neovim: store hosts, paste connection
--- strings from anywhere, catch misconfiguration before it costs you a failed
--- login, and open sessions without ever building a shell command string.
---
--- Quick start:
--- >lua
---     require("ssh_launcher").setup()
--- <
--- Then `:Ssh` opens the manager.

local M = {}

M.version = "2.0.0"

local MIN_NVIM = "nvim-0.10"

---@return boolean
local function version_ok()
  return vim.fn.has(MIN_NVIM) == 1
end

--------------------------------------------------------------------------------
-- Lifecycle
--------------------------------------------------------------------------------

--- Configure the plugin. Optional: every entry point calls this implicitly with
--- defaults if it has not run yet.
---@param opts ssh_launcher.Config|nil
---@return ssh_launcher.Config
function M.setup(opts)
  if not version_ok() then
    vim.notify(
      ("ssh-launcher.nvim requires Neovim 0.10 or newer (running %s)"):format(tostring(vim.version())),
      vim.log.levels.ERROR
    )
    return {}
  end

  local config = require("ssh_launcher.config")
  local resolved, problems = config.setup(opts)

  local log = require("ssh_launcher.log")
  for _, problem in ipairs(problems) do
    log.warn("config: " .. problem)
  end

  require("ssh_launcher.ui.theme").setup()

  if resolved.commands.enable then
    M._create_commands(resolved)
  end

  if resolved.ssh_config.import_on_setup then
    vim.schedule(function()
      local added = require("ssh_launcher.store").import(require("ssh_launcher.sshconfig").hosts())
      if added > 0 then
        log.info(("imported %d host(s) from ssh_config"):format(added))
      end
    end)
  end

  return resolved
end

local did_implicit_setup = false

--- Make sure `setup()` has run. Lets the commands work with zero configuration.
function M.ensure_setup()
  local config = require("ssh_launcher.config")
  if config.did_setup or did_implicit_setup then
    return
  end
  did_implicit_setup = true
  M.setup({})
end

--------------------------------------------------------------------------------
-- Public API
--------------------------------------------------------------------------------

--- Open the host manager.
---@param opts { filter: string|nil, sort: string|nil }|nil
function M.open(opts)
  M.ensure_setup()
  return require("ssh_launcher.ui.manager").open(opts)
end

--- Pick a host with the configured picker and connect to it.
---@param opts table|nil
function M.pick(opts)
  M.ensure_setup()
  return require("ssh_launcher.ui.picker").pick(nil, opts)
end

--- Connect to a saved host by name, a host table, or anything parseable
--- (`"deploy@10.0.0.4"`, a full `ssh …` command line).
---@param target string|ssh_launcher.Host|nil
---@param opts ssh_launcher.ConnectOpts|nil
function M.connect(target, opts)
  M.ensure_setup()
  local connect = require("ssh_launcher.connect")
  if target == nil then
    return M.pick(opts)
  end
  if type(target) == "table" then
    return connect.connect(target, opts)
  end
  local store = require("ssh_launcher.store")
  local saved = store.get_by_name(target)
  if saved then
    return connect.connect(saved, opts)
  end
  return connect.connect_text(target, opts)
end

--- Open the editor on a new host, optionally pre-filled from pasted text.
---@param text string|nil
function M.add(text)
  M.ensure_setup()
  return require("ssh_launcher.ui.form").create({ paste = text })
end

--- Edit a saved host by name (or pick one).
---@param name string|nil
function M.edit(name)
  M.ensure_setup()
  local store = require("ssh_launcher.store")
  if name then
    local h = store.get_by_name(name)
    if not h then
      return require("ssh_launcher.log").error(("no host matches %q"):format(name))
    end
    return require("ssh_launcher.ui.form").edit(h)
  end
  require("ssh_launcher.ui.picker").pick(function(h)
    require("ssh_launcher.ui.form").edit(h)
  end)
end

--- Delete a saved host by name.
---@param name string
function M.delete(name)
  M.ensure_setup()
  local store = require("ssh_launcher.store")
  local log = require("ssh_launcher.log")
  local h = store.get_by_name(name)
  if not h then
    return log.error(("no host matches %q"):format(name))
  end
  if h.readonly then
    return log.error(("%s comes from %s and cannot be deleted here"):format(h.name, h.origin or h.source))
  end
  require("ssh_launcher.ui.dialog").confirm({
    title = ("Delete %s?"):format(h.name),
    destructive = true,
    default_no = true,
    yes = "Delete",
  }, function(confirmed)
    if confirmed then
      store.remove(h.id)
      log.info(("deleted %s"):format(h.name))
    end
  end)
end

--- Report every problem with a host (or with all of them).
---@param name string|nil
function M.diagnose(name)
  M.ensure_setup()
  local store = require("ssh_launcher.store")
  local diagnostics = require("ssh_launcher.diagnostics")
  local Host = require("ssh_launcher.host")
  local log = require("ssh_launcher.log")

  if name then
    local h = store.get_by_name(name)
    if not h then
      return log.error(("no host matches %q"):format(name))
    end
    M.open()
    local manager = require("ssh_launcher.ui.manager").instance()
    if manager then
      manager:show_diagnostics()
    end
    return
  end

  local lines = {}
  local total = 0
  for _, h in ipairs(store.all()) do
    local issues = diagnostics.check(h)
    if #issues > 0 then
      total = total + #issues
      lines[#lines + 1] = ("%s (%s) — %s"):format(Host.label(h), Host.target(h), diagnostics.summary(issues))
      for _, issue in ipairs(issues) do
        lines[#lines + 1] = ("    %-6s %s  [%s]"):format(issue.severity, issue.message, issue.code)
      end
      lines[#lines + 1] = ""
    end
  end
  if total == 0 then
    return log.info("every saved host checks out")
  end
  local win = require("ssh_launcher.ui.float").text(lines, {
    title = ("Diagnostics — %d issue%s"):format(total, total == 1 and "" or "s"),
    width = 0.85,
    height = 0.8,
  })
  return win
end

--- Import hosts from ssh_config.
---@param opts { from: string|nil }|nil
function M.import(opts)
  M.ensure_setup()
  opts = opts or {}
  local log = require("ssh_launcher.log")
  local store = require("ssh_launcher.store")

  if opts.from and opts.from ~= "ssh_config" then
    local raw = require("ssh_launcher.util").read_file(opts.from)
    if not raw then
      return log.error(("cannot read %s"):format(opts.from))
    end
    local hosts = require("ssh_launcher.parser").parse_many(raw)
    local added, skipped = store.import(hosts)
    return log.info(("imported %d host(s), skipped %d duplicate(s)"):format(added, skipped))
  end

  local hosts = require("ssh_launcher.sshconfig").hosts(true)
  if #hosts == 0 then
    return log.warn("no hosts found in ~/.ssh/config")
  end
  local added, skipped = store.import(hosts)
  log.info(("imported %d host(s) from ssh_config, skipped %d duplicate(s)"):format(added, skipped))
end

--- Export every saved host into the managed block of ~/.ssh/config.
---@param opts { path: string|nil, dry_run: boolean|nil }|nil
function M.export(opts)
  M.ensure_setup()
  opts = opts or {}
  local store = require("ssh_launcher.store")
  local sshconfig = require("ssh_launcher.sshconfig")
  local log = require("ssh_launcher.log")

  local hosts = store.list()
  if #hosts == 0 then
    return log.warn("nothing to export")
  end
  local ok = sshconfig.export(hosts, opts)
  if ok and not opts.dry_run then
    log.info(("exported %d host(s) to %s"):format(#hosts, opts.path or "~/.ssh/config"))
  end
end

--- Open the ssh-agent menu.
function M.agent()
  M.ensure_setup()
  M.open()
  local manager = require("ssh_launcher.ui.manager").instance()
  if manager then
    manager:agent_menu()
  end
end

--- Jump to a running session.
function M.sessions()
  M.ensure_setup()
  require("ssh_launcher.connect").pick_session()
end

--- Saved hosts, for scripting.
---@return ssh_launcher.Host[]
function M.hosts()
  M.ensure_setup()
  return require("ssh_launcher.store").all()
end

--- Add a host programmatically. Accepts a partial host table or any string the
--- parser understands.
---@param spec string|table
---@return ssh_launcher.Host|nil host, string|nil err
function M.save(spec)
  M.ensure_setup()
  local store = require("ssh_launcher.store")
  if type(spec) == "string" then
    local res = require("ssh_launcher.parser").parse(spec)
    if not res or res.kind == "secret" then
      return nil, "could not parse that connection string"
    end
    return store.add(res.host)
  end
  return store.add(spec)
end

function M.health()
  M.ensure_setup()
  vim.cmd("checkhealth ssh_launcher")
end

--- Report anything in the running configuration that could interfere with a
--- session window, and the state of any sessions already open.
---
--- When a terminal opens and then vanishes, the cause is an autocommand
--- somewhere reacting to the window or buffer events. This lists the
--- candidates by the group that registered them, which names the culprit.
function M.doctor()
  M.ensure_setup()
  local cfg = require("ssh_launcher.config").get()
  local connect = require("ssh_launcher.connect")
  local Host = require("ssh_launcher.host")

  local terminal = require("ssh_launcher.terminal")
  local hooks = terminal.third_party_hooks()
  local shielded = cfg.terminal.protect == true
    or terminal.hostile_environment
    or (cfg.terminal.protect == "auto" and #hooks > 0)

  local lines = {
    "Session window settings",
    ("  strategy       %s"):format(
      type(cfg.terminal.strategy) == "function" and "custom function" or tostring(cfg.terminal.strategy)
    ),
    ("  protect        %s   -> TermOpen currently %s"):format(
      tostring(cfg.terminal.protect),
      shielded and "SUPPRESSED for sessions" or "allowed to run"
    ),
    ("  ensure_visible %s"):format(tostring(cfg.terminal.ensure_visible)),
    ("  noautocmd      %s"):format(tostring(cfg.terminal.noautocmd)),
    ("  reuse          %s"):format(tostring(cfg.terminal.reuse)),
    ("  hidden         %s   (off unloads a terminal when its window closes)"):format(tostring(vim.o.hidden)),
    "",
    "Terminal plugins detected",
  }

  if #hooks == 0 then
    lines[#lines + 1] = "  none — nothing else reacts to these events"
  else
    for _, hook in ipairs(hooks) do
      lines[#lines + 1] = ("  %-14s %s"):format(hook.event, hook.group)
    end
    lines[#lines + 1] = ""
    lines[#lines + 1] = shielded and "  All of the above are kept away from session windows."
      or "  These are allowed to run while a session opens."
  end

  lines[#lines + 1] = ""
  lines[#lines + 1] = "Open sessions"

  connect.prune_sessions()
  local sessions = connect.sessions()
  if #sessions == 0 then
    lines[#lines + 1] = "  none"
  end
  for _, s in ipairs(sessions) do
    local visible = false
    for _, w in ipairs(vim.api.nvim_list_wins()) do
      if vim.api.nvim_win_get_buf(w) == s.handle.buf then
        visible = true
      end
    end
    lines[#lines + 1] = ("  %-24s buf %-4d %s, %s"):format(
      Host.label(s.host),
      s.handle.buf,
      s.ended_at and "exited" or "running",
      visible and "on screen" or "NOT ON SCREEN — press S in the manager to jump to it"
    )
  end

  -- Events that fire when a window or terminal buffer appears. Anything hooked
  -- to these can move, hide or close the session window.
  lines[#lines + 1] = ""
  lines[#lines + 1] = "Autocommands that can affect a session window"
  local events = { "TermOpen", "TermClose", "BufWinEnter", "BufEnter", "WinEnter", "WinNew", "TabNewEntered", "BufNew" }
  local seen = {}
  local found = 0
  for _, event in ipairs(events) do
    local ok, autocmds = pcall(vim.api.nvim_get_autocmds, { event = event })
    if ok then
      for _, au in ipairs(autocmds) do
        local group = au.group_name or "(no group)"
        local key = event .. "/" .. group
        if not seen[key] and group ~= "SshLauncherTheme" and not group:match("^SshLauncher") then
          seen[key] = true
          found = found + 1
          lines[#lines + 1] = ("  %-14s %s"):format(event, group)
        end
      end
    end
  end
  if found == 0 then
    lines[#lines + 1] = "  none — your configuration is not hooking these events"
  else
    lines[#lines + 1] = ""
    lines[#lines + 1] = "  If a session window keeps disappearing, one of the groups above is doing it."
    lines[#lines + 1] = "  (nvim.terminal is Neovim's own and is never the cause.)"
    lines[#lines + 1] = ""
    lines[#lines + 1] = "  Inspect one with:  :verbose autocmd TermOpen"
    lines[#lines + 1] = "  Force protection:  terminal.protect = true"
    lines[#lines + 1] = '  Last resort:       terminal.eventignore = { "all" }'
    lines[#lines + 1] = ""
    lines[#lines + 1] = "  If one of these groups is yours, the tidiest fix is to skip our buffers:"
    lines[#lines + 1] = "    if vim.b[buf].ssh_launcher then return end"
    lines[#lines + 1] = "  Session buffers are marked before they are ever displayed. See"
    lines[#lines + 1] = "  :help ssh-launcher-marker"
  end

  return require("ssh_launcher.ui.float").text(lines, {
    title = "ssh-launcher doctor",
    width = 0.8,
    height = math.min(#lines + 2, math.floor(vim.o.lines * 0.8)),
  })
end

--------------------------------------------------------------------------------
-- Commands
--------------------------------------------------------------------------------

---@type table<string, { run: fun(args: string[], bang: boolean), desc: string, complete: string|nil }>
local SUBCOMMANDS = {
  open = {
    desc = "Open the host manager",
    run = function()
      M.open()
    end,
  },
  connect = {
    desc = "Connect to a host by name, or to anything parseable",
    complete = "host",
    run = function(args)
      M.connect(#args > 0 and table.concat(args, " ") or nil)
    end,
  },
  add = {
    desc = "Add a host, optionally seeded from a pasted connection string",
    run = function(args)
      M.add(#args > 0 and table.concat(args, " ") or nil)
    end,
  },
  edit = {
    desc = "Edit a saved host",
    complete = "host",
    run = function(args)
      M.edit(args[1] and table.concat(args, " ") or nil)
    end,
  },
  delete = {
    desc = "Delete a saved host",
    complete = "host",
    run = function(args)
      if not args[1] then
        return require("ssh_launcher.log").error("usage: :Ssh delete <name>")
      end
      M.delete(table.concat(args, " "))
    end,
  },
  list = {
    desc = "List saved hosts",
    run = function()
      local Host = require("ssh_launcher.host")
      local lines = {}
      for _, h in ipairs(M.hosts()) do
        lines[#lines + 1] = ("%-28s %-34s %s"):format(
          Host.label(h),
          Host.target(h),
          h.identity_file and require("ssh_launcher.util").contract(h.identity_file) or "agent"
        )
      end
      if #lines == 0 then
        return require("ssh_launcher.log").info("no hosts saved")
      end
      require("ssh_launcher.ui.float").text(lines, { title = "Saved hosts", width = 0.8 })
    end,
  },
  diagnose = {
    desc = "Report misconfiguration",
    complete = "host",
    run = function(args)
      M.diagnose(args[1] and table.concat(args, " ") or nil)
    end,
  },
  import = {
    desc = "Import hosts from ~/.ssh/config or a file",
    complete = "file",
    run = function(args)
      M.import({ from = args[1] })
    end,
  },
  export = {
    desc = "Export saved hosts into ~/.ssh/config",
    run = function(args)
      M.export({ path = args[1] })
    end,
  },
  agent = {
    desc = "Manage ssh-agent identities",
    run = function()
      M.agent()
    end,
  },
  sessions = {
    desc = "Jump to a running session",
    run = function()
      M.sessions()
    end,
  },
  keygen = {
    desc = "Generate a new key pair",
    run = function()
      M.open()
      local manager = require("ssh_launcher.ui.manager").instance()
      if manager then
        manager:keygen()
      end
    end,
  },
  reload = {
    desc = "Re-read the host database and ssh_config",
    run = function()
      require("ssh_launcher.store").reset()
      require("ssh_launcher.sshconfig").invalidate()
      require("ssh_launcher.keys").invalidate()
      require("ssh_launcher.probe").invalidate()
      require("ssh_launcher.log").info("reloaded")
    end,
  },
  health = {
    desc = "Run :checkhealth ssh_launcher",
    run = function()
      M.health()
    end,
  },
  doctor = {
    desc = "Diagnose session windows that open and then vanish",
    run = function()
      M.doctor()
    end,
  },
  version = {
    desc = "Show the plugin version",
    run = function()
      require("ssh_launcher.log").info("ssh-launcher.nvim " .. M.version)
    end,
  },
}

---@param arglead string
---@param cmdline string
---@return string[]
local function complete(arglead, cmdline)
  local parts = vim.split(cmdline, "%s+")
  -- parts[1] is the command name itself
  if #parts <= 2 then
    local names = vim.tbl_keys(SUBCOMMANDS)
    table.sort(names)
    return vim.tbl_filter(function(name)
      return name:find(arglead, 1, true) == 1
    end, names)
  end

  local sub = SUBCOMMANDS[parts[2]]
  if not sub or not sub.complete then
    return {}
  end
  if sub.complete == "file" then
    return vim.fn.getcompletion(arglead, "file")
  end
  if sub.complete == "host" then
    M.ensure_setup()
    local Host = require("ssh_launcher.host")
    local names = {}
    for _, h in ipairs(M.hosts()) do
      local label = Host.label(h)
      if label:find(arglead, 1, true) == 1 then
        names[#names + 1] = label
      end
    end
    table.sort(names)
    return names
  end
  return {}
end

--- Subcommand names, for the `plugin/` bootstrap's completion.
---@return string[]
function M._subcommands()
  local names = vim.tbl_keys(SUBCOMMANDS)
  table.sort(names)
  return names
end

M._complete = complete

--- Run `:Ssh …`. Shared by the eager `plugin/` stub and the command created by
--- `setup()`, so there is exactly one implementation and no re-dispatch.
---@param cmd table the user-command argument table
function M._dispatch(cmd)
  M.ensure_setup()
  local args = vim.deepcopy(cmd.fargs or {})
  if #args == 0 then
    return M.open()
  end
  local name = table.remove(args, 1)
  local sub = SUBCOMMANDS[name]
  if not sub then
    -- `:Ssh prod-api` should just connect; that is what people type.
    return M.connect(table.concat(cmd.fargs, " "))
  end
  return sub.run(args, cmd.bang == true)
end

--- The 1.x command names, kept so existing configs and muscle memory work.
M._legacy = {
  SshLauncher = function()
    M.open()
  end,
  SshConnect = function(args)
    M.connect(args ~= "" and args or nil)
  end,
  SshAddKey = function(args)
    M.add(args ~= "" and args or nil)
  end,
  SshEditKey = function(args)
    M.edit(args ~= "" and args or nil)
  end,
  SshAgent = function()
    M.agent()
  end,
  SshSessions = function()
    M.sessions()
  end,
  SshDiagnose = function(args)
    M.diagnose(args ~= "" and args or nil)
  end,
}

---@param cfg ssh_launcher.Config
function M._create_commands(cfg)
  vim.api.nvim_create_user_command("Ssh", M._dispatch, {
    nargs = "*",
    bang = true,
    complete = complete,
    desc = "ssh-launcher: manage and open SSH connections",
  })

  if not cfg.commands.legacy then
    return
  end

  for name, fn in pairs(M._legacy) do
    vim.api.nvim_create_user_command(name, function(cmd)
      M.ensure_setup()
      fn(cmd.args)
    end, {
      nargs = "*",
      complete = function(arglead)
        return complete(arglead, "Ssh connect " .. arglead)
      end,
      desc = "ssh-launcher: " .. name,
    })
  end
end

return M
