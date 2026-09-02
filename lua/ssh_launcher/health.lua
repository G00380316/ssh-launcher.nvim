---@mod ssh_launcher.health :checkhealth ssh_launcher

local M = {}

local start = vim.health.start
local ok = vim.health.ok
local warn = vim.health.warn
local error = vim.health.error
local info = vim.health.info

local function check_neovim()
  start("Neovim")
  if vim.fn.has("nvim-0.10") == 1 then
    ok(("Neovim %s"):format(tostring(vim.version())))
  else
    error("ssh-launcher.nvim needs Neovim 0.10 or newer", {
      "Upgrade Neovim, or pin the plugin to the 1.x tag.",
    })
  end
  if vim.fn.has("nvim-0.11") == 1 then
    info("terminal sessions use jobstart({ term = true })")
  else
    info("terminal sessions use the legacy termopen()")
  end
end

local function check_binaries()
  start("External tools")
  local util = require("ssh_launcher.util")

  local required = { "ssh" }
  local optional = {
    ["scp"] = "copying files and Neovim configuration to a host",
    ["ssh-add"] = "loading passphrase-protected keys into the agent",
    ["ssh-keygen"] = "key inspection, fingerprints and known_hosts repair",
    ["ssh-copy-id"] = "installing your public key on a remote host",
    ["tar"] = "packaging this Neovim configuration for a remote workspace",
  }

  for _, bin in ipairs(required) do
    if util.has_executable(bin) then
      local res = util.system_sync({ bin, "-V" }, 2000)
      local version = util.trim((res.stderr ~= "" and res.stderr or res.stdout))
      ok(("%s found — %s"):format(bin, version ~= "" and version or "version unknown"))
    else
      error(("%s is not on $PATH"):format(bin), { "Install OpenSSH, or set ssh.binary in setup()." })
    end
  end

  for bin, why in pairs(optional) do
    if util.has_executable(bin) then
      ok(("%s found"):format(bin))
    else
      warn(("%s is missing"):format(bin), { ("Without it: no %s."):format(why) })
    end
  end

  if vim.env.TMUX and util.has_executable("tmux") then
    info("inside tmux — terminal.strategy = 'tmux' will open sessions in tmux windows")
  end
end

