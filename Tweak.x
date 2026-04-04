/*
 * SudokuSolver v6 — Easybrain Sudoku (com.easybrain.sudoku)
 *
 * ROOT CAUSE (previous versions):
 *   Unity's OnApplicationPause() fires on background and the game saves
 *   the level state back to saved_progress.data, OVERWRITING our patch.
 *   We were patching before the game saved, so the patch was lost.
 *
 * FIX:
 *   Hook UnityAppController's -applicationDidEnterBackground: which fires
 *   AFTER OnApplicationPause / the game's save. We patch there instead,
 *   0.5 s after the notification to let any async writes finish.
 *
 * Blob layout (confirmed from memory dump):
 *   level blob → grid[0] @+106  : solution (all 1-9, no zeros)
 *   level blob → grid[1] @+432  : puzzle / given cells (zeros = blank)
 *   data  blob → grid[0] @+227  : given cells (mirrors level grid[1])
 *   data  blob → grid[1] @+552  : player entries (zeros = not entered) ← PATCH HERE
 *
 * Usage:
 *   Tap  ⚡  = arm the solve (shows instructions)
 *   Press home button → app backgrounds → patch fires → force-close → reopen = solved
 *   Long ⚡  = dump decrypted binaries → Documents/SudokuSolver/
 */

#import <UIKit/UIKit.h>
#import <dlfcn.h>
#import <sqlite3.h>
#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#import <mach/mach.h>
#import <substrate.h>

// ================================================================
#pragma mark - Globals
// ================================================================

static NSString *gDBPath    = nil;
static BOOL      gSolvePending = NO;   // armed by ⚡ tap, consumed on background

// ================================================================
#pragma mark - Toast
// ================================================================

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
        t.numberOfLines = 0;
        t.textColor = UIColor.whiteColor;
        t.backgroundColor = [UIColor.blackColor colorWithAlphaComponent:0.88];
        t.textAlignment = NSTextAlignmentCenter;
        t.font = [UIFont boldSystemFontOfSize:13];
        t.layer.cornerRadius = 14;
        t.clipsToBounds = YES;
        t.alpha = 0;

        CGSize maxSz = CGSizeMake(win.bounds.size.width - 60, 200);
        CGSize sz = [msg boundingRectWithSize:maxSz
            options:NSStringDrawingUsesLineFragmentOrigin
            attributes:@{NSFontAttributeName: t.font} context:nil].size;

        t.frame = CGRectMake(
            (win.bounds.size.width - sz.width - 32) / 2,
            win.bounds.size.height - 140,
            sz.width + 32, sz.height + 20);
        [win addSubview:t];

        [UIView animateWithDuration:0.25 animations:^{ t.alpha = 1; }
         completion:^(BOOL _) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 4*NSEC_PER_SEC),
                dispatch_get_main_queue(), ^{
                [UIView animateWithDuration:0.25 animations:^{ t.alpha = 0; }
                 completion:^(BOOL _) { [t removeFromSuperview]; }];
            });
        }];
    });
}

// ================================================================
#pragma mark - Database discovery
// ================================================================

static BOOL hasGameTable(NSString *path) {
    sqlite3 *db;
    if (sqlite3_open_v2([path UTF8String], &db, SQLITE_OPEN_READONLY, NULL) != SQLITE_OK)
        return NO;
    BOOL found = NO;
    sqlite3_stmt *st;
    if (sqlite3_prepare_v2(db,
            "SELECT 1 FROM sqlite_master WHERE type='table' AND name='saved_progress'",
            -1, &st, NULL) == SQLITE_OK) {
        found = (sqlite3_step(st) == SQLITE_ROW);
        sqlite3_finalize(st);
    }
    sqlite3_close(db);
    return found;
}

static BOOL isSQLiteFile(NSString *path) {
    NSFileHandle *fh = [NSFileHandle fileHandleForReadingAtPath:path];
    if (!fh) return NO;
    NSData *head = [fh readDataOfLength:16];
    [fh closeFile];
    if (head.length < 16) return NO;
    return memcmp(head.bytes, "SQLite format 3\0", 16) == 0;
}

