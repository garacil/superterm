# Drives a console program in a new Windows Terminal window and captures what
# the host actually renders, so resize behaviour can be checked without a
# person at the keyboard.
#
#   hosttest.ps1 -Exe <program> [-ExeArgs '...'] [-Tag NAME]
#                [-DebugLog path] [-Tee path]      set SUPERTERM_DEBUG / SUPERTERM_TEE for it
#                [-Click]                          click into the window after each resize
#                [-Drag]                           grow and shrink the window in steps instead
#                [-InjectText 'echo KEYS-OK']      feed key records with WriteConsoleInput first
#                [-Hook { param($stage) ... }]     run after each capture ('0-initial', ...)
#                [-Conhost]                        host in the legacy console instead
#                [-KeepOpen]                       leave the window for a person to use
#
# Captures land in shots\<Tag>\ as PNG: the whole window, plus top-left and
# bottom-right crops at full resolution so row headers stay legible.
# See README.md in this directory.
param(
  [Parameter(Mandatory = $true)][string]$Exe,
  [string]$ExeArgs = '',
  [string]$Tag = 'STHOST',
  [string]$ProcName = '',
  [string]$DebugLog = '',
  [string]$Tee = '',
  [switch]$Conhost,
  [switch]$Click,
  [switch]$Drag,
  [int]$DragSteps = 24,
  [int]$DragDx = 48,
  [int]$DragDy = 28,
  [int]$DragIntervalMs = 40,
  [string]$InjectText = '',
  [int]$SettleMs = 2500,
  [string]$OutDir = '',
  [scriptblock]$Hook = $null,
  [switch]$KeepOpen
)

$ErrorActionPreference = 'Stop'
if ($OutDir -eq '') { $OutDir = Join-Path $PSScriptRoot "shots\$Tag" }
if ($ProcName -eq '') { $ProcName = [System.IO.Path]::GetFileNameWithoutExtension($Exe) }

Add-Type -AssemblyName System.Drawing
Add-Type -TypeDefinition @'
using System;
using System.Text;
using System.Runtime.InteropServices;
using System.Collections.Generic;

