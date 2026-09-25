unit Compilar.Parser;

interface

uses
  System.Generics.Collections,
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
    class procedure AddContinuation(Issues: TList<TCompileIssue>; Index: Integer;
      const Msg: string);
  end;

implementation

uses
  System.SysUtils, System.RegularExpressions, System.Classes,
  System.Generics.Defaults,
  Compilar.PathUtils;

const
  // Pattern for Delphi compiler messages:
  // C:\Path\File.pas(123,45): Error E2003: Undeclared identifier: 'Foo'
  // W:\Path\File.pas(123): Warning W1000: Symbol 'Bar' is deprecated
  // SynTest.dpr(5): error F1026: File not found: 'mormot.defines.inc' [W:\...\SynTest.dproj]
  // TestHint.dpr(6): Hint warning H2164: Variable 'UnusedVar' is declared but never used [...]
  // CodeGear.Delphi.Targets(427,5): error E2202: Required package 'rbProMAX' not found [...]
  // Supports any file extension (the error code pattern is specific enough)
  // Handles optional MSBuild project suffix: [path\to\project.dproj]
  // Note: Hints use "Hint warning" prefix, not just "Hint"
  // Order matters: "Hint warning" must come before "Hint" to match correctly
  COMPILER_MSG_PATTERN = '^(.+\.\w+)\((\d+)(?:,(\d+))?\):\s*(Fatal|Error|Warning|Hint\s*warning|Hint)\s+([A-Z]\d+):\s*(.+?)(?:\s*\[.+\])?$';

  // MSBuild-level errors (v1.14): a build TASK failed, not dcc, so the build
  // can stop with no dcc message at all (T-4Y7N: BRCC32 with an unusable %TEMP%):
  // c:\...\CodeGear.Common.Targets(1276,5): error MSB4018: The "BRCC32" task failed unexpectedly. [...]
  // MSBUILD : error MSB1009: Project file does not exist.
  // A multi-line error repeats origin and code on every line (exception text,
  // stack trace); those continuation lines become the issue's context.
  MSBUILD_ERROR_PATTERN = '^(?:(.+?)\((\d+)(?:,(\d+))?\)|MSBUILD)\s*:\s*error\s+(MSB\d+)\s*:\s*(.*?)(?:\s*\[[^\]]+\])?$';
  MSBUILD_CONTINUATION_MAX = 4;

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
  OpenKey: string;      // multi-line MSBuild error whose continuation lines are being kept
  OpenIndex: Integer;
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
    OpenKey := '';
    OpenIndex := -1;

    for I := 0 to Lines.Count - 1 do
    begin
      // Trim: v:normal indents DCC output with spaces
      if ParseLine(Trim(Lines[I]), Issue) then
      begin
        // Deduplicate: v:normal emits each issue twice (DCC output + MSBuild reformatted)
        IssueKey := Issue.FilePath + ':' + IntToStr(Issue.Line) + ':' + Issue.Code;
        if SeenIssues.ContainsKey(IssueKey) then
        begin
          // Consecutive repeats of the error just added are its continuation
          // lines; the repeat in the closing summary is not (OpenKey was
          // closed by the lines in between).
          if IssueKey = OpenKey then
            AddContinuation(Issues, OpenIndex, Issue.Message)
          else
            OpenKey := '';
          Continue;
        end;
        SeenIssues.Add(IssueKey, True);
        OpenKey := '';

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
          if IsMSBuildCode(Issue.Code) then
          begin
            OpenKey := IssueKey;
            OpenIndex := Issues.Count - 1;
          end;
        end;
      end
      else
        OpenKey := '';
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

    Exit(True);
  end;

  Match := TRegEx.Match(Line, MSBUILD_ERROR_PATTERN, [roIgnoreCase]);
  if Match.Success then
  begin
    // Groups 1-3: origin file(line[,column]); absent in "MSBUILD : error ..."
    if Match.Groups[1].Success and (Match.Groups[1].Value <> '') then
    begin
      Issue.FilePath := TPathUtils.NormalizeForOutput(Match.Groups[1].Value);
      Issue.Line := StrToIntDef(Match.Groups[2].Value, 0);
      if Match.Groups[3].Success then
        Issue.Column := StrToIntDef(Match.Groups[3].Value, 0)
      else
        Issue.Column := 1;
    end;
    Issue.IssueType := itError;
    Issue.Code := UpperCase(Match.Groups[4].Value);
    Issue.Message := Trim(Match.Groups[5].Value);
    SetLength(Issue.Context, 0);
    Result := True;
  end;
end;

class procedure TOutputParser.AddContinuation(Issues: TList<TCompileIssue>;
  Index: Integer; const Msg: string);
var
  Item: TCompileIssue;
begin
  if (Msg = '') or (Index < 0) or (Index >= Issues.Count) then
    Exit;
  Item := Issues[Index];
  if Length(Item.Context) >= MSBUILD_CONTINUATION_MAX then
    Exit;
  Item.Context := Item.Context + [Msg];
  Issues[Index] := Item;
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
