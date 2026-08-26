program background_size_probe;

{$mode objfpc}{$H+}

uses
  st_artbg;

var
  Index, W, H: integer;
begin
  ArtReload;
  Index := ArtIndexOf('goody');
  if Index = 0 then
    Halt(2);
  ArtSize(Index, W, H);
  WriteLn(W, 'x', H);
end.