static NSString *findDB(void) {
    if (gDBPath) return gDBPath;

    NSString *home = NSHomeDirectory();
    NSFileManager *fm = [NSFileManager defaultManager];
    NSDirectoryEnumerator *en = [fm enumeratorAtPath:home];
    NSString *rel;
    NSMutableArray *candidates = [NSMutableArray array];

    while ((rel = [en nextObject])) {
        if ([rel hasPrefix:@"Sudoku.app"] || [rel containsString:@".app/"]) {
            [en skipDescendants]; continue;
        }
        if ([rel containsString:@"Frameworks/"] || [rel containsString:@"PlugIns/"]) {
            [en skipDescendants]; continue;
        }
        NSString *full = [home stringByAppendingPathComponent:rel];
        BOOL isDir = NO;
        [fm fileExistsAtPath:full isDirectory:&isDir];
        if (isDir) continue;

        NSString *ext = [rel pathExtension].lowercaseString;
        if ([ext isEqualToString:@"sqlite"] || [ext isEqualToString:@"sqlite3"] || [ext isEqualToString:@"db"]) {
            [candidates insertObject:full atIndex:0];
            continue;
        }
        NSDictionary *attr = [fm attributesOfItemAtPath:full error:nil];
        unsigned long long sz = [attr fileSize];
        if (sz > 4096 && sz < 500*1024*1024 && isSQLiteFile(full))
            [candidates addObject:full];
    }

    for (NSString *c in candidates) {
        if (hasGameTable(c)) {
            gDBPath = [c copy];
            NSLog(@"[SS] game db: %@", gDBPath);
            return gDBPath;
        }
    }
    return nil;
}

// ================================================================
#pragma mark - Blob grid helpers
// ================================================================

/* Returns array of @(byte_offset) for every run of 81 uint32 LE values all in [0..9].
   Advances past each grid to avoid overlaps. */
static NSArray *findAllGrids(const uint8_t *bytes, NSInteger len) {
    NSMutableArray *r = [NSMutableArray array];
    NSInteger limit = len - 81 * 4, off = 0;
    while (off <= limit) {
        BOOL ok = YES;
        for (int i = 0; i < 81; i++) {
            uint32_t v; memcpy(&v, bytes + off + i*4, 4);
            if (v > 9) { ok = NO; break; }
        }
        if (ok) { [r addObject:@(off)]; off += 81*4; }
        else    off++;
    }
    return r;
}

/* First grid where all 81 values are in [1..9] (no zeros = solution). */
static NSInteger findSolutionGrid(const uint8_t *bytes, NSInteger len) {
    NSInteger limit = len - 81*4;
    for (NSInteger off = 0; off <= limit; off++) {
        BOOL ok = YES;
        for (int i = 0; i < 81; i++) {
            uint32_t v; memcpy(&v, bytes + off + i*4, 4);
            if (v < 1 || v > 9) { ok = NO; break; }
        }
        if (ok) return off;
    }
    return -1;
}

// ================================================================
#pragma mark - Core solve logic
// ================================================================

