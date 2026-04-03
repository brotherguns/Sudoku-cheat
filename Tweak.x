/*
 * SudokuSolver — Auto-solve for Easybrain Sudoku (com.easybrain.sudoku)
 *
 * v1: Safe for dylib injection. Only hooks UIWindow for the button.
 *     All IL2CPP + SQLite work happens on-demand when the user taps solve.
 *     Nothing runs at startup that could crash the app.
 */

#import <UIKit/UIKit.h>
#import <dlfcn.h>
#import <sqlite3.h>
#import <substrate.h>
#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#import <mach/mach.h>
#import <sys/stat.h>

// ================================================================
#pragma mark - IL2CPP types & function pointers
// ================================================================

typedef void  Il2CppDomain;
typedef void  Il2CppAssembly;
typedef void  Il2CppImage;
typedef void  Il2CppClass;
typedef void  Il2CppObject;
typedef void  Il2CppMethodInfo;

static Il2CppDomain*       (*api_domain_get)(void);
static Il2CppAssembly**    (*api_domain_get_assemblies)(Il2CppDomain*, size_t*);
static Il2CppImage*        (*api_assembly_get_image)(Il2CppAssembly*);
static const char*         (*api_image_get_name)(Il2CppImage*);
static Il2CppClass*        (*api_class_from_name)(Il2CppImage*, const char*, const char*);
static const Il2CppMethodInfo* (*api_class_get_methods)(Il2CppClass*, void**);
static const Il2CppMethodInfo* (*api_class_get_method_from_name)(Il2CppClass*, const char*, int);
static Il2CppObject*       (*api_runtime_invoke)(const Il2CppMethodInfo*, void*, void**, Il2CppObject**);
static const char*         (*api_method_get_name)(const Il2CppMethodInfo*);
static void*               (*api_object_unbox)(Il2CppObject*);

static BOOL gIL2CPPResolved = NO;

// ================================================================
#pragma mark - Instance capture state
// ================================================================

static void *gCellsInstance = NULL;   // BoardModelCells this-ptr
static BOOL  gHooked        = NO;     // did we install the targeted hook?

static const Il2CppMethodInfo *mGetCellAnswer = NULL;
static const Il2CppMethodInfo *mSetCell       = NULL;
static const Il2CppMethodInfo *mIsCellMutable = NULL;
static const Il2CppMethodInfo *mGetCellState  = NULL;
static const Il2CppMethodInfo *mCountEmpty    = NULL;

// ================================================================
#pragma mark - IL2CPP resolve (lazy, on first solve tap)
// ================================================================

static BOOL resolveAPI(void) {
    if (gIL2CPPResolved) return YES;

    // These symbols live in UnityFramework which is loaded by now
    #define R(name, sym) name = dlsym(RTLD_DEFAULT, #sym)
    R(api_domain_get,                il2cpp_domain_get);
    R(api_domain_get_assemblies,     il2cpp_domain_get_assemblies);
    R(api_assembly_get_image,        il2cpp_assembly_get_image);
    R(api_image_get_name,            il2cpp_image_get_name);
    R(api_class_from_name,           il2cpp_class_from_name);
    R(api_class_get_methods,         il2cpp_class_get_methods);
    R(api_class_get_method_from_name,il2cpp_class_get_method_from_name);
    R(api_runtime_invoke,            il2cpp_runtime_invoke);
    R(api_method_get_name,           il2cpp_method_get_name);
    R(api_object_unbox,              il2cpp_object_unbox);
    #undef R

    gIL2CPPResolved = api_domain_get
                   && api_class_from_name
                   && api_class_get_method_from_name
                   && api_runtime_invoke
                   && api_object_unbox;

    NSLog(@"[SS] il2cpp API resolved: %d", gIL2CPPResolved);
    return gIL2CPPResolved;
}

static Il2CppImage *findGameImage(void) {
    Il2CppDomain *dom = api_domain_get();
    if (!dom) return NULL;
    size_t cnt = 0;
    Il2CppAssembly **asms = api_domain_get_assemblies(dom, &cnt);
    for (size_t i = 0; i < cnt; i++) {
        Il2CppImage *img = api_assembly_get_image(asms[i]);
        if (!img) continue;
        if (api_class_from_name(img, "Sudoku.Game.Mechanics.Base", "BoardModelCells"))
            return img;
    }
    return NULL;
}

