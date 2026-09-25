unit Compilar.Output;

interface

uses
  Compilar.Types;

type
  TJSONOutput = class
  public
    /// Generate pretty-printed JSON for successful/error compilation result.
    /// AFullIssues=False (the CLI default) lists only error/fatal items in the
    /// issues array — warnings/hints stay as counters plus "issues_omitted" —
    /// so sessions get a minimal honest projection without piping through
    /// ad-hoc filters. --full restores every item.
    class function Generate(const AResult: TCompileResult;
      AFullIssues: Boolean = True): string;

    /// Generate JSON for invalid arguments (no workspace cause: historical
    /// {status, version, error} shape, no workspace field whatsoever)
    class function Invalid(const ErrorMsg: string): string; overload;

    /// Same, plus the STRUCTURED identity of a failure caused by the
    /// cmx-workspace resolution ladder (v1.12 fix, post-review R1):
    /// `workspace_source` and, for the two-slot failures, `workspace_conflict`
    /// — so a JSON client never has to parse the prose of `error` to learn
    /// which slots collided. Emits nothing extra when AWs.Present is False.
    class function Invalid(const ErrorMsg: string;
      const AWs: TCmxWsFailure): string; overload;

    /// Generate JSON for the --version query (tool identity, no compile)
    class function Version: string;

    /// Generate JSON for the --help query (usage, options, exit codes; no
    /// compile). JSON like every other output: stdout of this tool is always
    /// machine-readable, help included.
    class function Help: string;

    /// Generate JSON for internal error
    class function InternalError(const ErrorMsg: string): string;

    /// Generate JSON for build event failure (prebuild/postbuild)
    class function BuildEventError(const AEventType: string;
      const Args: TCompilerArgs; const AEvent: TBuildEventInfo): string;

  private
    class function EscapeJSON(const S: string): string;
    class function IssueToJSON(const Issue: TCompileIssue; Indent: Integer): string;
    class function StringArrayToJSON(const Arr: TArray<string>; Indent: Integer): string;
    class function Pad(Level: Integer): string;
  end;

implementation

uses
  System.SysUtils, System.IOUtils, System.Classes,
  Compilar.Config, Compilar.PathUtils, CmxWorkspace.Detect;

const
  INDENT_SIZE = 2;
  NL = #13#10;

class function TJSONOutput.Pad(Level: Integer): string;
begin
  Result := StringOfChar(' ', Level * INDENT_SIZE);
end;

class function TJSONOutput.EscapeJSON(const S: string): string;
var
  I: Integer;
  C: Char;
  SB: TStringBuilder;
begin
  SB := TStringBuilder.Create;
  try
    for I := 1 to Length(S) do
    begin
      C := S[I];
      case C of
        '"': SB.Append('\"');
        '\': SB.Append('\\');
        '/': SB.Append('\/');
        #8: SB.Append('\b');
        #9: SB.Append('\t');
        #10: SB.Append('\n');
        #12: SB.Append('\f');
        #13: SB.Append('\r');
      else
        if (Ord(C) < 32) or (Ord(C) > 127) then
          SB.Append(Format('\u%4.4x', [Ord(C)]))
        else
          SB.Append(C);
      end;
    end;
    Result := SB.ToString;
  finally
    SB.Free;
  end;
end;

class function TJSONOutput.StringArrayToJSON(const Arr: TArray<string>; Indent: Integer): string;
var
  SB: TStringBuilder;
  I: Integer;
  P: string;
begin
  if Length(Arr) = 0 then
    Exit('[]');

  P := Pad(Indent);
  SB := TStringBuilder.Create;
  try
    SB.Append('[').Append(NL);
    for I := 0 to High(Arr) do
    begin
      SB.Append(P).Append(Pad(1)).Append('"').Append(EscapeJSON(Arr[I])).Append('"');
      if I < High(Arr) then
        SB.Append(',');
      SB.Append(NL);
    end;
    SB.Append(P).Append(']');
    Result := SB.ToString;
  finally
    SB.Free;
  end;
end;

class function TJSONOutput.IssueToJSON(const Issue: TCompileIssue; Indent: Integer): string;
var
  SB: TStringBuilder;
  P, P1: string;