local function check_permissions()
  start("File permissions")
  local util = require("ssh_launcher.util")
  local keys = require("ssh_launcher.keys")
  local config = require("ssh_launcher.config")

  local dir = keys.ssh_dir_status()
  if not util.is_dir(dir.path) then
    info(("%s does not exist yet"):format(util.contract(dir.path)))
  elseif dir.too_open then
    warn(("%s is mode %s"):format(util.contract(dir.path), dir.mode or "?"), {
      ("Run: chmod 700 %s"):format(util.contract(dir.path)),
      "A readable ~/.ssh exposes your config, known_hosts and public keys to other local accounts.",
    })
  else
    ok(("%s is mode %s"):format(util.contract(dir.path), dir.mode or "?"))
  end

  local store_path = util.expand(config.get().store.path)
  if util.is_file(store_path) then
    local open, mode = util.is_world_accessible(store_path)
    if open then
      warn(("the host database is mode %s"):format(mode or "?"), {
        ("Run: chmod 600 %s"):format(util.contract(store_path)),
      })
    else
      ok(("host database %s is mode %s"):format(util.contract(store_path), mode or "?"))
    end
  else
    info(("no host database yet (will be created at %s)"):format(util.contract(store_path)))
  end

  local bad = {}
  for _, info_ in ipairs(keys.discover()) do
    if info_.too_open then
      bad[#bad + 1] = ("%s (mode %s)"):format(util.contract(info_.path), info_.mode or "?")
    end
  end
  if #bad > 0 then
    warn(
      ("%d private key(s) are readable by others"):format(#bad),
      vim.list_extend(bad, {
        "ssh refuses keys with loose permissions. Open the manager and press f to fix them.",
      })
    )
  else
    ok("every discovered private key is mode 0600 or tighter")
  end
end

local function check_agent()
  start("ssh-agent")
  local agent = require("ssh_launcher.agent")
  local running, reason = agent.running()
  if not running then
    warn(reason, {
      "Start one with: eval $(ssh-agent -s)",
      "Without an agent you re-enter passphrases on every connection.",
    })
    return
  end
  local loaded, err = agent.list_sync()
  if not loaded then
    warn(err or "agent unreachable")
    return
  end
  if #loaded == 0 then
    local policy = require("ssh_launcher.config").get().ssh.auto_add_keys
    warn("the agent is running but holds no identities", {
      policy == "never" and "ssh.auto_add_keys is 'never', so keys are never loaded for you."
        or ("Locked keys are loaded on demand (ssh.auto_add_keys = %q)."):format(policy),
      "To load one now: press A in the manager, or run ssh-add ~/.ssh/id_ed25519",
    })
  else
    ok(("%d identit%s loaded"):format(#loaded, #loaded == 1 and "y" or "ies"))
    for _, k in ipairs(loaded) do
      info(("  %s %s %s"):format(k.type or "?", k.fingerprint, k.comment))
    end
  end
end

local function check_hosts()
  start("Hosts")
  local store = require("ssh_launcher.store")
  local diagnostics = require("ssh_launcher.diagnostics")
  local Host = require("ssh_launcher.host")

  local saved = store.list()
  local external = store.external()
  info(("%d saved host(s), %d from external sources"):format(#saved, #external))

  if #saved == 0 and #external == 0 then
    info("nothing configured yet — `:Ssh add`, or `:Ssh import` to pull in ~/.ssh/config")
    return
  end

  local totals = { error = 0, warn = 0, hint = 0, info = 0 }
  local broken = {}
  for _, h in ipairs(store.all()) do
    local issues = diagnostics.check(h)
    local counts = diagnostics.counts(issues)
    for key, value in pairs(counts) do
      totals[key] = (totals[key] or 0) + value
    end
    if counts.error > 0 then
      broken[#broken + 1] = ("%s (%s): %s"):format(Host.label(h), Host.target(h), diagnostics.summary(issues))
    end
  end

  if totals.error > 0 then
    error(
      ("%d host(s) have blocking problems"):format(#broken),
      vim.list_extend(broken, {
        "Open the manager and press D on a host for the details, f to repair.",
      })
    )
  elseif totals.warn > 0 then
    warn(("%d warning(s) across your hosts"):format(totals.warn), {
      "Run :Ssh diagnose for the full list.",
    })
  else
    ok("every host passes validation")
  end
end

local function check_ssh_config()
  start("ssh_config")
  local util = require("ssh_launcher.util")
  local config = require("ssh_launcher.config")
  local sshconfig = require("ssh_launcher.sshconfig")

  local path = util.expand(config.get().ssh_config.path)
  if not util.is_file(path) then
    info(("%s does not exist"):format(util.contract(path)))
    return
  end
  local hosts = sshconfig.hosts(true)
  ok(("parsed %s — %d host block(s)"):format(util.contract(path), #hosts))

  local content = util.read_file(path) or ""
  if content:find("StrictHostKeyChecking%s+no") then
    warn("ssh_config disables host-key checking somewhere", {
      "`StrictHostKeyChecking no` accepts any host key silently. Prefer `accept-new`.",
    })
  end
end

local function check_config()
  start("Configuration")
  local config = require("ssh_launcher.config")
  local cfg = config.get()

  if not config.did_setup then
    info("setup() has not been called; defaults are in effect")
  end

  if cfg.ssh.strict_host_key_checking == "no" then
    error("ssh.strict_host_key_checking is 'no'", {
      "Every connection will silently accept whatever key the far end presents.",
      "Use 'accept-new' to trust the first key but still detect a change.",
    })
  else
    ok(("host-key policy: %s"):format(cfg.ssh.strict_host_key_checking))
  end

  if cfg.ssh.forward_agent then
    warn("agent forwarding is on for every host", {
      "Anyone with root on a remote host can then use your loaded keys.",
      "Prefer per-host forwarding, or ProxyJump.",
    })
  end

  if cfg.ssh.control_master then
    ok(("connection multiplexing enabled (ControlPersist %s)"):format(cfg.ssh.control_persist))
  else
    info("connection multiplexing is off — enable ssh.control_master for near-instant reconnects")
  end

  info(("terminal strategy: %s"):format(cfg.terminal.strategy))
  info(("remote file adapter: %s"):format(require("ssh_launcher.remote").adapter() or "unavailable"))
  info(("remote Neovim strategy: %s"):format(cfg.workspace.strategy))
  info(("picker: %s"):format(cfg.ui.picker))
  info(("diagnostics on connect: %s"):format(cfg.diagnostics.on_connect))
end

local function check_ui()
  start("Interface")
  local config = require("ssh_launcher.config")
  local cfg = config.get()

  if config.use_icons() then
    ok("Nerd Font glyphs enabled")
  else
    ok("ASCII glyphs (set vim.g.have_nerd_font = true, or ui.icons = true, for Nerd Font icons)")
  end

  if cfg.a11y.announce then
    ok("state changes are echoed for screen readers")
  else
    info("a11y.announce is off — screen readers will not hear state changes")
  end
  if cfg.a11y.text_markers then
    ok("status is conveyed as text as well as colour")
  else
    warn("a11y.text_markers is off — status is conveyed by colour and glyph only")
  end
  if cfg.a11y.high_contrast then
    info("high-contrast highlighting is on")
  end

  for _, mod in ipairs({ "telescope", "fzf-lua", "snacks" }) do
    if pcall(require, mod) then
      info(("%s is available as a picker"):format(mod))
    end
  end
end

function M.check()
  local okmod, err = pcall(function()
    check_neovim()
    check_binaries()
    check_config()
    check_permissions()
    check_agent()
    check_ssh_config()
    check_hosts()
    check_ui()
  end)
  if not okmod then
    error("health check crashed: " .. tostring(err))
  end
end

return M