static NSString *solveViaDB(void) {
    // invalidate cached path so we re-discover (DB might have moved)
    NSString *dbPath = findDB();
    if (!dbPath) return @"No game DB found.\nStart a puzzle first.";

    sqlite3 *db;
    if (sqlite3_open([dbPath UTF8String], &db) != SQLITE_OK)
        return @"Failed to open DB.";

    NSString *result = nil;
    sqlite3_stmt *st;
    const char *q =
        "SELECT sp.rowid, sp.data, sp.level "
        "FROM saved_progress sp "
        "ORDER BY sp.time_unix DESC LIMIT 1";

    if (sqlite3_prepare_v2(db, q, -1, &st, NULL) == SQLITE_OK) {
        if (sqlite3_step(st) == SQLITE_ROW) {
            sqlite3_int64 rowid  = sqlite3_column_int64(st, 0);
            const void *rawData  = sqlite3_column_blob(st, 1);
            int dataLen          = sqlite3_column_bytes(st, 1);
            const void *rawLevel = sqlite3_column_blob(st, 2);
            int levelLen         = sqlite3_column_bytes(st, 2);

            NSLog(@"[SS] rowid=%lld data=%d level=%d", rowid, dataLen, levelLen);

            if (!rawData || !rawLevel || dataLen < 81*4*2 || levelLen < 81*4) {
                result = @"Blob too small.";
            } else {
                const uint8_t *dB = (const uint8_t *)rawData;
                const uint8_t *lB = (const uint8_t *)rawLevel;

                // 1. Extract solution from level blob
                NSInteger solOff = findSolutionGrid(lB, levelLen);
                if (solOff < 0) {
                    result = @"Solution not found in level blob.";
                } else {
                    uint32_t sol[81];
                    for (int i = 0; i < 81; i++)
                        memcpy(&sol[i], lB + solOff + i*4, 4);
                    NSLog(@"[SS] solution @level+%ld: %u %u %u…", (long)solOff, sol[0], sol[1], sol[2]);

                    // 2. Find grids in data blob
                    //    data grid[0] = given cells  (read-only in-game, has puzzle clues)
                    //    data grid[1] = player cells (what we write)
                    NSArray *dGrids = findAllGrids(dB, dataLen);
                    NSLog(@"[SS] data grids: %lu", (unsigned long)dGrids.count);

                    if (dGrids.count < 2) {
                        result = [NSString stringWithFormat:
                            @"Expected ≥2 grids in data blob, got %lu.", (unsigned long)dGrids.count];
                    } else {
                        NSInteger givenOff  = [dGrids[0] integerValue];
                        NSInteger playerOff = [dGrids[1] integerValue];

                        uint32_t given[81];
                        for (int i = 0; i < 81; i++)
                            memcpy(&given[i], dB + givenOff + i*4, 4);

                        NSLog(@"[SS] given@data+%ld  player@data+%ld", (long)givenOff, (long)playerOff);

                        // 3. Patch player cells: write solution for every blank cell
                        NSMutableData *pd = [NSMutableData dataWithBytes:rawData length:dataLen];
                        uint8_t *out = (uint8_t *)pd.mutableBytes;
                        int filled = 0;
                        for (int i = 0; i < 81; i++) {
                            if (given[i] == 0) {
                                memcpy(out + playerOff + i*4, &sol[i], 4);
                                filled++;
                            }
                        }
                        NSLog(@"[SS] filled %d blank cells", filled);

                        // 4. Write back
                        sqlite3_stmt *upd;
                        if (sqlite3_prepare_v2(db,
                                "UPDATE saved_progress SET data=? WHERE rowid=?",
                                -1, &upd, NULL) == SQLITE_OK) {
                            sqlite3_bind_blob(upd, 1, pd.bytes, (int)pd.length, SQLITE_TRANSIENT);
                            sqlite3_bind_int64(upd, 2, rowid);
                            if (sqlite3_step(upd) == SQLITE_DONE)
                                result = @"✅ Solved! Force-close & reopen.";
                            else
                                result = [NSString stringWithFormat:@"Write failed: %s", sqlite3_errmsg(db)];
                            sqlite3_finalize(upd);
                        } else {
                            result = [NSString stringWithFormat:@"Prepare failed: %s", sqlite3_errmsg(db)];
                        }
                    }
                }
            }
        } else {
            result = @"No saved games found.\nStart a puzzle first.";
        }
        sqlite3_finalize(st);
    } else {
        result = [NSString stringWithFormat:@"Query error: %s", sqlite3_errmsg(db)];
    }

    sqlite3_close(db);
    return result ?: @"Unknown error";
}

// ================================================================
#pragma mark - Memory Dumper
// ================================================================

static NSString *dumpDir(void) {
    NSString *d = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents/SudokuSolver"];
    [[NSFileManager defaultManager] createDirectoryAtPath:d
                              withIntermediateDirectories:YES attributes:nil error:nil];
    return d;
}

