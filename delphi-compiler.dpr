program DelphiCompiler;

{$APPTYPE CONSOLE}

uses
  System.SysUtils,
  System.Diagnostics,
  Compilar.Types in 'Compilar.Types.pas',
  Compilar.Args in 'Compilar.Args.pas',
  Compilar.Config in 'Compilar.Config.pas',
  Compilar.PathUtils in 'Compilar.PathUtils.pas',
  Compilar.MSBuild in 'Compilar.MSBuild.pas',
  Compilar.Parser in 'Compilar.Parser.pas',
  Compilar.Lookup in 'Compilar.Lookup.pas',
  Compilar.Context in 'Compilar.Context.pas',
  Compilar.ProjectInfo in 'Compilar.ProjectInfo.pas',
  Compilar.Output in 'Compilar.Output.pas';

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
begin
  try
    // 1. Parse command line arguments
    if not TArgsParser.Parse(Args, ParseError) then
    begin
      Writeln(TJSONOutput.Invalid(ParseError));
      ExitCode := 0;
      Exit;
    end;

    // 2. Initialize config (env file, env vars, auto-detection)
    InitConfig(Args.ProjectPathWin, Args.WSLMode);

    // 3. Run MSBuild (with timing)
    CompileStartTime := Now;
    SW := TStopwatch.StartNew;

    if not TMSBuildRunner.Execute(Args, MSBuildOutput, MSBuildExitCode) then
    begin
      Writeln(TJSONOutput.InternalError('MSBuild execution failed'));
      ExitCode := 0;
      Exit;
    end;

    SW.Stop;

    // 3b. Echo raw output if requested
    if Args.RawOutput then
    begin
      Writeln(ErrOutput, '--- MSBuild Raw Output (ExitCode=' + IntToStr(MSBuildExitCode) + ', Len=' + IntToStr(Length(MSBuildOutput)) + ') ---');
      Writeln(ErrOutput, MSBuildOutput);
      Writeln(ErrOutput, '--- End Raw Output ---');
    end;

    // 4. Parse MSBuild output (with truncation tracking)
    Issues := TOutputParser.Parse(MSBuildOutput, Args.MaxErrors, Truncated, TotalIssuesFound);

    // 5. Enrich issues with context and lookup
    TContextEnricher.AddSourceContext(Issues, Args.ContextLines);
    TLookupEnricher.AddLookup(Issues);

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
          Result.OutputPath := '';  // Don't report stale output as valid
        end;
      end;
    end;

    // 8. Output JSON
    Writeln(TJSONOutput.Generate(Result));
    ExitCode := 0;

  except
    on E: Exception do
    begin
      Writeln(TJSONOutput.InternalError(E.Message));
      ExitCode := 0;
    end;
  end;
end.
