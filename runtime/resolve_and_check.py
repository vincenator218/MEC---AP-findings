#!/usr/bin/env python3
"""Resolve captured (RCX, nameHash) pairs to ability names and cross-check
ownership against the live save file. Reuses decode_save.py's hash
dictionary logic and patch_save.py's section-walking logic."""
import re
import struct
import sys

sys.path.insert(0, ".")
from patch_save import find_progression_sections


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


# (RCX, nameHash) pairs captured this round, de-duplicated by RCX (order preserved)
PAIRS = [
    ("2A167638", "92135F48"),
    ("2A18AC50", "427FB289"),
    ("2A193D50", "B4F7A73E"),
    ("2A17DD20", "F139B4B3"),
    ("2A182E88", "732EB4A1"),
    ("2A1834F0", "F996B210"),
    ("2A18A6B0", "2B48D119"),
    ("2A173488", "6F18BEF0"),
    ("2A185FE8", "80E2C6E4"),
    ("2A1729E8", "17EEE7F5"),
    ("2A198698", "6AF13485"),
    ("2A1873E8", "848D8855"),
    ("2A184D00", "848D8854"),
    ("2A18F9F8", "848D8857"),
    ("2A195498", "37A952EC"),
    ("2A16E5F0", "710BF0CB"),
    ("2A175B48", "B794DAFB"),
    ("2A16FD10", "6EE99C14"),
    ("2A17EE28", "243C4904"),
    ("2A187AF0", "56E000EC"),
    ("2A174248", "525F777A"),
    ("2A173668", "071FEB22"),
    ("2A1947F0", "67800619"),
    ("2A181150", "C0B346D0"),
    ("2A172C40", "87156FC6"),
    ("2A192838", "EC427EC6"),
    ("2A182528", "12B6DD5E"),
    ("2A17FBC0", "2CB07F0E"),
    ("2A1851D8", "2B091FD6"),
    ("2A167840", "FE47B0D7"),
    ("2A1797E8", "38B355F9"),
    ("2A191078", "16F58B58"),
    ("2A183068", "E17601CF"),
    ("2A18CC08", "03331FBB"),
    ("2A1943B8", "B75C826E"),
    ("2A16D1F0", "1FEA76A6"),
    ("2A18DE00", "E77600AB"),
]


def main():
    hashdict = build_hash_dictionary(["../gameconfigs/PlayerProgressionData_full.txt"])
    print(f"hash dictionary: {len(hashdict)} unique hashes")

    save_path = "/mnt/user-data/uploads/settings/PROF_SAVE"
    data = open(save_path, "rb").read()
    sections = find_progression_sections(data)
    section_records = {}
    for key, vstart, vallen in sections:
        blob = data[vstart:vstart + vallen]
        count = struct.unpack_from("<I", blob, 144)[0]
        recs = {}
        for i in range(count):
            h, v = struct.unpack_from("<II", blob, 148 + i * 8)
            recs[h] = v
        section_records[key] = recs

    print(f"save sections: {list(section_records.keys())}\n")

    print(f"{'ptr':<10} {'hash':<10} {'name':<45} values-per-section")
    for ptr_hex, hash_hex in PAIRS:
        h = int(hash_hex, 16)
        name = hashdict.get(h)
        vals = []
        for key in section_records:
            v = section_records[key].get(h)
            vals.append(f"{key.replace('ProgressionManagerData','PMD')}={v if v is not None else 'absent'}")
        print(f"{ptr_hex:<10} {hash_hex:<10} {str(name):<45} {'  '.join(vals)}")


if __name__ == "__main__":
    sys.exit(main())
