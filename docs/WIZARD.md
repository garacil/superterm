# Session Wizard

The built-in wizard is available from:

```text
Sessions -> Quick session wizard...
```

In Spanish mode the same entry is `Sesiones -> Asistente de sesion rapida...`.

![Sessions menu with the quick session wizard entry](../screenshots/session-menu.png)

It builds a fresh workspace of one to four panes. For each pane, enter:

1. A connection command, for example `ssh -tt alice@prod.example.com`,
   `tmux attach -t remote`, `mosh alice@host`, or a local command.
2. An optional command to send after the connection command starts, for
   example `tmux new -A -s main` or `cd /srv/app && ./run.sh`.

![Session wizard connection command](../screenshots/wizard.png)

The wizard collects every entry before replacing the current panes, so
canceling at any point leaves the current workspace unchanged. It then tiles
the resulting panes and focuses the first one.

Wizard panes are ad-hoc: they do not reference a window class and the wizard
does not modify the configuration file or store credentials. For a
reproducible setup, define window classes (`[class.*]`, or `Classes ->
Manage classes...`) and reference them from a profile — or run the wizard
once and use `Profiles -> Save current as profile...`, which remembers each
pane's connection command.

The connection command runs as a shell script under the configured login
shell. When a post-connect command is present, the wizard feeds it to the
connection's standard input as the command starts. This is suitable for
interactive SSH, tmux, telnet-like commands, and similar PTY programs.
Key-based SSH login is recommended; commands that require a password may
consume the same input and need to be tested carefully.

For a persistent remote console, enter:

```text
Connection command: ssh -tt alice@prod.example.com
After connecting:   tmux new -A -s main
```

For a command that should end in a shell, enter a command that starts one:

```text
After connecting: cd /srv/app && ./daily-command; exec bash -l
```

The wizard is intentionally a quick-launch tool. It does not attempt to parse
or validate arbitrary shell syntax and does not store credentials.
