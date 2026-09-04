# Dumps what conhost holds for another process's console: buffer and window
# geometry, cursor, output mode, and every row with its distinct attributes.
# Attaches to the console of -ProcId, so the target must share that console
# (for a program started through a cmd.exe wrapper, use the wrapper's pid).
#
#   condump.ps1 -ProcId <pid> -Out <file>
param([int]$ProcId, [string]$Out)
$lines = New-Object System.Collections.Generic.List[string]
try {
Add-Type -TypeDefinition @'
using System;
using System.Text;
using System.Runtime.InteropServices;
public static class K {
  [DllImport("kernel32.dll", SetLastError=true)] public static extern bool FreeConsole();
  [DllImport("kernel32.dll", SetLastError=true)] public static extern bool AttachConsole(uint pid);
  [DllImport("kernel32.dll", SetLastError=true, CharSet=CharSet.Unicode)] public static extern IntPtr CreateFile(string n, uint a, uint s, IntPtr sa, uint d, uint f, IntPtr t);
  [DllImport("kernel32.dll", SetLastError=true)] public static extern bool GetConsoleScreenBufferInfo(IntPtr h, out CSBI i);
  [DllImport("kernel32.dll", SetLastError=true)] public static extern bool GetConsoleMode(IntPtr h, out uint m);
  [DllImport("kernel32.dll", SetLastError=true, CharSet=CharSet.Unicode)] public static extern bool ReadConsoleOutputCharacterW(IntPtr h, StringBuilder s, uint n, COORD c, out uint r);
  [DllImport("kernel32.dll", SetLastError=true)] public static extern bool ReadConsoleOutputAttribute(IntPtr h, ushort[] a, uint n, COORD c, out uint r);
  [StructLayout(LayoutKind.Sequential)] public struct COORD { public short X, Y; }
  [StructLayout(LayoutKind.Sequential)] public struct SMALL_RECT { public short Left, Top, Right, Bottom; }
  [StructLayout(LayoutKind.Sequential)] public struct CSBI { public COORD dwSize; public COORD dwCursorPosition; public ushort wAttributes; public SMALL_RECT srWindow; public COORD dwMaximumWindowSize; }
}
'@
  [void][K]::FreeConsole()
  if (-not [K]::AttachConsole([uint32]$ProcId)) {
    throw ("attach to $ProcId failed: " + [Runtime.InteropServices.Marshal]::GetLastWin32Error())
  }
  # GENERIC_READ | GENERIC_WRITE, FILE_SHARE_READ | FILE_SHARE_WRITE, OPEN_EXISTING
  $h = [K]::CreateFile('CONOUT$', [uint32]3221225472, 3, [IntPtr]::Zero, 3, 0, [IntPtr]::Zero)
  if ($h -eq [IntPtr]::Zero -or $h.ToInt64() -eq -1) { throw ("CONOUT open failed: " + [Runtime.InteropServices.Marshal]::GetLastWin32Error()) }
  $i = New-Object K+CSBI
  if (-not [K]::GetConsoleScreenBufferInfo($h, [ref]$i)) { throw ("GetConsoleScreenBufferInfo failed: " + [Runtime.InteropServices.Marshal]::GetLastWin32Error()) }
  $m = 0; [void][K]::GetConsoleMode($h, [ref]$m)
  $lines.Add(("buffer={0}x{1} window=({2},{3})-({4},{5}) => {6}x{7} cursor=({8},{9}) attr=0x{10:X} outmode=0x{11:X}" -f $i.dwSize.X, $i.dwSize.Y, $i.srWindow.Left, $i.srWindow.Top, $i.srWindow.Right, $i.srWindow.Bottom, ($i.srWindow.Right-$i.srWindow.Left+1), ($i.srWindow.Bottom-$i.srWindow.Top+1), $i.dwCursorPosition.X, $i.dwCursorPosition.Y, $i.wAttributes, $m))
  $w = [int]$i.dwSize.X
  $nonblank = 0
  for ($y = 0; $y -lt [Math]::Min([int]$i.dwSize.Y, 400); $y++) {
    $sb = New-Object System.Text.StringBuilder ($w + 1)
    $c = New-Object K+COORD; $c.X = 0; $c.Y = [int16]$y
    $r = 0
    [void][K]::ReadConsoleOutputCharacterW($h, $sb, [uint32]$w, $c, [ref]$r)
    $a = New-Object 'uint16[]' $w
    [void][K]::ReadConsoleOutputAttribute($h, $a, [uint32]$w, $c, [ref]$r)
    $t = $sb.ToString().TrimEnd()
    $attrs = ($a | Select-Object -Unique | ForEach-Object { '{0:X}' -f $_ }) -join ','
    if ($t.Length -gt 0) { $nonblank++ }
    $lines.Add(("{0,4}: [{1}] {2}" -f $y, $attrs, $t))
  }
  $lines.Insert(1, "nonblank rows: $nonblank")
} catch {
  $lines.Add("error: $_")
} finally {
  $lines | Out-File $Out -Encoding utf8
  try { [void][K]::FreeConsole() } catch {}
}
