(*
  Author: German Luis Aracil Boned
  Project: superterm - terminal with autologin, splits and sessions
  Unit: st_layout - split tree (vertical/horizontal, max 16 panes)
*)

unit st_layout;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes;

const
  MAX_PANES = 16;
  // Canonical desktop work area, in character cells. The menu and status
  // rows are outside this height. Keep the ceiling aligned with TScreen's
  // 8192 x 4096 limit: fullscreen additionally owns those two UI rows.
  DESKTOP_MIN_W = 20;
  DESKTOP_MIN_H = 25;
  DESKTOP_MAX_W = 8192;
  DESKTOP_MAX_H = 4094;
  // First-run workspace.  These are canonical character dimensions, not a
  // request to resize the terminal which happens to launch SuperTerm.
  DEFAULT_DESKTOP_W = 120;
  DEFAULT_DESKTOP_H = 50;
  DEFAULT_INITIAL_PANE_COLS = 80;
  DEFAULT_INITIAL_PANE_ROWS = 25;
  // FreeVision's MinWinSize (vendor/fv322/views.pas). A window smaller than
  // this cannot be dragged or resized by hand, so nothing should place one.
  MIN_WIN_W = 16;
  MIN_WIN_H = 6;
  CASCADE_STEP_X = 3;   // horizontal stagger between cascaded windows

type
  TSplitDir = (sdV, sdH); // sdV: side by side | sdH: top/bottom

  TRect = record
    X, Y, W, H: integer;
  end;

  TNode = class
  public
    IsSplit: boolean;
    Dir: TSplitDir;
    Ratio: double;           // 0.15..0.85 relative size of child A
    A, B: TNode;             // children if split
    LeafIndex: integer;      // pane index if leaf
    Parent: TObject;         // parent TNode or nil
    constructor CreateLeaf(AIndex: integer);
    constructor CreateSplit(ADir: TSplitDir; AA, AB: TNode);
    destructor Destroy; override;
  end;

  TLayout = class
  private
    FLastRects: array of TRect;
    function FindLeafNode(ANode: TNode; AIndex: integer): TNode;
    function FindLeafParent(ARoot, ANode: TNode): TNode;
    procedure CollectLeaves(ANode: TNode; AList: TList);
    procedure CalcRects(ANode: TNode; const R: TRect);
    procedure CollectDividers(ANode: TNode; const R: TRect);
  public
    Root: TNode;
    Focused: integer;
    LastInsertedIndex: integer;
    DividerList: array of TRect; // divider line rects (1 cell thick)
    constructor Create;
    destructor Destroy; override;
    function PaneCount: integer;
    function SplitPane(AIndex: integer; ADir: TSplitDir): boolean;
    // Put the first pane back into an empty layout. Closing the last window
    // leaves the desktop empty instead of ending the program, so there has to
    // be a way in again -- and splitting needs a leaf to split.
    function AddFirstPane: boolean;
    function ClosePane(AIndex: integer): boolean; // false if it became empty
    procedure ResizeFocused(ADir: TSplitDir; ADelta: integer);
    procedure FocusNext(ADelta: integer);
    procedure ComputeRects(AW, AH: integer; out Rects: array of TRect);
    procedure Reindex;
  end;

// Staggered slot AK for an AW x AH window on an ADeskW x ADeskH desktop.
// The span the slots are spread over is clamped to at least 1: a window as
// wide (or as tall) as the desktop then lands at the origin instead of
// dividing by zero, which used to raise SIGFPE and kill the whole session.
function CascadeRect(AK, AW, AH, ADeskW, ADeskH: integer): TRect;

// Outer size, in cells, that a new window wants: ACols x ARows plus the frame,
// or two thirds of the desktop when they are 0 (automatic). Floored at the
// smallest window the user can still drag and resize, then clamped to the
// desktop -- in that order, so a desktop smaller than the floor yields the
// desktop rather than something that does not fit on it.
procedure WantedWindowSize(ACols, ARows, ADeskW, ADeskH: integer;
  out AW, AH: integer);

