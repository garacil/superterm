# Feeds keystrokes to another process's console with WriteConsoleInput: one
# key-down and one key-up record per character, straight into the input queue,
# independent of window focus. Exercises the same path a real keyboard takes
# through the keyboard driver.
#
#   injectkeys.ps1 -ProcId <pid> -Text 'echo KEYS-OK' -Out <file>
param([int]$ProcId, [string]$Text, [string]$Out)
$lines = New-Object System.Collections.Generic.List[string]
try {
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class KI {
  [DllImport("kernel32.dll", SetLastError=true)] public static extern bool FreeConsole();
  [DllImport("kernel32.dll", SetLastError=true)] public static extern bool AttachConsole(uint pid);
  [DllImport("kernel32.dll", SetLastError=true, CharSet=CharSet.Unicode)] public static extern IntPtr CreateFile(string n, uint a, uint s, IntPtr sa, uint d, uint f, IntPtr t);
  [DllImport("kernel32.dll", SetLastError=true)] public static extern bool WriteConsoleInputW(IntPtr h, INPUT_RECORD[] buf, uint n, out uint written);
  [StructLayout(LayoutKind.Explicit, Size=20)]
  public struct INPUT_RECORD {
    [FieldOffset(0)] public ushort EventType;
    [FieldOffset(4)] public int bKeyDown;
    [FieldOffset(8)] public ushort wRepeatCount;
    [FieldOffset(10)] public ushort wVirtualKeyCode;
    [FieldOffset(12)] public ushort wVirtualScanCode;
    [FieldOffset(14)] public char UnicodeChar;
    [FieldOffset(16)] public uint dwControlKeyState;
  }
}
'@
  [void][KI]::FreeConsole()
  if (-not [KI]::AttachConsole([uint32]$ProcId)) { throw ("attach failed: " + [Runtime.InteropServices.Marshal]::GetLastWin32Error()) }
  $h = [KI]::CreateFile('CONIN$', [uint32]3221225472, 3, [IntPtr]::Zero, 3, 0, [IntPtr]::Zero)
  if ($h.ToInt64() -eq -1) { throw ("CONIN open failed: " + [Runtime.InteropServices.Marshal]::GetLastWin32Error()) }
  $recs = New-Object 'KI+INPUT_RECORD[]' ($Text.Length * 2)
  $i = 0
  foreach ($ch in $Text.ToCharArray()) {
    foreach ($down in 1, 0) {
      $r = New-Object KI+INPUT_RECORD
      $r.EventType = 1; $r.bKeyDown = $down; $r.wRepeatCount = 1
      $r.wVirtualKeyCode = 0; $r.wVirtualScanCode = 0; $r.UnicodeChar = $ch; $r.dwControlKeyState = 0
      $recs[$i] = $r; $i++
    }
  }
  $w = 0
  if (-not [KI]::WriteConsoleInputW($h, $recs, [uint32]$recs.Length, [ref]$w)) { throw ("WriteConsoleInput failed: " + [Runtime.InteropServices.Marshal]::GetLastWin32Error()) }
  $lines.Add("injected $w records into console of pid $ProcId")
} catch {
  $lines.Add("error: $_")
} finally {
  $lines | Out-File $Out -Encoding utf8
  try { [void][KI]::FreeConsole() } catch {}
}
