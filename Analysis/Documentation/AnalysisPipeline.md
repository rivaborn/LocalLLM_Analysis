# AnalysisPipeline.py

Single-mode orchestrator that runs the full architecture-doc pipeline across every subsection listed in `Common/.env`.

## What it does

For each `<subsection>` in the `#Subsections begin / #Subsections end` block in `Common/.env`, the orchestrator:

1. Runs the six-step pipeline against `<repo_root>/<subsection>/`
2. Renames the resulting `<repo_root>/architecture/` folder to `<repo_root>/N. <subsection_sanitized>/` (where `N` is the 1-indexed position in the subsection list)
3. Moves on to the next subsection

Before the per-subsection loop, it runs two **one-time setup steps** (LSP scaffolding) unless `--skip-lsp` is passed.

## Invocation

```
python LocalLLM_Analysis\Analysis\AnalysisPipeline.py [OPTIONS]
```

**Always launch from the C&C repo root** — the orchestrator uses `Path.cwd()` as the repo root and passes that as `cwd=` to every subprocess. The PS1 worker scripts use the same convention (`(Get-Location).Path`), so the source dirs (`REDALERT/`, `TIBERIANDAWN/`, `CnCTDRAMapEditor/`) must be discoverable as direct children of the CWD.

The orchestrator script's location is unrelated to where you run it — it always finds `.env` at `<script_dir>/../Common/.env` and finds worker scripts at `<script_dir>/<script>.ps1`.

## CLI Options

| Flag             | Type    | Default | Effect                                                                                                                                                                    |
| ---------------- | ------- | ------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `--dry-run`      | flag    | off     | Log every command that would run, but skip execution. Includes step renames. Use this to preview the full plan before committing GPU time.                                |
| `--start-from N` | int ≥ 1 | `1`     | Skip subsections `1..N-1`. Subsection numbering is 1-indexed and matches the order in `.env`. Errors out if `N` exceeds the subsection count.                             |
| `--skip-lsp`     | flag    | off     | Skip the one-time setup steps (`generate_compile_commands.py` + `serena_extract.ps1`). Use after the LSP index is already built, or when running on a non-C++ subsection. |
| `-h` / `--help`  | flag    | —       | Print argparse help and exit.                                                                                                                                             |

There is no flag for choosing a subsection by name, model, preset, or env file — all of that is driven by `Common/.env`.

## Pipeline Steps (per subsection)

Defined in the `PIPELINE_STEPS` list at the top of `AnalysisPipeline.py`. All six run unconditionally per subsection in this order:

| # | Step                  | Script                                                       | Notes                                                                                                                                                |
| - | --------------------- | ------------------------------------------------------------ | ---------------------------------------------------------------------------------------------------------------------------------------------------- |
| 1 | Per-file docs         | `archgen_local.ps1 -TargetDir <subsection> -Preset generals` | LLM call. The `-Preset generals` arg is hardcoded in the PIPELINE_STEPS list — change it there if you want a different preset for orchestrated runs. |
| 2 | Cross-reference index | `archxref.ps1`                                               | Pure text, no LLM.                                                                                                                                   |
| 3 | Mermaid diagrams      | `archgraph.ps1`                                              | Pure text, no LLM.                                                                                                                                   |
| 4 | Architecture overview | `arch_overview_local.ps1`                                    | LLM call.                                                                                                                                            |
| 5 | Pass 2 context        | `archpass2_context.ps1`                                      | Pure text, no LLM.                                                                                                                                   |
| 6 | Pass 2 analysis       | `archpass2_local.ps1`                                        | LLM call.                                                                                                                                            |

Only step 1 receives `-TargetDir`; the others operate on whatever `architecture/` already contains.

After step 6, the orchestrator runs `shutil.move("architecture", f"{i}. {sanitize_subsection_name(subsection)}")` at the repo root.

## One-time setup steps

Run before the first subsection (skipped entirely if `--skip-lsp`):

1. `python generate_compile_commands.py` — produces `compile_commands.json` for clangd
2. `powershell ... serena_extract.ps1` — runs clangd to produce `.serena_context.txt` files

If you've already generated these (or you're running on a non-C++ subsection like `CnCTDRAMapEditor/`), pass `--skip-lsp` to bypass them.

## Resume / skip behaviour

The orchestrator has two independent ways to skip a subsection:

1. **`--start-from N`** — explicitly skips subsections before index `N`.
2. **Auto-skip on completion** — for each remaining subsection, the orchestrator checks `repo_root` for any directory matching `^\d+\.\s+...<sanitized_subsection>$`. If found, that subsection is treated as already processed and skipped.

This means if a previous run completed `1. REDALERT` and `2. TIBERIANDAWN` but failed on `CnCTDRAMapEditor`, you can simply re-run with no flags and it will resume at subsection 3.