begin
  P := Pad(Indent);
  P1 := Pad(Indent + 1);

  SB := TStringBuilder.Create;
  try
    SB.Append('{').Append(NL);
    SB.Append(P1).Append('"type": "').Append(IssueTypeToStr(Issue.IssueType)).Append('",').Append(NL);
    SB.Append(P1).Append('"code": "').Append(EscapeJSON(Issue.Code)).Append('",').Append(NL);
    SB.Append(P1).Append('"file": "').Append(EscapeJSON(Issue.FilePath)).Append('",').Append(NL);
    SB.Append(P1).Append('"line": ').Append(IntToStr(Issue.Line)).Append(',').Append(NL);
    SB.Append(P1).Append('"column": ').Append(IntToStr(Issue.Column)).Append(',').Append(NL);
    SB.Append(P1).Append('"message": "').Append(EscapeJSON(Issue.Message)).Append('"');

    // Add context if available
    if Length(Issue.Context) > 0 then
    begin
      SB.Append(',').Append(NL);
      SB.Append(P1).Append('"context": ').Append(StringArrayToJSON(Issue.Context, Indent + 1));
    end;

    SB.Append(NL);
    SB.Append(P).Append('}');
    Result := SB.ToString;
  finally
    SB.Free;
  end;
end;

class function TJSONOutput.Generate(const AResult: TCompileResult;
  AFullIssues: Boolean): string;
var
  SB: TStringBuilder;
  I, Omitted: Integer;
  P1, P2: string;
  Shown: TArray<TCompileIssue>;
