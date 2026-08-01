---@mod ssh_launcher.config Configuration
---
--- Every knob lives here with a documented default. `setup()` deep-merges the
--- user table over these defaults and validates the result, reporting problems
--- as warnings instead of hard errors so a typo can never brick startup.

local util = require("ssh_launcher.util")

local M = {}

local data_dir = util.join(vim.fn.stdpath("data") --[[@as string]], "ssh_launcher")
local cache_dir = util.join(vim.fn.stdpath("cache") --[[@as string]], "ssh_launcher")

---@class ssh_launcher.Config
M.defaults = {
  ---------------------------------------------------------------------------
  -- Storage
  ---------------------------------------------------------------------------
  store = {
    --- Host database. Always written atomically with mode 0600.
    path = util.join(data_dir, "hosts.json"),
    --- Directory for backups, history and lock files.
    state_dir = data_dir,
    --- Keep a timestamped copy before destructive rewrites (migrations, imports).
    backup = true,
    --- How many rotated backups to retain.
    backup_keep = 5,
    --- Additional read-only host sources merged into the list.
    --- Each entry: `{ path = "...", name = "team" }` pointing at a JSON file in
    --- the export format. Perfect for a repo-checked-in fleet definition.
    extra_sources = {},
    --- Project-local overrides: when this file exists in cwd it is loaded too.
    project_file = ".ssh-launcher.json",
  },

  ---------------------------------------------------------------------------
  -- SSH invocation
  ---------------------------------------------------------------------------
  ssh = {
    binary = "ssh",
    --- "yes" | "accept-new" | "no". `no` disables host-key verification and is
    --- rejected unless `diagnostics.allow_insecure` is also true.
    strict_host_key_checking = "accept-new",
    --- Seconds before giving up on the TCP connect.
    connect_timeout = 10,
    --- Keepalive so long-lived sessions survive NAT timeouts.
    server_alive_interval = 30,
    server_alive_count_max = 3,
    --- Connection multiplexing: subsequent connections to the same host reuse
    --- the first session's channel and open in milliseconds.
    control_master = false,
    control_path = util.join(cache_dir, "cm-%C"),
    control_persist = "10m",
    --- Extra argv appended to every connection.
    extra_args = {},
    --- `-o Key=Value` pairs applied to every connection.
    default_options = {},
    --- Forward the agent by default. Off: agent forwarding lets anyone with
    --- root on the remote impersonate you.
    forward_agent = false,
    --- Request a TTY explicitly (helps with `RequestTTY no` in ssh_config).
    request_tty = true,
    --- Compress the stream. Usually a loss on modern links; opt-in.
    compression = false,
  },

  ---------------------------------------------------------------------------
  -- Terminal / window behaviour
  ---------------------------------------------------------------------------
  terminal = {
    --- "tab" | "float" | "vsplit" | "split" | "current" | "tmux"
    strategy = "tab",
    --- Reuse an existing live session for the same host instead of dialling again.
    reuse = true,
    --- Start terminal buffers in insert mode.
    start_insert = true,
    --- Close the terminal buffer when ssh exits cleanly.
    close_on_exit = false,
    --- Keep the buffer but show the exit status when ssh fails.
    notify_on_exit = true,
    --- Buffer-local options applied to session terminals.
    buf_options = {},
    win_options = { number = false, relativenumber = false, signcolumn = "no" },
    --- Float geometry when `strategy = "float"`.
    float = { width = 0.9, height = 0.85, border = "rounded" },
  },

  ---------------------------------------------------------------------------
  -- UI
  ---------------------------------------------------------------------------
  ui = {
    border = "rounded",
    width = 0.82,
    height = 0.8,
    winblend = 0,
    --- true | false | "auto" (auto follows `vim.g.have_nerd_font`).
    icons = "auto",
    --- Columns rendered in the manager, in order. Any of:
    --- status, name, target, port, key, tags, last, count.
    columns = { "status", "name", "target", "key", "tags", "last" },
    --- "frecency" | "name" | "recent" | "host" | "manual"
    sort = "frecency",
    --- Ask before deleting a host.
    confirm_delete = true,
    --- Show the keymap hint line in the manager footer.
    show_footer = true,
    --- Preview pane with resolved ssh command and diagnostics.
    preview = true,
    --- Picker used by `:Ssh connect`: "manager" | "telescope" | "fzf-lua"
    --- | "snacks" | "select" | "auto".
    picker = "manager",
  },

  ---------------------------------------------------------------------------
  -- Accessibility
  ---------------------------------------------------------------------------
  a11y = {
    --- Force ASCII glyphs everywhere (also implied by `ui.icons = false`).
    ascii = false,
    --- Echo state changes to the message area so screen readers pick them up.
    announce = true,
    --- Never encode meaning in colour alone: prefix rows with text markers.
    text_markers = true,
    --- Use bold/underline instead of subtle colour differences.
    high_contrast = false,
    --- Skip transient animations and redraw churn.
    reduce_motion = true,
    --- Show inline diagnostics as virtual text in the editor form.
    virtual_text = true,
    --- Mirror every diagnostic into a plain-text panel inside the form buffer,
    --- because virtual text is invisible to screen readers.
    diagnostics_panel = true,
  },

  ---------------------------------------------------------------------------
  -- Misconfiguration detection
  ---------------------------------------------------------------------------
  diagnostics = {
    enable = true,
    --- What to do when a host with errors is launched:
    --- "off" | "warn" | "block" (block = confirm dialog listing the problems).
    on_connect = "block",
    --- Resolve the hostname in the background and flag unknown names.
    check_dns = true,
    --- TCP-probe the port in the background for the reachability column.
    check_reachability = true,
    probe_timeout = 2000,
    --- Verify key file modes (0600) and ~/.ssh (0700).
    check_permissions = true,
    --- Read key headers to detect .pub / PuTTY / encrypted keys.
    check_key_format = true,
    --- Cross-check against ~/.ssh/known_hosts.
    check_known_hosts = true,
    --- Permit `StrictHostKeyChecking=no`. Leave false in any shared fleet.
    allow_insecure = false,
    --- Codes to never report, e.g. `{ "SSH013" }`.
    disabled = {},
    --- Downgrade specific codes: `{ SSH021 = "hint" }`.
    severity_overrides = {},
  },

  ---------------------------------------------------------------------------
  -- ~/.ssh/config integration
  ---------------------------------------------------------------------------
  ssh_config = {
    path = "~/.ssh/config",
    --- Surface ssh_config hosts in the manager (read-only, marked as such).
    include = true,
    --- Follow `Include` directives when parsing.
    follow_includes = true,
    --- Skip aliases containing wildcards.
    skip_wildcards = true,
    --- Marker comments delimiting the block this plugin owns on export.
    block_begin = "# >>> ssh-launcher.nvim managed block >>>",
    block_end = "# <<< ssh-launcher.nvim managed block <<<",
  },

  ---------------------------------------------------------------------------
  -- Security policy
  ---------------------------------------------------------------------------
  security = {
    --- Refuse to persist anything that looks like a password/secret.
    forbid_secret_storage = true,
    --- Warn when a host enables agent forwarding.
    warn_agent_forwarding = true,
    --- Extra confirmation before connecting to a production-tagged host.
    confirm_production = true,
    production_tags = { "prod", "production", "live" },
    --- Offer to chmod 600 keys that are too permissive.
    offer_permission_fix = true,
    --- Redact host/user in `:messages` style output.
    redact_in_logs = false,
  },

  ---------------------------------------------------------------------------
  -- History / ranking
  ---------------------------------------------------------------------------
  history = {
    enable = true,
    max_entries = 1000,
    --- Weighting for the frecency sort.
    frecency = { recency_weight = 1.0, frequency_weight = 1.0, half_life_days = 14 },
  },

  ---------------------------------------------------------------------------
  -- Keymaps (manager window). Set any to `false` to unbind.
  ---------------------------------------------------------------------------
  keymaps = {
    connect = { "<CR>", "o" },
    connect_split = "<C-x>",
    connect_vsplit = "<C-v>",
    connect_tab = "<C-t>",
    add = "a",
    paste_add = "p",
    edit = "e",
    duplicate = "c",
    delete = { "d", "<Del>" },
    rename = "r",
    filter = "/",
    clear_filter = "<Esc>",
    sort = "s",
    toggle_mark = "<Space>",
    clear_marks = "M",
    diagnose = "D",
    fix = "f",
    probe = "P",
    import = "i",
    export = "X",
    agent = "A",
    copy_id = "C",
    keygen = "G",
    yank_command = "y",
    open_terminal = "t",
    sessions = "S",
    help = { "?", "g?" },
    refresh = "R",
    quit = { "q", "<C-c>" },
  },

  --- Commands created by `setup()`. Legacy names are kept for compatibility.
  commands = {
    enable = true,
    legacy = true,
  },

  --- vim.log.levels threshold for notifications. DEBUG also writes a log file.
  log_level = vim.log.levels.INFO,
}

