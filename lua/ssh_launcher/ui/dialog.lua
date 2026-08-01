---@mod ssh_launcher.ui.dialog Confirmations and choices
---
--- A keyboard-first modal. Every choice is reachable three ways — cursor plus
--- `<CR>`, its number, or its mnemonic letter — and the whole thing is plain
--- buffer text so a screen reader reads it like any other window.

local util = require("ssh_launcher.util")
local theme = require("ssh_launcher.ui.theme")
local float = require("ssh_launcher.ui.float")
local render = require("ssh_launcher.ui.render")
local log = require("ssh_launcher.log")

local M = {}

local ns = vim.api.nvim_create_namespace("ssh_launcher_dialog")

---@class ssh_launcher.Choice
---@field label string
---@field value any
---@field key string|nil mnemonic
---@field desc string|nil
---@field destructive boolean|nil

---@class ssh_launcher.DialogOpts
---@field title string
---@field lines (string|ssh_launcher.Line)[]|nil body text
---@field choices ssh_launcher.Choice[]
---@field default integer|nil
---@field on_choice fun(value: any, index: integer|nil)
---@field width number|nil

--- Show a modal choice dialog.
---@param opts ssh_launcher.DialogOpts
function M.choose(opts)
  local choices = opts.choices or {}
  if #choices == 0 then
    return opts.on_choice(nil, nil)
  end

  local body = {}
  for _, line in ipairs(opts.lines or {}) do
    if type(line) == "string" then
      body[#body + 1] = { { line } }
    else
      body[#body + 1] = line
    end
  end

  local selected = math.max(1, math.min(opts.default or 1, #choices))
  local first_choice_row = #body + 2 -- 1-indexed, after body + blank line
  local answered = false

  local width = opts.width or 0
  for _, line in ipairs(body) do
    local text = render.flatten(line)
    width = math.max(width, util.width(text))
  end
  for i, choice in ipairs(choices) do
    width = math.max(width, util.width(("  %d. %s  %s"):format(i, choice.label, choice.desc or "")))
  end
  width = math.min(math.max(width + 4, 44), math.floor(vim.o.columns * 0.9))

  local win
  local function draw()
    local lines = {}
    vim.list_extend(lines, body)
    lines[#lines + 1] = { { "" } }
    for i, choice in ipairs(choices) do
      local active = i == selected
      -- The marker is text, not a colour: `>` means "this is the one".
      local marker = active and (theme.icon("arrow") .. " ") or "  "
      local key = choice.key or tostring(i)
      local hl = choice.destructive and theme.hl("Error") or theme.hl("Value")
      lines[#lines + 1] = {
        { marker, theme.hl("KeyHint") },
        { ("[%s] "):format(key), theme.hl("KeyHint") },
        { choice.label, active and theme.hl("Name") or hl },
        choice.desc and { "  " .. choice.desc, theme.hl("Muted") } or { "" },
      }
    end
    lines[#lines + 1] = { { "" } }
    lines[#lines + 1] = {
      { "  j/k move  ", theme.hl("Muted") },
      { "<CR> choose  ", theme.hl("Muted") },
      { "<Esc> cancel", theme.hl("Muted") },
    }
    render.draw(win.buf, ns, lines)
    win:set_cursor(first_choice_row + selected - 1)
  end

  local function answer(index)
    if answered then
      return
    end
    answered = true
    local choice = index and choices[index] or nil
    win:close()
    vim.schedule(function()
      opts.on_choice(choice and choice.value or nil, index)
    end)
  end

  win = float.open({
    title = opts.title,
    width = width,
    height = #body + #choices + 4,
    cursorline = false,
    close_keys = false,
    on_close = function()
      if not answered then
        answered = true
        vim.schedule(function()
          opts.on_choice(nil, nil)
        end)
      end
    end,
  })

  vim.bo[win.buf].filetype = "ssh-launcher-dialog"

  win:map("n", { "j", "<Down>", "<Tab>" }, function()
    selected = selected % #choices + 1
    draw()
  end, "Next choice")

  win:map("n", { "k", "<Up>", "<S-Tab>" }, function()
    selected = (selected - 2) % #choices + 1
    draw()
  end, "Previous choice")

  win:map("n", { "<CR>", "<Space>" }, function()
    answer(selected)
  end, "Confirm")

  win:map("n", { "q", "<Esc>", "<C-c>" }, function()
    answer(nil)
  end, "Cancel")

  for i, choice in ipairs(choices) do
    win:map("n", tostring(i), function()
      answer(i)
    end, choice.label)
    if choice.key then
      win:map("n", choice.key, function()
        answer(i)
      end, choice.label)
    end
  end

  draw()
  log.announce(("%s — %d options, use j/k and Enter"):format(opts.title, #choices))
end

--- Yes/no shorthand.
---@param opts { title: string, lines: (string|ssh_launcher.Line)[]|nil, yes: string|nil, no: string|nil, destructive: boolean|nil, default_no: boolean|nil }
---@param cb fun(confirmed: boolean)
function M.confirm(opts, cb)
  M.choose({
    title = opts.title,
    lines = opts.lines,
    default = opts.default_no and 2 or 1,
    choices = {
      { label = opts.yes or "Yes", value = true, key = "y", destructive = opts.destructive },
      { label = opts.no or "Cancel", value = false, key = "n" },
    },
    on_choice = function(value)
      cb(value == true)
    end,
  })
end

--- Single-line input. Delegates to `vim.ui.input` so it inherits whatever input
--- UI the user has configured (including accessible ones).
---@param opts { prompt: string, default: string|nil, completion: string|nil }
---@param cb fun(value: string|nil)
function M.input(opts, cb)
  vim.ui.input({
    prompt = opts.prompt,
    default = opts.default,
    completion = opts.completion,
  }, function(value)
    cb(util.nonblank(value))
  end)
end

return M
