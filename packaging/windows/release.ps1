# Builds the Windows release of the version in VERSION: superterm.exe through
# the Makefile, the Inno Setup installer, the flat zip, and a .sha256 next to
# each; optionally signs everything and replaces the assets on the GitHub
# release of that version.
#
#   powershell -ExecutionPolicy Bypass -File packaging\windows\release.ps1 [-Sign] [-Upload] [-SkipBuild]
#
# -Sign needs a certificate configured for sign.ps1 (see docs/WINDOWS.md);
# without it the build stops rather than shipping unsigned. -Upload takes the
# GitHub token from Git Credential Manager (git credential fill) and expects
# the release tag v<version> to exist already.
#
# A published asset URL is immutable: the upload refuses to overwrite a name
# the release already carries, because a download URL whose bytes change is
# exactly what Microsoft Store policy 10.2.9 forbids, and the Store is not the
# only consumer that assumes a checksum stays true. Ship a new binary under a
# new VERSION, which gives it a new tag and a new URL. -Replace overrides this
# for a release nobody has consumed yet, and says plainly what it is breaking.
param(
  [switch]$Sign,
  [switch]$Upload,
  [switch]$SkipBuild,
  [switch]$Replace,
  [string]$Iscc,
  [string]$Repo = 'garacil/superterm'
)

$ErrorActionPreference = 'Stop'

# Inno Setup 7 installs under the 64-bit Program Files, 6 under the 32-bit one,
# so neither path alone survives an upgrade: take -Iscc, else SUPERTERM_ISCC,
# else the newest installation found. The script is compatible with both.
if (-not $Iscc) {
  if ($env:SUPERTERM_ISCC) {
    $Iscc = $env:SUPERTERM_ISCC
  } else {
    $Iscc = @(7, 6) |
      ForEach-Object { $v = $_; @($env:ProgramFiles, ${env:ProgramFiles(x86)}) |
        ForEach-Object { Join-Path $_ "Inno Setup $v\ISCC.exe" } } |
      Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1
  }
}
if (-not $Iscc) { throw 'Inno Setup compiler not found; install it or set SUPERTERM_ISCC' }
$root = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$version = (Get-Content (Join-Path $root 'VERSION') -Raw).Trim()
$dist = Join-Path $root 'dist'
$exe = Join-Path $root 'bin\superterm.exe'
$tray = Join-Path $root 'bin\superterm-tray.exe'
$setupName = "SuperTerm-$version-windows-x64-setup.exe"
$zipName = "superterm-$version-windows-x86_64.zip"
$setup = Join-Path $dist $setupName
$zip = Join-Path $dist $zipName

function Step($s) { Write-Output ("== {0}" -f $s) }

# The Makefile is written for GNU Make under a POSIX shell: run it through
# Git's bash, with the make that ships next to the configured fpc (the
# Embarcadero make configure may have recorded is not the project's).
if (-not $SkipBuild) {
  Step "build $version"
  $cfg = Get-Content (Join-Path $root 'config.status') | ForEach-Object { $_ -split '=', 2 }
  $fpc = (Get-Content (Join-Path $root 'config.status') | Where-Object { $_ -like 'fpc=*' }) -replace '^fpc=', ''
  if (-not $fpc) { throw 'config.status has no fpc= line; run ./configure first' }
  $makePosix = ($fpc -replace '/[^/]+$', '') + '/make'
  $git = (Get-Command git.exe -ErrorAction Stop).Source
  $bash = Join-Path (Split-Path (Split-Path $git -Parent) -Parent) 'bin\bash.exe'
  if (-not (Test-Path $bash)) { throw "bash.exe not found next to git ($bash)" }
  $rootPosix = '/' + ($root.Substring(0, 1).ToLower()) + ($root.Substring(2) -replace '\\', '/')
  & $bash -lc "cd '$rootPosix' && '$makePosix' release"
  if ($LASTEXITCODE -ne 0) { throw 'make release failed' }
  & $bash -lc "cd '$rootPosix' && '$makePosix' traytool"
  if ($LASTEXITCODE -ne 0) { throw 'make traytool failed' }
  if (-not (Test-Path $tray)) { throw 'superterm-tray.exe was not built' }
  $reported = (& $exe --version | Select-Object -First 1)
  if ($reported -notmatch [regex]::Escape($version)) { throw "built binary reports '$reported', expected $version" }
  $vi = (Get-Item $exe).VersionInfo
  if ($vi.ProductVersion -ne $version) { throw "version resource says '$($vi.ProductVersion)', expected $version (superterm.res stale?)" }
  Write-Output "  $reported, version resource $($vi.ProductVersion), $($vi.CompanyName)"
}

if ($Sign) {
  Step 'sign superterm.exe and superterm-tray.exe'
  & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'sign.ps1') $exe $tray
  if ($LASTEXITCODE -ne 0) { throw 'signing the executables failed' }
}

