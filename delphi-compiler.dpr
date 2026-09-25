program DelphiCompiler;

{$APPTYPE CONSOLE}

{$R 'delphi-compiler.res'}

uses
  Winapi.Windows,
  System.SysUtils,
  System.Diagnostics,
  CmxWorkspace.Detect in '..\..\cmx-slots\lib\CmxWorkspace.Detect.pas',
  Compilar.Types in 'Compilar.Types.pas',
  Compilar.Args in 'Compilar.Args.pas',
  Compilar.Config in 'Compilar.Config.pas',
  Compilar.PathUtils in 'Compilar.PathUtils.pas',
  Compilar.MSBuild in 'Compilar.MSBuild.pas',
  Compilar.Parser in 'Compilar.Parser.pas',
  Compilar.Context in 'Compilar.Context.pas',
  Compilar.ProjectInfo in 'Compilar.ProjectInfo.pas',
  Compilar.Output in 'Compilar.Output.pas',
  Compilar.BuildEvents in 'Compilar.BuildEvents.pas';

  procedure WriteStdout(const S: string);
  var
    Bytes: TBytes;
    Handle: THandle;
    Written: DWORD;
  begin
    Handle := GetStdHandle(STD_OUTPUT_HANDLE);
    Bytes := TEncoding.UTF8.GetBytes(S + sLineBreak);
    WriteFile(Handle, Bytes[0], Length(Bytes), Written, nil);
  end;

  procedure WriteStderr(const S: string);
  var
    Bytes: TBytes;
    Handle: THandle;
    Written: DWORD;
  begin
    Handle := GetStdHandle(STD_ERROR_HANDLE);
    Bytes := TEncoding.UTF8.GetBytes(S + sLineBreak);
    WriteFile(Handle, Bytes[0], Length(Bytes), Written, nil);
  end;

  // A real pass is EXACTLY status in {ok, hints, warnings} (v1.9 contract).
  function IsPassStatus(const AStatus: string): Boolean;
  begin
    Result := (AStatus = 'ok') or (AStatus = 'hints') or (AStatus = 'warnings');
  end;

var
  Args: TCompilerArgs;
  ParseError: string;
  MSBuildOutput: string;
  MSBuildExitCode: Integer;
  Issues: TArray<TCompileIssue>;
  Result: TCompileResult;
  Truncated: Boolean;
  TotalIssuesFound: Integer;
  SW: TStopwatch;
  CompileStartTime: TDateTime;
  OutputWinPath: string;
  OutputFileTime: TDateTime;
  LPreBuildCmd: string;
  LPostBuildCmd: string;
  LProjectDir: string;
  LEventResult: TBuildEventInfo;
