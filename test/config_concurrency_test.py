#!/usr/bin/env python3
"""Cross-process configuration/profile/class transactions stay atomic.

This compiles a tiny Pascal caller against the same public units used by the
IDE. A common gate makes stale readers publish simultaneously, while a Python
sampler parses every visible generation of superterm.ini.
"""

import configparser
import glob
import os
import shutil
import subprocess
import sys
import tempfile
import time

sys.path.insert(0, os.path.dirname(__file__))
import stlib
from stlib import check


PROJECT = os.path.abspath(os.path.join(os.path.dirname(__file__), '..'))
HOME = stlib.fresh_home('config-concurrency')
INI = os.path.join(HOME, '.superterm', 'superterm.ini')
SYSINI = os.path.join(HOME, 'system.ini')
BUILD = tempfile.mkdtemp(prefix='st-config-mutator-', dir=HOME)
SOURCE = os.path.join(BUILD, 'config_mutator.pas')
HELPER = os.path.join(BUILD, 'config_mutator')

PROGRAM = r'''program config_mutator;
{$mode objfpc}{$H+}
uses
  Classes, SysUtils, Unix, st_config, st_profiles, st_wclass;

procedure Touch(const Path: string);
var
  S: TFileStream;
begin
  S := TFileStream.Create(Path, fmCreate);
  S.Free;
end;

procedure AwaitGate;
begin
  Touch(ParamStr(5));
  while not FileExists(ParamStr(6)) do
    Sleep(1);
end;

procedure AwaitCommittedWinner;
var
  Deadline: QWord;
begin
  if ParamStr(7) = '-' then
    Halt(6);
  Deadline := GetTickCount64 + 10000;
  while not FileExists(ParamStr(7)) do
  begin
    if GetTickCount64 >= Deadline then
      Halt(8);
    Sleep(1);
  end;
end;

procedure SplitPair(const S: string; out LeftS, RightS: string);
var
  P: integer;
begin
  P := Pos('/', S);
  if P <= 1 then
    Halt(7);
  LeftS := Copy(S, 1, P - 1);
  RightS := Copy(S, P + 1, MaxInt);
  if RightS = '' then
    Halt(7);
end;

procedure LoadCombinedClasses(const UserIni, SystemIni: string;
  out AClasses: TWindowClassArray);
var
  SystemClasses: TWindowClassArray;
begin
  LoadWindowClasses(UserIni, coUser, AClasses);
  if not SameFileName(UserIni, SystemIni) then
  begin
    LoadWindowClasses(SystemIni, coSystem, SystemClasses);
    MergeWindowClasses(AClasses, SystemClasses);
  end;
end;

var
  Op, NameS, UserIni, SystemIni, PairLeft, PairRight: string;
  Profiles: TProfileArray;
  ClassesA: TWindowClassArray;
  C: TWindowClass;
  P: TProfileSpec;
  Cfg: TConfig;
  Created: boolean;
  LockFd: cint;
  Idx: integer;
  SelectedWindow: string;
  Args: array[0..2] of PChar;
begin
  if ParamCount < 7 then
    Halt(2);
  Profiles := nil;
  ClassesA := nil;
  Op := ParamStr(1);
  NameS := ParamStr(2);
  UserIni := ParamStr(3);
  SystemIni := ParamStr(4);
  if Op = 'lockexec' then
  begin
    LockFd := AcquireConfigFileLock(UserIni);
    Touch(ParamStr(5));
    Args[0] := PChar('/bin/sleep');
    Args[1] := PChar('5');
    Args[2] := nil;
    FpExecV('/bin/sleep', PPChar(@Args[0]));
    ReleaseConfigFileLock(LockFd);
    Halt(127);
  end;
  // Same-object operations deliberately take their optimistic snapshot
  // before publishing readiness. Every process therefore edits the exact
  // same generation, and only the first compare-and-swap may succeed.
  if (Op = 'class-edit') or (Op = 'class-delete-late') or
     (Op = 'class-rename-late') then
  begin
    LoadCombinedClasses(UserIni, SystemIni, ClassesA);
    Idx := FindClassByName(ClassesA, 'shared-class');
    if Idx < 0 then
      Halt(4);
    C := ClassesA[Idx];
    if Op = 'class-rename-late' then
      C.Name := NameS
    else
      C.Cmd := NameS;
  end
  else if (Op = 'profile-edit') or (Op = 'profile-edit-late') or
          (Op = 'profile-delete-late') or
          (Op = 'profile-rename-late') or
          (Op = 'profile-rename-default') then
  begin
    LoadProfiles(UserIni, SystemIni, Profiles);
    Idx := FindProfileByName(Profiles, 'shared-profile');
    if (Idx < 0) or (Length(Profiles[Idx].Windows) <> 1) then
      Halt(5);
    P := Profiles[Idx];
    P.Windows := Copy(Profiles[Idx].Windows, 0,
      Length(Profiles[Idx].Windows));
    P.Windows[0].Name := NameS;
  end
  else if Op = 'profile-delete-default' then
  begin
    LoadProfiles(UserIni, SystemIni, Profiles);
    Idx := FindProfileByName(Profiles, 'renamed-profile');
    if Idx < 0 then
      Halt(5);
  end
  else if Op = 'profile-delete-named' then
  begin
    LoadProfiles(UserIni, SystemIni, Profiles);
    Idx := FindProfileByName(Profiles, NameS);
    if Idx < 0 then
      Halt(5);
  end
  else if Op = 'profile-create-late' then
    LoadProfiles(UserIni, SystemIni, Profiles)
  else if Op = 'default-pair' then
    LoadConfig(Cfg);
  AwaitGate;
  if (Op = 'class-delete-late') or (Op = 'class-rename-late') or
     (Op = 'profile-edit-late') or (Op = 'profile-create-late') or
     (Op = 'profile-delete-late') or (Op = 'profile-rename-late') or
     (Op = 'default-window-late') or (Op = 'default-profile-late') then
    AwaitCommittedWinner;
  if Op = 'profile' then
  begin
    Created := CreateEmptyProfileAtomic(UserIni, SystemIni, NameS, Profiles);
    WriteLn('CREATED=', Ord(Created));
  end
  else if Op = 'profile-create-late' then
  begin
    Created := CreateEmptyProfileAtomic(UserIni, SystemIni, NameS, Profiles);
    WriteLn('CREATED=', Ord(Created));
  end
  else if Op = 'class' then
  begin
    C := DefaultWindowClass;
    C.Name := NameS;
    C.Cmd := 'echo ' + NameS;
    Created := UpsertUserWindowClassAtomic(UserIni, SystemIni, '', C, ClassesA);
    WriteLn('CREATED=', Ord(Created));
  end
  else if Op = 'class-edit' then
  begin
    Created := UpsertUserWindowClassAtomic(UserIni, SystemIni,
      'shared-class', C, ClassesA);
    WriteLn('CREATED=', Ord(Created));
    Idx := FindClassByName(ClassesA, 'shared-class');
    if Idx >= 0 then
      WriteLn('FRESH=', ClassesA[Idx].Cmd);
  end
  else if Op = 'class-delete-late' then
  begin
    Created := DeleteUserWindowClassAtomic(UserIni, SystemIni,
      'shared-class', ClassesA);
    WriteLn('CREATED=', Ord(Created));
    Idx := FindClassByName(ClassesA, 'shared-class');
    if Idx >= 0 then
      WriteLn('FRESH=', ClassesA[Idx].Cmd);
  end
  else if Op = 'class-rename-late' then
  begin
    Created := UpsertUserWindowClassAtomic(UserIni, SystemIni,
      'shared-class', C, ClassesA);
    WriteLn('CREATED=', Ord(Created));
    Idx := FindClassByName(ClassesA, 'shared-class');
    if Idx >= 0 then
      WriteLn('FRESH=', ClassesA[Idx].Cmd);
  end
  else if Op = 'profile-edit' then
  begin
    Created := UpsertUserProfileAtomic(UserIni, SystemIni, P, Profiles);
    WriteLn('CREATED=', Ord(Created));
    Idx := FindProfileByName(Profiles, 'shared-profile');
    if (Idx >= 0) and (Length(Profiles[Idx].Windows) = 1) then
      WriteLn('FRESH=', Profiles[Idx].Windows[0].Name);
  end
  else if Op = 'profile-edit-late' then
  begin
    Created := UpsertUserProfileAtomic(UserIni, SystemIni, P, Profiles);
    WriteLn('CREATED=', Ord(Created));
    Idx := FindProfileByName(Profiles, 'shared-profile');
    if (Idx >= 0) and (Length(Profiles[Idx].Windows) = 1) then
      WriteLn('FRESH=', Profiles[Idx].Windows[0].Name);
  end
  else if Op = 'profile-delete-late' then
  begin
    Created := DeleteUserProfileAtomic(UserIni, SystemIni,
      'shared-profile', Profiles);
    WriteLn('CREATED=', Ord(Created));
    Idx := FindProfileByName(Profiles, 'shared-profile');
    if (Idx >= 0) and (Length(Profiles[Idx].Windows) = 1) then
      WriteLn('FRESH=', Profiles[Idx].Windows[0].Name);
  end
  else if Op = 'profile-rename-late' then
  begin
    Created := RenameUserProfileAtomic(UserIni, SystemIni,
      'shared-profile', NameS, Profiles);
    WriteLn('CREATED=', Ord(Created));
    Idx := FindProfileByName(Profiles, 'shared-profile');
    if (Idx >= 0) and (Length(Profiles[Idx].Windows) = 1) then
      WriteLn('FRESH=', Profiles[Idx].Windows[0].Name);
  end
  else if Op = 'profile-rename-default' then
  begin
    Created := RenameUserProfileAtomic(UserIni, SystemIni,
      'shared-profile', 'renamed-profile', Profiles);
    WriteLn('CREATED=', Ord(Created));
  end
  else if Op = 'profile-delete-default' then
  begin
    Created := DeleteUserProfileAtomic(UserIni, SystemIni,
      'renamed-profile', Profiles);
    WriteLn('CREATED=', Ord(Created));
  end
  else if Op = 'profile-delete-named' then
  begin
    Created := DeleteUserProfileAtomic(UserIni, SystemIni, NameS, Profiles);
    WriteLn('CREATED=', Ord(Created));
  end
  else if Op = 'default-pair' then
  begin
    SplitPair(NameS, PairLeft, PairRight);
    Cfg.DefaultProfile := PairLeft;
    Cfg.DefaultWindow := PairRight;
    SaveConfigFields(Cfg, [cfDefaultProfile, cfDefaultWindow]);
    WriteLn('SAVED=1');
  end
  else if Op = 'default-window-late' then
  begin
    SplitPair(NameS, PairLeft, PairRight);
    Created := SaveDefaultWindowIfProfile(PairLeft, PairRight);
    WriteLn('SAVED=', Ord(Created));
  end
  else if (Op = 'default-profile') or (Op = 'default-profile-late') then
  begin
    SplitPair(NameS, PairLeft, PairRight);
    Created := SetDefaultProfileAtomic(UserIni, SystemIni, PairLeft,
      PairRight, Profiles, SelectedWindow);
    WriteLn('SAVED=', Ord(Created));
    WriteLn('WINDOW=', SelectedWindow);
  end
  else if Op = 'language' then
  begin
    LoadConfig(Cfg);
    Cfg.Language := ulSpanish;
    SaveConfigFields(Cfg, [cfLanguage]);
  end
  else if Op = 'session' then
  begin
    LoadConfig(Cfg);
    Cfg.DefaultSession := NameS;
    SaveConfigFields(Cfg, [cfDefaultSession]);
  end
  else if Op = 'ssh-route' then
  begin
    LoadConfig(Cfg);
    Cfg.SshLastSession := NameS;
    SaveConfigFields(Cfg, [cfSshLastSession]);
  end
  else if Op = 'threads' then
  begin
    LoadConfig(Cfg);
    Cfg.MultiThread := StrToInt(NameS);
    SaveConfigFields(Cfg, [cfMultiThread]);
  end
  else
    Halt(3);
  // A deterministic second barrier replaces timing guesses in stale-writer
  // tests: the winner publishes this marker only after its transaction has
  // returned, and the stale operation cannot begin before then.
  if (ParamStr(7) <> '-') and
     (Op <> 'class-delete-late') and (Op <> 'class-rename-late') and
     (Op <> 'profile-edit-late') and (Op <> 'profile-create-late') and
     (Op <> 'profile-delete-late') and (Op <> 'profile-rename-late') and
     (Op <> 'default-window-late') and (Op <> 'default-profile-late') then
    Touch(ParamStr(7));
end.
'''

