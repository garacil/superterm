(*
  Project: superterm
  Unit: st_perf - opt-in aggregated performance telemetry

  SUPERTERM_PERF=1 enables bounded per-stage counters. Summaries are written
  through st_debug once a second (and on an explicit flush), so a caller also
  supplies SUPERTERM_DEBUG=/path/to/log. The disabled path is one cached
  atomic test; it allocates nothing and takes no lock.

  The stages are this project's own pipeline, not a general profiler: a pane
  byte is parsed into the client's screen mirror, Free Vision draws the tree
  into the video buffer, the flush compares that buffer against the previously
  presented cells, builds the changed-cell runs and writes them once. Each of
  those is a stage below, so a claim about where the time goes can be checked
  instead of argued.
*)

unit st_perf;

{$mode objfpc}{$H+}

interface

type
  TSuperTermPerfStage = (
    stpsInputAdmission,     { host key/mouse byte accepted and routed }
    stpsPtyRead,            { one read from a pane master }
    stpsScreenParse,        { st_screen WriteBytes for those bytes }
    stpsFVDraw,             { Free Vision draw of the affected view(s) }
    stpsFrameCompare,       { WideUpdateScreen cell comparison }
    stpsNativePrepare,      { building the changed-cell runs and SGR }
    stpsSocketDelivery,     { daemon -> client frame delivery }
    stpsPhysicalWrite       { the single buffered write to the terminal }
  );

function SuperTermPerfEnabled: Boolean;
function SuperTermPerfNowMicros: QWord;
procedure SuperTermPerfObserve(AStage: TSuperTermPerfStage;
  AStartedMicros: QWord; AUnits: QWord = 0);
procedure SuperTermPerfFlush;

implementation

uses
  SysUtils, st_debug
  {$IFDEF LINUX}
  , Linux, UnixType
  {$ENDIF}
  ;

const
  PERF_REPORT_INTERVAL_MS = 1000;
  PERF_HISTOGRAM_BUCKETS = 32;

type
  TPerfHistogram = array[0 .. PERF_HISTOGRAM_BUCKETS - 1] of QWord;
  TPerfAggregate = record
    Count: QWord;
    TotalMicros: QWord;
    MaxMicros: QWord;
    Units: QWord;
    Histogram: TPerfHistogram;
  end;
  TPerfAggregates = array[TSuperTermPerfStage] of TPerfAggregate;
  TPerfLines = array[TSuperTermPerfStage] of string;

var
  PerfState: LongInt = 0; { 0 unresolved, 1 disabled, 2 enabled }
  PerfLock: TRTLCriticalSection;
  PerfValues: TPerfAggregates;
  PerfLastReportTick: QWord = 0;

function SuperTermPerfEnabled: Boolean;
var
  Enabled: Boolean;
begin
  if System.InterlockedCompareExchange(PerfState, 0, 0) = 0 then
  begin
    Enabled := (GetEnvironmentVariable('SUPERTERM_PERF') = '1') and
      DebugActive;
    if Enabled then
      System.InterlockedCompareExchange(PerfState, 2, 0)
    else
      System.InterlockedCompareExchange(PerfState, 1, 0);
  end;
  Result := System.InterlockedCompareExchange(PerfState, 0, 0) = 2;
end;

function SuperTermPerfNowMicros: QWord;
{$IFDEF LINUX}
var
  Stamp: TTimeSpec;
{$ENDIF}
begin
  {$IFDEF LINUX}
  { Match the installed FPC Unix RTL's monotonic source, but retain its
    nanosecond field so sub-millisecond optimized stages remain measurable. }
  Stamp := Default(TTimeSpec);
  if clock_gettime(CLOCK_MONOTONIC, @Stamp) = 0 then
    Exit(QWord(Stamp.tv_sec) * QWord(1000000) +
      QWord(Stamp.tv_nsec div 1000));
  {$ENDIF}
  { Portable monotonic fallback. }
  Result := GetTickCount64 * QWord(1000);
end;

function PerfStageName(AStage: TSuperTermPerfStage): string;
begin
  case AStage of
    stpsInputAdmission: Result := 'input-admission';
    stpsPtyRead: Result := 'pty-read';
    stpsScreenParse: Result := 'screen-parse';
    stpsFVDraw: Result := 'fv-draw';
    stpsFrameCompare: Result := 'frame-compare';
    stpsNativePrepare: Result := 'native-prepare';
    stpsSocketDelivery: Result := 'socket-delivery';
    stpsPhysicalWrite: Result := 'physical-write';
  else
    Result := 'unknown';
  end;
end;

function PerfBucket(AMicros: QWord): LongInt;
begin
  Result := 0;
  while (AMicros > 1) and (Result < PERF_HISTOGRAM_BUCKETS - 1) do
  begin
    AMicros := (AMicros + 1) shr 1;
    Inc(Result);
  end;
end;

