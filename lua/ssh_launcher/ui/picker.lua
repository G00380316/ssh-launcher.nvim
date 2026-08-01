---@mod ssh_launcher.ui.picker Fuzzy picker integrations
---
--- The built-in manager is the default because it can do things a generic
--- picker cannot (diagnostics, marks, repairs). But plenty of people live in
--- Telescope, fzf-lua or snacks.nvim, so those are first-class too.

local util = require("ssh_launcher.util")
local log = require("ssh_launcher.log")
local config = require("ssh_launcher.config")
local Host = require("ssh_launcher.host")
local store = require("ssh_launcher.store")
local diagnostics = require("ssh_launcher.diagnostics")
local theme = require("ssh_launcher.ui.theme")

local M = {}

---@param h ssh_launcher.Host
---@return string
local function display(h)
  local issues = diagnostics.check(h)
  local worst = diagnostics.worst(issues)
  local marker = ""
  if worst == "error" then
    marker = theme.icon("error") .. " "
  elseif worst == "warn" then
    marker = theme.icon("warn") .. " "
  end
  local tags = (h.tags and #h.tags > 0) and ("  [" .. table.concat(h.tags, ",") .. "]") or ""
  return ("%s%s  %s%s"):format(marker, util.fit(Host.label(h), 28), Host.target(h), tags)
end

---@return ssh_launcher.Host[]
local function hosts()
  return store.sorted(store.all(), config.get().ui.sort)
end

---@param cb fun(h: ssh_launcher.Host)
local function with_select(cb)
  local list = hosts()
  if #list == 0 then
    return log.warn("no hosts saved — run :Ssh add")
  end
  vim.ui.select(list, {
    prompt = "SSH host",
    format_item = display,
  }, function(choice)
    if choice then
      cb(choice)
    end
  end)
end

---@param cb fun(h: ssh_launcher.Host)
---@return boolean available
local function with_telescope(cb)
  local ok, pickers = pcall(require, "telescope.pickers")
  if not ok then
    return false
  end
  local finders = require("telescope.finders")
  local conf = require("telescope.config").values
  local actions = require("telescope.actions")
  local action_state = require("telescope.actions.state")
  local previewers = require("telescope.previewers")

  pickers
    .new({}, {
      prompt_title = "SSH hosts",
      finder = finders.new_table({
        results = hosts(),
        entry_maker = function(h)
          return {
            value = h,
            display = display(h),
            ordinal = Host.search_text(h),
          }
        end,
      }),
      sorter = conf.generic_sorter({}),
      previewer = previewers.new_buffer_previewer({
        title = "Host",
        define_preview = function(self, entry)
          local h = entry.value
          local lines = {
            ("Name    %s"):format(Host.label(h)),
            ("Target  %s"):format(Host.target(h)),
            ("Key     %s"):format(h.identity_file and util.contract(h.identity_file) or "ssh-agent"),
            ("Source  %s"):format(h.origin or h.source),
            "",
            "$ " .. Host.command_string(h),
            "",
          }
          for _, issue in ipairs(diagnostics.check(h)) do
            lines[#lines + 1] = ("%s: %s (%s)"):format(issue.severity, issue.message, issue.code)
          end
          vim.api.nvim_buf_set_lines(self.state.bufnr, 0, -1, false, lines)
        end,
      }),
      attach_mappings = function(bufnr)
        actions.select_default:replace(function()
          local entry = action_state.get_selected_entry()
          actions.close(bufnr)
          if entry then
            cb(entry.value)
          end
        end)
        return true
      end,
    })
    :find()
  return true
end

---@param cb fun(h: ssh_launcher.Host)
---@return boolean available
local function with_fzf_lua(cb)
  local ok, fzf = pcall(require, "fzf-lua")
  if not ok then
    return false
  end
  local list = hosts()
  local by_display = {}
  local entries = {}
  for _, h in ipairs(list) do
    local text = display(h)
    by_display[text] = h
    entries[#entries + 1] = text
  end
  fzf.fzf_exec(entries, {
    prompt = "SSH hosts> ",
    actions = {
      ["default"] = function(selected)
        local h = selected and by_display[selected[1]]
        if h then
          cb(h)
        end
      end,
    },
  })
  return true
end

---@param cb fun(h: ssh_launcher.Host)
---@return boolean available
local function with_snacks(cb)
  local ok, snacks = pcall(require, "snacks")
  if not ok or not snacks.picker then
    return false
  end
  local items = {}
  for _, h in ipairs(hosts()) do
    items[#items + 1] = { text = display(h), host = h }
  end
  snacks.picker.pick({
    title = "SSH hosts",
    items = items,
    format = function(item)
      return { { item.text } }
    end,
    confirm = function(picker, item)
      picker:close()
      if item then
        cb(item.host)
      end
    end,
  })
  return true
end

--- Pick a host with whatever UI is configured, then call `cb`.
---@param cb fun(h: ssh_launcher.Host)|nil defaults to connecting
---@param opts { picker: string|nil }|nil
function M.pick(cb, opts)
  opts = opts or {}
  -- A caller that passed its own callback wants a *value* back, which the
  -- manager cannot provide: it is a whole application, not a selection widget.
  local wants_value = cb ~= nil
  cb = cb or function(h)
    require("ssh_launcher.connect").connect(h)
  end

  local which = opts.picker or config.get().ui.picker

  if which == "manager" then
    if not wants_value then
      return require("ssh_launcher.ui.manager").open()
    end
    which = "auto"
  end

  local providers = {
    telescope = with_telescope,
    ["fzf-lua"] = with_fzf_lua,
    snacks = with_snacks,
  }

  if which == "auto" then
    for _, name in ipairs({ "telescope", "fzf-lua", "snacks" }) do
      if providers[name](cb) then
        return
      end
    end
    return with_select(cb)
  end

  local provider = providers[which]
  if provider then
    if provider(cb) then
      return
    end
    log.warn(("%s is not installed; falling back to vim.ui.select"):format(which))
  end
  return with_select(cb)
end

--- Telescope extension entry point (`:Telescope ssh_launcher`).
function M.telescope()
  local available = with_telescope(function(h)
    require("ssh_launcher.connect").connect(h)
  end)
  if not available then
    log.error("telescope.nvim is not installed")
  end
end

return M