Step 'installer'
if (-not (Test-Path $Iscc)) { throw "Inno Setup compiler not found at $Iscc" }
$isccArgs = @('/Q')
if ($Sign) {
  $signCmd = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$(Join-Path $PSScriptRoot 'sign.ps1')`" `$f"
  $isccArgs += @('/DSIGN', "/Ssuperterm=$signCmd")
}
if (Test-Path $setup) { Remove-Item $setup }
& $Iscc @isccArgs (Join-Path $PSScriptRoot 'superterm.iss')
if ($LASTEXITCODE -ne 0 -or -not (Test-Path $setup)) { throw 'ISCC failed' }

Step 'zip'
$stage = Join-Path $env:TEMP ("superterm-zip-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $stage | Out-Null
Copy-Item $exe, $tray, (Join-Path $PSScriptRoot 'superterm-launch.cmd'), (Join-Path $root 'README.md'), (Join-Path $root 'LICENSE'), (Join-Path $root 'docs\WINDOWS.md') $stage
Copy-Item (Join-Path $root 'backgrounds\*.art') $stage
if (Test-Path $zip) { Remove-Item $zip }
Compress-Archive -Path "$stage\*" -DestinationPath $zip
Remove-Item -Recurse -Force $stage

Step 'checksums'
$assets = @()
foreach ($f in @($setup, $zip)) {
  $n = Split-Path $f -Leaf
  $h = (Get-FileHash $f -Algorithm SHA256).Hash.ToLower()
  [IO.File]::WriteAllText("$f.sha256", "$h  $n`n")
  Write-Output "  $h  $n"
  $assets += @($f, "$f.sha256")
}
if ($Sign) {
  foreach ($f in @($exe, $tray, $setup)) {
    $s = Get-AuthenticodeSignature $f
    if ($s.Status -ne 'Valid') { throw "$f is not validly signed ($($s.Status))" }
  }
  Write-Output "  signatures valid: $((Get-AuthenticodeSignature $setup).SignerCertificate.Subject)"
}

if ($Upload) {
  Step "upload to $Repo release v$version"
  # git credential wants LF-terminated key=value lines on stdin; a PowerShell
  # pipeline re-encodes them, so hand it a file through cmd instead.
  $req = Join-Path $env:TEMP ("st-cred-" + [guid]::NewGuid().ToString('N') + '.txt')
  [IO.File]::WriteAllText($req, "protocol=https`nhost=github.com`n`n")
  try {
    $token = ((& cmd.exe /c "git credential fill < `"$req`"") | Where-Object { $_ -like 'password=*' }) -replace '^password=', ''
  } finally { Remove-Item $req -ErrorAction SilentlyContinue }
  if (-not $token) { throw 'no GitHub credential from git credential fill' }
  $hdr = @{ Authorization = "Bearer $token"; 'User-Agent' = 'superterm-release' }
  $rel = Invoke-RestMethod -Headers $hdr -Uri "https://api.github.com/repos/$Repo/releases/tags/v$version"
  # Refuse the whole upload before changing anything: a run that replaced two
  # assets and then stopped would leave the release in a state nobody chose.
  $clash = @($assets | ForEach-Object { Split-Path $_ -Leaf } |
    Where-Object { $n = $_; $rel.assets | Where-Object { $_.name -eq $n } })
  if ($clash -and -not $Replace) {
    throw ("v$version already publishes " + ($clash -join ', ') +
      ". Those URLs are handed out and must keep their bytes; bump VERSION and " +
      'release again, or pass -Replace if this release has not been consumed.')
  }
  foreach ($f in $assets) {
    $n = Split-Path $f -Leaf
    $old = $rel.assets | Where-Object { $_.name -eq $n }
    foreach ($o in $old) {
      Invoke-RestMethod -Headers $hdr -Method Delete -Uri "https://api.github.com/repos/$Repo/releases/assets/$($o.id)" | Out-Null
      Write-Warning "replaced ${n}: anyone who already downloaded this URL has different bytes"
    }
    $ct = if ($n -like '*.sha256') { 'text/plain' } elseif ($n -like '*.zip') { 'application/zip' } else { 'application/octet-stream' }
    $r = Invoke-RestMethod -Headers $hdr -Method Post -ContentType $ct -InFile $f -Uri "https://uploads.github.com/repos/$Repo/releases/$($rel.id)/assets?name=$n"
    Write-Output "  uploaded $n ($($r.size) bytes)"
  }
  # What Partner Center wants in the submission's download URL field.
  Write-Output ''
  Write-Output '  Microsoft Store download URL for this version:'
  Write-Output "    https://github.com/$Repo/releases/download/v$version/$setupName"
}

Step 'done'
Get-ChildItem $dist -Filter "*$version*" | Select-Object Name, Length, LastWriteTime | Format-Table -AutoSize