---@type ssh_launcher.Config
local options = vim.deepcopy(M.defaults)

---@type boolean
M.did_setup = false

--- Validation rules: `path -> { allowed values | validator }`.
local enums = {
  ["ssh.strict_host_key_checking"] = { "yes", "accept-new", "no", "ask" },
  ["terminal.strategy"] = { "tab", "float", "vsplit", "split", "current", "tmux" },
  ["ui.sort"] = { "frecency", "name", "recent", "host", "manual" },
  ["ui.picker"] = { "manager", "telescope", "fzf-lua", "snacks", "select", "auto" },
  ["diagnostics.on_connect"] = { "off", "warn", "block" },
}

---@param tbl table
---@param path string
---@return any
local function get_path(tbl, path)
  local node = tbl
  for part in path:gmatch("[^.]+") do
    if type(node) ~= "table" then
      return nil
    end
    node = node[part]
  end
  return node
end

---@param tbl table
---@param path string
---@param value any
local function set_path(tbl, path, value)
  local parts = vim.split(path, ".", { plain = true })
  local node = tbl
  for i = 1, #parts - 1 do
    node = node[parts[i]]
  end
  node[parts[#parts]] = value
end

---@param opts ssh_launcher.Config
---@return string[] problems
local function validate(opts)
  local problems = {}

  for path, allowed in pairs(enums) do
    local value = get_path(opts, path)
    if value ~= nil and not vim.tbl_contains(allowed, value) then
      problems[#problems + 1] =
        ("%s = %q is not one of: %s (using default)"):format(path, tostring(value), table.concat(allowed, ", "))
      set_path(opts, path, get_path(M.defaults, path))
    end
  end

  local numbers = {
    ["ssh.connect_timeout"] = { 1, 600 },
    ["ssh.server_alive_interval"] = { 0, 3600 },
    ["ssh.server_alive_count_max"] = { 0, 100 },
    ["ui.width"] = { 0.1, 1.0 },
    ["ui.height"] = { 0.1, 1.0 },
    ["ui.winblend"] = { 0, 100 },
    ["diagnostics.probe_timeout"] = { 100, 60000 },
  }
  for path, range in pairs(numbers) do
    local value = get_path(opts, path)
    if type(value) ~= "number" then
      problems[#problems + 1] = ("%s must be a number (using default)"):format(path)
      set_path(opts, path, get_path(M.defaults, path))
    elseif value < range[1] or value > range[2] then
      local clamped = math.min(math.max(value, range[1]), range[2])
      problems[#problems + 1] = ("%s = %s clamped to %s"):format(path, value, clamped)
      set_path(opts, path, clamped)
    end
  end

  if opts.ssh.strict_host_key_checking == "no" and not opts.diagnostics.allow_insecure then
    problems[#problems + 1] = "ssh.strict_host_key_checking = 'no' disables host-key verification "
      .. "and enables machine-in-the-middle attacks; falling back to 'accept-new'. "
      .. "Set diagnostics.allow_insecure = true if you truly need it."
    opts.ssh.strict_host_key_checking = "accept-new"
  end

  if type(opts.ssh.extra_args) ~= "table" then
    problems[#problems + 1] = "ssh.extra_args must be a list of strings (ignored)"
    opts.ssh.extra_args = {}
  end

  if opts.ui.icons == false then
    opts.a11y.ascii = true
  end

  return problems
end

--- Merge user options over the defaults and validate.
---@param user ssh_launcher.Config|nil
---@return ssh_launcher.Config opts, string[] problems
function M.setup(user)
  options = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), user or {})

  -- `tbl_deep_extend` merges list-like tables key-by-key, which is wrong for
  -- keymap lists and tag lists: the user means "replace", not "overlay".
  local replace_lists = {
    "ssh.extra_args",
    "security.production_tags",
    "ui.columns",
    "diagnostics.disabled",
    "store.extra_sources",
  }
  for _, path in ipairs(replace_lists) do
    local provided = user and get_path(user, path)
    if provided ~= nil then
      set_path(options, path, vim.deepcopy(provided))
    end
  end
  if user and user.keymaps then
    for key, value in pairs(user.keymaps) do
      options.keymaps[key] = value
    end
  end

  local problems = validate(options)

  require("ssh_launcher.log").level = options.log_level
  M.did_setup = true
  return options, problems
end

---@return ssh_launcher.Config
function M.get()
  return options
end

--- Resolve whether glyphs should be used, honouring `ui.icons = "auto"`.
---@return boolean
function M.use_icons()
  if options.a11y.ascii then
    return false
  end
  if options.ui.icons == "auto" then
    return vim.g.have_nerd_font == true or vim.g.have_nerd_font == 1
  end
  return options.ui.icons and true or false
end

---@param name string
---@return string|string[]|false
function M.keymap(name)
  return options.keymaps[name]
end

return M
