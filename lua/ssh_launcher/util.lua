---@mod ssh_launcher.util Low-level helpers
---
--- Path, filesystem, string and async primitives shared by every other module.
--- Nothing in here touches user state; everything is pure or filesystem-local.

local M = {}

local uv = vim.uv or vim.loop
M.uv = uv

M.sep = package.config:sub(1, 1)
M.is_win = M.sep == "\\"

--------------------------------------------------------------------------------
-- Paths
--------------------------------------------------------------------------------

---@return string
function M.home()
  return uv.os_homedir() or vim.env.HOME or vim.env.USERPROFILE or ""
end

--- Expand `~`, `$VAR` and `${VAR}` without invoking glob expansion.
--- Unlike |expand()| this never treats `*`, `?` or `[` as wildcards, which
--- matters because key paths may legitimately contain them.
---@param path string|nil
---@return string|nil
function M.expand(path)
  if type(path) ~= "string" or path == "" then
    return path
  end
  local p = path
  local home = M.home()
  if home ~= "" then
    if p == "~" then
      p = home
    elseif p:sub(1, 2) == "~/" or (M.is_win and p:sub(1, 2) == "~\\") then
      p = home .. "/" .. p:sub(3)
    end
  end
  p = p:gsub("%${([%w_]+)}", function(v)
    return uv.os_getenv(v) or ("${" .. v .. "}")
  end)
  p = p:gsub("%$([%w_]+)", function(v)
    return uv.os_getenv(v) or ("$" .. v)
  end)
  return p
end

