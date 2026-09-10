#!/usr/bin/env python3
"""
mass_set_collectibles.py -- set MANY collectible records to a given value at
once (e.g. "collect every GridLeak except N"), by inserting brand-new
records where none exist yet. Unlike patch_save.py (fixed-size, in-place),
this GROWS the ProgressionManagerData value blob(s) -- more invasive, so
read the whole plan before running it on anything you care about.

How it keeps the file size constant: everything after the edited value in
the file gets shifted forward by however many bytes we insert, and an equal
number of zero bytes are trimmed off the very end of the file (which is
~984KB of pure padding in every save observed so far -- see FINDINGS.md
§12). Net effect: same total file size, same everything-after-the-used-region
being zero, just the used region got a little bigger and the padding a
little smaller.

Usage:
    python mass_set_collectibles.py PROF_SAVE PlayerProgressionData_full.txt \
        --category GridLeaks --leave-uncollected 1 --out PROF_SAVE.maxed

    # or hold back specific named items instead of a random/alphabetical N:
    python mass_set_collectibles.py PROF_SAVE PlayerProgressionData_full.txt \
        --category GridLeaks --hold-back "AnchorGridLeaks_AnchorCompulsionOrb03D3A619-C32A-490B-A8BC-5C8D589954C9" \
        --out PROF_SAVE.maxed

--category matches the per-orb naming pattern "<District><Category>_<District><Category-singular>Orb<GUID>"
(GridLeaks is the only one wired up right now -- SecretBag/ElectronicParts/
AudioPickup/Intel follow a similar but not identical pattern per §10h/§12
and aren't pattern-matched here yet).

ALWAYS work on a copy, and set Steam (or any cloud sync) offline before
testing in-game, or the sync can silently revert your edit before the game
even reads it (see FINDINGS.md §12a round 1).
"""
import argparse
import re
import struct
import sys


def djb2a(data: bytes) -> int:
    h = 5381
    for b in data:
        h = ((h * 33) ^ b) & 0xFFFFFFFF
    return h


def read_u32(data, pos):
    return struct.unpack_from("<I", data, pos)[0]


CATEGORY_PATTERNS = {
    "GridLeaks": re.compile(r"^([A-Za-z]+)GridLeaks_\1CompulsionOrb[0-9A-Fa-f-]{36}$"),
}


