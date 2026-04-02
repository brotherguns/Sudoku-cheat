// SudokuSolver — Easybrain Sudoku.com iOS auto-solver tweak
// Supports:
//   1. Runtime IL2CPP API resolution (if symbols survive stripping)
//   2. SQLite hook (most reliable — reads solution column from DB)
//   3. Pure backtracking solver fallback (solves from given cells)
//   4. Memory dumper — dumps DATA sections to disk for offline RVA analysis

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <sqlite3.h>
#import <dlfcn.h>

#include "Solver.h"
#include "MemDumper.h"

// ─── Globals ────────────────────────────────────────────────────────────────

static int  g_solution[9][9];   // solution grid (1-9), 0 = unknown
static int  g_given[9][9];      // given cells from puzzle
static BOOL g_solution_ready = NO;
static sqlite3 *g_db = NULL;    // cached DB handle
static BOOL g_dump_done = NO;

// Floating button tags
#define TAG_SOLVE  0x50DE
#define TAG_DUMP   0x50DF

// ─── IL2CPP Runtime Types (opaque structs, access by pointer offset) ────────

typedef struct Il2CppObject { void *klass; void *monitor; } Il2CppObject;

// IL2CPP API function pointers (resolved at runtime)
static void* (*_il2cpp_domain_get)(void) = NULL;
static void* (*_il2cpp_domain_get_assemblies)(void*, size_t*) = NULL;
static void* (*_il2cpp_assembly_get_image)(void*) = NULL;
static void* (*_il2cpp_image_get_class)(void*, size_t) = NULL;
static size_t (*_il2cpp_image_get_class_count)(void*) = NULL;
static const char* (*_il2cpp_class_get_name)(void*) = NULL;
static void* (*_il2cpp_class_get_method_from_name)(void*, const char*, int) = NULL;

// Cached class/method pointers
static void *_klass_BoardModelCells = NULL;
static void *_method_GetCellAnswer  = NULL;
static void *_method_SetCell        = NULL;
static void *_method_IsCellMutable  = NULL;

// ─── IL2CPP API Resolution ──────────────────────────────────────────────────

static BOOL resolve_il2cpp_api(void) {
    #define RESOLVE(fn) _##fn = (typeof(_##fn))dlsym(RTLD_DEFAULT, #fn)
    RESOLVE(il2cpp_domain_get);
    RESOLVE(il2cpp_domain_get_assemblies);
    RESOLVE(il2cpp_assembly_get_image);
    RESOLVE(il2cpp_image_get_class);
    RESOLVE(il2cpp_image_get_class_count);
    RESOLVE(il2cpp_class_get_name);
    RESOLVE(il2cpp_class_get_method_from_name);
    #undef RESOLVE
    return (_il2cpp_domain_get != NULL);
}

static void find_board_classes(void) {
    if (!_il2cpp_domain_get) return;
    void *domain = _il2cpp_domain_get();
    if (!domain) return;
    size_t asm_count = 0;
    void **assemblies = _il2cpp_domain_get_assemblies(domain, &asm_count);
    if (!assemblies) return;

    for (size_t ai = 0; ai < asm_count; ai++) {
        void *img = _il2cpp_assembly_get_image ? _il2cpp_assembly_get_image(assemblies[ai]) : NULL;
        if (!img) continue;
        size_t cnt = _il2cpp_image_get_class_count ? _il2cpp_image_get_class_count(img) : 0;
        for (size_t ci = 0; ci < cnt; ci++) {
            void *klass = _il2cpp_image_get_class ? _il2cpp_image_get_class(img, ci) : NULL;
            if (!klass) continue;
            const char *name = _il2cpp_class_get_name ? _il2cpp_class_get_name(klass) : NULL;
            if (!name) continue;
            if (strcmp(name, "BoardModelCells") == 0) {
                _klass_BoardModelCells = klass;
                if (_il2cpp_class_get_method_from_name) {
                    _method_GetCellAnswer = _il2cpp_class_get_method_from_name(klass, "GetCellAnswer", 2);
                    _method_SetCell       = _il2cpp_class_get_method_from_name(klass, "SetCell", 3);
                    _method_IsCellMutable = _il2cpp_class_get_method_from_name(klass, "IsCellMutable", 2);
                }
            }
        }
    }
}

// ─── IL2CPP Direct Invocation (if method pointers found) ───────────────────

