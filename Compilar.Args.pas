unit Compilar.Args;

interface

uses
  Compilar.Types;

type
  /// An informational invocation: the tool prints what was asked for and exits
  /// 0 WITHOUT compiling, whatever else is on the command line.
  TInfoRequest = (irNone, irVersion, irHelp);

  TArgsParser = class
  public
    /// Detect an informational flag (--version / --help) in ANY position of the
    /// command line (v1.12). Before, only ParamStr(1) was inspected, so
    /// `--workspace=ROOT --version` took `--version` as the project path and
    /// died with a confusing `invalid` (BUG-ARG-ORDER-VERSION). Leftmost flag
    /// wins when both are present.
    class function DetectInfoRequest: TInfoRequest;

    /// Parse command line arguments into TCompilerArgs
    /// Returns False if validation fails, with error message in ErrorMsg
    class function Parse(out Args: TCompilerArgs; out ErrorMsg: string): Boolean;

  private
    /// Single source of truth for the informational flag names, shared by
    /// DetectInfoRequest and by the Parse loop (which must not report them as
    /// unknown arguments).
    class function InfoFlagOf(const Param: string): TInfoRequest;
    class function ParseConfig(const Value: string; out Config: TBuildConfig): Boolean;
    class function ParsePlatform(const Value: string; out Platform: TBuildPlatform): Boolean;
    class function ValidateProjectPath(const Path: string; out ErrorMsg: string): Boolean;
    /// Resolve the effective cmx-workspace slot root (MARKER-CONTRACT.md §5.3
    /// ladder). Returns False with ErrorMsg on any state the contract requires
    /// to fail loudly instead of degrading to a canonical build.
    class function ResolveWorkspace(var Args: TCompilerArgs; out ErrorMsg: string): Boolean;
  end;

implementation

uses
  System.SysUtils, System.IOUtils, Compilar.PathUtils, CmxWorkspace.Detect;

class function TArgsParser.InfoFlagOf(const Param: string): TInfoRequest;
begin
  if SameText(Param, '--version') then
    Result := irVersion
  else if SameText(Param, '--help') then
    Result := irHelp
  else
    Result := irNone;
end;

class function TArgsParser.DetectInfoRequest: TInfoRequest;
var
  I: Integer;
begin
  Result := irNone;
  for I := 1 to ParamCount do
  begin
    Result := InfoFlagOf(ParamStr(I));
    if Result <> irNone then
      Exit;
  end;
end;

class function TArgsParser.Parse(out Args: TCompilerArgs; out ErrorMsg: string): Boolean;
const
  USAGE = 'Usage: delphi-compiler.exe <project.dproj> [options] (--help lists every option)';
var
  I: Integer;
  Param, ParamUpper: string;
  ProjectGiven: Boolean;