// Same size, centred on the desktop. Placing a new window must never move an
// existing one, so it is placed on its own merits and simply lands on top.
function CentredRect(AW, AH, ADeskW, ADeskH: integer): TRect;

// Shared validation for profile/session loading, UI dialogs and the daemon's
// explicit desktop-resize command. Dimensions are the usable desktop area,
// not the two fixed menu/status rows.
function IsDesktopSizeValid(AWidth, AHeight: Longint): boolean;
procedure NormalizeDesktopSize(var AWidth, AHeight: Longint);

// Preserve a window's size and, whenever possible, its position. If no safe
// draggable title cell intersects the new desktop, move only far enough to
// expose one. The safe interval excludes FreeVision/SuperTerm's left close
// control and right minimize/zoom controls.
function KeepWindowTitleReachable(var AX, AY: Longint;
  AWindowWidth, ADeskW, ADeskH: Longint): boolean;


implementation

function IsDesktopSizeValid(AWidth, AHeight: Longint): boolean;
begin
  Result := (AWidth >= DESKTOP_MIN_W) and
    (AWidth <= DESKTOP_MAX_W) and
    (AHeight >= DESKTOP_MIN_H) and
    (AHeight <= DESKTOP_MAX_H);
end;

procedure NormalizeDesktopSize(var AWidth, AHeight: Longint);
begin
  if AWidth < DESKTOP_MIN_W then AWidth := DESKTOP_MIN_W;
  if AWidth > DESKTOP_MAX_W then AWidth := DESKTOP_MAX_W;
  if AHeight < DESKTOP_MIN_H then AHeight := DESKTOP_MIN_H;
  if AHeight > DESKTOP_MAX_H then AHeight := DESKTOP_MAX_H;
end;

function KeepWindowTitleReachable(var AX, AY: Longint;
  AWindowWidth, ADeskW, ADeskH: Longint): boolean;
const
  // See TTermWindow.HandleEvent and TFrame.Draw. X=2..4 is close;
  // width-10..width-8 is minimize and width-5..width-3 is zoom.
  SAFE_TITLE_LEFT = 5;
  SAFE_TITLE_RIGHT_MARGIN = 11;
var
  LocalLeft, LocalRight, SafeLeft, SafeRight, NewX: Int64;
  OldX, OldY: Longint;
begin
  Result := False;
  if not IsDesktopSizeValid(ADeskW, ADeskH) then
    Exit;
  OldX := AX;
  OldY := AY;
  if AWindowWidth >= MIN_WIN_W then
  begin
    LocalLeft := SAFE_TITLE_LEFT;
    LocalRight := Int64(AWindowWidth) - SAFE_TITLE_RIGHT_MARGIN;
  end
  else
  begin
    // Malformed legacy geometry can be narrower than FreeVision permits.
    // Do not resize it here: expose its middle title cell instead.
    LocalLeft := AWindowWidth div 2;
    LocalRight := LocalLeft;
  end;
  SafeLeft := Int64(AX) + LocalLeft;
  SafeRight := Int64(AX) + LocalRight;
  NewX := AX;
  if SafeRight < 0 then
    NewX := Int64(AX) - SafeRight
  else if SafeLeft >= ADeskW then
    NewX := Int64(AX) - (SafeLeft - (ADeskW - 1));
  // Both expressions above land close to the small canonical desktop even
  // for hostile Longint input, but keep the narrowing conversion explicit.
  if NewX < Low(Longint) then NewX := Low(Longint);
  if NewX > High(Longint) then NewX := High(Longint);
  AX := Longint(NewX);
  if AY < 0 then
    AY := 0
  else if AY >= ADeskH then
    AY := ADeskH - 1;
  Result := (AX <> OldX) or (AY <> OldY);
end;

procedure WantedWindowSize(ACols, ARows, ADeskW, ADeskH: integer;
  out AW, AH: integer);
