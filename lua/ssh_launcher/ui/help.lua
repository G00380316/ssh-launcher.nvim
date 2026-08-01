---@mod ssh_launcher.ui.help Keymap reference
---
--- Discoverability without documentation: every window answers `?`.

local util = require("ssh_launcher.util")
local config = require("ssh_launcher.config")
local theme = require("ssh_launcher.ui.theme")
local float = require("ssh_launcher.ui.float")
local render = require("ssh_launcher.ui.render")

local M = {}

local ns = vim.api.nvim_create_namespace("ssh_launcher_help")

---@param name string
---@return string
local function keys_for(name)
  local value = config.keymap(name)
  if value == false or value == nil then
    return "—"
  end
  if type(value) == "table" then
    return table.concat(value, " / ")
  end
  return value
end

---@type table<string, { title: string, sections: { title: string, items: { [1]: string, [2]: string }[] }[] }>
local SPECS = {
  manager = {
    title = "ssh-launcher — host manager",
    sections = {
      {
        title = "Connect",
        items = {
          { keys_for("connect"), "Open a session" },
          { keys_for("connect_split"), "Open in a horizontal split" },
          { keys_for("connect_vsplit"), "Open in a vertical split" },
          { keys_for("connect_tab"), "Open in a new tab" },
          { keys_for("sessions"), "Jump to a running session" },
          { keys_for("yank_command"), "Copy the resolved ssh command" },
        },
      },
      {
        title = "Manage hosts",
        items = {
          { keys_for("add"), "Add a host (empty form)" },
          { keys_for("paste_add"), "Add from the clipboard or pasted text" },
          { keys_for("edit"), "Edit the host under the cursor" },
          { keys_for("duplicate"), "Duplicate it" },
          { keys_for("rename"), "Rename it" },
          { keys_for("delete"), "Delete it (or every marked host)" },
          { keys_for("toggle_mark"), "Mark / unmark for bulk actions" },
          { keys_for("clear_marks"), "Clear all marks" },
        },
      },
      {
        title = "Diagnose and repair",
        items = {
          { keys_for("diagnose"), "Show every problem (1-9 there applies one fix)" },
          { keys_for("fix"), "Apply every safe fix to this host or the marked ones" },
          { keys_for("probe"), "Re-check reachability now" },
          { keys_for("agent"), "ssh-agent: list, add, remove keys" },
          { keys_for("copy_id"), "Install your public key on the remote" },
          { keys_for("keygen"), "Generate a new key pair" },
        },
      },
      {
        title = "View",
        items = {
          { keys_for("filter"), "Filter as you type" },
          { keys_for("clear_filter"), "Clear the filter" },
          { keys_for("sort"), "Change the sort order" },
          { keys_for("refresh"), "Reload from disk" },
          { keys_for("import"), "Import from ~/.ssh/config or a file" },
          { keys_for("export"), "Export to ~/.ssh/config or JSON" },
          { keys_for("open_terminal"), "Plain terminal in the current window" },
          { keys_for("help"), "This help" },
          { keys_for("quit"), "Close" },
        },
      },
    },
  },
  form = {
    title = "ssh-launcher — host editor",
    sections = {
      {
        title = "Editing",
        items = {
          { "<Tab> / <S-Tab>", "Move between fields" },
          { "<CR>", "Start editing the field under the cursor" },
          { "Paste line", "Drop an ssh command, URL or config block; fields fill in" },
          { "<C-g>", "Pull a connection out of the clipboard" },
          { "<C-k>", "Choose from the private keys found in ~/.ssh" },
        },
      },
      {
        title = "Validation",
        items = {
          { "<C-d>", "Explain the problem on this line" },
          { "]d / [d", "Next / previous problem (standard diagnostics)" },
          { "<C-f>", "Apply every automatic fix" },
          { "gx", "Show the exact ssh command that will run" },
        },
      },
      {
        title = "Finishing",
        items = {
          { "<C-s> / :w", "Save" },
          { "<C-a>", "Save and connect" },
          { "q", "Close (asks about unsaved changes)" },
          { "<C-c>", "Close, discarding changes" },
        },
      },
    },
  },
}

---@param context string
function M.show(context)
  local spec = SPECS[context] or SPECS.manager
  local lines = {}
  local width = 0

  local key_width = 0
  for _, section in ipairs(spec.sections) do
    for _, item in ipairs(section.items) do
      key_width = math.max(key_width, util.width(item[1]))
    end
  end
  key_width = math.min(key_width, 22)

  for si, section in ipairs(spec.sections) do
    if si > 1 then
      lines[#lines + 1] = { { "" } }
    end
    lines[#lines + 1] = { { section.title, theme.hl("Section") } }
    for _, item in ipairs(section.items) do
      local key = util.fit(item[1], key_width, "right")
      lines[#lines + 1] = {
        { "  " .. key, theme.hl("KeyHint") },
        { "  " .. item[2], theme.hl("Value") },
      }
      width = math.max(width, key_width + util.width(item[2]) + 4)
    end
  end

  lines[#lines + 1] = { { "" } }
  lines[#lines + 1] = { { "  Every key above is configurable via setup({ keymaps = { … } }).", theme.hl("Muted") } }

  local win = float.open({
    title = spec.title,
    footer = "q close",
    width = math.min(math.max(width + 6, 52), math.floor(vim.o.columns * 0.9)),
    height = math.min(#lines + 2, math.floor(vim.o.lines * 0.85)),
    cursorline = false,
  })
  render.draw(win.buf, ns, lines)
  return win
end

return M