typedef int (*GetCellAnswer_fn)(void *this_, int row, int col, void *method);
typedef void (*SetCell_fn)(void *this_, int row, int col, int val, void *method);
typedef BOOL (*IsCellMutable_fn)(void *this_, int row, int col, void *method);

static int il2cpp_GetCellAnswer(void *cells_obj, int row, int col) {
    if (!_method_GetCellAnswer) return 0;
    uintptr_t fptr = *(uintptr_t *)_method_GetCellAnswer;
    if (!fptr) return 0;
    return ((GetCellAnswer_fn)fptr)(cells_obj, row, col, _method_GetCellAnswer);
}

static void il2cpp_SetCell(void *cells_obj, int row, int col, int val) {
    if (!_method_SetCell) return;
    uintptr_t fptr = *(uintptr_t *)_method_SetCell;
    if (!fptr) return;
    ((SetCell_fn)fptr)(cells_obj, row, col, val, _method_SetCell);
}

static BOOL il2cpp_IsCellMutable(void *cells_obj, int row, int col) {
    if (!_method_IsCellMutable) return YES;
    uintptr_t fptr = *(uintptr_t *)_method_IsCellMutable;
    if (!fptr) return YES;
    return ((IsCellMutable_fn)fptr)(cells_obj, row, col, _method_IsCellMutable);
}

// ─── SQLite Hooks ──────────────────────────────────────────────────────────

// We hook sqlite3_open_v2 to grab the DB handle, then query it directly
static int (*orig_sqlite3_open_v2)(const char*, sqlite3**, int, const char*) = NULL;

static int hooked_sqlite3_open_v2(const char *filename, sqlite3 **ppDb, int flags, const char *zVfs) {
    int rc = orig_sqlite3_open_v2(filename, ppDb, flags, zVfs);
    if (rc == SQLITE_OK && ppDb && *ppDb && filename) {
        // The game DB is typically named game.db or puzzle.db
        if (strstr(filename, ".db") || strstr(filename, "game") || strstr(filename, "puzzle")) {
            g_db = *ppDb;
            NSLog(@"[SudokuSolver] Captured DB handle: %p path=%s", g_db, filename);
        }
    }
    return rc;
}

// Query the solution from the DB for the current in-progress level
static BOOL query_solution_from_db(void) {
    if (!g_db) return NO;

    // Schema from metadata strings:
    // SELECT id, levelId, cells, solution FROM gameState ORDER BY lastPlayed DESC LIMIT 1
    const char *sql = "SELECT cells, solution FROM gameState ORDER BY lastPlayed DESC LIMIT 1;";
    sqlite3_stmt *stmt = NULL;
    if (sqlite3_prepare_v2(g_db, sql, -1, &stmt, NULL) != SQLITE_OK) {
        // Try alternate table name
        sql = "SELECT cells, solution FROM game_state ORDER BY lastPlayed DESC LIMIT 1;";
        if (sqlite3_prepare_v2(g_db, sql, -1, &stmt, NULL) != SQLITE_OK) {
            NSLog(@"[SudokuSolver] DB query failed: %s", sqlite3_errmsg(g_db));
            return NO;
        }
    }

    BOOL got_solution = NO;
    if (sqlite3_step(stmt) == SQLITE_ROW) {
        const unsigned char *cells_text    = sqlite3_column_text(stmt, 0);
        const unsigned char *solution_text = sqlite3_column_text(stmt, 1);

        NSLog(@"[SudokuSolver] cells=%s", cells_text ?: (const unsigned char*)"nil");
        NSLog(@"[SudokuSolver] solution=%s", solution_text ?: (const unsigned char*)"nil");

        // Parse solution — format is likely a compact string like "534678912..."
        // or JSON. Try compact 81-digit string first.
        if (solution_text) {
            const char *s = (const char *)solution_text;
            size_t len = strlen(s);

            // Case 1: bare 81-digit string "534678912..."
            if (len == 81) {
                for (int i = 0; i < 81; i++) {
                    if (s[i] >= '1' && s[i] <= '9') {
                        g_solution[i/9][i%9] = s[i] - '0';
                    }
                }
                got_solution = YES;
            }
            // Case 2: JSON array of ints [5,3,4,6,7,8,...]
            else if (s[0] == '[') {
                int idx = 0, num = 0;
                BOOL in_num = NO;
                for (size_t j = 0; j < len && idx < 81; j++) {
                    char c = s[j];
                    if (c >= '0' && c <= '9') { num = num*10 + (c-'0'); in_num = YES; }
                    else if (in_num) {
                        g_solution[idx/9][idx%9] = num;
                        idx++; num = 0; in_num = NO;
                    }
                }
                got_solution = (idx == 81);
            }
            // Case 3: try parsing CellConverter JSON objects
            // Format might be: [{"v":5,"e":true},{"v":3,"e":false}...]
            else if (strstr(s, "\"v\"") || strstr(s, "\"value\"")) {
                NSData *d = [NSData dataWithBytes:s length:len];
                NSArray *arr = [NSJSONSerialization JSONObjectWithData:d options:0 error:nil];
                if ([arr isKindOfClass:[NSArray class]] && arr.count == 81) {
                    for (int i = 0; i < 81; i++) {
                        NSDictionary *cell = arr[i];
                        int v = [cell[@"v"] ?: cell[@"value"] intValue];
                        g_solution[i/9][i%9] = v;
                    }
                    got_solution = YES;
                }
            }
        }

        // Parse given cells for backtracking fallback
        if (cells_text && !got_solution) {
            const char *c = (const char *)cells_text;
            size_t len2 = strlen(c);
            memset(g_given, 0, sizeof(g_given));
            if (len2 == 81) {
                for (int i = 0; i < 81; i++)
                    if (c[i] >= '1' && c[i] <= '9')
                        g_given[i/9][i%9] = c[i] - '0';
            } else if (c[0] == '[') {
                // same JSON parsing as above but for given
                int idx = 0, num2 = 0; BOOL in_n = NO;
                for (size_t j = 0; j < len2 && idx < 81; j++) {
                    char ch = c[j];
                    if (ch >= '0' && ch <= '9') { num2 = num2*10+(ch-'0'); in_n = YES; }
                    else if (in_n) { g_given[idx/9][idx%9] = num2; idx++; num2=0; in_n=NO; }
                }
            }
        }
    }
    sqlite3_finalize(stmt);
    return got_solution;
}