begin
  if ACols > 0 then
    AW := ACols + 2          // the frame takes one cell on each side
  else
    AW := ADeskW * 2 div 3;
  if ARows > 0 then
    AH := ARows + 2
  else
    AH := ADeskH * 2 div 3;
  if AW < MIN_WIN_W then
    AW := MIN_WIN_W;
  if AH < MIN_WIN_H then
    AH := MIN_WIN_H;
  if AW > ADeskW then
    AW := ADeskW;
  if AH > ADeskH then
    AH := ADeskH;
end;

function CentredRect(AW, AH, ADeskW, ADeskH: integer): TRect;
begin
  Result.W := AW;
  Result.H := AH;
  Result.X := (ADeskW - AW) div 2;
  Result.Y := (ADeskH - AH) div 2;
  if Result.X < 0 then
    Result.X := 0;
  if Result.Y < 0 then
    Result.Y := 0;
end;

function CascadeRect(AK, AW, AH, ADeskW, ADeskH: integer): TRect;
var
  SpanX, SpanY: integer;
begin
  if AK < 0 then
    AK := 0;
  SpanX := ADeskW - AW;
  if SpanX < 1 then
    SpanX := 1;
  SpanY := ADeskH - AH - 1;
  if SpanY < 1 then
    SpanY := 1;
  Result.X := (AK * CASCADE_STEP_X) mod SpanX;
  Result.Y := AK mod SpanY;
  Result.W := AW;
  Result.H := AH;
end;

constructor TNode.CreateLeaf(AIndex: integer);
begin
  inherited Create;
  IsSplit := False;
  LeafIndex := AIndex;
  Ratio := 0.5;
end;

constructor TNode.CreateSplit(ADir: TSplitDir; AA, AB: TNode);
begin
  inherited Create;
  IsSplit := True;
  Dir := ADir;
  A := AA;
  B := AB;
  Ratio := 0.5;
  if AA <> nil then AA.Parent := Self;
  if AB <> nil then AB.Parent := Self;
end;

destructor TNode.Destroy;
begin
  A.Free;
  B.Free;
  inherited;
end;

constructor TLayout.Create;
begin
  inherited;
  Root := TNode.CreateLeaf(0);
  Focused := 0;
  LastInsertedIndex := 0;
end;

destructor TLayout.Destroy;
begin
  Root.Free;
  inherited;
end;

function TLayout.PaneCount: integer;
var
  L: TList;
begin
  L := TList.Create;
  try
    CollectLeaves(Root, L);
    Result := L.Count;
  finally
    L.Free;
  end;
end;

procedure TLayout.CollectLeaves(ANode: TNode; AList: TList);
begin
  if ANode = nil then
    Exit;
  if not ANode.IsSplit then
    AList.Add(ANode)
  else
  begin
    CollectLeaves(ANode.A, AList);
    CollectLeaves(ANode.B, AList);
  end;
end;

function TLayout.FindLeafNode(ANode: TNode; AIndex: integer): TNode;
begin
  Result := nil;
  if ANode = nil then
    Exit;
  if (not ANode.IsSplit) and (ANode.LeafIndex = AIndex) then
    Exit(ANode);
  if ANode.IsSplit then
  begin
    Result := FindLeafNode(ANode.A, AIndex);
    if Result = nil then
      Result := FindLeafNode(ANode.B, AIndex);
  end;
end;

function TLayout.FindLeafParent(ARoot, ANode: TNode): TNode;
begin
  Result := nil;
  if ARoot = nil then
    Exit;
  if (ARoot.A = ANode) or (ARoot.B = ANode) then
    Exit(ARoot);
  if ARoot.IsSplit then
  begin
    Result := FindLeafParent(ARoot.A, ANode);
    if Result = nil then
      Result := FindLeafParent(ARoot.B, ANode);
  end;
end;

function TLayout.AddFirstPane: boolean;
begin
  Result := False;
  if Root <> nil then
    Exit;
  Root := TNode.CreateLeaf(0);
  Focused := 0;
  LastInsertedIndex := 0;
  Result := True;
