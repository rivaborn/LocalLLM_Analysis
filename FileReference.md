# Architecture Analysis Toolkit -- File Reference

All toolkit files live in the `ArchAnalysis/` directory. Scripts are run from the repo root.

## Pipeline Scripts

### llm_common.ps1 -- Shared Helper Module
Dot-sourced by all `*_local.ps1` scripts. Provides `Invoke-LocalLLM` (Ollama API client with retry), `Get-LLMEndpoint` (builds URL from `LLM_HOST`/`LLM_PORT`), and shared utilities: `Read-EnvFile`, `Get-SHA1`, `Get-Preset`, `Get-FenceLang`, `Test-TrivialFile`, `Write-TrivialStub`, `Get-OutputBudget`, `Truncate-Source`, `Load-CompressedLSP`, `Show-SimpleProgress`.

### archgen_local.ps1 -- Pass 1: Per-File Documentation
Generates one `.md` doc per source file via local LLM. Synchronous. Truncates source to `MAX_FILE_LINES`, loads compressed LSP symbols when available, adaptive output budget (300-800 tokens). SHA1 hash DB for resumability, trivial file skipping, progress display with ETA.

### archxref.ps1 -- Cross-Reference Index
Parses Pass 1 docs and builds cross-reference index: function-to-file mappings, call graph edges, global state ownership, header dependencies, subsystem interfaces. Pure text processing -- no LLM calls.

### archgraph.ps1 -- Call Graph & Dependency Diagrams
Generates Mermaid diagrams from Pass 1 docs: function-level call graphs grouped by subsystem, subsystem dependency diagrams. No LLM calls.

### arch_overview_local.ps1 -- Architecture Overview
Synthesizes per-file docs into subsystem-level overview. Chunks for large codebases (threshold 400 lines). Extracts only headings + purpose for token efficiency. Two-tier: per-subsystem overviews then final synthesis.

### archpass2_context.ps1 -- Targeted Pass 2 Context
Extracts relevant architecture overview paragraphs and xref entries per file. Zero LLM calls, runs in seconds.

### archpass2_local.ps1 -- Pass 2: Selective Re-Analysis
Re-analyzes files with architecture context. Scoring (`-Top N`, `-ScoreOnly`), targeted context, SHA1 hash DB. Source capped at 300 lines.

### serena_extract.ps1 -- LSP Context Extraction (Optional)
Orchestrates adaptive parallel LSP extraction via clangd. Zero LLM calls. Auto-scales workers based on RAM. Requires `compile_commands.json` + clangd index.

### serena_extract.py -- Adaptive Parallel LSP Client
Python script that spawns clangd processes via LSP JSON-RPC. Shared queue, RAM monitoring, crash recovery, incremental support, PCH cleanup.

### generate_compile_commands.py -- Compilation Database Generator
Generates `compile_commands.json` for clangd by discovering whichever build artifacts are available. Resolution order: (1) an existing `compile_commands.json` anywhere under the root is copied verbatim; (2) native Visual Studio / Visual C++ project files are parsed directly -- `.vcxproj` (MSBuild), `.vcproj` (VS 2002-2008), `.dsp` (VC6) -- extracting per-project `AdditionalIncludeDirectories`, `PreprocessorDefinitions`, and source lists; `.sln` files are reported for visibility; (3) if no native projects are found, the script delegates to `cmake` / `meson` / `ninja` / `bazel` when their config files sit at the repo root, stopping with an install URL if the required tool is not on `PATH`. On duplicate source paths, `.vcxproj` > `.vcproj` > `.dsp`.

## Prompt Files

### archgen_local_prompt.txt -- Pass 1 Prompt
Per-file analysis targeting ~400-600 token output. Bullet-point format.

### arch_overview_local_prompt.txt -- Overview Prompt
Architecture overview requesting ~800 token output.

### archpass2_local_prompt.txt -- Pass 2 Prompt
Cross-cutting enrichment targeting ~400 token output.

## Configuration

### .env (in ArchAnalysis/, alongside the scripts)
LLM settings: `LLM_HOST`, `LLM_PORT`, `LLM_MODEL`, `LLM_TEMPERATURE`, `LLM_MAX_TOKENS`, `LLM_TIMEOUT`. Pipeline settings: `PRESET`, `CODEBASE_DESC`, `MAX_FILE_LINES`, `SKIP_TRIVIAL`, `INCLUDE_EXT_REGEX`, `EXCLUDE_DIRS_REGEX`. Also contains a `#Subsections begin` / `#Subsections end` block listing subdirectories for `ArchPipeline.py`, with optional file-count annotations (comment lines are ignored by the parser).

### .clangd (at repo root, optional)
Controls clangd behavior for LSP extraction. Disables diagnostics, enables background indexing.

## Documentation (in ArchAnalysis/)

| File                 | Description                                   |
|----------------------|-----------------------------------------------|
| `Setup.md`           | Setup and usage guide                         |
| `Instructions.md`    | CLI reference for every script                |
| `Quickstart.md`      | Condensed reference                           |
| `LLMArchitecture.md` | Local LLM pipeline design plan                |
| `Optimizations.md`   | Context optimization strategies               |
| `SerenaFinal.md`     | Technical reference (LSP, lessons learned)     |
| `FileReference.md`   | This file                                     |
| `CLAUDE.md`          | Project context for AI assistants             |

## Other Directories

| Directory                    | Description                                         |
|------------------------------|-----------------------------------------------------|
| `Dep/`                       | Deprecated files from earlier Claude-based pipeline |
| `architecture/`              | Generated output (docs, xref, diagrams, state)      |
| `ArchAnalysis/.serena_context/` | LSP extraction output (optional)                 |
| `.cache/clangd/`             | clangd persistent index (optional)                  |
