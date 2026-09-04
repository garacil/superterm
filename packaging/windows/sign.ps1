# Signs Windows executables with Authenticode and an RFC 3161 timestamp, then
# verifies them. Used directly, by Inno Setup through the SignTool hook in
# superterm.iss, and by release.ps1.
#
#   sign.ps1 <file> [<file> ...]
#
# The certificate comes from the environment, first match wins:
#   SUPERTERM_SIGN_THUMBPRINT   SHA-1 thumbprint of a certificate in the
#                               current user's store (a hardware token or an
#                               HSM-backed certificate shows up there too)
#   SUPERTERM_SIGN_PFX          path of a .pfx file, with
#   SUPERTERM_SIGN_PFX_PASSWORD its password
#   SUPERTERM_SIGN_DLIB         Azure Trusted Signing: path of
#                               Azure.CodeSigning.Dlib.dll, with
#   SUPERTERM_SIGN_METADATA     the JSON metadata file for the account
#                               (packaging\windows\trusted-signing.json)
#   SUPERTERM_SIGN_TIMESTAMP    timestamp server (default DigiCert's)
#
# Trusted Signing authenticates through DefaultAzureCredential, which this
# script does not touch: the dlib reads it from the environment. Either run
# `az login` as a principal with the Trusted Signing Certificate Profile
# Signer role, or set AZURE_TENANT_ID, AZURE_CLIENT_ID and
# AZURE_CLIENT_SECRET. Without credentials signtool fails inside the dlib,
# not here, and the message names the account rather than the login.
#
# Exit codes: 0 signed and verified, 2 no certificate configured, 3 signtool
# not found, 1 signing or verification failed. Without a certificate this
# script refuses rather than producing an unsigned artifact, so a signed
# build cannot silently come out unsigned.
param(
  [Parameter(Position = 0, ValueFromRemainingArguments = $true)][string[]]$Files
)

$ErrorActionPreference = 'Stop'

function Find-SignTool {
  if ($env:SUPERTERM_SIGNTOOL -and (Test-Path $env:SUPERTERM_SIGNTOOL)) { return $env:SUPERTERM_SIGNTOOL }
  $cmd = Get-Command signtool.exe -ErrorAction SilentlyContinue
  if ($cmd) { return $cmd.Source }
  $kits = "${env:ProgramFiles(x86)}\Windows Kits\10\bin"
  if (Test-Path $kits) {
    $found = Get-ChildItem $kits -Directory | Where-Object { $_.Name -match '^10\.' } |
      Sort-Object { [version]$_.Name } -Descending |
      ForEach-Object { Join-Path $_.FullName 'x64\signtool.exe' } |
      Where-Object { Test-Path $_ } | Select-Object -First 1
    if ($found) { return $found }
  }
  return $null
}

if (-not $Files -or $Files.Count -eq 0) { Write-Error 'sign.ps1: no files given'; exit 1 }
$Files = $Files | ForEach-Object { $_.Trim('"') }

$signtool = Find-SignTool
if (-not $signtool) {
  Write-Error 'sign.ps1: signtool.exe not found (install the Windows SDK, or set SUPERTERM_SIGNTOOL)'
  exit 3
}

$ts = if ($env:SUPERTERM_SIGN_TIMESTAMP) { $env:SUPERTERM_SIGN_TIMESTAMP } else { 'http://timestamp.digicert.com' }
$common = @('sign', '/fd', 'SHA256', '/td', 'SHA256', '/tr', $ts,
            '/d', 'SuperTerm', '/du', 'https://superterm.org')

if ($env:SUPERTERM_SIGN_THUMBPRINT) {
  $cred = @('/sha1', $env:SUPERTERM_SIGN_THUMBPRINT)
  $how = "certificate $($env:SUPERTERM_SIGN_THUMBPRINT) from the user store"
} elseif ($env:SUPERTERM_SIGN_PFX) {
  $cred = @('/f', $env:SUPERTERM_SIGN_PFX)
  if ($env:SUPERTERM_SIGN_PFX_PASSWORD) { $cred += @('/p', $env:SUPERTERM_SIGN_PFX_PASSWORD) }
  $how = "pfx $($env:SUPERTERM_SIGN_PFX)"
} elseif ($env:SUPERTERM_SIGN_DLIB -and $env:SUPERTERM_SIGN_METADATA) {
  $cred = @('/dlib', $env:SUPERTERM_SIGN_DLIB, '/dmdf', $env:SUPERTERM_SIGN_METADATA)
  $how = 'Azure Trusted Signing'
} else {
  Write-Error 'sign.ps1: no certificate configured (SUPERTERM_SIGN_THUMBPRINT, SUPERTERM_SIGN_PFX or SUPERTERM_SIGN_DLIB+SUPERTERM_SIGN_METADATA)'
  exit 2
}

foreach ($f in $Files) {
  if (-not (Test-Path $f)) { Write-Error "sign.ps1: $f does not exist"; exit 1 }
  Write-Output "signing $f with $how"
  & $signtool @common @cred $f
  if ($LASTEXITCODE -ne 0) { Write-Error "sign.ps1: signtool sign failed for $f"; exit 1 }
  & $signtool verify /pa /v $f | Out-Null
  if ($LASTEXITCODE -ne 0) { Write-Error "sign.ps1: signature of $f does not verify"; exit 1 }
  $sig = Get-AuthenticodeSignature $f
  Write-Output ("  {0}: {1}" -f $sig.Status, $sig.SignerCertificate.Subject)
}
exit 0
