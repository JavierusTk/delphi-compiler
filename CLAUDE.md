# delphi-compiler

Source code for `delphi-compiler.exe` — a Delphi compilation wrapper with structured JSON output, designed for AI coding agents.

## Project Files

| File | Purpose |
|------|---------|
| `delphi-compiler.dpr` | Main project file |
| `delphi-compiler.dproj` | Delphi project settings |

## Source Units

| Unit | Purpose |
|------|---------|
| `CmxWorkspace.Detect.pas` | **External** (`W:\cmx-slots\lib`, reference implementation of `MARKER-CONTRACT.md`): slot identity detection. Reached by `DCC_UnitSearchPath ..\..\cmx-slots\lib` and compiled INTO the exe — build-time dependency only |
| `Compilar.Args.pas` | Command-line argument parsing + workspace resolution ladder |
| `Compilar.BuildEvents.pas` | PreBuild/PostBuild event parsing and execution |
| `Compilar.Config.pas` | Configuration (.env, registry, auto-detection) |
| `Compilar.Context.pas` | Source code context extraction for errors |
| `Compilar.MSBuild.pas` | MSBuild invocation wrapper |
| `Compilar.Output.pas` | JSON output formatting |
| `Compilar.Parser.pas` | Compiler output parsing |
| `Compilar.PathUtils.pas` | Path manipulation utilities |
| `Compilar.ProjectInfo.pas` | .dproj parsing and output path resolution |
| `Compilar.Types.pas` | Type definitions |

## Compilation Pipeline

```
1. Parse args → TCompilerArgs
2. Init config (registry, .env, env vars)
3. Parse PreBuild/PostBuild events from .dproj
4. Execute PreBuild event (abort on failure → prebuild_error)
5. Execute MSBuild (with /p:PreBuildEvent= /p:PostBuildEvent= to suppress native events)
6. Parse compiler output → TCompileIssue[] (dcc messages + MSBuild task errors `MSBnnnn`)
7. Enrich with source context (MSBuild errors keep their continuation lines instead)
7b. Stale output → `output_locked` when the only errors are MSBuild file-lock errors (MSB3061/3021/3027) or there are none
7c. MSBuild exit code ≠ 0 and still a pass → `error` + synthetic `MSBUILD_EXIT` issue
8. Execute PostBuild event — only after a pass (status ok/hints/warnings) and never in workspace or `--test` mode; otherwise reported as `skipped` + `reason`. A failure sets `postbuild_error`
9. Output JSON → stdout (error items only unless `--full`; counters always complete) + deterministic exit code
```

## Build Events

Build events are parsed from `.dproj` PropertyGroups with condition priority:

1. **Config+Platform** (`$(Config)=='Debug' AND $(Platform)=='Win32'`) — highest
2. **Config only** (`$(Config)=='Debug'`)
3. **Cfg_X style** (`$(Cfg_2_Win32)`, `$(Cfg_2)`, `$(Base_Win32)`, `$(Base)`)

Events are executed via a temp `.bat` file (PID-unique name) in the project directory. MSBuild's native event execution is suppressed to avoid double execution.

PostBuild rules (v1.13):

