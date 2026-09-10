#!/usr/bin/env python3
"""
decode_save.py -- parse a Mirror's Edge Catalyst PROF_SAVE file and resolve
every per-save progression flag/stat to a human-readable name and value.

No live game process needed at all -- this reads the save file directly.

Save file format (reverse-engineered 2026-09-10):
  - Magic "FBCHUNKS" + a ~38 byte header.
  - Then a flat sequence of "blocks". Each block is:
        u32 entry_count
        entry_count x {
            u32 type            (1=float-as-text, 2=bool/int-as-text,
                                  4=stat-as-text, 5=binary blob, ...)
            u32 keylen          (strlen(key)+1, includes trailing NUL)
            keylen bytes        key string, NUL-terminated
            u32 vallen
            vallen bytes        value (text or binary depending on type)
        }
  - The interesting block (type=5) has keys "ProgressionManagerData",
    "ProgressionManagerData_<id1>", "ProgressionManagerData_<id2>" (one per
    linked platform account; usually near-identical). Its value is:
        144 bytes  -- player transform/session floats (not needed here)
        u32        -- record count N
        N x { u32 name_hash, u32 value }   -- the actual per-save state table
  - Everything after the last block is zero padding out to a fixed file size
    (1,024,026 bytes observed) -- the save format pre-allocates a big buffer
    and only uses the first ~40KB.

The 32-bit name_hash is djb2a (seed 5381, XOR variant) over the UTF-8 bytes
of the flag's internal `Name` field (or `SyncStatName` / `ActiveNameSid` /
`NumberOfFlagsSyncStatName` / `SumOfFlagValuesSyncStatName` -- all four Sid
field kinds hash into the same space), with NO trailing NUL byte:

    def djb2a(s: bytes) -> int:
        h = 5381
        for b in s:
            h = ((h * 33) ^ b) & 0xFFFFFFFF
        return h

Cracked by hashing every resolved Sid string already extracted from the
static PlayerProgressionData_full.txt dump and matching against the hashes
found in a real save -- 977/985 records (99.2%) resolved on the first try,
zero collisions across 3,342 candidate strings.

Usage:
    python decode_save.py PROF_SAVE PlayerProgressionData_full.txt [--out out.json]

The second argument is the text dump produced earlier in this project by
dumping PlayerProgressionData.bin through ebx_parser.py (must contain lines
like ".Name = 'Foo'" / ".SyncStatName = 'pf_Foo'" / etc.) -- it's the source
of every candidate string for the reverse hash lookup. Swap in a fuller/newer
dump (e.g. one that also covers RewardsData.bin, RunnerKitDefinitionsMeta,
achievements, ...) to resolve more of the long tail.
"""
import argparse
import json
import re
import struct
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


def build_hash_dictionary(static_dump_paths):
    """Extract every candidate Sid-ish string from one or more static EBX
    text dumps and return {djb2a_hash: string}. Later files win on collision
    (there weren't any observed, but keep it deterministic)."""
    names = set()
    for path in static_dump_paths:
        text = open(path, encoding="utf-8", errors="replace").read()
        for pat in SID_FIELD_PATTERNS:
            for m in re.finditer(pat, text):
                names.add(m.group(1))

    table = {}
    collisions = 0
    for name in names:
        h = djb2a(name.encode("utf-8"))
        if h in table and table[h] != name:
            collisions += 1
        table[h] = name
    return table, len(names), collisions


def read_u32(data, pos):
    return struct.unpack_from("<I", data, pos)[0]


def parse_kv_entry(data, pos):
    """Parse one [type][keylen][key][vallen][val] entry at `pos`.
    Returns (type, key, vallen, val, next_pos) or None if it doesn't look
    like a valid entry (used both to parse and to sanity-check)."""
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
    val = data[vpos + 4 : vpos + 4 + vallen]
    return typ, keystr, vallen, val, vpos + 4 + vallen


def parse_all_blocks(data, start_pos=46):
    """Walk the flat sequence of [count][entries...] blocks starting at
    start_pos. Returns list of (block_start_pos, count, [(pos,type,key,vallen,val), ...])."""
    n = len(data)
    pos = start_pos
    blocks = []
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
            typ, k, vlen, v, newpos = r
            entries.append((bpos, typ, k, vlen, v))
            bpos = newpos
        if not ok:
            break
        blocks.append((pos, count, entries))
        pos = bpos
    return blocks


def decode_progression_blob(value: bytes):
    """Decode one ProgressionManagerData value blob into (header_bytes,
    [(hash, value), ...])."""
    count = read_u32(value, 144)
    records = []
    off = 148
    for _ in range(count):
        if off + 8 > len(value):
            break
        h, v = struct.unpack_from("<II", value, off)
        records.append((h, v))
        off += 8
    return value[:144], records


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("save_file", help="Path to a PROF_SAVE file")
    ap.add_argument("static_dumps", nargs="+", help="One or more static EBX text dumps to mine for candidate Sid strings")
    ap.add_argument("--out", default=None, help="Write full JSON here (default: print summary only)")
    args = ap.parse_args()

    data = open(args.save_file, "rb").read()
    print(f"save file: {args.save_file} ({len(data)} bytes)")

    hashdict, n_candidates, collisions = build_hash_dictionary(args.static_dumps)
    print(f"hash dictionary: {n_candidates} candidate strings -> {len(hashdict)} unique hashes ({collisions} collisions)")

    blocks = parse_all_blocks(data)
    print(f"parsed {len(blocks)} key/value blocks")

    result = {"blocks": [], "progression": []}

    for bpos, count, entries in blocks:
        block_out = []
        for pos, typ, key, vlen, val in entries:
            if key.startswith("ProgressionManagerData"):
                header, records = decode_progression_blob(val)
                resolved = 0
                recs_out = []
                for h, v in records:
                    name = hashdict.get(h)
                    if name:
                        resolved += 1
                    recs_out.append({"hash": f"0x{h:08x}", "name": name, "value": v})
                pct = (resolved / len(records) * 100) if records else 0.0
                print(f"  {key}: {len(records)} records, {resolved} resolved ({pct:.1f}%)")
                result["progression"].append({"key": key, "record_count": len(records), "resolved": resolved, "records": recs_out})
            else:
                # generic settings/stat entry -- value is ASCII text
                try:
                    text = val.rstrip(b"\x00").decode("utf-8")
                except UnicodeDecodeError:
                    text = None
                block_out.append({"type": typ, "key": key, "value": text if text is not None else val.hex()})
        result["blocks"].append({"start": bpos, "count": count, "entries": block_out})

    if args.out:
        json.dump(result, open(args.out, "w"), indent=1)
        print(f"wrote {args.out}")
    else:
        print("(pass --out FILE.json to save full decoded output)")


if __name__ == "__main__":
    sys.exit(main())
