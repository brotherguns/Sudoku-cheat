/*
 * SudokuSolver — Auto-solve tweak for Easybrain Sudoku (iOS)
 * Bundle: com.easybrain.sudoku
 * Engine: Unity IL2CPP arm64, metadata v31
 *
 * == How it works ==
 *
 * PRIMARY (live solve via IL2CPP runtime API):
 *   • On load, resolve il2cpp_* exports from UnityFramework via dlsym
 *   • Hook BoardModelCells.Init() to capture the active cells model
 *   • On solve: loop every cell, call GetCellAnswer() → SetCell()
 *
 * FALLBACK (DB patch — requires level restart):
 *   • Read the `solution` column from the SudokuGame sqlite table
 *   • Overwrite the `cells` column so the game loads a solved board
 *
 * == Key classes (from metadata dump) ==
 *
 *   BoardModelCells (Sudoku.Game.Mechanics.Base)
 *     Fields: Model, UndoManager, OnCellChanged, OnCellStateChanged, LevelData, Config
 *     Key methods:
 *       Init()                     — we hook this to grab the instance
 *       GetCellAnswer(int)         — returns correct digit for flat index
 *       SetCell(int, int)          — sets cell at flat index to digit
 *       IsCellMutable(int)         — true if not a preset constant
 *       GetCellState(int)          — Empty=0, Error=1, Ok=2, Constant=3
 *       IsAllCellsFull()           — true when board is complete
 *       CountEmptyCells()          — remaining empty cell count
 *
 *   LevelSaveConfig (Sudoku.Scripts.Game.Mechanics.Base.Data.Serialize)
 *     Fields: Mode, Difficulty, LevelId, CellsData, Height, Width, MaxNumber ...
 *
 *   CellState enum: Empty=0  Error=1  Ok=2  Constant=3  Unavailable=4
 *
 *   SudokuGame sqlite table:
 *     cells, solution, state, mistakesCount, ...
 */

#import <UIKit/UIKit.h>
#import <dlfcn.h>
#import <sqlite3.h>
#import <objc/runtime.h>
#import <substrate.h>

#pragma mark - IL2CPP API types

typedef void Il2CppDomain;
typedef void Il2CppAssembly;
typedef void Il2CppImage;
typedef void Il2CppClass;
typedef void Il2CppObject;
typedef void Il2CppMethodInfo;

// Function pointer types for every il2cpp export we need
#define IL2CPP_API_LIST \
    X(Il2CppDomain*,      il2cpp_domain_get,                    (void)) \
    X(Il2CppAssembly**,   il2cpp_domain_get_assemblies,         (Il2CppDomain*, size_t*)) \
    X(Il2CppImage*,       il2cpp_assembly_get_image,            (Il2CppAssembly*)) \
    X(const char*,        il2cpp_image_get_name,                (Il2CppImage*)) \
    X(Il2CppClass*,       il2cpp_class_from_name,               (Il2CppImage*, const char*, const char*)) \
    X(const Il2CppMethodInfo*, il2cpp_class_get_method_from_name, (Il2CppClass*, const char*, int)) \
    X(Il2CppObject*,      il2cpp_runtime_invoke,                (const Il2CppMethodInfo*, void*, void**, Il2CppObject**)) \
    X(const char*,        il2cpp_class_get_name,                (Il2CppClass*)) \
    X(Il2CppClass*,       il2cpp_object_get_class,              (Il2CppObject*)) \
    X(int,                il2cpp_class_get_type_token,           (Il2CppClass*)) \
    X(void*,              il2cpp_object_unbox,                   (Il2CppObject*))

// Declare function pointers
#define X(ret, name, args) static ret (*name##_ptr) args = NULL;
IL2CPP_API_LIST
#undef X

#pragma mark - State

static BOOL       gIL2CPPReady    = NO;   // il2cpp exports resolved

// Forward declarations
static BOOL resolveIL2CPP(void);
static BOOL resolveMethods(void);
static void installInvokeHook(void);
static NSString *findDB(void);
static BOOL       gBoardReady     = NO;   // have an active board instance
static void      *gCellsInstance  = NULL;  // BoardModelCells*
static int        gBoardSize      = 81;    // 9×9 default

// Method pointers cached after first resolve
static const Il2CppMethodInfo *mGetCellAnswer = NULL;
static const Il2CppMethodInfo *mSetCell       = NULL;
static const Il2CppMethodInfo *mIsCellMutable = NULL;
static const Il2CppMethodInfo *mGetCellState  = NULL;
static const Il2CppMethodInfo *mCountEmpty    = NULL;
static const Il2CppMethodInfo *mIsAllFull     = NULL;

