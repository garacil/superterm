# Native Windows

SuperTerm has a native Windows target on the `windows-support` branch. It is
not a WSL wrapper: Windows Terminal or the regular Windows console drives the
same FreeVision interface, and pane processes run through Windows ConPTY.

## Scope

The Windows build supports the local terminal workspace, profiles, classes,
the VT screen engine, UTF-8 terminal input/output, contextual `--help`, and
outgoing SSH panes. It requires Windows 10 version 1809 (build 17763) or newer,
the first Windows release that supplies ConPTY.

The detached Unix daemon, shared multi-client sessions and dedicated OpenSSH
server are POSIX-server features at present. To host a persistent shared
workspace over SSH, use a GNU/Linux or macOS SuperTerm host; a Windows machine
can still connect to it with its ordinary `ssh` client. This boundary is
intentional and explicit, not a fallback to WSL.

## Build the native executable

Use the platform branch and an x86_64 Free Pascal installation from Git Bash:

```sh
git clone https://github.com/garacil/superterm.git
cd superterm
git switch windows-support
./configure --with-fpc=/d/lazarus/fpc/3.2.2/bin/x86_64-win64/fpc
/d/lazarus/fpc/3.2.2/bin/x86_64-win64/make.exe release
bin/superterm.exe --help
```

The maintained Windows build uses FPC 3.2.2 x86_64 and produces a native PE
executable. The release page also carries the Windows x64 installer generated
from this branch.

## Use it

Start `superterm.exe` from Windows Terminal, `cmd.exe`, or PowerShell. The
first run creates the same fixed monochrome Alien-hacker workspace used by the
other native targets. The `superterm-launch.cmd` included by the installer can
open a suitably sized Windows Terminal window when `wt.exe` is available.

For a remote shared session hosted on GNU/Linux or macOS, use the standard
Windows OpenSSH client exactly as on any other machine:

```powershell
ssh -tt -p 8022 user@server
```

`-tt` asks OpenSSH to allocate the interactive terminal required by the
SuperTerm SSH entry. No SuperTerm client program, browser extension or custom
network protocol is installed on the viewing computer.