public static class W32 {
  public delegate bool EnumProc(IntPtr h, IntPtr l);
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc p, IntPtr l);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetClassName(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int cmd);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern bool MoveWindow(IntPtr h, int x, int y, int w, int hh, bool repaint);
  [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr h, IntPtr hdc, uint flags);
  [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr h, uint msg, IntPtr w, IntPtr l);
  [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
  [DllImport("user32.dll")] public static extern void mouse_event(uint flags, uint dx, uint dy, uint data, UIntPtr extra);
  [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();

  [StructLayout(LayoutKind.Sequential)]
  public struct RECT { public int Left, Top, Right, Bottom; }

  public class Win { public IntPtr H; public string Title; public string Cls; public uint Pid; }

  public static List<Win> List() {
    var r = new List<Win>();
    EnumWindows((h, l) => {
      if (!IsWindowVisible(h)) return true;
      var t = new StringBuilder(512); GetWindowText(h, t, 512);
      var c = new StringBuilder(256); GetClassName(h, c, 256);
      uint pid; GetWindowThreadProcessId(h, out pid);
      r.Add(new Win { H = h, Title = t.ToString(), Cls = c.ToString(), Pid = pid });
      return true;
    }, IntPtr.Zero);
    return r;
  }
}
'@

[void][W32]::SetProcessDPIAware()
if (-not (Test-Path $OutDir)) { New-Item -ItemType Directory -Path $OutDir | Out-Null }

function Log($s) { Write-Output ("{0:HH:mm:ss.fff} {1}" -f (Get-Date), $s) }

function Find-Win {
  param([string]$Title, [string]$Cls)
  foreach ($w in [W32]::List()) {
    if ($w.Cls -eq $Cls -and $w.Title -like "*$Title*") { return $w }
  }
  return $null
}

function Shot {
  param([IntPtr]$H, [string]$Name)
  $r = New-Object W32+RECT
  [void][W32]::GetWindowRect($H, [ref]$r)
  $w = $r.Right - $r.Left; $hgt = $r.Bottom - $r.Top
  if ($w -le 0 -or $hgt -le 0) { Log "shot ${Name}: empty rect"; return }
  $bmp = New-Object System.Drawing.Bitmap $w, $hgt
  $g = [System.Drawing.Graphics]::FromImage($bmp)
  $hdc = $g.GetHdc()
  $ok = [W32]::PrintWindow($H, $hdc, 2)
  $g.ReleaseHdc($hdc)
  # an all-black capture means PrintWindow could not render it: use the screen
  $black = $true
  for ($y = 10; $y -lt $hgt -and $black; $y += [Math]::Max(1, [int]($hgt / 12))) {
    for ($x = 10; $x -lt $w; $x += [Math]::Max(1, [int]($w / 12))) {
      $c = $bmp.GetPixel($x, $y)
      if ($c.R + $c.G + $c.B -gt 30) { $black = $false; break }
    }
  }
  if (-not $ok -or $black) {
    $g.CopyFromScreen($r.Left, $r.Top, 0, 0, (New-Object System.Drawing.Size $w, $hgt))
    $how = 'screen'
  } else { $how = 'printwindow' }
  $g.Dispose()
  $bmp.Save((Join-Path $OutDir "$Name.png"), [System.Drawing.Imaging.ImageFormat]::Png)
  $cw = [Math]::Min(1100, $w); $ch = [Math]::Min(520, $hgt)
  $crop = $bmp.Clone((New-Object System.Drawing.Rectangle 0, 0, $cw, $ch), $bmp.PixelFormat)
  $crop.Save((Join-Path $OutDir "$Name-tl.png"), [System.Drawing.Imaging.ImageFormat]::Png)
  $crop.Dispose()
  $bx = [Math]::Max(0, $w - 1100); $by = [Math]::Max(0, $hgt - 520)
  $crop = $bmp.Clone((New-Object System.Drawing.Rectangle $bx, $by, ($w - $bx), ($hgt - $by)), $bmp.PixelFormat)
  $crop.Save((Join-Path $OutDir "$Name-br.png"), [System.Drawing.Imaging.ImageFormat]::Png)
  $crop.Dispose()
  $bmp.Dispose()
  Log ("shot {0}: {1}x{2} at ({3},{4}) via {5}" -f $Name, $w, $hgt, $r.Left, $r.Top, $how)
  if ($Hook) { & $Hook $Name }
}

function Click-Center {
  param([IntPtr]$H)
  $r = New-Object W32+RECT
  [void][W32]::GetWindowRect($H, [ref]$r)
  $x = [int](($r.Left + $r.Right) / 2); $y = [int](($r.Top + $r.Bottom) / 2)
  [void][W32]::SetForegroundWindow($H)
  Start-Sleep -Milliseconds 150
  [void][W32]::SetCursorPos($x, $y)
  Start-Sleep -Milliseconds 80
  [W32]::mouse_event(0x0002, 0, 0, 0, [UIntPtr]::Zero)   # LEFTDOWN
  Start-Sleep -Milliseconds 60
  [W32]::mouse_event(0x0004, 0, 0, 0, [UIntPtr]::Zero)   # LEFTUP
  Log "click at ($x,$y)"
}

# Environment does not reach a program started by an already running Windows
# Terminal, so a wrapper batch file carries it.
$launchExe = $Exe; $launchArgs = $ExeArgs
if ($DebugLog -ne '' -or $Tee -ne '') {
  $wrapper = Join-Path $env:TEMP "st-host-$Tag.cmd"
  $body = "@echo off`r`n"
  if ($DebugLog -ne '') { $body += "set SUPERTERM_DEBUG=$DebugLog`r`n" }
  if ($Tee -ne '') { $body += "set SUPERTERM_TEE=$Tee`r`n" }
  $body += "`"$Exe`" $ExeArgs`r`n"
  [IO.File]::WriteAllText($wrapper, $body)
  $launchExe = 'cmd.exe'; $launchArgs = "/c $wrapper"
}

$before = @(Get-Process -Name $ProcName -ErrorAction SilentlyContinue | ForEach-Object { $_.Id })

if ($Conhost) {
  $cls = 'ConsoleWindowClass'
  $cmd = "title $Tag & `"$launchExe`" $launchArgs"
  Log "launch conhost: cmd /c $cmd"
  Start-Process -FilePath 'conhost.exe' -ArgumentList @('cmd.exe', '/c', $cmd) | Out-Null
} else {
  $cls = 'CASCADIA_HOSTING_WINDOW_CLASS'
  $argl = "-w -1 new-tab --title $Tag --suppressApplicationTitle -- `"$launchExe`" $launchArgs"
  Log "launch wt: wt.exe $argl"
  Start-Process -FilePath 'wt.exe' -ArgumentList $argl | Out-Null
}

$win = $null
$deadline = (Get-Date).AddSeconds(15)
while (-not $win -and (Get-Date) -lt $deadline) {
  Start-Sleep -Milliseconds 250
  $win = Find-Win -Title $Tag -Cls $cls
}
if (-not $win) {
  Log "window '$Tag' ($cls) not found; visible windows:"
  [W32]::List() | Where-Object { $_.Title } | ForEach-Object { "  [$($_.Cls)] $($_.Title)" }
  exit 2
}
$h = $win.H
Log ("window found: hwnd=0x{0:X} pid={1} title='{2}'" -f $h.ToInt64(), $win.Pid, $win.Title)

Start-Sleep -Milliseconds 2500

if ($InjectText -ne '') {
  $p = Get-Process -Name $ProcName -ErrorAction SilentlyContinue | Where-Object { $before -notcontains $_.Id } | Select-Object -First 1
  if ($p) {
    $out = Join-Path $OutDir 'inject.txt'
    Start-Process -FilePath 'powershell.exe' -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "$PSScriptRoot\injectkeys.ps1", '-ProcId', $p.Id, '-Text', "`"$InjectText`"", '-Out', $out) -Wait -WindowStyle Hidden
    Log ("inject: " + (Get-Content $out -Raw).Trim())
    Start-Sleep -Milliseconds 800
  } else { Log "inject: no new $ProcName process found" }
}

