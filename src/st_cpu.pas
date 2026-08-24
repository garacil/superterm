(*
  Project: superterm
  Unit: st_cpu - CPUs which this process can actually schedule threads on

  FPC 3.2.x leaves System.CPUCount at its generic fallback on several Unix
  targets. Query the operating system directly instead: Linux affinity also
  respects cpusets, while Darwin explicitly documents hw.activecpu as the
  value SMP-aware programs should use to size their thread pools.
*)

unit st_cpu;

{$mode objfpc}{$H+}

interface

function AvailableCPUCount: integer;

implementation

uses
  ctypes
  {$ifdef darwin}, SysCtl{$endif}
  {$ifdef windows}, Windows{$endif};

{$ifdef linux}
const
  CPU_SET_WORDS = 16; // Linux/glibc CPU_SETSIZE = 1024 on 64-bit targets

type
  TCpuSet = packed array[0..CPU_SET_WORDS - 1] of QWord;

function sched_getaffinity(pid: cint; cpusetsize: csize_t;
  mask: pointer): cint; cdecl; external 'c' name 'sched_getaffinity';

function LinuxCPUCount: integer;
var
  Mask: TCpuSet;
  I, B: integer;
  W: QWord;
begin
  Result := 0;
  Mask := Default(TCpuSet);
  if sched_getaffinity(0, SizeOf(Mask), @Mask) <> 0 then
    Exit;
  for I := 0 to High(Mask) do
  begin
    W := Mask[I];
    for B := 0 to 63 do
    begin
      Inc(Result, W and 1);
      W := W shr 1;
    end;
  end;
end;
{$endif}

{$ifdef darwin}
function DarwinCPUCount: integer;
var
  Count: cuint;
  Len: csize_t;
begin
  Result := 0;
  Count := 0;
  Len := SizeOf(Count);
  if FPsysctlbyname(PAnsiChar('hw.activecpu'), @Count, @Len, nil, 0) = 0 then
    Result := Count;
  if Result > 0 then
    Exit;
  Count := 0;
  Len := SizeOf(Count);
  if FPsysctlbyname(PAnsiChar('hw.logicalcpu'), @Count, @Len, nil, 0) = 0 then
    Result := Count;
end;
{$endif}

{$ifdef windows}
const
  ALL_PROCESSOR_GROUPS = $FFFF;

// Not declared in FPC 3.2.2's Windows unit; bind it from kernel32 directly.
function GetActiveProcessorCount(GroupNumber: WORD): DWORD; stdcall;
  external 'kernel32' name 'GetActiveProcessorCount';

function WindowsCPUCount: integer;
begin
  // The number of logical processors the current process group can run on.
  // GetActiveProcessorCount(ALL_PROCESSOR_GROUPS) mirrors what a thread pool
  // should size to and respects a group-limited process, the Windows analogue
  // of the Linux affinity mask and Darwin hw.activecpu.
  Result := integer(GetActiveProcessorCount(ALL_PROCESSOR_GROUPS));
end;
{$endif}

function AvailableCPUCount: integer;
begin
  {$ifdef linux}
  Result := LinuxCPUCount;
  {$else}
  {$ifdef darwin}
  Result := DarwinCPUCount;
  {$else}
  {$ifdef windows}
  Result := WindowsCPUCount;
  {$else}
  Result := 1;
  {$endif}
  {$endif}
  {$endif}
  if Result < 1 then
    Result := 1;
end;

end.
