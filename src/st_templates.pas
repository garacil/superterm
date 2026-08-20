(*
  Unidad: st_templates - definiciones persistentes de templates, sesiones,
  ventanas y terminales.
 *)

unit st_templates;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, IniFiles, sqlite3conn, sqldb;

type
  TTemplatePaneSpec = record
    Name: string;
    Enabled: boolean;
    Terminal: string;       // nombre de TTerminalDef, vacio = terminal local
    Cmd: string;
    Cwd: string;
    PostConnect: string;    // comando opcional despues de conectar
    ScrollBack: integer;    // 0 = usar el terminal referenciado
  end;

  TTemplatePaneArray = array of TTemplatePaneSpec;

  TTemplateWindowSpec = record
    Name: string;
    Enabled: boolean;
    Layout: string;
    FocusedPane: integer;
    Panes: TTemplatePaneArray;
  end;

  TTemplateWindowArray = array of TTemplateWindowSpec;

  TTemplateSessionSpec = record
    Name: string;
    Enabled: boolean;
    FocusedWindow: integer;
    Windows: TTemplateWindowArray;
  end;

  TTemplateSessionArray = array of TTemplateSessionSpec;

  TTemplateSpec = record
    Name: string;
    Enabled: boolean;
    DefaultSession: string;
    Sessions: TTemplateSessionArray;
  end;

  TTemplateArray = array of TTemplateSpec;

function LoadTemplates(const FileName: string; out Templates: TTemplateArray): boolean;
function LoadTemplateSQLite(const FileName: string;
  out Template: TTemplateSpec): boolean;
function LoadTemplatesSQLiteDir(const Directory: string;
  out Templates: TTemplateArray): boolean;
procedure SaveTemplateSQLite(const FileName: string;
  const Template: TTemplateSpec);

implementation

function ReadBool(const Ini: TIniFile; const Section, Ident: string;
  Default: boolean): boolean;
var
  S: string;
begin
  S := Trim(Ini.ReadString(Section, Ident, ''));
  if S = '' then
    Exit(Default);
  Result := SameText(S, '1') or SameText(S, 'true') or
    SameText(S, 'yes') or SameText(S, 'on');
end;

function Names(const S: string): TStringList;
var
  I: integer;
begin
  Result := TStringList.Create;
  Result.Delimiter := ',';
  Result.StrictDelimiter := True;
  Result.DelimitedText := S;
  for I := Result.Count - 1 downto 0 do
  begin
    Result[I] := Trim(Result[I]);
    if Result[I] = '' then
      Result.Delete(I);
  end;
end;

function TemplateSection(const Section: string): boolean;
var
  Rest: string;
begin
  Result := Pos('template.', LowerCase(Section)) = 1;
  if not Result then
    Exit;
  Rest := Copy(Section, Length('template.') + 1, MaxInt);
  Result := (Rest <> '') and (Pos('.', Rest) = 0);
end;

function SQLiteMeta(Q: TSQLQuery; const Key: string): string;
begin
  Result := '';
  Q.Close;
  Q.SQL.Text := 'select value from metadata where key=:key';
  Q.Params.ParamByName('key').AsString := Key;
  Q.Open;
  if not Q.EOF then
    Result := Q.Fields[0].AsString;
  Q.Close;
end;

function SQLiteBool(Q: TSQLQuery; const FieldName: string;
  Default: boolean): boolean;
begin
  if Q.FieldByName(FieldName).IsNull then
    Result := Default
  else
    Result := Q.FieldByName(FieldName).AsInteger <> 0;
end;

procedure SQLiteExec(Q: TSQLQuery; const SQL: string);
begin
  Q.Close;
  Q.SQL.Text := SQL;
  Q.ExecSQL;
end;

function LoadTemplateSQLite(const FileName: string;
  out Template: TTemplateSpec): boolean;
var
  Conn: TSQLite3Connection;
  Trans: TSQLTransaction;
  Q, QWindows, QPanes: TSQLQuery;
  Session: TTemplateSessionSpec;
  Window: TTemplateWindowSpec;
  Pane: TTemplatePaneSpec;
  SessionName, WindowName: string;