// ─── Backtracking Fallback ──────────────────────────────────────────────────

static BOOL solve_from_givens(void) {
    // Try DB first to populate g_given
    query_solution_from_db();

    // If we already have solution from DB, use it
    memset(g_solution, 0, sizeof(g_solution));

    // Check if g_given has enough clues (need at least 17)
    int clue_count = 0;
    for (int r = 0; r < 9; r++)
        for (int c = 0; c < 9; c++)
            if (g_given[r][c]) { g_solution[r][c] = g_given[r][c]; clue_count++; }

    if (clue_count < 17) {
        NSLog(@"[SudokuSolver] Not enough clues (%d) for backtracking", clue_count);
        return NO;
    }

    if (sudoku_solve(g_solution)) {
        g_solution_ready = YES;
        return YES;
    }
    return NO;
}

// ─── ObjC UI Interaction (send tap events to game cells) ───────────────────

// Walk the view hierarchy and find all cell views, ordered by position
static void collect_cells(UIView *view, NSMutableArray *cells, CGRect gridBounds) {
    if (!view || view.hidden || view.alpha < 0.01) return;

    // Heuristic: cells are small square views arranged in a 9x9 grid
    CGRect frame = [view convertRect:view.bounds toView:nil];
    if (CGRectContainsRect(gridBounds, frame)) {
        CGFloat w = frame.size.width, h = frame.size.height;
        // Cell views are roughly 1/9th of the grid
        CGFloat cellW = gridBounds.size.width / 9.0;
        if (w >= cellW * 0.5 && w <= cellW * 1.5 && h >= cellW * 0.5 && h <= cellW * 1.5) {
            [cells addObject:view];
        }
    }

    for (UIView *sub in view.subviews)
        collect_cells(sub, cells, gridBounds);
}

// ─── Solve via IL2CPP (direct method call) ─────────────────────────────────

static BOOL solve_via_il2cpp(void) {
    if (!_method_GetCellAnswer || !_method_SetCell) return NO;

    // We need the BoardModelCells instance — scan the heap is complex.
    // Instead, rely on the hooked SetCell below to get 'this' pointer.
    // This path is used only if we captured the object pointer.
    return NO; // placeholder until we have the instance pointer
}

// ─── Core Solve Entry Point ─────────────────────────────────────────────────