static NSString *gDBPath    = nil;
static UIButton *gSolveBtn  = nil;
static BOOL      gBtnAdded  = NO;

#pragma mark - IL2CPP bootstrap

static BOOL resolveIL2CPP(void) {
    if (gIL2CPPReady) return YES;

    #define X(ret, name, args) \
        name##_ptr = (ret(*) args)dlsym(RTLD_DEFAULT, #name); \
        if (!name##_ptr) { NSLog(@"[SS] missing: %s", #name); }
    IL2CPP_API_LIST
    #undef X

    gIL2CPPReady = (il2cpp_domain_get_ptr &&
                    il2cpp_class_from_name_ptr &&
                    il2cpp_class_get_method_from_name_ptr &&
                    il2cpp_runtime_invoke_ptr);

    NSLog(@"[SS] il2cpp resolved: %d", gIL2CPPReady);
    return gIL2CPPReady;
}

static Il2CppImage *findGameImage(void) {
    if (!gIL2CPPReady) return NULL;

    Il2CppDomain *dom = il2cpp_domain_get_ptr();
    if (!dom) return NULL;

    size_t cnt = 0;
    Il2CppAssembly **asms = il2cpp_domain_get_assemblies_ptr(dom, &cnt);

    for (size_t i = 0; i < cnt; i++) {
        Il2CppImage *img = il2cpp_assembly_get_image_ptr(asms[i]);
        if (!img) continue;
        // Try resolving BoardModelCells directly
        Il2CppClass *k = il2cpp_class_from_name_ptr(img,
                            "Sudoku.Game.Mechanics.Base", "BoardModelCells");
        if (k) return img;
    }
    return NULL;
}

static BOOL resolveMethods(void) {
    if (mGetCellAnswer) return YES;

    Il2CppImage *img = findGameImage();
    if (!img) { NSLog(@"[SS] game image not found"); return NO; }

    Il2CppClass *cells = il2cpp_class_from_name_ptr(img,
                            "Sudoku.Game.Mechanics.Base", "BoardModelCells");
    if (!cells) { NSLog(@"[SS] BoardModelCells not found"); return NO; }

    // GetCellAnswer has overloads (1-arg flat index, 2-arg row/col, 3-arg?)
    // SetCell same. We want the single-int-arg versions.
    mGetCellAnswer = il2cpp_class_get_method_from_name_ptr(cells, "GetCellAnswer", 1);
    mSetCell       = il2cpp_class_get_method_from_name_ptr(cells, "SetCell", 2);
    mIsCellMutable = il2cpp_class_get_method_from_name_ptr(cells, "IsCellMutable", 1);
    mGetCellState  = il2cpp_class_get_method_from_name_ptr(cells, "GetCellState", 1);
    mCountEmpty    = il2cpp_class_get_method_from_name_ptr(cells, "CountEmptyCells", 0);
    mIsAllFull     = il2cpp_class_get_method_from_name_ptr(cells, "IsAllCellsFull", 0);

    NSLog(@"[SS] methods — answer:%p set:%p mutable:%p state:%p empty:%p full:%p",
          mGetCellAnswer, mSetCell, mIsCellMutable, mGetCellState, mCountEmpty, mIsAllFull);

    return (mGetCellAnswer && mSetCell);
}

#pragma mark - IL2CPP invoke helpers

static int invokeInt(const Il2CppMethodInfo *m, void *obj, int arg) {
    Il2CppObject *exc = NULL;
    void *args[1] = { &arg };
    Il2CppObject *ret = il2cpp_runtime_invoke_ptr(m, obj, args, &exc);
    if (exc || !ret) return -1;
    return *(int *)il2cpp_object_unbox_ptr(ret);
}

static BOOL invokeBool(const Il2CppMethodInfo *m, void *obj, int arg) {
    Il2CppObject *exc = NULL;
    void *args[1] = { &arg };
    Il2CppObject *ret = il2cpp_runtime_invoke_ptr(m, obj, args, &exc);
    if (exc || !ret) return NO;
    return *(bool *)il2cpp_object_unbox_ptr(ret);
}

static void invokeSetCell(void *obj, int idx, int val) {
    Il2CppObject *exc = NULL;
    void *args[2] = { &idx, &val };
    il2cpp_runtime_invoke_ptr(mSetCell, obj, args, &exc);
}

#pragma mark - Live solve

static BOOL solveLive(void) {
    if (!gBoardReady || !gCellsInstance) return NO;
    if (!mGetCellAnswer || !mSetCell) return NO;

    NSLog(@"[SS] solving live, board size %d", gBoardSize);

    int filled = 0;
    for (int i = 0; i < gBoardSize; i++) {
        // Skip constant / already-correct cells
        if (mIsCellMutable && !invokeBool(mIsCellMutable, gCellsInstance, i))
            continue;

        if (mGetCellState) {
            int state = invokeInt(mGetCellState, gCellsInstance, i);
            if (state == 2 || state == 3) continue; // Ok or Constant
        }

        int answer = invokeInt(mGetCellAnswer, gCellsInstance, i);
        if (answer > 0) {
            invokeSetCell(gCellsInstance, i, answer);
            filled++;
        }
    }

    NSLog(@"[SS] filled %d cells", filled);
    return (filled > 0);
}

#pragma mark - SQLite fallback

static NSString *findDB(void) {
    if (gDBPath) return gDBPath;

    NSString *home = NSHomeDirectory();
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray *dirs = @[@"Documents", @"Library", @"Library/Application Support"];

    for (NSString *sub in dirs) {
        NSString *dir = [home stringByAppendingPathComponent:sub];
        for (NSString *f in [fm contentsOfDirectoryAtPath:dir error:nil]) {
            if (![f hasSuffix:@".db"] && ![f hasSuffix:@".sqlite"] && ![f hasSuffix:@".sqlite3"])
                continue;
            NSString *full = [dir stringByAppendingPathComponent:f];
            sqlite3 *db;
            if (sqlite3_open_v2([full UTF8String], &db, SQLITE_OPEN_READONLY, NULL) == SQLITE_OK) {
                sqlite3_stmt *st;
                if (sqlite3_prepare_v2(db,
                        "SELECT 1 FROM sqlite_master WHERE type='table' AND name='SudokuGame'",
                        -1, &st, NULL) == SQLITE_OK) {
                    if (sqlite3_step(st) == SQLITE_ROW)
                        gDBPath = [full copy];
                    sqlite3_finalize(st);
                }
                sqlite3_close(db);
                if (gDBPath) { NSLog(@"[SS] db: %@", gDBPath); return gDBPath; }
            }
        }
    }

    // Deep search in Documents
    NSDirectoryEnumerator *en = [fm enumeratorAtPath:[home stringByAppendingPathComponent:@"Documents"]];
    NSString *f;
    while ((f = [en nextObject])) {
        if (![f hasSuffix:@".db"] && ![f hasSuffix:@".sqlite3"]) continue;
        NSString *full = [[home stringByAppendingPathComponent:@"Documents"]
                            stringByAppendingPathComponent:f];
        sqlite3 *db;
        if (sqlite3_open_v2([full UTF8String], &db, SQLITE_OPEN_READONLY, NULL) == SQLITE_OK) {
            sqlite3_stmt *st;
            if (sqlite3_prepare_v2(db,
                    "SELECT 1 FROM sqlite_master WHERE type='table' AND name='SudokuGame'",
                    -1, &st, NULL) == SQLITE_OK) {
                if (sqlite3_step(st) == SQLITE_ROW)
                    gDBPath = [full copy];
                sqlite3_finalize(st);
            }
            sqlite3_close(db);
            if (gDBPath) return gDBPath;
        }
    }
    return nil;
}

static BOOL solveDB(void) {
    NSString *dbPath = findDB();
    if (!dbPath) { NSLog(@"[SS] db not found"); return NO; }

    sqlite3 *db;
    if (sqlite3_open([dbPath UTF8String], &db) != SQLITE_OK) return NO;

    BOOL ok = NO;
    sqlite3_stmt *st;

    // Read solution
    if (sqlite3_prepare_v2(db,
            "SELECT solution, cells FROM SudokuGame "
            "WHERE state != 'COMPLETED' ORDER BY lastPlayed DESC LIMIT 1",
            -1, &st, NULL) == SQLITE_OK) {
        if (sqlite3_step(st) == SQLITE_ROW) {
            const char *sol = (const char *)sqlite3_column_text(st, 0);
            const char *cur = (const char *)sqlite3_column_text(st, 1);
            if (sol && cur) {
                NSLog(@"[SS] solution len=%lu  cells len=%lu",
                      strlen(sol), strlen(cur));

                // Write solution as cells
                sqlite3_stmt *upd;
                if (sqlite3_prepare_v2(db,
                        "UPDATE SudokuGame SET cells = ?, "
                        "mistakesCount = 0, mistakesCountAll = 0 "
                        "WHERE state != 'COMPLETED' "
                        "ORDER BY lastPlayed DESC LIMIT 1",
                        -1, &upd, NULL) == SQLITE_OK) {
                    sqlite3_bind_text(upd, 1, sol, -1, SQLITE_TRANSIENT);
                    ok = (sqlite3_step(upd) == SQLITE_DONE);
                    sqlite3_finalize(upd);
                }
            }
        }
        sqlite3_finalize(st);
    }

    sqlite3_close(db);
    NSLog(@"[SS] db solve %s", ok ? "OK" : "FAIL");
    return ok;
}

#pragma mark - Toast helper

static void showToast(NSString *msg) {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindow *win = nil;
        for (UIWindowScene *sc in [UIApplication sharedApplication].connectedScenes) {
            if (sc.activationState == UISceneActivationStateForegroundActive) {
                for (UIWindow *w in sc.windows) {
                    if (w.isKeyWindow) { win = w; break; }
                }
            }
        }
        if (!win) return;

        UILabel *t = [[UILabel alloc] init];
        t.text = msg;
        t.textColor = [UIColor whiteColor];
        t.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.85];
        t.textAlignment = NSTextAlignmentCenter;
        t.font = [UIFont boldSystemFontOfSize:14];
        t.layer.cornerRadius = 14;
        t.clipsToBounds = YES;
        t.alpha = 0;
        [t sizeToFit];

        CGRect fr = t.frame;
        fr.size.width += 32;
        fr.size.height += 16;
        fr.origin.x = (win.bounds.size.width - fr.size.width) / 2;
        fr.origin.y = win.bounds.size.height - 140;
        t.frame = fr;
        [win addSubview:t];

        [UIView animateWithDuration:0.25 animations:^{ t.alpha = 1; }
            completion:^(BOOL f) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2*NSEC_PER_SEC),
                dispatch_get_main_queue(), ^{
                [UIView animateWithDuration:0.25 animations:^{ t.alpha = 0; }
                    completion:^(BOOL f2) { [t removeFromSuperview]; }];
            });
        }];
    });
}