begin
  Template.Name := '';
  Template.Enabled := False;
  Template.DefaultSession := '';
  Template.Sessions := nil;
  Result := False;
  if (FileName = '') or (not FileExists(FileName)) then
    Exit;
  Conn := TSQLite3Connection.Create(nil);
  Trans := TSQLTransaction.Create(nil);
  Q := TSQLQuery.Create(nil);
  QWindows := TSQLQuery.Create(nil);
  QPanes := TSQLQuery.Create(nil);
  try
    try
      Conn.DatabaseName := FileName;
      Conn.Transaction := Trans;
      Trans.DataBase := Conn;
      Q.DataBase := Conn;
      Q.Transaction := Trans;
      QWindows.DataBase := Conn;
      QWindows.Transaction := Trans;
      QPanes.DataBase := Conn;
      QPanes.Transaction := Trans;
      Conn.Open;
      Trans.StartTransaction;
      Template.Name := SQLiteMeta(Q, 'name');
      if Template.Name = '' then
      begin
        Trans.Rollback;
        Exit;
      end;
      Template.Enabled := SQLiteMeta(Q, 'enabled') <> '0';
      Template.DefaultSession := SQLiteMeta(Q, 'default_session');

    Q.Close;
    Q.SQL.Text :=
      'select name,enabled,focused_window from sessions order by ord,name';
    Q.Open;
    while not Q.EOF do
    begin
      Session.Name := Q.FieldByName('name').AsString;
      Session.Enabled := SQLiteBool(Q, 'enabled', True);
      Session.FocusedWindow := Q.FieldByName('focused_window').AsInteger;
      Session.Windows := nil;
      SessionName := Session.Name;

      QWindows.Close;
      QWindows.SQL.Text :=
        'select name,enabled,layout,focused_pane from windows ' +
        'where session_name=:session_name order by ord,name';
      QWindows.Params.ParamByName('session_name').AsString := SessionName;
      QWindows.Open;
      while not QWindows.EOF do
      begin
        Window.Name := QWindows.FieldByName('name').AsString;
        Window.Enabled := SQLiteBool(QWindows, 'enabled', True);
        Window.Layout := QWindows.FieldByName('layout').AsString;
        Window.FocusedPane := QWindows.FieldByName('focused_pane').AsInteger;
        Window.Panes := nil;
        WindowName := Window.Name;

        QPanes.Close;
        QPanes.SQL.Text :=
          'select name,enabled,terminal,cmd,cwd,postconnect,scrollback ' +
          'from panes where session_name=:session_name and ' +
          'window_name=:window_name order by ord,name';
        QPanes.Params.ParamByName('session_name').AsString := SessionName;
        QPanes.Params.ParamByName('window_name').AsString := WindowName;
        QPanes.Open;
        while not QPanes.EOF do
        begin
          Pane.Name := QPanes.FieldByName('name').AsString;
          Pane.Enabled := SQLiteBool(QPanes, 'enabled', True);
          Pane.Terminal := QPanes.FieldByName('terminal').AsString;
          Pane.Cmd := QPanes.FieldByName('cmd').AsString;
          Pane.Cwd := QPanes.FieldByName('cwd').AsString;
          Pane.PostConnect := QPanes.FieldByName('postconnect').AsString;
          Pane.ScrollBack := QPanes.FieldByName('scrollback').AsInteger;
          SetLength(Window.Panes, Length(Window.Panes) + 1);
          Window.Panes[High(Window.Panes)] := Pane;
          QPanes.Next;
        end;
        QPanes.Close;
        SetLength(Session.Windows, Length(Session.Windows) + 1);
        Session.Windows[High(Session.Windows)] := Window;
        QWindows.Next;
      end;
      QWindows.Close;
      SetLength(Template.Sessions, Length(Template.Sessions) + 1);
      Template.Sessions[High(Template.Sessions)] := Session;
      Q.Next;
    end;
    Q.Close;
    Trans.Commit;
    Result := Length(Template.Sessions) > 0;
    except
      if Trans.Active then
        Trans.Rollback;
      Template.Sessions := nil;
      Result := False;
    end;
  finally
    QPanes.Free;
    QWindows.Free;
    Q.Free;
    Trans.Free;
    Conn.Free;
  end;
