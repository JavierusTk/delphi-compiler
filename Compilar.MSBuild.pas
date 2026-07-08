unit Compilar.MSBuild;

interface

uses
  Compilar.Types;

type
  TMSBuildRunner = class
  public
    /// Execute MSBuild for the given project
    /// Returns True if MSBuild was executed (even if compilation failed)
    /// Returns False only if MSBuild couldn't be started
    class function Execute(const Args: TCompilerArgs;
      out Output: string; out ExitCode: Integer): Boolean;

  private
    class function GetRSVarsPath: string;
    class function BuildWorkspaceSearchPath(const Root: string): string;
    class function BuildCommandLine(const Args: TCompilerArgs): string;
    class function RunProcess(const CommandLine: string;
      out Output: string; out ExitCode: Integer; TimeoutMs: Cardinal): Boolean;
  end;

implementation

uses
  System.SysUtils, System.IOUtils, System.Classes,
  Winapi.Windows, Winapi.ShellAPI,
  Compilar.Config;

const
  MSBUILD_TIMEOUT_MS = 300000; // 5 minutes

class function TMSBuildRunner.GetRSVarsPath: string;
begin
  Result := Config.RsVarsPath;
  if Result = '' then
    raise Exception.Create('rsvars.bat path not configured. Set RSVARS_PATH in delphi-compiler.env');
  if not FileExists(Result) then
    raise Exception.Create('rsvars.bat not found at: ' + Result);
end;

class function TMSBuildRunner.BuildWorkspaceSearchPath(const Root: string): string;
var
  SR: TSearchRec;
  Attrs: DWORD;
  Name: string;
