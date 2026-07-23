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

    /// Generate JSON for invalid arguments
    class function Invalid(const ErrorMsg: string): string;

    /// Generate JSON for the --version query (tool identity, no compile)
    class function Version: string;

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
  Compilar.Config, Compilar.PathUtils;

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
begin
  Result := '{' + NL +
    Pad(1) + '"status": "invalid",' + NL +
    Pad(1) + '"version": "' + COMPILER_VERSION + '",' + NL +
    Pad(1) + '"error": "' + EscapeJSON(ErrorMsg) + '"' + NL +
    '}';
end;

class function TJSONOutput.Version: string;
begin
  Result := '{' + NL +
    Pad(1) + '"tool": "delphi-compiler",' + NL +
    Pad(1) + '"version": "' + COMPILER_VERSION + '"' + NL +
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
    P1 + '"build_event": {' + NL +
    P2 + '"type": "' + EscapeJSON(AEventType) + '",' + NL +
    P2 + '"command": "' + EscapeJSON(AEvent.Command) + '",' + NL +
    P2 + '"exit_code": ' + IntToStr(AEvent.ExitCode) + ',' + NL +
    P2 + '"output": "' + EscapeJSON(AEvent.Output) + '"' + NL +
    P1 + '}' + NL +
    '}';
end;

end.