#pragma mark - Solve dispatcher

static void onSolveTapped(void) {
    NSLog(@"[SS] solve tapped — il2cpp:%d board:%d", gIL2CPPReady, gBoardReady);

    // Try live solve first
    if (gIL2CPPReady && gBoardReady) {
        if (!mGetCellAnswer) resolveMethods();
        if (solveLive()) {
            showToast(@"✅ Solved!");
            return;
        }
    }

    // Fall back to DB
    if (solveDB()) {
        showToast(@"✅ Solved via DB — tap ↩ to reload");
    } else {
        showToast(@"❌ No active game found");
    }
}

#pragma mark - Floating button

static void addButton(UIWindow *win) {
    if (gBtnAdded || !win) return;

    gSolveBtn = [UIButton buttonWithType:UIButtonTypeCustom];
    gSolveBtn.frame = CGRectMake(win.bounds.size.width - 66, 100, 52, 52);
    gSolveBtn.backgroundColor = [UIColor colorWithRed:0.18 green:0.65 blue:0.35 alpha:0.92];
    gSolveBtn.layer.cornerRadius = 26;
    gSolveBtn.layer.shadowColor   = [UIColor blackColor].CGColor;
    gSolveBtn.layer.shadowOffset  = CGSizeMake(0, 2);
    gSolveBtn.layer.shadowOpacity = 0.35;
    gSolveBtn.layer.shadowRadius  = 4;

    [gSolveBtn setTitle:@"⚡" forState:UIControlStateNormal];
    gSolveBtn.titleLabel.font = [UIFont systemFontOfSize:22];

    [gSolveBtn addTarget:[NSNull null]
                  action:@selector(ssTapped)
        forControlEvents:UIControlEventTouchUpInside];

    UIPanGestureRecognizer *pan =
        [[UIPanGestureRecognizer alloc] initWithTarget:[NSNull null]
                                                action:@selector(ssPan:)];
    [gSolveBtn addGestureRecognizer:pan];

    [win addSubview:gSolveBtn];
    gBtnAdded = YES;
    NSLog(@"[SS] button added");
}

