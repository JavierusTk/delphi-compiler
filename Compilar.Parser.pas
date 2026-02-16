unit Compilar.Parser;

interface

uses
  Compilar.Types;

type
  TOutputParser = class
  public
    /// Parse MSBuild output and extract compilation issues
    /// MaxErrors limits how many errors to extract (to avoid cascade errors)
    /// Truncated is set to True if there were more errors beyond MaxErrors
    /// TotalIssuesFound is the total count of all parseable issues in the output
    class function Parse(const Output: string; MaxErrors: Integer;
      out Truncated: Boolean; out TotalIssuesFound: Integer): TArray<TCompileIssue>;

  private
    class function ParseLine(const Line: string; out Issue: TCompileIssue): Boolean;
    class function ExtractIssueType(const TypeStr: string): TIssueType;
  end;

implementation

uses
  System.SysUtils, System.RegularExpressions, System.Classes,
  System.Generics.Collections, System.Generics.Defaults,
  Compilar.PathUtils;

const
  // Pattern for Delphi compiler messages:
  // C:\Path\File.pas(123,45): Error E2003: Undeclared identifier: 'Foo'
  // W:\Path\File.pas(123): Warning W1000: Symbol 'Bar' is deprecated
  // SynTest.dpr(5): error F1026: File not found: 'mormot.defines.inc' [W:\...\SynTest.dproj]
  // TestHint.dpr(6): Hint warning H2164: Variable 'UnusedVar' is declared but never used [...]
  // Supports: .pas, .dpr, .dpk, .inc files
  // Handles optional MSBuild project suffix: [path\to\project.dproj]
  // Note: Hints use "Hint warning" prefix, not just "Hint"
  // Order matters: "Hint warning" must come before "Hint" to match correctly
  COMPILER_MSG_PATTERN = '^(.+\.(?:pas|dpr|dpk|inc))\((\d+)(?:,(\d+))?\):\s*(Fatal|Error|Warning|Hint\s*warning|Hint)\s+([A-Z]\d+):\s*(.+?)(?:\s*\[.+\])?$';

class function TOutputParser.Parse(const Output: string; MaxErrors: Integer;
  out Truncated: Boolean; out TotalIssuesFound: Integer): TArray<TCompileIssue>;
var
  Lines: TStringList;
  I: Integer;
  Issue: TCompileIssue;
  IssueKey: string;
  ErrorCount: Integer;
  Issues: TList<TCompileIssue>;
  SeenIssues: TDictionary<string, Boolean>;
  Collecting: Boolean;
begin
  Issues := TList<TCompileIssue>.Create;
  Lines := TStringList.Create;
  SeenIssues := TDictionary<string, Boolean>.Create;
  try
    Lines.Text := Output;
    ErrorCount := 0;
    Truncated := False;
    TotalIssuesFound := 0;
    Collecting := True;

    for I := 0 to Lines.Count - 1 do
    begin
      // Trim: v:normal indents DCC output with spaces
      if ParseLine(Trim(Lines[I]), Issue) then
      begin
        // Deduplicate: v:normal emits each issue twice (DCC output + MSBuild reformatted)
        IssueKey := Issue.FilePath + ':' + IntToStr(Issue.Line) + ':' + Issue.Code;
        if SeenIssues.ContainsKey(IssueKey) then
          Continue;
        SeenIssues.Add(IssueKey, True);

        Inc(TotalIssuesFound);

        if Collecting then
        begin
          // Count errors and check limit
          if Issue.IssueType in [itError, itFatal] then
          begin
            Inc(ErrorCount);
            if ErrorCount > MaxErrors then
            begin
              Truncated := True;
              Collecting := False;
              Continue;  // Stop collecting but keep counting
            end;
          end;

          Issues.Add(Issue);
        end;
      end;
    end;

    Result := Issues.ToArray;
  finally
    SeenIssues.Free;
    Lines.Free;
    Issues.Free;
  end;
end;

class function TOutputParser.ParseLine(const Line: string; out Issue: TCompileIssue): Boolean;
var
  Match: TMatch;
  Regex: TRegEx;
begin
  Result := False;
  FillChar(Issue, SizeOf(Issue), 0);

  Regex := TRegEx.Create(COMPILER_MSG_PATTERN, [roIgnoreCase]);
  Match := Regex.Match(Line);

  if Match.Success then
  begin
    // Group 1: File path
    Issue.FilePath := TPathUtils.NormalizeForOutput(Match.Groups[1].Value);

    // Group 2: Line number
    Issue.Line := StrToIntDef(Match.Groups[2].Value, 0);

    // Group 3: Column number (optional)
    if Match.Groups[3].Success then
      Issue.Column := StrToIntDef(Match.Groups[3].Value, 0)
    else
      Issue.Column := 1;

    // Group 4: Issue type (Fatal, Error, Warning, Hint)
    Issue.IssueType := ExtractIssueType(Match.Groups[4].Value);

    // Group 5: Error code (E2003, W1000, etc.)
    Issue.Code := Match.Groups[5].Value;

    // Group 6: Message
    Issue.Message := Trim(Match.Groups[6].Value);

    // Initialize arrays
    SetLength(Issue.Context, 0);
    Issue.Lookup.Found := False;
    SetLength(Issue.Lookup.Results, 0);

    Result := True;
  end;
end;

class function TOutputParser.ExtractIssueType(const TypeStr: string): TIssueType;
var
  Upper: string;
begin
  Upper := UpperCase(TypeStr);
  if Upper = 'FATAL' then
    Result := itFatal
  else if Upper = 'ERROR' then
    Result := itError
  else if Upper = 'WARNING' then
    Result := itWarning
  else if (Upper = 'HINT') or (Upper = 'HINT WARNING') then
    Result := itHint
  else
    Result := itError;
end;

end.
