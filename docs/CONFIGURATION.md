# Configuration

## Files

There are two configuration roles:

- `~/.superterm/superterm.ini` stores user preferences such as the default
  template and session.
- `$SUPERTERM_INI`, or `/etc/superterm/superterm.ini` when the variable is not
  set, stores terminal definitions and INI templates.

They may be the same file. This is convenient for a personal installation:

```sh
export SUPERTERM_INI="$HOME/.superterm/superterm.ini"
```

The application creates `~/.superterm` automatically. Use mode `700` for the
directory when it contains credentials.

## User settings

```ini
[autologin]
shell=/bin/bash
login=1

[ui]
language=en

[session]
autosave=1
autorestore=0
default_template=daily
default_session=remote
default_window=production
```

`language` controls the application interface. It accepts `en` (English,
the default) or `es` (Spanish). The same setting is available at runtime from
`Language` or `Idioma` in the application menu; changing it updates the menus,
status line, wizard, help, and standard dialogs immediately and saves the
selection to the user configuration.

`autorestore=1` restores `~/.superterm/session.ini` when no template takes
priority. Set it to `0` when every startup must create fresh template
connections.

## Terminal definitions

Terminal sections must begin with `t` so the loader recognizes them:

```ini
[t-production]
name=production
enabled=1
type=ssh
host=prod.example.com
user=alice
port=22
key=~/.ssh/id_ed25519
scrollback=20000

[t-local-monitor]
name=local-monitor
enabled=1
type=local
shell=/bin/bash
cmd=watch -n 2 uptime
cwd=/tmp
```

SSH fields:

- `host` is the remote host.
- `user` is optional and becomes `user@host`.
- `port` is optional.
- `key` is an optional private key path.
- `password` is optional but requires `sshpass`; use a key or agent instead.
- `cmd` is an optional remote command for an SSH definition.

Local fields:

- `shell` selects the local shell.
- `cmd` is executed by that shell.
- `cwd` selects the starting directory.

## Templates

A template is a named profile. A session selects its windows, and each window
selects one or more panes:

```ini
[template.daily]
name=daily
enabled=1
default_session=remote
sessions=remote

[template.daily.session.remote]
enabled=1
focused_window=0
windows=production,logs

[template.daily.session.remote.window.production]
enabled=1
layout=L
focused_pane=0
panes=prod

[template.daily.session.remote.window.production.pane.prod]
enabled=1
terminal=production
postconnect=tmux new-session -A -s production

[template.daily.session.remote.window.logs]
enabled=1
layout=L
panes=logs

[template.daily.session.remote.window.logs.pane.logs]
enabled=1
terminal=production
postconnect=cd /var/log && tail -f application.log
```

`postconnect` is sent as the remote command for SSH. This makes commands such
as `tmux attach -t someone` natural: SSH authenticates, starts the remote
command, and keeps the PTY attached while tmux is running.

If a command should run and then leave an interactive shell, use a remote
wrapper script or a command such as:

```ini
postconnect=cd /srv/app && ./daily-command; exec bash -l
```

For a persistent console, prefer:

```ini
postconnect=tmux new-session -A -s someone
```

`layout=L` means one pane. Split layouts use `V:` or `H:` nodes, for example:

```ini
layout=V:500;L;L
```

The ratio is in the range `0..1000`; `V` places panes side by side and `H`
places them vertically.

## Startup behavior

At startup, the configured default template/session/window is activated and
its PTYs are created. Templates are alternatives, not simultaneous profiles.
Switching templates recreates the target template's PTYs.

To launch the same four remote windows every day:

```ini
[session]
autorestore=0
default_template=daily
default_session=remote
default_window=production
```

Use `Templates`, `Sessions`, and `Windows` in the English interface, or
`Plantillas`, `Sesiones`, and `Ventanas` in the Spanish interface, to switch
profiles while running.

## SQLite templates

Set:

```ini
[storage]
backend=sqlite
directory=templates
```

The directory is resolved relative to the configuration file. Each
`templates/*.db` file is one template database with `metadata`, `sessions`,
`windows`, and `panes` tables. SQLite storage is useful for generated or
managed profiles; INI is easier to edit by hand.
