---@mod ssh_launcher.ui.theme Highlights and glyphs
---
--- Two accessibility rules drive this module:
---
--- 1. Every highlight *links* to a standard group, so the plugin inherits the
---    user's colourscheme (and their contrast tuning) instead of hard-coding
---    colours that may be invisible in their theme.
--- 2. Colour is never the only signal. Each status also has a glyph and a word,
---    and `a11y.ascii` swaps every glyph for plain ASCII.

local config = require("ssh_launcher.config")

local M = {}

M.PREFIX = "SshLauncher"

--- group -> default link
M.LINKS = {
  Normal = "NormalFloat",
  Border = "FloatBorder",
  Title = "Title",
  Header = "Title",
  Name = "Function",
  Target = "String",
  Key = "Constant",
  Tag = "Type",
  Muted = "Comment",
  Footer = "Comment",
  KeyHint = "Special",
  Match = "IncSearch",
  Selected = "Visual",
  Marked = "DiffAdd",
  Ok = "DiagnosticOk",
  Error = "DiagnosticError",
  Warn = "DiagnosticWarn",
  Info = "DiagnosticInfo",
  Hint = "DiagnosticHint",
  Production = "DiagnosticWarn",
  ReadOnly = "Comment",
  Label = "Label",
  Value = "Normal",
  Section = "Title",
  Cursor = "CursorLine",
  Prompt = "Question",
  Count = "Number",
}

local ICONS = {
  nerd = {
    up = "",
    down = "",
    unknown = "",
    checking = "",
    key = "",
    tag = "",
    production = "",
    error = "",
    warn = "",
    info = "",
    hint = "",
    ok = "",
    jump = "",
    terminal = "",
    search = "",
    marked = "",
    unmarked = "",
    readonly = "",
    forward = "",
    session = "",
    arrow = "→",
    bullet = "•",
  },
  ascii = {
    up = "+",
    down = "x",
    unknown = "?",
    checking = "~",
    key = "K",
    tag = "#",
    production = "!",
    error = "E",
    warn = "W",
    info = "i",
    hint = "h",
    ok = "v",
    jump = ">",
    terminal = "$",
    search = "/",
    marked = "[x]",
    unmarked = "[ ]",
    readonly = "R",
    forward = "L",
    session = "*",
    arrow = "->",
    bullet = "-",
  },
}

--- Words paired with every glyph. Screen readers get these, not the glyph.
M.WORDS = {
  up = "reachable",
  down = "unreachable",
  unknown = "unchecked",
  checking = "checking",
  error = "error",
  warn = "warning",
  info = "info",
  hint = "hint",
  ok = "ok",
  production = "production",
  readonly = "read-only",
}

---@param name string
---@return string
function M.hl(name)
  return M.PREFIX .. name
end

---@param name string
---@return string
function M.icon(name)
  local set = config.use_icons() and ICONS.nerd or ICONS.ascii
  return set[name] or ICONS.ascii[name] or "?"
end

--- Glyph plus, when text markers are enabled, nothing extra — the *word* is
--- exposed separately via |ssh_launcher.ui.theme.word| so callers can place it
--- where it reads best.
---@param name string
---@return string
function M.word(name)
  return M.WORDS[name] or name
end

M.SEVERITY_HL = {
  error = "Error",
  warn = "Warn",
  info = "Info",
  hint = "Hint",
}

M.SEVERITY_ICON = {
  error = "error",
  warn = "warn",
  info = "info",
  hint = "hint",
}

M.STATUS_HL = {
  up = "Ok",
  refused = "Error",
  timeout = "Warn",
  dns = "Error",
  error = "Error",
  unknown = "Muted",
  checking = "Muted",
}

M.STATUS_ICON = {
  up = "up",
  refused = "down",
  timeout = "unknown",
  dns = "down",
  error = "down",
  unknown = "unknown",
  checking = "checking",
}

--- Define (or redefine) every highlight group. Idempotent and safe to call from
--- a ColorScheme autocommand.
function M.apply()
  local cfg = config.get()
  for name, link in pairs(M.LINKS) do
    local group = M.hl(name)
    -- `default = true` means a user's own definition always wins.
    vim.api.nvim_set_hl(0, group, { link = link, default = true })
  end

  if cfg.a11y.high_contrast then
    -- Reinforce meaning with weight and underline so the display survives
    -- monochrome terminals and low-vision colour settings.
    local emphatic = {
      Error = { bold = true, underline = true },
      Warn = { bold = true },
      Production = { bold = true, underline = true },
      Name = { bold = true },
      Header = { bold = true, underline = true },
      Match = { bold = true, underline = true },
      Selected = { bold = true, reverse = true },
    }
    for name, attrs in pairs(emphatic) do
      local group = M.hl(name)
      local existing = vim.api.nvim_get_hl(0, { name = group, link = false }) or {}
      local merged = vim.tbl_extend("force", existing, attrs)
      merged.link = nil
      vim.api.nvim_set_hl(0, group, merged)
    end
  end

  -- DiagnosticOk only exists in newer Neovim releases and some themes skip it.
  if vim.tbl_isempty(vim.api.nvim_get_hl(0, { name = "DiagnosticOk" }) or {}) then
    vim.api.nvim_set_hl(0, M.hl("Ok"), { link = "String", default = true })
  end
end

local group_id = nil

--- Install the ColorScheme hook once.
function M.setup()
  M.apply()
  if group_id then
    return
  end
  group_id = vim.api.nvim_create_augroup("SshLauncherTheme", { clear = true })
  vim.api.nvim_create_autocmd("ColorScheme", {
    group = group_id,
    desc = "Re-link ssh-launcher highlights after a colourscheme change",
    callback = function()
      M.apply()
    end,
  })
end

--- Border style honouring `vim.o.winborder` when the user set one globally.
---@param override string|nil
---@return string|string[]
function M.border(override)
  local border = override or config.get().ui.border
  if border == "auto" then
    local global = vim.o.winborder
    if global and global ~= "" then
      return global
    end
    return "rounded"
  end
  return border
end

return M
