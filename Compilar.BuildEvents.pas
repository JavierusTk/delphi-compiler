unit Compilar.BuildEvents;

interface

uses
  Compilar.Types;

type
  TBuildEvents = class
  public
    class function GetPreBuildEvent(const ADprojPath, AConfig, APlatform: string): string;
    class function GetPostBuildEvent(const ADprojPath, AConfig, APlatform: string): string;
    class function Execute(const ACommand, AProjectDir: string): TBuildEventInfo;
  private
    class function ParseEvent(const ADprojPath, AEventName, AConfig, APlatform: string): string;
    class function CleanEventValue(const AValue: string): string;
  end;

implementation

uses
  System.SysUtils, System.IOUtils, System.Classes,
  System.RegularExpressions, Winapi.Windows;

//------------------------------------------------------------------------------
class function TBuildEvents.CleanEventValue(const AValue: string): string;
var
  LLines: TStringList;
  LResult: TStringList;
  I: Integer;
  LLine: string;
begin
  Result := EmptyStr;
  LLine := AValue;
  LLine := StringReplace(LLine, '<![CDATA[', EmptyStr, []);
  LLine := StringReplace(LLine, ']]>', EmptyStr, []);

  LLines := TStringList.Create();
  LResult := TStringList.Create();
  try
    LLines.Text := LLine;
    for I := 0 to LLines.Count - 1 do
    begin
      LLine := System.SysUtils.Trim(LLines[I]);
      if LLine.IsEmpty then
        Continue;
      // Skip MSBuild macro references like $(PreBuildEvent)
      if LLine.StartsWith('$(') and LLine.EndsWith(')') then
        Continue;
      LResult.Add(LLine);
    end;
    // Join with line breaks for the .bat file (each command on its own line).
    // Using && would change semantics: MSBuild runs each line independently,
    // but && aborts on first non-zero exit code.
    Result := EmptyStr;
    for I := 0 to LResult.Count - 1 do
    begin
      if I > 0 then
        Result := Result + #13#10;
      Result := Result + LResult[I];
    end;
  finally
    LLines.Free();
    LResult.Free();
  end;
end;

//------------------------------------------------------------------------------
class function TBuildEvents.ParseEvent(const ADprojPath, AEventName,
  AConfig, APlatform: string): string;
var
  LContent: string;
  LBlocks: TArray<string>;
  LBlock: string;
  LCondition: string;
  LValue: string;
  LMatch: TMatch;
  I: Integer;
  LBestValue: string;
  LBestPriority: Integer;
  LPriority: Integer;
  LPropPattern: string;
  LCfgKey: string;
  LCfgPlatKey: string;
  LBasePlatKey: string;
begin
  Result := EmptyStr;
  if not FileExists(ADprojPath) then
    Exit;

  try
    LContent := TFile.ReadAllText(ADprojPath, TEncoding.UTF8);
  except
    Exit;
  end;

  LBestValue := EmptyStr;
  LBestPriority := -1;
  LPropPattern := '<' + AEventName + '>(.*?)</' + AEventName + '>';
  LBlocks := LContent.Split(['<PropertyGroup']);

  // Pass 1: Search PropertyGroups with direct $(Config)/$(Platform) conditions
  for I := 1 to High(LBlocks) do
  begin
    LBlock := LBlocks[I];

    LMatch := TRegEx.Match(LBlock, '\s+Condition="([^"]*)"');
    if not LMatch.Success then
      Continue;
    LCondition := LMatch.Groups[1].Value;

    if (Pos('$(Config)', LCondition) > 0) and (Pos('$(Platform)', LCondition) > 0) and
       (Pos(AConfig, LCondition) > 0) and (Pos(APlatform, LCondition) > 0) then
      LPriority := 4
    else
    if (Pos('$(Config)', LCondition) > 0) and (Pos(AConfig, LCondition) > 0) then
    begin
      if (Pos('$(Platform)', LCondition) > 0) and (Pos(APlatform, LCondition) = 0) then
        Continue;
      LPriority := 3;
    end
    else
      Continue;

    LMatch := TRegEx.Match(LBlock, LPropPattern, [roSingleLine]);
    if LMatch.Success and (LPriority > LBestPriority) then
    begin
      LValue := CleanEventValue(LMatch.Groups[1].Value);
      if not LValue.IsEmpty then
      begin
        LBestValue := LValue;
        LBestPriority := LPriority;
      end;
    end;
  end;

  if not LBestValue.IsEmpty then
    Exit(LBestValue);

  // Pass 2: Search PropertyGroups with Cfg_X style conditions
  LMatch := TRegEx.Match(LContent,
    '<BuildConfiguration\s+Include="' + AConfig + '">\s*<Key>(\w+)</Key>',
    [roIgnoreCase]);
  if not LMatch.Success then
    Exit;

  LCfgKey := LMatch.Groups[1].Value;
  LCfgPlatKey := LCfgKey + '_' + APlatform;
  LBasePlatKey := 'Base_' + APlatform;

  for I := 1 to High(LBlocks) do
  begin
    LBlock := LBlocks[I];

    LMatch := TRegEx.Match(LBlock, '\s+Condition="([^"]*)"');
    if not LMatch.Success then
      Continue;
    LCondition := LMatch.Groups[1].Value;

    if Pos('$(' + LCfgPlatKey + ')', LCondition) > 0 then
      LPriority := 4
    else
    if (Pos('$(' + LCfgKey + ')', LCondition) > 0) and
       (Pos('$(' + LCfgKey + '_', LCondition) = 0) then
      LPriority := 3
    else
    if Pos('$(' + LBasePlatKey + ')', LCondition) > 0 then
      LPriority := 2
    else
    if (Pos('$(Base)', LCondition) > 0) and
       (Pos('$(Base_', LCondition) = 0) then
      LPriority := 1
    else
      Continue;

    LMatch := TRegEx.Match(LBlock, LPropPattern, [roSingleLine]);
    if LMatch.Success and (LPriority > LBestPriority) then
    begin
      LValue := CleanEventValue(LMatch.Groups[1].Value);
      if not LValue.IsEmpty then
      begin
        LBestValue := LValue;
        LBestPriority := LPriority;
      end;
    end;
  end;

  Result := LBestValue;
