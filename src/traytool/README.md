# superterm-tray — Windows notification-area helper

`superterm-tray.exe` is a small, separate GUI program that lives in the
Windows notification area (the system tray) and manages detached SuperTerm
sessions from there. It exists because the console client has no window of its
own — the window belongs to the terminal emulator — so once it closes there is
nothing on screen to show that the session server and its shells are still
alive, or to bring a session back.

It is deliberately a separate executable from `superterm.exe`, which stays a
pure console program. The two share only the session directory and the fact
that `superterm.exe` sits next to the tray binary in the install folder.

## What it does

- **Left double-click** on the tray icon: attach the one live session, or, if
  there are several, open the menu to choose.
- **Right-click**: a menu with one submenu per live session — **Attach** and
  **Close** — plus **Exit** (which only removes the tray icon; it never touches
  the sessions).
- **Attach** opens the session in a new Windows Terminal window (or a plain
  console if Windows Terminal is absent), running `superterm attach NAME`.
- **Close** runs `superterm kill NAME` with no window, ending that session and
  the programs inside it.

When it reopens a session, the tray restores the window to the size it was
last used at (the daemon records that size in the session file) and centres it
on the monitor. A session closed while maximised reopens maximised; one closed
minimised reopens at its normal size, centred. `superterm-tray --attach NAME`
does the same from the command line without the tray icon.

Sessions are read straight from `%LOCALAPPDATA%\superterm\sessions\*.sock` —
the same names `superterm list` shows. Only one tray instance runs at a time
(a named mutex); a second launch exits immediately.

## Building

Windows only. The Makefile builds it with the project's strict diagnostics,
never as part of `all` or `release`, so a GNU/Linux or macOS build never
compiles it — the same rule as `src/st_conpty.pas`:

```
make traytool          # -> bin/superterm-tray.exe
```

`packaging/windows/release.ps1` builds, signs (with `-Sign`) and packages it
alongside `superterm.exe`; the installer places it in the install folder with
a Start-menu shortcut, and its close-running-instance guard also closes a
running tray so Setup can replace the file.

## Why it is portable to `main`

The source lives in the shared tree and only a Windows build target ever
compiles it, so the file can sit in `main` untouched by the GNU/Linux and
macOS builds. It uses only `Windows` and `ShellApi` (`Shell_NotifyIconW`),
depends on no project unit, and launches `superterm.exe` by path rather than
linking against it. See `TORESOLVE.md` for the branch-to-main plan.
