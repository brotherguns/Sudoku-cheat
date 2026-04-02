#!/usr/bin/env python3
"""
analyze_dump.py — post-process SudokuSolver memory dump

Usage:
    python3 analyze_dump.py /path/to/SudokuDump/dump_log.txt

This script:
 1. Parses dump_log.txt to extract all found RVAs
 2. Identifies likely CodeRegistration + method table
 3. Generates a patched Tweak.x snippet with hard-coded RVA_* defines
 4. Outputs a summary of what to plug into MemDumper.h
"""

import re
import sys
import os
from collections import defaultdict

def parse_log(path):
    with open(path, 'r', errors='replace') as f:
        text = f.read()

    lines = text.splitlines()
    results = {
        'slide': None,
        'base': None,
        'api_symbols': {},
        'classes': defaultdict(dict),  # class_name -> {method_name: rva}
        'strings': [],
        'code_regs': [],
        'ptr_clusters': defaultdict(list),  # RVA region -> [ptrs]
    }

    current_class = None

    for line in lines:
        # Base / slide
        m = re.search(r'ASLR slide: (0x[0-9a-f]+)', line)
        if m: results['slide'] = int(m.group(1), 16)

        m = re.search(r'Image base \(with ASLR\): (0x[0-9a-f]+)', line)
        if m: results['base'] = int(m.group(1), 16)

        # IL2CPP API symbols
        m = re.search(r'\[API\] (il2cpp_\w+) = (0x[0-9a-f]+)', line)
        if m: results['api_symbols'][m.group(1)] = int(m.group(2), 16)

        # Classes
        m = re.search(r'\[CLASS\] (\w+) @ (0x[0-9a-f]+)', line)
        if m:
            current_class = m.group(1)
            results['classes'][current_class]['_ptr'] = int(m.group(2), 16)

        # Methods
        m = re.search(r'\[METHOD\] (\w+)::(\w+) fptr=(0x[0-9a-f]+) RVA=(0x[0-9a-f]+)', line)
        if m:
            cls, meth, fptr, rva = m.group(1), m.group(2), int(m.group(3), 16), int(m.group(4), 16)
            results['classes'][cls][meth] = {'fptr': fptr, 'rva': rva}

        # String matches
        m = re.search(r'\[STR\] "(.+)" found in (\S+) at VA (0x[0-9a-f]+)', line)
        if m:
            results['strings'].append({
                'str': m.group(1), 'section': m.group(2), 'va': int(m.group(3), 16)
            })

        # CodeRegistration candidates
        m = re.search(r'\[CODEREG\?\] Found candidate at (0x[0-9a-f]+): count=(\d+) firstPtr=(0x[0-9a-f]+) RVA=(0x[0-9a-f]+)', line)
        if m:
            results['code_regs'].append({
                'addr': int(m.group(1), 16),
                'count': int(m.group(2)),
                'first_ptr': int(m.group(3), 16),
                'first_rva': int(m.group(4), 16),
            })

    return results

def print_report(results):
    print("=" * 60)
    print("SudokuSolver Dump Analysis")
    print("=" * 60)

    slide = results['slide']
    base  = results['base']
    print(f"\n[+] ASLR slide : {slide:#x}" if slide else "\n[!] ASLR slide : not found")
    print(f"[+] Image base : {base:#x}" if base else "[!] Image base : not found")

    print(f"\n[+] IL2CPP API symbols via dlsym ({len(results['api_symbols'])} found):")
    if results['api_symbols']:
        for sym, addr in results['api_symbols'].items():
            rva = addr - slide - 0x100000000 if slide else 0
            print(f"    {sym:45s} VA={addr:#x}  RVA={rva:#x}")
    else:
        print("    NONE — IL2CPP symbols are fully stripped.")
        print("    You'll need to use the RVA-based approach with hard-coded offsets.")

    print(f"\n[+] Classes found ({len(results['classes'])}):")
    key_classes = ['BoardModelCells', 'BoardModelBase', 'CellData', 'LevelSaveConfig']
    all_cls = sorted(results['classes'].keys())
    for cls in key_classes + [c for c in all_cls if c not in key_classes]:
        if cls not in results['classes']: continue
        methods = {k: v for k, v in results['classes'][cls].items() if k != '_ptr'}
        ptr = results['classes'][cls].get('_ptr', 0)
        print(f"\n  {cls} @ {ptr:#x}")
        for meth, info in methods.items():
            print(f"    {meth:30s} RVA={info['rva']:#x}  fptr={info['fptr']:#x}")

    print(f"\n[+] CodeRegistration candidates ({len(results['code_regs'])}):")
    for cr in results['code_regs']:
        print(f"    addr={cr['addr']:#x}  count={cr['count']}  firstPtr={cr['first_ptr']:#x}  RVA={cr['first_rva']:#x}")

    print(f"\n[+] Key strings found:")
    for s in results['strings']:
        rva = s['va'] - slide - 0x100000000 if slide else 0
        print(f"    \"{s['str']}\" in {s['section']} VA={s['va']:#x} RVA={rva:#x}")

    # Generate Tweak defines
    print("\n" + "=" * 60)
    print("GENERATED MemDumper.h DEFINES (paste these in):")
    print("=" * 60)
    key_methods = {
        'RVA_GetCellAnswer': ('BoardModelCells', 'GetCellAnswer'),
        'RVA_SetCell':       ('BoardModelCells', 'SetCell'),
        'RVA_IsCellMutable': ('BoardModelCells', 'IsCellMutable'),
    }
    for define, (cls, meth) in key_methods.items():
        rva = 0
        if cls in results['classes'] and meth in results['classes'][cls]:
            rva = results['classes'][cls][meth]['rva']
        print(f"#define {define:<20s} {rva:#x}  // {cls}::{meth}")

    print("\nNext steps:")
    if not results['api_symbols']:
        print("  1. IL2CPP symbols are stripped — use Frida or a debugger to find method ptrs")
        print("     frida -U -n 'Sudoku' -e 'Process.enumerateModules().forEach(m => console.log(m.name, m.base))'")
        print("  2. Or use the CodeRegistration candidates to scan the method pointer array")
        print("  3. Or rely on the SQLite hook (already in Tweak.x) — just tap SOLVE")
    else:
        print("  1. Paste the defines above into MemDumper.h")
        print("  2. Recompile Tweak.x — direct IL2CPP calls will now work")

if __name__ == '__main__':
    if len(sys.argv) < 2:
        print(f"Usage: {sys.argv[0]} dump_log.txt")
        sys.exit(1)

    path = sys.argv[1]
    if not os.path.exists(path):
        print(f"File not found: {path}")
        sys.exit(1)

    results = parse_log(path)
    print_report(results)
