/*
 * SudokuSolver v4 — Easybrain Sudoku (com.easybrain.sudoku)
 *
 * Fixed: targets real DB schema (saved_progress table, not SudokuGame).
 * The game stores puzzle/solution data as binary blobs:
 *   level blob : solution — 81×uint32 LE, values 1-9, no zeros
 *   level blob : puzzle   — 81×uint32 LE, values 0-9, zeros = empty
 *   data  blob : cells    — 81×uint32 LE, current cell state (what we overwrite)
 *
 * Tap  ⚡ = solve the active game via blob patch
 * Long ⚡ = dump decrypted binaries + metadata to Documents/SudokuSolver/
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

static NSString *gDBPath = nil;

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
        t.backgroundColor = [UIColor.blackColor colorWithAlphaComponent:0.85];
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
         completion:^(BOOL d) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3*NSEC_PER_SEC),
                dispatch_get_main_queue(), ^{
                [UIView animateWithDuration:0.25 animations:^{ t.alpha = 0; }
                 completion:^(BOOL d2) { [t removeFromSuperview]; }];
            });
        }];
    });
}

// ================================================================
#pragma mark - Database discovery
// ================================================================

// Check for the real Easybrain save-state table.
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
        if (sz > 4096 && sz < 500*1024*1024) {
            if (isSQLiteFile(full)) [candidates addObject:full];
        }
    }

    NSLog(@"[SS] found %lu SQLite candidates", (unsigned long)candidates.count);

    for (NSString *c in candidates) {
        NSLog(@"[SS] checking: %@", [c stringByReplacingOccurrencesOfString:home withString:@"~"]);
        if (hasGameTable(c)) {
            gDBPath = [c copy];
            NSLog(@"[SS] found game db: %@", gDBPath);
            return gDBPath;
        }
    }

    NSLog(@"[SS] no saved_progress table found in %lu candidates", (unsigned long)candidates.count);
    return nil;
}

// ================================================================
#pragma mark - Blob grid scanner
// ================================================================

/*
 * scanForGrid — byte-by-byte scan for 81 consecutive uint32 LE values
 * all within [0..9]. If requireNonZero, also rejects zeros (finds solution).
 * Returns byte offset, or -1 if not found.
 *
 * Blobs are typically ~800-1000 bytes, so this is fast.
 */
static NSInteger scanForGrid(const uint8_t *bytes, NSInteger len, BOOL requireNonZero) {
    NSInteger limit = len - 81 * 4;
    for (NSInteger off = 0; off <= limit; off++) {
        BOOL valid = YES;
        for (int i = 0; i < 81; i++) {
            uint32_t v;
            memcpy(&v, bytes + off + i * 4, 4);
            // arm64 is LE, so no swap needed
            if (v > 9 || (requireNonZero && v == 0)) { valid = NO; break; }
        }
        if (valid) return off;
    }
    return -1;
}

// ================================================================
#pragma mark - Solve via DB (blob patch)
// ================================================================