static BOOL resolveMethods(void) {
    if (mGetCellAnswer) return YES;
    Il2CppImage *img = findGameImage();
    if (!img) return NO;

    Il2CppClass *cls = api_class_from_name(img,
                        "Sudoku.Game.Mechanics.Base", "BoardModelCells");
    if (!cls) return NO;

    mGetCellAnswer = api_class_get_method_from_name(cls, "GetCellAnswer", 1);
    mSetCell       = api_class_get_method_from_name(cls, "SetCell",       2);
    mIsCellMutable = api_class_get_method_from_name(cls, "IsCellMutable", 1);
    mGetCellState  = api_class_get_method_from_name(cls, "GetCellState",  1);
    mCountEmpty    = api_class_get_method_from_name(cls, "CountEmptyCells",0);

    NSLog(@"[SS] methods: answer=%p set=%p mutable=%p state=%p empty=%p",
          mGetCellAnswer, mSetCell, mIsCellMutable, mGetCellState, mCountEmpty);

    return (mGetCellAnswer && mSetCell);
}

// ================================================================
#pragma mark - Targeted hook: BoardModelCells.GetCellState
// ================================================================
// Hook ONE specific IL2CPP method to capture the `this` pointer.
// GetCellState is called when the board renders — not super hot,
// and gives us the instance immediately when the board is visible.

static int (*orig_GetCellState)(void *self, int index, const Il2CppMethodInfo *method);

static int hook_GetCellState(void *self, int index, const Il2CppMethodInfo *method) {
    if (!gCellsInstance && self) {
        gCellsInstance = self;
        NSLog(@"[SS] captured BoardModelCells instance %p", self);
    }
    return orig_GetCellState(self, index, method);
}

static void installTargetedHook(void) {
    if (gHooked) return;
    if (!mGetCellState) return;

    // il2cpp MethodInfo has methodPointer as its first field
    void *funcPtr = *(void **)mGetCellState;
    if (!funcPtr) { NSLog(@"[SS] method pointer is null"); return; }

    MSHookFunction(funcPtr, (void *)hook_GetCellState, (void **)&orig_GetCellState);
    gHooked = YES;
    NSLog(@"[SS] hooked GetCellState at %p", funcPtr);
}

// ================================================================
#pragma mark - IL2CPP invoke helpers
// ================================================================

static int callInt(const Il2CppMethodInfo *m, void *obj, int a) {
    Il2CppObject *exc = NULL;
    void *args[] = { &a };
    Il2CppObject *r = api_runtime_invoke(m, obj, args, &exc);
    if (exc || !r) return -1;
    return *(int *)api_object_unbox(r);
}

static BOOL callBool(const Il2CppMethodInfo *m, void *obj, int a) {
    Il2CppObject *exc = NULL;
    void *args[] = { &a };
    Il2CppObject *r = api_runtime_invoke(m, obj, args, &exc);
    if (exc || !r) return NO;
    return *(bool *)api_object_unbox(r);
}

static void callSetCell(void *obj, int idx, int val) {
    Il2CppObject *exc = NULL;
    void *args[] = { &idx, &val };
    api_runtime_invoke(mSetCell, obj, args, &exc);
}

// ================================================================
#pragma mark - Live solve via IL2CPP
// ================================================================

static BOOL solveLive(void) {
    if (!gCellsInstance || !mGetCellAnswer || !mSetCell) return NO;

    int filled = 0;
    for (int i = 0; i < 81; i++) {
        // Skip preset / already correct
        if (mGetCellState) {
            int st = callInt(mGetCellState, gCellsInstance, i);
            if (st == 2 || st == 3) continue;  // Ok or Constant
        } else if (mIsCellMutable) {
            if (!callBool(mIsCellMutable, gCellsInstance, i)) continue;
        }

        int answer = callInt(mGetCellAnswer, gCellsInstance, i);
        if (answer > 0 && answer <= 9) {
            callSetCell(gCellsInstance, i, answer);
            filled++;
        }
    }

    NSLog(@"[SS] live: filled %d cells", filled);
    return filled > 0;
}

// ================================================================
#pragma mark - SQLite DB solve (fallback)
// ================================================================

