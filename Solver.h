#pragma once
#include <string.h>
#include <stdint.h>

// Pure C backtracking solver for 9x9 sudoku
// board[row][col] = 1-9 or 0 for empty

static int _sudoku_valid(int board[9][9], int row, int col, int num) {
    for (int i = 0; i < 9; i++) {
        if (board[row][i] == num) return 0;
        if (board[i][col] == num) return 0;
        int br = (row / 3) * 3 + i / 3;
        int bc = (col / 3) * 3 + i % 3;
        if (board[br][bc] == num) return 0;
    }
    return 1;
}

static int sudoku_solve(int board[9][9]) {
    for (int row = 0; row < 9; row++) {
        for (int col = 0; col < 9; col++) {
            if (board[row][col] == 0) {
                for (int num = 1; num <= 9; num++) {
                    if (_sudoku_valid(board, row, col, num)) {
                        board[row][col] = num;
                        if (sudoku_solve(board)) return 1;
                        board[row][col] = 0;
                    }
                }
                return 0;
            }
        }
    }
    return 1; // solved
}