end;

//------------------------------------------------------------------------------
class function TBuildEvents.GetPreBuildEvent(const ADprojPath, AConfig,
  APlatform: string): string;
begin
  Result := ParseEvent(ADprojPath, 'PreBuildEvent', AConfig, APlatform);
end;

//------------------------------------------------------------------------------
class function TBuildEvents.GetPostBuildEvent(const ADprojPath, AConfig,
  APlatform: string): string;
begin
  Result := ParseEvent(ADprojPath, 'PostBuildEvent', AConfig, APlatform);
end;

//------------------------------------------------------------------------------
class function TBuildEvents.Execute(const ACommand,
  AProjectDir: string): TBuildEventInfo;
var
  LSA: TSecurityAttributes;
  LSI: TStartupInfo;
  LPI: TProcessInformation;
  LTempBat: string;
  LReadPipe: THandle;
  LWritePipe: THandle;
  LBuffer: array[0..4095] of Byte;
  LBytesRead: DWORD;
  LOutput: TStringBuilder;
  LWaitResult: DWORD;
  LCmdLine: string;
  LWideLen: Integer;
  LWideBuffer: string;
begin
  Result.Command := ACommand;
  Result.Output := EmptyStr;
  Result.ExitCode := -1;
  Result.Executed := True;
  Result.Success := False;
  Result.Skipped := False;
  Result.SkipReason := EmptyStr;

  // Write a temp bat file in the project directory.
  // Use PID for uniqueness to avoid collisions under concurrent compilation.
  LTempBat := IncludeTrailingPathDelimiter(AProjectDir) +
    Format('__compilar_event_%d__.bat', [GetCurrentProcessId]);
  try
    try
      TFile.WriteAllText(LTempBat,
        '@echo off' + #13#10 +
        '%~d0' + #13#10 +
        'cd "%~dp0"' + #13#10 +
        'set PATH=%CD%;%PATH%' + #13#10 +
        ACommand + #13#10,
        TEncoding.ASCII);
    except
      on E: Exception do
      begin
        Result.Output := 'Failed to create temp bat: ' + E.Message;
        Exit;
      end;
    end;

    LCmdLine := 'cmd.exe /c "' + LTempBat + '"';

    FillChar(LSA, SizeOf(LSA), 0);
    LSA.nLength := SizeOf(LSA);
    LSA.bInheritHandle := True;

    if not CreatePipe(LReadPipe, LWritePipe, @LSA, 0) then
      Exit;

    try
      SetHandleInformation(LReadPipe, HANDLE_FLAG_INHERIT, 0);

      FillChar(LSI, SizeOf(LSI), 0);
      LSI.cb := SizeOf(LSI);
      LSI.dwFlags := STARTF_USESHOWWINDOW or STARTF_USESTDHANDLES;
      LSI.wShowWindow := SW_HIDE;
      LSI.hStdOutput := LWritePipe;
      LSI.hStdError := LWritePipe;
      LSI.hStdInput := 0;

      FillChar(LPI, SizeOf(LPI), 0);

      if not CreateProcess(
        nil,
        PChar(LCmdLine),
        nil,
        nil,
        True,
        CREATE_NO_WINDOW,
        nil,
        PChar(AProjectDir),
        LSI,
        LPI) then
        Exit;

      try
        CloseHandle(LWritePipe);
        LWritePipe := 0;

        LOutput := TStringBuilder.Create();
        try
          repeat
            if ReadFile(LReadPipe, LBuffer, SizeOf(LBuffer), LBytesRead, nil) and
               (LBytesRead > 0) then
            begin
              LWideLen := MultiByteToWideChar(CP_OEMCP, 0, @LBuffer[0], LBytesRead, nil, 0);
              SetLength(LWideBuffer, LWideLen);
              MultiByteToWideChar(CP_OEMCP, 0, @LBuffer[0], LBytesRead,
                PChar(LWideBuffer), LWideLen);
              LOutput.Append(LWideBuffer);
            end;
          until LBytesRead = 0;

          Result.Output := System.SysUtils.Trim(LOutput.ToString());
        finally
          LOutput.Free();
        end;

        LWaitResult := WaitForSingleObject(LPI.hProcess, 60000);
        if LWaitResult = WAIT_TIMEOUT then
        begin
          TerminateProcess(LPI.hProcess, 1);
          Result.Output := Result.Output + #13#10 +
            '[TIMEOUT: Build event killed after 60 seconds]';
          Result.ExitCode := -2;
        end
        else
        begin
          GetExitCodeProcess(LPI.hProcess, DWORD(Result.ExitCode));
        end;

        Result.Success := (Result.ExitCode = 0);
      finally
        CloseHandle(LPI.hProcess);
        CloseHandle(LPI.hThread);
      end;
    finally
      if LReadPipe <> 0 then
        CloseHandle(LReadPipe);
      if LWritePipe <> 0 then
        CloseHandle(LWritePipe);
    end;

  finally
    // Always clean up temp bat file
    if FileExists(LTempBat) then
      System.SysUtils.DeleteFile(LTempBat);
  end;
end;

end.
