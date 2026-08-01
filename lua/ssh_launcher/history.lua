---@mod ssh_launcher.history Connection log
---
--- An append-only record of connection attempts. It powers the "last used"
--- column, the frecency sort, and answering "when did this host last work?"
--- without leaving the editor.
---
--- Only metadata is recorded — never command output, never anything typed into
--- a session.

local util = require("ssh_launcher.util")
local config = require("ssh_launcher.config")

local M = {}

---@class ssh_launcher.HistoryEntry
---@field at integer unix time
---@field host_id string
---@field name string
---@field target string
---@field outcome "started"|"closed"|"failed"
---@field exit_code integer|nil
---@field duration integer|nil seconds

---@type ssh_launcher.HistoryEntry[]|nil
local entries = nil

---@return string
local function path()
  local cfg = config.get()
  return util.join(util.expand(cfg.store.state_dir), "history.json")
end

---@return ssh_launcher.HistoryEntry[]
function M.load()
  if entries then
    return entries
  end
  entries = {}
  local raw = util.read_file(path())
  if raw and util.trim(raw) ~= "" then
    local ok, decoded = pcall(vim.json.decode, raw, { luanil = { object = true, array = true } })
    if ok and util.is_list(decoded) then
      entries = decoded
    end
  end
  return entries
end

local flush = nil

local function persist()
  if not config.get().history.enable then
    return
  end
  flush = flush or util.debounce(function()
    local cfg = config.get()
    local list = M.load()
    local max = cfg.history.max_entries or 1000
    if #list > max then
      list = vim.list_slice(list, #list - max + 1, #list)
      entries = list
    end
    util.write_file_atomic(path(), util.json_pretty(list) .. "\n", tonumber("600", 8))
  end, 500)
  flush()
end

---@param entry ssh_launcher.HistoryEntry
function M.record(entry)
  if not config.get().history.enable then
    return
  end
  local list = M.load()
  entry.at = entry.at or util.now()
  list[#list + 1] = entry
  persist()
end

--- Entries for one host, newest first.
---@param host_id string
---@param limit integer|nil
---@return ssh_launcher.HistoryEntry[]
function M.for_host(host_id, limit)
  local out = {}
  local list = M.load()
  for i = #list, 1, -1 do
    if list[i].host_id == host_id then
      out[#out + 1] = list[i]
      if limit and #out >= limit then
        break
      end
    end
  end
  return out
end

---@param limit integer|nil
---@return ssh_launcher.HistoryEntry[]
function M.recent(limit)
  local out = {}
  local list = M.load()
  for i = #list, 1, -1 do
    out[#out + 1] = list[i]
    if limit and #out >= limit then
      break
    end
  end
  return out
end

function M.clear()
  entries = {}
  util.write_file_atomic(path(), "[]\n", tonumber("600", 8))
end

return M
