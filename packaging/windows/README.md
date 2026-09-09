# Windows packaging and release

Everything needed to turn a built `bin\superterm.exe` into the published
Windows assets lives in this directory. The macOS equivalent belongs in
`packaging/macos`; nothing here is shared.

| File | Role |
|---|---|
| `superterm.iss` | Inno Setup 6 script: per-user x64 installer, publisher and version information, optional Authenticode signing (`/DSIGN`). |
| `sign.ps1` | Signs and verifies executables with `signtool` and an RFC 3161 timestamp; refuses without a certificate. |
| `trusted-signing.json` | Azure Trusted Signing account metadata handed to `signtool /dmdf`. Carries no secret; the account and profile names are filled in after onboarding. |
| `release.ps1` | The whole release in one command: build, version checks, signing, installer, flat zip, checksums, upload. |
| `superterm-launch.cmd` | What the Start-menu and desktop shortcuts run: opens SuperTerm in a new Windows Terminal window when `wt.exe` exists, else in `cmd.exe`. |
| `alien-hacker.ico` | Application and installer icon. The executable embeds it through `src/superterm.rc`. |

## The release, step by step

```powershell
powershell -ExecutionPolicy Bypass -File packaging\windows\release.ps1 [-Sign] [-Upload] [-SkipBuild]
```

1. **Build.** Runs `make release` and `make traytool` through Git's `bash.exe`
   with the GNU Make that ships next to the `fpc` recorded in `config.status`
   (`./configure` must have been run once). The Makefile regenerates
   `src/st_version.inc` and `src/superterm_version.rh` from `VERSION`,
   recompiles `src/superterm.res` with `windres`, and links `bin\superterm.exe`
   (the console client and session server) and `bin\superterm-tray.exe` (the
   notification-area helper, source in `src/traytool`; it lists live sessions,
   reopens one at the size it was last used at — recorded by the daemon in the
   session file — centred on the monitor, or closes one). The script then checks
   that `--version` and the version resource both say what `VERSION` says.
   `-SkipBuild` reuses the binaries as they are.
2. **Sign** (`-Sign`). `sign.ps1` signs `bin\superterm.exe` and
   `bin\superterm-tray.exe`; Inno Setup then calls it again for the setup and
   the uninstaller. See "Signing" below.
3. **Installer.** `ISCC.exe /Q [/DSIGN /Ssuperterm=...] superterm.iss` writes
   `dist\SuperTerm-<version>-windows-x64-setup.exe`. It installs under
   `%LOCALAPPDATA%\Programs\SuperTerm` without elevation and carries both
   executables, `superterm-launch.cmd`, the documentation, the configuration
   example and the desktop backgrounds. It closes a running SuperTerm (client,
   session server or tray) before replacing files, and offers a
   checked-by-default task to start the tray at sign-in (an `HKCU\…\Run` entry,
   removed on uninstall). Behaviour is documented in `docs/WINDOWS.md`.
4. **Zip.** `dist\superterm-<version>-windows-x86_64.zip`, **flat** (no
   directories): `superterm.exe`, `superterm-tray.exe`, `superterm-launch.cmd`,
   `README.md`, `LICENSE`, `WINDOWS.md` and every `backgrounds\*.art`.
5. **Checksums.** A `.sha256` next to each, one line:
   `<lowercase sha256>  <filename>`.
6. **Upload** (`-Upload`). Puts the four Windows assets on the GitHub release
   `v<version>`, which must already exist (the GNU/Linux and macOS assets are
   published from their own branches). There is no `gh` CLI on the build
   machine; the script talks to the REST API with the token Git Credential
   Manager already holds (`git credential fill`). It ends by printing the
   download URL to paste into a Microsoft Store submission.

Asset names are part of the download links and must not change:

- `SuperTerm-<version>-windows-x64-setup.exe` and `.sha256`
- `superterm-<version>-windows-x86_64.zip` and `.sha256`