end;

function TLayout.SplitPane(AIndex: integer; ADir: TSplitDir): boolean;
var
  Leaf, Par, NewSplit: TNode;
  NewLeaf, OldLeaf: TNode;
  L: TList;
begin
  Result := False;
  if PaneCount >= MAX_PANES then
    Exit;
  Leaf := FindLeafNode(Root, AIndex);
  if Leaf = nil then
    Exit;

  L := TList.Create;
  try
    CollectLeaves(Root, L);
    // new leaf index: at the end
    NewLeaf := TNode.CreateLeaf(L.Count);
  finally
    L.Free;
  end;

  OldLeaf := TNode.CreateLeaf(AIndex);
  NewSplit := TNode.CreateSplit(ADir, OldLeaf, NewLeaf);
  OldLeaf.Parent := NewSplit;
  NewLeaf.Parent := NewSplit;

  Par := FindLeafParent(Root, Leaf);
  if Par = nil then
  begin
    // it is the root
    Root.Free;
    Root := NewSplit;
    NewSplit.Parent := nil;
  end
  else
  begin
    if Par.A = Leaf then
      Par.A := NewSplit
    else
      Par.B := NewSplit;
    NewSplit.Parent := Par;
    Leaf.Free;
  end;
  Reindex;
  // The new leaf is the right/bottom sibling of the selected leaf in the
  // preorder traversal used by Reindex.
  LastInsertedIndex := AIndex + 1;
  Result := True;
end;

function TLayout.ClosePane(AIndex: integer): boolean;
var
  Leaf, Par, Grand, Sibling: TNode;
begin
  Result := False;
  Leaf := FindLeafNode(Root, AIndex);
  if Leaf = nil then
    Exit;
  Par := FindLeafParent(Root, Leaf);
  if Par = nil then
  begin
    // only pane: leaf root
    FreeAndNil(Root);
    Focused := -1;
    LastInsertedIndex := -1;
    Exit(False);
  end;
  if Par.A = Leaf then
    Sibling := Par.B
  else
    Sibling := Par.A;
  Grand := FindLeafParent(Root, Par);
  if Grand = nil then
  begin
    Root := Sibling;
    Sibling.Parent := nil;
  end
  else
  begin
    if Grand.A = Par then
      Grand.A := Sibling
    else
      Grand.B := Sibling;
    Sibling.Parent := Grand;
  end;
  Leaf.Free;
  Par.A := nil;
  Par.B := nil;
  Par.Free;
  Reindex;
  if Focused >= PaneCount then
    Focused := PaneCount - 1;
  Result := PaneCount > 0;
end;

procedure TLayout.Reindex;
var
  L: TList;
  i: integer;
begin
  L := TList.Create;
  try
    CollectLeaves(Root, L);
    for i := 0 to L.Count - 1 do
      TNode(L[i]).LeafIndex := i;
  finally
    L.Free;
  end;
end;

procedure TLayout.ResizeFocused(ADir: TSplitDir; ADelta: integer);
var
  Leaf, N: TNode;
begin
  Leaf := FindLeafNode(Root, Focused);
  if Leaf = nil then
    Exit;
  N := FindLeafParent(Root, Leaf);
  // find the nearest split on the requested axis
  while (N <> nil) do
  begin
    if TNode(N).Dir = ADir then
    begin
      TNode(N).Ratio := TNode(N).Ratio + ADelta * 0.05;
      if TNode(N).Ratio < 0.15 then TNode(N).Ratio := 0.15;
      if TNode(N).Ratio > 0.85 then TNode(N).Ratio := 0.85;
      Exit;
    end;
    N := FindLeafParent(Root, N);
  end;
end;

procedure TLayout.FocusNext(ADelta: integer);
var
  n: integer;
begin
  n := PaneCount;
  if n = 0 then
    Exit;
  Focused := (Focused + ADelta) mod n;
  if Focused < 0 then
    Focused := Focused + n;
end;

