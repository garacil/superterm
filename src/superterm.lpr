(*
  Autor: Germán Luis Aracil Boned
  Proyecto: superterm - terminal con autologin, splits y sesiones
  Programa principal: arranca la aplicacion FreeVision
*)

program superterm;

{$mode objfpc}{$H+}

uses
  Objects, Drivers, App, st_fvui;

var
  STApp: PSuperApp;

begin
  STApp := New(PSuperApp, Init);
  Application := Pointer(STApp);
  STApp^.Run;
  Dispose(STApp, Done);
end.
