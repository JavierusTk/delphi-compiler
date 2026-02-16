unit Compilar.Config;

interface

type
  TCompilerConfig = record
    RsVarsPath: string;
    LookupPath: string;
    FileIndexPath: string;
    EnvironmentProjPath: string;
    WSLMode: Boolean;
    Warnings: TArray<string>;
  end;

/// Initialize config from .env file, environment variables, and auto-detection.
/// ProjectPathWin is needed to derive the drive root for FILE_INDEX_PATH auto-detection.
/// WSLFromCLI overrides any WSL setting from config/env.
procedure InitConfig(const ProjectPathWin: string; WSLFromCLI: Boolean);

/// Returns the current config (call after InitConfig)
function Config: TCompilerConfig;

/// Resolve MSBuild-style $(VarName) variables using values from environment.proj.
/// Actual Windows environment variables take precedence over environment.proj values.
function ResolveEnvProjVars(const Value: string): string;

/// Returns MSBuild /p: properties for environment.proj variables
/// not already present as Windows environment variables.
function GetMSBuildEnvProperties: string;

implementation

uses
  System.SysUtils, System.IOUtils, System.Classes,
  System.RegularExpressions, System.Win.Registry, Winapi.Windows;

// ---------------------------------------------------------------------------
// .env file parsing
// ---------------------------------------------------------------------------

type
  TEnvPair = record
    Key: string;
    Value: string;
  end;

var
  GConfig: TCompilerConfig;
  GConfigInitialized: Boolean;
  GEnvProjVars: TArray<TEnvPair>;

function Config: TCompilerConfig;
begin
  Result := GConfig;
end;

function ParseEnvFile(const FilePath: string): TArray<TEnvPair>;
var
  Lines: TStringList;
  I: Integer;
  Line, K, V: string;
  EqPos: Integer;
  List: TArray<TEnvPair>;
  Count: Integer;
