# SudokuSolver

Tweak for **Easybrain Sudoku** (`com.easybrain.sudoku`).

## Usage

| Action | Result |
|--------|--------|
| Tap ⚡ | Solve the current puzzle (patches the save DB) |
| Long-press ⚡ | Dump decrypted binaries + metadata → `Documents/SudokuSolver/` |
| Drag ⚡ | Reposition the button |

After tapping ⚡, **force-close and reopen** the app — the game reads save data at launch, so a full kill+relaunch is required to see the board filled in.

## How it works (v4)

The game stores puzzle state in `Library/Application Support/save/database.sqlite` in a table called `saved_progress`. Each row has two binary blobs:

- **`level`** — puzzle definition. Contains two packed 81×uint32 LE grids: the **solution** (values 1–9, no zeros) and the **original puzzle** (zeros = empty cells).
- **`data`** — current game state. Contains a packed 81×uint32 LE grid of the player's current cell values.

Tapping ⚡ reads the most recent `saved_progress` row, byte-scans the `level` blob for the solution grid, overwrites the matching grid in the `data` blob, and writes it back.

## Requirements

- Jailbroken iOS 15+ (rootless or rootful)
- Substrate / Substitute / libhooker

## Building

```bash
make package FINALPACKAGE=1 THEOS_PACKAGE_SCHEME=rootless  # rootless
make clean && make package FINALPACKAGE=1                   # rootful
```

Or push to `main` and grab the `.deb` from the GitHub Actions artifact.
