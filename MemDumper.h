#pragma once
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <mach-o/dyld.h>
#include <mach-o/loader.h>
#include <mach-o/nlist.h>
#include <dlfcn.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <mach/mach.h>

#define DUMP_DIR "/var/mobile/Documents/SudokuDump"

// ─── Helpers ───────────────────────────────────────────────────────────────

static void _dump_mkdir(void) {
    mkdir(DUMP_DIR, 0755);
}

static void _dump_write(const char *filename, const void *data, size_t len) {
    _dump_mkdir();
    char path[512];
    snprintf(path, sizeof(path), DUMP_DIR "/%s", filename);
    FILE *f = fopen(path, "wb");
    if (f) { fwrite(data, 1, len, f); fclose(f); }
}

static void _dump_log(FILE *log, const char *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    vfprintf(log, fmt, ap);
    va_end(ap);
    fflush(log);
}

// ─── Find target image ─────────────────────────────────────────────────────

static const struct mach_header_64 *_find_sudoku_header(uintptr_t *out_slide) {
    uint32_t count = _dyld_image_count();
    for (uint32_t i = 0; i < count; i++) {
        const char *name = _dyld_get_image_name(i);
        if (name && strstr(name, "Sudoku") && !strstr(name, ".dylib") && !strstr(name, "framework")) {
            if (out_slide) *out_slide = (uintptr_t)_dyld_get_image_vmaddr_slide(i);
            return (const struct mach_header_64 *)_dyld_get_image_header(i);
        }
    }
    // fallback: image 0 is usually the main executable
    if (out_slide) *out_slide = (uintptr_t)_dyld_get_image_vmaddr_slide(0);
    return (const struct mach_header_64 *)_dyld_get_image_header(0);
}

// ─── Scan for il2cpp domain/class API ──────────────────────────────────────

typedef void* (*il2cpp_domain_get_t)(void);
typedef void* (*il2cpp_domain_get_assemblies_t)(void *domain, size_t *size);
typedef void* (*il2cpp_assembly_get_image_t)(void *assembly);
typedef void* (*il2cpp_image_get_class_t)(void *image, size_t index);
typedef size_t (*il2cpp_image_get_class_count_t)(void *image);
typedef const char* (*il2cpp_class_get_name_t)(void *klass);
typedef void* (*il2cpp_class_get_method_from_name_t)(void *klass, const char *name, int argsCount);
typedef void* (*il2cpp_method_get_object_t)(void *method, void *refclass);
typedef uintptr_t (*il2cpp_resolve_icall_t)(const char *name);

typedef struct {
    il2cpp_domain_get_t domain_get;
    il2cpp_domain_get_assemblies_t domain_get_assemblies;
    il2cpp_assembly_get_image_t assembly_get_image;
    il2cpp_image_get_class_t image_get_class;
    il2cpp_image_get_class_count_t image_get_class_count;
    il2cpp_class_get_name_t class_get_name;
    il2cpp_class_get_method_from_name_t class_get_method_from_name;
    il2cpp_resolve_icall_t resolve_icall;
} Il2CppAPI;

static int _resolve_il2cpp_api(Il2CppAPI *api, FILE *log) {
    void *handle = RTLD_DEFAULT;
    memset(api, 0, sizeof(*api));

    const char *syms[] = {
        "il2cpp_domain_get",
        "il2cpp_domain_get_assemblies",
        "il2cpp_assembly_get_image",
        "il2cpp_image_get_class",
        "il2cpp_image_get_class_count",
        "il2cpp_class_get_name",
        "il2cpp_class_get_method_from_name",
        "il2cpp_resolve_icall",
    };
    void **ptrs[] = {
        (void**)&api->domain_get,
        (void**)&api->domain_get_assemblies,
        (void**)&api->assembly_get_image,
        (void**)&api->image_get_class,
        (void**)&api->image_get_class_count,
        (void**)&api->class_get_name,
        (void**)&api->class_get_method_from_name,
        (void**)&api->resolve_icall,
    };
    int found = 0;
    for (int i = 0; i < 8; i++) {
        *ptrs[i] = dlsym(handle, syms[i]);
        if (*ptrs[i]) {
            _dump_log(log, "[API] %s = %p\n", syms[i], *ptrs[i]);
            found++;
        } else {
            _dump_log(log, "[API] %s = NOT FOUND\n", syms[i]);
        }
    }
    return found;
}

