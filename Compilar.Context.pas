unit Compilar.Context;

interface

uses
  System.SysUtils,
  Compilar.Types;

type
  TContextEnricher = class
  public
    /// Add source code context to each issue
    /// ContextLines specifies how many lines before and after the error line
    class procedure AddSourceContext(var Issues: TArray<TCompileIssue>; ContextLines: Integer);

  private
    class function ReadSourceLines(const FilePath: string;
      CenterLine, ContextLines: Integer): TArray<string>;
    class function DetectFileEncoding(const FilePath: string): TEncoding;
  end;

implementation

uses
  System.IOUtils, System.Classes, System.Generics.Collections,
  Compilar.PathUtils;

class procedure TContextEnricher.AddSourceContext(var Issues: TArray<TCompileIssue>;
  ContextLines: Integer);
var
  I: Integer;
  WinPath: string;
begin
  for I := 0 to High(Issues) do
  begin
    if Issues[I].FilePath <> '' then
    begin
      // Convert to Windows path for file reading
      WinPath := TPathUtils.NormalizeToWindows(Issues[I].FilePath);

      if FileExists(WinPath) then
        Issues[I].Context := ReadSourceLines(WinPath, Issues[I].Line, ContextLines);
    end;
  end;
end;

class function TContextEnricher.DetectFileEncoding(const FilePath: string): TEncoding;
var
  FS: TFileStream;
  BOM: array[0..2] of Byte;
  BytesRead: Integer;
  Bytes: TBytes;
  Text: string;
begin
  FS := TFileStream.Create(FilePath, fmOpenRead or fmShareDenyNone);
  try
    BytesRead := FS.Read(BOM, 3);

    if BytesRead >= 3 then
    begin
      // UTF-8 BOM: EF BB BF
      if (BOM[0] = $EF) and (BOM[1] = $BB) and (BOM[2] = $BF) then
        Exit(TEncoding.UTF8);
    end;

    if BytesRead >= 2 then
    begin
      // UTF-16 LE BOM: FF FE
      if (BOM[0] = $FF) and (BOM[1] = $FE) then
        Exit(TEncoding.Unicode);

      // UTF-16 BE BOM: FE FF
      if (BOM[0] = $FE) and (BOM[1] = $FF) then
        Exit(TEncoding.BigEndianUnicode);
    end;

    // No BOM: try UTF-8 first, fall back to ANSI if replacement chars found
    FS.Position := 0;
    SetLength(Bytes, FS.Size);
    if FS.Size > 0 then
    begin
      FS.ReadBuffer(Bytes[0], FS.Size);
      Text := TEncoding.UTF8.GetString(Bytes);
      if Pos(#$FFFD, Text) > 0 then
        Exit(TEncoding.ANSI);
      Exit(TEncoding.UTF8);
    end;
  finally
    FS.Free;
  end;

  Result := TEncoding.ANSI;
end;

class function TContextEnricher.ReadSourceLines(const FilePath: string;
  CenterLine, ContextLines: Integer): TArray<string>;
var
  Lines: TStringList;
  StartLine, EndLine: Integer;
  I: Integer;
  ResultList: TList<string>;
  LineNum: Integer;
  LineText: string;
  Marker: string;
  Encoding: TEncoding;
begin
  SetLength(Result, 0);
  ResultList := TList<string>.Create;
  Lines := TStringList.Create;
  try
    // Detect encoding and load file
    Encoding := DetectFileEncoding(FilePath);
    Lines.LoadFromFile(FilePath, Encoding);

    // Calculate range (1-indexed in source, 0-indexed in TStringList)
    StartLine := CenterLine - ContextLines;
    EndLine := CenterLine + ContextLines;

    if StartLine < 1 then StartLine := 1;
    if EndLine > Lines.Count then EndLine := Lines.Count;

    // Extract lines with line numbers
    for I := StartLine to EndLine do
    begin
      LineNum := I;
      LineText := Lines[I - 1]; // TStringList is 0-indexed

      // Mark the error line
      if I = CenterLine then
        Marker := '  // <-- HERE'
      else
        Marker := '';

      // Format: "  45:     if ModoDesarrollo then  // <-- HERE"
      ResultList.Add(Format('%4d: %s%s', [LineNum, LineText, Marker]));
    end;

    Result := ResultList.ToArray;
  finally
    Lines.Free;
    ResultList.Free;
  end;
end;

end.
