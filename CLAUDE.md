# CLAUDE.md -- Project Context

## Project Overview

Architecture documentation toolkit for game engine codebases. Generates per-file and subsystem-level architecture docs using a local Ollama LLM server, with optional LSP-powered semantic analysis via clangd.

**Target Codebase:** Command & Conquer Remastered Collection source release (EA/Westwood, open-sourced 2020). Contains the original C++ game logic for Tiberian Dawn (1995) and Red Alert (1996) as shipped in the Remastered Collection DLLs, plus a C# WinForms map editor.
**LLM Server:** Ollama at `LLM_HOST:LLM_PORT` (default `192.168.1.126:11434`)
**Model:** `qwen2.5-coder:14b` (configurable via `LLM_MODEL` in `.env`)

## Directory Layout

```
repo root/
  compile_commands.json    Generated compilation database (for clangd, optional)
  architecture/            Generated output (docs, xref, diagrams)
  ArchAnalysis/            All toolkit scripts, prompts, and documentation
    .env                   Pipeline configuration (LLM server, preset, etc.)
  REDALERT/                Red Alert (1996) C++ game source  (+ WIN32LIB/ subdir)
  TIBERIANDAWN/            Tiberian Dawn (1995) C++ game source  (+ WIN32LIB/ subdir)
  CnCTDRAMapEditor/        C# WinForms map editor for both games
  CnCRemastered.sln        Solution referencing RedAlert.vcxproj + TiberianDawn.vcxproj
  CnCTDRAMapEditor.sln     Solution for the C# map editor
```

Scripts are run from the repo root: `.\ArchAnalysis\archgen_local.ps1 -Preset cnc`
The `.env` file lives in `ArchAnalysis/` (same directory as the scripts). Output goes to `architecture/` at the repo root.

## Pipeline Order

```
0 (free)   .\ArchAnalysis\serena_extract.ps1          LSP symbol data via clangd (optional)
1          .\ArchAnalysis\archgen_local.ps1            Per-file .md docs
2 (free)   .\ArchAnalysis\archxref.ps1                Cross-reference index
3 (free)   .\ArchAnalysis\archgraph.ps1               Mermaid call graph diagrams
4          .\ArchAnalysis\arch_overview_local.ps1      Subsystem architecture overview
4b (free)  .\ArchAnalysis\archpass2_context.ps1        Per-file targeted context
5          .\ArchAnalysis\archpass2_local.ps1          Selective re-analysis
```

## Key Configuration (.env in ArchAnalysis/)

- `LLM_HOST` and `LLM_PORT` -- Ollama server address (default `192.168.1.126:11434`)
- `LLM_MODEL` -- model name (default `qwen2.5-coder:14b`)
- `LLM_TEMPERATURE`, `LLM_MAX_TOKENS`, `LLM_TIMEOUT` -- inference parameters
- `PRESET=cnc` for the Remastered Collection codebase (alias of `generals`/`sage`)
- `INCLUDE_EXT_REGEX` / `EXCLUDE_DIRS_REGEX` -- preset overrides. Currently extended with `.cs` (for `CnCTDRAMapEditor/`) and `bin|obj|Steamworks\.NET` excludes.
- `MAX_FILE_LINES=800` -- source truncation for limited context window
- `SKIP_TRIVIAL=1` -- skip generated/trivial files with stub docs
- `#Subsections begin` / `#Subsections end` block -- lists subdirectories for `ArchPipeline.py` to process in sequence. Currently: `REDALERT`, `TIBERIANDAWN`, `CnCTDRAMapEditor`. Comment lines (e.g. `# 530 files`) are ignored by the parser.

## Architecture

- All scripts and prompts live in `ArchAnalysis/`
- Scripts dot-source `llm_common.ps1` (from `$PSScriptRoot`) for shared functions
- Prompt `.txt` files are loaded from `$PSScriptRoot` (same directory as scripts)
- `.env` is read from `$PSScriptRoot` (same directory as the scripts)
- Single-threaded LLM processing (GPU handles one inference at a time)
- Text-processing scripts (`archxref.ps1`, `archgraph.ps1`, `archpass2_context.ps1`) have no LLM dependency

## clangd / LSP (Optional)

- Generate `compile_commands.json` via: `python ArchAnalysis\generate_compile_commands.py`
- The generator discovers build artifacts in this order: (1) an existing `compile_commands.json`, (2) `.vcxproj` / `.vcproj` / `.dsp`, (3) delegate to `cmake` / `meson` / `ninja` / `bazel` if their config files are at the root (stops and prints an install URL if the required tool is missing).
- For this repo it parses `REDALERT/RedAlert.vcxproj` and `TIBERIANDAWN/TiberianDawn.vcxproj` directly (486 total translation units). The `CnCTDRAMapEditor/` is C# and is skipped (clangd is C++-only).
- clangd on VS Community Edition: `"C:\Program Files\Microsoft Visual Studio\18\Community\VC\Tools\Llvm\x64\bin\clangd.exe"`
- No separate index-building step needed -- `serena_extract.ps1` spawns clangd which builds the index on-the-fly (first run is slower)
- Index cached at `.cache/clangd/index/` for faster subsequent runs
- `serena_extract.ps1` produces `.serena_context.txt` files used by `archgen_local.ps1`

## Documentation Files (in ArchAnalysis/)

- `Setup.md` -- Setup and usage guide
- `Instructions.md` -- CLI reference for every script
- `Quickstart.md` -- Condensed reference
- `FileReference.md` -- Index of all files
- `LLMArchitecture.md` -- Local LLM pipeline design plan
- `Optimizations.md` -- Context optimization strategies

## Presets

Defined in `llm_common.ps1`. Use `-Preset` flag or `PRESET` in `.env`.

| Preset                       | Description                                                        |
|------------------------------|--------------------------------------------------------------------|
| `generals` / `cnc` / `sage` | C&C codebases: Generals/Zero Hour (SAGE) and TD/RA Remastered src |
| `quake` / `doom` / `idtech` | id Software / Quake-family                                         |
| `unreal` / `ue4` / `ue5`   | Unreal Engine                      |
| `godot`                      | Godot (C++/GDScript/C#)           |
| `unity`                      | Unity (C#/shaders)                 |
| `source` / `valve`          | Source Engine                      |
| `rust`                       | Rust engines (Bevy, etc.)          |