begin

  try
    // 0. Informational flags (--version / --help) win from ANY position and
    //    never compile (v1.12): asking a tool what it is must not depend on
    //    where the question sits on the command line.
    case TArgsParser.DetectInfoRequest of
      irVersion:
        begin
          WriteStdout(TJSONOutput.Version);
          ExitCode := 0;
          Exit;
        end;
      irHelp:
        begin
          WriteStdout(TJSONOutput.Help);
          ExitCode := 0;
          Exit;
        end;
    end;

    // 1. Parse command line arguments
    if not TArgsParser.Parse(Args, ParseError) then
    begin
      // Args.WsFailure is filled only when the CAUSE is the workspace ladder;
      // an ordinary argument error emits the historical shape unchanged.
      WriteStdout(TJSONOutput.Invalid(ParseError, Args.WsFailure));
      ExitCode := 2;
      Exit;
    end;

    // 2. Initialize config (env file, env vars, auto-detection)
    InitConfig(Args.ProjectPathWin, Args.WSLMode);

    // 2b. Parse and run pre-build event
    LProjectDir := ExtractFilePath(Args.ProjectPathWin);
    LPreBuildCmd := TBuildEvents.GetPreBuildEvent(
      Args.ProjectPathWin, Args.ConfigStr, Args.PlatformStr);
    LPostBuildCmd := TBuildEvents.GetPostBuildEvent(
      Args.ProjectPathWin, Args.ConfigStr, Args.PlatformStr);

    if not LPreBuildCmd.IsEmpty then
    begin
      LEventResult := TBuildEvents.Execute(LPreBuildCmd, LProjectDir);
      if not LEventResult.Success then
      begin
        WriteStdout(TJSONOutput.BuildEventError('prebuild', Args, LEventResult));
        ExitCode := 1;
        Exit;
      end;
    end;

    // 3. Run MSBuild (with timing)
    CompileStartTime := Now;
    SW := TStopwatch.StartNew;

    if not TMSBuildRunner.Execute(Args, MSBuildOutput, MSBuildExitCode) then
    begin
      WriteStdout(TJSONOutput.InternalError('MSBuild execution failed'));
      ExitCode := 3;
      Exit;
    end;

    SW.Stop;

    // 3b. Echo raw output if requested
    if Args.RawOutput then
    begin
      WriteStderr('--- MSBuild Raw Output (ExitCode=' + IntToStr(MSBuildExitCode) + ', Len=' + IntToStr(Length(MSBuildOutput)) + ') ---');
      WriteStderr(MSBuildOutput);
      WriteStderr('--- End Raw Output ---');
    end;

    // 4. Parse MSBuild output (with truncation tracking)
    Issues := TOutputParser.Parse(MSBuildOutput, Args.MaxErrors, Truncated, TotalIssuesFound);

    // 5. Enrich issues with source context (ProjectDir resolves dcc's
    //    project-relative paths, e.g. the main .dpr in F-level errors)
    TContextEnricher.AddSourceContext(Issues, Args.ContextLines, LProjectDir);

    // 6. Build result
    Result := TCompileResult.Create(Args, Issues, MSBuildExitCode, Truncated, TotalIssuesFound);
    Result.ProjectPath := TPathUtils.NormalizeForOutput(Args.ProjectPathWin);
    Result.TimeMs := SW.ElapsedMilliseconds;

    // 7. Resolve output binary path (MSBuild output is authoritative, dproj is fallback)
    Result.OutputPath := TProjectInfo.GetOutputFromMSBuild(MSBuildOutput, Args);
    if Result.OutputPath = '' then
      Result.OutputPath := TProjectInfo.GetOutputPath(Args);

    // 7b. Verify output was actually produced by this compilation (not a stale file)
    if Result.OutputPath <> '' then
    begin
      OutputWinPath := TPathUtils.NormalizeToWindows(Result.OutputPath);
      if FileAge(OutputWinPath, OutputFileTime) then
      begin
        if OutputFileTime < CompileStartTime then
        begin
          Result.OutputStale := True;
          Result.OutputMessage := 'NOT A SUCCESSFUL BUILD. The output binary was NOT rewritten by this run (most likely locked by another process: with /t:rebuild the Clean step aborts before compiling; with the default /t:build the linker cannot rewrite the locked file). "errors":0 here is meaningless. Close the process holding the output (or free the file) and recompile to get a real result.';
          // NOT a success: a locked output means the binary on disk does not
          // correspond to this compilation. Flag it distinctly, but callers must
          // NOT read output_locked as a clean compile: errors=0 here means
          // "output not produced", not "compiled with no errors".
          if Result.ErrorCount = 0 then
            Result.Status := 'output_locked';
        end;
      end;
    end;

    // 7c. Store PreBuild event info
    if not LPreBuildCmd.IsEmpty then
      Result.PreBuildEvent := LEventResult;

    // 7d. PostBuild event (v1.13). Runs only after a REAL pass: keying on
    //     ErrorCount = 0 let it run on output_locked and deploy a binary this
    //     run never wrote. A defined event that does not run is reported as
    //     skipped with its reason, never silently dropped.
    if not LPostBuildCmd.IsEmpty then
    begin
      Result.PostBuildEvent.Command := LPostBuildCmd;
      if not IsPassStatus(Result.Status) then
      begin
        Result.PostBuildEvent.Skipped := True;
        Result.PostBuildEvent.SkipReason := 'compilation did not pass (status=' + Result.Status + ')';
      end
      else if Args.WorkspaceRoot <> '' then
      begin
        // Slot build: outputs are redirected under ROOT\out, but the event was
        // written for the canonical tree (absolute W:\ paths, $(...) macros this
        // tool does not expand). Running it would fail or copy a slot binary
        // into the canonical tree; cmx-workspace build suppresses it as well.
        Result.PostBuildEvent.Skipped := True;
        Result.PostBuildEvent.SkipReason := 'workspace mode: outputs are redirected under the slot and the event targets the canonical tree';
      end
      else
      begin
        LEventResult := TBuildEvents.Execute(LPostBuildCmd, LProjectDir);
        Result.PostBuildEvent := LEventResult;
        // The binary compiled, but the build the .dproj declares did not
        // complete (typically a deploy copy): not a pass.
        if not LEventResult.Success then
          Result.Status := 'postbuild_error';
      end;
    end;

    // 7e. Loud stderr line for the deceptive zero-error non-build (output_locked).
    //     Sessions VERY often pipe stdout through an inline minimizer that prints only
    //     the error count; that hides output_locked (errors:0 but NOTHING compiled).
    //     stderr is not consumed by a stdout-only pipe, so this survives the pattern.
    if Result.Status = 'output_locked' then
      WriteStderr('[delphi-compiler] NOT A BUILD (status=output_locked): output binary locked by another process; MSBuild /t:rebuild Clean aborted before compiling, so NOTHING was compiled. "errors":0 is meaningless here. Free the lock (close the running app) and recompile.')
    else if Result.Status = 'postbuild_error' then
      WriteStderr('[delphi-compiler] NOT A PASS (status=postbuild_error): the sources compiled but the .dproj PostBuild event failed (exit ' + IntToStr(Result.PostBuildEvent.ExitCode) + '). "errors":0 does not mean the build completed; see post_build_event in the JSON.');

    // 8. Output JSON (error items only unless --full; counters always complete)
    WriteStdout(TJSONOutput.Generate(Result, Args.FullOutput));

    // 9. Deterministic process exit code (v1.9). A real pass is EXACTLY
    //    status in {ok, hints, warnings}; every other status (error,
    //    output_locked, postbuild_error, ...) reports errors:0 or not, but did
    //    NOT complete a trustworthy build. Callers key on the exit code (or on
    //    status), never on the error count alone.
    if IsPassStatus(Result.Status) then
      ExitCode := 0
    else
      ExitCode := 1;

  except
    on E: Exception do
    begin
      WriteStdout(TJSONOutput.InternalError(E.Message));
      ExitCode := 3;
    end;
  end;
end.