static void do_solve(void) {
    if (!g_solution_ready) {
        // Try DB first
        if (query_solution_from_db()) {
            g_solution_ready = YES;
            NSLog(@"[SudokuSolver] Got solution from DB");
        } else {
            // Backtracking fallback
            if (solve_from_givens()) {
                NSLog(@"[SudokuSolver] Solved via backtracking");
            } else {
                UIAlertController *alert = [UIAlertController
                    alertControllerWithTitle:@"SudokuSolver"
                    message:@"Couldn't get solution yet. Make sure the puzzle is loaded and try again."
                    preferredStyle:UIAlertControllerStyleAlert];
                [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
                UIViewController *root = [UIApplication sharedApplication].keyWindow.rootViewController;
                [root presentViewController:alert animated:YES completion:nil];
                return;
            }
        }
    }

    // Log solution
    NSLog(@"[SudokuSolver] Solution:");
    for (int r = 0; r < 9; r++) {
        NSLog(@"[SudokuSolver]  %d %d %d | %d %d %d | %d %d %d",
              g_solution[r][0], g_solution[r][1], g_solution[r][2],
              g_solution[r][3], g_solution[r][4], g_solution[r][5],
              g_solution[r][6], g_solution[r][7], g_solution[r][8]);
    }

    // ── Strategy 1: Hit the number pad buttons programmatically ──────────
    // Find the 9x9 grid view by looking for a view with exactly 81 similar subviews
    UIWindow *window = [UIApplication sharedApplication].keyWindow;
    UIView *root_view = window.rootViewController.view;

    // Find grid: look for the view containing ~81 cell-sized subviews
    __block UIView *gridView = nil;
    NSMutableArray *allViews = [NSMutableArray array];

    // BFS
    NSMutableArray *queue = [NSMutableArray arrayWithObject:root_view];
    while (queue.count > 0) {
        UIView *v = queue[0]; [queue removeObjectAtIndex:0];
        [allViews addObject:v];
        for (UIView *sub in v.subviews) [queue addObject:sub];
    }

    // Score each view as "likely grid" by counting uniform subviews
    for (UIView *v in allViews) {
        if (v.subviews.count < 9) continue;
        CGFloat first_w = v.subviews.firstObject.frame.size.width;
        CGFloat first_h = v.subviews.firstObject.frame.size.height;
        int uniform = 0;
        for (UIView *sub in v.subviews) {
            CGFloat dw = fabs(sub.frame.size.width - first_w);
            CGFloat dh = fabs(sub.frame.size.height - first_h);
            if (dw < 2 && dh < 2) uniform++;
        }
        // 81 cells or 9 rows
        if (uniform >= 81 || (uniform >= 9 && first_w > 20 && first_h > 20)) {
            gridView = v;
            break;
        }
    }

    if (gridView) {
        NSLog(@"[SudokuSolver] Found grid view: %@ with %lu subviews",
              NSStringFromClass([gridView class]), (unsigned long)gridView.subviews.count);

        NSArray *cells = gridView.subviews;
        // Sort by position: top-to-bottom, left-to-right
        NSSortDescriptor *byY = [NSSortDescriptor sortDescriptorWithKey:@"frame.origin.y" ascending:YES];
        NSSortDescriptor *byX = [NSSortDescriptor sortDescriptorWithKey:@"frame.origin.x" ascending:YES];
        cells = [cells sortedArrayUsingDescriptors:@[byY, byX]];

        // Tap each mutable cell, then tap the correct number key
        // This requires finding the number pad too
        UIView *numPad = nil;
        for (UIView *v in allViews) {
            if (v.subviews.count == 9 && v != gridView) {
                BOOL all_similar = YES;
                CGFloat fw = v.subviews.firstObject.frame.size.width;
                for (UIView *sub in v.subviews) {
                    if (fabs(sub.frame.size.width - fw) > 5) { all_similar = NO; break; }
                }
                if (all_similar && fw > 20) { numPad = v; break; }
            }
        }
        NSLog(@"[SudokuSolver] NumPad: %@", numPad ? NSStringFromClass([numPad class]) : @"not found");

        if (cells.count >= 81 && numPad) {
            NSArray *numKeys = [numPad.subviews sortedArrayUsingDescriptors:@[byX]];
            dispatch_async(dispatch_get_main_queue(), ^{
                NSTimeInterval delay = 0.0;
                for (int i = 0; i < 81 && i < (int)cells.count; i++) {
                    int row = i / 9, col = i % 9;
                    int ans = g_solution[row][col];
                    if (ans < 1 || ans > 9) continue;

                    UIView *cell = cells[i];
                    UIView *key  = (ans - 1 < (int)numKeys.count) ? numKeys[ans-1] : nil;

                    // Check if cell already has correct value (look at label)
                    // Skip preset cells — look for UILabel with bold/different font
                    UILabel *cellLabel = nil;
                    for (UIView *sub in cell.subviews) {
                        if ([sub isKindOfClass:[UILabel class]]) { cellLabel = (UILabel*)sub; break; }
                    }
                    if (cellLabel) {
                        NSString *txt = cellLabel.text;
                        if (txt && [txt intValue] == ans) continue; // already correct
                        // If it has a value and is non-editable, skip (bold font heuristic)
                        UIFont *f = cellLabel.font;
                        if (txt.length > 0 && f.pointSize > 16 && [f.fontName containsString:@"Bold"]) continue;
                    }

                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                                   dispatch_get_main_queue(), ^{
                        // Tap cell to select it
                        CGPoint cellCenter = [cell convertPoint:CGPointMake(cell.bounds.size.width/2,
                                                                             cell.bounds.size.height/2)
                                                          toView:nil];
                        if (key) {
                            // Synthesize tap on cell
                            [cell.nextResponder touchesBegan:[NSSet setWithObject:
                                [UITouch new]] withEvent:nil];
                            // Use sendActionsForControlEvents if it's a UIControl
                            if ([cell isKindOfClass:[UIControl class]])
                                [(UIControl*)cell sendActionsForControlEvents:UIControlEventTouchUpInside];

                            // Tap the number key
                            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 50 * NSEC_PER_MSEC),
                                           dispatch_get_main_queue(), ^{
                                if ([key isKindOfClass:[UIControl class]])
                                    [(UIControl*)key sendActionsForControlEvents:UIControlEventTouchUpInside];
                            });
                        }
                    });
                    delay += 0.12; // 120ms between cells
                }
            });
            return;
        }
    }

    // ── Strategy 2: Accessibility actions ────────────────────────────────
    NSLog(@"[SudokuSolver] Grid/numpad not found — trying accessibility");
    // (fallback: not implemented in this version)

    // Show solution in alert as last resort
    NSMutableString *grid = [NSMutableString string];
    for (int r = 0; r < 9; r++) {
        for (int c = 0; c < 9; c++)
            [grid appendFormat:@"%d ", g_solution[r][c]];
        [grid appendString:@"\n"];
    }
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:@"Solution"
        message:grid
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    UIViewController *rootVC = [UIApplication sharedApplication].keyWindow.rootViewController;
    [rootVC presentViewController:alert animated:YES completion:nil];
}