#pragma mark - NSNull category for button actions

@interface NSNull (SS)
- (void)ssTapped;
- (void)ssPan:(UIPanGestureRecognizer *)g;
@end

@implementation NSNull (SS)
- (void)ssTapped { onSolveTapped(); }
- (void)ssPan:(UIPanGestureRecognizer *)g {
    UIView *v = g.view;
    CGPoint t = [g translationInView:v.superview];
    v.center = CGPointMake(v.center.x + t.x, v.center.y + t.y);
    [g setTranslation:CGPointZero inView:v.superview];
}
@end

#pragma mark - Hooks

// Capture the active BoardModelCells instance when the board initialises.
// BoardModelCells.Init() is called every time a level starts.
// We can't hook C# methods directly by name without offsets, so we use a
// UnityAppController hook + periodic polling instead.

%hook UIWindow

- (void)makeKeyAndVisible {
    %orig;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
        dispatch_get_main_queue(), ^{
        addButton(self);
    });
}

%end

// Poll for il2cpp readiness after Unity finishes loading.
// UnityAppController is the standard Unity iOS app delegate class name.
%hook UnityAppController

- (void)applicationDidBecomeActive:(UIApplication *)app {
    %orig;

    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSLog(@"[SS] unity active");
        dispatch_async(dispatch_get_global_queue(0, 0), ^{
            // Give Unity a moment to finish init
            [NSThread sleepForTimeInterval:1.5];
            resolveIL2CPP();
            if (gIL2CPPReady) {
                installInvokeHook();
                resolveMethods();
            }
            findDB();
        });
    });
}

