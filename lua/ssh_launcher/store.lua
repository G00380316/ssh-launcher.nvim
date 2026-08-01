---@mod ssh_launcher.store Host database
---
--- Durable, atomic, 0600 storage for saved hosts, plus read-only aggregation of
--- external sources (`~/.ssh/config`, shared fleet files, project-local files).
---
--- Concurrency: Neovim instances share one file. Before every write the on-disk
--- mtime is compared with what we loaded; if another instance wrote in the
--- meantime we re-read and merge per-host by `updated_at` rather than silently
--- overwriting a colleague's edit.

local util = require("ssh_launcher.util")
local log = require("ssh_launcher.log")
local config = require("ssh_launcher.config")
local Host = require("ssh_launcher.host")

local M = {}

M.SCHEMA_VERSION = 2

---@class ssh_launcher.StoreState
local state = {
  ---@type ssh_launcher.Host[]
  hosts = {},
  ---@type integer|nil
  mtime = nil,
  loaded = false,
  ---@type ssh_launcher.Host[]
  external = {},
  external_loaded = false,
}

---@type table<string, fun()>
local listeners = {}

--- Register a callback fired whenever the host set changes.
---@param name string
---@param cb fun()
function M.on_change(name, cb)
  listeners[name] = cb
end

local function emit_change()
  for name, cb in pairs(listeners) do
    local ok, err = pcall(cb)
    if not ok then
      log.debug(("listener %s failed: %s"):format(name, err))
    end
  end
end

---@return string
local function path()
  return util.expand(config.get().store.path)
end

---@return integer|nil
local function disk_mtime()
  local st = util.stat(path())
  return st and st.mtime and st.mtime.sec or nil
end

--------------------------------------------------------------------------------
-- Decoding / migration
--------------------------------------------------------------------------------

---@param raw string
---@return table|nil decoded, string|nil err
local function decode(raw)
  if util.trim(raw) == "" then
    return { version = M.SCHEMA_VERSION, hosts = {} }, nil
  end
  local ok, result = pcall(vim.json.decode, raw, { luanil = { object = true, array = true } })
  if not ok then
    return nil, tostring(result)
  end
  return result, nil
end

