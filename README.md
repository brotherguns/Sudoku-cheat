# SudokuSolver Theos Tweak
Auto-solver + runtime memory dumper for Easybrain Sudoku.com (iOS, Unity IL2CPP)

## Build

```bash
# Set up Theos if you haven't
export THEOS=/opt/theos   # or wherever yours is

cd SudokuSolver
make package FINALPACKAGE=1
# .deb goes to packages/
```

## Install
Sideload the .deb via your jailbreak package manager (Sileo, Zebra) or:
```bash
scp packages/*.deb mobile@<device-ip>:/var/mobile/
ssh mobile@<device-ip>
sudo dpkg -i /var/mobile/*.deb
sudo killall -9 Sudoku
```

## Usage

### SOLVE button (green)
1. Open Sudoku.com, start a puzzle
2. Tap the green **SOLVE** button (bottom-right)

Flow:
1. Queries the SQLite `gameState` table for the `solution` column (fastest)
2. Falls back to backtracking solver using the given cells
3. Injects answers by simulating taps on the cell grid → number pad

### DUMP button (blue)
1. Open any puzzle so the game is fully initialized
2. Tap the blue **DUMP** button
3. Wait for the "Memory Dump Done" alert
4. Pull the dump off device:

```bash
scp -r mobile@<device-ip>:/var/mobile/Documents/SudokuDump/ ./dump/
python3 analyze_dump.py dump/dump_log.txt
```

The script will print any found method RVAs and generate `#define` lines to paste into `MemDumper.h`.

## Why dump?

The binary uses **chained fixups** (iOS 16+ dyld format) so IL2CPP pointers
can't be found statically — they're only resolved once the app is running.
The DUMP button captures those resolved pointers from live memory and logs
their RVAs (ASLR-removed), which you can then hard-code for a faster, more
reliable hook path.

## File layout
```
SudokuSolver/
├── Tweak.x          # Main hook file
├── Solver.h         # Pure C backtracking sudoku solver
├── MemDumper.h      # Runtime memory dumper
├── analyze_dump.py  # Post-process the dump on your PC
├── Makefile
├── control
└── SudokuSolver.plist
```
