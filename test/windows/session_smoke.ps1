# End-to-end check of Windows detached sessions, driven from a script so no
# hands touch the keyboard. It starts a named session in a Windows Terminal
# window, detaches it by injecting the prefix+d chord, confirms the server
# process outlives the window, reattaches in a second window, and kills the
# session. Each CLI answer is asserted.
#
#   powershell -ExecutionPolicy Bypass -File test\windows\session_smoke.ps1
#
# Requires a built bin\superterm.exe and Windows Terminal as the default
# terminal. Leaves nothing behind on success.
param(
  [string]$Exe = 'D:\sources\superterm\bin\superterm.exe',
  [string]$Name = 'smoke1',
  [string]$PrefixChord = 'd'
)
$ErrorActionPreference = 'Continue'
$here = $PSScriptRoot
$fails = 0
function Check($cond, $what) {
  if ($cond) { Write-Output "ok    $what" }
  else { Write-Output "FAIL  $what"; $script:fails++ }
}
function Stc { & $Exe @args 2>&1 }

Add-Type -TypeDefinition @'
using System;
using System.Text;
using System.Runtime.InteropServices;
using System.Collections.Generic;
public static class WS {
  public delegate bool EnumProc(IntPtr h, IntPtr l);
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc p, IntPtr l);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetClassName(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr h, uint m, IntPtr w, IntPtr l);
  public static IntPtr Find(string title) {
    IntPtr found = IntPtr.Zero;
    EnumWindows((h, l) => {
      if (!IsWindowVisible(h)) return true;
      var c = new StringBuilder(256); GetClassName(h, c, 256);
      var t = new StringBuilder(512); GetWindowText(h, t, 512);
      if (c.ToString() == "CASCADIA_HOSTING_WINDOW_CLASS" && t.ToString().Contains(title)) { found = h; return false; }
      return true;
    }, IntPtr.Zero);
    return found;
  }
}
'@

# make sure no stale session of this name exists
Stc kill $Name | Out-Null
Start-Sleep -Milliseconds 500

$tag = "SMOKE_$(Get-Random)"
$argl = "-w -1 new-tab --title $tag --suppressApplicationTitle -- `"$Exe`" --session $Name"
Write-Output "launch: wt.exe $argl"
Start-Process -FilePath 'wt.exe' -ArgumentList $argl
Start-Sleep -Seconds 4

$proc = Get-CimInstance Win32_Process -Filter "Name='superterm.exe'" |
  Where-Object { $_.CommandLine -like "*--session $Name*" } | Select-Object -First 1
Check ($null -ne $proc) 'client process started'
$daemon = Get-CimInstance Win32_Process -Filter "Name='superterm.exe'" |
  Where-Object { $_.CommandLine -like '*--session-daemon*' } | Select-Object -First 1
Check ($null -ne $daemon) 'session server process started'

$list = Stc list
Check (($list -join "`n") -match [regex]::Escape($Name)) 'list shows the session'

Stc send "$Name" 'echo SMOKE-MARKER' | Out-Null
Start-Sleep -Milliseconds 800
$cap = Stc capture $Name
Check (($cap -join "`n") -match 'SMOKE-MARKER') 'capture shows sent input'

# detach: inject Ctrl-<something> is the prefix; default prefix is Ctrl-Q (0x11)
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$here\injectkeys.ps1" `
  -ProcId $proc.ProcessId -Text ([char]17 + $PrefixChord) -Out "$env:TEMP\smoke-detach.txt" | Out-Null
Start-Sleep -Seconds 3
$clientGone = -not (Get-Process -Id $proc.ProcessId -ErrorAction SilentlyContinue)
Check $clientGone 'client exited on detach'
$daemonAlive = $null -ne (Get-Process -Id $daemon.ProcessId -ErrorAction SilentlyContinue)
Check $daemonAlive 'session server survived detach'

$list = Stc list
Check (($list -join "`n") -match [regex]::Escape($Name)) 'session still listed after detach'

Stc send "$Name" 'echo AFTER-DETACH' | Out-Null
Start-Sleep -Milliseconds 800
$cap = Stc capture $Name
Check (($cap -join "`n") -match 'AFTER-DETACH') 'detached session still accepts input'

# reattach
$tag2 = "SMOKE2_$(Get-Random)"
$argl2 = "-w -1 new-tab --title $tag2 --suppressApplicationTitle -- `"$Exe`" attach $Name"
Start-Process -FilePath 'wt.exe' -ArgumentList $argl2
Start-Sleep -Seconds 4
$client2 = Get-CimInstance Win32_Process -Filter "Name='superterm.exe'" |
  Where-Object { $_.CommandLine -like "*attach $Name*" } | Select-Object -First 1
Check ($null -ne $client2) 'reattach client started'
$list = Stc list
Check (($list -join "`n") -match '\s1\s') 'reattached session reports a client'

# close the reattached window, then kill the session
$w = [WS]::Find($tag2)
if ($w -ne [IntPtr]::Zero) { [void][WS]::PostMessage($w, 0x0010, [IntPtr]::Zero, [IntPtr]::Zero) }
Start-Sleep -Seconds 2
$kill = Stc kill $Name
Check (($kill -join "`n") -match 'terminated|terminada') 'kill terminated the session'
Start-Sleep -Milliseconds 800
$list = Stc list
Check (($list -join "`n") -match 'no sessions|no hay sesiones') 'no sessions remain'

Get-Process -Name superterm -ErrorAction SilentlyContinue |
  Where-Object { $_.Id -eq $daemon.ProcessId } | Stop-Process -Force -ErrorAction SilentlyContinue

Write-Output ""
if ($fails -eq 0) { Write-Output 'session_smoke: PASS' } else { Write-Output "session_smoke: $fails FAILED"; exit 1 }