A per-subsection failure that produces no `architecture/` folder (e.g. step 1 crashes early) leaves nothing to skip-detect, so re-running picks up at the failed subsection. A failure *after* renaming has been performed for prior subsections is fine — those completed dirs are just markers.

## Configuration source

Everything lives in `Common/.env`:

- **Subsections** — the lines between `#Subsections begin` and `#Subsections end`. Comment lines (starting with `#`) and blanks are ignored. Backslashes are preserved (`Generals\Code\GameEngine\Source\Common` is a valid subsection path).
- **LLM endpoint, model, context budgets, thinking mode** — read by the worker PS1 scripts via `Common/llm_common.ps1`. AnalysisPipeline.py itself does not read these; it only reads the subsections block.
- **Preset, file filters** — also read by the worker PS1s.

Example subsection block (from the C&C `.env`):

```
#Subsections begin
REDALERT
# 530 files at root + 79 in WIN32LIB subdir
TIBERIANDAWN
# 307 files at root + 82 in WIN32LIB subdir
CnCTDRAMapEditor
# 257 C# files
#Subsections end
```

Resulting renamed output folders after a clean run: `1. REDALERT/`, `2. TIBERIANDAWN/`, `3. CnCTDRAMapEditor/`.

## Output

- **Per-subsection docs** — `<repo_root>/N. <subsection>/` (after rename)
- **Pipeline log** — `<script_dir>/pipeline.log` (appended; never truncated). Contains every command line, every timestamp, full DEBUG log, and any error tails.
- **Console** — colored progress to stderr; `PROGRESS: x/y` lines from worker scripts are rewritten in place via `\r` so they don't spam the scrollback.

## Process model

- **Subprocess streaming** — `subprocess.Popen` with `stdout=PIPE, stderr=None`. stdout is read line-by-line and re-emitted; stderr passes through directly so PowerShell's color codes survive.
- **Working directory** — every subprocess inherits `cwd=str(repo_root)`.
- **Failure handling** — non-zero exit code raises `CalledProcessError`. The orchestrator catches it in `main()`, logs the last 50 lines of output, and exits with code 1.
- **Cancellation** — Ctrl+C interrupts the current subprocess. The PS1 workers also support Ctrl+Q for graceful exit (handled inside the worker via `Test-CancelKey`).

## Common invocations

**Full clean run from the C&C repo root:**
```
cd C:\Path\To\CnC_Remastered
python C:\Coding\LocalLLM_Analysis\Analysis\AnalysisPipeline.py
```

**Preview the plan without spending GPU time:**
```
python C:\Coding\LocalLLM_Analysis\Analysis\AnalysisPipeline.py --dry-run
```

**Skip LSP setup (you already have `compile_commands.json` and `.serena_context.txt` files):**
```
python C:\Coding\LocalLLM_Analysis\Analysis\AnalysisPipeline.py --skip-lsp
```

**Resume after a failed run on subsection 3 (skip-detect handles 1 and 2, but you want to be explicit):**
```
python C:\Coding\LocalLLM_Analysis\Analysis\AnalysisPipeline.py --start-from 3 --skip-lsp
```

**Re-run only the C# editor subsection (it's third in the list):**
```
# Delete the existing "3. CnCTDRAMapEditor/" first, then:
python C:\Coding\LocalLLM_Analysis\Analysis\AnalysisPipeline.py --start-from 3 --skip-lsp
```

## Exit codes

| Code | Meaning                                                                                                            |
| ---- | ------------------------------------------------------------------------------------------------------------------ |
| 0    | All subsections completed (or auto-skipped)                                                                        |
| 1    | A worker subprocess exited non-zero, OR `--start-from` exceeds subsection count, OR no subsections found in `.env` |
| 2    | Unexpected exception (e.g. missing `.env`, missing `architecture/` at rename time, file-system errors)             |

## Customizing the pipeline

The pipeline order, the `-Preset` value passed to step 1, and which steps use `-TargetDir` are all controlled by the `PIPELINE_STEPS` list at the top of `AnalysisPipeline.py`. To change behavior:

- **Reorder** — swap entries in the list
- **Skip a step permanently** — comment out its `PipelineStep(...)` line
- **Pass extra args to a step** — append to its `args` list (e.g. `["-Preset", "cnc", "-Clean"]`)
- **Add a new step** — append a `PipelineStep(name, script, args, use_target_dir, is_powershell)` entry; if the script is Python set `is_powershell=False`

There is no CLI flag for these — the pipeline shape is intentionally fixed in code so all subsections are processed identically.

## Related

- `Common/.env` — the only config file the orchestrator reads
- `Common/llm_common.ps1` — shared module the worker scripts use (irrelevant to the orchestrator itself)
- The 6 worker scripts: `archgen_local.ps1`, `archxref.ps1`, `archgraph.ps1`, `arch_overview_local.ps1`, `archpass2_context.ps1`, `archpass2_local.ps1`
- The 2 LSP setup scripts: `generate_compile_commands.py`, `serena_extract.ps1`
