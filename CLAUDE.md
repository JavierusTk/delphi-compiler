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
| `Compilar.Args.pas` | Command-line argument parsing |
| `Compilar.BuildEvents.pas` | PreBuild/PostBuild event parsing and execution |
| `Compilar.Config.pas` | Configuration (.env, registry, auto-detection) |
| `Compilar.Context.pas` | Source code context extraction for errors |
| `Compilar.Lookup.pas` | Symbol lookup integration for undeclared identifiers |
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
7. Enrich with source context + symbol lookup
8. Execute PostBuild event (only if no errors)
9. Output JSON → stdout
```

## Build Events

Build events are parsed from `.dproj` PropertyGroups with condition priority:

1. **Config+Platform** (`$(Config)=='Debug' AND $(Platform)=='Win32'`) — highest
2. **Config only** (`$(Config)=='Debug'`)
3. **Cfg_X style** (`$(Cfg_2_Win32)`, `$(Cfg_2)`, `$(Base_Win32)`, `$(Base)`)

Events are executed via a temp `.bat` file (PID-unique name) in the project directory. MSBuild's native event execution is suppressed to avoid double execution.

> **Note**: Custom MSBuild targets (`<Target Name="BeforeBuild">`) are NOT handled — only `<PreBuildEvent>` and `<PostBuildEvent>` property elements.

## JSON Output Status Values

| Status | Meaning |
|--------|---------|
| `ok` | Compiled successfully, no issues |
| `hints` | Compiled successfully, only hints |
| `warnings` | Compiled successfully, warnings present |
| `error` | Compilation failed |
| `output_locked` | Compiled OK but output file locked by another process |
| `prebuild_error` | PreBuild event failed (compilation not attempted) |
| `invalid` | Bad command-line arguments |
| `internal_error` | Unexpected failure |

## Building

```bash
msbuild delphi-compiler.dproj /p:Config=Release /p:Platform=Win32
```

## Usage

See [README.md](README.md) for complete usage instructions.