with open(SOURCE, 'w', encoding='utf-8') as stream:
    stream.write(PROGRAM)

compile_result = subprocess.run([
    'fpc', '-Mobjfpc', '-Sh', '-vewnh', '-vm11030,11031',
    '-Fu' + os.path.join(PROJECT, 'src'),
    '-Fu' + os.path.join(PROJECT, 'vendor', 'fv322'),
    '-FU' + BUILD, '-FE' + BUILD, '-o' + HELPER, SOURCE,
], text=True, capture_output=True, timeout=60)
compiler_diagnostics = [
    line for line in (compile_result.stdout + compile_result.stderr).splitlines()
    if any(marker in line for marker in (' Warning:', ' Note:', ' Hint:'))
]
check('concurrency helper compiles cleanly',
      compile_result.returncode == 0 and
      not compiler_diagnostics)
if compiler_diagnostics:
    print('\n'.join(compiler_diagnostics))
if compile_result.returncode != 0:
    print(compile_result.stdout)
    print(compile_result.stderr)
    stlib.report()

with open(INI, 'w', encoding='utf-8') as stream:
    stream.write('''[ui]
language=en
[session]
default_session=base
default_profile=alpha
default_window=main
ssh_session=last
ssh_last_session=initial-route
multithread=1
[class.shared-class]
name=shared-class
enabled=1
cmd=ORIGINAL_CLASS
[profile.shared-profile]
name=shared-profile
enabled=1
focused_window=0
windows=original-window
[profile.shared-profile.window.original-window]
enabled=1
layout=L
focused_pane=0
panes=
[profile.alpha]
name=alpha
enabled=1
focused_window=0
windows=main
[profile.alpha.window.main]
enabled=1
layout=L
focused_pane=0
panes=
[profile.beta]
name=beta
enabled=1
focused_window=0
windows=work
[profile.beta.window.work]
enabled=1
layout=L
focused_pane=0
panes=
[sentinel]
keep=this-value
''')
with open(SYSINI, 'w', encoding='utf-8') as stream:
    stream.write('[sentinel-system]\nkeep=yes\n')
