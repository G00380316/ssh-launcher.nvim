# ssh-launcher.nvim

An SSH connection manager for Neovim. Store your fleet, paste connection
strings from anywhere, and find out *why* a connection will fail before you
waste a login attempt on it.

```
┌ Hosts  6/8   prod ───────────────────────────────────────────────────────┐
│    NAME                  TARGET                     KEY        TAGS      │
│  ✓ prod-api-eu           deploy@10.0.4.12:2222      prod       prod,eu   │
│  ✓ prod-api-us           deploy@10.8.1.9:2222       prod       prod,us   │
│  ✗ prod-db-primary       postgres@10.0.9.2          agent      prod      │
│  ? bastion               jump@bastion.corp.net      id_ed…     infra     │
└──────────────────────────────────────────────────────────────────────────┘
┌ Details ─────────────────────────────────────────────────────────────────┐
│  prod-db-primary   postgres@10.0.9.2                                     │
│  key: from ssh-agent · used: 2026-07-30 14:02 (23 times) · refused       │
│  $ ssh -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new …       │
│  ✗ error: Key ~/.ssh/db is mode 0644 — too open      [f fixes this]      │
└──────────────────────────────────────────────────────────────────────────┘
```

## Why

Three things go wrong with SSH in an editor, and this fixes all three.

**Getting details in is tedious.** Everyone copies `ssh -i "key.pem"
ec2-user@ec2-3-8-1-2.compute.amazonaws.com` out of a console or a runbook.
Paste it — the whole line — into one field and every other field fills in. Also
understood: `ssh://` URLs, `user@host:port`, `scp`/`rsync` commands, whole
`ssh_config` blocks, JSON, and bare addresses.

**Failures are cryptic.** `Permission denied (publickey)` tells you nothing.
Around forty rules check the address, user, port, key file, jump host,
forwards, options, duplicates and `known_hosts`, and each finding says what is
wrong, why it matters, and offers a fix. A key at mode 0644 is one keystroke
from being fixed rather than an afternoon of confusion.

**The easy path is the insecure one.** Plenty of tooling reaches for
`StrictHostKeyChecking=no` to stop the prompts. This plugin refuses to, builds
every command as an argument list instead of a shell string, keeps agent
forwarding off by default, and never writes key material anywhere.

## Features

- **Host manager** — searchable, sortable, filter-as-you-type, bulk marks,
  live reachability, and a detail pane showing the exact command that will run.
- **Smart paste** — one field understands every shape an SSH connection comes
  in. Passwords and private keys are refused with an explanation.
- **~40 misconfiguration checks** with automatic repair: key permissions,
  public-key-used-as-private, PuTTY keys, missing files, encrypted keys not in
  the agent, deprecated algorithms, invalid forwards, misspelled ssh options,
  duplicate names, jump-host loops, unresolvable names, closed ports.
- **`~/.ssh/config` both ways** — existing hosts appear automatically
  (including `Include`); export writes into a delimited managed block that
  leaves the rest of your file untouched.
- **Sessions anywhere** — tab, split, float, tmux window, or your own terminal
  plugin via a one-function `strategy`. Coexists with floaterm/toggleterm-style
  managers: if one takes the session window, it's reopened and later sessions
  protect themselves automatically. Existing sessions are reused rather than
  redialled.
- **Bastions, forwards, remote commands** — `ProxyJump`, `-L`/`-R`/`-D`,
  landing directories, and per-host `ssh -o` options.
