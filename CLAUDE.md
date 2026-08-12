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
6. Parse compiler output → TCompileIssue[]
7. Enrich with source context
8. Execute PostBuild event (only if no errors)
9. Output JSON → stdout (error items only unless `--full`; counters always complete) + deterministic exit code
```

## Build Events

Build events are parsed from `.dproj` PropertyGroups with condition priority:

1. **Config+Platform** (`$(Config)=='Debug' AND $(Platform)=='Win32'`) — highest
2. **Config only** (`$(Config)=='Debug'`)
3. **Cfg_X style** (`$(Cfg_2_Win32)`, `$(Cfg_2)`, `$(Base_Win32)`, `$(Base)`)

Events are executed via a temp `.bat` file (PID-unique name) in the project directory. MSBuild's native event execution is suppressed to avoid double execution.

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
- JSON: `workspace_source` (`flag|project|env|marker|none`) is always present; `workspace_root` when there is one; `workspace_conflict {env, marker}` when a higher rung arbitrated a divergence.
- The unit is a **build-time** dependency only (`DCC_UnitSearchPath = ..\..\cmx-slots\lib`, plus an explicit `DCCReference`/`in` clause): the exe carries its own compiled copy and does not need `cmx-slots` at runtime.

## Version Identity (v1.11)

`--version` as sole/first argument prints `{"tool": "delphi-compiler", "version": "...", "cmx_ws_contract": N}` and exits 0. Every JSON output carries a `"version"` field and the exe's PE VerInfo matches. Single source of truth: `COMPILER_VERSION` in `Compilar.Types.pas` — bump it together with `CHANGELOG.md` and the dproj `VerInfo_Keys` on every release. `cmx_ws_contract` (v1.12) is `CMX_WS_CONTRACT` from the shared detection unit — compare it across tools to detect compile skew (contract §6).

## Process Exit Code (v1.9)

| Exit | Meaning |
|------|---------|
| `0` | Real pass: `status ∈ {ok, hints, warnings}` |
| `1` | Build failure: `error`, `output_locked`, `prebuild_error` |
| `2` | `invalid` (bad arguments / project not found / slot guard) |
| `3` | `internal_error` (MSBuild could not run, unexpected exception) |

Callers key pass/fail on the exit code (or on `status`), **never** on `errors`
alone — `output_locked`, `invalid` and `internal_error` all report `errors: 0`
without a successful compile. A `postbuild_error` after a clean compile keeps
exit `0` (the binary is good; the event result is in the JSON).

## JSON Output Status Values

| Status | Meaning |
|--------|---------|
| `ok` | Compiled successfully, no issues |
| `hints` | Compiled successfully, only hints |
| `warnings` | Compiled successfully, warnings present |
| `error` | Compilation failed |
| `output_locked` | **NOT a successful build.** Output binary locked by another process → `/t:rebuild` Clean failed, build aborted **before compiling**, sources **NOT compiled** (`errors:0` does not mean the code compiles). Also printed as a `[delphi-compiler] NOT A BUILD …` line on **stderr**. |
| `prebuild_error` | PreBuild event failed (compilation not attempted) |
| `invalid` | Bad command-line arguments |
| `internal_error` | Unexpected failure |

## Building

```bash
msbuild delphi-compiler.dproj /p:Config=Release /p:Platform=Win32
```

## Usage

See [README.md](README.md) for complete usage instructions.