static NSString *findDB(void) {
    NSString *home = NSHomeDirectory();
    NSFileManager *fm = [NSFileManager defaultManager];

    // Search common locations
    NSArray *dirs = @[
        [home stringByAppendingPathComponent:@"Documents"],
        [home stringByAppendingPathComponent:@"Library"],
        [home stringByAppendingPathComponent:@"Library/Application Support"],
    ];

    for (NSString *dir in dirs) {
        NSArray *files = [fm contentsOfDirectoryAtPath:dir error:nil];
        for (NSString *f in files) {
            if (![f hasSuffix:@".db"] && ![f hasSuffix:@".sqlite"]
                && ![f hasSuffix:@".sqlite3"]) continue;

            NSString *path = [dir stringByAppendingPathComponent:f];
            sqlite3 *db;
            if (sqlite3_open_v2([path UTF8String], &db,
                    SQLITE_OPEN_READONLY, NULL) != SQLITE_OK) continue;

            sqlite3_stmt *st;
            BOOL found = NO;
            if (sqlite3_prepare_v2(db,
                    "SELECT 1 FROM sqlite_master "
                    "WHERE type='table' AND name='SudokuGame'",
                    -1, &st, NULL) == SQLITE_OK) {
                found = (sqlite3_step(st) == SQLITE_ROW);
                sqlite3_finalize(st);
            }
            sqlite3_close(db);
            if (found) {
                NSLog(@"[SS] found db: %@", path);
                return path;
            }
        }
    }

    // Deep search Documents recursively
    NSString *docs = [home stringByAppendingPathComponent:@"Documents"];
    NSDirectoryEnumerator *en = [fm enumeratorAtPath:docs];
    NSString *f;
    while ((f = [en nextObject])) {
        if (![f hasSuffix:@".db"] && ![f hasSuffix:@".sqlite3"]) continue;
        NSString *path = [docs stringByAppendingPathComponent:f];
        sqlite3 *db;
        if (sqlite3_open_v2([path UTF8String], &db,
                SQLITE_OPEN_READONLY, NULL) != SQLITE_OK) continue;
        sqlite3_stmt *st;
        BOOL found = NO;
        if (sqlite3_prepare_v2(db,
                "SELECT 1 FROM sqlite_master "
                "WHERE type='table' AND name='SudokuGame'",
                -1, &st, NULL) == SQLITE_OK) {
            found = (sqlite3_step(st) == SQLITE_ROW);
            sqlite3_finalize(st);
        }
        sqlite3_close(db);
        if (found) return path;
    }

    return nil;
}

static BOOL solveDB(void) {
    NSString *dbPath = findDB();
    if (!dbPath) { NSLog(@"[SS] no db found"); return NO; }

    sqlite3 *db;
    if (sqlite3_open([dbPath UTF8String], &db) != SQLITE_OK) return NO;

    BOOL ok = NO;
    sqlite3_stmt *st;

    if (sqlite3_prepare_v2(db,
            "SELECT solution FROM SudokuGame "
            "WHERE state != 'COMPLETED' "
            "ORDER BY lastPlayed DESC LIMIT 1",
            -1, &st, NULL) == SQLITE_OK) {
        if (sqlite3_step(st) == SQLITE_ROW) {
            const char *sol = (const char *)sqlite3_column_text(st, 0);
            if (sol && strlen(sol) > 0) {
                NSLog(@"[SS] solution: %.20s... (len=%lu)", sol, strlen(sol));

                sqlite3_stmt *upd;
                if (sqlite3_prepare_v2(db,
                        "UPDATE SudokuGame SET cells = ? "
                        "WHERE state != 'COMPLETED' "
                        "ORDER BY lastPlayed DESC LIMIT 1",
                        -1, &upd, NULL) == SQLITE_OK) {
                    sqlite3_bind_text(upd, 1, sol, -1, SQLITE_TRANSIENT);
                    ok = (sqlite3_step(upd) == SQLITE_DONE);
                    sqlite3_finalize(upd);
                    if (ok) NSLog(@"[SS] db updated");
                }
            }
        }
        sqlite3_finalize(st);
    }
    sqlite3_close(db);
    return ok;
}

// ================================================================
#pragma mark - UI helpers
// ================================================================

static UIWindow *getKeyWindow(void) {
    for (UIWindowScene *sc in [UIApplication sharedApplication].connectedScenes) {
        if (sc.activationState == UISceneActivationStateForegroundActive) {
            for (UIWindow *w in sc.windows) {
                if (w.isKeyWindow) return w;
            }
        }
    }
    return nil;
}