- **Runs only after a real pass.** Before v1.13 the guard was `ErrorCount = 0`, so it also ran on `output_locked` and deployed a binary that run never wrote.
- **Never in workspace mode.** Outputs are redirected under `ROOT\out`, but the event was written for the canonical tree (absolute `W:\` paths; `$(...)` macros are NOT expanded by this tool). Running it would fail or copy a slot binary into the canonical tree. `cmx-workspace build` suppresses it too.
- **Never with `--test`** (v1.14): same reason — the outputs go to a scratch folder and the event targets the real output.
- **A defined event that does not run is reported**, never dropped: `"post_build_event": {"command", "skipped": true, "reason"}`.
- **A failure is not a pass**: status `postbuild_error`, exit 1, plus a `[delphi-compiler] NOT A PASS …` line on stderr. The binary compiled, but the build the `.dproj` declares (typically a deploy copy) did not complete.

> **Note**: Custom MSBuild targets (`<Target Name="BeforeBuild">`) are NOT handled — only `<PreBuildEvent>` and `<PostBuildEvent>` property elements.

## Build Targets and Workspace Mode (v1.7)

- Default target: **`/t:build`** (incremental). `/t:rebuild` requires `--rebuild-canonical` (its Clean step can delete shared canonical DCPs).
- Workspace (cmx-workspace slot) mode — all outputs under `ROOT\out`, env-seeded `DCC_UnitSearchPath`, `--depends` provenance file, auto-translation of `W:\Packages290\...` project paths to the slot copy. Mutually exclusive with `--test` and `--rebuild-canonical`. Since v1.8 the search path prepends the slot's private baseline (`ROOT\baseline\DCP\290`, `ROOT\baseline\DCU\290`) ahead of the registry Library Path, and `baseline`/`run`/`bin` root dirs are excluded from the worktree enumeration.
- `--test` scratch: `W:\temp\compilar\<PID>` (per-process, parallel-safe).

## Workspace Resolution Ladder (v1.12)

`ROOT` no longer comes only from `--workspace=`. `TArgsParser.ResolveWorkspace`
implements the precedence ladder of
[`W:\cmx-slots\lib\MARKER-CONTRACT.md`](../../cmx-slots/lib/MARKER-CONTRACT.md)
§5.3 using the shared unit `CmxWorkspace.Detect.pas`:

```
--workspace (flag) > project path under C:\cmx-ws\sX > validated CMX_WORKSPACE > marker-walk from CWD > none
```

- Rung 2 (`project`) is immune to the WSL junction asymmetry (§4.3); rung 4 (`marker`) is a best-effort net.
- Rung 3 requires the env value to **validate** against the marker of the root it names — a raw env is only a hint.
- `invalid` (exit 2), never a silent canonical build: project/workspace slot mismatch (any source, `--workspace` included), env≠marker conflict with nothing to arbitrate it, an unusable marker, and a present-but-unvalidatable env with a `W:\`/`C:\cmx-ws\` project (residue of the pre-v1.12 session guard).
- JSON of a **result**: `workspace_source` (`flag|project|env|marker|none`) is always present; `workspace_root` when there is one; `workspace_conflict {env, marker}` when a higher rung arbitrated a divergence.
- JSON of a **fatal** (`invalid`, exit 2) caused by the ladder: same fields, so no client has to parse the prose of `error`. `workspace_source` names the rung the failure is about (`none` = no identity could be adopted: conflict, unusable marker, unvalidatable env); `workspace_conflict` carries the two slots, `{env, marker}` for the env≠marker conflict and `{project, workspace}` for the slot mismatch. Filled through `TCompilerArgs.WsFailure` (`TCmxWsFailure`, set at each failing exit of `TArgsParser`) and rendered by the `TJSONOutput.Invalid(ErrorMsg, WsFailure)` overload. An `invalid` with a **non**-workspace cause (unknown argument, project not found, …) keeps the bare `{status, version, error}` shape — no workspace field is ever invented for it.
- The unit is a **build-time** dependency only (`DCC_UnitSearchPath = ..\..\cmx-slots\lib`, plus an explicit `DCCReference`/`in` clause): the exe carries its own compiled copy and does not need `cmx-slots` at runtime.

## Command-Line Parsing (v1.12)

One pass over every argument in `TArgsParser.Parse`, no positional assumptions:

- **`--version` / `--help` are informational in ANY position** — detected by `TArgsParser.DetectInfoRequest` (called from the `.dpr` *before* `Parse`), print and exit 0 **without compiling**. Leftmost wins if both appear. `--help` emits JSON too (`TJSONOutput.Help`: usage, notes, exit codes, options table): stdout of this tool is always machine-readable.
- **Unknown argument ⇒ `invalid` (exit 2), naming it.** Before, anything unrecognized was silently dropped, so a typo like `--workpsace=ROOT` produced a *canonical* build from inside a slot.
- **The project is the first argument that is neither an option nor a legacy positional keyword** (`DEBUG`/`RELEASE`/`WIN32`/`WIN64`/`TEST`) — no longer forced to `ParamStr(1)`, so the slot guard's own `--workspace=ROOT <project>` template parses. A second non-option argument is an error.
- Single source of truth for the informational flag names: `TArgsParser.InfoFlagOf`, used by both the pre-parse scan and the parse loop (so they are never reported as unknown).

## Version Identity (v1.11)

`--version`, in any position since v1.12, prints `{"tool": "delphi-compiler", "version": "...", "cmx_ws_contract": N}` and exits 0. Every JSON output carries a `"version"` field and the exe's PE VerInfo matches. Single source of truth: `COMPILER_VERSION` in `Compilar.Types.pas` — bump it together with `CHANGELOG.md` and the dproj `VerInfo_Keys` on every release. `cmx_ws_contract` (v1.12) is `CMX_WS_CONTRACT` from the shared detection unit — compare it across tools to detect compile skew (contract §6).

## Process Exit Code (v1.9)

| Exit | Meaning |
|------|---------|
| `0` | Real pass: `status ∈ {ok, hints, warnings}` |
| `1` | Build failure: `error`, `output_locked`, `prebuild_error`, `postbuild_error` |
| `2` | `invalid` (bad arguments / project not found / slot guard) |
| `3` | `internal_error` (MSBuild could not run, unexpected exception) |

Callers key pass/fail on the exit code (or on `status`), **never** on `errors`
alone — `invalid` and `internal_error` report `errors: 0` without a successful
compile, and `output_locked` reports only the MSBuild lock error (`MSB3061`, since
v1.14) or none: the sources were not compiled either way. Since v1.14 a failed
MSBuild run is never a pass: MSBuild task errors (`MSBnnnn`) are issues, and a
non-zero MSBuild exit with no recognized error line adds a synthetic
`MSBUILD_EXIT` issue (before, `status: "ok"`/exit 0 with `exit_code: 1` in the
JSON — `T-4Y7N`). Since v1.13 `postbuild_error` also exits `1` (the
v1.9 note that it kept exit `0` described a status the code never emitted: a
failed PostBuild left `status: "ok"`, a false green).

## JSON Output Status Values

| Status | Meaning |
|--------|---------|
| `ok` | Compiled successfully, no issues |
| `hints` | Compiled successfully, only hints |
| `warnings` | Compiled successfully, warnings present |
| `error` | Compilation failed |
| `output_locked` | **NOT a successful build.** Output binary locked by another process → `/t:rebuild` Clean failed, build aborted **before compiling**, sources **NOT compiled** (`errors` is 0, or 1 for the `MSB3061` that names the locked file: it says nothing about the code). Also printed as a `[delphi-compiler] NOT A BUILD …` line on **stderr**. |
| `prebuild_error` | PreBuild event failed (compilation not attempted) |
| `postbuild_error` | Sources compiled but the PostBuild event failed — NOT a pass (exit 1) |
| `invalid` | Bad command-line arguments |
| `internal_error` | Unexpected failure |

## Building

```bash
msbuild delphi-compiler.dproj /p:Config=Release /p:Platform=Win32
```

## Usage

See [README.md](README.md) for complete usage instructions.