Shot $h '0-initial'

if ($Drag) {
  $r = New-Object W32+RECT
  [void][W32]::GetWindowRect($h, [ref]$r)
  $x = $r.Left; $y = $r.Top; $w = $r.Right - $r.Left; $hh = $r.Bottom - $r.Top
  Log "drag: $DragSteps steps of +$DragDx,+$DragDy every $DragIntervalMs ms from ${w}x${hh}"
  for ($i = 1; $i -le $DragSteps; $i++) {
    $w += $DragDx; $hh += $DragDy
    [void][W32]::MoveWindow($h, $x, $y, $w, $hh, $true)
    if ($i -eq [int]($DragSteps / 2)) { Shot $h '1-mid-grow' }
    Start-Sleep -Milliseconds $DragIntervalMs
  }
  Shot $h '2-end-grow'
  Start-Sleep -Milliseconds 500
  Shot $h '3-settled-large'
  for ($i = 1; $i -le $DragSteps; $i++) {
    $w -= $DragDx; $hh -= $DragDy
    [void][W32]::MoveWindow($h, $x, $y, $w, $hh, $true)
    if ($i -eq [int]($DragSteps / 2)) { Shot $h '4-mid-shrink' }
    Start-Sleep -Milliseconds $DragIntervalMs
  }
  Shot $h '5-end-shrink'
  Start-Sleep -Milliseconds 500
  Shot $h '6-settled-small'
} else {
  Log 'maximize'
  [void][W32]::ShowWindow($h, 3)   # SW_MAXIMIZE
  Start-Sleep -Milliseconds $SettleMs
  Shot $h '1-maximized'
  if ($Click) {
    Click-Center $h
    Start-Sleep -Milliseconds 1200
    Shot $h '2-maximized-clicked'
  }
  Log 'restore'
  [void][W32]::ShowWindow($h, 9)   # SW_RESTORE
  Start-Sleep -Milliseconds $SettleMs
  Shot $h '3-restored'
  if ($Click) {
    Click-Center $h
    Start-Sleep -Milliseconds 1200
    Shot $h '4-restored-clicked'
  }
}

Log ("foreground now: 0x{0:X}" -f ([W32]::GetForegroundWindow()).ToInt64())

if (-not $KeepOpen) {
  Log 'close'
  [void][W32]::PostMessage($h, 0x0010, [IntPtr]::Zero, [IntPtr]::Zero)   # WM_CLOSE
  Start-Sleep -Milliseconds 1500
  Get-Process -Name $ProcName -ErrorAction SilentlyContinue | Where-Object { $before -notcontains $_.Id } | ForEach-Object {
    Log "kill leftover $($_.Name) pid=$($_.Id)"
    Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue
  }
  $w2 = Find-Win -Title $Tag -Cls $cls
  if ($w2) { Log 'window still open after WM_CLOSE'; [void][W32]::PostMessage($w2.H, 0x0010, [IntPtr]::Zero, [IntPtr]::Zero) }
}
Log 'done'
