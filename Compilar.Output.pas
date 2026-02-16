unit Compilar.Output;

interface

uses
  Compilar.Types;

type
  TJSONOutput = class
  public
    /// Generate pretty-printed JSON for successful/error compilation result
    class function Generate(const AResult: TCompileResult): string;

    /// Generate JSON for invalid arguments
    class function Invalid(const ErrorMsg: string): string;

    /// Generate JSON for internal error
    class function InternalError(const ErrorMsg: string): string;

  private
    class function EscapeJSON(const S: string): string;
    class function IssueToJSON(const Issue: TCompileIssue; Indent: Integer): string;
    class function LookupToJSON(const Lookup: TLookupResult; Indent: Integer): string;
    class function StringArrayToJSON(const Arr: TArray<string>; Indent: Integer): string;
    class function Pad(Level: Integer): string;
  end;

implementation

uses
  System.SysUtils, System.Classes,
  Compilar.Config;

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
        if (Ord(C) < 32) then
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

class function TJSONOutput.LookupToJSON(const Lookup: TLookupResult; Indent: Integer): string;
var
  SB: TStringBuilder;
  I: Integer;
  Entry: TLookupEntry;
  P, P1, P2: string;
begin
  P := Pad(Indent);
  P1 := Pad(Indent + 1);
  P2 := Pad(Indent + 2);

  SB := TStringBuilder.Create;
  try
    SB.Append('{').Append(NL);
    SB.Append(P1).Append('"found": ').Append(BoolToStr(Lookup.Found, True).ToLower);

    SB.Append(',').Append(NL);
    SB.Append(P1).Append('"symbol": "').Append(EscapeJSON(Lookup.Symbol)).Append('"');

    if Lookup.Found and (Length(Lookup.Results) > 0) then
    begin
      SB.Append(',').Append(NL);
      SB.Append(P1).Append('"results": [').Append(NL);
      for I := 0 to High(Lookup.Results) do
      begin
        Entry := Lookup.Results[I];
        SB.Append(P2).Append('{').Append(NL);
        SB.Append(Pad(Indent + 3)).Append('"unit": "').Append(EscapeJSON(Entry.UnitName)).Append('",').Append(NL);
        SB.Append(Pad(Indent + 3)).Append('"path": "').Append(EscapeJSON(Entry.Path)).Append('",').Append(NL);
        SB.Append(Pad(Indent + 3)).Append('"type": "').Append(EscapeJSON(Entry.SymbolType)).Append('",').Append(NL);
        SB.Append(Pad(Indent + 3)).Append('"line": ').Append(IntToStr(Entry.Line)).Append(NL);
        SB.Append(P2).Append('}');
        if I < High(Lookup.Results) then
          SB.Append(',');
        SB.Append(NL);
      end;
      SB.Append(P1).Append(']');
    end
    else if Lookup.Hint <> '' then
    begin
      SB.Append(',').Append(NL);
      SB.Append(P1).Append('"hint": "').Append(EscapeJSON(Lookup.Hint)).Append('"');
    end;

    SB.Append(NL);
    SB.Append(P).Append('}');
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

    // Add lookup if it was performed
    if Issue.Lookup.Symbol <> '' then
    begin
      SB.Append(',').Append(NL);
      SB.Append(P1).Append('"lookup": ').Append(LookupToJSON(Issue.Lookup, Indent + 1));
    end;

    SB.Append(NL);
    SB.Append(P).Append('}');
    Result := SB.ToString;
  finally
    SB.Free;
  end;
end;

class function TJSONOutput.Generate(const AResult: TCompileResult): string;
var
  SB: TStringBuilder;
  I: Integer;
  P1, P2: string;
begin
  P1 := Pad(1);
  P2 := Pad(2);

  SB := TStringBuilder.Create;
  try
    SB.Append('{').Append(NL);

    SB.Append(P1).Append('"status": "').Append(EscapeJSON(AResult.Status)).Append('",').Append(NL);
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
        SB.Append(P1).Append('"output_message": "Output file was NOT updated (likely locked by another process). The existing file is from a previous build. Release the lock and recompile.",').Append(NL);
      end;
    end;

    // Config warnings (if any)
    if Length(Config.Warnings) > 0 then
    begin
      SB.Append(P1).Append('"config_warnings": ').Append(StringArrayToJSON(Config.Warnings, 1)).Append(',').Append(NL);
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

    // Issues array (always present, may be empty)
    SB.Append(P1).Append('"issues": ');
    if Length(AResult.Issues) = 0 then
    begin
      SB.Append('[]').Append(NL);
    end
    else
    begin
      SB.Append('[').Append(NL);
      for I := 0 to High(AResult.Issues) do
      begin
        SB.Append(P2).Append(IssueToJSON(AResult.Issues[I], 2));
        if I < High(AResult.Issues) then
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
    Pad(1) + '"error": "' + EscapeJSON(ErrorMsg) + '"' + NL +
    '}';
end;

class function TJSONOutput.InternalError(const ErrorMsg: string): string;
begin
  Result := '{' + NL +
    Pad(1) + '"status": "internal_error",' + NL +
    Pad(1) + '"error": "' + EscapeJSON(ErrorMsg) + '"' + NL +
    '}';
end;

end.
