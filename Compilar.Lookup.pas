unit Compilar.Lookup;

interface

uses
  Compilar.Types;

type
  TLookupEnricher = class
  public
    /// Add lookup results for undeclared identifiers (E2003) and missing files (F1026)
    class procedure AddLookup(var Issues: TArray<TCompileIssue>);

  private
    class function IsUndeclaredIdentifier(const Issue: TCompileIssue): Boolean;
    class function IsFileNotFound(const Issue: TCompileIssue): Boolean;
    class function ExtractQuotedName(const Message: string): string;
    class function RunDelphiLookup(const Symbol: string): TLookupResult;
    class function SearchFileIndex(const FileName: string): TLookupResult;
    class function ParseLookupOutput(const Output, Symbol: string): TLookupResult;
  end;

implementation

uses
  System.SysUtils, System.RegularExpressions, System.Classes,
  System.Generics.Collections,
  Winapi.Windows,
  Compilar.PathUtils,
  Compilar.Config;

const
  LOOKUP_TIMEOUT_MS = 5000; // 5 seconds per symbol

class procedure TLookupEnricher.AddLookup(var Issues: TArray<TCompileIssue>);
var
  I: Integer;
  Name: string;
begin
  for I := 0 to High(Issues) do
  begin
    if IsUndeclaredIdentifier(Issues[I]) then
    begin
      Name := ExtractQuotedName(Issues[I].Message);
      if Name <> '' then
        Issues[I].Lookup := RunDelphiLookup(Name);
    end
    else if IsFileNotFound(Issues[I]) then
    begin
      Name := ExtractQuotedName(Issues[I].Message);
      if Name <> '' then
        Issues[I].Lookup := SearchFileIndex(Name);
    end;
  end;
end;

class function TLookupEnricher.IsUndeclaredIdentifier(const Issue: TCompileIssue): Boolean;
begin
  // E2003: Undeclared identifier: 'X'
  Result := (Issue.Code = 'E2003') and
            (Pos('Undeclared identifier', Issue.Message) > 0);
end;

class function TLookupEnricher.IsFileNotFound(const Issue: TCompileIssue): Boolean;
begin
  // F1026: File not found: 'UnitName.pas'
  Result := (Issue.Code = 'F1026') and
            (Pos('File not found', Issue.Message) > 0);
end;

class function TLookupEnricher.ExtractQuotedName(const Message: string): string;
var
  Match: TMatch;
  Regex: TRegEx;
begin
  Result := '';

  // Pattern: 'SomeName' (single-quoted identifier or filename)
  Regex := TRegEx.Create('''([^'']+)''');
  Match := Regex.Match(Message);

  if Match.Success then
    Result := Match.Groups[1].Value;
end;

class function TLookupEnricher.SearchFileIndex(const FileName: string): TLookupResult;
var
  Lines: TStringList;
  I: Integer;
  Line: string;
  SearchName: string;
  Entry: TLookupEntry;
  ResultList: TList<TLookupEntry>;
  IndexPath: string;
begin
  Result.Found := False;
  Result.Symbol := FileName;
  SetLength(Result.Results, 0);
  Result.Hint := '';

  IndexPath := Config.FileIndexPath;
  if IndexPath = '' then
  begin
    Result.Hint := 'File index not configured';
    Exit;
  end;

  if not FileExists(IndexPath) then
  begin
    Result.Hint := 'File index not found at ' + IndexPath;
    Exit;
  end;

  // Search for the filename in the file index
  SearchName := LowerCase(FileName);
  ResultList := TList<TLookupEntry>.Create;
  Lines := TStringList.Create;
  try
    try
      Lines.LoadFromFile(IndexPath);
    except
      Result.Hint := 'Could not read file index';
      Exit;
    end;

    for I := 0 to Lines.Count - 1 do
    begin
      Line := Lines[I];
      // file-index.txt contains full paths, one per line
      if LowerCase(ExtractFileName(Trim(Line))).Contains(SearchName) then
      begin
        Entry.Path := TPathUtils.NormalizeForOutput(Trim(Line));
        Entry.UnitName := ChangeFileExt(ExtractFileName(Trim(Line)), '');
        Entry.SymbolType := 'file';
        Entry.Line := 0;
        ResultList.Add(Entry);

        if ResultList.Count >= 3 then
          Break;
      end;
    end;

    if ResultList.Count > 0 then
    begin
      Result.Found := True;
      Result.Results := ResultList.ToArray;
    end
    else
    begin
      Result.Hint := 'File not in index. Check search paths or file existence.';
    end;
  finally
    Lines.Free;
    ResultList.Free;
  end;
end;

class function TLookupEnricher.RunDelphiLookup(const Symbol: string): TLookupResult;
var
  SA: TSecurityAttributes;
  SI: TStartupInfo;
  PI: TProcessInformation;
  hReadPipe, hWritePipe: THandle;
  Buffer: array[0..4095] of AnsiChar;
  BytesRead: DWORD;
  Output: TStringBuilder;
  WaitResult: DWORD;
  CommandLine: string;
  ExitCode: DWORD;
  LookupExe: string;
