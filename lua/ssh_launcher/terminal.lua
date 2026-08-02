---@mod ssh_launcher.terminal Terminal process hosting
---
--- Runs an argv list in a Neovim terminal using the placement the user asked
--- for. The argument list is passed through verbatim — there is no shell in the
--- path, so no quoting bug can turn a hostname into a command.

local util = require("ssh_launcher.util")
local log = require("ssh_launcher.log")
local config = require("ssh_launcher.config")
local theme = require("ssh_launcher.ui.theme")
local float = require("ssh_launcher.ui.float")

local M = {}

---@class ssh_launcher.TerminalHandle
---@field buf integer
---@field win integer|nil
---@field job integer|nil
---@field float ssh_launcher.Float|nil
---@field argv string[]
---@field title string
---@field started_at integer
---@field exit_code integer|nil

--- Signals reported by a job as `128 + signum`. Without this a user who closed
--- a window sees "exited with status 129", which reads like a failure.
local SIGNALS = {
  [1] = { name = "SIGHUP", why = "the connection was hung up" },
  [2] = { name = "SIGINT", why = "interrupted" },
  [3] = { name = "SIGQUIT", why = "quit" },
  [9] = { name = "SIGKILL", why = "killed" },
  [13] = { name = "SIGPIPE", why = "the connection broke" },
  [15] = { name = "SIGTERM", why = "terminated" },
}

--- Plain-English rendering of a process exit status.
---@param code integer
---@return string
function M.describe_exit(code)
  if code == 0 then
    return "finished"
  end
  if code > 128 and code < 160 then
    local sig = SIGNALS[code - 128]
    if sig then
      return ("%s (%s)"):format(sig.why, sig.name)
    end
    return ("killed by signal %d"):format(code - 128)
  end
  if code == 255 then
    return "ssh could not establish the connection"
  end
  return ("exited with status %d"):format(code)
end

---@param argv string[]
---@param opts table
---@return integer job
local function spawn(buf, argv, opts)
  local job
  vim.api.nvim_buf_call(buf, function()
    local job_opts = {
      env = opts.env,
      cwd = opts.cwd,
      on_exit = opts.on_exit,
    }
    if vim.fn.has("nvim-0.11") == 1 then
      job_opts.term = true
      job = vim.fn.jobstart(argv, job_opts)
    else
      ---@diagnostic disable-next-line: deprecated
      job = vim.fn.termopen(argv, job_opts)
    end
  end)
  return job
end

---@param opts table
---@return integer buf, ssh_launcher.Float|nil
local function make_window(opts)
  local strategy = opts.strategy or config.get().terminal.strategy
  local buf = vim.api.nvim_create_buf(true, false)
  vim.bo[buf].bufhidden = "hide"

  if strategy == "float" then
    local fcfg = config.get().terminal.float
    local win = float.open({
      buf = buf,
      title = opts.title,
      footer = "i insert  <C-\\><C-n> normal  q close",
      width = opts.width or fcfg.width,
      height = opts.height or fcfg.height,
      border = fcfg.border,
      modifiable = true,
      cursorline = false,
      close_keys = false,
      enter = true,
    })
    return buf, win
  end

  if strategy == "tab" then
    vim.cmd("tabnew")
  elseif strategy == "vsplit" then
    vim.cmd("vsplit")
  elseif strategy == "split" then
    vim.cmd(("botright %dsplit"):format(opts.height or math.floor(vim.o.lines * 0.4)))
  elseif strategy ~= "current" then
    vim.cmd("tabnew")
  end

  -- `tabnew`/`split` create an empty [No Name] buffer that we immediately
  -- replace; without this it lingers in the buffer list forever.
  local placeholder = vim.api.nvim_get_current_buf()
  vim.api.nvim_win_set_buf(0, buf)
  if placeholder ~= buf and vim.api.nvim_buf_is_valid(placeholder) then
    local empty = vim.api.nvim_buf_get_name(placeholder) == ""
      and not vim.bo[placeholder].modified
      and vim.api.nvim_buf_line_count(placeholder) <= 1
      and (vim.api.nvim_buf_get_lines(placeholder, 0, 1, false)[1] or "") == ""
    if empty then
      pcall(vim.api.nvim_buf_delete, placeholder, { force = false })
    end
  end

  return buf, nil
end

