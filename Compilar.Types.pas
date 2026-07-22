unit Compilar.Types;

interface

type
  /// Build configuration
  TBuildConfig = (bcDebug, bcRelease);

  /// Target platform
  TBuildPlatform = (bpWin32, bpWin64);

  /// Issue type from compiler
  TIssueType = (itError, itWarning, itHint, itFatal);

  /// Single compilation issue (error, warning, or hint)
  TCompileIssue = record
    IssueType: TIssueType;
    Code: string;           // E2003, W1000, H2164, etc.
    FilePath: string;       // Full path to .pas file (Linux format)
    Line: Integer;
    Column: Integer;
    Message: string;
    Context: TArray<string>;  // Source code lines around error
  end;

  /// Parsed command line arguments
  TCompilerArgs = record
    ProjectPath: string;      // Full path to .dproj (Linux format)
    ProjectPathWin: string;   // Full path to .dproj (Windows format)
    Config: TBuildConfig;
    Platform: TBuildPlatform;
    TestMode: Boolean;        // Compile to temp folder
    MaxErrors: Integer;       // Max errors to report (default 3)
    ContextLines: Integer;    // Lines of context around error (default 5)
    RawOutput: Boolean;       // Echo raw MSBuild output to stderr
    FullOutput: Boolean;      // --full: list warning/hint items too (default: error items only)
    WSLMode: Boolean;         // Output Linux paths (--wsl flag)
    WorkspaceRoot: string;    // --workspace=ROOT: redirect ALL outputs under ROOT\out (cmx-workspace slots)
    RebuildCanonical: Boolean;// --rebuild-canonical: use /t:rebuild (default is /t:build since workspace mode)

    function ConfigStr: string;
    function PlatformStr: string;
  end;

  /// Build event execution result (prebuild/postbuild)
  TBuildEventInfo = record
    Command: string;
    Output: string;
    ExitCode: Integer;
    Executed: Boolean;
    Success: Boolean;
  end;

  /// Final compilation result
  TCompileResult = record
    Status: string;            // ok, hints, warnings, error, invalid, internal_error
    Project: string;           // Project filename only
    ProjectPath: string;       // Full path to .dproj (Linux format)
    Config: string;
    Platform: string;
    OutputPath: string;        // Path to compiled binary (Linux format)
    OutputStale: Boolean;      // True if output file was not updated (likely locked)
    OutputMessage: string;     // Human-readable explanation when OutputStale
    PreBuildEvent: TBuildEventInfo;
    PostBuildEvent: TBuildEventInfo;
    TimeMs: Int64;
    ExitCode: Integer;         // MSBuild exit code
    ErrorCount: Integer;
    WarningCount: Integer;
    HintCount: Integer;
    Truncated: Boolean;        // True if MaxErrors cut the issue list short
    TotalIssuesFound: Integer; // Total issues detected before truncation
    Issues: TArray<TCompileIssue>;

    class function Create(const Args: TCompilerArgs;
      const AIssues: TArray<TCompileIssue>; AExitCode: Integer;
      ATruncated: Boolean; ATotalIssuesFound: Integer): TCompileResult; static;
  end;

/// Helper functions for enum conversion
function IssueTypeToStr(T: TIssueType): string;
function StrToIssueType(const S: string): TIssueType;

/// Per-process scratch dir for --test mode (PID-suffixed: two concurrent
/// --test runs must not clean each other's output). Shared by MSBuild and
/// ProjectInfo so the path is defined exactly once.
function TestScratchDir: string;

implementation

uses
  System.SysUtils, System.IOUtils, Winapi.Windows;

function TestScratchDir: string;
begin
  Result := 'W:\temp\compilar\' + IntToStr(GetCurrentProcessId);
end;

function TCompilerArgs.ConfigStr: string;
begin
  case Config of
    bcDebug: Result := 'Debug';
    bcRelease: Result := 'Release';
  end;
end;

function TCompilerArgs.PlatformStr: string;
begin
  case Platform of
    bpWin32: Result := 'Win32';
    bpWin64: Result := 'Win64';
  end;
end;

class function TCompileResult.Create(const Args: TCompilerArgs;
  const AIssues: TArray<TCompileIssue>; AExitCode: Integer;
  ATruncated: Boolean; ATotalIssuesFound: Integer): TCompileResult;
var
  Issue: TCompileIssue;
begin
  Result.Project := TPath.GetFileName(Args.ProjectPath);
  Result.ProjectPath := Args.ProjectPath;
  Result.Config := Args.ConfigStr;
  Result.Platform := Args.PlatformStr;
  Result.ExitCode := AExitCode;
  Result.Truncated := ATruncated;
  Result.TotalIssuesFound := ATotalIssuesFound;
  Result.Issues := AIssues;
  Result.ErrorCount := 0;
  Result.WarningCount := 0;
  Result.HintCount := 0;
  Result.OutputPath := '';
  Result.OutputStale := False;
  Result.PreBuildEvent.Executed := False;
  Result.PostBuildEvent.Executed := False;

  // Count issues by type
  for Issue in AIssues do
  begin
    case Issue.IssueType of
      itError, itFatal: Inc(Result.ErrorCount);
      itWarning: Inc(Result.WarningCount);
      itHint: Inc(Result.HintCount);
    end;
  end;

  // Determine status: separate hints-only from warnings
  if Result.ErrorCount > 0 then
    Result.Status := 'error'
  else if Result.WarningCount > 0 then
    Result.Status := 'warnings'
  else if Result.HintCount > 0 then
    Result.Status := 'hints'
  else
    Result.Status := 'ok';
end;

function IssueTypeToStr(T: TIssueType): string;
begin
  case T of
    itError: Result := 'error';
    itWarning: Result := 'warning';
    itHint: Result := 'hint';
    itFatal: Result := 'fatal';
  end;
end;

function StrToIssueType(const S: string): TIssueType;
var
  Lower: string;
begin
  Lower := LowerCase(S);
  if Lower = 'error' then Result := itError
  else if Lower = 'warning' then Result := itWarning
  else if Lower = 'hint' then Result := itHint
  else if Lower = 'fatal' then Result := itFatal
  else Result := itError;
end;

end.
