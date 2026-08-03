---@mod ssh_launcher.terminal Terminal process hosting
---
--- Runs an argv list in a Neovim terminal using the placement the user asked
--- for. The argument list is passed through verbatim — there is no shell in the
--- path, so no quoting bug can turn a hostname into a command.

local util = require("ssh_launcher.util")

local uv = util.uv
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

--- Did this session end because its window went away, rather than because
--- anything went wrong?
---
--- SIGHUP reaches a local `ssh` when its pty is destroyed, and the only thing
--- that destroys the pty is the terminal buffer being closed. A remote-side
--- problem never arrives this way — ssh reports those by exiting 255. So a
--- hangup is local teardown by definition, and is never news.
---@param handle ssh_launcher.TerminalHandle
---@param code integer
---@return boolean
function M.was_torn_down(handle, code)
  -- Deliberately *not* keyed on `handle.closing`: a TermClose handler that
  -- deletes the buffer sets that flag after ssh has already failed on its own,
  -- and suppressing the report then would hide the very error the user needs.
  -- A teardown that caused the exit always shows up as SIGHUP.
  return code == 129 or handle.closed_by_us == true
end

--- A live session was destroyed by something other than the user. Report it
--- once, remember the environment, and let the caller reconnect.
---@param handle ssh_launcher.TerminalHandle
---@param opts table
function M.report_hijack(handle, opts)
  if handle.hijacked then
    return
  end
  handle.hijacked = true
  M.hostile_environment = true

  vim.schedule(function()
    log.error(
      ("%s: another plugin destroyed the session buffer, which killed ssh before it could connect. "):format(
        handle.title
      ) .. "Retrying with window events suppressed. Run :Ssh doctor to see what did it."
    )
    if opts and opts.on_hijack then
      pcall(opts.on_hijack, handle)
    end
  end)
end

--- The last meaningful lines a process left on screen.
---@param buf integer
---@param limit integer|nil how many non-blank lines to keep
---@return string|nil
function M.capture_tail(buf, limit)
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    return nil
  end
  local ok, lines = pcall(vim.api.nvim_buf_get_lines, buf, -200, -1, false)
  if not ok then
    return nil
  end
  local kept = {}
  for i = #lines, 1, -1 do
    local line = vim.trim(lines[i])
    if line ~= "" then
      table.insert(kept, 1, line)
      if #kept >= (limit or 6) then
        break
      end
    end
  end
  if #kept == 0 then
    return nil
  end
  return table.concat(kept, "\n")
end

--- A session that ran for at least this long got far enough to be a session:
--- it authenticated, it had a shell. How its exit should be described depends
--- entirely on which side of this line it falls.
M.ESTABLISHED_MS = 5000

--- Plain-English rendering of a process exit status.
---@param code integer
---@param opts { established: boolean|nil }|nil
---@return string
function M.describe_exit(code, opts)
  opts = opts or {}
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
    -- 255 is ssh's own failure code, but only before a session exists. Once
    -- one has been running, the same number means the link went away.
    return opts.established and "the connection was closed" or "ssh could not establish the connection"
  end
  if opts.established then
    -- After an interactive session ssh returns the remote shell's status, so
    -- this is usually just the last command the user ran failing.
    return ("session ended (remote status %d)"):format(code)
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

--- Set once a session window has been taken away from us. From then on this
--- Neovim session opens terminals with TermOpen suppressed, so the second
--- connection does not have to be rescued like the first.
---@type boolean
M.hostile_environment = false

--- How long after opening a session its destruction is still attributed to
--- another plugin rather than to the user. Layout guards act within
--- milliseconds; a person closing a session they just opened does not.
M.GRACE_MS = 5000

--- Is this one of our session buffers?
---
--- Published as a contract for configurations that manage windows: a layout
--- guard, tab hook or terminal manager can call this (or read `b:ssh_launcher`)
--- to leave other people's terminals alone.
---@param buf integer|nil defaults to the current buffer
---@return boolean
function M.is_session_buffer(buf)
  buf = buf or vim.api.nvim_get_current_buf()
  if not vim.api.nvim_buf_is_valid(buf) then
    return false
  end
  local ok, marked = pcall(function()
    return vim.b[buf].ssh_launcher
  end)
  return ok and marked == true
end

--- Events fired while a session window is being created, any of which can be
--- used to rearrange, replace or delete what we just made. A terminal manager
--- hooks TermOpen; a layout manager hooks WinNew or BufWinEnter; a tab handler
--- hooks TabNewEntered. All of them reach our buffer.
M.PROTECTED_EVENTS = {
  "TermOpen",
  "BufNew",
  "BufEnter",
  "BufWinEnter",
  "WinNew",
  "WinEnter",
  "TabNewEntered",
}