--- v1 was a bare array of `{name,user,host,key}`. v2 is
--- `{version, hosts, updated_at}` with the richer host schema.
---@param decoded table
---@return ssh_launcher.Host[] hosts, boolean migrated
local function migrate(decoded)
  local migrated = false
  local raw_hosts

  if util.is_list(decoded) then
    raw_hosts = decoded
    migrated = true
  else
    raw_hosts = decoded.hosts or {}
    if (tonumber(decoded.version) or 1) < M.SCHEMA_VERSION then
      migrated = true
    end
  end

  local hosts = {}
  local seen_ids = {}
  for _, raw in ipairs(raw_hosts) do
    if type(raw) == "table" then
      local h = Host.normalize(raw)
      -- Guarantee unique ids even if a hand-edited file duplicated one.
      while seen_ids[h.id] do
        h.id = util.uid()
        migrated = true
      end
      seen_ids[h.id] = true
      h.source = "store"
      hosts[#hosts + 1] = h
    end
  end
  return hosts, migrated
end

---@param reason string
local function backup(reason)
  local cfg = config.get()
  if not cfg.store.backup then
    return
  end
  local p = path()
  if not util.is_file(p) then
    return
  end
  local content = util.read_file(p)
  if not content then
    return
  end
  local dir = util.join(util.expand(cfg.store.state_dir), "backups")
  util.mkdirp(dir, tonumber("700", 8))
  local dest = util.join(dir, ("hosts-%s-%s.json"):format(os.date("%Y%m%d%H%M%S"), reason))
  util.write_file_atomic(dest, content, tonumber("600", 8))

  -- rotate
  local entries = {}
  for _, e in ipairs(util.scandir(dir)) do
    if e.type == "file" and e.name:match("^hosts%-") then
      entries[#entries + 1] = e.name
    end
  end
  table.sort(entries)
  local excess = #entries - (cfg.store.backup_keep or 5)
  for i = 1, excess do
    pcall(util.uv.fs_unlink, util.join(dir, entries[i]))
  end
end

--------------------------------------------------------------------------------
-- Load / save
--------------------------------------------------------------------------------

--- Read the store from disk. Safe to call repeatedly; a corrupt file is moved
--- aside rather than silently discarded.
---@param force boolean|nil
---@return ssh_launcher.Host[]
function M.load(force)
  local p = path()
  local mtime = disk_mtime()

  if state.loaded and not force and mtime == state.mtime then
    return state.hosts
  end

  if not util.is_file(p) then
    state.hosts = {}
    state.mtime = nil
    state.loaded = true
    return state.hosts
  end

  local raw, rerr = util.read_file(p)
  if not raw then
    log.error(("cannot read %s: %s"):format(util.contract(p), rerr or "unknown error"))
    state.loaded = true
    return state.hosts
  end

  local decoded, derr = decode(raw)
  if not decoded then
    local quarantine = p .. ".corrupt." .. os.date("%Y%m%d%H%M%S")
    util.write_file_atomic(quarantine, raw, tonumber("600", 8))
    log.error(
      ("host database is not valid JSON (%s). The unreadable file was preserved at %s and a fresh one will be created."):format(
        derr or "parse error",
        util.contract(quarantine)
      )
    )
    state.hosts = {}
    state.mtime = mtime
    state.loaded = true
    return state.hosts
  end

  local hosts, migrated = migrate(decoded)
  state.hosts = hosts
  state.mtime = mtime
  state.loaded = true

  if migrated then
    backup("premigration")
    if M.save({ silent = true }) then
      log.info(("upgraded %d saved host%s to schema v%d"):format(#hosts, #hosts == 1 and "" or "s", M.SCHEMA_VERSION))
    end
  end

  -- File permissions matter as much as content: a world-readable host list
  -- leaks your entire internal topology.
  local open, mode = util.is_world_accessible(p)
  if open then
    util.chmod(p, tonumber("600", 8))
    log.warn(("tightened permissions on %s (was %s, now 0600)"):format(util.contract(p), mode or "?"))
  end

  return state.hosts
end

---@param opts { silent: boolean|nil, reason: string|nil }|nil
---@return boolean ok, string|nil err
function M.save(opts)
  opts = opts or {}
  local p = path()

  -- Another instance may have written since we loaded.
  local current = disk_mtime()
  if state.loaded and state.mtime and current and current > state.mtime then
    log.debug("store changed on disk, merging before write")
    local merged = M.merge_with_disk()
    if merged then
      state.hosts = merged
    end
  end

  local payload = {
    version = M.SCHEMA_VERSION,
    updated_at = util.now(),
    generator = "ssh-launcher.nvim",
    hosts = vim.tbl_map(Host.serialize, state.hosts),
  }

  -- Indented and key-sorted: fleet files live in git, so diffs must be readable.
  local ok, encoded = pcall(util.json_pretty, payload)
  if not ok then
    log.error("failed to encode host database: " .. tostring(encoded))
    return false, tostring(encoded)
  end

  local wok, werr = util.write_file_atomic(p, encoded .. "\n", tonumber("600", 8))
  if not wok then
    log.error(("cannot write %s: %s"):format(util.contract(p), werr or "unknown error"))
    return false, werr
  end

  state.mtime = disk_mtime()
  if not opts.silent then
    emit_change()
  end
  return true, nil
end

--- Re-read the file and merge it with in-memory state, newest `updated_at` wins.
---@return ssh_launcher.Host[]|nil
function M.merge_with_disk()
  local raw = util.read_file(path())
  if not raw then
    return nil
  end
  local decoded = decode(raw)
  if not decoded then
    return nil
  end
  local disk_hosts = migrate(decoded)

  local by_id = {}
  local order = {}
  local function put(h)
    if by_id[h.id] then
      if (h.updated_at or 0) > (by_id[h.id].updated_at or 0) then
        by_id[h.id] = h
      end
    else
      by_id[h.id] = h
      order[#order + 1] = h.id
    end
  end
  for _, h in ipairs(disk_hosts) do
    put(h)
  end
  for _, h in ipairs(state.hosts) do
    put(h)
  end

  local out = {}
  for _, id in ipairs(order) do
    out[#out + 1] = by_id[id]
  end
  return out
end

--------------------------------------------------------------------------------
-- External read-only sources
--------------------------------------------------------------------------------

---@param file string
---@param source string
---@param label string|nil
---@return ssh_launcher.Host[]
local function load_json_source(file, source, label)
  local p = util.expand(file)
  if not util.is_file(p) then
    return {}
  end
  local raw = util.read_file(p)
  if not raw then
    return {}
  end
  local decoded = decode(raw)
  if not decoded then
    log.warn(("ignoring %s: not valid JSON"):format(util.contract(p)))
    return {}
  end
  local hosts = migrate(decoded)
  for _, h in ipairs(hosts) do
    h.source = source
    h.readonly = true
    h.origin = label or util.contract(p)
    h.id = ("%s:%s"):format(source, h.id)
  end
  return hosts
end

--- Hosts contributed by sources the user cannot edit here.
---@param force boolean|nil
---@return ssh_launcher.Host[]
function M.external(force)
  if state.external_loaded and not force then
    return state.external
  end
  local cfg = config.get()
  local out = {}

  for _, src in ipairs(cfg.store.extra_sources or {}) do
    local file = type(src) == "table" and src.path or src
    local name = type(src) == "table" and src.name or nil
    vim.list_extend(out, load_json_source(file, "extra", name))
  end

  if cfg.store.project_file and cfg.store.project_file ~= "" then
    local project = util.join(vim.fn.getcwd(), cfg.store.project_file)
    vim.list_extend(out, load_json_source(project, "project", "project"))
  end

  if cfg.ssh_config.include then
    local ok, sshconfig = pcall(require, "ssh_launcher.sshconfig")
    if ok then
      local hosts = sshconfig.hosts()
      vim.list_extend(out, hosts)
    end
  end

  state.external = out
  state.external_loaded = true
  return out
end

function M.invalidate_external()
  state.external_loaded = false
end

--------------------------------------------------------------------------------
-- Queries
--------------------------------------------------------------------------------

--- Saved (editable) hosts only.
---@return ssh_launcher.Host[]
function M.list()
  return M.load()
end

--- Saved hosts plus every read-only source, de-duplicated by target.
---@param opts { external: boolean|nil }|nil
---@return ssh_launcher.Host[]
function M.all(opts)
  opts = opts or {}
  local include_external = opts.external
  if include_external == nil then
    include_external = true
  end
  local out = vim.deepcopy(M.load())
  if not include_external then
    return out
  end

  local seen = {}
  for _, h in ipairs(out) do
    seen[(Host.target(h)):lower()] = true
  end
  for _, h in ipairs(M.external()) do
    local key = (Host.target(h)):lower()
    if not seen[key] then
      seen[key] = true
      out[#out + 1] = h
    end
  end
  return out
end

---@param id string
---@return ssh_launcher.Host|nil, integer|nil index
function M.get(id)
  for i, h in ipairs(M.load()) do
    if h.id == id then
      return h, i
    end
  end
  for _, h in ipairs(M.external()) do
    if h.id == id then
      return h, nil
    end
  end
  return nil, nil
end

---@param name string
---@return ssh_launcher.Host|nil
function M.get_by_name(name)
  local needle = (name or ""):lower()
  for _, h in ipairs(M.all()) do
    if (h.name or ""):lower() == needle then
      return h
    end
  end
  -- fall back to a unique prefix match, which makes `:Ssh connect prod` work
  local matches = {}
  for _, h in ipairs(M.all()) do
    if (h.name or ""):lower():find(needle, 1, true) == 1 then
      matches[#matches + 1] = h
    end
  end
  return #matches == 1 and matches[1] or nil
end

---@return integer
function M.count()
  return #M.load()
end

--------------------------------------------------------------------------------
-- Mutations
--------------------------------------------------------------------------------

---@param partial table
---@return ssh_launcher.Host|nil host, string|nil err
function M.add(partial)
  local h = Host.normalize(partial)
  h.source = "store"
  h.readonly = nil
  h.created_at = util.now()
  h.updated_at = util.now()

  M.load()
  table.insert(state.hosts, h)
  local ok, err = M.save()
  if not ok then
    table.remove(state.hosts)
    return nil, err
  end
  return h, nil
end

---@param id string
---@param patch table
---@return ssh_launcher.Host|nil host, string|nil err
function M.update(id, patch)
  M.load()
  for i, h in ipairs(state.hosts) do
    if h.id == id then
      local merged = vim.tbl_extend("force", vim.deepcopy(h), patch or {})
      merged.id = id
      local normalized = Host.normalize(merged)
      normalized.source = "store"
      normalized.created_at = h.created_at
      normalized.updated_at = util.now()
      local previous = state.hosts[i]
      state.hosts[i] = normalized
      local ok, err = M.save()
      if not ok then
        state.hosts[i] = previous
        return nil, err
      end
      return normalized, nil
    end
  end
  return nil, ("no saved host with id %s"):format(id)
end

---@param id string
---@return boolean ok, string|nil err
function M.remove(id)
  M.load()
  for i, h in ipairs(state.hosts) do
    if h.id == id then
      local removed = table.remove(state.hosts, i)
      local ok, err = M.save()
      if not ok then
        table.insert(state.hosts, i, removed)
        return false, err
      end
      return true, nil
    end
  end
  return false, ("no saved host with id %s"):format(id)
end

---@param ids string[]
---@return integer removed
function M.remove_many(ids)
  M.load()
  local set = {}
  for _, id in ipairs(ids) do
    set[id] = true
  end
  local kept, removed = {}, 0
  for _, h in ipairs(state.hosts) do
    if set[h.id] then
      removed = removed + 1
    else
      kept[#kept + 1] = h
    end
  end
  if removed > 0 then
    state.hosts = kept
    M.save()
  end
  return removed
end

--- Record a successful connection for frecency ranking.
---@param id string
function M.touch(id)
  M.load()
  for i, h in ipairs(state.hosts) do
    if h.id == id then
      state.hosts[i].last_used_at = util.now()
      state.hosts[i].use_count = (h.use_count or 0) + 1
      M.save({ silent = true })
      return
    end
  end
end

--- Bulk insert with de-duplication against existing targets.
---@param hosts table[]
---@param opts { skip_duplicates: boolean|nil, source_label: string|nil }|nil
---@return integer added, integer skipped
function M.import(hosts, opts)
  opts = opts or {}
  M.load()
  local existing = {}
  for _, h in ipairs(state.hosts) do
    existing[(Host.target(h)):lower()] = true
    existing[(h.name or ""):lower()] = true
  end

  local added, skipped = 0, 0
  for _, raw in ipairs(hosts) do
    local h = Host.normalize(raw)
    h.source = "store"
    h.readonly = nil
    h.id = util.uid()
    local key = (Host.target(h)):lower()
    if opts.skip_duplicates ~= false and (existing[key] or existing[(h.name or ""):lower()]) then
      skipped = skipped + 1
    else
      existing[key] = true
      existing[(h.name or ""):lower()] = true
      table.insert(state.hosts, h)
      added = added + 1
    end
  end

  if added > 0 then
    backup("preimport")
    M.save()
  end
  return added, skipped
end

--- Serialize hosts to the portable export format.
---@param hosts ssh_launcher.Host[]|nil defaults to all saved hosts
---@return string json
function M.export_json(hosts)
  hosts = hosts or M.list()
  local payload = {
    version = M.SCHEMA_VERSION,
    exported_at = util.now(),
    generator = "ssh-launcher.nvim",
    hosts = vim.tbl_map(Host.serialize, hosts),
  }
  return util.json_pretty(payload) .. "\n"
end

--- Order hosts for display.
---@param hosts ssh_launcher.Host[]
---@param mode string|nil
---@return ssh_launcher.Host[]
function M.sorted(hosts, mode)
  mode = mode or config.get().ui.sort
  local out = vim.deepcopy(hosts)

  if mode == "manual" then
    return out
  end

  local comparators = {
    name = function(a, b)
      return (a.name or ""):lower() < (b.name or ""):lower()
    end,
    host = function(a, b)
      return (a.host or ""):lower() < (b.host or ""):lower()
    end,
    recent = function(a, b)
      return (a.last_used_at or 0) > (b.last_used_at or 0)
    end,
  }

  if mode == "frecency" then
    local cfg = config.get().history.frecency
    local now = util.now()
    local half_life = math.max(cfg.half_life_days, 0.1) * 86400
    local function score(h)
      local recency = 0
      if h.last_used_at then
        recency = 0.5 ^ ((now - h.last_used_at) / half_life)
      end
      local frequency = math.log(1 + (h.use_count or 0))
      return recency * cfg.recency_weight + frequency * cfg.frequency_weight
    end
    table.sort(out, function(a, b)
      local sa, sb = score(a), score(b)
      if sa == sb then
        return (a.name or ""):lower() < (b.name or ""):lower()
      end
      return sa > sb
    end)
    return out
  end

  local cmp = comparators[mode]
  if cmp then
    table.sort(out, cmp)
  end
  return out
end

--- Drop all in-memory state (tests, `:Ssh reload`).
function M.reset()
  state.hosts = {}
  state.mtime = nil
  state.loaded = false
  state.external = {}
  state.external_loaded = false
end

return M