static void showToast(NSString *msg) {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindow *win = getKeyWindow();
        if (!win) return;

        UILabel *t = [[UILabel alloc] init];
        t.text = msg;
        t.textColor = UIColor.whiteColor;
        t.backgroundColor = [UIColor.blackColor colorWithAlphaComponent:0.85];
        t.textAlignment = NSTextAlignmentCenter;
        t.font = [UIFont boldSystemFontOfSize:14];
        t.layer.cornerRadius = 14;
        t.clipsToBounds = YES;
        t.alpha = 0;
        [t sizeToFit];

        CGRect fr = t.frame;
        fr.size.width  += 32;
        fr.size.height += 16;
        fr.origin.x = (win.bounds.size.width  - fr.size.width)  / 2;
        fr.origin.y =  win.bounds.size.height - 140;
        t.frame = fr;
        [win addSubview:t];

        [UIView animateWithDuration:0.25 animations:^{ t.alpha = 1; }
         completion:^(BOOL done) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2*NSEC_PER_SEC),
                dispatch_get_main_queue(), ^{
                [UIView animateWithDuration:0.25 animations:^{ t.alpha = 0; }
                 completion:^(BOOL d2) { [t removeFromSuperview]; }];
            });
        }];
    });
}

// ================================================================
#pragma mark - Memory Dumper
// ================================================================

static NSString *dumpDir(void) {
    NSString *docs = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents"];
    NSString *dir  = [docs stringByAppendingPathComponent:@"SudokuSolver"];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir
                              withIntermediateDirectories:YES attributes:nil error:nil];
    return dir;
}

// Dump a single Mach-O image from memory (decrypted)
static BOOL dumpMachO(const struct mach_header_64 *header, const char *name, NSString *outPath) {
    if (!header || header->magic != MH_MAGIC_64) return NO;

    // First pass: find __TEXT vmaddr (for slide calc) and total file size
    const uint8_t *ptr = (const uint8_t *)header + sizeof(struct mach_header_64);
    uint64_t fileSize = 0;
    uint64_t textVMAddr = 0;

    for (uint32_t i = 0; i < header->ncmds; i++) {
        const struct load_command *lc = (const struct load_command *)ptr;
        if (lc->cmd == LC_SEGMENT_64) {
            const struct segment_command_64 *seg = (const struct segment_command_64 *)ptr;
            uint64_t end = seg->fileoff + seg->filesize;
            if (end > fileSize) fileSize = end;
            if (strcmp(seg->segname, "__TEXT") == 0) textVMAddr = seg->vmaddr;
        }
        ptr += lc->cmdsize;
    }

    if (fileSize == 0 || textVMAddr == 0) return NO;

    intptr_t slide = (intptr_t)header - (intptr_t)textVMAddr;

    // Allocate output buffer
    NSMutableData *data = [NSMutableData dataWithLength:(NSUInteger)fileSize];
    if (!data) return NO;
    uint8_t *buf = (uint8_t *)data.mutableBytes;

    // Second pass: copy each segment from memory into its fileoff position
    ptr = (const uint8_t *)header + sizeof(struct mach_header_64);
    for (uint32_t i = 0; i < header->ncmds; i++) {
        const struct load_command *lc = (const struct load_command *)ptr;
        if (lc->cmd == LC_SEGMENT_64) {
            const struct segment_command_64 *seg = (const struct segment_command_64 *)ptr;
            if (seg->filesize > 0 && seg->vmsize > 0 && seg->fileoff + seg->filesize <= fileSize) {
                const uint8_t *segData = (const uint8_t *)(seg->vmaddr + slide);

                // Verify the memory is readable
                vm_size_t regionSize = 0;
                vm_address_t regionAddr = (vm_address_t)segData;
                vm_region_basic_info_data_64_t info;
                mach_msg_type_number_t count = VM_REGION_BASIC_INFO_COUNT_64;
                mach_port_t objName;

                kern_return_t kr = vm_region_64(mach_task_self(), &regionAddr, &regionSize,
                    VM_REGION_BASIC_INFO_64, (vm_region_info_t)&info, &count, &objName);

                if (kr == KERN_SUCCESS && (info.protection & VM_PROT_READ)) {
                    memcpy(buf + seg->fileoff, segData, (size_t)seg->filesize);
                }
            }
        }
        ptr += lc->cmdsize;
    }

    // Third pass: clear cryptid so tools know this is decrypted
    ptr = buf + sizeof(struct mach_header_64);
    for (uint32_t i = 0; i < header->ncmds; i++) {
        struct load_command *lc = (struct load_command *)ptr;
        if (lc->cmd == LC_ENCRYPTION_INFO_64) {
            struct encryption_info_command_64 *enc = (struct encryption_info_command_64 *)ptr;
            enc->cryptid = 0;
            NSLog(@"[SS] cleared cryptid in dump");
        } else if (lc->cmd == LC_ENCRYPTION_INFO) {
            struct encryption_info_command *enc = (struct encryption_info_command *)ptr;
            enc->cryptid = 0;
        }
        ptr += lc->cmdsize;
    }

    return [data writeToFile:outPath atomically:YES];
}

