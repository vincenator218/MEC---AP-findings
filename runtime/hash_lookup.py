#!/usr/bin/env python3
"""
hash_lookup.py -- reverse a live nameHash (captured from RCX/RAX+0x10 in the
stat-formatter at MirrorsEdgeCatalyst.exe+3A1BF63) back to a human-readable
ability/flag name, using the same djb2a hash dictionary decode_save.py
builds from PlayerProgressionData_full.txt.

Usage:
    python hash_lookup.py 0x1a2b3c4d [0x... ...]
"""
import re
import sys


def djb2a(data: bytes) -> int:
    h = 5381
    for b in data:
        h = ((h * 33) ^ b) & 0xFFFFFFFF
    return h


SID_FIELD_PATTERNS = [
    r"\.SyncStatName\s*=\s*'([^']+)'",
    r"\.Name\s*=\s*'([^']+)'",
    r"\.NumberOfFlagsSyncStatName\s*=\s*'([^']+)'",
    r"\.SumOfFlagValuesSyncStatName\s*=\s*'([^']+)'",
    r"\.ActiveNameSid\s*=\s*'([^']+)'",
    r"\.ActiveLongDescSid\s*=\s*'([^']+)'",
]


def build_hash_dictionary(paths):
    names = set()
    for path in paths:
        text = open(path, encoding="utf-8", errors="replace").read()
        for pat in SID_FIELD_PATTERNS:
            for m in re.finditer(pat, text):
                names.add(m.group(1))
    table = {}
    for name in names:
        table[djb2a(name.encode("utf-8"))] = name
    return table


def main():
    if len(sys.argv) < 2:
        print("usage: python hash_lookup.py 0xHASH [0xHASH ...]", file=sys.stderr)
        return 1
    table = build_hash_dictionary(["../gameconfigs/PlayerProgressionData_full.txt"])
    print(f"dictionary: {len(table)} unique hashes")
    for arg in sys.argv[1:]:
        h = int(arg, 16)
        name = table.get(h)
        print(f"  0x{h:08x} -> {name if name else '(not found -- not in this dump, or not a Name/SyncStatName-hashed field)'}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