%end

// Hook sqlite3_open to auto-detect the game database path
%hookf(int, sqlite3_open, const char *filename, sqlite3 **ppDb) {
    int r = %orig;
    if (r == SQLITE_OK && filename && !gDBPath) {
        NSString *path = [NSString stringWithUTF8String:filename];
        if ([path containsString:@"SudokuGame"] ||
            [path containsString:@"sudoku"]) {
            gDBPath = [path copy];
            NSLog(@"[SS] captured db open: %@", gDBPath);
        } else {
            // Check if this DB has SudokuGame table
            sqlite3_stmt *st;
            if (sqlite3_prepare_v2(*ppDb,
                    "SELECT 1 FROM sqlite_master WHERE type='table' AND name='SudokuGame'",
                    -1, &st, NULL) == SQLITE_OK) {
                if (sqlite3_step(st) == SQLITE_ROW) {
                    gDBPath = [path copy];
                    NSLog(@"[SS] captured db (has SudokuGame): %@", gDBPath);
                }
                sqlite3_finalize(st);
            }
        }
    }
    return r;
}

%hookf(int, sqlite3_open_v2, const char *filename, sqlite3 **ppDb, int flags, const char *zVfs) {
    int r = %orig;
    if (r == SQLITE_OK && filename && !gDBPath) {
        NSString *path = [NSString stringWithUTF8String:filename];
        if ([path containsString:@"SudokuGame"] ||
            [path containsString:@"sudoku"]) {
            gDBPath = [path copy];
            NSLog(@"[SS] captured db open_v2: %@", gDBPath);
        }
    }
    return r;
}

// ---- Manual hook of il2cpp_runtime_invoke (deferred) ----
// We can't use %hookf because the symbol lives in UnityFramework
// which isn't loaded yet when our tweak's %init runs.
// Instead we use MSHookFunction after il2cpp is ready.

static void *(*orig_il2cpp_runtime_invoke)(const void *, void *, void **, void **) = NULL;

static void *hooked_il2cpp_runtime_invoke(const void *method, void *obj, void **params, void **exc) {
    void *ret = orig_il2cpp_runtime_invoke(method, obj, params, exc);

    if (gBoardReady || !obj) return ret;
    if (!il2cpp_object_get_class_ptr || !il2cpp_class_get_name_ptr) return ret;

    @try {
        Il2CppClass *klass = il2cpp_object_get_class_ptr((Il2CppObject *)obj);
        if (!klass) return ret;
        const char *name = il2cpp_class_get_name_ptr(klass);
        if (name && strcmp(name, "BoardModelCells") == 0) {
            gCellsInstance = obj;
            gBoardReady = YES;
            NSLog(@"[SS] captured BoardModelCells @ %p", obj);
            if (!mGetCellAnswer) resolveMethods();
        }
    } @catch (NSException *e) {}

    return ret;
}

// Called once il2cpp is loaded to install the invoke hook
static void installInvokeHook(void) {
    void *sym = dlsym(RTLD_DEFAULT, "il2cpp_runtime_invoke");
    if (!sym) { NSLog(@"[SS] il2cpp_runtime_invoke not found for hook"); return; }
    MSHookFunction(sym, (void *)hooked_il2cpp_runtime_invoke,
                   (void **)&orig_il2cpp_runtime_invoke);
    NSLog(@"[SS] invoke hook installed");
}

#pragma mark - Constructor

%ctor {
    NSString *bid = [[NSBundle mainBundle] bundleIdentifier];
    NSLog(@"[SS] loaded in %@", bid);

    if (![bid containsString:@"easybrain"]) {
        NSLog(@"[SS] not target app, skipping");
        return;
    }

    %init;
}