begin
  P1 := Pad(1);
  P2 := Pad(2);

  // Default projection: error/fatal items only; warnings/hints remain visible
  // as counters. --full lists everything.
  if AFullIssues then
    Shown := AResult.Issues
  else
  begin
    Shown := [];
    for I := 0 to High(AResult.Issues) do
      if AResult.Issues[I].IssueType in [itError, itFatal] then
        Shown := Shown + [AResult.Issues[I]];
  end;
  Omitted := Length(AResult.Issues) - Length(Shown);

  SB := TStringBuilder.Create;
  try
    SB.Append('{').Append(NL);

    SB.Append(P1).Append('"status": "').Append(EscapeJSON(AResult.Status)).Append('",').Append(NL);
    SB.Append(P1).Append('"version": "').Append(COMPILER_VERSION).Append('",').Append(NL);
    SB.Append(P1).Append('"project": "').Append(EscapeJSON(AResult.Project)).Append('",').Append(NL);
    SB.Append(P1).Append('"project_path": "').Append(EscapeJSON(AResult.ProjectPath)).Append('",').Append(NL);
    SB.Append(P1).Append('"config": "').Append(EscapeJSON(AResult.Config)).Append('",').Append(NL);
    SB.Append(P1).Append('"platform": "').Append(EscapeJSON(AResult.Platform)).Append('",').Append(NL);

    // cmx-workspace identity (v1.12): which rung of the §5.3 ladder decided the
    // build overlay. ALWAYS present — 'none' is a canonical build.
    SB.Append(P1).Append('"workspace_source": "').Append(EscapeJSON(AResult.WorkspaceSource)).Append('",').Append(NL);
    if AResult.WorkspaceRoot <> '' then
      SB.Append(P1).Append('"workspace_root": "').Append(EscapeJSON(AResult.WorkspaceRoot)).Append('",').Append(NL);
    // Non-fatal env<>marker divergence (a higher rung arbitrated it): reported
    // so the caller can see the ambiguity that was NOT used to decide.
    if (AResult.ConflictEnvSlot <> '') or (AResult.ConflictMarkerSlot <> '') then
    begin
      SB.Append(P1).Append('"workspace_conflict": {').Append(NL);
      SB.Append(P2).Append('"env": "').Append(EscapeJSON(AResult.ConflictEnvSlot)).Append('",').Append(NL);
      SB.Append(P2).Append('"marker": "').Append(EscapeJSON(AResult.ConflictMarkerSlot)).Append('"').Append(NL);
      SB.Append(P1).Append('},').Append(NL);
    end;

    if AResult.OutputPath <> '' then
    begin
      SB.Append(P1).Append('"output": "').Append(EscapeJSON(AResult.OutputPath)).Append('",').Append(NL);
      if AResult.OutputStale then
      begin
        SB.Append(P1).Append('"output_stale": true,').Append(NL);
        if AResult.OutputMessage <> '' then
          SB.Append(P1).Append('"output_message": "').Append(EscapeJSON(AResult.OutputMessage)).Append('",').Append(NL);
      end;
    end;

    // Config warnings (if any)
    if Length(Config.Warnings) > 0 then
    begin
      SB.Append(P1).Append('"config_warnings": ').Append(StringArrayToJSON(Config.Warnings, 1)).Append(',').Append(NL);
    end;

    // Build events (if executed)
    if AResult.PreBuildEvent.Executed then
    begin
      SB.Append(P1).Append('"pre_build_event": {').Append(NL);
      SB.Append(P2).Append('"command": "').Append(EscapeJSON(AResult.PreBuildEvent.Command)).Append('",').Append(NL);
      SB.Append(P2).Append('"exit_code": ').Append(IntToStr(AResult.PreBuildEvent.ExitCode));
      if AResult.PreBuildEvent.Output <> '' then
      begin
        SB.Append(',').Append(NL);
        SB.Append(P2).Append('"output": "').Append(EscapeJSON(AResult.PreBuildEvent.Output)).Append('"');
      end;
      SB.Append(NL);
      SB.Append(P1).Append('},').Append(NL);
    end;

    if AResult.PostBuildEvent.Executed then
    begin
      SB.Append(P1).Append('"post_build_event": {').Append(NL);
      SB.Append(P2).Append('"command": "').Append(EscapeJSON(AResult.PostBuildEvent.Command)).Append('",').Append(NL);
      SB.Append(P2).Append('"exit_code": ').Append(IntToStr(AResult.PostBuildEvent.ExitCode));
      if AResult.PostBuildEvent.Output <> '' then
      begin
        SB.Append(',').Append(NL);
        SB.Append(P2).Append('"output": "').Append(EscapeJSON(AResult.PostBuildEvent.Output)).Append('"');
      end;
      SB.Append(NL);
      SB.Append(P1).Append('},').Append(NL);
    end
    else if AResult.PostBuildEvent.Skipped then
    begin
      // Defined in the .dproj but not run (v1.13): say so and why.
      SB.Append(P1).Append('"post_build_event": {').Append(NL);
      SB.Append(P2).Append('"command": "').Append(EscapeJSON(AResult.PostBuildEvent.Command)).Append('",').Append(NL);
      SB.Append(P2).Append('"skipped": true,').Append(NL);
      SB.Append(P2).Append('"reason": "').Append(EscapeJSON(AResult.PostBuildEvent.SkipReason)).Append('"').Append(NL);
      SB.Append(P1).Append('},').Append(NL);
    end;

    SB.Append(P1).Append('"time_ms": ').Append(IntToStr(AResult.TimeMs)).Append(',').Append(NL);
    SB.Append(P1).Append('"exit_code": ').Append(IntToStr(AResult.ExitCode)).Append(',').Append(NL);
    SB.Append(P1).Append('"errors": ').Append(IntToStr(AResult.ErrorCount)).Append(',').Append(NL);
    SB.Append(P1).Append('"warnings": ').Append(IntToStr(AResult.WarningCount)).Append(',').Append(NL);
    SB.Append(P1).Append('"hints": ').Append(IntToStr(AResult.HintCount)).Append(',').Append(NL);

    if AResult.Truncated then
    begin
      SB.Append(P1).Append('"truncated": true,').Append(NL);
      SB.Append(P1).Append('"total_issues_found": ').Append(IntToStr(AResult.TotalIssuesFound)).Append(',').Append(NL);
    end;

    // Brief-mode marker: warning/hint items exist but are not listed
    if Omitted > 0 then
    begin
      SB.Append(P1).Append('"issues_omitted": ').Append(IntToStr(Omitted)).Append(',').Append(NL);
      SB.Append(P1).Append('"issues_detail": "error items only - rerun with --full for warning/hint items",').Append(NL);
    end;

    // Issues array (always present, may be empty)
    SB.Append(P1).Append('"issues": ');
    if Length(Shown) = 0 then
    begin
      SB.Append('[]').Append(NL);
    end
    else
    begin
      SB.Append('[').Append(NL);
      for I := 0 to High(Shown) do
      begin
        SB.Append(P2).Append(IssueToJSON(Shown[I], 2));
        if I < High(Shown) then
          SB.Append(',');
        SB.Append(NL);
      end;
      SB.Append(P1).Append(']').Append(NL);
    end;

    SB.Append('}');
    Result := SB.ToString;
  finally
    SB.Free;
  end;