begin
  Result.Found := False;
  Result.Symbol := Symbol;
  SetLength(Result.Results, 0);
  Result.Hint := '';

  LookupExe := Config.LookupPath;
  if LookupExe = '' then
  begin
    Result.Hint := 'delphi-lookup.exe not configured';
    Exit;
  end;

  if not FileExists(LookupExe) then
  begin
    Result.Hint := 'delphi-lookup.exe not found at ' + LookupExe;
    Exit;
  end;

  // Build command line: delphi-lookup.exe "Symbol" -n 3
  CommandLine := Format('"%s" "%s" -n 3', [LookupExe, Symbol]);

  // Set up security attributes for pipe inheritance
  FillChar(SA, SizeOf(SA), 0);
  SA.nLength := SizeOf(SA);
  SA.bInheritHandle := True;

  // Create pipe for stdout
  if not CreatePipe(hReadPipe, hWritePipe, @SA, 0) then
  begin
    Result.Hint := 'Failed to create pipe for delphi-lookup';
    Exit;
  end;

  try
    SetHandleInformation(hReadPipe, HANDLE_FLAG_INHERIT, 0);

    FillChar(SI, SizeOf(SI), 0);
    SI.cb := SizeOf(SI);
    SI.dwFlags := STARTF_USESHOWWINDOW or STARTF_USESTDHANDLES;
    SI.wShowWindow := SW_HIDE;
    SI.hStdOutput := hWritePipe;
    SI.hStdError := hWritePipe;

    FillChar(PI, SizeOf(PI), 0);

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
    begin
      Result.Hint := 'Failed to start delphi-lookup';
      Exit;
    end;

    try
      CloseHandle(hWritePipe);
      hWritePipe := 0;

      Output := TStringBuilder.Create;
      try
        repeat
          FillChar(Buffer, SizeOf(Buffer), 0);
          if ReadFile(hReadPipe, Buffer, SizeOf(Buffer) - 1, BytesRead, nil) and (BytesRead > 0) then
            Output.Append(string(AnsiString(Buffer)));
        until BytesRead = 0;

        WaitResult := WaitForSingleObject(PI.hProcess, LOOKUP_TIMEOUT_MS);
        if WaitResult = WAIT_TIMEOUT then
        begin
          TerminateProcess(PI.hProcess, 1);
          Result.Hint := 'delphi-lookup timed out';
          Exit;
        end;

        GetExitCodeProcess(PI.hProcess, ExitCode);
        Result := ParseLookupOutput(Output.ToString, Symbol);
      finally
        Output.Free;
      end;
    finally
      CloseHandle(PI.hProcess);
      CloseHandle(PI.hThread);
    end;
  finally
    if hReadPipe <> 0 then CloseHandle(hReadPipe);
    if hWritePipe <> 0 then CloseHandle(hWritePipe);
  end;
end;

class function TLookupEnricher.ParseLookupOutput(const Output, Symbol: string): TLookupResult;
var
  Lines: TStringList;
  I: Integer;
  Line, NextLine: string;
  Entry: TLookupEntry;
  ResultList: TList<TLookupEntry>;
  TypeMatch, FileMatch: TMatch;
begin
  Result.Found := False;
  Result.Symbol := Symbol;
  SetLength(Result.Results, 0);
  Result.Hint := '';

  if Trim(Output) = '' then
  begin
    Result.Hint := 'Symbol not in index. May be new, misspelled, or in non-indexed folder.';
    Exit;
  end;

  // Check for "No results found" message
  if Pos('No results found', Output) > 0 then
  begin
    Result.Hint := 'Symbol not in index. May be new, misspelled, or in non-indexed folder.';
    Exit;
  end;

  ResultList := TList<TLookupEntry>.Create;
  Lines := TStringList.Create;
  try
    Lines.Text := Output;

    // Parse delphi-lookup output format:
    // // Result 1 (Exact Match - USER CODE): ModoDesarrollo (function)
    // // File: TableMax.pas

    for I := 0 to Lines.Count - 2 do  // -2 because we look ahead
    begin
      Line := Lines[I];

      // Look for "// Result N" lines
      if Pos('// Result ', Line) > 0 then
      begin
        Entry.Path := '';
        Entry.Line := 0;
        Entry.SymbolType := 'unknown';
        Entry.UnitName := '';

        // Extract type from parentheses at end: (function), (procedure), etc.
        TypeMatch := TRegEx.Match(Line, '\((\w+)\)\s*$');
        if TypeMatch.Success then
          Entry.SymbolType := LowerCase(TypeMatch.Groups[1].Value);

        // Look for "// File: xxx.pas" in next few lines
        if I + 1 < Lines.Count then
        begin
          NextLine := Lines[I + 1];
          FileMatch := TRegEx.Match(NextLine, '//\s*File:\s*([A-Za-z0-9_.\-]+\.pas)', [roIgnoreCase]);
          if FileMatch.Success then
          begin
            Entry.Path := FileMatch.Groups[1].Value;
            Entry.UnitName := ChangeFileExt(Entry.Path, '');
          end;
        end;

        // Only add if we found a file
        if Entry.UnitName <> '' then
        begin
          ResultList.Add(Entry);
          if ResultList.Count >= 3 then
            Break;
        end;
      end;
    end;

    if ResultList.Count > 0 then
    begin
      Result.Found := True;
      Result.Results := ResultList.ToArray;
    end
    else
    begin
      Result.Hint := 'Symbol not in index. May be new, misspelled, or in non-indexed folder.';
    end;
  finally
    Lines.Free;
    ResultList.Free;
  end;
end;

end.
