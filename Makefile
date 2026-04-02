THEOS_PACKAGE_SCHEME = rootless
TARGET := iphone:clang:18.5:14.0
ARCHS = arm64

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = SudokuSolver

SudokuSolver_FILES = Tweak.x
SudokuSolver_CFLAGS = -fobjc-arc -Wno-deprecated-declarations
SudokuSolver_CCFLAGS = -std=c++17
SudokuSolver_FRAMEWORKS = UIKit Foundation
SudokuSolver_LIBRARIES = sqlite3
SudokuSolver_PRIVATE_FRAMEWORKS =

# Rootless install path
SudokuSolver_INSTALL_PATH = /var/jb/Library/MobileSubstrate/DynamicLibraries

include $(THEOS_MAKE_PATH)/tweak.mk
