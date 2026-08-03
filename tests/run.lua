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
    "ui.theme",
    "ui.float",
    "ui.render",
    "ui.dialog",
    "ui.form",
    "ui.help",
    "ui.manager",
    "ui.picker",
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
  local cfg = require("ssh_launcher.config").setup({ terminal = { strategy = "nope" }, ui = { width = 99 } })
  eq(cfg.terminal.strategy, "tab")
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

test("commands and completion work through the user-command layer", function()
  reset_store()
  require("ssh_launcher").save("deploy@web-01.example.com")

  local ssh = require("ssh_launcher")
  truthy(#ssh._complete("", "Ssh ") > 5, "subcommand completion")
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
