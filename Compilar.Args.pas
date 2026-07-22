unit Compilar.Args;

interface

uses
  Compilar.Types;

type
  TArgsParser = class
  public
    /// Parse command line arguments into TCompilerArgs
    /// Returns False if validation fails, with error message in ErrorMsg
    class function Parse(out Args: TCompilerArgs; out ErrorMsg: string): Boolean;

  private
    class function ParseConfig(const Value: string; out Config: TBuildConfig): Boolean;
    class function ParsePlatform(const Value: string; out Platform: TBuildPlatform): Boolean;
    class function ValidateProjectPath(const Path: string; out ErrorMsg: string): Boolean;
  end;

implementation

uses
  System.SysUtils, System.IOUtils, Compilar.PathUtils;

class function TArgsParser.Parse(out Args: TCompilerArgs; out ErrorMsg: string): Boolean;
var
  I: Integer;
  Param, ParamUpper: string;
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

  // Check for minimum arguments
  if ParamCount < 1 then
  begin
    ErrorMsg := 'No project path specified. Usage: delphi-compiler.exe <project.dproj> [options]';
    Exit;
  end;

  // First argument is always the project path
  Args.ProjectPath := ParamStr(1);

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

  // Parse remaining arguments
  for I := 2 to ParamCount do
  begin
    Param := ParamStr(I);
    ParamUpper := UpperCase(Param);

    // Check for --option=value format
    if Param.StartsWith('--config=', True) then
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
    end;
    // Unknown arguments are silently ignored
  end;

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
    ErrorMsg := '--workspace and --test are mutually exclusive (a workspace build already writes to ROOT\out).';
    Exit;
  end;
  if (Args.WorkspaceRoot <> '') and Args.RebuildCanonical then
  begin
    ErrorMsg := '--rebuild-canonical is not allowed inside a workspace (/t:rebuild must never run against a slot).';
    Exit;
  end;

  // Slot-session guard (cmx-workspace): inside a slot (CMX_WORKSPACE set), a
  // canonical W:\ project without --workspace would write to the SHARED
  // canonical output dirs. Hard error with the corrected invocation.
  if (Args.WorkspaceRoot = '') and (GetEnvironmentVariable('CMX_WORKSPACE') <> '') then
  begin
    if Args.ProjectPathWin.StartsWith('W:\', True) or
       Args.ProjectPathWin.StartsWith('C:\cmx-ws\', True) then
    begin
      ErrorMsg := 'This session runs inside cmx-workspace slot "' +
        GetEnvironmentVariable('CMX_WORKSPACE') +
        '". Use --workspace=' + GetEnvironmentVariable('CMX_WORKSPACE') +
        ' (and the slot copy of the project under it), or "cmx-workspace build".';
      Exit;
    end;
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