fixture_parser = configparser.ConfigParser(strict=True)
with open(INI, encoding='utf-8') as stream:
    fixture_parser.read_file(stream)
check('initial concurrency fixture is strictly parseable',
      fixture_parser.get('session', 'default_profile') == 'alpha' and
      fixture_parser.get('session', 'default_window') == 'main')

ENV = dict(os.environ, HOME=HOME, SUPERTERM_INI=SYSINI, LANG='C')


def launch(op, name, ready, gate, commit_marker='-'):
    return subprocess.Popen(
        [HELPER, op, name, INI, SYSINI, ready, gate, commit_marker],
        text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=ENV)


def read_default_pair():
    parser = configparser.ConfigParser(strict=True)
    with open(INI, encoding='utf-8') as stream:
        parser.read_file(stream)
    return (parser.get('session', 'default_profile', fallback=''),
            parser.get('session', 'default_window', fallback=''))


def gated_batch(specs, label, valid_default_pairs=None,
                required_default_pairs=None):
    gate = os.path.join(BUILD, label + '.go')
    jobs = []
    for index, spec in enumerate(specs):
        op, name = spec[:2]
        commit_marker = spec[2] if len(spec) > 2 else '-'
        ready = os.path.join(BUILD, f'{label}.{index}.ready')
        jobs.append((launch(op, name, ready, gate, commit_marker), ready))
    deadline = time.monotonic() + 10
    while (time.monotonic() < deadline and
           not all(os.path.exists(ready) for _job, ready in jobs)):
        time.sleep(0.01)
    check(label + ' workers reach common barrier',
          all(os.path.exists(ready) for _job, ready in jobs))
    observed_pairs = set()
    if valid_default_pairs is not None:
        observed_pairs.add(read_default_pair())
    open(gate, 'wb').close()
    parse_errors = []
    while any(job.poll() is None for job, _ready in jobs):
        parser = configparser.ConfigParser(strict=True)
        try:
            with open(INI, encoding='utf-8') as stream:
                parser.read_file(stream)
            if valid_default_pairs is not None:
                observed_pairs.add((
                    parser.get('session', 'default_profile', fallback=''),
                    parser.get('session', 'default_window', fallback='')))
        except (OSError, configparser.Error) as exc:
            parse_errors.append(str(exc))
        time.sleep(0.002)
    results = []
    for job, _ready in jobs:
        out, err = job.communicate(timeout=2)
        results.append((job.returncode, out, err))
    if valid_default_pairs is not None:
        observed_pairs.add(read_default_pair())
    check(label + ' publishes only parseable generations', not parse_errors)
    check(label + ' workers all finish cleanly',
          all(code == 0 for code, _out, _err in results))
    if valid_default_pairs is not None:
        check(label + ' never publishes a split default pair',
              observed_pairs <= set(valid_default_pairs))
    if required_default_pairs is not None:
        check(label + ' observes both complete generations',
              set(required_default_pairs) <= observed_pairs)
    return results