// ─── Floating Button ────────────────────────────────────────────────────────

static UIButton *_make_button(NSString *title, SEL action, CGFloat x, CGFloat y,
                               id target, UIColor *color) {
    UIButton *btn = [UIButton buttonWithType:UIButtonTypeCustom];
    btn.frame = CGRectMake(x, y, 64, 64);
    btn.backgroundColor = color;
    btn.layer.cornerRadius = 32;
    btn.layer.shadowColor = [UIColor blackColor].CGColor;
    btn.layer.shadowOpacity = 0.4;
    btn.layer.shadowRadius = 4;
    btn.layer.shadowOffset = CGSizeMake(0, 2);
    [btn setTitle:title forState:UIControlStateNormal];
    btn.titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightBold];
    [btn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    [btn addTarget:target action:action forControlEvents:UIControlEventTouchUpInside];
    btn.userInteractionEnabled = YES;
    return btn;
}

static void add_overlay_buttons(UIViewController *vc) {
    UIView *view = vc.view;
    if (!view) return;

    // Remove existing
    [[view viewWithTag:TAG_SOLVE] removeFromSuperview];
    [[view viewWithTag:TAG_DUMP]  removeFromSuperview];

    CGFloat safeBottom = 0;
    if (@available(iOS 11.0, *))
        safeBottom = view.safeAreaInsets.bottom;

    CGFloat btnY = view.bounds.size.height - 80 - safeBottom;
    CGFloat btnX = view.bounds.size.width  - 80;

    // Solve button (green)
    UIButton *solveBtn = _make_button(@"SOLVE", @selector(sudokuSolvePressed:), btnX, btnY,
                                       [UIApplication sharedApplication].delegate,
                                       [UIColor colorWithRed:0.2 green:0.7 blue:0.3 alpha:0.9]);
    solveBtn.tag = TAG_SOLVE;
    [view addSubview:solveBtn];

    // Dump button (blue)
    UIButton *dumpBtn = _make_button(@"DUMP", @selector(sudokuDumpPressed:), btnX, btnY - 80,
                                      [UIApplication sharedApplication].delegate,
                                      [UIColor colorWithRed:0.2 green:0.4 blue:0.8 alpha:0.9]);
    dumpBtn.tag = TAG_DUMP;
    [view addSubview:dumpBtn];
}

