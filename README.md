# SudokuSolver

Auto-solve tweak for **Easybrain Sudoku** (`com.easybrain.sudoku`) on iOS.

## How it works

A floating ⚡ button appears in-game. Tap it to auto-fill every empty cell with the correct answer.

### Primary: IL2CPP runtime solve (instant)
- Resolves Unity's `il2cpp_*` API exports via `dlsym` at runtime
- Hooks `il2cpp_runtime_invoke` to capture the active `BoardModelCells` instance
- Calls `GetCellAnswer(i)` → `SetCell(i, answer)` for every mutable cell
- Works instantly without reloading

### Fallback: SQLite DB patch (requires reload)
- Hooks `sqlite3_open` to auto-detect the game database
- Reads the `solution` column from the `SudokuGame` table
- Writes it into the `cells` column
- You need to back out and re-enter the level for it to take effect

## Building

### GitHub Actions
Push to `main` and the workflow builds both rootless and rootful `.deb` packages automatically.

### Local
```
export THEOS=~/theos
make package
```

## Install
- **Rootless jailbreak (Dopamine etc):** use the rootless `.deb`
- **Rootful jailbreak (unc0ver etc):** use the rootful `.deb`
- **TrollStore / Sideload:** inject the dylib with your preferred method

## Target app info
| | |
|---|---|
| App | Sudoku.com by Easybrain |
| Bundle ID | `com.easybrain.sudoku` |
| Engine | Unity IL2CPP arm64 |
| Metadata version | 31 |
| Key class | `BoardModelCells` (Sudoku.Game.Mechanics.Base) |