specs = ([('profile', f'profile-{i}') for i in range(8)] +
         [('class', f'class-{i}') for i in range(8)] +
         [('language', 'es'), ('session', 'concurrent-session'),
          ('ssh-route', 'concurrent-route'), ('threads', '4')])
gated_batch(specs, 'distinct')

parser = configparser.ConfigParser(strict=True)
parser.read(INI)
check('all distinct profiles survive',
      all(parser.has_section(f'profile.profile-{i}') for i in range(8)))
check('all distinct classes survive',
      all(parser.has_section(f'class.class-{i}') for i in range(8)))
check('stale field-scoped config writes merge',
      parser.get('ui', 'language') == 'es' and
      parser.get('session', 'default_session') == 'concurrent-session' and
      parser.get('session', 'ssh_last_session') == 'concurrent-route' and
      parser.getint('session', 'multithread') == 4)
check('unrelated section survives every rewrite',
      parser.get('sentinel', 'keep') == 'this-value')

# Every worker loaded the same object before the gate. The persisted record is
# the optimistic revision: exactly one complete replacement wins, while every
# loser is refreshed to that winning generation instead of silently replacing
# it with another stale edit.
same_class = gated_batch(
    [('class-edit', f'CLASS_REVISION_{i}') for i in range(10)],
    'same-class')