// ─── App Delegate Category (for button actions) ─────────────────────────────

@interface UIApplication (SudokuSolver)
@end

@implementation UIApplication (SudokuSolver)

- (void)sudokuSolvePressed:(UIButton *)sender {
    NSLog(@"[SudokuSolver] Solve pressed");
    g_solution_ready = NO; // force re-query
    do_solve();
}

- (void)sudokuDumpPressed:(UIButton *)sender {
    NSLog(@"[SudokuSolver] Dump pressed");
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        sudoku_memdump();
        dispatch_async(dispatch_get_main_queue(), ^{
            UIAlertController *alert = [UIAlertController
                alertControllerWithTitle:@"Memory Dump Done"
                message:@"Saved to:\n/var/mobile/Documents/SudokuDump/\n\nCopy dump_log.txt and dump_DATA*.bin off device for analysis."
                preferredStyle:UIAlertControllerStyleAlert];
            [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
            UIViewController *root = [UIApplication sharedApplication].keyWindow.rootViewController;
            [root presentViewController:alert animated:YES completion:nil];
        });
    });
}

@end

// ─── Hooks ──────────────────────────────────────────────────────────────────

// Hook sqlite3_open_v2 to capture the DB handle
%hookf(int, sqlite3_open_v2, const char *filename, sqlite3 **ppDb, int flags, const char *zVfs) {
    int rc = %orig;
    if (rc == SQLITE_OK && ppDb && *ppDb && filename) {
        NSLog(@"[SudokuSolver] sqlite3_open_v2: %s", filename);
        if (strstr(filename, ".db") || strstr(filename, "sudoku") || strstr(filename, "game")) {
            g_db = *ppDb;
        }
    }
    return rc;
}

// Hook UIViewController -viewDidAppear: to inject our buttons
%hook UIViewController

- (void)viewDidAppear:(BOOL)animated {
    %orig;

    NSString *cls = NSStringFromClass([self class]);
    // Only inject into the main game view controller (Easybrain uses Unity/ObjC bridge)
    // Common controller names from Unity: UnityAppController, or any that has the game view
    if ([cls containsString:@"Game"] || [cls containsString:@"Sudoku"] ||
        [cls containsString:@"Board"] || [cls containsString:@"Main"] ||
        [cls isEqualToString:@"UnityAppController"] ||
        [cls containsString:@"ViewController"]) {

        NSLog(@"[SudokuSolver] viewDidAppear: %@", cls);
        add_overlay_buttons(self);

        // One-time IL2CPP API resolution
        static dispatch_once_t once;
        dispatch_once(&once, ^{
            if (resolve_il2cpp_api()) {
                NSLog(@"[SudokuSolver] IL2CPP API resolved via dlsym");
                find_board_classes();
                if (_method_GetCellAnswer)
                    NSLog(@"[SudokuSolver] GetCellAnswer method found");
                else
                    NSLog(@"[SudokuSolver] GetCellAnswer not found — using DB/backtracking");
            } else {
                NSLog(@"[SudokuSolver] IL2CPP API not available via dlsym — using DB/backtracking");
            }
        });
    }
}

%end

// Hook viewDidLayoutSubviews to keep buttons on top
%hook UIViewController

- (void)viewDidLayoutSubviews {
    %orig;
    // Re-raise buttons if they got buried
    UIView *solveBtn = [self.view viewWithTag:TAG_SOLVE];
    UIView *dumpBtn  = [self.view viewWithTag:TAG_DUMP];
    if (solveBtn) [self.view bringSubviewToFront:solveBtn];
    if (dumpBtn)  [self.view bringSubviewToFront:dumpBtn];
}

%end

// Hook UIWindow -makeKeyAndVisible to catch the window as early as possible
%hook UIWindow

- (void)makeKeyAndVisible {
    %orig;
}

%end

// ─── Constructor ─────────────────────────────────────────────────────────────

%ctor {
    NSLog(@"[SudokuSolver] Loaded — bundle: %@", [NSBundle mainBundle].bundleIdentifier);
    memset(g_solution, 0, sizeof(g_solution));
    memset(g_given, 0, sizeof(g_given));

    // Ensure dump dir exists
    mkdir(DUMP_DIR, 0755);

    %init;
}
