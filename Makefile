INSTALL_TARGET_PROCESSES = Sudoku
ARCHS = arm64
TARGET = iphone:clang:latest:15.0

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = SudokuSolver

SudokuSolver_FILES = Tweak.x
SudokuSolver_CFLAGS = -fobjc-arc -Wno-deprecated-declarations
SudokuSolver_FRAMEWORKS = UIKit CoreFoundation
SudokuSolver_LIBRARIES = sqlite3

include $(THEOS_MAKE_PATH)/tweak.mk