check('same class generation has exactly one writer',
      sum('CREATED=1' in out for _code, out, _err in same_class) == 1)
parser = configparser.ConfigParser(strict=True)
parser.read(INI)
class_winner = parser.get('class.shared-class', 'cmd')
check('same class losers reload the winning generation',
      class_winner.startswith('CLASS_REVISION_') and
      all(f'FRESH={class_winner}' in out
          for _code, out, _err in same_class))

same_profile = gated_batch(
    [('profile-edit', f'profile-revision-{i}') for i in range(10)],
    'same-profile')
check('same profile generation has exactly one writer',
      sum('CREATED=1' in out for _code, out, _err in same_profile) == 1)
parser = configparser.ConfigParser(strict=True)
parser.read(INI)
profile_winner = parser.get('profile.shared-profile', 'windows')
check('same profile losers reload the winning generation',
      profile_winner.startswith('profile-revision-') and
      all(f'FRESH={profile_winner}' in out
          for _code, out, _err in same_profile))

# An edit commits first and publishes a marker; the stale destructive writer
# waits for that marker while retaining its older snapshot. This covers the
# destructive path without relying on scheduler timing.
class_delete_marker = os.path.join(BUILD, 'class-delete.winner')
class_delete = gated_batch([
    ('class-edit', 'CLASS_SURVIVES_STALE_DELETE', class_delete_marker),
    ('class-delete-late', 'unused', class_delete_marker),
], 'class-delete-conflict')
check('stale class delete cannot erase a newer edit',
      'CREATED=1' in class_delete[0][1] and
      'CREATED=0' in class_delete[1][1] and
      'FRESH=CLASS_SURVIVES_STALE_DELETE' in class_delete[1][1])

class_rename_marker = os.path.join(BUILD, 'class-rename.winner')
class_rename = gated_batch([
    ('class-edit', 'CLASS_SURVIVES_STALE_RENAME', class_rename_marker),
    ('class-rename-late', 'renamed-class', class_rename_marker),
], 'class-rename-conflict')
check('stale class rename cannot relabel a newer edit',
      'CREATED=1' in class_rename[0][1] and
      'CREATED=0' in class_rename[1][1] and
      'FRESH=CLASS_SURVIVES_STALE_RENAME' in class_rename[1][1])