begin
  SetLength(Result, 0);
  if not FileExists(FilePath) then
    Exit;

  Lines := TStringList.Create;
  try
    try
      Lines.LoadFromFile(FilePath, TEncoding.UTF8);
    except
      Exit;
    end;

    Count := 0;
    SetLength(List, Lines.Count);

    for I := 0 to Lines.Count - 1 do
    begin
      Line := Trim(Lines[I]);
      if (Line = '') or Line.StartsWith('#') then
        Continue;

      EqPos := Pos('=', Line);
      if EqPos < 2 then
        Continue;

      K := Trim(Copy(Line, 1, EqPos - 1));
      V := Trim(Copy(Line, EqPos + 1, MaxInt));

      // Strip optional surrounding quotes
      if (Length(V) >= 2) and ((V[1] = '"') or (V[1] = '''')) and (V[Length(V)] = V[1]) then
        V := Copy(V, 2, Length(V) - 2);

      List[Count].Key := UpperCase(K);
      List[Count].Value := V;
      Inc(Count);
    end;

    SetLength(List, Count);
    Result := List;
  finally
    Lines.Free;
  end;
end;

function FindEnvValue(const Pairs: TArray<TEnvPair>; const Key: string): string;
var
  I: Integer;
  UK: string;
begin
  Result := '';
  UK := UpperCase(Key);
  for I := 0 to High(Pairs) do
    if Pairs[I].Key = UK then
      Exit(Pairs[I].Value);
end;

// ---------------------------------------------------------------------------
// Resolve a setting: environment variable > .env file > empty
// ---------------------------------------------------------------------------

function ResolveValue(const Key: string; const EnvPairs: TArray<TEnvPair>): string;
var
  EnvVal: string;
begin
  // 1. Environment variable
  EnvVal := GetEnvironmentVariable(Key);
  if EnvVal <> '' then
    Exit(EnvVal);

  // 2. .env file
  Result := FindEnvValue(EnvPairs, Key);
end;

// ---------------------------------------------------------------------------
// Registry auto-detection for RAD Studio rsvars.bat
// ---------------------------------------------------------------------------

function AutoDetectRsVars(out ErrorMsg: string): string;
var
  Reg: TRegistry;
  SubKeys: TStringList;
  I: Integer;
  RootDirStr, Candidate: string;
  Matches: TArray<string>;
  MatchCount: Integer;
begin
  Result := '';
  ErrorMsg := '';
  MatchCount := 0;
  SetLength(Matches, 0);

  Reg := TRegistry.Create(KEY_READ);
  try
    Reg.RootKey := HKEY_CURRENT_USER;

    if not Reg.OpenKeyReadOnly('SOFTWARE\Embarcadero\BDS') then
    begin
      ErrorMsg := 'RAD Studio not found in registry (HKCU\SOFTWARE\Embarcadero\BDS). Set RSVARS_PATH in delphi-compiler.env';
      Exit;
    end;

    SubKeys := TStringList.Create;
    try
      Reg.GetKeyNames(SubKeys);
      Reg.CloseKey;

      for I := 0 to SubKeys.Count - 1 do
      begin
        if Reg.OpenKeyReadOnly('SOFTWARE\Embarcadero\BDS\' + SubKeys[I]) then
        begin
          try
            if Reg.ValueExists('RootDir') then
            begin
              RootDirStr := Reg.ReadString('RootDir');
              Candidate := IncludeTrailingPathDelimiter(RootDirStr) + 'bin\rsvars.bat';
              if FileExists(Candidate) then
              begin
                Inc(MatchCount);
                SetLength(Matches, MatchCount);
                Matches[MatchCount - 1] := Candidate;
              end;
            end;
          finally
            Reg.CloseKey;
          end;
        end;
      end;
    finally
      SubKeys.Free;
    end;
  finally
    Reg.Free;
  end;

  if MatchCount = 0 then
  begin
    ErrorMsg := 'No RAD Studio installation found with rsvars.bat. Set RSVARS_PATH in delphi-compiler.env';
  end
  else if MatchCount = 1 then
  begin
    Result := Matches[0];
  end
  else
  begin
    ErrorMsg := 'Multiple RAD Studio installations found (' + IntToStr(MatchCount) +
      '). Set RSVARS_PATH in delphi-compiler.env to select one:';
    for I := 0 to High(Matches) do
      ErrorMsg := ErrorMsg + sLineBreak + '  ' + Matches[I];
  end;
end;

// ---------------------------------------------------------------------------
// Auto-detection for delphi-lookup.exe (same dir as compiler exe)
// ---------------------------------------------------------------------------

function AutoDetectLookupPath: string;
var
  ExeDir, Candidate: string;
begin
  Result := '';
  ExeDir := ExtractFilePath(ParamStr(0));
  Candidate := IncludeTrailingPathDelimiter(ExeDir) + 'delphi-lookup.exe';
  if FileExists(Candidate) then
    Result := Candidate;
end;

// ---------------------------------------------------------------------------
// Auto-detection for .file-index.txt (drive root of project)
// ---------------------------------------------------------------------------

function AutoDetectFileIndexPath(const ProjectPathWin: string): string;
var
  DriveRoot, Candidate: string;
begin
  Result := '';
  if Length(ProjectPathWin) < 3 then
    Exit;

  // Extract drive root: "W:\..." -> "W:\"
  DriveRoot := Copy(ProjectPathWin, 1, 3);
  Candidate := DriveRoot + '.public\.file-index.txt';
  if FileExists(Candidate) then
    Result := Candidate;
end;

// ---------------------------------------------------------------------------
// AddWarning helper
// ---------------------------------------------------------------------------

procedure AddWarning(var Cfg: TCompilerConfig; const Msg: string);
begin
  SetLength(Cfg.Warnings, Length(Cfg.Warnings) + 1);
  Cfg.Warnings[High(Cfg.Warnings)] := Msg;
end;

// ---------------------------------------------------------------------------
// environment.proj parsing (MSBuild IDE variables)
// ---------------------------------------------------------------------------

function FindEnvironmentProjPath(const RsVarsPath: string): string;
var
  Match: TMatch;
  Version, AppData: string;
begin
  Result := '';

  // Extract BDS version from rsvars.bat path: ...\studio\23.0\bin\rsvars.bat
  Match := TRegEx.Match(RsVarsPath, '(\d+\.\d+)\\bin\\rsvars\.bat$', [roIgnoreCase]);
  if not Match.Success then
    Exit;
  Version := Match.Groups[1].Value;

  AppData := GetEnvironmentVariable('APPDATA');
  if AppData = '' then
    Exit;

  Result := IncludeTrailingPathDelimiter(AppData) +
    'Embarcadero\BDS\' + Version + '\environment.proj';
  if not FileExists(Result) then
    Result := '';
end;

function ParseEnvironmentProj(const FilePath: string): TArray<TEnvPair>;
var
  Content, PropContent: string;
  PropMatch: TMatch;
  Matches: TMatchCollection;
  M: TMatch;
  I, Count: Integer;
begin
  SetLength(Result, 0);
  if not FileExists(FilePath) then
    Exit;

  try
    Content := TFile.ReadAllText(FilePath, TEncoding.UTF8);
  except
    Exit;
  end;

  // Extract PropertyGroup content
  PropMatch := TRegEx.Match(Content,
    '<PropertyGroup>(.*?)</PropertyGroup>', [roSingleLine]);
  if not PropMatch.Success then
    Exit;
  PropContent := PropMatch.Groups[1].Value;

  // Match property definitions: <VARNAME Condition="...">VALUE</VARNAME>
  // Also matches entries without Condition attribute
  Matches := TRegEx.Matches(PropContent, '<(\w+)\b[^>]*>([^<]+)</\1>');
  SetLength(Result, Matches.Count);
  Count := 0;
  for I := 0 to Matches.Count - 1 do
  begin
    M := Matches[I];
    Result[Count].Key := UpperCase(M.Groups[1].Value);
    Result[Count].Value := M.Groups[2].Value;
    Inc(Count);
  end;
  SetLength(Result, Count);
end;

function ResolveEnvProjVars(const Value: string): string;
var
  I: Integer;
  VarPattern, EnvValue: string;
begin
  Result := Value;
  if Pos('$(', Result) = 0 then
    Exit;

  for I := 0 to High(GEnvProjVars) do
  begin
    VarPattern := '$(' + GEnvProjVars[I].Key + ')';
    // Case-insensitive check
    if Pos(VarPattern, UpperCase(Result)) > 0 then
    begin
      // Actual environment variable takes precedence (mirrors MSBuild Condition behavior)
      EnvValue := GetEnvironmentVariable(GEnvProjVars[I].Key);
      if EnvValue = '' then
        EnvValue := GEnvProjVars[I].Value;
      Result := StringReplace(Result, '$(' + GEnvProjVars[I].Key + ')',
        EnvValue, [rfReplaceAll, rfIgnoreCase]);
    end;
  end;
end;

function GetMSBuildEnvProperties: string;
var
  I: Integer;
  Key, Value: string;
  SB: TStringBuilder;
begin
  Result := '';
  if Length(GEnvProjVars) = 0 then
    Exit;

  SB := TStringBuilder.Create;
  try
    for I := 0 to High(GEnvProjVars) do
    begin
      Key := GEnvProjVars[I].Key;
      // Skip variables already in the Windows environment (PATH, TEMP, APPDATA, etc.)
      if GetEnvironmentVariable(Key) <> '' then
        Continue;
      Value := GEnvProjVars[I].Value;
      if Pos(' ', Value) > 0 then
        SB.AppendFormat('/p:%s="%s" ', [Key, Value])
      else
        SB.AppendFormat('/p:%s=%s ', [Key, Value]);
    end;
    Result := SB.ToString.TrimRight;
  finally
    SB.Free;
  end;
end;

// ---------------------------------------------------------------------------
// InitConfig
// ---------------------------------------------------------------------------

procedure InitConfig(const ProjectPathWin: string; WSLFromCLI: Boolean);
var
  EnvFilePath: string;
  EnvPairs: TArray<TEnvPair>;
  Val: string;
  AutoError: string;
begin
  GConfig := Default(TCompilerConfig);

  // Parse .env file next to the exe
  EnvFilePath := ExtractFilePath(ParamStr(0)) + 'delphi-compiler.env';
  EnvPairs := ParseEnvFile(EnvFilePath);

  // --- RSVARS_PATH ---
  Val := ResolveValue('RSVARS_PATH', EnvPairs);
  if Val <> '' then
  begin
    if FileExists(Val) then
      GConfig.RsVarsPath := Val
    else
      raise Exception.Create('RSVARS_PATH points to non-existent file: ' + Val);
  end
  else
  begin
    // Auto-detect from registry
    GConfig.RsVarsPath := AutoDetectRsVars(AutoError);
    if GConfig.RsVarsPath = '' then
      raise Exception.Create(AutoError);
  end;

  // --- DELPHI_LOOKUP_PATH ---
  Val := ResolveValue('DELPHI_LOOKUP_PATH', EnvPairs);
  if Val <> '' then
  begin
    if FileExists(Val) then
      GConfig.LookupPath := Val
    else
      AddWarning(GConfig, 'DELPHI_LOOKUP_PATH not found: ' + Val);
  end
  else
    GConfig.LookupPath := AutoDetectLookupPath;

  // --- FILE_INDEX_PATH ---
  Val := ResolveValue('FILE_INDEX_PATH', EnvPairs);
  if Val <> '' then
  begin
    if FileExists(Val) then
      GConfig.FileIndexPath := Val
    else
      AddWarning(GConfig, 'FILE_INDEX_PATH not found: ' + Val);
  end
  else
  begin
    GConfig.FileIndexPath := AutoDetectFileIndexPath(ProjectPathWin);
    if GConfig.FileIndexPath = '' then
      AddWarning(GConfig, 'File index not found at drive root .public\.file-index.txt');
  end;

  // --- WSL ---
  // CLI flag has highest precedence
  if WSLFromCLI then
    GConfig.WSLMode := True
  else
  begin
    Val := ResolveValue('WSL', EnvPairs);
    GConfig.WSLMode := SameText(Val, 'true') or (Val = '1');
  end;

  // --- ENVIRONMENT.PROJ ---
  GConfig.EnvironmentProjPath := FindEnvironmentProjPath(GConfig.RsVarsPath);
  if GConfig.EnvironmentProjPath <> '' then
    GEnvProjVars := ParseEnvironmentProj(GConfig.EnvironmentProjPath)
  else
    AddWarning(GConfig, 'environment.proj not found (custom MSBuild variables unavailable)');

  GConfigInitialized := True;
end;

end.