// ─── Pattern scanner ───────────────────────────────────────────────────────

// Search for a byte pattern in a memory range
// pattern: bytes to match, mask: 'x' = match, '?' = wildcard
static uintptr_t _pattern_scan(const uint8_t *base, size_t len,
                                const uint8_t *pattern, const char *mask, size_t plen) {
    for (size_t i = 0; i + plen <= len; i++) {
        int ok = 1;
        for (size_t j = 0; j < plen; j++) {
            if (mask[j] == 'x' && base[i+j] != pattern[j]) { ok = 0; break; }
        }
        if (ok) return (uintptr_t)(base + i);
    }
    return 0;
}

// ─── String scanner ─────────────────────────────────────────────────────────

// Find all occurrences of a string in a memory range and log their VA
static void _scan_string(const uint8_t *base, size_t len, uintptr_t va_base,
                          const char *needle, FILE *log, const char *section_name) {
    size_t nlen = strlen(needle);
    for (size_t i = 0; i + nlen <= len; i++) {
        if (memcmp(base + i, needle, nlen) == 0) {
            _dump_log(log, "[STR] \"%s\" found in %s at VA %#lx (file+%#lx)\n",
                      needle, section_name, va_base + i, i);
        }
    }
}

// ─── Main dump function ─────────────────────────────────────────────────────

/*
 * sudoku_memdump()
 *
 * Call this from your tweak at a good time (e.g. after first viewDidAppear).
 * It will:
 *   1. Locate the Sudoku image and dump all its sections from live memory
 *   2. Scan for key IL2CPP strings to locate CodeRegistration / class descriptors
 *   3. Try dlsym for IL2CPP API functions and log their addresses
 *   4. Write everything to DUMP_DIR
 *
 * After dumping, copy the files off-device and run the included
 * analyze_dump.py against dump_DATA.bin + dump_log.txt to extract
 * method pointers with ASLR removed.
 */
