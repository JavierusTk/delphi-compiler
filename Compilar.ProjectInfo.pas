unit Compilar.ProjectInfo;

interface

uses
  Compilar.Types;

type
  TProjectInfo = class
  public
    /// Extract output binary path from MSBuild output (parses DCC command line flags)
    /// This is the authoritative source since it reflects actual MSBuild variable resolution
    class function GetOutputFromMSBuild(const MSBuildOutput: string; const Args: TCompilerArgs): string;

    /// Extract the expected output binary path by parsing the .dproj file
    /// Fallback when MSBuild output parsing fails
    class function GetOutputPath(const Args: TCompilerArgs): string;

  private
    class function FindDccCommandLine(const MSBuildOutput: string): string;
    class function ExtractDccFlag(const DccLine, Flag: string): string;
    class function ExtractSourceFromDccLine(const DccLine: string): string;
    class function ReadMainSource(const DprojPath: string): string;
    class function ReadDprojProperty(const DprojPath, PropertyName, Config, Platform: string): string;
    class function ReadOptsetProperty(const OptsetPath, PropertyName: string): string;
    class function ReadImportedProperty(const DprojPath, PropertyName, Config, Platform: string): string;
    class function ReadDeployFileOutput(const DprojPath, Config: string): string;
    class function GetProjectExtension(const DprojPath: string): string;
    class function GetLibSuffix(const DprojPath: string): string;
    class function ResolveVariables(const Value, Config, Platform, ProjectDir: string): string;
  end;

implementation

uses
  System.SysUtils, System.IOUtils, System.Classes, System.RegularExpressions,
  Compilar.PathUtils, Compilar.Config;

const
  TEMP_OUTPUT_DIR = 'W:\temp\compilar';

class function TProjectInfo.FindDccCommandLine(const MSBuildOutput: string): string;
var
  Lines: TArray<string>;
  Line: string;
  I: Integer;
