unit Compilar.PathUtils;

interface

type
  TPathUtils = class
  public
    /// Convert Linux path (/mnt/w/...) to Windows path (W:\...)
    class function LinuxToWindows(const Path: string): string;

    /// Convert Windows path (W:\...) to Linux path (/mnt/w/...)
    class function WindowsToLinux(const Path: string): string;

    /// Detect if path is Linux format
    class function IsLinuxPath(const Path: string): Boolean;

    /// Detect if path is Windows format
    class function IsWindowsPath(const Path: string): Boolean;

    /// Normalize path to Linux format (for JSON output)
    class function NormalizeToLinux(const Path: string): string;

    /// Normalize path to Windows format (for MSBuild)
    class function NormalizeToWindows(const Path: string): string;

    /// Normalize path for JSON output (Linux if WSL mode, Windows otherwise)
    class function NormalizeForOutput(const Path: string): string;
  end;

implementation

uses
  System.SysUtils, System.RegularExpressions,
  Compilar.Config;

class function TPathUtils.IsLinuxPath(const Path: string): Boolean;
begin
  Result := Path.StartsWith('/mnt/');
end;

class function TPathUtils.IsWindowsPath(const Path: string): Boolean;
begin
  // Matches C:\, D:\, W:\, etc.
  Result := (Length(Path) >= 3) and
            CharInSet(Path[1], ['A'..'Z', 'a'..'z']) and
            (Path[2] = ':') and
            (Path[3] = '\');
end;

class function TPathUtils.LinuxToWindows(const Path: string): string;
var
  DriveLetter: Char;
  Rest: string;
begin
  // /mnt/w/folder/file.pas -> W:\folder\file.pas
  if not IsLinuxPath(Path) then
    Exit(Path);

  // Extract drive letter from /mnt/X/...
  if Length(Path) < 6 then
    Exit(Path);

  DriveLetter := UpCase(Path[6]);  // /mnt/w -> 'W'
  Rest := Copy(Path, 7, MaxInt);   // /folder/file.pas

  // Replace forward slashes with backslashes
  Rest := StringReplace(Rest, '/', '\', [rfReplaceAll]);

  Result := DriveLetter + ':' + Rest;
end;

class function TPathUtils.WindowsToLinux(const Path: string): string;
var
  DriveLetter: Char;
  Rest: string;
begin
  // W:\folder\file.pas -> /mnt/w/folder/file.pas
  if not IsWindowsPath(Path) then
    Exit(Path);

  DriveLetter := LowerCase(Path[1])[1];
  Rest := Copy(Path, 3, MaxInt);  // \folder\file.pas

  // Replace backslashes with forward slashes
  Rest := StringReplace(Rest, '\', '/', [rfReplaceAll]);

  Result := '/mnt/' + DriveLetter + Rest;
end;

class function TPathUtils.NormalizeToLinux(const Path: string): string;
begin
  if IsWindowsPath(Path) then
    Result := WindowsToLinux(Path)
  else
    Result := Path;
end;

class function TPathUtils.NormalizeToWindows(const Path: string): string;
begin
  if IsLinuxPath(Path) then
    Result := LinuxToWindows(Path)
  else
    Result := Path;
end;

class function TPathUtils.NormalizeForOutput(const Path: string): string;
begin
  if Config.WSLMode then
    Result := NormalizeToLinux(Path)
  else
    Result := NormalizeToWindows(Path);
end;

end.