profile_delete_marker = os.path.join(BUILD, 'profile-delete.winner')
profile_delete = gated_batch([
    ('profile-edit', 'profile-survives-stale-delete', profile_delete_marker),
    ('profile-delete-late', 'unused', profile_delete_marker),
], 'profile-delete-conflict')
check('stale profile delete cannot erase a newer edit',
      'CREATED=1' in profile_delete[0][1] and
      'CREATED=0' in profile_delete[1][1] and
      'FRESH=profile-survives-stale-delete' in profile_delete[1][1])

profile_rename_marker = os.path.join(BUILD, 'profile-rename.winner')
profile_rename = gated_batch([
    ('profile-edit', 'profile-survives-stale-rename', profile_rename_marker),
    ('profile-rename-late', 'renamed-profile', profile_rename_marker),
], 'profile-rename-conflict')
check('stale profile rename cannot relabel a newer edit',
      'CREATED=1' in profile_rename[0][1] and
      'CREATED=0' in profile_rename[1][1] and
      'FRESH=profile-survives-stale-rename' in profile_rename[1][1])

# The default profile and its selected window form one logical value.  A
# client which still displays alpha/main must not combine that stale profile
# with a freshly committed beta/work.  The second marker is published only
# after SaveConfigFields returns, so this ordering is deterministic.
default_window_marker = os.path.join(BUILD, 'default-window.winner')
default_window_race = gated_batch([
    ('default-pair', 'beta/work', default_window_marker),
    ('default-window-late', 'alpha/main', default_window_marker),
], 'default-window-compare',
    valid_default_pairs={('alpha', 'main'), ('beta', 'work')},
    required_default_pairs={('alpha', 'main'), ('beta', 'work')})
check('stale alpha window cannot cross into fresh beta default',
      'SAVED=1' in default_window_race[0][1] and
      'SAVED=0' in default_window_race[1][1] and
      read_default_pair() == ('beta', 'work'))

# Setting the default is itself a profile transaction, not a stale index plus
# an unrelated config write. It validates the named profile under the common
# lock and resolves a vanished preferred window from that same generation.
fresh_default = gated_batch(
    [('default-profile', 'beta/vanished-window')],
    'default-profile-fresh-window',
    valid_default_pairs={('beta', 'work')})
check('default profile resolves window from fresh generation',
      'SAVED=1' in fresh_default[0][1] and
      'WINDOW=work' in fresh_default[0][1] and
      read_default_pair() == ('beta', 'work'))

deleted_alpha_marker = os.path.join(BUILD, 'delete-alpha.winner')
stale_default = gated_batch([
    ('profile-delete-named', 'alpha', deleted_alpha_marker),
    ('default-profile-late', 'alpha/main', deleted_alpha_marker),
], 'default-profile-deleted-race',
    valid_default_pairs={('beta', 'work')})
parser = configparser.ConfigParser(strict=True)
parser.read(INI)
check('deleted profile cannot become stale default',
      'CREATED=1' in stale_default[0][1] and
      'SAVED=0' in stale_default[1][1] and
      read_default_pair() == ('beta', 'work') and
      not parser.has_section('profile.alpha'))

# Profile writers also use the common lock and copy the authoritative file
# generation.  An old client creating or editing an unrelated profile after a
# new default commits must preserve that complete fresh pair.
create_default_marker = os.path.join(BUILD, 'profile-create-default.winner')
unrelated_create = gated_batch([
    ('default-pair', 'gamma/desk', create_default_marker),
    ('profile-create-late', 'unrelated-created', create_default_marker),
], 'unrelated-profile-create',
    valid_default_pairs={('beta', 'work'), ('gamma', 'desk')},
    required_default_pairs={('beta', 'work'), ('gamma', 'desk')})
check('unrelated profile create preserves fresh default',
      'SAVED=1' in unrelated_create[0][1] and
      'CREATED=1' in unrelated_create[1][1] and
      read_default_pair() == ('gamma', 'desk'))

edit_default_marker = os.path.join(BUILD, 'profile-edit-default.winner')
unrelated_edit = gated_batch([
    ('default-pair', 'beta/work', edit_default_marker),
    ('profile-edit-late', 'unrelated-edit-generation', edit_default_marker),
], 'unrelated-profile-edit',
    valid_default_pairs={('gamma', 'desk'), ('beta', 'work')},
    required_default_pairs={('gamma', 'desk'), ('beta', 'work')})
