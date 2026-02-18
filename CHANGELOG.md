# Changelog

## v1.1 - 2026-02-18

- Add `output_locked` status when compilation succeeds but BPL/EXE is locked by another process
- Previously `status: "ok"` + `exit_code: 1` were contradictory signals; now `status: "output_locked"` disambiguates
- Preserve `OutputPath` in JSON when output is stale (was being cleared to empty)
- `OutputMessage` is now a record field instead of a hardcoded string

## v1.0 - 2025-06-07

- Initial release: Delphi compilation wrapper with JSON output
- MSBuild invocation with configurable Debug/Release and Win32/Win64
- Compiler output parsing (errors, warnings, hints)
- Source code context extraction around errors
- Symbol lookup integration for undeclared identifiers
- Output staleness detection
