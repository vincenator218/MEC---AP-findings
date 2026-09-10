#!/usr/bin/env python3
"""
patch_save.py -- flip a single per-save progression record's value in-place,
without changing the file's size or touching anything else. This is the
safest possible test of the write path: no record-count changes, no
length-prefix changes, no risk of desyncing the block parser.

Usage:
    # by name (recomputes the djb2a hash for you):
    python patch_save.py PROF_SAVE --name "ElectronicPartsAcSh_Chip07Taken" --value 0 --out PROF_SAVE.patched

    # by raw hash (if you already know it, e.g. from decode_save.py's output):
    python patch_save.py PROF_SAVE --hash 0x37b4d085 --value 0 --out PROF_SAVE.patched

It edits every ProgressionManagerData* section that contains a record with
that hash (there are normally up to 3 -- one per linked platform account --
and they can legitimately disagree, so by default it patches all of them
that have the record; pass --section to restrict to just one, matching the
key name decode_save.py prints, e.g. ProgressionManagerData_2266106373).

ALWAYS work on a copy. Never point --out at your real, in-use save file.
"""
import argparse
import struct
import sys


def djb2a(data: bytes) -> int:
    h = 5381
    for b in data:
        h = ((h * 33) ^ b) & 0xFFFFFFFF
    return h


def read_u32(data, pos):
    return struct.unpack_from("<I", data, pos)[0]


def parse_kv_entry(data, pos):
    n = len(data)
    if pos + 8 > n:
        return None
    typ = read_u32(data, pos)
    keylen = read_u32(data, pos + 4)
    if keylen == 0 or keylen > 256 or pos + 8 + keylen > n:
        return None
    key = data[pos + 8 : pos + 8 + keylen]
    if not key.endswith(b"\x00") or not all(32 <= c < 127 for c in key[:-1]):
        return None
    keystr = key[:-1].decode("latin1")
    vpos = pos + 8 + keylen
    if vpos + 4 > n:
        return None
    vallen = read_u32(data, vpos)
    if vallen > 5_000_000 or vpos + 4 + vallen > n:
        return None
    return typ, keystr, vallen, vpos + 4, vpos + 4 + vallen  # (..., value_start, next_entry_pos)


def find_progression_sections(data, start_pos=46):
    """Returns [(key, value_start_offset, value_len), ...] for every
    ProgressionManagerData* entry found by walking the block sequence."""
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
            typ, key, vallen, vstart, newpos = r
            entries.append((key, vstart, vallen))
            bpos = newpos
        if not ok:
            break
        for key, vstart, vallen in entries:
            if key.startswith("ProgressionManagerData"):
                sections.append((key, vstart, vallen))
        pos = bpos
    return sections


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("save_file")
    ap.add_argument("--name", help="Flag name to hash and patch (djb2a, UTF-8, no trailing NUL)")
    ap.add_argument("--hash", help="Raw hash to patch instead of --name, e.g. 0x37b4d085")
    ap.add_argument("--value", type=int, required=True, help="New 4-byte value to write (e.g. 0 or 1)")
    ap.add_argument("--section", default=None, help="Restrict to one ProgressionManagerData* key (default: patch every section containing this hash)")
    ap.add_argument("--out", required=True, help="Output path -- NEVER your live save file")
    args = ap.parse_args()

    if not args.name and not args.hash:
        print("error: pass --name or --hash", file=sys.stderr)
        return 1
    target_hash = djb2a(args.name.encode("utf-8")) if args.name else int(args.hash, 16)
    print(f"target hash: 0x{target_hash:08x}" + (f"  (from name {args.name!r})" if args.name else ""))

    data = bytearray(open(args.save_file, "rb").read())
    sections = find_progression_sections(data)
    print(f"found {len(sections)} ProgressionManagerData* section(s): {[s[0] for s in sections]}")

    patched = 0
    for key, vstart, vallen in sections:
        if args.section and key != args.section:
            continue
        blob = data[vstart:vstart + vallen]
        count = struct.unpack_from("<I", blob, 144)[0]
        for i in range(count):
            off = 148 + i * 8
            h, v = struct.unpack_from("<II", blob, off)
            if h == target_hash:
                old = v
                struct.pack_into("<I", data, vstart + off + 4, args.value)
                print(f"  {key}: record {i} (hash 0x{h:08x}) value {old} -> {args.value}")
                patched += 1
                break
        else:
            print(f"  {key}: hash 0x{target_hash:08x} not found in this section (no change)")

    if patched == 0:
        print("NOTHING PATCHED -- hash not found anywhere. Not writing output.", file=sys.stderr)
        return 1

    assert len(data) == len(open(args.save_file, "rb").read()), "file size changed -- aborting, something is wrong"
    open(args.out, "wb").write(data)
    print(f"wrote {args.out} ({patched} record(s) patched, file size unchanged)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