--- Third-party handlers on any of |ssh_launcher.terminal.PROTECTED_EVENTS|.
---
--- Knowing in advance that such handlers exist lets the very first connection
--- protect itself, instead of one having to fail first.
---@return { event: string, group: string }[]
function M.third_party_hooks()
  local out, seen = {}, {}
  for _, event in ipairs(M.PROTECTED_EVENTS) do
    local ok, autocmds = pcall(vim.api.nvim_get_autocmds, { event = event })
    if ok then
      for _, au in ipairs(autocmds) do
        local group = au.group_name or "(no group)"
        local key = event .. "/" .. group
        if
          not seen[key]
          and not group:match("^nvim[%._]") -- Neovim's own runtime
          and not group:match("^SshLauncher")
        then
          seen[key] = true
          out[#out + 1] = { event = event, group = group }
        end
      end
    end
  end
  return out
end

---@param buf integer
---@return boolean
local function is_displayed(buf)
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_buf(win) == buf then
      return true
    end
  end
  return false
end

---@param opts table
---@return integer buf, ssh_launcher.Float|nil
local function make_window(opts)
  local strategy = opts.strategy or config.get().terminal.strategy
  local buf = vim.api.nvim_create_buf(true, false)
  vim.bo[buf].bufhidden = "hide"
  -- Marked before the buffer is ever displayed, so a window guard reacting to
  -- the very first event can already tell whose terminal this is.
  vim.b[buf].ssh_launcher = true

  -- A function strategy hands window creation to the user, so a session can be
  -- hosted by whatever terminal plugin they already use. It receives our
  -- buffer and only has to put it on screen.
  if type(strategy) == "function" then
    local ok, err = pcall(strategy, buf, opts)
    if not ok then
      log.error(("terminal.strategy failed: %s; falling back to a tab"):format(tostring(err)))
    elseif is_displayed(buf) then
      return buf, nil
    else
      log.warn("terminal.strategy did not put the session on screen; falling back to a tab")
    end
    strategy = "tab"
  end

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

  -- `noautocmd` is the escape hatch for a configuration that reacts to window
  -- and buffer events by rearranging or closing things. It suppresses the
  -- events for the window we are creating only; the terminal itself still
  -- fires TermOpen, so terminal-specific setup keeps working.
  local prefix = config.get().terminal.noautocmd and "noautocmd " or ""

  if strategy == "tab" then
    vim.cmd(prefix .. "tabnew")
  elseif strategy == "vsplit" then
    vim.cmd(prefix .. "vsplit")
  elseif strategy == "split" then
    vim.cmd(("%sbotright %dsplit"):format(prefix, opts.height or math.floor(vim.o.lines * 0.4)))
  elseif strategy ~= "current" then
    vim.cmd(prefix .. "tabnew")
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
    opened_at = uv.now(),
  }

  -- Suppress the configured events for the whole of opening the session, then
  -- restore unconditionally — leaving 'eventignore' set would break the
  -- editor far worse than the problem it works around.
  local ignore = cfg.terminal.eventignore
  local previous_eventignore = nil
  if type(ignore) == "string" then
    ignore = { ignore }
  end
  ignore = vim.deepcopy(ignore or {})

  -- Decide whether to keep other plugins' handlers away from this session.
  local protect = cfg.terminal.protect
  local hooks = {}
  if protect == "auto" then
    hooks = M.third_party_hooks()
  end
  local shield = protect == true or M.hostile_environment or (protect == "auto" and #hooks > 0)
  if shield and not vim.tbl_contains(ignore, "all") then
    for _, event in ipairs(M.PROTECTED_EVENTS) do
      if not vim.tbl_contains(ignore, event) then
        ignore[#ignore + 1] = event
      end
    end
    if #hooks > 0 then
      log.debug(("shielding this session from %d third-party handler(s)"):format(#hooks))
    end
  end
  if type(ignore) == "table" and #ignore > 0 then
    previous_eventignore = vim.o.eventignore
    vim.o.eventignore = table.concat(ignore, ",")
  end

  local ok_window, buf, win = pcall(make_window, vim.tbl_extend("force", opts, { strategy = strategy }))
  if not ok_window then
    if previous_eventignore ~= nil then
      vim.o.eventignore = previous_eventignore
    end
    log.error(("could not open a window for %s: %s"):format(handle.title, tostring(buf)))
    return nil
  end
  handle.buf = buf
  handle.float = win
  handle.win = win and win.win or vim.api.nvim_get_current_win()

  local close_on_exit = opts.close_on_exit
  if close_on_exit == nil then
    close_on_exit = cfg.terminal.close_on_exit
  end

  -- Destroying the buffer destroys the pty, which SIGHUPs the process. Watch
  -- for that so every teardown path — `:bdelete`, an unloaded buffer under
  -- 'nohidden', another plugin's cleanup, quitting Neovim — is recognised as a
  -- deliberate close rather than reported as a dropped connection. The
  -- autocommand runs before the scheduled `on_exit`, so the flag is always set
  -- in time.
  vim.api.nvim_create_autocmd({ "BufUnload", "BufWipeout" }, {
    buffer = buf,
    once = true,
    desc = "ssh-launcher: note that a session's window went away",
    callback = function()
      handle.closing = true
      handle.output = M.capture_tail(buf) or handle.output
    end,
  })

  -- Take a copy of the transcript the moment the process exits, while the
  -- buffer is guaranteed to be intact. Configurations very commonly delete
  -- terminal buffers on TermClose; by the time BufUnload runs the text has
  -- already been discarded, and ssh's reason for failing goes with it.
  vim.api.nvim_create_autocmd("TermClose", {
    buffer = buf,
    once = true,
    desc = "ssh-launcher: keep the session's last output",
    callback = function()
      handle.output = M.capture_tail(buf) or handle.output
    end,
  })

  handle.job = spawn(buf, argv, {
    env = opts.env,
    cwd = opts.cwd,
    on_exit = function(_, code)
      handle.exit_code = code
      -- Never overwrite a capture that already succeeded: TermClose runs before
      -- this and is the reading with the buffer still intact, whereas by now
      -- the terminal may already have been torn down.
      handle.output = M.capture_tail(buf) or handle.output
      vim.schedule(function()
        -- Try again now the pty has flushed; the process often exits before
        -- its last words reach the buffer.
        handle.output = M.capture_tail(buf) or handle.output
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
        -- A session that dies of SIGHUP moments after opening, without the
        -- user having closed it, was destroyed by something else — its buffer
        -- was deleted and that took the pty with it. A process that ended on
        -- its own reports a real status instead, so the two cannot be
        -- confused, whatever order the events arrive in.
        if code == 129 and not handle.closed_by_us and (uv.now() - (handle.opened_at or 0)) < M.GRACE_MS then
          M.report_hijack(handle, opts)
          return
        end

        if close_on_exit and code == 0 then
          M.close(handle)
        elseif cfg.terminal.notify_on_exit and code ~= 0 and not M.was_torn_down(handle, code) then
          -- Only report an exit the user did not ask for, and say what the
          -- process actually printed — that is the part worth reading, and it
          -- may already have been deleted along with the buffer.
          local established = (uv.now() - (handle.opened_at or 0)) >= M.ESTABLISHED_MS

          local function report()
            if established then
              -- The transcript here is the shell the user was just working in.
              -- Quoting it back at them as though it explained a failure is
              -- worse than saying nothing: a prompt is not an error message.
              local message = ("%s: %s"):format(handle.title, M.describe_exit(code, { established = true }))
              if code == 255 then
                log.warn(message)
              else
                log.info(message)
              end
              return
            end

            -- Too short to have been a session: this is a connection failure,
            -- and the last thing on screen is ssh explaining why.
            handle.output = M.capture_tail(buf) or handle.output
            local message = ("%s %s"):format(handle.title, M.describe_exit(code))
            if handle.output then
              message = message .. ":\n" .. handle.output
            elseif vim.api.nvim_buf_is_valid(buf) then
              message = message .. " — press q to close the window"
            end
            log.warn(message)
          end

          if not established and handle.output == nil and vim.api.nvim_buf_is_valid(buf) then
            -- Exited before the pty flushed: wait a moment rather than
            -- reporting a failure with no explanation attached.
            vim.defer_fn(report, 80)
          else
            report()
          end
        end
      end)
    end,
  })

  -- The suppression window ends here: everything that the configured events
  -- could have disrupted has happened.
  if previous_eventignore ~= nil then
    vim.o.eventignore = previous_eventignore
  end

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

  -- A session with a live process but no window on screen is invisible and
  -- unusable, and the cause is always outside this plugin: an autocommand, a
  -- session manager, a picker restoring the layout it captured. Check once the
  -- current sequence of events has settled, and put the window back rather
  -- than leaving the user staring at "connecting to …" with nothing to show.
  vim.schedule(function()
    -- The user closing it themselves this quickly is not a problem.
    if handle.closed_by_us then
      return
    end

    -- A destroyed buffer is the serious case: destroying it closed the pty,
    -- which killed ssh. The session is gone, not merely hidden.
    local destroyed = not vim.api.nvim_buf_is_valid(buf)
    if not destroyed and is_displayed(buf) then
      return
    end

    -- Unless the process had already finished on its own, in which case the
    -- buffer being gone is just cleanup — a TermClose handler tidying up after
    -- it. Blaming another plugin for that would be a misdiagnosis; the exit
    -- itself is reported by `on_exit`, with the output it left behind.
    if handle.exit_code ~= nil and handle.exit_code ~= 129 then
      return
    end

    M.hostile_environment = true

    if destroyed then
      M.report_hijack(handle, opts)
      return
    end

    if cfg.terminal.ensure_visible then
      M.focus(handle)
      log.warn(("%s: another plugin took the session window; it has been reopened."):format(handle.title))
    end
  end)

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
  -- non-zero status is not reported back as a failure. `closed_by_us`
  -- additionally distinguishes this from another plugin destroying the buffer.
  handle.closing = true
  handle.closed_by_us = true
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

  if type(strategy) == "function" then
    local ok = pcall(strategy, handle.buf, { title = handle.title })
    if ok and is_displayed(handle.buf) then
      handle.win = vim.api.nvim_get_current_win()
      return true
    end
    strategy = "tab"
  end
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