begin
  Result := False;

  // Initialize defaults
  Args.Config := bcDebug;
  Args.Platform := bpWin32;
  Args.TestMode := False;
  Args.MaxErrors := 3;
  Args.ContextLines := 5;
  Args.RawOutput := False;
  Args.FullOutput := False;
  Args.WSLMode := False;
  Args.WorkspaceRoot := '';
  Args.RebuildCanonical := False;
  Args.WorkspaceSource := cwsrcNone;
  Args.ConflictEnvSlot := '';
  Args.ConflictMarkerSlot := '';

  // Check for minimum arguments
  if ParamCount < 1 then
  begin
    ErrorMsg := 'No project path specified. ' + USAGE;
    Exit;
  end;

  Args.ProjectPath := '';
  ProjectGiven := False;

  // ONE pass over EVERY argument (v1.12). Options are position-independent, an
  // unrecognized one is a loud error instead of the old silent skip, and the
  // project is simply the first argument that is neither an option nor a legacy
  // positional keyword — so the shape the slot guard suggests
  // (`--workspace=ROOT <project>`) parses like the historical `<project>
  // --workspace=ROOT`.
  for I := 1 to ParamCount do
  begin
    Param := ParamStr(I);
    if Param = '' then
      Continue;
    ParamUpper := UpperCase(Param);

    // Informational flags are handled before parsing (see the .dpr): accept
    // them here so they are never reported as unknown arguments.
    if InfoFlagOf(Param) <> irNone then
      Continue
    // Check for --option=value format
    else if Param.StartsWith('--config=', True) then
    begin
      if not ParseConfig(Copy(Param, 10, MaxInt), Args.Config) then
      begin
        ErrorMsg := 'Invalid config value. Use Debug or Release.';
        Exit;
      end;
    end
    else if Param.StartsWith('--platform=', True) then
    begin
      if not ParsePlatform(Copy(Param, 12, MaxInt), Args.Platform) then
      begin
        ErrorMsg := 'Invalid platform value. Use Win32 or Win64.';
        Exit;
      end;
    end
    else if Param.StartsWith('--max-errors=', True) then
    begin
      Args.MaxErrors := StrToIntDef(Copy(Param, 14, MaxInt), 3);
      if Args.MaxErrors < 1 then Args.MaxErrors := 1;
      if Args.MaxErrors > 10 then Args.MaxErrors := 10;
    end
    else if Param.StartsWith('--context-lines=', True) then
    begin
      Args.ContextLines := StrToIntDef(Copy(Param, 17, MaxInt), 5);
      if Args.ContextLines < 0 then Args.ContextLines := 0;
      if Args.ContextLines > 20 then Args.ContextLines := 20;
    end
    else if Param.StartsWith('--workspace=', True) then
    begin
      Args.WorkspaceRoot := Copy(Param, 13, MaxInt);
      // Normalize to Windows form and strip trailing slash
      if TPathUtils.IsLinuxPath(Args.WorkspaceRoot) then
        Args.WorkspaceRoot := TPathUtils.LinuxToWindows(Args.WorkspaceRoot);
      Args.WorkspaceRoot := StringReplace(Args.WorkspaceRoot, '/', '\', [rfReplaceAll]);
      while Args.WorkspaceRoot.EndsWith('\') do
        SetLength(Args.WorkspaceRoot, Length(Args.WorkspaceRoot) - 1);
      if not DirectoryExists(Args.WorkspaceRoot) then
      begin
        ErrorMsg := 'Workspace root not found: ' + Args.WorkspaceRoot;
        Exit;
      end;
    end
    else if ParamUpper = '--REBUILD-CANONICAL' then
    begin
      Args.RebuildCanonical := True;
    end
    else if ParamUpper = '--TEST' then
    begin
      Args.TestMode := True;
    end
    else if ParamUpper = '--RAW' then
    begin
      Args.RawOutput := True;
    end
    else if ParamUpper = '--FULL' then
    begin
      Args.FullOutput := True;
    end
    else if ParamUpper = '--WSL' then
    begin
      Args.WSLMode := True;
    end
    // Also support positional arguments for backwards compatibility
    else if (ParamUpper = 'DEBUG') or (ParamUpper = 'RELEASE') then
    begin
      ParseConfig(Param, Args.Config);
    end
    else if (ParamUpper = 'WIN32') or (ParamUpper = 'WIN64') then
    begin
      ParsePlatform(Param, Args.Platform);
    end
    else if ParamUpper = 'TEST' then
    begin
      Args.TestMode := True;
    end
    // Anything else that looks like a flag is a typo, not a project: say so
    // instead of swallowing it (a silently ignored --workpsace=ROOT used to
    // become a canonical build).
    else if Param.StartsWith('-') then
    begin
      ErrorMsg := 'Unknown argument: ' + Param + '. ' + USAGE;
      Exit;
    end
    else if not ProjectGiven then
    begin
      Args.ProjectPath := Param;
      ProjectGiven := True;
    end
    else
    begin
      ErrorMsg := 'Unexpected extra argument: ' + Param + ' (the project is already "' +
        Args.ProjectPath + '"). ' + USAGE;
      Exit;
    end;
  end;

  if not ProjectGiven then
  begin
    ErrorMsg := 'No project path specified. ' + USAGE;
    Exit;
  end;

  // Validate project path
  if not ValidateProjectPath(Args.ProjectPath, ErrorMsg) then
    Exit;

  // Normalize paths
  if TPathUtils.IsLinuxPath(Args.ProjectPath) then
  begin
    Args.ProjectPathWin := TPathUtils.LinuxToWindows(Args.ProjectPath);
  end
  else if TPathUtils.IsWindowsPath(Args.ProjectPath) then
  begin
    Args.ProjectPathWin := Args.ProjectPath;
    Args.ProjectPath := TPathUtils.WindowsToLinux(Args.ProjectPath);
  end
  else
  begin
    // Mixed or non-standard path — normalize slashes first, then treat as Windows
    Args.ProjectPathWin := StringReplace(Args.ProjectPath, '/', '\', [rfReplaceAll]);
    Args.ProjectPath := TPathUtils.WindowsToLinux(Args.ProjectPathWin);
  end;

  // Resolve the effective workspace BEFORE any path translation: the ladder
  // decides whether this run is a slot build at all (v1.12).
  if not ResolveWorkspace(Args, ErrorMsg) then
    Exit;

  // Workspace mode: the project to compile is the SLOT copy. Translate a
  // canonical W:\Packages290\... path (what discovery tooling returns) to the
  // workspace worktree; any other W:\ project is an error.
  if Args.WorkspaceRoot <> '' then
  begin
    if Args.ProjectPathWin.StartsWith('W:\Packages290\', True) then
    begin
      Args.ProjectPathWin := Args.WorkspaceRoot + Copy(Args.ProjectPathWin, 3, MaxInt);
      Args.ProjectPath := TPathUtils.WindowsToLinux(Args.ProjectPathWin);
      if not FileExists(Args.ProjectPathWin) then
      begin
        ErrorMsg := 'Workspace copy of the project not found: ' + Args.ProjectPathWin;
        Exit;
      end;
    end
    else if Args.ProjectPathWin.StartsWith('W:\', True) then
    begin
      ErrorMsg := 'In workspace mode the project must live under the workspace (or be given as W:\Packages290\... for auto-translation). Got: ' + Args.ProjectPathWin;
      Exit;
    end;
  end;

  // Mutually exclusive / incoherent combinations
  if (Args.WorkspaceRoot <> '') and Args.TestMode then
  begin
    ErrorMsg := 'Workspace mode (source=' + CmxWsSourceToStr(Args.WorkspaceSource) +
      ', root=' + Args.WorkspaceRoot + ') and --test are mutually exclusive (a workspace build already writes to ROOT\out).';
    Exit;
  end;
  if (Args.WorkspaceRoot <> '') and Args.RebuildCanonical then
  begin
    ErrorMsg := '--rebuild-canonical is not allowed inside a workspace (/t:rebuild must never run against a slot). Workspace source=' +
      CmxWsSourceToStr(Args.WorkspaceSource) + ', root=' + Args.WorkspaceRoot + '.';
    Exit;
  end;

  Result := True;
end;

class function TArgsParser.ResolveWorkspace(var Args: TCompilerArgs;
  out ErrorMsg: string): Boolean;
var
  Detection, ProjDetect: TCmxWsDetection;
  ProjectSlot, WsSlot: string;
begin
  // Precedence ladder of MARKER-CONTRACT.md §5.3:
  //   --workspace flag > project path > validated env > CWD marker-walk > none
  // Everything the contract classifies as Invalid or as an env<>marker conflict
  // fails LOUDLY here (exit 2); a CLI tool must never degrade silently to a
  // canonical build when the slot identity cannot be trusted (§2.2).
  Result := False;
  ErrorMsg := '';

  // Apparent slot of the project, from the SHAPE of its path alone (§3).
  ProjectSlot := CmxSlotIdFromPath(Args.ProjectPathWin);

  // Both channels (env + marker-walk from CWD, §5.1) are always evaluated: even
  // when a higher rung wins, a divergence between them is reported as a
  // non-fatal "workspace_conflict" in the JSON.
  Detection := DetectCmxWorkspace;
  if Detection.Conflict then
  begin
    Args.ConflictEnvSlot := Detection.Env.SlotId;
    Args.ConflictMarkerSlot := Detection.Marker.SlotId;
  end;

  if Args.WorkspaceRoot <> '' then
    // Rung 1 — explicit flag: conscious human intervention, always wins.
    Args.WorkspaceSource := cwsrcFlag
  else if ProjectSlot <> '' then
  begin
    // Rung 2 — derived from the project path. Immune to the WSL junction
    // asymmetry (§4.3): the path comes from the invocation, not from a CWD
    // that WSL may have already resolved through a junction. A root that LOOKS
    // like a slot but has no readable marker is Invalid, never "no slot" (§2.1).
    ProjDetect := DetectCmxWorkspaceBounded(ExtractFileDir(Args.ProjectPathWin));
    if ProjDetect.Marker.State <> cwsFound then
    begin
      ErrorMsg := Format('The project lives under cmx-workspace slot "%s" but that slot has no usable %s (%s): %s. ' +
        'Repair the slot (cmx-workspace doctor / re-provision) or pass an explicit --workspace=ROOT.',
        [ProjectSlot, CMX_WS_MARKER_FILENAME, CmxWsStateToStr(ProjDetect.Marker.State),
         ProjDetect.Marker.Detail]);
      Exit;
    end;
    Args.WorkspaceRoot := CmxSlotRootPath(Args.ProjectPathWin);
    Args.WorkspaceSource := cwsrcProject;
  end
  else if Detection.Conflict then
  begin
    // No flag and no project-derived identity: the two automatic channels
    // disagree and nothing can arbitrate. Never adopt either side silently.
    ErrorMsg := Format('cmx-workspace identity CONFLICT: %s="%s" resolves to slot "%s", but the marker found by walking up from the current directory (%s) belongs to slot "%s". ' +
      'Pass --workspace=ROOT explicitly to disambiguate.',
      [CMX_WS_ENV_NAME, Detection.Env.RawValue, Detection.Env.SlotId,
       Detection.Marker.MarkerPath, Detection.Marker.SlotId]);
    Exit;
  end
  else if Detection.Env.State = cwsFound then
  begin
    // Rung 3 — env VALIDATED against the marker of the root it points at
    // (§5.3). Until v1.11 this combination was a hard error asking for
    // --workspace; a validated env is now a legitimate source of identity.
    Args.WorkspaceRoot := CmxSlotRootPath(Detection.Env.RawValue);
    Args.WorkspaceSource := cwsrcEnv;
  end
  else if Detection.Marker.State = cwsFound then
  begin
    // Rung 4 — marker-walk from CWD: the last net (best effort, §4.3).
    Args.WorkspaceRoot := CmxSlotRootPath(Detection.Marker.RootWin);
    Args.WorkspaceSource := cwsrcMarker;
  end
  else if Detection.Marker.State = cwsInvalid then
  begin
    // A marker file EXISTS above the CWD and cannot be trusted: loud error,
    // never a silent canonical build (§2.2).
    ErrorMsg := Format('A cmx-workspace marker was found while walking up from the current directory but it is NOT usable: %s. ' +
      'Repair the slot or pass an explicit --workspace=ROOT.', [Detection.Marker.Detail]);
    Exit;
  end
  else
  begin
    // Rung 5 — no slot anchor at all: canonical behaviour, not an error.
    Args.WorkspaceSource := cwsrcNone;
    // Residue of the pre-v1.12 session guard: an env that is PRESENT but not
    // validatable (orphan root after teardown, non-slot shape, marker that
    // disagrees with it) plus a canonical/slot project is still the ambiguous
    // situation the guard existed for. Fail explicitly instead of writing to
    // the SHARED canonical output dirs.
    if (Detection.Env.State = cwsInvalid) and
       (Args.ProjectPathWin.StartsWith('W:\', True) or
        Args.ProjectPathWin.StartsWith('C:\cmx-ws\', True)) then
    begin
      ErrorMsg := Format('%s is set but cannot be trusted as a slot identity (%s), and no other source (project path, marker) applies. ' +
        'Compiling "%s" without --workspace would write to the SHARED canonical output dirs. ' +
        'Pass --workspace=ROOT, run from inside the slot, or clear %s.',
        [CMX_WS_ENV_NAME, Detection.Env.Detail, Args.ProjectPathWin, CMX_WS_ENV_NAME]);
      Exit;
    end;
  end;

  // Coherence workspace <-> project, WHATEVER the source (flag included): a
  // project physically inside slot sX can never be built with slot sY's overlay.
  if (ProjectSlot <> '') and (Args.WorkspaceRoot <> '') then
  begin
    WsSlot := CmxSlotIdFromPath(Args.WorkspaceRoot);
    if (WsSlot <> '') and not SameText(WsSlot, ProjectSlot) then
    begin
      ErrorMsg := Format('cmx-workspace slot mismatch: the project belongs to slot "%s" (%s) but the effective workspace is slot "%s" (%s, source=%s). ' +
        'Build the slot "%s" copy of the project, or point --workspace at "%s".',
        [ProjectSlot, Args.ProjectPathWin, WsSlot, Args.WorkspaceRoot,
         CmxWsSourceToStr(Args.WorkspaceSource), WsSlot, ProjectSlot]);
      Exit;
    end;
  end;

  if (Args.WorkspaceRoot <> '') and not DirectoryExists(Args.WorkspaceRoot) then
  begin
    ErrorMsg := Format('Workspace root not found: %s (source=%s)',
      [Args.WorkspaceRoot, CmxWsSourceToStr(Args.WorkspaceSource)]);
    Exit;
  end;

  Result := True;
end;

class function TArgsParser.ParseConfig(const Value: string; out Config: TBuildConfig): Boolean;
var
  Upper: string;
begin
  Upper := UpperCase(Value);
  if Upper = 'DEBUG' then
  begin
    Config := bcDebug;
    Result := True;
  end
  else if Upper = 'RELEASE' then
  begin
    Config := bcRelease;
    Result := True;
  end
  else
    Result := False;
end;

class function TArgsParser.ParsePlatform(const Value: string; out Platform: TBuildPlatform): Boolean;
var
  Upper: string;
begin
  Upper := UpperCase(Value);
  if Upper = 'WIN32' then
  begin
    Platform := bpWin32;
    Result := True;
  end
  else if Upper = 'WIN64' then
  begin
    Platform := bpWin64;
    Result := True;
  end
  else
    Result := False;
end;

class function TArgsParser.ValidateProjectPath(const Path: string; out ErrorMsg: string): Boolean;
var
  NormalizedPath: string;
begin
  Result := False;

  // Check if it's a full path (not just filename)
  if (not Path.Contains('/')) and (not Path.Contains('\')) then
  begin
    ErrorMsg := 'You must provide a full path, not just a filename. Provided: ' + Path;
    Exit;
  end;

  // Check extension
  if not Path.EndsWith('.dproj', True) then
  begin
    ErrorMsg := 'Project file must have .dproj extension. Provided: ' + Path;
    Exit;
  end;

  // Check if file exists (normalize to Windows path for FileExists)
  NormalizedPath := TPathUtils.NormalizeToWindows(Path);
  if not FileExists(NormalizedPath) then
  begin
    ErrorMsg := 'Project file not found: ' + Path;
    Exit;
  end;

  Result := True;
end;

end.
