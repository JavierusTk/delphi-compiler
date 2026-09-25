unit Compilar.Types;

interface

uses
  CmxWorkspace.Detect;

const
  /// Tool version — single source of truth. `--version`, the "version" field
  /// of every JSON output and the dproj VerInfo keys must stay in sync.
  COMPILER_VERSION = '1.15';

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

  /// cmx-workspace identity of an `invalid` (exit 2) whose CAUSE is the
  /// resolution ladder (v1.12, fix post-review R1). Until this fix the fatal
  /// JSON carried the slots involved ONLY inside the human sentence of
  /// "error", so a JSON client had to parse prose to recover them — exactly
  /// the case (conflict / mismatch) where a caller most needs the two slot
  /// ids. Ordinary argument errors (unknown flag, project not found, bad
  /// --config) leave this empty and keep the historical {status, version,
  /// error} shape: no workspace field ever appears for a non-workspace cause.
  TCmxWsFailure = record
    Present: Boolean;  // emit the workspace_* fields in the invalid JSON
    Source: string;    // 'flag'|'project'|'env'|'marker'|'none' — the rung the failure is ABOUT
                       // ('none' = the ladder could adopt no identity at all)
    KeyA: string;      // workspace_conflict: name of the first side involved...
    SlotA: string;     // ...and its slot id
    KeyB: string;      // '' when the failure involves no PAIR of slots
    SlotB: string;

    procedure Clear;
    /// Failure attributable to a single rung: only workspace_source travels.
    procedure Note(const ASource: string);
    /// Failure with TWO slots involved. Key pairs in use:
    ///   'env'/'marker'        — env <> CWD-marker conflict (same shape as the
    ///                           non-fatal workspace_conflict of a build result)
    ///   'project'/'workspace' — the project belongs to one slot and the
    ///                           effective workspace is another
    procedure NoteConflict(const ASource, AKeyA, ASlotA, AKeyB, ASlotB: string);
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
    WorkspaceRoot: string;    // effective cmx-workspace slot root: ALL outputs go under ROOT\out
    RebuildCanonical: Boolean;// --rebuild-canonical: use /t:rebuild (default is /t:build since workspace mode)
    // --- cmx-workspace identity (v1.12, MARKER-CONTRACT.md §5.3 ladder) ---
    WorkspaceSource: TCmxWsSource;  // which rung of the ladder set WorkspaceRoot
    ConflictEnvSlot: string;        // non-fatal env<>marker conflict: slot id seen in CMX_WORKSPACE
    ConflictMarkerSlot: string;     // ...and the one the CWD marker-walk found ('' when no conflict)
    /// Structured identity of a FATAL workspace failure. Written by the parser
    /// on the failing path and read by the caller AFTER Parse returns False
    /// (the record is passed by reference, so what the parser wrote survives),
    /// so the `invalid` JSON can state the slots instead of only narrating them.
    WsFailure: TCmxWsFailure;

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
    Skipped: Boolean;       // defined in the .dproj but deliberately NOT run
    SkipReason: string;     // why (reported in the JSON, never a silent omission)
  end;

  /// Final compilation result
  TCompileResult = record
    Status: string;            // ok, hints, warnings, error, output_locked, postbuild_error, invalid, internal_error
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
    // --- cmx-workspace identity (v1.12) ---
    WorkspaceSource: string;      // 'flag' | 'project' | 'env' | 'marker' | 'none'
    WorkspaceRoot: string;        // effective slot root ('' when source = none)
    ConflictEnvSlot: string;      // informational env<>marker conflict (both '' when none)
    ConflictMarkerSlot: string;

    class function Create(const Args: TCompilerArgs;
      const AIssues: TArray<TCompileIssue>; AExitCode: Integer;
      ATruncated: Boolean; ATotalIssuesFound: Integer): TCompileResult; static;
  end;

/// Helper functions for enum conversion
function IssueTypeToStr(T: TIssueType): string;
function StrToIssueType(const S: string): TIssueType;

/// True for an MSBuild-level diagnostic (code MSBnnnn): a build task failed,
/// not dcc (v1.14).
function IsMSBuildCode(const ACode: string): Boolean;

/// MSBuild errors meaning "the output file is held by another process"
/// (delete/copy denied). They EXPLAIN output_locked instead of competing
/// with it: /t:rebuild on a locked exe prints MSB3061 and compiles nothing.
function IsFileLockMSBuildCode(const ACode: string): Boolean;

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

function IsMSBuildCode(const ACode: string): Boolean;
begin
  Result := ACode.StartsWith('MSB', True);
end;

function IsFileLockMSBuildCode(const ACode: string): Boolean;
begin
  // MSB3061: unable to delete file; MSB3021: unable to copy file;
  // MSB3027: could not copy, retry count exceeded (file locked)
  Result := SameText(ACode, 'MSB3061') or SameText(ACode, 'MSB3021')
    or SameText(ACode, 'MSB3027');
end;

procedure TCmxWsFailure.Clear;
begin
  Present := False;
  Source := '';
  KeyA := '';
  SlotA := '';
  KeyB := '';
  SlotB := '';
end;

procedure TCmxWsFailure.Note(const ASource: string);
begin
  Clear;
  Present := True;
  Source := ASource;
end;

procedure TCmxWsFailure.NoteConflict(const ASource, AKeyA, ASlotA, AKeyB,
  ASlotB: string);
begin
  Note(ASource);
  KeyA := AKeyA;
  SlotA := ASlotA;
  KeyB := AKeyB;
  SlotB := ASlotB;
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
  Result.PreBuildEvent.Skipped := False;
  Result.PostBuildEvent.Executed := False;
  Result.PostBuildEvent.Skipped := False;
  Result.WorkspaceSource := CmxWsSourceToStr(Args.WorkspaceSource);
  Result.WorkspaceRoot := Args.WorkspaceRoot;
  Result.ConflictEnvSlot := Args.ConflictEnvSlot;
  Result.ConflictMarkerSlot := Args.ConflictMarkerSlot;

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