end;

function LoadTemplatesSQLiteDir(const Directory: string;
  out Templates: TTemplateArray): boolean;
var
  SR: TSearchRec;
  FileName: string;
  Template: TTemplateSpec;
begin
  Templates := nil;
  Result := False;
  if (Directory = '') or (not DirectoryExists(Directory)) then
    Exit;
  if FindFirst(IncludeTrailingPathDelimiter(Directory) + '*.db',
    faAnyFile, SR) <> 0 then
    Exit;
  try
    repeat
      if (SR.Name = '.') or (SR.Name = '..') then
        continue;
      FileName := IncludeTrailingPathDelimiter(Directory) + SR.Name;
      if LoadTemplateSQLite(FileName, Template) then
      begin
        SetLength(Templates, Length(Templates) + 1);
        Templates[High(Templates)] := Template;
      end;
    until FindNext(SR) <> 0;
  finally
    FindClose(SR);
  end;
  Result := Length(Templates) > 0;
end;

procedure SaveTemplateSQLite(const FileName: string;
  const Template: TTemplateSpec);
var
  Conn: TSQLite3Connection;
  Trans: TSQLTransaction;
  Q: TSQLQuery;
  I, J, K: integer;
  EnabledValue: string;
begin
  if ExtractFileDir(FileName) <> '' then
    ForceDirectories(ExtractFileDir(FileName));
  Conn := TSQLite3Connection.Create(nil);
  Trans := TSQLTransaction.Create(nil);
  Q := TSQLQuery.Create(nil);
  try
    try
      Conn.DatabaseName := FileName;
      Conn.Transaction := Trans;
      Trans.DataBase := Conn;
      Q.DataBase := Conn;
      Q.Transaction := Trans;
      Conn.Open;
      Trans.StartTransaction;
    SQLiteExec(Q, 'create table if not exists metadata (' +
      'key text primary key,value text not null)');
    SQLiteExec(Q, 'create table if not exists sessions (' +
      'name text primary key,enabled integer,focused_window integer,ord integer)');
    SQLiteExec(Q, 'create table if not exists windows (' +
      'session_name text not null,name text not null,enabled integer,' +
      'layout text,focused_pane integer,ord integer,' +
      'primary key(session_name,name))');
    SQLiteExec(Q, 'create table if not exists panes (' +
      'session_name text not null,window_name text not null,name text not null,' +
      'enabled integer,terminal text,cmd text,cwd text,postconnect text,' +
      'scrollback integer,ord integer,' +
      'primary key(session_name,window_name,name))');
    SQLiteExec(Q, 'delete from metadata');
    SQLiteExec(Q, 'delete from panes');
    SQLiteExec(Q, 'delete from windows');
    SQLiteExec(Q, 'delete from sessions');

    Q.SQL.Text := 'insert into metadata(key,value) values(:key,:value)';
    Q.Params.ParamByName('key').AsString := 'name';
    Q.Params.ParamByName('value').AsString := Template.Name;
    Q.ExecSQL;
    Q.Params.ParamByName('key').AsString := 'enabled';
    if Template.Enabled then EnabledValue := '1' else EnabledValue := '0';
    Q.Params.ParamByName('value').AsString := EnabledValue;
    Q.ExecSQL;
    Q.Params.ParamByName('key').AsString := 'default_session';
    Q.Params.ParamByName('value').AsString := Template.DefaultSession;
    Q.ExecSQL;

    Q.SQL.Text := 'insert into sessions(name,enabled,focused_window,ord) ' +
      'values(:name,:enabled,:focused_window,:ord)';
    for I := 0 to High(Template.Sessions) do
    begin
      Q.Params.ParamByName('name').AsString := Template.Sessions[I].Name;
      Q.Params.ParamByName('enabled').AsInteger := Ord(Template.Sessions[I].Enabled);
      Q.Params.ParamByName('focused_window').AsInteger :=
        Template.Sessions[I].FocusedWindow;
      Q.Params.ParamByName('ord').AsInteger := I;
      Q.ExecSQL;
    end;

    Q.SQL.Text := 'insert into windows(session_name,name,enabled,layout,' +
      'focused_pane,ord) values(:session_name,:name,:enabled,:layout,' +
      ':focused_pane,:ord)';
    for I := 0 to High(Template.Sessions) do
      for J := 0 to High(Template.Sessions[I].Windows) do
      begin
        Q.Params.ParamByName('session_name').AsString := Template.Sessions[I].Name;
        Q.Params.ParamByName('name').AsString := Template.Sessions[I].Windows[J].Name;
        Q.Params.ParamByName('enabled').AsInteger :=
          Ord(Template.Sessions[I].Windows[J].Enabled);
        Q.Params.ParamByName('layout').AsString := Template.Sessions[I].Windows[J].Layout;
        Q.Params.ParamByName('focused_pane').AsInteger :=
          Template.Sessions[I].Windows[J].FocusedPane;
        Q.Params.ParamByName('ord').AsInteger := J;
        Q.ExecSQL;
      end;

    Q.SQL.Text := 'insert into panes(session_name,window_name,name,enabled,' +
      'terminal,cmd,cwd,postconnect,scrollback,ord) values(:session_name,' +
      ':window_name,:name,:enabled,:terminal,:cmd,:cwd,:postconnect,' +
      ':scrollback,:ord)';
    for I := 0 to High(Template.Sessions) do
      for J := 0 to High(Template.Sessions[I].Windows) do
        for K := 0 to High(Template.Sessions[I].Windows[J].Panes) do
        begin
          Q.Params.ParamByName('session_name').AsString := Template.Sessions[I].Name;
          Q.Params.ParamByName('window_name').AsString :=
            Template.Sessions[I].Windows[J].Name;
          Q.Params.ParamByName('name').AsString :=
            Template.Sessions[I].Windows[J].Panes[K].Name;
          Q.Params.ParamByName('enabled').AsInteger :=
            Ord(Template.Sessions[I].Windows[J].Panes[K].Enabled);
          Q.Params.ParamByName('terminal').AsString :=
            Template.Sessions[I].Windows[J].Panes[K].Terminal;
          Q.Params.ParamByName('cmd').AsString :=
            Template.Sessions[I].Windows[J].Panes[K].Cmd;
          Q.Params.ParamByName('cwd').AsString :=
            Template.Sessions[I].Windows[J].Panes[K].Cwd;
          Q.Params.ParamByName('postconnect').AsString :=
            Template.Sessions[I].Windows[J].Panes[K].PostConnect;
          Q.Params.ParamByName('scrollback').AsInteger :=
            Template.Sessions[I].Windows[J].Panes[K].ScrollBack;
          Q.Params.ParamByName('ord').AsInteger := K;
          Q.ExecSQL;
        end;
      Trans.Commit;
    except
      if Trans.Active then
        Trans.Rollback;
      raise;
    end;
  finally
    Q.Free;
    Trans.Free;
    Conn.Free;
  end;