--- Run a command inside tmux instead of Neovim, when the user lives there.
---@param argv string[]
---@param opts table
---@return boolean handled
local function run_in_tmux(argv, opts)
  if util.blank(vim.env.TMUX) or not util.has_executable("tmux") then
    return false
  end
  local cmd = { "tmux", "new-window" }
  if opts.title then
    cmd[#cmd + 1] = "-n"
    cmd[#cmd + 1] = (opts.title:gsub("%s+", "-"))
  end
  vim.list_extend(cmd, argv)
  util.system(cmd, { timeout = 5000 }, function(res)
    if not res.ok then
      log.error(("tmux new-window failed: %s"):format(util.nonblank(res.stderr) or res.code))
    end
  end)
  return true
end

---@class ssh_launcher.TerminalOpts
---@field title string|nil
---@field strategy string|nil
---@field height number|nil
---@field width number|nil
---@field env table|nil
---@field cwd string|nil
---@field start_insert boolean|nil
---@field close_on_exit boolean|nil
---@field on_exit fun(code: integer, handle: ssh_launcher.TerminalHandle)|nil

--- Run `argv` in a terminal.
---@param argv string[]
---@param opts ssh_launcher.TerminalOpts|nil
---@return ssh_launcher.TerminalHandle|nil
function M.run(argv, opts)
  opts = opts or {}
  local cfg = config.get()

  if not argv or #argv == 0 then
    log.error("nothing to run")
    return nil
  end

  local exe = argv[1]
  if not util.has_executable(exe) then
    log.error(("%s is not installed or not on $PATH"):format(exe))
    return nil
  end

  local strategy = opts.strategy or cfg.terminal.strategy
  if strategy == "tmux" then
    if run_in_tmux(argv, opts) then
      return nil
    end
    strategy = "tab"
    log.debug("not inside tmux; falling back to a tab")
  end

  ---@type ssh_launcher.TerminalHandle
  local handle = {
    buf = -1,
    argv = argv,
    title = opts.title or util.basename(exe),
    started_at = util.now(),
  }

  local buf, win = make_window(vim.tbl_extend("force", opts, { strategy = strategy }))
  handle.buf = buf
  handle.float = win
  handle.win = win and win.win or vim.api.nvim_get_current_win()

  local close_on_exit = opts.close_on_exit
  if close_on_exit == nil then
    close_on_exit = cfg.terminal.close_on_exit
  end

  handle.job = spawn(buf, argv, {
    env = opts.env,
    cwd = opts.cwd,
    on_exit = function(_, code)
      handle.exit_code = code
      vim.schedule(function()
        if opts.on_exit then
          pcall(opts.on_exit, code, handle)
        end
        if vim.api.nvim_buf_is_valid(buf) then
          -- After the process is gone the buffer is a transcript. Make `q`
          -- close it so a dead session never traps the user.
          pcall(vim.keymap.set, "n", "q", function()
            M.close(handle)
          end, { buffer = buf, nowait = true, desc = "ssh-launcher: close session" })
        end
        if close_on_exit and code == 0 then
          M.close(handle)
        elseif cfg.terminal.notify_on_exit and code ~= 0 and not handle.closing then
          -- Only report an exit the user did not ask for. Closing the window
          -- kills the job with SIGHUP, and announcing that as a failure — with
          -- advice to press `q` in a window that no longer exists — is noise.
          local hint = vim.api.nvim_buf_is_valid(buf) and " — press q to close the window" or ""
          log.warn(("%s %s%s"):format(handle.title, M.describe_exit(code), hint))
        end
      end)
    end,
  })

  if not handle.job or handle.job <= 0 then
    log.error(("could not start %s"):format(exe))
    return nil
  end

  vim.b[buf].ssh_launcher_title = handle.title
  pcall(vim.api.nvim_buf_set_name, buf, ("ssh-launcher://%s/%d"):format(handle.title:gsub("/", "-"), handle.job))

  for key, value in pairs(cfg.terminal.buf_options or {}) do
    pcall(function()
      vim.bo[buf][key] = value
    end)
  end
  if handle.win and vim.api.nvim_win_is_valid(handle.win) then
    for key, value in pairs(cfg.terminal.win_options or {}) do
      pcall(function()
        vim.wo[handle.win][key] = value
      end)
    end
    pcall(function()
      vim.wo[handle.win].winhighlight = "Normal:" .. theme.hl("Normal")
    end)
  end

  local start_insert = opts.start_insert
  if start_insert == nil then
    start_insert = cfg.terminal.start_insert
  end
  if start_insert then
    vim.schedule(function()
      if vim.api.nvim_get_current_buf() == buf then
        vim.cmd("startinsert")
      end
    end)
  end

  log.announce(("started %s"):format(handle.title))
  return handle
end

---@param handle ssh_launcher.TerminalHandle
function M.close(handle)
  if not handle then
    return
  end
  -- Deleting the buffer sends SIGHUP to the job; flag it so the resulting
  -- non-zero status is not reported back as a failure.
  handle.closing = true
  if handle.float then
    handle.float:close()
  end
  if handle.buf and vim.api.nvim_buf_is_valid(handle.buf) then
    pcall(vim.api.nvim_buf_delete, handle.buf, { force = true })
  end
end

---@param handle ssh_launcher.TerminalHandle
---@return boolean
function M.is_running(handle)
  if not handle or not handle.job then
    return false
  end
  if handle.exit_code ~= nil then
    return false
  end
  return vim.fn.jobwait({ handle.job }, 0)[1] == -1
end

--- Bring an existing session's buffer back on screen.
---@param handle ssh_launcher.TerminalHandle
---@param strategy string|nil
function M.focus(handle, strategy)
  if not handle or not vim.api.nvim_buf_is_valid(handle.buf) then
    return false
  end

  -- Already visible somewhere? Just go there.
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_buf(win) == handle.buf then
      vim.api.nvim_set_current_win(win)
      return true
    end
  end

  strategy = strategy or config.get().terminal.strategy
  if strategy == "float" then
    local fcfg = config.get().terminal.float
    handle.float = float.open({
      buf = handle.buf,
      title = handle.title,
      width = fcfg.width,
      height = fcfg.height,
      border = fcfg.border,
      modifiable = true,
      cursorline = false,
      close_keys = false,
      enter = true,
    })
    handle.win = handle.float.win
  else
    if strategy == "tab" then
      vim.cmd("tabnew")
    elseif strategy == "vsplit" then
      vim.cmd("vsplit")
    elseif strategy == "split" then
      vim.cmd("split")
    end
    vim.api.nvim_win_set_buf(0, handle.buf)
    handle.win = vim.api.nvim_get_current_win()
  end
  return true
end

return M