begin
  Result := '';
  Lines := MSBuildOutput.Split([#10]);
  for I := 0 to High(Lines) do
  begin
    Line := Lines[I].Trim;
    // DCC compiler executables: dcc32.exe, dcc64.exe, dccosx64.exe, dccaarm64.exe, etc.
    if TRegEx.IsMatch(Line, '\bdcc\w*\.exe\b', [roIgnoreCase]) then
      Exit(Line);
  end;
end;

class function TProjectInfo.ExtractDccFlag(const DccLine, Flag: string): string;
var
  SearchFlag: string;
  FlagPos, StartPos, EndPos: Integer;
begin
  Result := '';

  // Search for flag preceded by space to avoid matching inside paths
  SearchFlag := ' ' + Flag;
  FlagPos := Pos(SearchFlag, DccLine);
  if FlagPos = 0 then
    Exit;

  StartPos := FlagPos + Length(SearchFlag);
  if StartPos > Length(DccLine) then
    Exit;

  if DccLine[StartPos] = '"' then
  begin
    // Quoted value: -E"path with spaces"
    Inc(StartPos);
    EndPos := Pos('"', DccLine, StartPos);
    if EndPos > StartPos then
      Result := Copy(DccLine, StartPos, EndPos - StartPos);
  end
  else
  begin
    // Unquoted value: -E.\Win64\Release (runs until space)
    EndPos := StartPos;
    while (EndPos <= Length(DccLine)) and (DccLine[EndPos] > ' ') do
      Inc(EndPos);
    Result := Copy(DccLine, StartPos, EndPos - StartPos);
  end;
end;

class function TProjectInfo.ExtractSourceFromDccLine(const DccLine: string): string;
var
  Match: TMatch;
begin
  // The .dpr/.dpk source file is the last token on the DCC command line.
  // It may be quoted or unquoted, and followed by optional whitespace or (TaskId:NN).
  Match := TRegEx.Match(DccLine, '(?:"([^"]+\.dp[rk])"|(\S+\.dp[rk]))\s*(?:\(TaskId:\d+\))?\s*$', [roIgnoreCase]);
  if Match.Success then
  begin
    if Match.Groups[1].Success then
      Result := Match.Groups[1].Value   // Quoted path
    else
      Result := Match.Groups[2].Value;  // Unquoted path
  end
  else
    Result := '';
end;

class function TProjectInfo.ReadMainSource(const DprojPath: string): string;
var
  Content: string;
  Match: TMatch;
begin
  Result := '';
  if not FileExists(DprojPath) then
    Exit;
  try
    Content := TFile.ReadAllText(DprojPath, TEncoding.UTF8);
  except
    Exit;
  end;
  Match := TRegEx.Match(Content, '<MainSource>([^<]+)</MainSource>');
  if Match.Success then
    Result := Match.Groups[1].Value;
end;

class function TProjectInfo.GetOutputFromMSBuild(const MSBuildOutput: string; const Args: TCompilerArgs): string;
var
  DccLine: string;
  OutputDir, Extension: string;
  ProjectDir, ProjectName: string;
  FullPath: string;
  ExtFromProject: string;
begin
  Result := '';

  DccLine := FindDccCommandLine(MSBuildOutput);
  if DccLine = '' then
    Exit;

  ProjectDir := ExtractFilePath(Args.ProjectPathWin);
  ProjectName := ChangeFileExt(TPath.GetFileName(Args.ProjectPathWin), '');
  ExtFromProject := GetProjectExtension(Args.ProjectPathWin);

  // Extract output directory: -LE for BPL packages, -E for exe/dll
  if ExtFromProject = '.bpl' then
    OutputDir := ExtractDccFlag(DccLine, '-LE')
  else
    OutputDir := ExtractDccFlag(DccLine, '-E');

  // Without -E/-LE, DCC writes output to the source file directory (.dpr/.dpk)
  if OutputDir = '' then
    OutputDir := ExtractFilePath(ExtractSourceFromDccLine(DccLine));

  if OutputDir = '' then
    Exit;

  // Extract output extension from -TX flag, fallback to project type
  Extension := ExtractDccFlag(DccLine, '-TX');
  if Extension = '' then
    Extension := ExtFromProject;

  // Resolve relative paths against project directory
  if not TPath.IsPathRooted(OutputDir) then
    OutputDir := TPath.Combine(ProjectDir, OutputDir);
  OutputDir := TPath.GetFullPath(OutputDir);

  FullPath := TPath.Combine(OutputDir, ProjectName + Extension);

  if FileExists(FullPath) then
    Result := TPathUtils.NormalizeForOutput(FullPath)
  else
  begin
    // Try with lib suffix (e.g., MyPackage290.bpl from {$LIBSUFFIX AUTO})
    FullPath := TPath.Combine(OutputDir, ProjectName + GetLibSuffix(Args.ProjectPathWin) + Extension);
    if FileExists(FullPath) then
      Result := TPathUtils.NormalizeForOutput(FullPath);
  end;
end;

class function TProjectInfo.GetOutputPath(const Args: TCompilerArgs): string;
var
  ExeOutput: string;
  ProjectDir: string;
  ProjectName: string;
  Extension: string;
  OutputDir: string;
  FullPath: string;
begin
  Result := '';

  // In test mode, output always goes to temp folder
  if Args.TestMode then
  begin
    ProjectName := ChangeFileExt(TPath.GetFileName(Args.ProjectPathWin), '');
    Extension := GetProjectExtension(Args.ProjectPathWin);
    FullPath := TPath.Combine(TEMP_OUTPUT_DIR, ProjectName + Extension);
    if FileExists(FullPath) then
      Result := TPathUtils.NormalizeForOutput(FullPath);
    Exit;
  end;

  ProjectDir := ExtractFilePath(Args.ProjectPathWin);
  ProjectName := ChangeFileExt(TPath.GetFileName(Args.ProjectPathWin), '');
  Extension := GetProjectExtension(Args.ProjectPathWin);

  // Try to read output directory from .dproj
  // For packages (.bpl), use DCC_BplOutput; for executables, use DCC_ExeOutput
  if Extension = '.bpl' then
    ExeOutput := ReadDprojProperty(Args.ProjectPathWin, 'DCC_BplOutput', Args.ConfigStr, Args.PlatformStr)
  else
    ExeOutput := ReadDprojProperty(Args.ProjectPathWin, 'DCC_ExeOutput', Args.ConfigStr, Args.PlatformStr);

  if ExeOutput <> '' then
  begin
    // Resolve MSBuild variables: $(Config), $(Platform), etc.
    OutputDir := ResolveVariables(ExeOutput, Args.ConfigStr, Args.PlatformStr, ProjectDir);

    // Make absolute if relative
    if not TPath.IsPathRooted(OutputDir) then
      OutputDir := TPath.Combine(ProjectDir, OutputDir);

    OutputDir := TPath.GetFullPath(OutputDir);
    FullPath := TPath.Combine(OutputDir, ProjectName + Extension);
  end
  else
  begin
    // Fallback: check DeployFile with Class="ProjectOutput" for the actual output path
    FullPath := ReadDeployFileOutput(Args.ProjectPathWin, Args.ConfigStr);

    // Resolve relative DeployFile paths against project directory
    if (FullPath <> '') and not TPath.IsPathRooted(FullPath) then
      FullPath := TPath.GetFullPath(TPath.Combine(ProjectDir, FullPath));

    if FullPath = '' then
    begin
      // Without DCC_ExeOutput, DCC writes output to the source file directory.
      // Read MainSource from dproj to find the .dpr/.dpk location.
      OutputDir := ExtractFilePath(ReadMainSource(Args.ProjectPathWin));
      if OutputDir = '' then
        OutputDir := ProjectDir;
      FullPath := TPath.Combine(OutputDir, ProjectName + Extension);
    end;
  end;

  // Only report if the file actually exists (compilation succeeded)
  if FileExists(FullPath) then
    Result := TPathUtils.NormalizeForOutput(FullPath)
  else
  begin
    // Try with lib suffix (e.g., MyPackage290.bpl from {$LIBSUFFIX AUTO})
    OutputDir := ExtractFilePath(FullPath);
    FullPath := TPath.Combine(OutputDir, ProjectName + GetLibSuffix(Args.ProjectPathWin) + Extension);
    if FileExists(FullPath) then
      Result := TPathUtils.NormalizeForOutput(FullPath);
  end;
end;

class function TProjectInfo.ReadDprojProperty(const DprojPath, PropertyName, Config, Platform: string): string;
var
  Content: string;
  Match: TMatch;
  CfgKey, CfgPlatKey, BasePlatKey: string;
  Blocks: TArray<string>;
  Block, Condition: string;
  BestValue: string;
  BestPriority, Priority: Integer;
  I: Integer;
  PropPattern: string;
begin
  Result := '';

  if not FileExists(DprojPath) then
    Exit;

  try
    Content := TFile.ReadAllText(DprojPath, TEncoding.UTF8);
  except
    Exit;
  end;

  // Find config key mapping: e.g., Release -> Cfg_1, Debug -> Cfg_2
  Match := TRegEx.Match(Content,
    '<BuildConfiguration\s+Include="' + Config + '">\s*<Key>(\w+)</Key>',
    [roIgnoreCase]);
  if not Match.Success then
    Exit;
  CfgKey := Match.Groups[1].Value;

  // Build scope identifiers for priority matching
  CfgPlatKey := CfgKey + '_' + Platform;     // e.g., Cfg_1_Win64
  BasePlatKey := 'Base_' + Platform;          // e.g., Base_Win64

  // Search PropertyGroup blocks with MSBuild-aware priority.
  // Most specific matching scope wins (Config+Platform > Config > Base+Platform > Base).
  BestValue := '';
  BestPriority := -1;
  PropPattern := '<' + PropertyName + '>([^<]+)</' + PropertyName + '>';

  Blocks := Content.Split(['<PropertyGroup']);
  for I := 1 to High(Blocks) do
  begin
    Block := Blocks[I];

    // Extract Condition attribute
    Match := TRegEx.Match(Block, '\s+Condition="([^"]*)"');
    if not Match.Success then
      Continue;  // Skip unconditional PropertyGroups (project metadata)
    Condition := Match.Groups[1].Value;

    // Determine priority based on which MSBuild scope this PropertyGroup belongs to.
    // Note: Cfg_1_Win64 condition contains both $(Cfg_1) and $(Cfg_1_Win64),
    // so we check the most specific key first and use underscore-prefix exclusions
    // to distinguish config-only from config+platform groups.
    if Pos('$(' + CfgPlatKey + ')', Condition) > 0 then
      Priority := 4  // Config + Platform (e.g., Cfg_1_Win64)
    else if (Pos('$(' + CfgKey + ')', Condition) > 0) and
            (Pos('$(' + CfgKey + '_', Condition) = 0) then
      Priority := 3  // Config only (e.g., Cfg_1), excluding platform-specific variants
    else if Pos('$(' + BasePlatKey + ')', Condition) > 0 then
      Priority := 2  // Base + Platform (e.g., Base_Win64)
    else if (Pos('$(Base)', Condition) > 0) and
            (Pos('$(Base_', Condition) = 0) then
      Priority := 1  // Base only, excluding platform-specific variants
    else
      Continue;  // Not applicable (different config or platform)

    // Look for the property in this block
    Match := TRegEx.Match(Block, PropPattern);
    if Match.Success and (Priority > BestPriority) then
    begin
      BestValue := Match.Groups[1].Value;
      BestPriority := Priority;
    end;
  end;

  Result := BestValue;

  // If not found in .dproj, check imported optsets
  if Result = '' then
    Result := ReadImportedProperty(DprojPath, PropertyName, Config, Platform);
end;

class function TProjectInfo.ReadOptsetProperty(const OptsetPath, PropertyName: string): string;
var
  Content: string;
  Match: TMatch;
begin
  Result := '';
  if not FileExists(OptsetPath) then
    Exit;
  try
    Content := TFile.ReadAllText(OptsetPath, TEncoding.UTF8);
  except
    Exit;
  end;
  Match := TRegEx.Match(Content,
    '<' + PropertyName + '>([^<]+)</' + PropertyName + '>');
  if Match.Success then
    Result := Match.Groups[1].Value;
end;

class function TProjectInfo.ReadImportedProperty(
  const DprojPath, PropertyName, Config, Platform: string): string;
var
  Content: string;
  Matches: TMatchCollection;
  ImportPath, ResolvedPath, ProjectDir: string;
  I: Integer;
begin
  Result := '';
  try
    Content := TFile.ReadAllText(DprojPath, TEncoding.UTF8);
  except
    Exit;
  end;

  ProjectDir := ExtractFilePath(DprojPath);

  // Find Import elements referencing .optset files
  Matches := TRegEx.Matches(Content,
    '<Import\s+Project="([^"]+\.optset)"', [roIgnoreCase]);
  for I := 0 to Matches.Count - 1 do
  begin
    ImportPath := Matches[I].Groups[1].Value;
    // Resolve variables in import path
    ResolvedPath := ResolveEnvProjVars(ImportPath);
    if not TPath.IsPathRooted(ResolvedPath) then
      ResolvedPath := TPath.GetFullPath(TPath.Combine(ProjectDir, ResolvedPath));

    if FileExists(ResolvedPath) then
    begin
      Result := ReadOptsetProperty(ResolvedPath, PropertyName);
      if Result <> '' then
        Exit;
    end;
  end;
end;

class function TProjectInfo.ReadDeployFileOutput(const DprojPath, Config: string): string;
var
  Content: string;
  Match: TMatch;
  Pattern: string;
begin
  Result := '';

  if not FileExists(DprojPath) then
    Exit;

  try
    Content := TFile.ReadAllText(DprojPath, TEncoding.UTF8);
  except
    Exit;
  end;

  // Look for <DeployFile LocalName="..." Configuration="Config" Class="ProjectOutput"/>
  Pattern := '<DeployFile\s+LocalName="([^"]+)"\s+Configuration="' + Config + '"\s+Class="ProjectOutput"';
  Match := TRegEx.Match(Content, Pattern, [roIgnoreCase]);

  if Match.Success then
    Result := Match.Groups[1].Value;
end;

class function TProjectInfo.GetProjectExtension(const DprojPath: string): string;
var
  Content: string;
  MainSource: string;
begin
  // Default to .exe
  Result := '.exe';

  if not FileExists(DprojPath) then
    Exit;

  try
    Content := TFile.ReadAllText(DprojPath, TEncoding.UTF8);
  except
    Exit;
  end;

  // Check MainSource extension: .dpr -> .exe, .dpk -> .bpl
  MainSource := '';
  with TRegEx.Match(Content, '<MainSource>([^<]+)</MainSource>') do
    if Success then
      MainSource := Groups[1].Value;

  if MainSource.EndsWith('.dpk', True) then
    Result := '.bpl'
  else if Pos('Library', Content) > 0 then
  begin
    // Check for <Borland.ProjectType>Library</Borland.ProjectType>
    if TRegEx.IsMatch(Content, '<Borland\.ProjectType>.*Library.*</Borland\.ProjectType>') then
      Result := '.dll';
  end;
end;

class function TProjectInfo.GetLibSuffix(const DprojPath: string): string;
var
  MainSource, DpkPath, DpkContent: string;
  Match: TMatch;
begin
  Result := '';
  MainSource := ReadMainSource(DprojPath);
  if not MainSource.EndsWith('.dpk', True) then
    Exit;

  DpkPath := TPath.Combine(ExtractFilePath(DprojPath), MainSource);
  if not FileExists(DpkPath) then
    Exit;

  try
    DpkContent := TFile.ReadAllText(DpkPath, TEncoding.UTF8);
  except
    Exit;
  end;

  // Match {$LIBSUFFIX 'xxx'} or {$LIBSUFFIX AUTO}
  Match := TRegEx.Match(DpkContent, '\{\$LIBSUFFIX\s+''?(\w+)''?\}', [roIgnoreCase]);
  if Match.Success then
  begin
    Result := Match.Groups[1].Value;
    if SameText(Result, 'AUTO') then
      Result := ResolveEnvProjVars('$(DELPHIVERSION)');
  end;
end;

class function TProjectInfo.ResolveVariables(const Value, Config, Platform, ProjectDir: string): string;
begin
  Result := Value;
  Result := StringReplace(Result, '$(Config)', Config, [rfReplaceAll, rfIgnoreCase]);
  Result := StringReplace(Result, '$(Configuration)', Config, [rfReplaceAll, rfIgnoreCase]);
  Result := StringReplace(Result, '$(Platform)', Platform, [rfReplaceAll, rfIgnoreCase]);
  Result := StringReplace(Result, '$(ProjectDir)', ProjectDir, [rfReplaceAll, rfIgnoreCase]);
  // Resolve remaining variables from environment.proj (BPLCMX, DCPCMX, DCUCMX, etc.)
  Result := ResolveEnvProjVars(Result);
end;

end.