end;

class function TJSONOutput.Invalid(const ErrorMsg: string): string;
var
  NoWs: TCmxWsFailure;
begin
  NoWs.Clear;
  Result := Invalid(ErrorMsg, NoWs);
end;

class function TJSONOutput.Invalid(const ErrorMsg: string;
  const AWs: TCmxWsFailure): string;
var
  WsFields: string;
begin
  WsFields := '';
  if AWs.Present then
  begin
    // Which rung of the §5.3 ladder this fatal is ABOUT ('none' = no identity
    // could be adopted, which is itself the failure in the conflict family).
    WsFields := Pad(1) + '"workspace_source": "' + EscapeJSON(AWs.Source) + '",' + NL;
    // Both slots of a two-sided failure. Keys name the sides and therefore the
    // kind: {env, marker} for the env<>CWD-marker conflict (identical shape to
    // the non-fatal workspace_conflict of a build result), {project, workspace}
    // for the project<>effective-workspace mismatch. When a fatal carries one,
    // it describes the conflict that CAUSED the exit.
    if AWs.KeyA <> '' then
      WsFields := WsFields +
        Pad(1) + '"workspace_conflict": {' + NL +
        Pad(2) + '"' + EscapeJSON(AWs.KeyA) + '": "' + EscapeJSON(AWs.SlotA) + '",' + NL +
        Pad(2) + '"' + EscapeJSON(AWs.KeyB) + '": "' + EscapeJSON(AWs.SlotB) + '"' + NL +
        Pad(1) + '},' + NL;
  end;

  Result := '{' + NL +
    Pad(1) + '"status": "invalid",' + NL +
    Pad(1) + '"version": "' + COMPILER_VERSION + '",' + NL +
    WsFields +
    Pad(1) + '"error": "' + EscapeJSON(ErrorMsg) + '"' + NL +
    '}';
end;

class function TJSONOutput.Version: string;
begin
  // cmx_ws_contract surfaces the detection-contract version compiled INTO this
  // exe (MARKER-CONTRACT.md §6): cmx-slots/lib ships no versioned DCP, so each
  // consumer recompiles its own copy and can drift. Comparing this number
  // between tools is how that skew is detected.
  Result := '{' + NL +
    Pad(1) + '"tool": "delphi-compiler",' + NL +
    Pad(1) + '"version": "' + COMPILER_VERSION + '",' + NL +
    Pad(1) + '"cmx_ws_contract": ' + IntToStr(CMX_WS_CONTRACT) + NL +
    '}';
end;

class function TJSONOutput.Help: string;

  function Opt(const AFlag, ADefault, ADesc: string; ALast: Boolean = False): string;
  begin
    Result := Pad(2) + '{"flag": "' + EscapeJSON(AFlag) + '", "default": "' +
      EscapeJSON(ADefault) + '", "description": "' + EscapeJSON(ADesc) + '"}';
    if not ALast then
      Result := Result + ',';
    Result := Result + NL;
  end;

