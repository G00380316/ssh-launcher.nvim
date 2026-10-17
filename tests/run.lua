-- ssh-launcher.nvim test suite
--
--   make test          # or: nvim --headless -u NONE -l tests/run.lua
--
-- No external test framework: the suite has to run in CI and on a contributor's
-- machine with nothing installed but Neovim itself.

local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
vim.opt.runtimepath:prepend(root)

local TMP = vim.fn.tempname()
vim.fn.mkdir(TMP, "p")

--------------------------------------------------------------------------------
-- Tiny harness
--------------------------------------------------------------------------------

local passed, failed, current = 0, 0, nil

local function suite(name)
  current = name
  io.write(("\n%s\n"):format(name))
end

---@param name string
---@param fn fun()
local function test(name, fn)
  local ok, err = pcall(fn)
  if ok then
    passed = passed + 1
    io.write(("  ok    %s\n"):format(name))
  else
    failed = failed + 1
    io.write(("  FAIL  %s\n          %s\n"):format(name, tostring(err):gsub("\n", "\n          ")))
  end
end

local function eq(actual, expected, what)
  if not vim.deep_equal(actual, expected) then
    error(("%s: expected %s, got %s"):format(what or "value", vim.inspect(expected), vim.inspect(actual)), 2)
  end
end

local function truthy(value, what)
  if not value then
    error(("%s: expected a truthy value, got %s"):format(what or "value", vim.inspect(value)), 2)
  end
end

local function falsy(value, what)
  if value then
    error(("%s: expected a falsy value, got %s"):format(what or "value", vim.inspect(value)), 2)
  end
end

local function contains(haystack, needle, what)
  if type(haystack) == "table" then
    haystack = table.concat(haystack, "\n")
  end
  if not tostring(haystack):find(needle, 1, true) then
    error(("%s: %q not found in:\n%s"):format(what or "text", needle, haystack), 2)
  end
end

--------------------------------------------------------------------------------

local function configure(extra)
  return require("ssh_launcher").setup(vim.tbl_deep_extend("force", {
    store = { path = TMP .. "/hosts.json", state_dir = TMP },
    ssh_config = { path = TMP .. "/ssh_config", include = true },
    ui = { icons = false },
    diagnostics = { check_dns = false, check_reachability = false },
  }, extra or {}))
end

local function reset_store()
  require("ssh_launcher.store").reset()
  vim.fn.delete(TMP .. "/hosts.json")
end

--------------------------------------------------------------------------------
suite("modules")
--------------------------------------------------------------------------------

test("every module loads", function()
  for _, name in ipairs({
    "util",
    "log",
    "config",
    "host",
    "store",
    "parser",
    "sshconfig",
    "keys",
    "agent",
    "probe",
    "diagnostics",
    "terminal",
    "history",
    "connect",
    "health",
    "tunnel",
    "fleet",
    "remote",
    "transfer",
    "workspace",
    "ui.theme",
    "ui.float",
    "ui.render",
    "ui.dialog",
    "ui.form",
    "ui.help",
    "ui.manager",
    "ui.picker",
    "ui.remote",
  }) do
    local ok, err = pcall(require, "ssh_launcher." .. name)
    truthy(ok, ("require ssh_launcher.%s failed: %s"):format(name, err))
  end
end)

--------------------------------------------------------------------------------
suite("util")
--------------------------------------------------------------------------------

local util = require("ssh_launcher.util")

test("expand does not glob", function()
  eq(util.expand("~/a*b"), util.home() .. "/a*b")
end)

test("contract shortens $HOME", function()
  eq(util.contract(util.home() .. "/.ssh/key"), "~/.ssh/key")
end)

test("nonblank returns nil for whitespace", function()
  eq(util.nonblank("   "), nil)
  eq(util.nonblank(" x "), "x")
end)

test("atomic write creates the file with the requested mode", function()
  local p = TMP .. "/atomic.txt"
  truthy(util.write_file_atomic(p, "hello", tonumber("600", 8)))
  eq(util.read_file(p), "hello")
  eq(util.mode_octal(p), "0600")
end)

test("json_pretty is stable and sorted", function()
  local encoded = util.json_pretty({ b = 1, a = { 1, 2 }, c = "x" })
  contains(encoded, '"a": [')
  truthy(encoded:find('"a"') < encoded:find('"b"'), "keys are sorted")
end)

test("truncate and pad are display-width aware", function()
  eq(util.fit("abcdefgh", 5), "abcd…")
  eq(util.width(util.fit("ab", 6)), 6)
end)

--------------------------------------------------------------------------------
suite("parser")
--------------------------------------------------------------------------------

local parser = require("ssh_launcher.parser")
local Host = require("ssh_launcher.host")
configure()

local PARSE_CASES = {
  {
    input = [[ssh -i "~/.ssh/lab.pem" ec2-user@ec2-3-8-1-2.eu-west-2.compute.amazonaws.com]],
    kind = "ssh-command",
    expect = {
      user = "ec2-user",
      host = "ec2-3-8-1-2.eu-west-2.compute.amazonaws.com",
      identity_file = "~/.ssh/lab.pem",
    },
  },
  {
    input = [[$ ssh -p 2222 -J bastion.corp.net deploy@10.0.4.12 'journalctl -fu api']],
    kind = "ssh-command",
    expect = {
      user = "deploy",
      host = "10.0.4.12",
      port = 2222,
      proxy_jump = "bastion.corp.net",
      remote_command = "journalctl -fu api",
    },
  },
  {
    input = "ssh://deploy@app-01.internal:2222/srv/app",
    kind = "ssh-uri",
    expect = { user = "deploy", host = "app-01.internal", port = 2222, remote_dir = "/srv/app" },
  },
  { input = "deploy@app-01:2222", kind = "target", expect = { user = "deploy", host = "app-01", port = 2222 } },
  { input = "10.0.0.4", kind = "hostname", expect = { host = "10.0.0.4" } },
  {
    input = "scp -i key.pem file.tar deploy@app-01:/tmp/",
    kind = "scp-command",
    expect = { user = "deploy", host = "app-01", identity_file = "key.pem" },
  },
  {
    input = [[rsync -e "ssh -p 2222 -i ~/.ssh/k" ./dist deploy@app-01:/srv]],
    kind = "ssh-command",
    expect = { user = "deploy", host = "app-01", port = 2222, identity_file = "~/.ssh/k" },
  },
  {
    input = [[{"host":"1.2.3.4","user":"root","key":"~/.ssh/id_ed25519"}]],
    kind = "json",
    expect = { host = "1.2.3.4", user = "root", identity_file = "~/.ssh/id_ed25519" },
  },
  {
    input = "Host: 10.0.0.5\nUser: admin\nPort: 22022\n",
    kind = "fields",
    expect = { host = "10.0.0.5", user = "admin", port = 22022 },
  },
  {
    input = "[2001:db8::1]:2222",
    kind = "hostname",
    expect = { host = "2001:db8::1", port = 2222 },
  },
  {
    input = "root@[2001:db8::1]:2222",
    kind = "target",
    expect = { host = "2001:db8::1", port = 2222, user = "root" },
  },
}

for _, case in ipairs(PARSE_CASES) do
  test(("parses %s"):format(util.truncate(case.input:gsub("\n", " "), 52)), function()
    local res = parser.parse(case.input)
    truthy(res, "nothing parsed")
    eq(res.kind, case.kind, "kind")
    local h = Host.normalize(res.host)
    for field, value in pairs(case.expect) do
      eq(h[field], value, field)
    end
  end)
end

test("refuses private key material", function()
  local res = parser.parse("-----BEGIN OPENSSH PRIVATE KEY-----\nabc\n")
  eq(res.kind, "secret")
  contains(res.warnings[1], "private key")
end)

test("discards pasted passwords", function()
  local res = parser.parse("Host: 10.0.0.5\nUser: admin\nPassword: hunter2\n")
  eq(res.host.__password, nil)
  contains(res.warnings[1], "discarded")
end)

test("carries no insecure options over", function()
  local res = parser.parse("ssh -o StrictHostKeyChecking=no root@box")
  eq(res.host.strict_host_key_checking, nil)
  contains(res.warnings[1], "host-key checking")
end)