begin
  // out\DCP\290 first (intra-workspace DCP cascade), then the slot's PRIVATE
  // baseline DCP/DCU (pinned mirror of the canonical: isolates the build from
  // concurrent canonical mutation; must precede the registry Library Path,
  // which cites live W:\DCP\290), then every REAL directory at ROOT level
  // (worktrees of the edit-set; junctions are reparse points and resolve from
  // the canonical registry Library Path anyway).
  Result := Root + '\out\DCP\290';
  if DirectoryExists(Root + '\baseline\DCP\290') then
    Result := Result + ';' + Root + '\baseline\DCP\290';
  if DirectoryExists(Root + '\baseline\DCU\290') then
    Result := Result + ';' + Root + '\baseline\DCU\290';
  if FindFirst(Root + '\*', faDirectory, SR) = 0 then
  begin
    try
      repeat
        Name := SR.Name;
        // baseline/run/bin are slot infrastructure, not source worktrees
        if (Name = '.') or (Name = '..') or (Name = 'out') or Name.StartsWith('.') or
           SameText(Name, 'Packages290') or SameText(Name, 'baseline') or
           SameText(Name, 'run') or SameText(Name, 'bin') then
          Continue;
        if (SR.Attr and faDirectory) = 0 then
          Continue;
        Attrs := GetFileAttributes(PChar(Root + '\' + Name));
        if (Attrs <> INVALID_FILE_ATTRIBUTES) and ((Attrs and FILE_ATTRIBUTE_REPARSE_POINT) <> 0) then
          Continue; // junction => canonical baseline, not worktree source
        Result := Result + ';' + Root + '\' + Name;
      until FindNext(SR) <> 0;
    finally
      System.SysUtils.FindClose(SR);
    end;
  end;
end;

class function TMSBuildRunner.BuildCommandLine(const Args: TCompilerArgs): string;
var
  RSVars: string;
  ExtraProps: string;
  EnvProps: string;
  Target: string;
  ScratchDir: string;
  OutRoot: string;
begin
  RSVars := GetRSVarsPath;
  ExtraProps := '';

  // Default target is /t:build. /t:rebuild's Clean step deletes shared
  // canonical artifacts (reproduced empirically: it deleted W:\DCP\290\*.dcp)
  // and is only allowed with the explicit --rebuild-canonical flag.
  if Args.RebuildCanonical then
    Target := 'rebuild'
  else
    Target := 'build';

  // If test mode, redirect output to a per-process temp folder (PID suffix:
  // two concurrent --test runs must not clean each other's scratch).
  if Args.TestMode then
  begin
    ScratchDir := TestScratchDir;
    if DirectoryExists(ScratchDir) then
    begin
      try
        TDirectory.Delete(ScratchDir, True);
      except
        // Ignore deletion errors
      end;
    end;
    ForceDirectories(ScratchDir);

    ExtraProps := Format(
      '/p:DCC_ExeOutput="%s" /p:DCC_UnitOutputDirectory="%s" ' +
      '/p:DCC_BplOutput="%s" /p:DCC_DcpOutput="%s"',
      [ScratchDir, ScratchDir, ScratchDir, ScratchDir]);
  end;

  // Workspace mode (cmx-workspace slot): ALL outputs under ROOT\out — the
  // explicit /p: globals are what isolates the .dproj that do not import the
  // shared optset. DCC_UnitSearchPath is seeded as an ENVIRONMENT variable
  // (never /p:, which would REPLACE the project's own relative search path);
  // --depends leaves ROOT\out\DCP\290\<Proj>.d for provenance asserts.
  if Args.WorkspaceRoot <> '' then
  begin
    OutRoot := Args.WorkspaceRoot + '\out';
    ForceDirectories(OutRoot + '\BPL\290');
    ForceDirectories(OutRoot + '\DCP\290');
    ForceDirectories(OutRoot + '\DCU\290');
    ForceDirectories(OutRoot + '\OBJ\290');
    ForceDirectories(OutRoot + '\HPP\290');
    ForceDirectories(OutRoot + '\EXE');
    ExtraProps := Format(
      '/p:DCC_BplOutput="%s\BPL\290" /p:DCC_DcpOutput="%s\DCP\290" ' +
      '/p:DCC_DcuOutput="%s\DCU\290" /p:DCC_ObjOutput="%s\OBJ\290" ' +
      '/p:DCC_HppOutput="%s\HPP\290" /p:DCC_ExeOutput="%s\EXE" ' +
      '/p:DCC_AdditionalSwitches=--depends',
      [OutRoot, OutRoot, OutRoot, OutRoot, OutRoot, OutRoot]);
    if GetEnvironmentVariable('DCC_UnitSearchPath') = '' then
      SetEnvironmentVariable('DCC_UnitSearchPath',
        PChar(BuildWorkspaceSearchPath(Args.WorkspaceRoot)));
  end;

  // Pass environment.proj variables not already in the Windows environment.
  // MSBuild doesn't import environment.proj when invoked from the command line;
  // only the IDE does. This ensures custom variables (BPLCMX, DCPCMX, etc.)
  // are available for optset resolution.
  EnvProps := GetMSBuildEnvProperties;
  if EnvProps <> '' then
  begin
    if ExtraProps <> '' then
      ExtraProps := ExtraProps + ' ' + EnvProps
    else
      ExtraProps := EnvProps;
  end;

  // Build the command line
  // We use cmd /c to run rsvars.bat first, then MSBuild
  Result := Format(
    'cmd.exe /c "call "%s" && MSBuild.exe "%s" /t:%s /p:Config=%s /p:Platform=%s /p:PreBuildEvent= /p:PostBuildEvent= /v:normal %s"',
    [RSVars, Args.ProjectPathWin, Target, Args.ConfigStr, Args.PlatformStr, ExtraProps]);
end;

class function TMSBuildRunner.RunProcess(const CommandLine: string;
  out Output: string; out ExitCode: Integer; TimeoutMs: Cardinal): Boolean;
var
  SA: TSecurityAttributes;
  SI: TStartupInfo;
  PI: TProcessInformation;
  hReadPipe, hWritePipe: THandle;
  Buffer: array[0..4095] of Byte;
  WideBuffer: string;
  WideLen: Integer;
  BytesRead: DWORD;
  TotalOutput: TStringBuilder;
  WaitResult: DWORD;
begin
  Result := False;
  Output := '';
  ExitCode := -1;

  // Set up security attributes for pipe inheritance
  FillChar(SA, SizeOf(SA), 0);
  SA.nLength := SizeOf(SA);
  SA.bInheritHandle := True;
  SA.lpSecurityDescriptor := nil;

  // Create pipe for stdout/stderr
  if not CreatePipe(hReadPipe, hWritePipe, @SA, 0) then
    Exit;

  try
    // Ensure the read handle is not inherited
    SetHandleInformation(hReadPipe, HANDLE_FLAG_INHERIT, 0);

    // Set up startup info
    FillChar(SI, SizeOf(SI), 0);
    SI.cb := SizeOf(SI);
    SI.dwFlags := STARTF_USESHOWWINDOW or STARTF_USESTDHANDLES;
    SI.wShowWindow := SW_HIDE;
    SI.hStdOutput := hWritePipe;
    SI.hStdError := hWritePipe;
    SI.hStdInput := 0;

    FillChar(PI, SizeOf(PI), 0);

    // Create the process
    if not CreateProcess(
      nil,
      PChar(CommandLine),
      nil,
      nil,
      True,
      CREATE_NO_WINDOW,
      nil,
      nil,
      SI,
      PI) then
      Exit;

    try
      // Close our copy of the write handle
      CloseHandle(hWritePipe);
      hWritePipe := 0;

      // Read output from pipe
      TotalOutput := TStringBuilder.Create;
      try
        repeat
          if ReadFile(hReadPipe, Buffer, SizeOf(Buffer), BytesRead, nil) and (BytesRead > 0) then
          begin
            // Use explicit OEM codepage conversion to avoid codepage mismatch
            // when running under WSL (MSBuild outputs OEM-encoded text via pipe)
            WideLen := MultiByteToWideChar(CP_OEMCP, 0, @Buffer[0], BytesRead, nil, 0);
            SetLength(WideBuffer, WideLen);
            MultiByteToWideChar(CP_OEMCP, 0, @Buffer[0], BytesRead, PChar(WideBuffer), WideLen);
            TotalOutput.Append(WideBuffer);
          end;
        until BytesRead = 0;

        Output := TotalOutput.ToString;
      finally
        TotalOutput.Free;
      end;

      // Wait for process to finish
      WaitResult := WaitForSingleObject(PI.hProcess, TimeoutMs);
      if WaitResult = WAIT_TIMEOUT then
      begin
        TerminateProcess(PI.hProcess, 1);
        Output := Output + #13#10 + '[TIMEOUT: Process killed after ' + IntToStr(TimeoutMs div 1000) + ' seconds]';
        ExitCode := -2;
      end
      else
      begin
        GetExitCodeProcess(PI.hProcess, DWORD(ExitCode));
      end;

      Result := True;
    finally
      CloseHandle(PI.hProcess);
      CloseHandle(PI.hThread);
    end;
  finally
    if hReadPipe <> 0 then CloseHandle(hReadPipe);
    if hWritePipe <> 0 then CloseHandle(hWritePipe);
  end;
end;

class function TMSBuildRunner.Execute(const Args: TCompilerArgs;
  out Output: string; out ExitCode: Integer): Boolean;
var
  CommandLine: string;
begin
  CommandLine := BuildCommandLine(Args);
  Result := RunProcess(CommandLine, Output, ExitCode, MSBUILD_TIMEOUT_MS);
end;

end.