--- Inverse of |ssh_launcher.util.expand| for display: shorten `$HOME` to `~`.
---@param path string|nil
---@return string|nil
function M.contract(path)
  if type(path) ~= "string" or path == "" then
    return path
  end
  local home = M.home()
  if home ~= "" and path:sub(1, #home) == home then
    return "~" .. path:sub(#home + 1)
  end
  return path
end

---@param ... string
---@return string
function M.join(...)
  local parts = { ... }
  local out = {}
  for _, p in ipairs(parts) do
    if p and p ~= "" then
      out[#out + 1] = (p:gsub("/+$", ""))
    end
  end
  return (table.concat(out, "/"):gsub("//+", "/"))
end

---@param path string
---@return string
function M.dirname(path)
  return path:match("^(.*)[/\\][^/\\]*$") or "."
end

---@param path string
---@return string
function M.basename(path)
  return path:match("[^/\\]*$") or path
end

--------------------------------------------------------------------------------
-- Filesystem
--------------------------------------------------------------------------------

---@param path string|nil
---@return uv.aliases.fs_stat_table|nil
function M.stat(path)
  if not path or path == "" then
    return nil
  end
  return uv.fs_stat(M.expand(path))
end

---@param path string|nil
---@return boolean
function M.exists(path)
  return M.stat(path) ~= nil
end

---@param path string|nil
---@return boolean
function M.is_file(path)
  local st = M.stat(path)
  return st ~= nil and st.type == "file"
end

---@param path string|nil
---@return boolean
function M.is_dir(path)
  local st = M.stat(path)
  return st ~= nil and st.type == "directory"
end

--- Permission bits of `path` as a 4-char octal string, e.g. `"0600"`.
---@param path string
---@return string|nil
function M.mode_octal(path)
  local st = M.stat(path)
  if not st then
    return nil
  end
  return string.format("%04o", bit and bit.band(st.mode, 4095) or (st.mode % 4096))
end

--- True when `path` grants any permission to group or other.
---@param path string
---@return boolean|nil open, string|nil mode
function M.is_world_accessible(path)
  local st = M.stat(path)
  if not st then
    return nil, nil
  end
  local perms = st.mode % 4096
  return (perms % 64) ~= 0, string.format("%04o", perms)
end

---@param path string
---@return string|nil content, string|nil err
function M.read_file(path)
  local p = M.expand(path)
  local fd, oerr = uv.fs_open(p, "r", 438)
  if not fd then
    return nil, oerr
  end
  local st = uv.fs_fstat(fd)
  local data = st and uv.fs_read(fd, st.size, 0) or nil
  uv.fs_close(fd)
  if not data then
    return nil, "read failed"
  end
  return data, nil
end

--- Read at most `n` bytes; used for cheap file sniffing (key headers etc).
---@param path string
---@param n integer
---@return string|nil
function M.read_head(path, n)
  local p = M.expand(path)
  local fd = uv.fs_open(p, "r", 438)
  if not fd then
    return nil
  end
  local data = uv.fs_read(fd, n, 0)
  uv.fs_close(fd)
  return data
end

---@param path string
---@param mode integer|nil octal mode, default 0700
---@return boolean ok, string|nil err
function M.mkdirp(path, mode)
  local p = M.expand(path)
  mode = mode or tonumber("700", 8)
  if M.is_dir(p) then
    return true
  end
  local parts, acc = {}, ""
  for part in p:gmatch("[^/\\]+") do
    parts[#parts + 1] = part
  end
  if p:sub(1, 1) == "/" then
    acc = ""
  end
  for i, part in ipairs(parts) do
    acc = (i == 1 and p:sub(1, 1) ~= "/") and part or (acc .. "/" .. part)
    if not M.is_dir(acc) then
      local ok, err = uv.fs_mkdir(acc, mode)
      if not ok and not M.is_dir(acc) then
        return false, err
      end
    end
  end
  return true, nil
end

--- Write `content` to `path` atomically: a sibling temp file is created with the
--- requested mode, fully written, fsynced and only then renamed over the target.
--- A crash therefore never leaves a truncated host database behind.
---@param path string
---@param content string
---@param mode integer|nil default 0600
---@return boolean ok, string|nil err
function M.write_file_atomic(path, content, mode)
  local p = M.expand(path)
  mode = mode or tonumber("600", 8)
  local dir = M.dirname(p)
  local ok, err = M.mkdirp(dir, tonumber("700", 8))
  if not ok then
    return false, ("cannot create %s: %s"):format(dir, err or "unknown error")
  end

  local tmp = ("%s.%d.tmp"):format(p, uv.os_getpid())
  local fd, oerr = uv.fs_open(tmp, "w", mode)
  if not fd then
    return false, oerr
  end

  local werr
  local written, e = uv.fs_write(fd, content, 0)
  if not written then
    werr = e
  end
  pcall(uv.fs_fsync, fd)
  uv.fs_close(fd)

  if werr then
    pcall(uv.fs_unlink, tmp)
    return false, werr
  end

  -- fs_open honours `mode` only on creation; enforce it explicitly in case the
  -- temp file survived a previous crash with looser permissions.
  pcall(uv.fs_chmod, tmp, mode)

  local rok, rerr = uv.fs_rename(tmp, p)
  if not rok then
    pcall(uv.fs_unlink, tmp)
    return false, rerr
  end
  return true, nil
end

---@param path string
---@param mode integer
---@return boolean ok, string|nil err
function M.chmod(path, mode)
  local ok, err = uv.fs_chmod(M.expand(path), mode)
  return ok and true or false, err
end

--- List a directory. Returns `{ {name=..., type=...}, ... }`.
---@param path string
---@return { name: string, type: string }[]
function M.scandir(path)
  local out = {}
  local handle = uv.fs_scandir(M.expand(path))
  if not handle then
    return out
  end
  while true do
    local name, type_ = uv.fs_scandir_next(handle)
    if not name then
      break
    end
    out[#out + 1] = { name = name, type = type_ }
  end
  return out
end

--------------------------------------------------------------------------------
-- Strings
--------------------------------------------------------------------------------

---@param s string|nil
---@return string
function M.trim(s)
  if type(s) ~= "string" then
    return ""
  end
  return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

---@param s string
---@param sep string lua pattern
---@return string[]
function M.split(s, sep)
  local out = {}
  for piece in tostring(s):gmatch("([^" .. sep .. "]+)") do
    out[#out + 1] = piece
  end
  return out
end

---@param s string|nil
---@return boolean
function M.blank(s)
  return s == nil or M.trim(s) == ""
end

--- Trimmed string, or `nil` when there was nothing but whitespace.
--- (Written as a function because `blank(s) and nil or trim(s)` is the classic
--- Lua footgun: the `nil` branch collapses and the `or` arm always wins.)
---@param s any
---@return string|nil
function M.nonblank(s)
  if s == nil then
    return nil
  end
  local t = M.trim(tostring(s))
  if t == "" then
    return nil
  end
  return t
end

--- Strip surrounding single/double quotes from a token.
---@param s string
---@return string
function M.unquote(s)
  local first, last = s:sub(1, 1), s:sub(-1)
  if #s >= 2 and (first == '"' or first == "'") and first == last then
    return s:sub(2, -2)
  end
  return s
end

---@param s string
---@return integer
function M.width(s)
  return vim.fn.strdisplaywidth(s or "")
end

--- Truncate to `n` display cells, appending an ellipsis when cut.
---@param s string
---@param n integer
---@param ellipsis string|nil
---@return string
function M.truncate(s, n, ellipsis)
  s = s or ""
  ellipsis = ellipsis or "…"
  if M.width(s) <= n then
    return s
  end
  local budget = n - M.width(ellipsis)
  if budget <= 0 then
    return string.rep(".", math.max(n, 0))
  end
  local out = {}
  local acc = 0
  for _, ch in ipairs(vim.split(s, "", { plain = true })) do
    local w = M.width(ch)
    if acc + w > budget then
      break
    end
    acc = acc + w
    out[#out + 1] = ch
  end
  return table.concat(out) .. ellipsis
end

--- Pad to `n` display cells (display-width aware, so icons/CJK align).
---@param s string
---@param n integer
---@param align "left"|"right"|"center"|nil
---@return string
function M.pad(s, n, align)
  s = s or ""
  local pad = n - M.width(s)
  if pad <= 0 then
    return s
  end
  if align == "right" then
    return string.rep(" ", pad) .. s
  elseif align == "center" then
    local l = math.floor(pad / 2)
    return string.rep(" ", l) .. s .. string.rep(" ", pad - l)
  end
  return s .. string.rep(" ", pad)
end

---@param s string
---@param n integer
---@param align "left"|"right"|"center"|nil
---@return string
function M.fit(s, n, align)
  return M.pad(M.truncate(s, n), n, align)
end

--------------------------------------------------------------------------------
-- Tables
--------------------------------------------------------------------------------

---@generic T
---@param tbl T[]
---@param pred fun(item: T, idx: integer): boolean
---@return integer|nil
function M.index_of(tbl, pred)
  for i, v in ipairs(tbl) do
    if type(pred) == "function" then
      if pred(v, i) then
        return i
      end
    elseif v == pred then
      return i
    end
  end
  return nil
end

---@generic T
---@param tbl T[]
---@param pred fun(item: T): boolean
---@return T|nil
function M.find(tbl, pred)
  local i = M.index_of(tbl, pred)
  return i and tbl[i] or nil
end

---@generic T
---@param tbl T[]
---@param pred fun(item: T): boolean
---@return T[]
function M.filter(tbl, pred)
  local out = {}
  for _, v in ipairs(tbl) do
    if pred(v) then
      out[#out + 1] = v
    end
  end
  return out
end

---@param tbl table
---@return boolean
function M.is_list(tbl)
  if type(tbl) ~= "table" then
    return false
  end
  if vim.islist then
    return vim.islist(tbl)
  end
  return vim.tbl_islist(tbl)
end

--- Remove `nil`-valued keys and empty strings so serialized hosts stay compact.
---@param tbl table
---@return table
function M.compact(tbl)
  local out = {}
  for k, v in pairs(tbl) do
    if v ~= nil and v ~= "" then
      if type(v) == "table" and vim.tbl_isempty(v) then
        -- drop empty containers
      else
        out[k] = v
      end
    end
  end
  return out
end

--------------------------------------------------------------------------------
-- JSON
--------------------------------------------------------------------------------

local json_escapes = {
  ['"'] = '\\"',
  ["\\"] = "\\\\",
  ["\b"] = "\\b",
  ["\f"] = "\\f",
  ["\n"] = "\\n",
  ["\r"] = "\\r",
  ["\t"] = "\\t",
}

local function json_string(s)
  local out = s:gsub('[%c"\\]', function(c)
    return json_escapes[c] or string.format("\\u%04x", c:byte())
  end)
  return '"' .. out .. '"'
end

--- Stable, indented JSON. Object keys are sorted so that two machines writing
--- the same fleet produce byte-identical files and diffs stay reviewable.
---@param value any
---@param indent string|nil
---@return string
function M.json_pretty(value, indent)
  indent = indent or ""
  local next_indent = indent .. "  "
  local t = type(value)

  if value == nil or value == vim.NIL then
    return "null"
  elseif t == "boolean" then
    return tostring(value)
  elseif t == "number" then
    if value ~= value or value == math.huge or value == -math.huge then
      return "null"
    end
    if value == math.floor(value) and math.abs(value) < 2 ^ 53 then
      return string.format("%d", value)
    end
    return string.format("%.14g", value)
  elseif t == "string" then
    return json_string(value)
  elseif t ~= "table" then
    return json_string(tostring(value))
  end

  if M.is_list(value) then
    if #value == 0 then
      return "[]"
    end
    local parts = {}
    for _, v in ipairs(value) do
      parts[#parts + 1] = next_indent .. M.json_pretty(v, next_indent)
    end
    return "[\n" .. table.concat(parts, ",\n") .. "\n" .. indent .. "]"
  end

  local keys = {}
  for k in pairs(value) do
    keys[#keys + 1] = tostring(k)
  end
  if #keys == 0 then
    return "{}"
  end
  table.sort(keys)
  local parts = {}
  for _, k in ipairs(keys) do
    parts[#parts + 1] = next_indent .. json_string(k) .. ": " .. M.json_pretty(value[k], next_indent)
  end
  return "{\n" .. table.concat(parts, ",\n") .. "\n" .. indent .. "}"
end

--------------------------------------------------------------------------------
-- Identity / time
--------------------------------------------------------------------------------

local id_counter = 0

--- Collision-resistant, human-greppable id (`h_<time36>_<rand>`).
---@return string
function M.uid()
  id_counter = id_counter + 1
  local t = os.time()
  local r = math.random(0, 0xFFFFFF)
  return string.format("h_%x_%x%x", t, r, id_counter)
end

---@return integer
function M.now()
  return os.time()
end

--- Compact relative time, e.g. `3m`, `5h`, `2d`, `—` when never.
---@param ts integer|nil
---@return string
function M.ago(ts)
  if not ts or ts <= 0 then
    return "—"
  end
  local d = os.time() - ts
  if d < 0 then
    return "now"
  end
  if d < 60 then
    return "now"
  end
  if d < 3600 then
    return ("%dm"):format(math.floor(d / 60))
  end
  if d < 86400 then
    return ("%dh"):format(math.floor(d / 3600))
  end
  if d < 86400 * 30 then
    return ("%dd"):format(math.floor(d / 86400))
  end
  if d < 86400 * 365 then
    return ("%dmo"):format(math.floor(d / (86400 * 30)))
  end
  return ("%dy"):format(math.floor(d / (86400 * 365)))
end

---@param ts integer|nil
---@return string
function M.datetime(ts)
  if not ts or ts <= 0 then
    return "never"
  end
  return os.date("%Y-%m-%d %H:%M", ts) --[[@as string]]
end

--------------------------------------------------------------------------------
-- Async
--------------------------------------------------------------------------------

--- Trailing-edge debounce that is safe to call from fast events.
---@param fn function
---@param ms integer
---@return function wrapped, function cancel
function M.debounce(fn, ms)
  local timer = nil
  local function cancel()
    if timer then
      timer:stop()
      if not timer:is_closing() then
        timer:close()
      end
      timer = nil
    end
  end
  return function(...)
    local args = { ... }
    cancel()
    timer = uv.new_timer()
    timer:start(
      ms,
      0,
      vim.schedule_wrap(function()
        cancel()
        fn(unpack(args))
      end)
    )
  end,
    cancel
end

---@class ssh_launcher.SystemResult
---@field code integer
---@field stdout string
---@field stderr string
---@field ok boolean

--- Run a command as an argv list (never through a shell) and call back on the
--- main loop. Returns immediately; the callback receives a normalized result.
---@param cmd string[]
---@param opts table|nil `{ timeout = ms, cwd = string, env = table, stdin = string }`
---@param on_exit fun(res: ssh_launcher.SystemResult)|nil
function M.system(cmd, opts, on_exit)
  opts = vim.tbl_extend("keep", opts or {}, { text = true, timeout = 10000 })
  local cb = on_exit
    and vim.schedule_wrap(function(res)
      on_exit({
        code = res.code or -1,
        stdout = res.stdout or "",
        stderr = res.stderr or "",
        ok = (res.code == 0),
      })
    end)
  local ok, err = pcall(vim.system, cmd, opts, cb)
  if not ok and on_exit then
    vim.schedule(function()
      on_exit({ code = -1, stdout = "", stderr = tostring(err), ok = false })
    end)
  end
end

--- Synchronous variant with a hard timeout. Only for fast, local binaries
--- (`ssh-keygen -l`, `ssh -G`), never for anything that touches the network.
---@param cmd string[]
---@param timeout integer|nil ms
---@return ssh_launcher.SystemResult
function M.system_sync(cmd, timeout)
  local ok, proc = pcall(vim.system, cmd, { text = true })
  if not ok then
    return { code = -1, stdout = "", stderr = tostring(proc), ok = false }
  end
  local done, res = pcall(function()
    return proc:wait(timeout or 5000)
  end)
  if not done then
    pcall(function()
      proc:kill(9)
    end)
    return { code = -1, stdout = "", stderr = "timed out", ok = false }
  end
  return {
    code = res.code or -1,
    stdout = res.stdout or "",
    stderr = res.stderr or "",
    ok = res.code == 0,
  }
end

---@param bin string
---@return boolean
function M.has_executable(bin)
  return vim.fn.executable(bin) == 1
end

---@param mod string
---@return boolean ok, any module
function M.has_module(mod)
  local ok, m = pcall(require, mod)
  return ok, ok and m or nil
end

return M