check('unrelated profile edit preserves fresh default',
      'SAVED=1' in unrelated_edit[0][1] and
      'CREATED=1' in unrelated_edit[1][1] and
      read_default_pair() == ('beta', 'work'))

# Rename and delete conditionally remap a matching default in the exact same
# atomic profile-file replacement.  Sampling every visible generation must
# see either the complete old pair or the complete new pair, never a hybrid.
set_shared = gated_batch([('default-pair', 'shared-profile/selected-window')],
                         'select-shared-default')
check('shared profile becomes complete default pair',
      'SAVED=1' in set_shared[0][1] and
      read_default_pair() == ('shared-profile', 'selected-window'))

renamed_default = gated_batch(
    [('profile-rename-default', 'unused')], 'rename-default-profile',
    valid_default_pairs={('shared-profile', 'selected-window'),
                         ('renamed-profile', 'selected-window')},
    required_default_pairs={('shared-profile', 'selected-window'),
                            ('renamed-profile', 'selected-window')})
parser = configparser.ConfigParser(strict=True)
parser.read(INI)
check('rename remaps default profile in its profile commit',
      'CREATED=1' in renamed_default[0][1] and
      read_default_pair() == ('renamed-profile', 'selected-window') and
      parser.has_section('profile.renamed-profile') and
      not parser.has_section('profile.shared-profile'))

deleted_default = gated_batch(
    [('profile-delete-default', 'unused')], 'delete-default-profile',
    valid_default_pairs={('renamed-profile', 'selected-window'), ('', '')},
    required_default_pairs={('renamed-profile', 'selected-window'), ('', '')})
parser = configparser.ConfigParser(strict=True)
parser.read(INI)
check('delete clears default profile and window in its profile commit',
      'CREATED=1' in deleted_default[0][1] and
      read_default_pair() == ('', '') and
      not parser.has_section('profile.renamed-profile'))

collision = gated_batch([('profile', 'Collision')] * 12, 'collision')
check('case-insensitive profile identity has one winner',
      sum('CREATED=1' in out for _code, out, _err in collision) == 1)
parser = configparser.ConfigParser(strict=True)
parser.read(INI)
check('collision writes exactly one profile section',
      sum(section.lower() == 'profile.collision'
          for section in parser.sections()) == 1)

# Invalid section suffixes are rejected by the same public predicates used by
# both readers and writers; they must never appear to save then disappear.
invalid = gated_batch([('profile', 'bad.name'), ('class', '[bad]')], 'invalid')
check('invalid names are rejected without exceptions',
      all('CREATED=0' in out for _code, out, _err in invalid))
parser = configparser.ConfigParser(strict=True)
parser.read(INI)
check('invalid names never reach disk',
      not parser.has_section('profile.bad.name') and
      not parser.has_section('class.[bad]'))

# The stable lock is FD_CLOEXEC. A process which execs sleep while holding it
# must release it at exec, allowing another writer to complete immediately.
lock_ready = os.path.join(BUILD, 'lockexec.ready')
lock_holder = launch('lockexec', '-', lock_ready, '-')
deadline = time.monotonic() + 5
while time.monotonic() < deadline and not os.path.exists(lock_ready):
    time.sleep(0.01)
quick_gate = os.path.join(BUILD, 'quick.go')
open(quick_gate, 'wb').close()
quick = launch('profile', 'after-exec', os.path.join(BUILD, 'quick.ready'),
               quick_gate)
quick_out, quick_err = quick.communicate(timeout=3)
check('configuration lock closes across exec',
      quick.returncode == 0 and 'CREATED=1' in quick_out and
      lock_holder.poll() is None)
lock_holder.wait(timeout=6)

# A substituted lock path is never followed.
lock_path = INI + '.lock'
if os.path.lexists(lock_path):
    os.unlink(lock_path)
os.symlink('/dev/null', lock_path)
bad_gate = os.path.join(BUILD, 'bad-lock.go')
open(bad_gate, 'wb').close()
bad_lock = launch('profile', 'must-not-save',
                  os.path.join(BUILD, 'bad-lock.ready'), bad_gate)
bad_lock.communicate(timeout=5)
check('symlinked configuration lock is rejected', bad_lock.returncode != 0)
os.unlink(lock_path)

check('no rewrite temporary is left behind', not glob.glob(INI + '.tmp.*'))

shutil.rmtree(BUILD, ignore_errors=True)
stlib.report()
