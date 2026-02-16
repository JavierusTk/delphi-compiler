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
  TEMP_OUTPUT_DIR = 'W:\temp\compilar';
  MSBUILD_TIMEOUT_MS = 300000; // 5 minutes

class function TMSBuildRunner.GetRSVarsPath: string;
begin
  Result := Config.RsVarsPath;
  if Result = '' then
    raise Exception.Create('rsvars.bat path not configured. Set RSVARS_PATH in delphi-compiler.env');
  if not FileExists(Result) then
    raise Exception.Create('rsvars.bat not found at: ' + Result);
end;

class function TMSBuildRunner.BuildCommandLine(const Args: TCompilerArgs): string;
var
  RSVars: string;
  ExtraProps: string;
  EnvProps: string;
begin
  RSVars := GetRSVarsPath;
  ExtraProps := '';

  // If test mode, redirect output to temp folder
  if Args.TestMode then
  begin
    // Create/clean temp directory
    if DirectoryExists(TEMP_OUTPUT_DIR) then
    begin
      try
        TDirectory.Delete(TEMP_OUTPUT_DIR, True);
      except
        // Ignore deletion errors
      end;
    end;
    ForceDirectories(TEMP_OUTPUT_DIR);

    ExtraProps := Format(
      '/p:DCC_ExeOutput="%s" /p:DCC_UnitOutputDirectory="%s" ' +
      '/p:DCC_BplOutput="%s" /p:DCC_DcpOutput="%s"',
      [TEMP_OUTPUT_DIR, TEMP_OUTPUT_DIR, TEMP_OUTPUT_DIR, TEMP_OUTPUT_DIR]);
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
    'cmd.exe /c "call "%s" && MSBuild.exe "%s" /t:rebuild /p:Config=%s /p:Platform=%s /v:normal %s"',
    [RSVars, Args.ProjectPathWin, Args.ConfigStr, Args.PlatformStr, ExtraProps]);
end;

class function TMSBuildRunner.RunProcess(const CommandLine: string;
  out Output: string; out ExitCode: Integer; TimeoutMs: Cardinal): Boolean;
var
  SA: TSecurityAttributes;
  SI: TStartupInfo;
  PI: TProcessInformation;
  hReadPipe, hWritePipe: THandle;
  Buffer: array[0..4095] of AnsiChar;
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
          FillChar(Buffer, SizeOf(Buffer), 0);
          if ReadFile(hReadPipe, Buffer, SizeOf(Buffer) - 1, BytesRead, nil) and (BytesRead > 0) then
            TotalOutput.Append(string(AnsiString(Buffer)));
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