static BOOL dumpImage(const struct mach_header_64 *hdr, intptr_t slide, NSString *outPath) {
    @try {
        if (!hdr || hdr->magic != MH_MAGIC_64) return NO;
        const uint8_t *ptr = (const uint8_t *)hdr + sizeof(struct mach_header_64);
        uint64_t fileSize = 0;
        for (uint32_t i = 0; i < hdr->ncmds; i++) {
            const struct load_command *lc = (const struct load_command *)ptr;
            if (lc->cmd == LC_SEGMENT_64) {
                const struct segment_command_64 *seg = (const struct segment_command_64 *)ptr;
                uint64_t end = seg->fileoff + seg->filesize;
                if (end > fileSize) fileSize = end;
            }
            ptr += lc->cmdsize;
        }
        if (!fileSize || fileSize > 500*1024*1024) return NO;
        NSMutableData *data = [NSMutableData dataWithLength:(NSUInteger)fileSize];
        if (!data) return NO;
        uint8_t *buf = (uint8_t *)data.mutableBytes;
        ptr = (const uint8_t *)hdr + sizeof(struct mach_header_64);
        for (uint32_t i = 0; i < hdr->ncmds; i++) {
            const struct load_command *lc = (const struct load_command *)ptr;
            if (lc->cmd == LC_SEGMENT_64) {
                const struct segment_command_64 *seg = (const struct segment_command_64 *)ptr;
                if (seg->filesize && seg->fileoff + seg->filesize <= fileSize)
                    memcpy(buf + seg->fileoff, (const void *)(seg->vmaddr + slide), seg->filesize);
            }
            ptr += lc->cmdsize;
        }
        ptr = buf + sizeof(struct mach_header_64);
        for (uint32_t i = 0; i < hdr->ncmds; i++) {
            struct load_command *lc = (struct load_command *)ptr;
            if (lc->cmd == LC_ENCRYPTION_INFO_64)
                ((struct encryption_info_command_64 *)ptr)->cryptid = 0;
            ptr += lc->cmdsize;
        }
        return [data writeToFile:outPath atomically:YES];
    } @catch (NSException *e) { NSLog(@"[SS] dumpImage: %@", e); return NO; }
}

static void performDump(void) {
    NSString *dir = dumpDir();
    NSMutableString *rpt = [NSMutableString string];
    int dumped = 0;
    NSString *appPath = [[NSBundle mainBundle] bundlePath];
    [rpt appendFormat:@"Dump: %@\nBundle: %@\nImages: %u\n\n",
        [NSDate date], [[NSBundle mainBundle] bundleIdentifier], _dyld_image_count()];

    for (uint32_t i = 0; i < _dyld_image_count(); i++) {
        const char *name = _dyld_get_image_name(i);
        const struct mach_header *hdr = _dyld_get_image_header(i);
        intptr_t slide = _dyld_get_image_vmaddr_slide(i);
        if (!name || !hdr) continue;
        NSString *path = [NSString stringWithUTF8String:name];
        if (!((i == 0) || [path containsString:appPath])) continue;
        NSString *imgName = [path lastPathComponent];
        [rpt appendFormat:@"[%u] %@\n  base=%p slide=0x%lx\n", i, imgName, hdr, (long)slide];
        if (hdr->magic == MH_MAGIC_64) {
            NSString *out = [dir stringByAppendingPathComponent:
                [NSString stringWithFormat:@"%@.decrypted", imgName]];
            [[NSFileManager defaultManager] removeItemAtPath:out error:nil];
            BOOL ok = dumpImage((const struct mach_header_64 *)hdr, slide, out);
            [rpt appendFormat:@"  → %@\n", ok ? @"OK" : @"FAIL"];
            if (ok) dumped++;
        }
    }

    NSArray *metaPaths = @[
        [appPath stringByAppendingPathComponent:@"Data/Managed/Metadata/global-metadata.dat"],
        [appPath stringByAppendingPathComponent:@"Frameworks/UnityFramework.framework/Data/Managed/Metadata/global-metadata.dat"],
    ];
    for (NSString *mp in metaPaths) {
        if ([[NSFileManager defaultManager] fileExistsAtPath:mp]) {
            NSString *dst = [dir stringByAppendingPathComponent:@"global-metadata.dat"];
            [[NSFileManager defaultManager] removeItemAtPath:dst error:nil];
            [[NSFileManager defaultManager] copyItemAtPath:mp toPath:dst error:nil];
            [rpt appendFormat:@"\nglobal-metadata.dat: copied\n"]; dumped++; break;
        }
    }
    NSString *dbPath = findDB();
    if (dbPath) {
        NSString *dst = [dir stringByAppendingPathComponent:[dbPath lastPathComponent]];
        [[NSFileManager defaultManager] removeItemAtPath:dst error:nil];
        [[NSFileManager defaultManager] copyItemAtPath:dbPath toPath:dst error:nil];
        [rpt appendFormat:@"\nDB: %@\n", [dbPath lastPathComponent]]; dumped++;
    }
    [rpt appendFormat:@"\nTotal: %d files\n", dumped];
    [rpt writeToFile:[dir stringByAppendingPathComponent:@"dump_report.txt"]
          atomically:YES encoding:NSUTF8StringEncoding error:nil];
    NSLog(@"[SS] dump done: %d files", dumped);
}