static void performDump(void) {
    NSLog(@"[SS] starting memory dump");
    NSString *dir = dumpDir();
    NSMutableString *report = [NSMutableString string];
    int dumped = 0;

    [report appendFormat:@"Dump: %@\n", [NSDate date]];
    [report appendFormat:@"Bundle: %@\n", [[NSBundle mainBundle] bundleIdentifier]];
    [report appendFormat:@"Images loaded: %u\n\n", _dyld_image_count()];

    for (uint32_t i = 0; i < _dyld_image_count(); i++) {
        const char *name = _dyld_get_image_name(i);
        const struct mach_header *hdr = _dyld_get_image_header(i);
        intptr_t slide = _dyld_get_image_vmaddr_slide(i);

        if (!name || !hdr) continue;

        NSString *imgName = [[NSString stringWithUTF8String:name] lastPathComponent];
        NSString *imgPath = [NSString stringWithUTF8String:name];

        [report appendFormat:@"[%u] %s\n    base=%p slide=0x%lx magic=0x%x\n",
            i, name, hdr, (long)slide, hdr->magic];

        // Only dump the main binary, UnityFramework, and any game-specific libs
        BOOL shouldDump = NO;
        if ([imgName isEqualToString:@"Sudoku"] ||
            [imgName containsString:@"UnityFramework"] ||
            [imgName containsString:@"GameAssembly"] ||
            [imgName containsString:@"easybrain"] ||
            [imgPath containsString:[[NSBundle mainBundle] bundlePath]]) {
            shouldDump = YES;
        }

        // Also dump if it's the main executable (index 0)
        if (i == 0) shouldDump = YES;

        if (shouldDump && hdr->magic == MH_MAGIC_64) {
            NSString *outFile = [dir stringByAppendingPathComponent:
                [NSString stringWithFormat:@"%@.decrypted", imgName]];

            BOOL ok = dumpMachO((const struct mach_header_64 *)hdr, name, outFile);
            [report appendFormat:@"    → DUMPED: %@ (%@)\n", imgName, ok ? @"OK" : @"FAIL"];
            if (ok) dumped++;
        }
    }

    // Also copy global-metadata.dat if we can find it
    NSString *bundlePath = [[NSBundle mainBundle] bundlePath];
    NSArray *metaPaths = @[
        [bundlePath stringByAppendingPathComponent:@"Data/Managed/Metadata/global-metadata.dat"],
        [bundlePath stringByAppendingPathComponent:@"Frameworks/UnityFramework.framework/Data/Managed/Metadata/global-metadata.dat"],
    ];

    for (NSString *mp in metaPaths) {
        if ([[NSFileManager defaultManager] fileExistsAtPath:mp]) {
            NSString *dst = [dir stringByAppendingPathComponent:@"global-metadata.dat"];
            [[NSFileManager defaultManager] copyItemAtPath:mp toPath:dst error:nil];
            [report appendFormat:@"\nglobal-metadata.dat: copied from %@\n", mp];
            dumped++;
            break;
        }
    }

    // Copy the sqlite DB too
    NSString *dbPath = findDB();
    if (dbPath) {
        NSString *dst = [dir stringByAppendingPathComponent:
            [dbPath lastPathComponent]];
        [[NSFileManager defaultManager] copyItemAtPath:dbPath toPath:dst error:nil];
        [report appendFormat:@"\nSQLite DB: copied %@\n", [dbPath lastPathComponent]];
        dumped++;
    }

    // Write the report
    [report appendFormat:@"\nTotal dumped: %d files\n", dumped];
    NSString *reportPath = [dir stringByAppendingPathComponent:@"dump_report.txt"];
    [report writeToFile:reportPath atomically:YES encoding:NSUTF8StringEncoding error:nil];

    NSLog(@"[SS] dump complete: %d files → %@", dumped, dir);
}