### A published URL keeps its bytes

Because the names are fixed per version, the download URL is fixed per version
too, and **the upload refuses to overwrite an asset the release already
carries**. It checks every name first and aborts before deleting anything, so a
refused run leaves the release exactly as it was.

This is not tidiness. A download URL whose contents change breaks the `.sha256`
published beside it, breaks anyone who pinned the link, and is specifically
forbidden by Microsoft Store policy 10.2.9, which requires that the binary
behind a submitted URL never change. A new binary means a new `VERSION`, a new
tag and a new URL — and, for the Store, a new submission pointing at it.

`-Replace` overrides the refusal and deletes the old assets first. It is for a
release nobody has downloaded yet; every replacement prints a warning naming
what it broke. If the version has been announced, or its URL sits in a Store
submission, bump `VERSION` instead.

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

### Azure Trusted Signing, now Artifact Signing

The route chosen for the project. The certificate is short-lived and lives in
Microsoft's service, so there is no token to plug in and no `.pfx` to guard;
what has to be present on the build machine is the dlib, the metadata file and
an Azure login.

**The procedure is [`SIGNING.md`](SIGNING.md)**, next to this file: what to do in
the Azure portal once per organisation, what to install on a build machine once
per machine, the command that produces the signed release, and the traps — the
sharpest being that Microsoft renamed the service to **Artifact Signing**, so
searching the portal for "Trusted" finds nothing, while the NuGet package, the
dlib and the endpoint keep the old name.

## Status

### Where to pick this up

Microsoft completed the identity validation on 2026-09-09 and the public trust
certificate profile `public-7kas` is active, so **Azure's side is finished** and
`trusted-signing.json` carries the endpoint, account and profile. The issued
subject is `CN=7kas Servicios Internet, S.L.`, exactly what the five publisher
strings in `src/superterm.rc` and `superterm.iss` already say, so nothing in the
repository has to move.

**What is left is the build machine**, which as of that date still had no
`signtool` new enough for `/dlib` (the newest Windows Kit on it was 10.0.19041,
and 10.0.22621 is the minimum), no `Azure.CodeSigning.Dlib.dll` and no Azure
CLI. [`SIGNING.md`](SIGNING.md), "Part 2", is that shopping list; "Part 3" is the
one command that follows it. The identifiers of the account, subscription and
validation live there too.

### How it got here

- 2026-09-04: Defender began quarantining
  `dist\SuperTerm-5.2.2-windows-x64-setup.exe` as `Trojan:Win32/Wacatac.B!ml`
  (threat 2147735505), on build and on download from the release alike. Only
  the installer was hit; `bin\superterm.exe` was left alone, so the detach
  feature is not what triggered it. It is the ordinary shape of the false
  positive: an unsigned, solid-LZMA2 Inno Setup installer that nothing in the
  world had run yet.
- 2026-09-04: moving to Inno Setup 7 produced a different setup stub and the
  detection stopped. **That is non-detection, not a fix.** The file is still
  unsigned, so a definition update can flag it again at any time, and
  SmartScreen still reports an unknown publisher. The real answers are the
  false-positive submission and, permanently, signing.
- 2026-09-04: the publisher became `7kas Servicios Internet, S.L.` across the
  version resource and the installer, the URLs moved to 7ks.ai and
  superterm.org, and Azure Trusted Signing was chosen as the route.
- 2026-09-04: the v5.2.2 Windows assets were replaced with a build that closes
  a running SuperTerm before replacing the executable. **They are still
  unsigned**, and the warnings remain until the certificate exists.
- 2026-09-04: the `signing-7kas` account was created and the public identity
  validation submitted. Two hours of it were spent on things worth writing
  down: the first Azure sign-in landed in a personal Microsoft tenant with no
  subscription at all, and the company one had to be selected by switching
  directory rather than account; and the roles could not be found because the
  service had been renamed to Artifact Signing. Both are covered above.

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