begin
  Result := '{' + NL +
    Pad(1) + '"tool": "delphi-compiler",' + NL +
    Pad(1) + '"version": "' + COMPILER_VERSION + '",' + NL +
    Pad(1) + '"usage": "delphi-compiler.exe <project.dproj> [options]",' + NL +
    Pad(1) + '"notes": [' + NL +
    Pad(2) + '"Options and the project path may appear in any order; an unrecognized argument is an error (status invalid, exit 2), never ignored.",' + NL +
    Pad(2) + '"--version and --help are informational in any position: they print and exit 0 without compiling.",' + NL +
    Pad(2) + '"Project path accepts Windows (W:\\...) or WSL (/mnt/w/...) form.",' + NL +
    Pad(2) + '"A pass is status in {ok, hints, warnings} — never infer success from errors:0 alone.",' + NL +
    Pad(2) + '"MSBuild task errors (code MSBnnnn) count as errors, and a failed MSBuild run is never a pass even when no error line is recognized (code MSBUILD_EXIT).",' + NL +
    Pad(2) + '"The .dproj PostBuild event runs only after a pass and never in workspace or --test mode (reported as skipped); if it fails, status is postbuild_error."' + NL +
    Pad(1) + '],' + NL +
    Pad(1) + '"exit_codes": {' + NL +
    Pad(2) + '"0": "pass (status ok|hints|warnings) or informational query",' + NL +
    Pad(2) + '"1": "build failure (error, output_locked, prebuild_error, postbuild_error)",' + NL +
    Pad(2) + '"2": "invalid (bad arguments, project not found, workspace guard)",' + NL +
    Pad(2) + '"3": "internal_error (MSBuild could not run, unexpected exception)"' + NL +
    Pad(1) + '},' + NL +
    Pad(1) + '"options": [' + NL +
    Opt('--config=Debug|Release', 'Debug', 'Build configuration') +
    Opt('--platform=Win32|Win64', 'Win32', 'Target platform') +
    Opt('--max-errors=N', '3', 'Max error items included in the output (1-10)') +
    Opt('--context-lines=N', '5', 'Lines of source context around each error (0-20)') +
    Opt('--workspace=ROOT', '(resolution ladder)', 'Build inside a cmx-workspace slot: all outputs under ROOT\out. Highest rung of the identity ladder (flag > project path > validated CMX_WORKSPACE > marker-walk > none)') +
    Opt('--rebuild-canonical', 'off', 'Use MSBuild /t:rebuild instead of /t:build. Forbidden in workspace mode') +
    Opt('--test', 'off', 'Compile to a per-process temp folder (every output, DCUs included; PostBuild not run). Mutually exclusive with workspace mode') +
    Opt('--raw', 'off', 'Echo raw MSBuild output to stderr') +
    Opt('--full', 'off', 'List warning/hint items in issues too (default: error items only)') +
    Opt('--wsl', 'off', 'Output file paths in Linux form (/mnt/x/...)') +
    Opt('--version', '-', 'Print tool identity JSON and exit 0 (no compile)') +
    Opt('--help', '-', 'Print this JSON and exit 0 (no compile)') +
    Opt('DEBUG|RELEASE|WIN32|WIN64|TEST', '-', 'Legacy positional keywords, equivalent to the matching option', True) +
    Pad(1) + ']' + NL +
    '}';
end;

class function TJSONOutput.InternalError(const ErrorMsg: string): string;
begin
  Result := '{' + NL +
    Pad(1) + '"status": "internal_error",' + NL +
    Pad(1) + '"version": "' + COMPILER_VERSION + '",' + NL +
    Pad(1) + '"error": "' + EscapeJSON(ErrorMsg) + '"' + NL +
    '}';
end;

class function TJSONOutput.BuildEventError(const AEventType: string;
  const Args: TCompilerArgs; const AEvent: TBuildEventInfo): string;
var
  P1, P2: string;
begin
  P1 := Pad(1);
  P2 := Pad(2);
  Result := '{' + NL +
    P1 + '"status": "' + EscapeJSON(AEventType) + '_error",' + NL +
    P1 + '"version": "' + COMPILER_VERSION + '",' + NL +
    P1 + '"project": "' + EscapeJSON(TPath.GetFileName(Args.ProjectPathWin)) + '",' + NL +
    P1 + '"project_path": "' + EscapeJSON(TPathUtils.NormalizeForOutput(Args.ProjectPathWin)) + '",' + NL +
    P1 + '"config": "' + EscapeJSON(Args.ConfigStr) + '",' + NL +
    P1 + '"platform": "' + EscapeJSON(Args.PlatformStr) + '",' + NL +
    P1 + '"workspace_source": "' + EscapeJSON(CmxWsSourceToStr(Args.WorkspaceSource)) + '",' + NL +
    P1 + '"build_event": {' + NL +
    P2 + '"type": "' + EscapeJSON(AEventType) + '",' + NL +
    P2 + '"command": "' + EscapeJSON(AEvent.Command) + '",' + NL +
    P2 + '"exit_code": ' + IntToStr(AEvent.ExitCode) + ',' + NL +
    P2 + '"output": "' + EscapeJSON(AEvent.Output) + '"' + NL +
    P1 + '}' + NL +
    '}';
end;

end.
