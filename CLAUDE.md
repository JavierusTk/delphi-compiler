# Compilar

Source code for `delphi-compiler.exe` - the Delphi compilation wrapper with JSON output.

## Project Files

| File | Purpose |
|------|---------|
| `delphi-compiler.dpr` | Main project file |
| `delphi-compiler.dproj` | Delphi project settings |

## Source Units

| Unit | Purpose |
|------|---------|
| `Compilar.Args.pas` | Command-line argument parsing |
| `Compilar.Context.pas` | Source code context extraction for errors |
| `Compilar.Lookup.pas` | Symbol lookup integration for undeclared identifiers |
| `Compilar.MSBuild.pas` | MSBuild invocation wrapper |
| `Compilar.Output.pas` | JSON output formatting |
| `Compilar.Parser.pas` | Compiler output parsing |
| `Compilar.PathUtils.pas` | Path manipulation utilities |
| `Compilar.Types.pas` | Type definitions |

## Subdirectories

| Directory | Description |
|-----------|-------------|
| `antiguo/` | Legacy versions (historical reference) |

## Building

```bash
# From IDE or command line
msbuild delphi-compiler.dproj /p:Config=Release
```

Output: `delphi-compiler.exe` in Tools/ parent directory.

## Usage

See [parent Tools/CLAUDE.md](../CLAUDE.md) for usage instructions.