static void onDumpTapped(void) {
    showToast(@"Dumping memory...");

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        performDump();

        NSString *dir = dumpDir();
        NSArray *files = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:dir error:nil];

        // Calculate total size
        unsigned long long totalSize = 0;
        for (NSString *f in files) {
            NSDictionary *attr = [[NSFileManager defaultManager] attributesOfItemAtPath:
                [dir stringByAppendingPathComponent:f] error:nil];
            totalSize += [attr fileSize];
        }

        NSString *msg = [NSString stringWithFormat:@"Dumped %lu files (%.1f MB)\n→ Documents/SudokuSolver/",
            (unsigned long)files.count, totalSize / 1048576.0];
        showToast(msg);
    });
}

// ================================================================
#pragma mark - Solve button action
// ================================================================

static void onSolveTapped(void) {
    NSLog(@"[SS] solve tapped");

    // Lazy-init everything on first tap
    if (!gIL2CPPResolved) resolveAPI();
    if (gIL2CPPResolved && !mGetCellAnswer) resolveMethods();
    if (gIL2CPPResolved && mGetCellState && !gHooked) installTargetedHook();

    // Try live solve
    if (gCellsInstance && mGetCellAnswer && mSetCell) {
        if (solveLive()) {
            showToast(@"Solved!");
            return;
        }
    }

    // Fall back to DB
    if (solveDB()) {
        showToast(@"Solved (restart level to see)");
    } else {
        showToast(@"No active game found");
    }
}

// ================================================================
#pragma mark - Floating button
// ================================================================

@interface SSSolveButton : UIButton
@end

@implementation SSSolveButton

- (void)ssTap      { onSolveTapped(); }
- (void)ssDumpLong:(UILongPressGestureRecognizer *)g {
    if (g.state == UIGestureRecognizerStateBegan) onDumpTapped();
}

- (void)ssPan:(UIPanGestureRecognizer *)g {
    CGPoint t = [g translationInView:self.superview];
    self.center = CGPointMake(self.center.x + t.x, self.center.y + t.y);
    [g setTranslation:CGPointZero inView:self.superview];
}

@end

static SSSolveButton *gBtn = nil;

static void addButton(UIWindow *win) {
    if (gBtn || !win) return;

    gBtn = [SSSolveButton buttonWithType:UIButtonTypeCustom];
    gBtn.frame = CGRectMake(win.bounds.size.width - 66, 100, 52, 52);
    gBtn.backgroundColor = [UIColor colorWithRed:0.18 green:0.65 blue:0.35 alpha:0.92];
    gBtn.layer.cornerRadius = 26;
    gBtn.layer.shadowColor   = UIColor.blackColor.CGColor;
    gBtn.layer.shadowOffset  = CGSizeMake(0, 2);
    gBtn.layer.shadowOpacity = 0.35;
    gBtn.layer.shadowRadius  = 4;
    [gBtn setTitle:@"⚡" forState:UIControlStateNormal];
    gBtn.titleLabel.font = [UIFont systemFontOfSize:22];

    [gBtn addTarget:gBtn action:@selector(ssTap)
      forControlEvents:UIControlEventTouchUpInside];

    UIPanGestureRecognizer *pan =
        [[UIPanGestureRecognizer alloc] initWithTarget:gBtn action:@selector(ssPan:)];
    [gBtn addGestureRecognizer:pan];

    UILongPressGestureRecognizer *lp =
        [[UILongPressGestureRecognizer alloc] initWithTarget:gBtn action:@selector(ssDumpLong:)];
    lp.minimumPressDuration = 1.5;
    [gBtn addGestureRecognizer:lp];

    [win addSubview:gBtn];
    NSLog(@"[SS] button added");
}

// ================================================================
#pragma mark - Hooks (minimal — just UIWindow for the button)
// ================================================================

%hook UIWindow

- (void)makeKeyAndVisible {
    %orig;

    // Delay so the app finishes setting up its UI first
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)),
        dispatch_get_main_queue(), ^{
        addButton(self);
    });
}

%end

// ================================================================
#pragma mark - Constructor
// ================================================================

%ctor {
    NSString *bid = [[NSBundle mainBundle] bundleIdentifier];
    NSLog(@"[SS] loaded in %@", bid);

    if (![bid containsString:@"easybrain"]) {
        NSLog(@"[SS] wrong app, skipping");
        return;
    }

    %init;
}