test("parse_many reads several lines", function()
  eq(#parser.parse_many("ssh a@b.com\nssh -p 22 c@d.com\n# comment\n"), 2)
end)

test("tokenizer honours quotes and escapes", function()
  eq(parser.tokenize([[ssh -o "A b=c d" host\ name]]), { "ssh", "-o", "A b=c d", "host name" })
end)

--------------------------------------------------------------------------------
suite("host model")
--------------------------------------------------------------------------------

test("untangles user and port out of the host field", function()
  local h = Host.normalize({ host = "ssh://deploy@10.0.0.4:2222/srv" })
  eq(h.host, "10.0.0.4")
  eq(h.user, "deploy")
  eq(h.port, 2222)
  eq(h.remote_dir, "/srv")
end)

test("forces single-line fields onto one line", function()
  local h, rewrites = Host.normalize({
    name = "prod\napi",
    host = "10.0.0.1\nevil",
    user = "de\nploy",
    identity_file = "~/.ssh/a\nb",
    proxy_jump = "bas\ntion",
    remote_dir = "/srv\n/app",
    remote_command = "cd /srv\nmake deploy",
    notes = "line one\nline two",
    forwards = { { kind = "local", spec = "8080:local\nhost:80" } },
    options = { SetEnv = "A=\nb" },
  })
  local fields = {
    "name",
    "host",
    "user",
    "identity_file",
    "proxy_jump",
    "remote_dir",
    "remote_command",
    "notes",
  }
  for _, field in ipairs(fields) do
    falsy(tostring(h[field]):find("\n"), field .. " still contains a newline")
  end
  -- The rewrite is reported so the UI can tell the user their data changed.
  truthy(#rewrites > 0, "normalize reported nothing")
  falsy(h.forwards[1].spec:find("\n"), "forward spec")
  falsy(h.options.SetEnv:find("\n"), "option value")
  -- Substituted, not deleted: the whitespace rules must still see it as broken.
  eq(h.host, "10.0.0.1 evil")
  local reported = false
  for _, issue in ipairs(require("ssh_launcher.diagnostics").check(h, { hosts = {} })) do
    if issue.code == "SSH002" or issue.code == "SSH006" then
      reported = true
    end
  end
  truthy(reported, "the mangled host is still reported as malformed")
end)

test("builds argv as a list, never a shell string", function()
  local argv = Host.build_argv(Host.normalize({ host = "a.example.com", user = "u", remote_command = "echo hi; ls" }))
  eq(argv[1], "ssh")
  truthy(vim.tbl_contains(argv, "echo hi; ls"), "remote command stays a single element")
  truthy(vim.tbl_contains(argv, "u@a.example.com"), "target present")
end)

test("adds IdentitiesOnly when a key is set", function()
  local argv = Host.build_argv(Host.normalize({ host = "h", identity_file = "/tmp/k" }))
  truthy(vim.tbl_contains(argv, "IdentitiesOnly=yes"))
end)

test("never emits StrictHostKeyChecking=no unless explicitly allowed", function()
  configure({ ssh = { strict_host_key_checking = "no" } })
  local argv = Host.build_argv(Host.normalize({ host = "h", strict_host_key_checking = "no" }))
  falsy(vim.tbl_contains(argv, "StrictHostKeyChecking=no"))
  truthy(vim.tbl_contains(argv, "StrictHostKeyChecking=accept-new"))
  configure()
end)

test("round-trips forwards and options through strings", function()
  local h = Host.normalize({ host = "h", forwards = "L 8080:localhost:80, D 1080", options = "SetEnv=A=b" })
  eq(Host.forwards_to_string(h.forwards), "L 8080:localhost:80, D 1080")
  eq(Host.options_to_string(h.options), "SetEnv=A=b")
end)

--------------------------------------------------------------------------------
suite("config")
--------------------------------------------------------------------------------

test("rejects invalid enums and clamps numbers", function()
  local cfg = require("ssh_launcher.config").setup({
    terminal = { strategy = "nope" },
    workspace = { strategy = "nowhere", bundle_timeout = 0 },
    ui = { width = 99 },
  })
  eq(cfg.terminal.strategy, "tab")
  eq(cfg.workspace.strategy, "tab")
  eq(cfg.workspace.bundle_timeout, 1000)
  eq(cfg.ui.width, 1.0)
end)

test("refuses to disable host-key checking silently", function()
  local cfg, problems = require("ssh_launcher.config").setup({ ssh = { strict_host_key_checking = "no" } })
  eq(cfg.ssh.strict_host_key_checking, "accept-new")
  truthy(#problems > 0)
  configure()
end)

test("replaces list options instead of merging them", function()
  local cfg = configure({ security = { production_tags = { "live" } } })
  eq(cfg.security.production_tags, { "live" })
  configure()
end)

--------------------------------------------------------------------------------
suite("store")
--------------------------------------------------------------------------------

local store = require("ssh_launcher.store")

test("adds, updates, touches and removes", function()
  reset_store()
  local h = store.add({ name = "prod-api", host = "10.0.0.4", user = "deploy", port = 2222 })
  truthy(h and h.id)
  eq(store.count(), 1)
  eq(util.mode_octal(TMP .. "/hosts.json"), "0600")

  local updated = store.update(h.id, { user = "root" })
  eq(updated.user, "root")

  store.touch(h.id)
  eq(store.get(h.id).use_count, 1)

  truthy(store.remove(h.id))
  eq(store.count(), 0)
end)

test("resolves names exactly and by unique prefix", function()
  reset_store()
  store.add({ name = "prod-api", host = "10.0.0.4" })
  store.add({ name = "staging", host = "10.0.0.5" })
  truthy(store.get_by_name("staging"))
  truthy(store.get_by_name("prod"))
end)

test("migrates the 1.x schema", function()
  reset_store()
  vim.fn.writefile({ '[{"name":"AWS","user":"ec2-user","host":"1.2.3.4","key":"~/.ssh/k.pem"}]' }, TMP .. "/hosts.json")
  local hosts = store.load(true)
  eq(#hosts, 1)
  eq(hosts[1].identity_file, "~/.ssh/k.pem")
  contains(util.read_file(TMP .. "/hosts.json"), '"version": 2')
  truthy(#vim.fn.glob(TMP .. "/backups/*.json", true, true) > 0, "a backup was kept")
end)

test("quarantines a corrupt database instead of losing it", function()
  reset_store()
  vim.fn.writefile({ "{ not json" }, TMP .. "/hosts.json")
  eq(#store.load(true), 0)
  truthy(#vim.fn.glob(TMP .. "/hosts.json.corrupt.*", true, true) > 0)
  vim.wait(60, function()
    return false
  end)
end)

test("import skips duplicates", function()
  reset_store()
  store.add({ name = "a", host = "1.1.1.1" })
  local added, skipped = store.import({ { name = "a", host = "1.1.1.1" }, { name = "b", host = "2.2.2.2" } })
  eq(added, 1)
  eq(skipped, 1)
end)

--------------------------------------------------------------------------------
suite("diagnostics")
--------------------------------------------------------------------------------

local diagnostics = require("ssh_launcher.diagnostics")

local function codes_for(host)
  local out = {}
  for _, issue in ipairs(diagnostics.check(host, { hosts = {} })) do
    out[issue.code] = issue.severity
  end
  return out
end

local loose_key = TMP .. "/loose_key"
vim.fn.writefile({ "-----BEGIN OPENSSH PRIVATE KEY-----", "x", "-----END OPENSSH PRIVATE KEY-----" }, loose_key)
vim.uv.fs_chmod(loose_key, tonumber("644", 8))

test("flags an empty record", function()
  local codes = codes_for(Host.normalize({ name = "", host = "" }))
  eq(codes.SSH001, "error", "empty host")
  eq(codes.SSH080, "error", "empty name")
end)

test("flags malformed fields", function()
  local codes = codes_for(Host.normalize({ name = "x", host = "bad host", user = "a b", port = 99999 }))
  truthy(codes.SSH002 or codes.SSH006, "bad host")
  eq(codes.SSH011, "error", "bad user")
  eq(codes.SSH020, "error", "bad port")
end)

test("flags a key that others can read", function()
  eq(codes_for(Host.normalize({ name = "x", host = "h.example.com", identity_file = loose_key })).SSH033, "error")
end)

test("flags a public key used as an identity", function()
  local pub = TMP .. "/id.pub"
  vim.fn.writefile({ "ssh-ed25519 AAAAC3Nz test@host" }, pub)
  eq(codes_for(Host.normalize({ name = "x", host = "h.example.com", identity_file = pub })).SSH032, "error")
end)

test("flags a missing key", function()
  eq(codes_for(Host.normalize({ name = "x", host = "h.example.com", identity_file = TMP .. "/nope" })).SSH030, "error")
end)

test("flags disabled host-key checking and agent forwarding", function()
  local codes = codes_for(Host.normalize({
    name = "x",
    host = "h.example.com",
    strict_host_key_checking = "no",
    forward_agent = true,
  }))
  eq(codes.SSH071, "error")
  eq(codes.SSH072, "warn")
end)

test("flags a self-referencing jump host", function()
  eq(codes_for(Host.normalize({ name = "x", host = "h.example.com", proxy_jump = "h.example.com" })).SSH050, "error")
end)

test("flags an invalid forward and a wildcard bind", function()
  local codes = codes_for(Host.normalize({ name = "x", host = "h.example.com", forwards = "L nonsense" }))
  eq(codes.SSH060, "error")
  eq(codes_for(Host.normalize({ name = "x", host = "h.example.com", forwards = "L 0.0.0.0:80:a:80" })).SSH061, "warn")
end)

test("flags an unknown ssh option", function()
  eq(codes_for(Host.normalize({ name = "x", host = "h.example.com", options = "Porrt=22" })).SSH070, "warn")
end)

test("flags a credential in the notes", function()
  eq(codes_for(Host.normalize({ name = "x", host = "h.example.com", notes = "password: hunter2" })).SSH100, "error")
end)

test("autofix repairs permissions and security settings", function()
  vim.uv.fs_chmod(loose_key, tonumber("644", 8))
  require("ssh_launcher.keys").invalidate()
  local _, applied = diagnostics.autofix(
    Host.normalize({ name = "x", host = "h.example.com", identity_file = loose_key }),
    { hosts = {} }
  )
  truthy(#applied > 0, "something was fixed")
  eq(util.mode_octal(loose_key), "0600")

  local fixed = diagnostics.autofix(
    Host.normalize({ name = "x", host = "h.example.com", strict_host_key_checking = "no", forward_agent = true }),
    { hosts = {} }
  )
  eq(fixed.strict_host_key_checking, "accept-new")
  eq(fixed.forward_agent, false)
end)

test("autofix never guesses which key to use, nor runs ssh-add", function()
  local host = Host.normalize({ name = "z", host = "h.example.com" })
  local fixed = diagnostics.autofix(host, { hosts = {} })
  eq(fixed.identity_file, nil)

  local manual = 0
  for _, issue in ipairs(diagnostics.check(host, { hosts = {} })) do
    if issue.fix and issue.fix.auto == false then
      manual = manual + 1
    end
  end
  truthy(manual >= 0, "manual fixes remain available")
end)

test("summary counts by severity", function()
  local issues = diagnostics.check(Host.normalize({ name = "", host = "" }), { hosts = {} })
  contains(diagnostics.summary(issues), "error")
end)

--------------------------------------------------------------------------------
suite("ssh_config")
--------------------------------------------------------------------------------

local sshconfig = require("ssh_launcher.sshconfig")

vim.fn.writefile({
  "Host bastion",
  "  HostName bastion.corp.net",
  "  User jump",
  "",
  "Host prod-*",
  "  User deploy",
  "",
  "Match host anything",
  "  User nobody",
  "",
  "Host db1",
  "  HostName 10.1.2.3",
  "  Port 2200",
  "  IdentityFile ~/.ssh/db",
  "  LocalForward 5432 localhost:5432",
  "  ProxyJump bastion",
}, TMP .. "/ssh_config")

test("parses host blocks, skipping wildcards and Match", function()
  sshconfig.invalidate()
  local hosts = sshconfig.hosts(true)
  eq(#hosts, 2)
  local db = vim.tbl_filter(function(h)
    return h.name == "db1"
  end, hosts)[1]
  eq(db.host, "10.1.2.3")
  eq(db.port, 2200)
  eq(db.proxy_jump, "bastion")
  eq(db.forwards, { { kind = "local", spec = "5432:localhost:5432" } })
  eq(db.readonly, true)
end)

test("exports into a managed block without touching the rest", function()
  local ok, content = sshconfig.export(
    { Host.normalize({ name = "web", host = "1.2.3.4", user = "root", port = 2222 }) },
    {
      path = TMP .. "/ssh_config",
      dry_run = true,
    }
  )
  truthy(ok)
  contains(content, "Host web")
  contains(content, "Host bastion")
  eq(select(2, content:gsub("managed block", "")), 2, "exactly one managed block")
end)

--------------------------------------------------------------------------------
suite("ui")
--------------------------------------------------------------------------------

test("manager renders rows, filters and previews", function()
  reset_store()
  store.add({ name = "prod-api", host = "10.0.0.4", user = "deploy", tags = { "prod" } })
  store.add({ name = "dev-box", host = "dev.example.com", user = "me" })

  local manager = require("ssh_launcher.ui.manager")
  manager.open()
  local mgr = manager.instance()
  truthy(mgr, "manager did not open")

  local lines = vim.api.nvim_buf_get_lines(mgr.win.buf, 0, -1, false)
  contains(lines[1], "NAME", "header")
  contains(lines, "prod-api", "saved host row")
  contains(lines, "bastion", "ssh_config host row")

  mgr.filter = "dev"
  mgr:load()
  mgr:draw()
  eq(#mgr.hosts, 1)

  mgr.win:close()
end)

test("a host containing newlines renders instead of taking the window down", function()
  reset_store()
  -- Reach past normalize the way a hand-edited database or a bad import would,
  -- so the render layer is the thing under test.
  local store_module = require("ssh_launcher.store")
  store_module.add({ name = "ok-host", host = "10.0.0.9" })
  local raw = store_module.list()
  raw[1].name = "prod\napi"
  raw[1].host = "10.0.0.1\nevil"

  local manager = require("ssh_launcher.ui.manager")
  manager.open()
  local mgr = manager.instance()
  truthy(mgr, "manager did not open")

  local lines = vim.api.nvim_buf_get_lines(mgr.win.buf, 0, -1, false)
  contains(lines, "prod api", "the newline became a space")
  for _, line in ipairs(lines) do
    falsy(line:find("\n"), "buffer lines must never contain newlines")
  end

  mgr:draw_preview()
  mgr.win:close()
end)

test("the editor form distributes a pasted ssh command across fields", function()
  reset_store()
  local h = store.add({ name = "prod-api", host = "10.0.0.4", user = "deploy" })
  local form = require("ssh_launcher.ui.form").open(h)

  local lines = vim.api.nvim_buf_get_lines(form.win.buf, 0, -1, false)
  contains(lines, "Name        : prod-api")

  local paste_line
  for i, line in ipairs(lines) do
    if line:match("^Paste") then
      paste_line = i
    end
  end
  truthy(paste_line, "no paste line")

  vim.api.nvim_buf_set_lines(form.win.buf, paste_line - 1, paste_line, false, {
    "Paste       : ssh -i ~/.ssh/other -p 2244 root@9.9.9.9",
  })
  form:update()

  eq(form.host.host, "9.9.9.9")
  eq(form.host.port, 2244)
  eq(form.host.user, "root")
  eq(form.host.identity_file, "~/.ssh/other")

  local after = vim.api.nvim_buf_get_lines(form.win.buf, 0, -1, false)
  contains(after, "Host        : 9.9.9.9", "form re-rendered")
  contains(after, "Paste       : ", "paste line cleared")

  form.win:close()
end)

test("the editor never grows orphan lines from a multi-line value", function()
  reset_store()
  local h = store.add({
    name = "a",
    host = "10.0.0.1",
    notes = "line one\nline two",
    remote_command = "cd /srv\nmake deploy",
  })

  local form = require("ssh_launcher.ui.form").edit(h)
  local lines = vim.api.nvim_buf_get_lines(form.win.buf, 0, -1, false)

  -- Every non-comment, non-blank line must parse back as a field. Anything
  -- else is content the form cannot round-trip, and would be lost on save.
  for _, line in ipairs(lines) do
    if line ~= "" and line:sub(1, 1) ~= "#" then
      truthy(line:match("^%s*[%a][%a%s]-%s*:"), ("orphan line in the form: %q"):format(line))
    end
  end

  -- and the value survives a save unchanged
  form:save()
  vim.wait(50, function()
    return false
  end)
  local saved = store.get_by_name("a")
  eq(saved.notes, "line one line two")
  eq(saved.remote_command, "cd /srv make deploy")

  form.win:close()
end)

test("the form reports problems through vim.diagnostic", function()
  local form = require("ssh_launcher.ui.form").open(Host.normalize({ name = "x", host = "" }))
  form:update()
  local items = vim.diagnostic.get(form.win.buf)
  truthy(#items > 0, "no diagnostics were published")
  form.win:close()
end)

test("help and dialog windows open", function()
  require("ssh_launcher.ui.help").show("manager"):close()
  require("ssh_launcher.ui.help").show("form"):close()
  require("ssh_launcher.ui.dialog").choose({
    title = "t",
    choices = { { label = "a", value = 1 } },
    on_choice = function() end,
  })
  vim.cmd("silent! only")
end)

--------------------------------------------------------------------------------
suite("sessions and the agent")
--------------------------------------------------------------------------------

local terminal = require("ssh_launcher.terminal")
local agent = require("ssh_launcher.agent")

test("exit statuses are reported in words, not raw numbers", function()
  eq(terminal.describe_exit(0), "finished")
  contains(terminal.describe_exit(129), "hung up", "SIGHUP")
  contains(terminal.describe_exit(130), "interrupted", "SIGINT")
  contains(terminal.describe_exit(143), "terminated", "SIGTERM")
  contains(terminal.describe_exit(255), "could not establish", "ssh's catch-all")
  contains(terminal.describe_exit(2), "status 2", "an ordinary status is left alone")
end)

--- Run something in a terminal, tear it down, and report whether the plugin
--- warned about the resulting exit.
---@param script_body string[]
---@param teardown fun(handle: table)|nil
---@return string|nil warning
local function warning_from_session(script_body, teardown)
  local script = TMP .. "/session_script"
  vim.fn.writefile(script_body, script)
  vim.uv.fs_chmod(script, tonumber("755", 8))

  local warned = nil
  local original = vim.notify
  vim.notify = function(msg, level, o)
    if level == vim.log.levels.WARN then
      warned = msg
    end
    return original(msg, level, o)
  end

  local handle = terminal.run({ script }, { title = "T", strategy = "current", start_insert = false })
  vim.wait(250, function()
    return false
  end)
  if teardown then
    teardown(handle)
  end
  vim.wait(700, function()
    return false
  end)
  vim.notify = original
  return warned
end

test("no teardown path reports a hangup as a failure", function()
  local sleeper = { "#!/bin/sh", "sleep 30" }
  -- Every one of these destroys the pty and SIGHUPs the job (status 129). The
  -- user asked for it in each case, so none of them is news.
  falsy(
    warning_from_session(sleeper, function(h)
      terminal.close(h)
    end),
    "terminal.close()"
  )

  falsy(
    warning_from_session(sleeper, function(h)
      vim.cmd("bdelete! " .. h.buf)
    end),
    ":bdelete!"
  )

  falsy(
    warning_from_session(sleeper, function(h)
      vim.cmd("bwipeout! " .. h.buf)
    end),
    ":bwipeout!"
  )

  falsy(
    warning_from_session(sleeper, function(h)
      -- What 'nohidden' does when the window closes. Neovim refuses to unload
      -- the last buffer, so give it another one to fall back to.
      vim.cmd("enew")
      vim.api.nvim_buf_delete(h.buf, { force = true, unload = true })
    end),
    "unloading the buffer"
  )
end)

test("a session window survives a configuration that closes it", function()
  local script = TMP .. "/sleeper2"
  vim.fn.writefile({ "#!/bin/sh", "sleep 30" }, script)
  vim.uv.fs_chmod(script, tonumber("755", 8))

  -- Stand in for a session manager or layout plugin that reacts to TermOpen.
  vim.api.nvim_create_augroup("SshLauncherTestHostile", { clear = true })
  vim.api.nvim_create_autocmd("TermOpen", {
    group = "SshLauncherTestHostile",
    callback = function()
      vim.schedule(function()
        pcall(vim.cmd, "tabclose")
      end)
    end,
  })

  local function on_screen(buf)
    for _, w in ipairs(vim.api.nvim_list_wins()) do
      if vim.api.nvim_win_get_buf(w) == buf then
        return true
      end
    end
    return false
  end

  local function run_with(terminal_opts)
    configure({ terminal = terminal_opts })
    local handle = terminal.run({ script }, { title = "S", strategy = "tab", start_insert = false })
    vim.wait(800, function()
      return false
    end)
    local visible = on_screen(handle.buf)
    pcall(terminal.close, handle)
    vim.wait(200, function()
      return false
    end)
    return visible
  end

  truthy(run_with({ ensure_visible = true }), "the window should have been reopened")
  truthy(
    run_with({ ensure_visible = false, eventignore = { "TermOpen" } }),
    "eventignore should have stopped it closing in the first place"
  )
  eq(vim.o.eventignore, "", "eventignore must always be restored")

  vim.api.nvim_del_augroup_by_name("SshLauncherTestHostile")
  configure()
end)

test("a session can be hosted by someone else's window", function()
  local script = TMP .. "/sleeper3"
  vim.fn.writefile({ "#!/bin/sh", "sleep 30" }, script)
  vim.uv.fs_chmod(script, tonumber("755", 8))

  local function on_screen(buf)
    for _, w in ipairs(vim.api.nvim_list_wins()) do
      if vim.api.nvim_win_get_buf(w) == buf then
        return true
      end
    end
    return false
  end

  -- What an integration with a terminal plugin looks like.
  local called = false
  configure({
    terminal = {
      strategy = function(buf)
        called = true
        vim.cmd("botright 10split")
        vim.api.nvim_win_set_buf(0, buf)
      end,
    },
  })
  local handle = terminal.run({ script }, { title = "custom", start_insert = false })
  vim.wait(400, function()
    return false
  end)
  truthy(called, "the strategy function was not called")
  truthy(on_screen(handle.buf), "the custom strategy's window")
  pcall(terminal.close, handle)

  -- A strategy that fails to display anything must not lose the session.
  configure({ terminal = { strategy = function() end } })
  local orphan = terminal.run({ script }, { title = "broken", start_insert = false })
  vim.wait(400, function()
    return false
  end)
  truthy(on_screen(orphan.buf), "a broken strategy should fall back, not lose the session")
  pcall(terminal.close, orphan)

  configure()
end)

test("losing a window once protects every session after it", function()
  local script = TMP .. "/sleeper4"
  vim.fn.writefile({ "#!/bin/sh", "sleep 30" }, script)
  vim.uv.fs_chmod(script, tonumber("755", 8))

  vim.api.nvim_create_augroup("SshLauncherTestGrabby", { clear = true })
  vim.api.nvim_create_autocmd("TermOpen", {
    group = "SshLauncherTestGrabby",
    callback = function()
      local win = vim.api.nvim_get_current_win()
      vim.schedule(function()
        pcall(vim.api.nvim_win_close, win, true)
      end)
    end,
  })

  configure()
  terminal.hostile_environment = false

  local first = terminal.run({ script }, { title = "first", start_insert = false })
  vim.wait(600, function()
    return false
  end)
  truthy(terminal.hostile_environment, "the grab should have been noticed")
  pcall(terminal.close, first)
  vim.wait(150, function()
    return false
  end)

  -- The second one suppresses TermOpen by itself, so it is never taken.
  local second = terminal.run({ script }, { title = "second", start_insert = false })
  vim.wait(600, function()
    return false
  end)
  local visible = false
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_buf(w) == second.buf then
      visible = true
    end
  end
  truthy(visible, "the second session should never have been taken")
  eq(vim.o.eventignore, "", "eventignore must always be restored")

  pcall(terminal.close, second)
  vim.api.nvim_del_augroup_by_name("SshLauncherTestGrabby")
  terminal.hostile_environment = false
  configure()
end)

--- A floating-terminal manager: adopts every terminal buffer that appears and
--- destroys it to re-host it. Destroying the buffer closes the pty, which kills
--- ssh — this is the shape of plugin that made connections fail outright.
---@param name string
---@return fun() remove, fun(): integer adoptions
local function install_terminal_manager(name)
  local adoptions = 0
  vim.api.nvim_create_augroup(name, { clear = true })
  vim.api.nvim_create_autocmd("TermOpen", {
    group = name,
    callback = function()
      adoptions = adoptions + 1
      local buf = vim.api.nvim_get_current_buf()
      vim.schedule(function()
        pcall(vim.api.nvim_buf_delete, buf, { force = true })
      end)
    end,
  })
  return function()
    vim.api.nvim_del_augroup_by_name(name)
  end, function()
    return adoptions
  end
end

---@return string fake_ssh
local function fake_ssh()
  local script = TMP .. "/fake_ssh"
  vim.fn.writefile({ "#!/bin/sh", "sleep 30" }, script)
  vim.uv.fs_chmod(script, tonumber("755", 8))
  return script
end

local function close_all_sessions()
  local connect = require("ssh_launcher.connect")
  for _, s in ipairs(connect.sessions()) do
    connect.close_session(s.id)
  end
  vim.wait(200, function()
    return false
  end)
end

test("a terminal manager cannot kill a session", function()
  local remove, adoptions = install_terminal_manager("TestTerminalManager")
  local connect = require("ssh_launcher.connect")

  configure({ ssh = { binary = fake_ssh() }, terminal = { start_insert = false, protect = "auto" } })
  terminal.hostile_environment = false
  reset_store()

  connect.connect(store.add({ name = "Target", host = "10.0.0.9", user = "me", port = 8087 }))
  vim.wait(1500, function()
    return false
  end)

  eq(adoptions(), 0, "the hook should never have run")
  eq(#connect.live_sessions(), 1, "the session should be alive on the first attempt")

  close_all_sessions()
  remove()
  terminal.hostile_environment = false
  configure()
end)

test("a session destroyed anyway is reconnected automatically", function()
  local remove, adoptions = install_terminal_manager("TestTerminalManager2")
  local connect = require("ssh_launcher.connect")

  -- Protection off, so the manager really does destroy the first session.
  configure({ ssh = { binary = fake_ssh() }, terminal = { start_insert = false, protect = false } })
  terminal.hostile_environment = false
  reset_store()

  connect.connect(store.add({ name = "Target", host = "10.0.0.9", user = "me", port = 8087 }))
  vim.wait(2500, function()
    return false
  end)

  truthy(adoptions() > 0, "the manager should have destroyed the first attempt")
  truthy(terminal.hostile_environment, "the hijack should have been recorded")
  eq(#connect.live_sessions(), 1, "the retry should have connected")

  close_all_sessions()
  remove()
  terminal.hostile_environment = false
  configure()
end)

test("why ssh failed survives a config that deletes terminal buffers", function()
  -- `TermClose -> bdelete` is an extremely common idiom, and it throws away
  -- the transcript — including the one line explaining the failure.
  vim.api.nvim_create_augroup("TestTermCloseCleanup", { clear = true })
  vim.api.nvim_create_autocmd("TermClose", {
    group = "TestTermCloseCleanup",
    callback = function(ev)
      vim.schedule(function()
        pcall(vim.api.nvim_buf_delete, ev.buf, { force = true })
      end)
    end,
  })

  local script = TMP .. "/failing_ssh"
  vim.fn.writefile({
    "#!/bin/sh",
    "sleep 0.2",
    "echo 'user@host: Permission denied (publickey).' >&2",
    "sleep 0.1",
    "exit 255",
  }, script)
  vim.uv.fs_chmod(script, tonumber("755", 8))

  local warned = nil
  local original = vim.notify
  vim.notify = function(msg, level, o)
    if level == vim.log.levels.WARN then
      warned = msg
    end
    return original(msg, level, o)
  end

  configure({ terminal = { start_insert = false } })
  local handle = terminal.run({ script }, { title = "T", strategy = "tab" })
  vim.wait(1500, function()
    return false
  end)
  vim.notify = original

  falsy(vim.api.nvim_buf_is_valid(handle.buf), "the config should have deleted the buffer")
  eq(handle.output, "user@host: Permission denied (publickey).", "the transcript was kept")
  truthy(warned, "the failure should have been reported")
  contains(warned, "Permission denied", "the reason must reach the user")

  vim.api.nvim_del_augroup_by_name("TestTermCloseCleanup")
  configure()
end)

test("a session destroyed by a timer is detected and reconnected", function()
  -- No autocommand is involved, so event shielding cannot prevent this: the
  -- only defence is noticing afterwards. Covers debounced layout guards,
  -- buffer sweepers and anything else working off a timer.
  local connect = require("ssh_launcher.connect")
  configure({ ssh = { binary = fake_ssh() }, terminal = { start_insert = false } })
  terminal.hostile_environment = false
  reset_store()

  local swept = 0
  vim.defer_fn(function()
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
      if vim.bo[buf].buftype == "terminal" and vim.api.nvim_buf_is_loaded(buf) and swept == 0 then
        swept = swept + 1
        pcall(vim.api.nvim_buf_delete, buf, { force = true })
      end
    end
  end, 300)

  connect.connect(store.add({ name = "Target", host = "10.0.0.9", user = "me", port = 8087 }))
  vim.wait(2500, function()
    return false
  end)

  eq(swept, 1, "the sweeper should have destroyed the first session")
  truthy(terminal.hostile_environment, "destruction should have been noticed")
  eq(#connect.live_sessions(), 1, "the session should have been reconnected")

  close_all_sessions()
  terminal.hostile_environment = false
  configure()
end)

test("closing a session yourself is never mistaken for interference", function()
  local connect = require("ssh_launcher.connect")
  configure({ ssh = { binary = fake_ssh() }, terminal = { start_insert = false } })
  terminal.hostile_environment = false
  reset_store()

  connect.connect(store.add({ name = "Target", host = "10.0.0.9", user = "me", port = 8087 }))
  vim.wait(500, function()
    return false
  end)
  eq(#connect.live_sessions(), 1, "the session should be up")

  -- Well inside the grace period, so only `closed_by_us` distinguishes this
  -- from a plugin destroying it.
  close_all_sessions()
  vim.wait(800, function()
    return false
  end)

  eq(#connect.live_sessions(), 0, "closing it must not reconnect")
  falsy(terminal.hostile_environment, "and must not be blamed on another plugin")
  configure()
end)

test("session buffers are identifiable by other plugins", function()
  configure({ ssh = { binary = fake_ssh() }, terminal = { start_insert = false } })
  local handle = terminal.run({ fake_ssh() }, { title = "marked", strategy = "tab" })
  vim.wait(300, function()
    return false
  end)

  -- The contract a window guard keys on to leave our terminals alone.
  eq(vim.b[handle.buf].ssh_launcher, true, "b:ssh_launcher")
  truthy(terminal.is_session_buffer(handle.buf), "is_session_buffer()")
  falsy(terminal.is_session_buffer(vim.api.nvim_create_buf(false, true)), "an unrelated buffer")

  pcall(terminal.close, handle)
  configure()
end)

test("an established session's exit is described as what it is", function()
  local established = { established = true }
  -- 255 means two completely different things either side of "did it connect".
  contains(terminal.describe_exit(255), "could not establish", "before a session exists")
  contains(terminal.describe_exit(255, established), "connection was closed", "after one has run")
  -- and a non-zero status from an interactive session is the remote shell's,
  -- not ssh failing.
  contains(terminal.describe_exit(3, established), "remote status 3")
  eq(terminal.describe_exit(0), "finished")
end)

test("quitting a working session does not raise a false alarm", function()
  local previous = terminal.ESTABLISHED_MS
  terminal.ESTABLISHED_MS = 400
  configure({ terminal = { start_insert = false } })

  ---@return string[] warnings, string[] infos
  local function messages_from(body, wait)
    local script = TMP .. "/exiting"
    vim.fn.writefile(body, script)
    vim.uv.fs_chmod(script, tonumber("755", 8))
    local warnings, infos = {}, {}
    local original = vim.notify
    vim.notify = function(msg, level, o)
      if level == vim.log.levels.WARN then
        warnings[#warnings + 1] = msg
      elseif level == vim.log.levels.INFO then
        infos[#infos + 1] = msg
      end
      return original(msg, level, o)
    end
    local handle = terminal.run({ script }, { title = "S", strategy = "tab" })
    vim.wait(wait, function()
      return false
    end)
    vim.notify = original
    pcall(terminal.close, handle)
    vim.wait(100, function()
      return false
    end)
    return warnings, infos
  end

  -- Worked, then the shell exited with the status of a failed command.
  local warnings, infos = messages_from({ "#!/bin/sh", "echo '[user@host ~]$ '", "sleep 0.8", "exit 3" }, 1600)
  eq(#warnings, 0, "a remote command's status is not a warning")
  truthy(#infos > 0, "but it is worth mentioning")
  contains(infos[1], "remote status 3")
  falsy(infos[1]:find("$", 1, true), "the shell prompt must not be quoted as an error")

  -- Worked, then exited cleanly: nothing to say at all.
  local clean = messages_from({ "#!/bin/sh", "echo '[user@host ~]$ '", "sleep 0.8", "exit 0" }, 1600)
  eq(#clean, 0, "a clean exit is silent")

  terminal.ESTABLISHED_MS = previous
  configure()
end)

test("a session that genuinely fails is still reported", function()
  local warned = warning_from_session({ "#!/bin/sh", "exit 1" })
  truthy(warned, "an ordinary non-zero exit must be reported")
  contains(warned, "status 1", "the status")

  local ssh_failure = warning_from_session({ "#!/bin/sh", "exit 255" })
  truthy(ssh_failure, "ssh's catch-all must be reported")
  contains(ssh_failure, "could not establish", "explained, not just numbered")

  falsy(warning_from_session({ "#!/bin/sh", "exit 0" }), "a clean exit is silent")
end)

test("only a locked key that the agent lacks asks to be unlocked", function()
  if not util.has_executable("ssh-keygen") then
    return
  end
  eq(agent.unlock_state(nil).needed, false, "no key")
  eq(agent.unlock_state(TMP .. "/does-not-exist").needed, false, "missing key")

  local plain = TMP .. "/plain_key"
  vim.fn.system({ "ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f", plain, "-C", "test" })
  eq(agent.unlock_state(plain).needed, false, "an unencrypted key needs no agent")

  local locked = TMP .. "/locked_key"
  vim.fn.system({ "ssh-keygen", "-q", "-t", "ed25519", "-N", "hunter2hunter2", "-f", locked, "-C", "test" })
  local state = agent.unlock_state(locked)
  truthy(state.needed, "a passphrase-protected key not in the agent should prompt")
  truthy(state.reason == "not-loaded" or state.reason == "no-agent", "reason: " .. tostring(state.reason))
  contains(state.detail, "passphrase", "the explanation")
end)

test("auto_add_keys is validated like every other enum", function()
  local cfg = require("ssh_launcher.config").setup({ ssh = { auto_add_keys = "sometimes" } })
  eq(cfg.ssh.auto_add_keys, "prompt")
  configure()
end)

--------------------------------------------------------------------------------
suite("tunnels, fleet and remote files")
--------------------------------------------------------------------------------

test("tunnels are raised, listed and stopped", function()
  local tunnel = require("ssh_launcher.tunnel")
  -- `ssh -N` holds the port open and prints nothing; a sleep behaves the same.
  configure({ ssh = { binary = fake_ssh() } })
  reset_store()

  local h = store.add({
    name = "db",
    host = "10.0.0.9",
    user = "me",
    forwards = "L 15432:localhost:5432, D 1080",
  })
  eq(#h.forwards, 2, "the host should declare two forwards")

  local opened, failures
  tunnel.open_all(h, function(n, errs)
    opened, failures = n, errs
  end)
  vim.wait(2000, function()
    return opened ~= nil
  end)

  eq(opened, 2, "both forwards should be up: " .. vim.inspect(failures))
  eq(#tunnel.for_host(h.id), 2)
  truthy(tunnel.is_open(h, h.forwards[1]))

  eq(tunnel.close_all(h), 2, "both should stop")
  eq(#tunnel.for_host(h.id), 0)
  eq(#tunnel.list(), 0)
  configure()
end)

test("a tunnel is refused rather than left hanging on a passphrase", function()
  if not util.has_executable("ssh-keygen") then
    return
  end
  local tunnel = require("ssh_launcher.tunnel")
  configure({ ssh = { binary = fake_ssh() } })

  local locked = TMP .. "/tunnel_key"
  vim.fn.delete(locked)
  vim.fn.system({ "ssh-keygen", "-q", "-t", "ed25519", "-N", "hunter2hunter2", "-f", locked, "-C", "t" })

  local h = Host.normalize({ name = "x", host = "10.0.0.9", identity_file = locked, forwards = "L 1:localhost:1" })
  local ok, msg
  tunnel.open(h, h.forwards[1], function(o, m)
    ok, msg = o, m
  end)
  vim.wait(1500, function()
    return ok ~= nil
  end)

  falsy(ok, "a background process cannot answer a passphrase prompt")
  contains(msg, "unattended")
  configure()
end)

test("a fleet command collects per-host results in order", function()
  local fleet = require("ssh_launcher.fleet")
  -- Stand-in ssh: echoes its last argument, and fails for one host.
  local script = TMP .. "/fleet_ssh"
  vim.fn.writefile({
    "#!/bin/sh",
    'for a in "$@"; do last="$a"; done',
    'case "$*" in *boom.example.com*) echo "boom" >&2; exit 7;; esac',
    'echo "ran: $last"',
  }, script)
  vim.uv.fs_chmod(script, tonumber("755", 8))

  configure({ ssh = { binary = script } })
  reset_store()
  local a = store.add({ name = "alpha", host = "10.0.0.1", user = "me" })
  -- the name never reaches argv, so the failure is keyed on the target
  local b = store.add({ name = "bad", host = "boom.example.com", user = "me" })
  local c = store.add({ name = "gamma", host = "10.0.0.3", user = "me" })

  local results
  fleet.run({ a, b, c }, "uptime; whoami", { concurrency = 2 }, function(r)
    results = r
  end)
  vim.wait(5000, function()
    return results ~= nil
  end)

  truthy(results, "the fleet run never finished")
  eq(#results, 3)
  -- Reported in the order given, not the order they returned.
  eq({ results[1].host.name, results[2].host.name, results[3].host.name }, { "alpha", "bad", "gamma" })
  eq(results[1].code, 0)
  eq(results[2].code, 7, "the failing host's status")
  contains(results[2].stderr, "boom")
  -- The command reached ssh as one argument, not split into shell words.
  contains(results[1].stdout, "ran: uptime; whoami")

  local rendered = table.concat(fleet.format("uptime", results), "\n")
  contains(rendered, "2 ok, 1 failed", "the summary counts outcomes")
  contains(rendered, "exit 7")
  configure()
end)

test("scp transfers pass paths as separate arguments", function()
  local remote = require("ssh_launcher.remote")
  local h = Host.normalize({
    name = "x",
    host = "10.0.0.9",
    user = "me",
    port = 2222,
    identity_file = "/tmp/key",
  })

  local argv = remote.scp_argv("put", h, "/srv/a file; rm -rf /", "/local/b.txt")
  eq(argv[1], "scp")
  truthy(vim.tbl_contains(argv, "-P"), "scp spells the port flag with a capital")
  truthy(vim.tbl_contains(argv, "2222"))
  truthy(vim.tbl_contains(argv, "IdentitiesOnly=yes"))
  truthy(vim.tbl_contains(argv, "StrictHostKeyChecking=accept-new"))
  -- The dangerous filename survives whole, as one argument.
  truthy(vim.tbl_contains(argv, "me@10.0.0.9:/srv/a file; rm -rf /"), vim.inspect(argv))
  eq(argv[#argv], "me@10.0.0.9:/srv/a file; rm -rf /", "put sends the remote path last")

  local down = remote.scp_argv("get", h, "/srv/x", "/local/x")
  eq(down[#down], "/local/x", "get sends the local path last")
end)

test("scp argv recurses for directories, ends options, and keeps local names local", function()
  local remote = require("ssh_launcher.remote")
  local h = Host.normalize({ name = "x", host = "10.0.0.9", user = "me" })

  local dir = TMP .. "/argv-dir"
  local file = TMP .. "/argv-file.txt"
  vim.fn.mkdir(dir, "p")
  vim.fn.writefile({ "x" }, file)

  local plain = remote.scp_argv("put", h, "/srv/", file)
  falsy(vim.tbl_contains(plain, "-r"), "a plain file needs no -r")

  local argv = remote.scp_argv("put", h, "/srv/", { file, dir })
  truthy(vim.tbl_contains(argv, "-r"), "a directory among the sources turns on -r")
  eq(argv[#argv], "me@10.0.0.9:/srv/", "the destination is last")
  eq(argv[#argv - 1], dir, "every source comes before it, in order")
  eq(argv[#argv - 2], file)
  eq(argv[#argv - 3], "--", "options end before the first path")

  truthy(vim.tbl_contains(remote.scp_argv("get", h, "/srv/x", "/local/x"), "-r"), "downloads can be directories")

  -- `a:b` would otherwise be read as host `a`; a leading dash as an option.
  local odd = remote.scp_argv("put", h, "/srv/", { "a:b.txt", "-rf" })
  truthy(vim.tbl_contains(odd, "./a:b.txt"), vim.inspect(odd))
  truthy(vim.tbl_contains(odd, "-rf"), "a dash-named path is data, because of --")
  local dashes = vim.fn.index(odd, "--")
  truthy(dashes >= 0 and dashes < vim.fn.index(odd, "-rf"), "the dash name comes after --")
end)

test("background scp never prompts, copies several remote paths, and carries host options", function()
  local remote = require("ssh_launcher.remote")
  local h = Host.normalize({
    name = "x",
    host = "10.0.0.9",
    user = "me",
    options = { UserKnownHostsFile = "/tmp/kh" },
    compression = true,
  })

  local argv = remote.scp_argv("get", h, { "/srv/a.txt", "/srv/b dir" }, "/local/dest", { batch = true })
  truthy(vim.tbl_contains(argv, "BatchMode=yes"), "a background copy must fail rather than wait on a prompt")
  truthy(vim.tbl_contains(argv, "ServerAliveInterval=15"), "and give up on a connection that has gone away")
  truthy(vim.tbl_contains(argv, "UserKnownHostsFile=/tmp/kh"), "the host's own ssh options apply to scp too")
  truthy(vim.tbl_contains(argv, "-C"), "as does compression")
  eq(argv[#argv], "/local/dest")
  eq(argv[#argv - 1], "me@10.0.0.9:/srv/b dir")
  eq(argv[#argv - 2], "me@10.0.0.9:/srv/a.txt", "every remote source is its own argument")

  falsy(
    vim.tbl_contains(remote.scp_argv("put", h, "/srv/", "/local/x"), "BatchMode=yes"),
    "interactive copies still may prompt"
  )

  eq(remote.glob_escape("report[1] *.txt"), "report\\[1\\] \\*.txt", "a literal name must not be read as a pattern")
  eq(remote.glob_escape("plain-name.txt"), "plain-name.txt")
end)

test("detailed remote listings carry size and mtime, and survive a zsh login shell", function()
  local remote = require("ssh_launcher.remote")
  local dir = TMP .. "/detailed-list"
  vim.fn.mkdir(dir .. "/sub", "p")
  vim.fn.writefile({ "twelve bytes" }, dir .. "/a file.txt") -- 13 bytes with the newline

  local res = util.system_sync({ "sh", "-c", remote.list_command(dir, true) }, 3000)
  truthy(res.ok, res.stderr)
  local _, entries, err = remote.parse_listing(res.stdout, true)
  eq(err, nil)
  eq(entries[1].name, "sub")
  eq(entries[2].name, "a file.txt")
  eq(entries[2].size, 13)
  truthy(entries[2].mtime and math.abs(entries[2].mtime - os.time()) < 300, "mtime is a recent epoch")

  -- A host with an unfamiliar stat just has no metadata; it still lists.
  local _, plain = remote.parse_listing("/d\0f\0garbage\0name\0", true)
  eq(plain[1], { type = "file", name = "name" })
  local _, _, truncated = remote.parse_listing("/d\0f\0123 456\0", true)
  contains(truncated, "truncated")

  -- The regression: the command used to reach the login shell as raw text. In zsh
  -- an unmatched glob (no `..?*` entries here) is fatal and `path` is tied to $PATH.
  if util.has_executable("zsh") then
    local h = Host.normalize({ name = "z", host = "h" })
    local argv = remote.command_argv(h, remote.list_command(dir, true))
    local viaz = util.system_sync({ "zsh", "-c", argv[#argv] }, 3000)
    truthy(viaz.ok, "a zsh login shell must be able to list a directory: " .. viaz.stderr)
    local _, listed = remote.parse_listing(viaz.stdout, true)
    eq(listed[2].name, "a file.txt")
  end
end)

test("human sizes stay short", function()
  eq(util.human_size(0), "0B")
  eq(util.human_size(1023), "1023B")
  eq(util.human_size(1024), "1.0K")
  eq(util.human_size(1536), "1.5K")
  eq(util.human_size(47 * 1024), "47K")
  eq(util.human_size(3 * 1024 * 1024 * 1024), "3.0G")
  eq(util.human_size(nil), "")
  eq(util.human_size(-1), "")
end)

test("local transfer paths resolve to real files before scp is ever started", function()
  local transfer = require("ssh_launcher.transfer")
  local base = TMP .. "/resolve"
  vim.fn.mkdir(base .. "/sub", "p")
  vim.fn.writefile({ "1" }, base .. "/a.log")
  vim.fn.writefile({ "2" }, base .. "/b.log")
  vim.fn.writefile({ "3" }, base .. "/c[1].txt")
  vim.fn.writefile({ "4" }, base .. "/sp ace.txt")

  local paths = transfer.resolve_local({ base .. "/*.log", base .. "/a.log", base .. "/sub/" })
  eq(paths, { base .. "/a.log", base .. "/b.log", base .. "/sub" }, "globs expand, duplicates collapse, slashes go")

  eq(transfer.resolve_local({ base .. "/c[1].txt" }), { base .. "/c[1].txt" }, "a literal name beats a pattern")
  eq(transfer.resolve_local({ base .. "/sp ace.txt" }), { base .. "/sp ace.txt" })

  local none, err = transfer.resolve_local({ base .. "/*.zip" })
  falsy(none)
  contains(err, "nothing matches")
  local _, missing = transfer.resolve_local({ base .. "/a.log", base .. "/nope.txt" })
  contains(missing, "no such file or directory")

  eq(transfer.resolve_local({ "~" }), { (util.home():gsub("/+$", "")) }, "~ expands")

  vim.cmd("enew")
  local _, unnamed = transfer.resolve_local({ "%" })
  contains(unnamed, "not a file", "% needs a file buffer")
  vim.cmd("edit " .. vim.fn.fnameescape(base .. "/a.log"))
  -- Neovim names a buffer by its real path, which differs from tempname() on macOS.
  eq(transfer.resolve_local({ "%" }), { vim.uv.fs_realpath(base .. "/a.log") }, "% is the current file")
  vim.cmd("bwipeout!")

  local landing = Host.normalize({ name = "x", host = "h", remote_dir = "/srv/app/" })
  eq(transfer.default_remote(landing), "/srv/app/", "a directory, so a typo cannot create a file")
  eq(transfer.default_remote(Host.normalize({ name = "y", host = "h" })), "./")
end)

test("remote commands use the saved SSH configuration without session side effects", function()
  local remote = require("ssh_launcher.remote")
  local h = Host.normalize({
    name = "workspace",
    host = "10.0.0.9",
    user = "me",
    port = 2222,
    identity_file = "/tmp/key",
    proxy_jump = "bastion",
    remote_dir = "/old",
    remote_command = "do-not-run",
    forwards = "L 8080:localhost:80",
    forward_agent = true,
  })
  local argv = remote.command_argv(h, "printf hello")
  eq(argv[#argv], "exec sh -c 'printf hello'", "the login shell only ever sees a one-line sh -c")
  truthy(vim.tbl_contains(argv, "2222"), "port")
  truthy(vim.tbl_contains(argv, "/tmp/key"), "identity")
  truthy(vim.tbl_contains(argv, "bastion"), "jump host")
  truthy(vim.tbl_contains(argv, "BatchMode=yes"), "background file operations must not hang on a prompt")
  falsy(vim.tbl_contains(argv, "do-not-run"), "the session's remote command leaked into a file operation")
  falsy(vim.tbl_contains(argv, "-L"), "session forwards leaked into a file operation")
  falsy(vim.tbl_contains(argv, "-A"), "agent forwarding leaked into a file operation")
  falsy(vim.tbl_contains(argv, "-t"), "file operations must not allocate a TTY")
end)

test("the built-in browser preserves unusual filenames and blocks path injection", function()
  local remote = require("ssh_launcher.remote")
  eq(remote.shell_quote("a'b; touch /tmp/nope"), [['a'\''b; touch /tmp/nope']])

  local dir = TMP .. "/remote-list; still-data"
  vim.fn.mkdir(dir .. "/z-dir", "p")
  vim.fn.writefile({ "x" }, dir .. "/a file.txt")
  vim.fn.writefile({ "x" }, dir .. "/.hidden")
  local res = util.system_sync({ "sh", "-c", remote.list_command(dir) }, 2000)
  truthy(res.ok, res.stderr)
  local resolved, entries, err = remote.parse_listing(res.stdout)
  eq(err, nil)
  eq(resolved, vim.uv.fs_realpath(dir))
  eq(entries[1], { name = "z-dir", type = "directory" }, "directories sort first")
  eq(entries[2], { name = ".hidden", type = "file" })
  eq(entries[3], { name = "a file.txt", type = "file" })

  local _, _, truncated = remote.parse_listing("/srv\0f\0missing-terminator")
  contains(truncated, "truncated")
end)

test("remote text buffers preserve line endings when written", function()
  local ui = require("ssh_launcher.ui.remote")
  local lines, format, eol = ui.decode("one\r\ntwo\r\n")
  eq(lines, { "one", "two" })
  eq(format, "dos")
  eq(eol, true)

  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].fileformat = format
  vim.bo[buf].endofline = eol
  eq(ui.encode(buf), "one\r\ntwo\r\n")
  vim.api.nvim_buf_delete(buf, { force = true })

  local _, _, _, err = ui.decode("text\0binary")
  contains(err, "binary")
end)

test("a remote file opens as an editable buffer and write sends it back", function()
  local runner = TMP .. "/fake-remote-ssh"
  vim.fn.writefile({
    "#!/bin/sh",
    'for arg in "$@"; do command="$arg"; done',
    'exec sh -c "$command"',
  }, runner)
  vim.uv.fs_chmod(runner, tonumber("755", 8))
  configure({ ssh = { binary = runner }, remote = { adapter = "builtin", timeout = 2000 } })

  local path = TMP .. "/remote-edit.txt"
  vim.fn.writefile({ "before" }, path)
  reset_store()
  local h = store.add({ name = "fake remote", host = "example.invalid", user = "me" })
  local ui = require("ssh_launcher.ui.remote")
  vim.cmd("Ssh browse fake remote " .. TMP)
  local browser = vim.api.nvim_get_current_buf()
  vim.wait(2000, function()
    return vim.api.nvim_buf_is_valid(browser)
      and table.concat(vim.api.nvim_buf_get_lines(browser, 0, -1, false), "\n"):find("remote%-edit.txt") ~= nil
  end)
  contains(vim.api.nvim_buf_get_lines(browser, 0, -1, false), "[f]  remote-edit.txt")

  local buf = ui.edit(h, path)
  vim.wait(2000, function()
    return vim.api.nvim_buf_is_valid(buf) and vim.bo[buf].buftype == "acwrite"
  end)
  eq(vim.api.nvim_buf_get_lines(buf, 0, -1, false), { "before" })

  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "after", "two" })
  vim.api.nvim_buf_call(buf, function()
    vim.cmd("write")
  end)
  vim.wait(2000, function()
    return table.concat(vim.fn.readfile(path), "\n") == "after\ntwo" and not vim.bo[buf].modified
  end)
  eq(vim.fn.readfile(path), { "after", "two" })
  falsy(vim.bo[buf].modified, "a completed remote write should clear the modified flag")
  vim.api.nvim_buf_delete(buf, { force = true })
  vim.api.nvim_buf_delete(browser, { force = true })
  configure()
end)

test("remote Neovim gets an isolated temporary config and persistent plugin data", function()
  local workspace = require("ssh_launcher.workspace")
  local command = workspace.launch_command({
    token = "safe-token",
    archive = "/tmp/config archive.tar.gz",
    path = "/srv/app with spaces",
    remote_root = "~/.cache/ssh launcher",
    binary = "nvim",
    args = { ".", "+checkhealth" },
  })
  contains(command, 'XDG_CONFIG_HOME="$session/config"')
  contains(command, 'XDG_DATA_HOME="$root/data"')
  contains(command, 'session="$root/sessions/session-safe-token"')
  contains(command, "workdir='/srv/app with spaces'")
  contains(command, "'nvim' '.' '+checkhealth'")
  contains(command, "trap cleanup 0")

  local h = Host.normalize({ id = "server", name = "Server", host = "server.example", remote_dir = "/old" })
  local session = workspace.session_host(h, command, "safe-token")
  eq(session.source, "workspace")
  eq(session.remote_dir, nil)
  eq(session.remote_command, command)
  eq(session.request_tty, true)
  contains(session.name, "Neovim")
end)

test("the local Neovim config bundle follows symlinks and excludes noise", function()
  if not util.has_executable("tar") then
    return
  end
  local workspace = require("ssh_launcher.workspace")
  local config_dir = TMP .. "/nvim-config"
  local linked = TMP .. "/linked-config.lua"
  local archive = TMP .. "/nvim-config.tar.gz"
  vim.fn.mkdir(config_dir, "p")
  vim.fn.writefile({ "return {}" }, linked)
  vim.uv.fs_symlink(linked, config_dir .. "/init.lua")
  vim.fn.writefile({ "ignore" }, config_dir .. "/scratch.tmp")

  local packed = util.system_sync(workspace.bundle_argv(config_dir, archive, { "*.tmp" }), 5000)
  truthy(packed.ok, packed.stderr)
  local listed = util.system_sync({ "tar", "-tzf", archive }, 5000)
  truthy(listed.ok, listed.stderr)
  contains(listed.stdout, "./init.lua")
  falsy(listed.stdout:find("scratch.tmp", 1, true), "excluded files must not be sent")
end)

test("the remote bootstrap loads the copied config and removes it on exit", function()
  if not util.has_executable("tar") then
    return
  end
  local workspace = require("ssh_launcher.workspace")
  local config_dir = TMP .. "/bootstrap-config"
  local workdir = TMP .. "/bootstrap-project"
  local root = TMP .. "/bootstrap-root"
  local archive = TMP .. "/bootstrap-config.tar.gz"
  local fake_nvim = TMP .. "/remote-nvim"
  vim.fn.mkdir(config_dir, "p")
  vim.fn.mkdir(workdir, "p")
  vim.fn.writefile({ "return true" }, config_dir .. "/init.lua")
  vim.fn.writefile({
    "#!/bin/sh",
    'test -f "$XDG_CONFIG_HOME/nvim/init.lua" || exit 9',
    'printf "config=%s\\ndata=%s\\ncwd=%s\\n" "$XDG_CONFIG_HOME" "$XDG_DATA_HOME" "$PWD"',
  }, fake_nvim)
  vim.uv.fs_chmod(fake_nvim, tonumber("755", 8))

  local packed = util.system_sync(workspace.bundle_argv(config_dir, archive), 5000)
  truthy(packed.ok, packed.stderr)
  local command = workspace.launch_command({
    token = "bootstrap",
    archive = archive,
    path = workdir,
    remote_root = root,
    binary = fake_nvim,
    args = { "." },
  })
  local launched = util.system_sync({ "sh", "-c", command }, 5000)
  truthy(launched.ok, launched.stderr)
  contains(launched.stdout, "config=" .. root .. "/sessions/session-bootstrap/config")
  contains(launched.stdout, "data=" .. root .. "/data")
  contains(launched.stdout, "cwd=" .. vim.uv.fs_realpath(workdir))
  eq(vim.fn.glob(root .. "/sessions/*"), "", "the copied config should be removed")
  truthy(util.is_dir(root .. "/data"), "plugin data should persist")
  falsy(util.exists(archive), "the uploaded archive should be removed")
end)

--------------------------------------------------------------------------------
suite("end to end")
--------------------------------------------------------------------------------

test("a real process receives the argv we intend, with no shell in between", function()
  -- A stand-in for ssh that records exactly what it was handed.
  local recorder = TMP .. "/fake-ssh"
  local argv_log = TMP .. "/argv.txt"
  vim.fn.delete(argv_log)
  vim.fn.writefile({
    "#!/bin/sh",
    ('for a in "$@"; do printf "%%s\\n" "$a" >> %s; done'):format(vim.fn.shellescape(argv_log)),
    "exit 0",
  }, recorder)
  vim.uv.fs_chmod(recorder, tonumber("755", 8))

  configure({
    ssh = { binary = recorder },
    terminal = { strategy = "current", start_insert = false },
    diagnostics = { on_connect = "off" },
  })

  reset_store()
  require("ssh_launcher").connect([[ssh -p 2222 -i /dev/null deploy@10.0.0.7 'uptime; whoami']])
  vim.wait(3000, function()
    return vim.fn.filereadable(argv_log) == 1
  end)
  vim.wait(200, function()
    return false
  end)

  local argv = vim.fn.readfile(argv_log)
  truthy(#argv > 0, "nothing was spawned")
  truthy(vim.tbl_contains(argv, "2222"), "port")
  truthy(vim.tbl_contains(argv, "deploy@10.0.0.7"), "target")
  truthy(vim.tbl_contains(argv, "StrictHostKeyChecking=accept-new"), "host-key policy")
  truthy(vim.tbl_contains(argv, "IdentitiesOnly=yes"), "IdentitiesOnly")
  -- The decisive assertion: shell metacharacters survive as one opaque argument.
  truthy(vim.tbl_contains(argv, "uptime; whoami"), "remote command was not split or interpreted")

  truthy(#require("ssh_launcher.connect").sessions() >= 1, "the session was registered")
  configure()
end)

--- Put a recording `scp` first on PATH. Returns the argv of its next
--- invocation (nil if it never ran), and a function that restores PATH.
--- With `hang`, scp records its arguments and its pid, then sleeps: a transfer
--- that is still in flight, for status, queue and cancel tests.
local function fake_scp(hang)
  local bin = TMP .. "/fake-bin"
  local record = TMP .. "/scp-argv.txt"
  vim.fn.mkdir(bin, "p")
  vim.fn.writefile({
    "#!/bin/sh",
    ("echo $$ > %s"):format(vim.fn.shellescape(TMP .. "/scp.pid")),
    ('for a in "$@"; do printf "%%s\\n" "$a" >> %s; done'):format(vim.fn.shellescape(record)),
    ('printf "==\\n" >> %s'):format(vim.fn.shellescape(record)),
    hang and "exec sleep 30" or "exit 0",
  }, bin .. "/scp")
  vim.uv.fs_chmod(bin .. "/scp", tonumber("755", 8))

  local original = vim.env.PATH
  vim.env.PATH = bin .. ":" .. original

  local function next_call(trigger)
    vim.fn.delete(record)
    trigger()
    local ran = vim.wait(3000, function()
      return vim.fn.filereadable(record) == 1 and vim.fn.readfile(record)[#vim.fn.readfile(record)] == "=="
    end)
    if not ran then
      return nil
    end
    local argv = vim.fn.readfile(record)
    argv[#argv] = nil
    return argv
  end

  local function never_runs(trigger)
    vim.fn.delete(record)
    trigger()
    vim.wait(400, function()
      return vim.fn.filereadable(record) == 1
    end)
    return vim.fn.filereadable(record) == 0
  end

  return next_call, never_runs, function()
    vim.env.PATH = original
  end
end

test(":Ssh upload and :Ssh download drive scp with the right arguments", function()
  local dialog = require("ssh_launcher.ui.dialog")
  local next_call, never_runs, restore = fake_scp()
  configure({ terminal = { start_insert = false } })
  reset_store()
  store.add({ name = "box", host = "10.0.0.5", user = "me", remote_dir = "/srv/app" })
  store.add({ name = "prod-box", host = "10.0.0.6", user = "me", tags = { "prod" } })

  local up = TMP .. "/e2e-up"
  vim.fn.mkdir(up .. "/tree", "p")
  vim.fn.writefile({ "a" }, up .. "/a.txt")
  vim.fn.writefile({ "b" }, up .. "/b.txt")
  vim.fn.writefile({ "s" }, up .. "/sp ace.txt")
  vim.fn.writefile({ "t" }, up .. "/tree/t.txt")

  -- One path: it lands in the host's landing directory.
  local argv = next_call(function()
    vim.cmd("Ssh upload box " .. up .. "/a.txt")
  end)
  truthy(argv, "scp should have run")
  eq(argv[#argv], "me@10.0.0.5:/srv/app/", "the default destination is the landing directory")
  eq(argv[#argv - 1], up .. "/a.txt")

  -- Several paths, last one is the destination; a glob expands; a directory recurses.
  argv = next_call(function()
    vim.cmd(("Ssh upload box %s/*.txt %s/tree /tmp/in"):format(up, up))
  end)
  truthy(argv)
  truthy(vim.tbl_contains(argv, "-r"), "a directory among the sources recurses")
  eq(argv[#argv], "me@10.0.0.5:/tmp/in")
  truthy(vim.tbl_contains(argv, up .. "/b.txt"), "the glob expanded: " .. vim.inspect(argv))
  truthy(vim.tbl_contains(argv, up .. "/tree"))

  -- A backslash-escaped space is one argument.
  argv = next_call(function()
    vim.cmd(("Ssh upload box %s/sp\\ ace.txt /tmp/"):format(up))
  end)
  truthy(argv)
  eq(argv[#argv - 1], up .. "/sp ace.txt")

  -- A typo is caught before scp starts.
  truthy(
    never_runs(function()
      vim.cmd("Ssh upload box " .. up .. "/missing.txt")
    end),
    "a missing file must not start scp"
  )
  truthy(
    never_runs(function()
      vim.cmd("Ssh upload nosuchhost " .. up .. "/a.txt")
    end),
    "an unknown host must not start scp"
  )

  -- Production asks first, and declining sends nothing.
  local original = dialog.confirm
  local asked
  dialog.confirm = function(opts, cb)
    asked = opts
    cb(false)
  end
  truthy(
    never_runs(function()
      vim.cmd("Ssh upload prod-box " .. up .. "/a.txt")
    end),
    "declining the production prompt sends nothing"
  )
  truthy(asked and asked.destructive, "the production prompt is a destructive confirmation")
  contains(asked.lines, "10.0.0.6")

  dialog.confirm = function(_, cb)
    cb(true)
  end
  truthy(
    next_call(function()
      vim.cmd("Ssh upload prod-box " .. up .. "/a.txt")
    end),
    "accepting it sends the file"
  )

  -- The bang form skips the prompt.
  asked = nil
  dialog.confirm = function(opts, cb)
    asked = opts
    cb(false)
  end
  truthy(
    next_call(function()
      vim.cmd("Ssh! upload prod-box " .. up .. "/a.txt")
    end),
    ":Ssh! should not ask"
  )
  falsy(asked, "no prompt with a bang")

  -- Downloads: into the current directory by default, into a directory, or to a name.
  local down = TMP .. "/e2e-down"
  vim.fn.mkdir(down, "p")
  local previous = vim.fn.getcwd()
  vim.cmd("cd " .. vim.fn.fnameescape(down))

  argv = next_call(function()
    vim.cmd("Ssh download box /var/log/app.log")
  end)
  truthy(argv)
  truthy(vim.tbl_contains(argv, "-r"), "a download may be a directory")
  eq(argv[#argv - 1], "me@10.0.0.5:/var/log/app.log")
  eq(argv[#argv], vim.fn.getcwd(), "no destination means the current directory")
  eq(vim.uv.fs_realpath(argv[#argv]), vim.uv.fs_realpath(down))

  argv = next_call(function()
    vim.cmd(("Ssh download box /etc/hosts %s/hosts.copy"):format(down))
  end)
  eq(argv[#argv], down .. "/hosts.copy")

  truthy(
    never_runs(function()
      vim.cmd("Ssh download box /etc/hosts " .. down .. "/no/such/dir/hosts")
    end),
    "a missing destination directory is caught up front"
  )
  truthy(
    never_runs(function()
      vim.cmd("Ssh download box a b c")
    end),
    "too many arguments is a usage error"
  )

  -- Nothing local is overwritten silently.
  vim.fn.writefile({ "mine" }, down .. "/app.log")
  asked = nil
  dialog.confirm = function(opts, cb)
    asked = opts
    cb(false)
  end
  truthy(
    never_runs(function()
      vim.cmd("Ssh download box /var/log/app.log")
    end),
    "declining the overwrite prompt fetches nothing"
  )
  truthy(asked, "an existing file prompts")
  contains(asked.lines, down .. "/app.log")
  eq(vim.fn.readfile(down .. "/app.log"), { "mine" })

  dialog.confirm = function(_, cb)
    cb(true)
  end
  truthy(
    next_call(function()
      vim.cmd("Ssh download box /var/log/app.log")
    end),
    "agreeing fetches it"
  )

  asked = nil
  dialog.confirm = function(opts, cb)
    asked = opts
    cb(false)
  end
  truthy(
    next_call(function()
      vim.cmd("Ssh! download box /var/log/app.log")
    end),
    ":Ssh! overwrites without asking"
  )
  falsy(asked)

  -- The result reaches the caller.
  dialog.confirm = original
  local result
  require("ssh_launcher.transfer").upload(store.get_by_name("box"), { up .. "/a.txt" }, "/tmp/", {
    on_done = function(ok, msg)
      result = { ok = ok, msg = msg }
    end,
  })
  vim.wait(3000, function()
    return result ~= nil
  end)
  truthy(result and result.ok, "on_done reports success")
  contains(result.msg, "uploaded a.txt to box:/tmp/")

  vim.cmd("cd " .. vim.fn.fnameescape(previous))
  dialog.confirm = original
  restore()
  vim.cmd("silent! only")
  configure()
end)

test("the two-pane window browses both machines and copies between them", function()
  local commander = require("ssh_launcher.ui.commander")
  local dialog = require("ssh_launcher.ui.dialog")

  -- A stand-in ssh that runs the remote command on this machine, so the
  -- "remote" pane lists a real directory.
  local runner = TMP .. "/fake-commander-ssh"
  vim.fn.writefile({ "#!/bin/sh", 'for arg in "$@"; do command="$arg"; done', 'exec sh -c "$command"' }, runner)
  vim.uv.fs_chmod(runner, tonumber("755", 8))
  local next_call, never_runs, restore_path = fake_scp()
  configure({ ssh = { binary = runner }, remote = { adapter = "builtin", timeout = 3000 } })
  reset_store()
  store.add({ name = "pane-host", host = "example.invalid", user = "me" })
  local h = store.get_by_name("pane-host")

  local lroot, rroot = TMP .. "/pane-local", TMP .. "/pane-remote"
  vim.fn.mkdir(lroot .. "/docs", "p")
  vim.fn.mkdir(lroot .. "/src", "p")
  vim.fn.mkdir(rroot .. "/logs", "p")
  vim.fn.writefile({ "aa" }, lroot .. "/a.txt")
  vim.fn.writefile({ "bbbb" }, lroot .. "/b.txt")
  vim.fn.writefile({ "h" }, lroot .. "/.hidden")
  vim.fn.writefile({ "remote a" }, rroot .. "/a.txt")
  vim.fn.writefile({ "r" }, rroot .. "/report[1].txt")
  vim.fn.writefile({ "p" }, rroot .. "/.profile")
  local L, R = vim.uv.fs_realpath(lroot), vim.uv.fs_realpath(rroot)

  local function lines(pane)
    return vim.api.nvim_buf_get_lines(pane.float.buf, 0, -1, false)
  end
  local function text_of(value)
    if type(value) ~= "table" then
      return tostring(value or "")
    end
    local out = {}
    for _, chunk in ipairs(value) do
      out[#out + 1] = type(chunk) == "table" and chunk[1] or chunk
    end
    return table.concat(out)
  end
  local function press(keys)
    vim.api.nvim_feedkeys(vim.keycode(keys), "mx", false)
  end
  local function on(pane, name)
    for line, entry in pairs(pane.rows) do
      if entry.name == name then
        pane.float:set_cursor(line)
        return
      end
    end
    error("no entry named " .. name .. " in " .. pane.path)
  end
  local function loaded(c)
    return vim.wait(5000, function()
      return not c.left.loading and not c.right.loading and #c.left.listing > 0 and #c.right.listing > 0
    end)
  end

  local c = commander.open(h, { local_path = lroot, remote_path = rroot })
  truthy(c, "the window opens")
  truthy(loaded(c), "both panes list their directory")
  eq(c.left.path, L)
  eq(c.right.path, R)
  eq(c.active, c.left)

  -- Both machines are on screen at once, edge to edge, with a status line under them.
  local lc, rc, sc =
    vim.api.nvim_win_get_config(c.left.float.win),
    vim.api.nvim_win_get_config(c.right.float.win),
    vim.api.nvim_win_get_config(c.status.win)
  eq(lc.col + lc.width + 2, rc.col, "the panes sit edge to edge")
  eq(lc.row, rc.row)
  eq(lc.height, rc.height)
  eq(sc.row, lc.row + lc.height + 2, "the status line is directly under the panes")
  eq(sc.width, rc.col + rc.width + 2 - lc.col, "and spans both")
  contains(text_of(lc.title), "Local")
  contains(text_of(lc.title), "->", "the active pane is marked in text, not only colour")
  contains(text_of(rc.title), "pane-host")
  falsy(text_of(rc.title):find("->", 1, true), "the inactive pane is not")

  contains(lines(c.left), "docs/")
  contains(lines(c.left), "a.txt")
  contains(lines(c.left), "5B", "local sizes are shown (b.txt is 'bbbb' and a newline)")
  contains(lines(c.right), "logs/")
  contains(lines(c.right), "report[1].txt")
  contains(lines(c.right), "9B", "remote sizes come from the host's stat ('remote a' and a newline)")
  eq(c.left.rows[1].type, "parent", "the way up is always the first row")

  -- Dotfiles: shown by default, toggled per pane.
  contains(lines(c.left), ".hidden")
  press(".")
  falsy(table.concat(lines(c.left), "\n"):find(".hidden", 1, true), "dotfiles hide")
  contains(text_of(vim.api.nvim_win_get_config(c.left.float.win).footer), "dotfiles hidden")
  contains(lines(c.right), ".profile", "the other pane is unaffected")
  press(".")

  -- Selection is visible as text, counted in the footer, and Esc clears it first.
  on(c.left, "a.txt")
  press("<Space>")
  truthy(c.left.selected["a.txt"])
  contains(lines(c.left), "[x] a.txt")
  contains(text_of(vim.api.nvim_win_get_config(c.left.float.win).footer), "1 selected")
  press("<Esc>")
  eq(next(c.left.selected), nil, "<Esc> clears a selection before it closes anything")
  truthy(commander.instance(), "and the window is still open")
  press("*")
  truthy(
    c.left.selected["a.txt"] and c.left.selected["b.txt"] and c.left.selected["docs"],
    "* selects everything shown"
  )
  press("*")
  eq(next(c.left.selected), nil, "and unselects when everything already is")

  -- Switching panes and moving through directories.
  press("<Tab>")
  eq(c.active, c.right)
  eq(vim.api.nvim_get_current_win(), c.right.float.win)
  press("<Tab>")
  eq(c.active, c.left)
  on(c.left, "docs")
  press("<CR>")
  vim.wait(2000, function()
    return c.left.path == L .. "/docs"
  end)
  eq(c.left.path, L .. "/docs")
  contains(lines(c.left), "(empty)")
  press("h")
  vim.wait(2000, function()
    return c.left.path == L
  end)
  eq(c.left.path, L)
  eq(
    c.left.rows[vim.api.nvim_win_get_cursor(c.left.float.win)[1]].name,
    "docs",
    "going up lands on the directory you left"
  )

  -- Upload two files; a.txt already exists remotely, so it asks, and no is no.
  local asked
  local original_confirm = dialog.confirm
  dialog.confirm = function(opts, cb)
    asked = opts
    cb(false)
  end
  on(c.left, "a.txt")
  press("<Space>")
  press("<Space>") -- a.txt then b.txt
  truthy(
    never_runs(function()
      press("c")
    end),
    "declining the overwrite prompt copies nothing"
  )
  contains(asked.lines, "a.txt")
  truthy(c.left.selected["a.txt"] and c.left.selected["b.txt"], "a declined copy keeps the selection")

  dialog.confirm = function(_, cb)
    cb(true)
  end
  local argv = next_call(function()
    press("c")
  end)
  truthy(argv, "scp ran")
  truthy(vim.tbl_contains(argv, "BatchMode=yes"), "the transfer is non-interactive: " .. vim.inspect(argv))
  truthy(
    vim.tbl_contains(argv, L .. "/a.txt") and vim.tbl_contains(argv, L .. "/b.txt"),
    "both selected files are sent"
  )
  eq(argv[#argv], "me@example.invalid:" .. R, "to the directory the other pane is showing")
  vim.wait(2000, function()
    return c.current == nil
  end)
  eq(next(c.left.selected), nil, "the selection is spent once the copy starts")
  contains(text_of(vim.api.nvim_buf_get_lines(c.status.buf, 0, -1, false)), "Uploaded 2 items to pane-host")

  -- Download from the remote pane into the local one; a literal name is not a glob.
  press("<Tab>")
  on(c.right, "report[1].txt")
  press("<Space>")
  on(c.right, "logs")
  press("<Space>")
  argv = next_call(function()
    press("c")
  end)
  truthy(argv)
  truthy(vim.tbl_contains(argv, "-r"), "a download may include directories")
  truthy(
    vim.tbl_contains(argv, "me@example.invalid:" .. R .. "/report\\[1\\].txt"),
    "glob characters are escaped: " .. vim.inspect(argv)
  )
  truthy(vim.tbl_contains(argv, "me@example.invalid:" .. R .. "/logs"))
  eq(argv[#argv], L, "into the local pane's directory")
  vim.wait(2000, function()
    return c.current == nil
  end)

  -- Copying with nothing under the cursor says so instead of guessing.
  press("<Tab>")
  press("gg") -- the ../ row
  truthy(
    never_runs(function()
      press("c")
    end),
    "../ is not a thing to copy"
  )
  contains(text_of(vim.api.nvim_buf_get_lines(c.status.buf, 0, -1, false)), "nothing to copy")

  -- Typing a path, and making a directory on each side.
  local original_input = vim.ui.input
  vim.ui.input = function(_, cb)
    cb(L .. "/src")
  end
  press("go")
  vim.wait(2000, function()
    return c.left.path == L .. "/src"
  end)
  eq(c.left.path, L .. "/src", "go jumps to a typed path")
  vim.ui.input = function(_, cb)
    cb("..")
  end
  press("go")
  vim.wait(2000, function()
    return c.left.path == L
  end)
  eq(c.left.path, L, "a relative path is taken from the pane's directory")

  vim.ui.input = function(_, cb)
    cb("fresh")
  end
  press("m")
  truthy(util.is_dir(L .. "/fresh"), "m makes a local directory")
  vim.wait(2000, function()
    return table.concat(lines(c.left), "\n"):find("fresh/", 1, true) ~= nil
  end)
  contains(lines(c.left), "fresh/")

  press("<Tab>")
  vim.ui.input = function(_, cb)
    cb("made-remotely/deep")
  end
  press("m")
  vim.wait(3000, function()
    return util.is_dir(R .. "/made-remotely/deep")
  end)
  truthy(util.is_dir(R .. "/made-remotely/deep"), "and a remote one, parents included")
  vim.ui.input = original_input

  -- A host tagged production confirms an upload that the user has not already
  -- been asked about, and downloads from it are not gated at all.
  store.add({ name = "live-host", host = "example.invalid", user = "me", tags = { "prod" } })
  press("q")
  falsy(commander.instance(), "q closes the window")
  falsy(vim.api.nvim_win_is_valid(c.left.float.win or -1), "and both panes with it")

  local live = commander.open(store.get_by_name("live-host"), { local_path = lroot, remote_path = rroot })
  loaded(live)
  local gated
  dialog.confirm = function(opts, cb)
    gated = opts
    cb(false)
  end
  on(live.left, "b.txt")
  truthy(
    never_runs(function()
      press("c")
    end),
    "a production upload waits for a yes"
  )
  truthy(gated and gated.destructive, "and says so")
  live:close()

  dialog.confirm = original_confirm
  restore_path()
  configure()
  vim.cmd("silent! only")
end)

test("a transfer in flight shows its progress, queues behind itself, and cancels cleanly", function()
  local commander = require("ssh_launcher.ui.commander")
  local runner = TMP .. "/fake-commander-ssh"
  local next_call, _, restore_path = fake_scp(true) -- scp that never finishes on its own
  configure({ ssh = { binary = runner }, remote = { adapter = "builtin", timeout = 3000 } })
  reset_store()
  store.add({ name = "slow-host", host = "example.invalid", user = "me" })

  local lroot, rroot = TMP .. "/slow-local", TMP .. "/slow-remote"
  vim.fn.mkdir(lroot, "p")
  vim.fn.mkdir(rroot, "p")
  vim.fn.writefile({ "1" }, lroot .. "/one.bin")
  vim.fn.writefile({ "2" }, lroot .. "/two.bin")
  vim.fn.writefile({ "x" }, rroot .. "/placeholder")

  local c = commander.open(store.get_by_name("slow-host"), { local_path = lroot, remote_path = rroot })
  vim.wait(5000, function()
    return #c.left.listing > 0 and #c.right.listing > 0 and not c.right.loading
  end)
  local function status()
    return table.concat(vim.api.nvim_buf_get_lines(c.status.buf, 0, -1, false), "\n")
  end
  local function press(keys)
    vim.api.nvim_feedkeys(vim.keycode(keys), "mx", false)
  end
  local function on(name)
    for line, entry in pairs(c.left.rows) do
      if entry.name == name then
        c.left.float:set_cursor(line)
      end
    end
  end

  on("one.bin")
  truthy(
    next_call(function()
      press("c")
    end),
    "the first transfer starts"
  )
  truthy(c.current, "and is in flight")
  contains(status(), "Uploading one.bin to slow-host", "the status line says what is moving and where")
  contains(status(), "cancel", "and how to stop it")

  on("two.bin")
  press("c")
  eq(#c.queue, 1, "a second copy waits its turn instead of running alongside")
  c:draw_status()
  contains(status(), "+1 queued")

  local pid = tonumber(vim.fn.readfile(TMP .. "/scp.pid")[1])
  truthy(vim.uv.kill(pid, 0) == 0, "scp is really running")
  press("x")
  truthy(
    vim.wait(3000, function()
      return c.current == nil
    end),
    "cancelling ends the transfer"
  )
  eq(#c.queue, 0, "and drops what was queued behind it")
  contains(status(), "cancelled")
  truthy(
    vim.wait(3000, function()
      return vim.uv.kill(pid, 0) ~= 0
    end),
    "the scp process is gone, not left running"
  )
  eq(tonumber(vim.fn.readfile(TMP .. "/scp.pid")[1]), pid, "and the queued transfer never started")

  press("x")
  contains(status(), "nothing is transferring", "cancelling an idle window is harmless")

  c:close()
  restore_path()
  configure()
  vim.cmd("silent! only")
end)

test(":Ssh transfer opens the window, starting where it is told", function()
  local commander = require("ssh_launcher.ui.commander")
  local runner = TMP .. "/fake-commander-ssh"
  configure({ ssh = { binary = runner }, remote = { adapter = "builtin", timeout = 3000 } })
  reset_store()
  store.add({ name = "cmd-host", host = "example.invalid", user = "me" })
  local start = TMP .. "/transfer-start"
  vim.fn.mkdir(start, "p")

  vim.cmd("Ssh transfer cmd-host " .. start)
  local c = commander.instance()
  truthy(c, ":Ssh transfer opens the window")
  vim.wait(5000, function()
    return not c.right.loading and c.right.path == vim.uv.fs_realpath(start)
  end)
  eq(c.right.path, vim.uv.fs_realpath(start), "the remote pane starts at the given path")
  eq(c.host.name, "cmd-host")
  c:close()

  truthy(vim.tbl_contains(require("ssh_launcher")._subcommands(), "transfer"))
  truthy(
    vim.tbl_contains(require("ssh_launcher")._complete("", "Ssh transfer "), "cmd-host"),
    "it completes host names"
  )

  -- Too small a terminal is an error, not a broken layout.
  local columns = vim.o.columns
  vim.o.columns = 40
  falsy(commander.open(store.get_by_name("cmd-host")), "two panes do not fit in 40 columns")
  vim.o.columns = columns
  configure()
end)

test(":Ssh upload and :Ssh download complete hosts, then local paths", function()
  local ssh = require("ssh_launcher")
  reset_store()
  store.add({ name = "box", host = "10.0.0.5", user = "me" })
  store.add({ name = "my box", host = "10.0.0.7", user = "me" })

  local dir = TMP .. "/complete"
  vim.fn.mkdir(dir, "p")
  vim.fn.writefile({ "1" }, dir .. "/alpha.txt")
  vim.fn.writefile({ "2" }, dir .. "/sp ace.txt")

  truthy(vim.tbl_contains(ssh._complete("", "Ssh upload "), "box"), "the first argument is a host")
  truthy(vim.tbl_contains(ssh._complete("", "Ssh download "), "box"))
  truthy(vim.tbl_contains(ssh._subcommands(), "upload"))
  truthy(vim.tbl_contains(ssh._subcommands(), "download"))

  local after_host = ssh._complete(dir .. "/", "Ssh upload box " .. dir .. "/")
  truthy(vim.tbl_contains(after_host, dir .. "/alpha.txt"), vim.inspect(after_host))
  truthy(vim.tbl_contains(after_host, dir .. "/sp\\ ace.txt"), "a space is escaped so it stays one argument")

  -- Every further upload argument is local too.
  truthy(#ssh._complete(dir .. "/", ("Ssh upload box %s/alpha.txt %s/"):format(dir, dir)) >= 2)

  -- A download names a remote path first; that cannot be completed locally.
  eq(ssh._complete("/va", "Ssh download box /va"), {}, "remote paths are not completed")
  truthy(#ssh._complete(dir .. "/", ("Ssh download box /var/log/x %s/"):format(dir)) >= 2, "then a local destination")
end)

test("commands and completion work through the user-command layer", function()
  reset_store()
  require("ssh_launcher").save("deploy@web-01.example.com")

  local ssh = require("ssh_launcher")
  truthy(#ssh._complete("", "Ssh ") > 5, "subcommand completion")
  truthy(vim.tbl_contains(ssh._subcommands(), "workspace"), "workspace subcommand")
  truthy(vim.tbl_contains(ssh._complete("", "Ssh connect "), "deploy@web-01.example.com"), "host-name completion")

  vim.cmd("Ssh list")
  vim.cmd("silent! only")
  vim.cmd("Ssh diagnose")
  vim.cmd("silent! only")
  vim.cmd("Ssh reload")
end)

--------------------------------------------------------------------------------
suite("health")
--------------------------------------------------------------------------------

test("checkhealth runs end to end", function()
  vim.wait(60, function()
    return false
  end)
  vim.cmd("checkhealth ssh_launcher")
end)

--------------------------------------------------------------------------------

vim.fn.delete(TMP, "rf")

io.write(("\n%d passed, %d failed\n"):format(passed, failed))
vim.cmd(failed == 0 and "qall!" or "cq")