static void sudoku_memdump(void) {
    _dump_mkdir();

    char logpath[512];
    snprintf(logpath, sizeof(logpath), DUMP_DIR "/dump_log.txt");
    FILE *log = fopen(logpath, "w");
    if (!log) return;

    uintptr_t slide = 0;
    const struct mach_header_64 *hdr = _find_sudoku_header(&slide);
    if (!hdr) { _dump_log(log, "[ERR] Could not find Sudoku image\n"); fclose(log); return; }

    uintptr_t base = (uintptr_t)hdr;
    _dump_log(log, "[INFO] Image base (with ASLR): %#lx\n", base);
    _dump_log(log, "[INFO] ASLR slide: %#lx\n", slide);
    _dump_log(log, "[INFO] Static base (no slide): %#lx\n", base - slide);

    // Try IL2CPP API via dlsym
    Il2CppAPI api;
    int api_found = _resolve_il2cpp_api(&api, log);
    _dump_log(log, "[INFO] IL2CPP API symbols found via dlsym: %d/8\n", api_found);

    if (api_found >= 4 && api.domain_get) {
        _dump_log(log, "[IL2CPP] Attempting runtime class enumeration...\n");
        void *domain = api.domain_get();
        _dump_log(log, "[IL2CPP] Domain: %p\n", domain);
        if (domain && api.domain_get_assemblies) {
            size_t asm_count = 0;
            void **assemblies = api.domain_get_assemblies(domain, &asm_count);
            _dump_log(log, "[IL2CPP] Assembly count: %zu\n", asm_count);
            for (size_t ai = 0; ai < asm_count && assemblies; ai++) {
                void *img = api.assembly_get_image ? api.assembly_get_image(assemblies[ai]) : NULL;
                if (!img) continue;
                size_t cls_count = api.image_get_class_count ? api.image_get_class_count(img) : 0;
                for (size_t ci = 0; ci < cls_count; ci++) {
                    void *klass = api.image_get_class ? api.image_get_class(img, ci) : NULL;
                    if (!klass) continue;
                    const char *name = api.class_get_name ? api.class_get_name(klass) : NULL;
                    if (name && (strstr(name, "Board") || strstr(name, "Cell") ||
                                 strstr(name, "Sudoku") || strstr(name, "Level") ||
                                 strstr(name, "Game"))) {
                        _dump_log(log, "[CLASS] %s @ %p\n", name, klass);
                        // Try to find key methods
                        const char *methods[] = {
                            "GetCellAnswer", "SetCell", "IsCellMutable",
                            "GetCellState", "IsAllCellsFull", "IsResolved",
                            "get_Cells", "NewGame", "LoadPuzzle", NULL
                        };
                        for (int mi = 0; methods[mi]; mi++) {
                            void *meth = api.class_get_method_from_name ?
                                api.class_get_method_from_name(klass, methods[mi], -1) : NULL;
                            if (meth) {
                                // method pointer is at offset 0 in MethodInfo struct
                                uintptr_t fptr = *(uintptr_t *)meth;
                                uintptr_t rva = fptr - slide - 0x100000000UL;
                                _dump_log(log, "  [METHOD] %s::%s fptr=%#lx RVA=%#lx\n",
                                          name, methods[mi], fptr, rva);
                            }
                        }
                    }
                }
            }
        }
    }

    // Walk load commands and dump each segment/section from live memory
    uint32_t ncmds = hdr->ncmds;
    const uint8_t *lcptr = (const uint8_t *)(hdr + 1);

    const char *targets[] = {
        "BoardModelCells", "BoardModelBase", "CellData", "LevelSaveConfig",
        "GetCellAnswer", "SetCell", "IsCellMutable", "solution",
        "mscorlib", "__il2cpp", "CodeRegistration", NULL
    };

    for (uint32_t i = 0; i < ncmds; i++) {
        const struct load_command *lc = (const struct load_command *)lcptr;
        if (lc->cmd == LC_SEGMENT_64) {
            const struct segment_command_64 *seg = (const struct segment_command_64 *)lc;
            char segname[17] = {0};
            memcpy(segname, seg->segname, 16);

            // Only dump writable data segments (they change at runtime / hold pointers)
            int is_data = (strncmp(segname, "__DATA", 6) == 0);
            int is_text = (strncmp(segname, "__TEXT", 6) == 0);

            if (is_data || is_text) {
                uintptr_t seg_va = base + (seg->vmaddr - (base - slide)); // runtime VA
                // Actually: runtime addr = seg->vmaddr + slide
                uintptr_t seg_runtime = seg->vmaddr + slide;
                size_t seg_size = (size_t)seg->vmsize;

                // Clamp to reasonable size
                if (seg_size > 64 * 1024 * 1024) seg_size = 64 * 1024 * 1024;

                _dump_log(log, "[SEG] %s vmaddr=%#llx runtime=%#lx size=%#lx\n",
                          segname, seg->vmaddr, seg_runtime, seg_size);

                // Scan for important strings in this segment
                const uint8_t *seg_mem = (const uint8_t *)seg_runtime;
                for (int ti = 0; targets[ti]; ti++) {
                    _scan_string(seg_mem, seg_size, seg_runtime, targets[ti], log, segname);
                }

                // Dump DATA segments to file (they contain runtime pointer arrays)
                if (is_data) {
                    char fname[64];
                    // Replace / and spaces in segname
                    char safe_seg[17] = {0};
                    for (int si = 0; si < 16 && segname[si]; si++)
                        safe_seg[si] = (segname[si] == '/' || segname[si] == ' ') ? '_' : segname[si];
                    snprintf(fname, sizeof(fname), "dump_%s.bin", safe_seg + 2); // skip __
                    _dump_write(fname, seg_mem, seg_size);
                    _dump_log(log, "[DUMP] Wrote %s (%zu bytes)\n", fname, seg_size);
                }

                // For __DATA, also log every 8-byte aligned pointer that falls
                // within the text section range (potential code pointers)
                if (is_data) {
                    uintptr_t text_start = 0x100008000 + slide;
                    uintptr_t text_end   = 0x102320000 + slide;
                    _dump_log(log, "[PTR_SCAN] Scanning %s for code pointers [%#lx-%#lx]...\n",
                              segname, text_start, text_end);
                    int ptr_count = 0;
                    for (size_t off = 0; off + 8 <= seg_size; off += 8) {
                        uintptr_t val = *(uintptr_t *)(seg_runtime + off);
                        if (val >= text_start && val < text_end) {
                            uintptr_t rva = val - slide - 0x100000000UL;
                            _dump_log(log, "  [PTR] %s+%#lx -> VA=%#lx RVA=%#lx\n",
                                      segname, off, val, rva);
                            if (++ptr_count > 50000) {
                                _dump_log(log, "  [PTR] ... truncated (>50k ptrs)\n");
                                break;
                            }
                        }
                    }
                    _dump_log(log, "[PTR_SCAN] Found %d code pointers in %s\n", ptr_count, segname);
                }

                // Walk sections and dump each
                const struct section_64 *sects = (const struct section_64 *)(seg + 1);
                for (uint32_t si = 0; si < seg->nsects; si++) {
                    char sectname[17] = {0};
                    memcpy(sectname, sects[si].sectname, 16);
                    uintptr_t sect_runtime = sects[si].addr + slide;
                    size_t sect_size = (size_t)sects[si].size;
                    if (sect_size > 32 * 1024 * 1024) sect_size = 32 * 1024 * 1024;
                    _dump_log(log, "  [SECT] %s.%s addr=%#llx runtime=%#lx size=%#lx\n",
                              segname, sectname, sects[si].addr, sect_runtime, sect_size);
                }
            }
        }
        lcptr += lc->cmdsize;
    }

    // Also try to find CodeRegistration by scanning for method count patterns
    // IL2CPP v31 CodeRegistration starts with: methodPointerCount (uint64), then methodPointers[]
    // We expect ~100k+ methods in a full game
    _dump_log(log, "[SCAN] Searching for CodeRegistration pattern...\n");
    {
        uintptr_t data_runtime = 0x102df8000 + slide; // __DATA_CONST.__got
        // We'll scan __DATA for large uint64 values that could be method pointer counts
        // Typical Unity game has 50000-300000 methods
        uintptr_t scan_start = 0x103048000 + slide;
        uintptr_t scan_size  = 0x2b99a8; // __DATA.__objc_const
        for (size_t off = 0; off + 8 <= scan_size; off += 8) {
            uint64_t val = *(uint64_t *)(scan_start + off);
            if (val >= 50000 && val <= 500000) {
                // Candidate: check if next value is a pointer into __TEXT
                uint64_t next = *(uint64_t *)(scan_start + off + 8);
                uintptr_t text_s = 0x100008000 + slide;
                uintptr_t text_e = 0x102320bc4 + slide;
                if (next >= text_s && next < text_e) {
                    _dump_log(log, "[CODEREG?] Found candidate at %#lx: count=%llu firstPtr=%#llx RVA=%#lx\n",
                              scan_start + off, val, next, next - slide - 0x100000000UL);
                }
            }
        }
    }

    _dump_log(log, "[DONE] Memory dump complete. Copy " DUMP_DIR " off device.\n");
    _dump_log(log, "[DONE] Run: python3 analyze_dump.py dump_log.txt\n");
    fclose(log);
}

// ─── Quick pointer resolver (use after memdump gives you RVAs) ─────────────

/*
 * After running the dump and analyzing dump_log.txt, replace these
 * RVA values with the real ones found in the log under [METHOD].
 * These are compiled-in as placeholders.
 */
#define RVA_GetCellAnswer  0x0  // PLACEHOLDER — fill from dump_log.txt
#define RVA_SetCell        0x0  // PLACEHOLDER
#define RVA_IsCellMutable  0x0  // PLACEHOLDER

static uintptr_t _rva_to_ptr(uintptr_t rva) {
    if (rva == 0) return 0;
    uintptr_t slide = 0;
    _find_sudoku_header(&slide);
    return rva + 0x100000000UL + slide;
}