def real_names_for_category(static_dump_paths, category):
    pat = CATEGORY_PATTERNS[category]
    names = set()
    for path in static_dump_paths:
        text = open(path, encoding="utf-8", errors="replace").read()
        for m in re.finditer(r"\.Name\s*=\s*'([^']+)'", text):
            n = m.group(1)
            if pat.match(n):
                names.add(n)
    return names


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
    return typ, keystr, vpos, vallen, vpos + 4 + vallen  # (..., vallen_field_pos, value_start=vpos+4, next_entry_pos)


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
            typ, key, vallen_pos, vallen, newpos = r
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
    ap.add_argument("--leave-uncollected", type=int, default=1, help="Hold back this many (alphabetically last) real items so they stay collectible in-game")
    ap.add_argument("--hold-back", action="append", default=[], help="Specific item name(s) to force-hold-back instead of/in addition to --leave-uncollected")
    ap.add_argument("--out", required=True)
    args = ap.parse_args()

    real_names = sorted(real_names_for_category(args.static_dumps, args.category))
    print(f"{len(real_names)} real '{args.category}' items known from static data")

    data = bytearray(open(args.save_file, "rb").read())
    original_size = len(data)
    sections = find_progression_sections(data)
    print(f"found sections: {[s[0] for s in sections]}")

    # Figure out which names are ALREADY collected (value==1) in ANY section
    # before picking what to hold back -- picking a hold-back candidate that
    # turns out to already be done (e.g. from earlier real gameplay) means
    # there's nothing left uncollected for you to go find in-game, even
    # though the record count still looks right. Bit us once; don't repeat it.
    already_collected = set()
    for key, vallen_pos, vallen in sections:
        vstart = vallen_pos + 4
        blob = bytes(data[vstart:vstart + vallen])
        count = struct.unpack_from("<I", blob, 144)[0]
        for i in range(count):
            h, v = struct.unpack_from("<II", blob, 148 + i * 8)
            if v == 1:
                already_collected.add(h)
    name_hash = {n: djb2a(n.encode("utf-8")) for n in real_names}
    genuinely_uncollected = [n for n in real_names if name_hash[n] not in already_collected]
    print(f"{len(genuinely_uncollected)}/{len(real_names)} are not yet collected anywhere in this save")

    hold_back = set(args.hold_back)
    for n in args.hold_back:
        if name_hash.get(n) in already_collected:
            print(f"WARNING: --hold-back {n!r} is already collected in this save -- it will NOT be findable in-game", file=sys.stderr)
    if args.leave_uncollected > 0:
        pool = [n for n in genuinely_uncollected if n not in hold_back]
        if len(pool) < args.leave_uncollected:
            print(f"WARNING: only {len(pool)} genuinely-uncollected items available, less than --leave-uncollected {args.leave_uncollected}", file=sys.stderr)
        hold_back.update(pool[-args.leave_uncollected:])
    to_set = [n for n in real_names if n not in hold_back]
    print(f"holding back {len(hold_back)} (confirmed not yet collected): {sorted(hold_back)}")
    print(f"will ensure {len(to_set)} items are set to value=1")

    # Process sections back-to-front so earlier offsets stay valid as we shift bytes.
    sections_sorted = sorted(sections, key=lambda s: s[1], reverse=True)
    total_inserted_bytes = 0

    for key, vallen_pos, vallen in sections_sorted:
        vstart = vallen_pos + 4
        blob = bytes(data[vstart:vstart + vallen])
        count = struct.unpack_from("<I", blob, 144)[0]
        existing_hashes = set()
        for i in range(count):
            h, v = struct.unpack_from("<II", blob, 148 + i * 8)
            existing_hashes.add(h)

        new_records = []
        for name in to_set:
            h = djb2a(name.encode("utf-8"))
            if h in existing_hashes:
                continue  # already set (should already be value=1 in a "collected" save; not touching existing values here)
            new_records.append(h)

        if not new_records:
            print(f"  {key}: nothing to insert (all already present)")
            continue

        insert_bytes = b"".join(struct.pack("<II", h, 1) for h in new_records)
        # New blob: header(144) + updated count(4) + old records + new records + original trailing padding
        new_count = count + len(new_records)
        header = blob[:144]
        old_records_region = blob[148:148 + count * 8]
        trailing = blob[148 + count * 8:]  # whatever padding followed the record array
        new_blob = header + struct.pack("<I", new_count) + old_records_region + insert_bytes + trailing
        grew_by = len(new_blob) - len(blob)

        # splice into file: replace [vstart, vstart+vallen) with new_blob, update vallen field
        data[vstart:vstart + vallen] = new_blob
        struct.pack_into("<I", data, vallen_pos, len(new_blob))
        total_inserted_bytes += grew_by
        print(f"  {key}: {count} -> {new_count} records (+{len(new_records)}), blob grew by {grew_by} bytes")

    if total_inserted_bytes == 0:
        print("Nothing changed anywhere -- not writing output.", file=sys.stderr)
        return 1

    # Trim that many zero bytes off the very end to keep the file size constant.
    if len(data) - total_inserted_bytes < original_size - total_inserted_bytes:
        pass
    tail = bytes(data[-total_inserted_bytes:])
    if any(b != 0 for b in tail):
        print("REFUSING: the bytes we'd trim off the end aren't all zero -- file may not have enough safe padding, aborting.", file=sys.stderr)
        return 1
    del data[-total_inserted_bytes:]

    assert len(data) == original_size, f"size mismatch: {len(data)} != {original_size}"
    open(args.out, "wb").write(data)
    print(f"\nwrote {args.out} ({original_size} bytes, unchanged size). Inserted {total_inserted_bytes} bytes total, trimmed equal padding off the end.")
    print(f"\nStill uncollected (go find these in-game): {sorted(hold_back)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