static NSString *solveViaDB(void) {
    NSString *dbPath = findDB();
    if (!dbPath) return @"No game database found.\nStart a puzzle first.";

    sqlite3 *db;
    if (sqlite3_open([dbPath UTF8String], &db) != SQLITE_OK)
        return @"Failed to open database.";

    NSString *result = nil;
    sqlite3_stmt *st;

    const char *query =
        "SELECT sp.rowid, sp.data, sp.level "
        "FROM saved_progress sp "
        "ORDER BY sp.time_unix DESC LIMIT 1";

    if (sqlite3_prepare_v2(db, query, -1, &st, NULL) == SQLITE_OK) {
        if (sqlite3_step(st) == SQLITE_ROW) {
            sqlite3_int64 rowid  = sqlite3_column_int64(st, 0);
            const void *rawData  = sqlite3_column_blob(st, 1);
            int dataLen          = sqlite3_column_bytes(st, 1);
            const void *rawLevel = sqlite3_column_blob(st, 2);
            int levelLen         = sqlite3_column_bytes(st, 2);

            NSLog(@"[SS] rowid=%lld data=%d bytes level=%d bytes", rowid, dataLen, levelLen);

            if (!rawData || !rawLevel || dataLen < 81*4 || levelLen < 81*4) {
                result = @"Blob too small — unexpected format.";
            } else {
                const uint8_t *dataBytes  = (const uint8_t *)rawData;
                const uint8_t *levelBytes = (const uint8_t *)rawLevel;

                // 1. Find the solution in the level blob (81 values, all 1-9, no zeros)
                NSInteger solOffset = scanForGrid(levelBytes, levelLen, YES);
                if (solOffset < 0) {
                    result = @"Solution not found in level data.\n(Try a different game mode.)";
                } else {
                    uint32_t solution[81];
                    for (int i = 0; i < 81; i++)
                        memcpy(&solution[i], levelBytes + solOffset + i * 4, 4);

                    NSLog(@"[SS] solution at level+%ld: %u %u %u ...",
                          (long)solOffset, solution[0], solution[1], solution[2]);

                    // 2. Find the current cell array in the data blob (values 0-9, zeros OK)
                    NSInteger cellOffset = scanForGrid(dataBytes, dataLen, NO);
                    if (cellOffset < 0) {
                        result = @"Cell array not found in save data.\n(Try re-entering the puzzle.)";
                    } else {
                        NSLog(@"[SS] cells at data+%ld", (long)cellOffset);

                        // 3. Patch: overwrite cell array with solution
                        NSMutableData *patchedData =
                            [NSMutableData dataWithBytes:rawData length:dataLen];
                        uint8_t *out = (uint8_t *)patchedData.mutableBytes;

                        for (int i = 0; i < 81; i++)
                            memcpy(out + cellOffset + i * 4, &solution[i], 4);

                        // 4. Write patched blob back
                        sqlite3_stmt *upd;
                        if (sqlite3_prepare_v2(db,
                                "UPDATE saved_progress SET data = ? WHERE rowid = ?",
                                -1, &upd, NULL) == SQLITE_OK) {
                            sqlite3_bind_blob(upd, 1,
                                patchedData.bytes, (int)patchedData.length, SQLITE_TRANSIENT);
                            sqlite3_bind_int64(upd, 2, rowid);
                            if (sqlite3_step(upd) == SQLITE_DONE)
                                result = @"Solved!\nForce-close & reopen to see it.";
                            else
                                result = [NSString stringWithFormat:@"Write failed: %s",
                                          sqlite3_errmsg(db)];
                            sqlite3_finalize(upd);
                        } else {
                            result = [NSString stringWithFormat:@"Prepare failed: %s",
                                      sqlite3_errmsg(db)];
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

        if (fileSize == 0 || fileSize > 500*1024*1024) return NO;

        NSMutableData *data = [NSMutableData dataWithLength:(NSUInteger)fileSize];
        if (!data) return NO;
        uint8_t *buf = (uint8_t *)data.mutableBytes;

        ptr = (const uint8_t *)hdr + sizeof(struct mach_header_64);
        for (uint32_t i = 0; i < hdr->ncmds; i++) {
            const struct load_command *lc = (const struct load_command *)ptr;
            if (lc->cmd == LC_SEGMENT_64) {
                const struct segment_command_64 *seg = (const struct segment_command_64 *)ptr;
                if (seg->filesize > 0 && seg->fileoff + seg->filesize <= fileSize) {
                    const void *src = (const void *)(seg->vmaddr + slide);
                    memcpy(buf + seg->fileoff, src, (size_t)seg->filesize);
                }
            }
            ptr += lc->cmdsize;
        }

        ptr = buf + sizeof(struct mach_header_64);
        for (uint32_t i = 0; i < hdr->ncmds; i++) {
            struct load_command *lc = (struct load_command *)ptr;
            if (lc->cmd == LC_ENCRYPTION_INFO_64) {
                ((struct encryption_info_command_64 *)ptr)->cryptid = 0;
            }
            ptr += lc->cmdsize;
        }

        return [data writeToFile:outPath atomically:YES];
    } @catch (NSException *e) {
        NSLog(@"[SS] dump exception: %@", e);
        return NO;
    }
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
        NSString *imgName = [path lastPathComponent];

        BOOL shouldDump = (i == 0) || [path containsString:appPath];
        if (!shouldDump) continue;

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
            [rpt appendFormat:@"\nglobal-metadata.dat: copied\n"];
            dumped++;
            break;
        }
    }

    NSString *dbPath = findDB();
    if (dbPath) {
        NSString *dst = [dir stringByAppendingPathComponent:[dbPath lastPathComponent]];
        [[NSFileManager defaultManager] removeItemAtPath:dst error:nil];
        [[NSFileManager defaultManager] copyItemAtPath:dbPath toPath:dst error:nil];
        [rpt appendFormat:@"\nDB: copied %@\n", [dbPath lastPathComponent]];
        dumped++;
    }

    NSMutableString *fileList = [NSMutableString stringWithString:@"App container files:\n"];
    NSString *home = NSHomeDirectory();
    NSDirectoryEnumerator *en = [[NSFileManager defaultManager] enumeratorAtPath:home];
    NSString *rel;
    while ((rel = [en nextObject])) {
        if ([rel containsString:@".app/"]) { [en skipDescendants]; continue; }
        NSDictionary *attr = [[NSFileManager defaultManager]
            attributesOfItemAtPath:[home stringByAppendingPathComponent:rel] error:nil];
        [fileList appendFormat:@"  %@ (%llu bytes)\n", rel, [attr fileSize]];
    }
    [fileList writeToFile:[dir stringByAppendingPathComponent:@"container_files.txt"]
               atomically:YES encoding:NSUTF8StringEncoding error:nil];

    [rpt appendFormat:@"\nTotal: %d files dumped to Documents/SudokuSolver/\n", dumped];
    [rpt writeToFile:[dir stringByAppendingPathComponent:@"dump_report.txt"]
          atomically:YES encoding:NSUTF8StringEncoding error:nil];

    NSLog(@"[SS] dump done: %d files", dumped);
}

// ================================================================
#pragma mark - Button actions
// ================================================================

static void onSolveTapped(void) {
    NSLog(@"[SS] solve tapped");
    NSString *result = solveViaDB();
    showToast(result);
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

- (void)ssTap { onSolveTapped(); }

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

    [gBtn addTarget:gBtn action:@selector(ssTap)
      forControlEvents:UIControlEventTouchUpInside];

    UIPanGestureRecognizer *pan =
        [[UIPanGestureRecognizer alloc] initWithTarget:gBtn action:@selector(ssPan:)];
    [gBtn addGestureRecognizer:pan];

    UILongPressGestureRecognizer *lp =
        [[UILongPressGestureRecognizer alloc] initWithTarget:gBtn action:@selector(ssDump:)];
    lp.minimumPressDuration = 1.5;
    [gBtn addGestureRecognizer:lp];

    [win addSubview:gBtn];
    NSLog(@"[SS] button added");
}

// ================================================================
#pragma mark - Hook (UIWindow only)
// ================================================================

%hook UIWindow

- (void)makeKeyAndVisible {
    %orig;
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
    if (![bid containsString:@"easybrain"]) return;
    %init;
}
