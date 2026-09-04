# Windows packaging and release

Everything needed to turn a built `bin\superterm.exe` into the published
Windows assets lives in this directory. The macOS equivalent belongs in
`packaging/macos`; nothing here is shared.

| File | Role |
|---|---|
| `superterm.iss` | Inno Setup 6 script: per-user x64 installer, publisher and version information, optional Authenticode signing (`/DSIGN`). |
| `sign.ps1` | Signs and verifies executables with `signtool` and an RFC 3161 timestamp; refuses without a certificate. |
| `release.ps1` | The whole release in one command: build, version checks, signing, installer, flat zip, checksums, upload. |
| `superterm-launch.cmd` | What the Start-menu and desktop shortcuts run: opens SuperTerm in a new Windows Terminal window when `wt.exe` exists, else in `cmd.exe`. |
| `alien-hacker.ico` | Application and installer icon. The executable embeds it through `src/superterm.rc`. |

## The release, step by step

```powershell
powershell -ExecutionPolicy Bypass -File packaging\windows\release.ps1 [-Sign] [-Upload] [-SkipBuild]
```

1. **Build.** Runs `make release` through Git's `bash.exe` with the GNU Make
   that ships next to the `fpc` recorded in `config.status` (`./configure`
   must have been run once). The Makefile regenerates `src/st_version.inc`
   and `src/superterm_version.rh` from `VERSION`, recompiles
   `src/superterm.res` with `windres`, and links `bin\superterm.exe`. The
   script then checks that `--version` and the executable's version resource
   both say what `VERSION` says. `-SkipBuild` reuses the binary as it is.
2. **Sign** (`-Sign`). `sign.ps1` signs `bin\superterm.exe`; Inno Setup then
   calls it again for the setup and the uninstaller. See "Signing" below.
3. **Installer.** `ISCC.exe /Q [/DSIGN /Ssuperterm=...] superterm.iss` writes
   `dist\SuperTerm-<version>-windows-x64-setup.exe`. It installs under
   `%LOCALAPPDATA%\Programs\SuperTerm` without elevation and carries the
   executable, `superterm-launch.cmd`, the documentation, the configuration
   example and the desktop backgrounds.
4. **Zip.** `dist\superterm-<version>-windows-x86_64.zip`, **flat** (no
   directories): `superterm.exe`, `superterm-launch.cmd`, `README.md`,
   `LICENSE`, `WINDOWS.md` and every `backgrounds\*.art`.
5. **Checksums.** A `.sha256` next to each, one line:
   `<lowercase sha256>  <filename>`.
6. **Upload** (`-Upload`). Replaces the four Windows assets on the GitHub
   release `v<version>`, which must already exist (the GNU/Linux and macOS
   assets are published from their own branches). There is no `gh` CLI on
   the build machine; the script talks to the REST API with the token Git
   Credential Manager already holds (`git credential fill`).

Asset names are part of the download links and must not change:

- `SuperTerm-<version>-windows-x64-setup.exe` and `.sha256`
- `superterm-<version>-windows-x86_64.zip` and `.sha256`

## Where the version lives

`VERSION` is the source of truth and arrives with the merge from `main`. From
it the Makefile generates `src/st_version.inc` (what `--version` prints) and
`src/superterm_version.rh` (the version resource). Two places are still
edited by hand on a bump: `#define AppVersion` at the top of `superterm.iss`,
and the sample filenames in `docs/WINDOWS.md`. `release.ps1` stops if the
binary and `VERSION` disagree.

## Signing

Unsigned assets trigger SmartScreen ("Windows protected your PC"), the
browser's download warning and an "Unknown publisher" prompt. Only an
Authenticode signature from a certificate issued by a CA in Microsoft's trust
program removes them; the publisher Windows shows is the certificate's
subject. `docs/WINDOWS.md`, "Code signing and the SmartScreen warning",
lists the kinds of certificate to obtain.

`sign.ps1` takes the certificate from the environment, first match wins:

| Variable | Meaning |
|---|---|
| `SUPERTERM_SIGN_THUMBPRINT` | SHA-1 thumbprint of a certificate in the current user's store (`Get-ChildItem Cert:\CurrentUser\My -CodeSigningCert`); hardware tokens and HSM-backed certificates appear there too |
| `SUPERTERM_SIGN_PFX` + `SUPERTERM_SIGN_PFX_PASSWORD` | a `.pfx` file and its password |
| `SUPERTERM_SIGN_DLIB` + `SUPERTERM_SIGN_METADATA` | Azure Trusted Signing: `Azure.CodeSigning.Dlib.dll` and the account's metadata JSON |
| `SUPERTERM_SIGN_TIMESTAMP` | timestamp server; default `http://timestamp.digicert.com` |
| `SUPERTERM_SIGNTOOL` | explicit `signtool.exe`; otherwise the newest x64 one under the Windows Kits is used |

With no variable set the script exits with code 2 and Inno Setup aborts, so
a `-Sign` release can never come out unsigned by accident. A full signed
release is then:

```powershell
$env:SUPERTERM_SIGN_THUMBPRINT = '<thumbprint>'
powershell -ExecutionPolicy Bypass -File packaging\windows\release.ps1 -Sign -Upload
```

Signing by hand, for a single file:

```powershell
powershell -ExecutionPolicy Bypass -File packaging\windows\sign.ps1 bin\superterm.exe
```

## Status

- 2026-09-04: the v5.2.2 Windows assets were rebuilt with the console-resize
  fix and the version resource and replaced on the release. **They are not
  signed: no code-signing certificate exists yet**, and the warnings remain
  until one is obtained and the release is re-run with `-Sign -Upload`.

## Things that bite

- Never run `ISCC.exe` from Git Bash: MSYS rewrites `/Q` and `/DSIGN` as
  paths and ISCC answers "You may not specify more than one script filename".
  Use PowerShell, as `release.ps1` does.
- `config.status` may record Embarcadero's `make` as `make=`; the project's
  build tool is the GNU Make next to `fpc`, which is what `release.ps1` uses.
- `windres` on Windows mangles quoted `-D` string values, which is why the
  version reaches `superterm.rc` through the generated header rather than
  the command line.
- A PowerShell pipeline into `git credential fill` re-encodes the request
  and Git refuses it ("missing protocol field"); `release.ps1` writes the
  request to a file and feeds it through `cmd`.
