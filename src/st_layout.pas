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
    function ClosePane(AIndex: integer): boolean; // false if it became empty
    procedure ResizeFocused(ADir: TSplitDir; ADelta: integer);
    procedure FocusNext(ADelta: integer);
    procedure ComputeRects(AW, AH: integer; out Rects: array of TRect);
    procedure Reindex;
  end;

implementation

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