- **Keys unlock themselves** — when a host's key needs a passphrase and isn't
  loaded, connecting offers to `ssh-add` it first (starting an agent if there
  isn't one), so you type the passphrase once instead of every time.
- **ssh-agent, keygen, ssh-copy-id, known_hosts repair** from the manager.
- **Background tunnels** — raise a host's port forwards as `ssh -N` processes
  (`L`), no interactive session parked open. Stopped when Neovim exits.
- **Fleet commands** — mark hosts, press `!`, run one command across all of
  them with bounded concurrency and per-host exit status.
- **Remote workspace** — `b` opens a built-in SSH file browser using the saved
  port, key, jump host and options. Open a text file, edit normally, and `:write`
  saves it back atomically. oil.nvim/netrw remain optional adapters;
  `:Ssh upload`/`:Ssh download` (or `U`/`W`) move files and directories.
- **Two-pane transfer** — `T` (or `:Ssh transfer`) shows this machine beside
  the host, with sizes and dates. Select with `<Space>`, press `c`, and the
  files go to whichever directory the *other* pane is showing — an upload from
  the left, a download from the right. Transfers run in the background with a
  live status line, a queue and cancel.
- **Your Neovim on the server** — `n` packages the configuration used by the
  current Neovim, sends it to a private session directory, and launches remote
  Neovim there. Plugins, LSPs, Git, searches and terminals then run entirely in
  the SSH environment; the copied config is removed when the session exits.
- **Connection history** — `:Ssh history` shows every connection, with
  outcomes and durations.
- **Production guard** — hosts tagged `prod` confirm before opening.
- **Connection multiplexing** — opt-in `ControlMaster`; reconnects in
  milliseconds.
- **Frecency ranking** — the host you actually want is at the top.
- **Telescope / fzf-lua / snacks** integrations, or the built-in manager.
- **Accessible by construction** — see below.
- **`:checkhealth ssh_launcher`** that checks your whole setup, not just the
  plugin's.

## Requirements

Neovim **0.10+** and the OpenSSH client. Configured remote workspaces also need
`tar` and `scp` locally, plus `nvim` and `tar` on the server. `ssh-add`,
`ssh-keygen` and `ssh-copy-id` unlock the agent, key-inspection and
key-distribution features. A Nerd Font is optional — ASCII glyphs are used
automatically without one.

## Installation

<details open>
<summary><b>lazy.nvim</b></summary>

```lua
{
  "G00380316/ssh-launcher.nvim",
  cmd = { "Ssh", "SshLauncher" },
  keys = {
    { "<leader>ss", "<cmd>Ssh<cr>", desc = "SSH hosts" },
  },
  opts = {},
}
```
</details>

<details>
<summary><b>packer.nvim</b></summary>

```lua
use({
  "G00380316/ssh-launcher.nvim",
  config = function()
    require("ssh_launcher").setup()
  end,
})
```
</details>

`setup()` is optional — the commands work without it.

## Getting started

1. Copy an ssh command from wherever you found it.
2. `:Ssh`, then press `p`. The clipboard is parsed and the form opens filled in.
3. `<C-s>` to save, `<CR>` to connect.

Already have `~/.ssh/config`? Those hosts are already in the list, marked
read-only. Press `i` to import them for editing.

## Commands

| Command | What it does |
| --- | --- |
| `:Ssh` | Open the manager |
| `:Ssh {name}` | Connect by name, or to any connection string |
| `:Ssh add [text]` | New host, optionally seeded from pasted text |
| `:Ssh edit [name]` | Edit a host |
| `:Ssh diagnose [name]` | Report every problem found |
| `:Ssh import [file]` | Import from `~/.ssh/config` or a JSON file |
| `:Ssh export [file]` | Write hosts into `~/.ssh/config` |
| `:Ssh agent` | Manage ssh-agent identities |
| `:Ssh sessions` | Jump to a running session |
| `:Ssh browse [name] [path]` | Browse and edit a host's files in the editor |
| `:Ssh transfer [name] [path]` | Two panes: browse this machine and a host, copy across |
| `:Ssh upload [name] {local}… [remote]` | Send files or directories to a host |
| `:Ssh download [name] {remote} [local]` | Fetch a file or directory from a host |
| `:Ssh workspace [name] [path]` | Launch remote Neovim with your local configuration |
| `:Ssh tunnels [name]` | List tunnels, or raise/drop a host's forwards |
| `:Ssh fleet <cmd>` | Run a command on every host (`--tag=prod` narrows it) |
| `:Ssh history [name]` | Show the connection log |
| `:Ssh keygen` | Generate a key pair |
| `:Ssh health` | `:checkhealth ssh_launcher` |
| `:Ssh doctor` | Diagnose session windows that vanish |

`:SshLauncher`, `:SshAddKey` and `:SshEditKey` from 1.x still work.

### Sending and fetching files

```vim
:Ssh upload web-01 %                          " the file you are editing
:Ssh upload web-01 dist/ /srv/app/            " a directory, recursively
:Ssh upload web-01 *.conf nginx.d /etc/nginx/ " several; the last is the destination
:Ssh download web-01 /var/log/app.log         " into the current directory
:Ssh download web-01 /var/log/app.log ~/logs/today.log
```

Omit the paths (or the host) and you are prompted, with the current file
offered first. Uploads without a destination land in the host's *Remote dir*.
`~`, `$VAR`, globs and `%` work locally; escape spaces as `my\ file.txt`. Tab
completes host names, then local paths.

Typos are caught before scp starts, uploads to `prod`-tagged hosts ask first,
and a download never replaces a local file without asking. `:Ssh! …` skips
those prompts. The manager's `U`/`W` use the same flow. See
`:help ssh-launcher-transfer`.

### Two-pane transfer

`:Ssh transfer web-01` (or `T` on a host in the manager) when you would rather
browse than type paths:

```
┌ > Local  ~/projects/site ─────────┐┌   web-01  /srv/app ───────────────┐
│    ../                            ││    ../                            │
│    docs/                          ││    backups/                       │
│    dist/                          ││    logs/                          │
│[x] index.html              12K    ││    index.html              11K    │
│[x] app.js                 340K    ││    app.js                 338K    │
│    README.md              1.2K    ││    server.conf            2.3K    │
└─────────── 5 items · 2 selected ──┘└───────────────────────── 6 items ─┘
 <Tab> switch   <Space> select   c copy   m mkdir   go path   ? help   q quit
```

`<Tab>` switches panes, `<Space>` selects, and `c` copies the selection (or the
file under the cursor) into the directory the **other** pane is showing — so
copying from the left pane uploads and from the right pane downloads, with no
path to type. `m` makes a directory, `go` jumps to a typed path, `.` toggles
dotfiles, `x` cancels. Existing files at the destination are listed and need a
yes; production hosts ask before an upload.

Copies run in the background: the status line shows what is moving and for how
long, further copies queue behind it, and the destination pane refreshes when
it finishes. Because nothing can answer a prompt there, a locked key is loaded
into ssh-agent when the window opens; a password-only host should use
`:Ssh upload`/`:Ssh download`. Every key is configurable under
`commander.keymaps`. See `:help ssh-launcher-commander`.

## Keys

In the manager: `<CR>` connect · `a` add · `p` paste-add · `e` edit · `d`
delete · `<Space>` mark · `/` filter · `s` sort · `D` diagnose · `f` fix · `A`
agent · `C` copy-id · `G` keygen · `K` forget host key · `L` tunnels · `!`
fleet command · `b` browse · `n` configured remote Neovim · `T` two-pane
transfer · `U`/`W` upload/download · `i` import · `X` export · `S` sessions ·
`?` help.

In the editor: `<Tab>` next field · `<C-k>` pick a key · `<C-f>` fix
everything · `<C-d>` explain this line · `gx` show the resolved command ·
`<C-s>` save · `<C-a>` save and connect.

In the remote browser: `<CR>`/`l` open · `h`/`-` parent · `r` refresh ·
`<C-x>`/`<C-v>`/`<C-t>` open in a split/vsplit/tab · `q` close. Remote text
files are regular Neovim buffers; use `:write` to save them to the server.

Every key is configurable. `?` shows the current bindings, not the defaults.

## Configuration

Defaults are sensible; everything below is optional. See
`:help ssh-launcher-config` for the full annotated table.

```lua
require("ssh_launcher").setup({
  ssh = {
    strict_host_key_checking = "accept-new",  -- "no" is refused
    control_master = true,                    -- multiplex; instant reconnects
  },
  terminal = {
    strategy = "float",                       -- tab | float | vsplit | split | tmux
  },
  remote = {
    adapter = "builtin",                      -- builtin | oil | netrw | auto
    timeout = 30000,
  },
  workspace = {
    config_dir = vim.fn.stdpath("config"),
    remote_root = "~/.cache/ssh-launcher.nvim",
    binary = "nvim",
    args = { "." },
    strategy = "tab",
  },
  ui = {
    picker = "manager",                       -- or telescope | fzf-lua | snacks
    sort = "frecency",
  },
  diagnostics = {
    on_connect = "block",                     -- off | warn | block
    disabled = { "SSH090" },                  -- silence individual codes
  },
  security = {
    confirm_production = true,
    production_tags = { "prod", "production", "live" },
  },
})
```

## Security

- **No shell in the path.** Commands are argument lists handed straight to the
  process, so nothing in a hostname, key path or remote command can be
  interpreted as shell syntax.
- **Host keys are verified.** `accept-new` by default. `no` requires two
  explicit opt-ins and still flags every affected host.
- **No secrets stored.** Pasted passwords are discarded, pasted private keys
  refused, credential-shaped fields reported as errors. The database is written
  atomically at mode 0600 and loose permissions are tightened on sight.
- **Config sync is explicit.** A workspace confirms before copying the chosen
  Neovim config, keeps it private, and removes it when remote Neovim exits.
- **Agent forwarding is opt-in** and warned about; `ProxyJump` is suggested
  instead.
- **`IdentitiesOnly=yes`** whenever a host names a key, so a large agent cannot
  burn through the server's `MaxAuthTries`.
- **Concurrent Neovim instances merge** rather than overwrite each other's
  edits.

## Accessibility

Not a mode — a property of how the UI is built.

- **Never colour alone.** Every status has a glyph *and* a word; rows carry a
  text marker next to the icon; severities are spelled out.
- **Everything is text.** No information exists only as a highlight or an
  overlay. The editor is a normal buffer you edit with normal Vim motions.
- **Screen readers** get state changes echoed to the message area — what
  opened, what a paste filled in, how many hosts matched, and the full state of
  the row under the cursor as you move.
- **Keyboard only.** Dialogs take cursor + `<CR>`, a number, or a mnemonic.
- **Your theme wins.** Highlights link to standard groups with `default = true`.
  `a11y.high_contrast` adds weight and underline instead of relying on hue.
- **No Nerd Font needed.** ASCII glyphs are automatic.

`:help ssh-launcher-accessibility`

## Data

Hosts live at `stdpath("data")/ssh_launcher/hosts.json`, mode 0600, pretty
printed with sorted keys so it diffs cleanly in git:

```json
{
  "version": 2,
  "hosts": [
    {
      "id": "h_6a6e69b3_f962bdd",
      "name": "prod-api-eu",
      "host": "10.0.4.12",
      "user": "deploy",
      "port": 2222,
      "identity_file": "~/.ssh/prod",
      "proxy_jump": "bastion.corp.net",
      "tags": ["prod", "eu-west-1"],
      "forwards": [{ "kind": "local", "spec": "5432:db.internal:5432" }]
    }
  ]
}
```

Point `store.extra_sources` at a checked-in file to share a fleet definition
with a team, or drop a `.ssh-launcher.json` in a repository for project-local
hosts. Both are read-only in the UI.

## Development

```bash
make test    # nvim --headless -u NONE -l tests/run.lua
make lint    # stylua --check .
```

The suite needs nothing but Neovim.

## License

MIT — see [LICENSE](LICENSE).

Issues and pull requests:
[github.com/G00380316/ssh-launcher.nvim](https://github.com/G00380316/ssh-launcher.nvim)
