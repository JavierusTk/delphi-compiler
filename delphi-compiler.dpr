program DelphiCompiler;

{$APPTYPE CONSOLE}

{$R 'delphi-compiler.res'}

uses
  Winapi.Windows,
  System.SysUtils,
  System.Diagnostics,
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

  /// First MSBuild-level error line in the raw output, trimmed, or '' when there is none.
  /// Used only to explain a 'build_failed' result. These lines carry an MSB#### code
  /// (e.g. "error MSB3061: Unable to delete file ...") and are NOT produced by the Delphi
  /// compiler, so TOutputParser does not recognise them and they never reach Issues[].
  function FirstMSBuildErrorLine(const AOutput: string): string;
  const
    MaxLen = 500;   // MSBuild can echo enormous lines; this goes into JSON.
  var
    Line: string;
    LowerLine: string;
  begin
    for Line in AOutput.Split([sLineBreak, #10]) do
    begin
      LowerLine := LowerCase(Line);
      if (Pos(': error ', LowerLine) > 0) or (Pos('error msb', LowerLine) > 0) then
      begin
        Result := Trim(Line);
        if Length(Result) > MaxLen then
          Result := Copy(Result, 1, MaxLen) + '...';
        EXIT;
      end;
    end;
    Result := '';
  end;

  /// A real pass. Every OTHER status (error, output_locked, build_failed, ...) can and
  /// often does carry "errors": 0 without a trustworthy binary behind it, so success
  /// must never be inferred from the error count. Single definition on purpose - the
  /// rule is applied in three places below and they must not drift apart.
  function IsPassStatus(const AStatus: string): Boolean;
  begin
    Result := (AStatus = 'ok') or (AStatus = 'hints') or (AStatus = 'warnings');
  end;

const
  /// Sentinel exit code TMSBuildRunner.RunProcess assigns when it kills MSBuild on
  /// timeout (Compilar.MSBuild.pas: `ExitCode := -2`). Not an MSBuild exit code -
  /// it means MSBuild never got to report one.
  MSBUILD_KILLED_EXIT = -2;

var
  Args: TCompilerArgs;
  ParseError: string;
  MSBuildFailLine: string;
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
    // 0. Version query (exclusive first-arg mode): tool identity, no compile.
    if (ParamCount >= 1) and SameText(ParamStr(1), '--version') then
    begin
      WriteStdout(TJSONOutput.Version);
      ExitCode := 0;
      Exit;
    end;

    // 1. Parse command line arguments
    if not TArgsParser.Parse(Args, ParseError) then
    begin
      WriteStdout(TJSONOutput.Invalid(ParseError));
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

    // 7b2. MSBuild failed, produced no parseable compiler diagnostic, and the status
    // computed above is STILL a pass. That combination is the deceptive one: the issue
    // parser only recognises DCC diagnostics (E####/W####/H####), so an MSBuild-level
    // failure such as
    //   error MSB3061: Unable to delete file "Foo.exe". Access to the path ... is denied.
    // leaves ErrorCount at 0 - not because the code is clean, but because there was
    // nothing to count. Step 9 would then map 'ok' to exit code 0 and certify a build
    // that never happened. Reachable whenever no output binary exists to make step 7b
    // fire: the first build of a project, a malformed .dproj (MSB4025), a failed --test.
    // Deliberately does NOT touch 'output_locked' (or any other non-pass status): 7b
    // already diagnosed that case correctly and step 7e prints a stderr warning keyed
    // on it, which overriding the status here would silently switch off.
    if (MSBuildExitCode <> 0) and (Result.ErrorCount = 0) and IsPassStatus(Result.Status) then
    begin
      Result.Status := 'build_failed';
      MSBuildFailLine := FirstMSBuildErrorLine(MSBuildOutput);

      // Three quite different situations share "MSBuild failed with no compiler error",
      // so diagnose before describing. Getting this wrong is not harmless: a message
      // saying "nothing was compiled" next to a binary that WAS just built is worse
      // than no message at all.
      if MSBuildExitCode = MSBUILD_KILLED_EXIT then
        Result.OutputMessage := 'MSBuild exceeded the internal timeout and was killed, so the build never finished.' +
          ' The compiler may have run partially - do NOT trust the output binary.'
      else
      if Result.OutputPath <> '' then
        // A binary exists, and step 7b found it fresh - a stale one would have become
        // 'output_locked', which the guard above excludes. So compile and link both
        // succeeded and something after them failed: typically a custom <Target> doing
        // a post-link patch or a signing step. OutputStale stays FALSE on purpose;
        // 7b measured the timestamp and claiming otherwise would contradict it.
        Result.OutputMessage := 'The project compiled and linked, but a later MSBuild step failed (exit code ' +
          IntToStr(MSBuildExitCode) + '). The binary was produced, but whatever that step was meant to do to it did NOT happen.'
      else
        // No binary at all: the compiler never got to run.
        Result.OutputMessage := 'MSBuild exited with code ' + IntToStr(MSBuildExitCode) +
          ' without reporting any compiler error, so the compiler did not run and NOTHING was compiled.' +
          ' Do NOT read this as a successful build.';

      if MSBuildFailLine <> '' then
        Result.OutputMessage := Result.OutputMessage + ' First MSBuild error: ' + MSBuildFailLine;
      // MSB3061 = Clean could not delete the output binary, i.e. it is still running.
      if Pos('MSB3061', MSBuildFailLine) > 0 then
        Result.OutputMessage := Result.OutputMessage +
          ' The output binary is locked by a running process - close it and recompile.';
    end;

    // 7c. Store PreBuild event info
    if not LPreBuildCmd.IsEmpty then
      Result.PreBuildEvent := LEventResult;

    // 7d. Run PostBuild event - only after a REAL pass. Gating on ErrorCount alone let
    // the event run against a stale binary: output_locked and build_failed both carry
    // errors:0 without having produced one, so a signing / patching / deploy step would
    // silently operate on the PREVIOUS build's output and report success.
    if (not LPostBuildCmd.IsEmpty) and IsPassStatus(Result.Status) then
    begin
      LEventResult := TBuildEvents.Execute(LPostBuildCmd, LProjectDir);
      Result.PostBuildEvent := LEventResult;
    end;

    // 7e. Loud stderr line for the deceptive zero-error non-build (output_locked).
    //     Sessions VERY often pipe stdout through an inline minimizer that prints only
    //     the error count; that hides output_locked (errors:0 but NOTHING compiled).
    //     stderr is not consumed by a stdout-only pipe, so this survives the pattern.
    if Result.Status = 'output_locked' then
      WriteStderr('[delphi-compiler] NOT A BUILD (status=output_locked): output binary locked by another process; MSBuild /t:rebuild Clean aborted before compiling, so NOTHING was compiled. "errors":0 is meaningless here. Free the lock (close the running app) and recompile.');

    // Same reasoning as 7e, for the no-binary variant: build_failed also reports
    // "errors": 0, and stdout-only minimizers would show it as a clean build.
    if Result.Status = 'build_failed' then
      WriteStderr('[delphi-compiler] NOT A BUILD (status=build_failed): ' + Result.OutputMessage);

    // 8. Output JSON (error items only unless --full; counters always complete)
    WriteStdout(TJSONOutput.Generate(Result, Args.FullOutput));

    // 9. Deterministic process exit code (v1.9). A real pass is EXACTLY
    //    status in {ok, hints, warnings}; every other status (error,
    //    output_locked, ...) reports errors:0 or not, but did NOT produce a
    //    trustworthy binary. Callers key on the exit code (or on status),
    //    never on the error count alone.
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
