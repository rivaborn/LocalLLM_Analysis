# Instructions for Using ArchPipeline.py and test_archpipeline.py

## Overview

This document provides instructions on how to use the `ArchPipeline.py` script for orchestrating the architecture analysis pipeline and how to run its corresponding unit tests using `test_archpipeline.py`.

## Prerequisites

1. **Python 3.12+**: Ensure you have Python 3.12 or a later version installed.
2. **Dependencies**:
   - No external dependencies are required beyond the standard library.
   - For testing, ensure `pytest` is installed (`pip install pytest`).

## Directory Structure

Ensure your project directory has the following structure:

```
C:\Coding\EA\CnC_Remastered_Collection\
│
├── REDALERT\                 C&C Red Alert (1996) source
├── TIBERIANDAWN\             C&C Tiberian Dawn (1995) source
├── CnCTDRAMapEditor\         C# WinForms map editor
│
└── ArchAnalysis\
    ├── ArchPipeline.py
    ├── test_archpipeline.py
    ├── .env                  Pipeline configuration (lives here, not repo root)
    └── ...
```

## Usage of ArchPipeline.py

### 1. Running the Pipeline

To run the architecture analysis pipeline, execute `ArchPipeline.py` with the desired options.

#### Basic Command

```powershell
python ArchAnalysis\ArchPipeline.py
```

#### Options

- **--dry-run**: Simulate the pipeline without executing any commands.
  
  ```powershell
  python ArchAnalysis\ArchPipeline.py --dry-run
  ```

- **--start-from N**: Start the pipeline from a specific subsection (1-based index).
  
  ```powershell
  python ArchAnalysis\ArchPipeline.py --start-from 3
  ```

- **--skip-lsp**: Skip the LSP extraction steps.
  
  ```powershell
  python ArchAnalysis\ArchPipeline.py --skip-lsp
  ```

### 2. Example Commands

- **Full Run**:
  
  ```powershell
  python ArchAnalysis\ArchPipeline.py
  ```

- **Dry Run Starting from Subsection 3**:
  
  ```powershell
  python ArchAnalysis\ArchPipeline.py --dry-run --start-from 3
  ```

- **Skip LSP Steps**:
  
  ```powershell
  python ArchAnalysis\ArchPipeline.py --skip-lsp
  ```

## Usage of test_archpipeline.py

### Running Tests

To run the unit tests for `ArchPipeline.py`, use `pytest`.

#### Basic Command

```powershell
python -m pytest ArchAnalysis\test_archpipeline.py -v
```

- **-v**: Verbose mode to see detailed test output.

### Example Commands

- **Run All Tests**:
  
  ```powershell
  python -m pytest ArchAnalysis\test_archpipeline.py -v
  ```

## Notes

- Ensure `ArchAnalysis/.env` is correctly formatted with the `#Subsections begin` and `#Subsections end` markers. Comment lines inside the block (e.g. `# 530 files`) are ignored by the parser.
- The pipeline creates `architecture/` at the repository root; it does not need to exist beforehand.

## Troubleshooting

- **FileNotFoundError**: Verify `ArchAnalysis/.env` exists (not the repo root).
- **subprocess.CalledProcessError**: Check the logs for detailed error messages from the failed commands.

For any issues or further assistance, please refer to the plan document or contact the development team.