function PerfBucketUpper(AIndex: LongInt): QWord;
begin
  if AIndex >= 63 then Exit(High(QWord));
  Result := QWord(1) shl AIndex;
end;

function PerfPercentile(const AValue: TPerfAggregate;
  ANumerator, ADenominator: QWord): QWord;
var
  Target, Seen: QWord;
  Index: LongInt;
begin
  Result := 0;
  if (AValue.Count = 0) or (ADenominator = 0) then Exit;
  Target := (AValue.Count * ANumerator + ADenominator - 1) div ADenominator;
  Seen := 0;
  for Index := 0 to High(AValue.Histogram) do
  begin
    Inc(Seen, AValue.Histogram[Index]);
    if Seen >= Target then Exit(PerfBucketUpper(Index));
  end;
end;

procedure ClearPerfAggregate(out AValue: TPerfAggregate);
begin
  AValue := Default(TPerfAggregate);
end;

procedure ClearPerfAggregates(out AValues: TPerfAggregates);
begin
  AValues := Default(TPerfAggregates);
end;

procedure BuildAndResetPerfLines(out ALines: TPerfLines;
  AForce: Boolean);
var
  Stage: TSuperTermPerfStage;
  NowTick, Average, P50, P95: QWord;
begin
  for Stage := Low(TSuperTermPerfStage) to High(TSuperTermPerfStage) do
    ALines[Stage] := '';
  NowTick := GetTickCount64;
  EnterCriticalSection(PerfLock);
  try
    if PerfLastReportTick = 0 then PerfLastReportTick := NowTick;
    if (not AForce) and
       (NowTick - PerfLastReportTick < PERF_REPORT_INTERVAL_MS) then Exit;
    PerfLastReportTick := NowTick;
    for Stage := Low(TSuperTermPerfStage) to High(TSuperTermPerfStage) do
      if PerfValues[Stage].Count <> 0 then
      begin
        Average := PerfValues[Stage].TotalMicros div
          PerfValues[Stage].Count;
        P50 := PerfPercentile(PerfValues[Stage], 50, 100);
        P95 := PerfPercentile(PerfValues[Stage], 95, 100);
        ALines[Stage] := Format(
          'perf: stage=%s count=%d avg_us=%d p50_le_us=%d p95_le_us=%d ' +
          'max_us=%d units=%d',
          [PerfStageName(Stage), PerfValues[Stage].Count, Average, P50, P95,
           PerfValues[Stage].MaxMicros, PerfValues[Stage].Units]);
        ClearPerfAggregate(PerfValues[Stage]);
      end;
  finally
    LeaveCriticalSection(PerfLock);
  end;
end;

procedure EmitPerfLines(const ALines: TPerfLines);
var
  Stage: TSuperTermPerfStage;
begin
  for Stage := Low(TSuperTermPerfStage) to High(TSuperTermPerfStage) do
    if ALines[Stage] <> '' then DebugLog(ALines[Stage]);
end;

procedure SuperTermPerfObserve(AStage: TSuperTermPerfStage;
  AStartedMicros: QWord; AUnits: QWord);
var
  Finished, Duration: QWord;
  Bucket: LongInt;
  Lines: TPerfLines;
begin
  if not SuperTermPerfEnabled then Exit;
  Finished := SuperTermPerfNowMicros;
  if Finished < AStartedMicros then Exit;
  Duration := Finished - AStartedMicros;
  Bucket := PerfBucket(Duration);
  EnterCriticalSection(PerfLock);
  try
    if PerfValues[AStage].Count < High(QWord) then
      Inc(PerfValues[AStage].Count);
    if PerfValues[AStage].TotalMicros <= High(QWord) - Duration then
      Inc(PerfValues[AStage].TotalMicros, Duration)
    else
      PerfValues[AStage].TotalMicros := High(QWord);
    if Duration > PerfValues[AStage].MaxMicros then
      PerfValues[AStage].MaxMicros := Duration;
    if PerfValues[AStage].Units <= High(QWord) - AUnits then
      Inc(PerfValues[AStage].Units, AUnits)
    else
      PerfValues[AStage].Units := High(QWord);
    if PerfValues[AStage].Histogram[Bucket] < High(QWord) then
      Inc(PerfValues[AStage].Histogram[Bucket]);
  finally
    LeaveCriticalSection(PerfLock);
  end;
  BuildAndResetPerfLines(Lines, False);
  EmitPerfLines(Lines);
end;

procedure SuperTermPerfFlush;
var
  Lines: TPerfLines;
begin
  if not SuperTermPerfEnabled then Exit;
  BuildAndResetPerfLines(Lines, True);
  EmitPerfLines(Lines);
end;

initialization
  PerfLock := Default(TRTLCriticalSection);
  InitCriticalSection(PerfLock);
  ClearPerfAggregates(PerfValues);

finalization
  DoneCriticalSection(PerfLock);

end.
