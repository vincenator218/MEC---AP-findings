#!/usr/bin/env python3
"""
clear_category.py -- remove every record for a category entirely (not just
set value=0), across all ProgressionManagerData* sections, shrinking each
blob and re-padding the file's zero tail to keep the total size constant.
The inverse of mass_set_collectibles.py's insertion.

Usage:
    python clear_category.py PROF_SAVE PlayerProgressionData_full.txt --category GridLeaks --out PROF_SAVE.zerogl
"""
import argparse
import re
import struct
import sys

from save_checksum import recompute_checksums

CATEGORY_PATTERNS = {
    "GridLeaks": re.compile(r"^([A-Za-z]+)GridLeaks_\1CompulsionOrb[0-9A-Fa-f-]{36}$"),
}


def djb2a(data: bytes) -> int:
    h = 5381
    for b in data:
        h = ((h * 33) ^ b) & 0xFFFFFFFF
    return h


def real_names_for_category(static_dump_paths, category):
    pat = CATEGORY_PATTERNS[category]
    names = set()
    for path in static_dump_paths:
        text = open(path, encoding="utf-8", errors="replace").read()
        for m in re.finditer(r"\.Name\s*=\s*'([^']+)'", text):
            if pat.match(m.group(1)):
                names.add(m.group(1))
    return names


def read_u32(data, pos):
    return struct.unpack_from("<I", data, pos)[0]


def parse_kv_entry(data, pos):
    n = len(data)
    if pos + 8 > n:
        return None
    keylen = read_u32(data, pos + 4)
    if keylen == 0 or keylen > 256 or pos + 8 + keylen > n:
        return None
    key = data[pos + 8: pos + 8 + keylen]
    if not key.endswith(b"\x00") or not all(32 <= c < 127 for c in key[:-1]):
        return None
    keystr = key[:-1].decode("latin1")
    vpos = pos + 8 + keylen
    if vpos + 4 > n:
        return None
    vallen = read_u32(data, vpos)
    if vallen > 5_000_000 or vpos + 4 + vallen > n:
        return None
    return typ_placeholder(), keystr, vpos, vallen, vpos + 4 + vallen


def typ_placeholder():
    return None


def find_progression_sections(data, start_pos=46):
    n = len(data)
    pos = start_pos
    sections = []
    while pos < n - 4:
        count = read_u32(data, pos)
        if count == 0 or count > 5000:
            break
        bpos = pos + 4
        entries = []
        ok = True
        for _ in range(count):
            r = parse_kv_entry(data, bpos)
            if r is None:
                ok = False
                break
            _, key, vallen_pos, vallen, newpos = r
            entries.append((key, vallen_pos, vallen))
            bpos = newpos
        if not ok:
            break
        for key, vallen_pos, vallen in entries:
            if key.startswith("ProgressionManagerData"):
                sections.append((key, vallen_pos, vallen))
        pos = bpos
    return sections


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("save_file")
    ap.add_argument("static_dumps", nargs="+")
    ap.add_argument("--category", required=True, choices=list(CATEGORY_PATTERNS))
    ap.add_argument("--out", required=True)
    args = ap.parse_args()

    real_names = real_names_for_category(args.static_dumps, args.category)
    target_hashes = {djb2a(n.encode("utf-8")) for n in real_names}
    print(f"{len(real_names)} real '{args.category}' items -> {len(target_hashes)} hashes to strip")

    data = bytearray(open(args.save_file, "rb").read())
    original_size = len(data)
    sections = find_progression_sections(data)
    print(f"found sections: {[s[0] for s in sections]}")

    sections_sorted = sorted(sections, key=lambda s: s[1], reverse=True)
    total_removed_bytes = 0

    for key, vallen_pos, vallen in sections_sorted:
        vstart = vallen_pos + 4
        blob = bytes(data[vstart:vstart + vallen])
        count = struct.unpack_from("<I", blob, 144)[0]
        header = blob[:144]
        trailing = blob[148 + count * 8:]

        kept = []
        removed = 0
        for i in range(count):
            h, v = struct.unpack_from("<II", blob, 148 + i * 8)
            if h in target_hashes:
                removed += 1
            else:
                kept.append((h, v))

        if removed == 0:
            print(f"  {key}: nothing to remove")
            continue

        new_blob = header + struct.pack("<I", len(kept)) + b"".join(struct.pack("<II", h, v) for h, v in kept) + trailing
        shrank_by = len(blob) - len(new_blob)
        data[vstart:vstart + vallen] = new_blob
        struct.pack_into("<I", data, vallen_pos, len(new_blob))
        total_removed_bytes += shrank_by
        print(f"  {key}: {count} -> {len(kept)} records (-{removed}), blob shrank by {shrank_by} bytes")

    if total_removed_bytes == 0:
        print("Nothing changed anywhere -- not writing output.", file=sys.stderr)
        return 1

    # Grow the file back to its original size with zero padding at the end
    # (the inverse of mass_set_collectibles.py trimming padding off).
    data.extend(b"\x00" * total_removed_bytes)

    assert len(data) == original_size, f"size mismatch: {len(data)} != {original_size}"
    recompute_checksums(data)
    open(args.out, "wb").write(data)
    print(f"\nwrote {args.out} ({original_size} bytes, unchanged size). Removed {total_removed_bytes} bytes total, padded back out with zeros. Header/body checksums recomputed.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
