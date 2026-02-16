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
  Args.WSLMode := False;

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
    // Assume it's a Windows path without validation
    Args.ProjectPathWin := Args.ProjectPath;
    Args.ProjectPath := TPathUtils.WindowsToLinux(Args.ProjectPath);
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
    else if ParamUpper = '--TEST' then
    begin
      Args.TestMode := True;
    end
    else if ParamUpper = '--RAW' then
    begin
      Args.RawOutput := True;
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