procedure TLayout.CalcRects(ANode: TNode; const R: TRect);
var
  a: integer;
  RA, RB: TRect;
begin
  if ANode = nil then
    Exit;
  if not ANode.IsSplit then
    Exit; // already assigned by ComputeRects
  if ANode.Dir = sdV then
  begin
    a := Round(R.W * ANode.Ratio);
    if a < 4 then a := 4;
    if a > R.W - 5 then a := R.W - 5;
    if R.W < 9 then a := R.W div 2;
    RA.X := R.X; RA.Y := R.Y; RA.W := a - 1; RA.H := R.H;
    RB.X := R.X + a; RB.Y := R.Y; RB.W := R.W - a; RB.H := R.H;
  end
  else
  begin
    a := Round(R.H * ANode.Ratio);
    if a < 3 then a := 3;
    if a > R.H - 4 then a := R.H - 4;
    if R.H < 7 then a := R.H div 2;
    RA.X := R.X; RA.Y := R.Y; RA.W := R.W; RA.H := a - 1;
    RB.X := R.X; RB.Y := R.Y + a; RB.W := R.W; RB.H := R.H - a;
  end;
  if not ANode.A.IsSplit then
    FLastRects[ANode.A.LeafIndex] := RA
  else
    CalcRects(ANode.A, RA);
  if not ANode.B.IsSplit then
    FLastRects[ANode.B.LeafIndex] := RB
  else
    CalcRects(ANode.B, RB);
end;

procedure TLayout.CollectDividers(ANode: TNode; const R: TRect);
var
  a: integer;
  RA, RB: TRect;
  d: TRect;
begin
  if (ANode = nil) or (not ANode.IsSplit) then
    Exit;
  if ANode.Dir = sdV then
  begin
    a := Round(R.W * ANode.Ratio);
    if a < 4 then a := 4;
    if a > R.W - 5 then a := R.W - 5;
    if R.W < 9 then a := R.W div 2;
    RA.X := R.X; RA.Y := R.Y; RA.W := a - 1; RA.H := R.H;
    RB.X := R.X + a; RB.Y := R.Y; RB.W := R.W - a; RB.H := R.H;
    d.X := R.X + a - 1; d.Y := R.Y; d.W := 1; d.H := R.H;
  end
  else
  begin
    a := Round(R.H * ANode.Ratio);
    if a < 3 then a := 3;
    if a > R.H - 4 then a := R.H - 4;
    if R.H < 7 then a := R.H div 2;
    RA.X := R.X; RA.Y := R.Y; RA.W := R.W; RA.H := a - 1;
    RB.X := R.X; RB.Y := R.Y + a; RB.W := R.W; RB.H := R.H - a;
    d.X := R.X; d.Y := R.Y + a - 1; d.W := R.W; d.H := 1;
  end;
  SetLength(DividerList, Length(DividerList) + 1);
  DividerList[High(DividerList)] := d;
  CollectDividers(ANode.A, RA);
  CollectDividers(ANode.B, RB);
end;

procedure TLayout.ComputeRects(AW, AH: integer; out Rects: array of TRect);
var
  R: TRect;
  i: integer;
begin
  R.X := 0;
  R.Y := 0;
  R.W := AW;
  R.H := AH;
  DividerList := nil;
  for i := 0 to High(Rects) do
  begin
    Rects[i].X := 0;
    Rects[i].Y := 0;
    Rects[i].W := AW;
    Rects[i].H := AH;
  end;
  if Root = nil then
    Exit;
  if not Root.IsSplit then
  begin
    if (Root.LeafIndex >= 0) and (Root.LeafIndex <= High(Rects)) then
      Rects[Root.LeafIndex] := R;
  end
  else
  begin
    SetLength(FLastRects, Length(Rects));
    for i := 0 to High(Rects) do
      FLastRects[i] := R;
    CalcRects(Root, R);
    for i := 0 to High(Rects) do
      Rects[i] := FLastRects[i];
  end;
  CollectDividers(Root, R);
end;

end.