end;

function LoadTemplates(const FileName: string; out Templates: TTemplateArray): boolean;
var
  Ini: TIniFile;
  Sections, TNames, SNames, WNames, PNames: TStringList;
  T, S, W, P: integer;
  Sec, SessionSec, WindowSec, PaneSec: string;
  StorageBackend, StorageDir: string;
  SQLiteTemplates: TTemplateArray;
  Template: TTemplateSpec;
  Session: TTemplateSessionSpec;
  Window: TTemplateWindowSpec;
  Pane: TTemplatePaneSpec;
begin
  Templates := nil;
  Result := False;
  if (FileName = '') or (not FileExists(FileName)) then
    Exit;
  Ini := TIniFile.Create(FileName);
  Sections := TStringList.Create;
  TNames := TStringList.Create;
  try
    StorageBackend := LowerCase(Trim(Ini.ReadString('storage', 'backend', 'ini')));
    StorageDir := Ini.ReadString('storage', 'directory', 'templates');
    if (StorageDir <> '') and (StorageDir[1] <> '/') then
      StorageDir := IncludeTrailingPathDelimiter(ExtractFileDir(FileName)) + StorageDir;
    Ini.ReadSections(Sections);
    for T := 0 to Sections.Count - 1 do
      if TemplateSection(Sections[T]) then
        TNames.Add(Copy(Sections[T], Length('template.') + 1, MaxInt));

    for T := 0 to TNames.Count - 1 do
    begin
      Sec := 'template.' + TNames[T];
      Template.Name := Ini.ReadString(Sec, 'name', TNames[T]);
      Template.Enabled := ReadBool(Ini, Sec, 'enabled', True);
      Template.DefaultSession := Ini.ReadString(Sec, 'default_session', '');
      Template.Sessions := nil;
      SNames := Names(Ini.ReadString(Sec, 'sessions', ''));
      try
        for S := 0 to SNames.Count - 1 do
        begin
          Session.Name := SNames[S];
          Session.Enabled := True;
          Session.FocusedWindow := 0;
          Session.Windows := nil;
          SessionSec := Sec + '.session.' + Session.Name;
          Session.Enabled := ReadBool(Ini, SessionSec, 'enabled', True);
          Session.FocusedWindow := Ini.ReadInteger(SessionSec,
            'focused_window', 0);
          WNames := Names(Ini.ReadString(SessionSec, 'windows', ''));
          try
            for W := 0 to WNames.Count - 1 do
            begin
              Window.Name := WNames[W];
              Window.Enabled := True;
              Window.FocusedPane := 0;
              Window.Panes := nil;
              WindowSec := SessionSec + '.window.' + Window.Name;
              Window.Enabled := ReadBool(Ini, WindowSec, 'enabled', True);
              Window.Layout := Ini.ReadString(WindowSec, 'layout', 'L');
              Window.FocusedPane := Ini.ReadInteger(WindowSec,
                'focused_pane', 0);
              PNames := Names(Ini.ReadString(WindowSec, 'panes', ''));
              try
                SetLength(Window.Panes, PNames.Count);
                for P := 0 to PNames.Count - 1 do
                begin
                  Pane.Name := PNames[P];
                  Pane.Enabled := True;
                  Pane.Terminal := '';
                  Pane.Cmd := '';
                  Pane.Cwd := '';
                  Pane.PostConnect := '';
                  Pane.ScrollBack := 0;
                  PaneSec := WindowSec + '.pane.' + Pane.Name;
                  Pane.Enabled := ReadBool(Ini, PaneSec, 'enabled', True);
                  Pane.Terminal := Ini.ReadString(PaneSec, 'terminal', '');
                  Pane.Cmd := Ini.ReadString(PaneSec, 'cmd', '');
                  Pane.Cwd := Ini.ReadString(PaneSec, 'cwd', '');
                  Pane.PostConnect := Ini.ReadString(PaneSec,
                    'postconnect', '');
                  Pane.ScrollBack := Ini.ReadInteger(PaneSec,
                    'scrollback', 0);
                  Window.Panes[P] := Pane;
                end;
              finally
                PNames.Free;
              end;
              SetLength(Session.Windows, Length(Session.Windows) + 1);
              Session.Windows[High(Session.Windows)] := Window;
            end;
          finally
            WNames.Free;
          end;
          SetLength(Template.Sessions, Length(Template.Sessions) + 1);
          Template.Sessions[High(Template.Sessions)] := Session;
        end;
      finally
        SNames.Free;
      end;
      SetLength(Templates, Length(Templates) + 1);
      Templates[High(Templates)] := Template;
    end;
    Result := Length(Templates) > 0;
    if StorageBackend = 'sqlite' then
    begin
      if LoadTemplatesSQLiteDir(StorageDir, SQLiteTemplates) then
      begin
        Templates := SQLiteTemplates;
        Result := True;
      end
      else
      begin
        Templates := nil;
        Result := False;
      end;
    end;
  finally
    TNames.Free;
    Sections.Free;
    Ini.Free;
  end;
end;

end.