// ================================================================
#pragma mark - Button actions
// ================================================================

static void onSolveTapped(void) {
    NSLog(@"[SS] solve tapped – arming");
    gSolvePending = YES;
    showToast(@"⚡ Armed!\n1. Press home button\n2. Force-close the app\n3. Reopen");
}

static void onDumpTapped(void) {
    showToast(@"Dumping…");
    dispatch_async(dispatch_get_global_queue(0, 0), ^{
        performDump();
        NSString *dir = dumpDir();
        NSArray *files = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:dir error:nil];
        unsigned long long total = 0;
        for (NSString *f in files) {
            NSDictionary *a = [[NSFileManager defaultManager]
                attributesOfItemAtPath:[dir stringByAppendingPathComponent:f] error:nil];
            total += [a fileSize];
        }
        showToast([NSString stringWithFormat:@"Dumped %lu files (%.1f MB)\n→ Documents/SudokuSolver/",
            (unsigned long)files.count, total / 1048576.0]);
    });
}

// ================================================================
#pragma mark - Floating button
// ================================================================

@interface SSSolveButton : UIButton
@end

@implementation SSSolveButton
- (void)ssTap  { onSolveTapped(); }
- (void)ssDump:(UILongPressGestureRecognizer *)g {
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
    gBtn.layer.shadowColor = UIColor.blackColor.CGColor;
    gBtn.layer.shadowOffset = CGSizeMake(0, 2);
    gBtn.layer.shadowOpacity = 0.35;
    gBtn.layer.shadowRadius = 4;
    [gBtn setTitle:@"⚡" forState:UIControlStateNormal];
    gBtn.titleLabel.font = [UIFont systemFontOfSize:22];
    [gBtn addTarget:gBtn action:@selector(ssTap) forControlEvents:UIControlEventTouchUpInside];
    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:gBtn action:@selector(ssPan:)];
    [gBtn addGestureRecognizer:pan];
    UILongPressGestureRecognizer *lp = [[UILongPressGestureRecognizer alloc] initWithTarget:gBtn action:@selector(ssDump:)];
    lp.minimumPressDuration = 1.5;
    [gBtn addGestureRecognizer:lp];
    [win addSubview:gBtn];
    NSLog(@"[SS] button added");
}

// ================================================================
#pragma mark - Hook: patch AFTER the game saves on background
// ================================================================

%hook UnityAppController

- (void)applicationDidEnterBackground:(UIApplication *)app {
    %orig;  // Unity's OnApplicationPause fires inside here — game saves state

    if (!gSolvePending) return;

    // Give any async DB writes up to 0.5 s to finish
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
        dispatch_get_global_queue(0, 0), ^{

        if (!gSolvePending) return;
        gSolvePending = NO;

        gDBPath = nil; // force re-discover in case path changed
        NSString *r = solveViaDB();
        NSLog(@"[SS] background solve: %@", r);
        // Can't show a toast here (app is backgrounded) — log is enough.
        // When the user reopens, the board will be solved.
    });
}

%end

// ================================================================
#pragma mark - Hook: UIWindow (add button)
// ================================================================

%hook UIWindow
- (void)makeKeyAndVisible {
    %orig;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)),
        dispatch_get_main_queue(), ^{ addButton(self); });
}
%end

// ================================================================
#pragma mark - Constructor
// ================================================================

%ctor {
    NSString *bid = [[NSBundle mainBundle] bundleIdentifier];
    NSLog(@"[SS] loaded in %@", bid);
    if (![bid containsString:@"easybrain"]) return;
    %init;
}
