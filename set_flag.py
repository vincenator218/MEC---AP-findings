#!/usr/bin/env python3
"""
set_flag.py -- set one or more arbitrary named flags to a given value,
whether or not a record for that name already exists in the save.

This is the general-purpose tool patch_save.py and mass_set_collectibles.py
each only half cover: patch_save.py can only flip a record that's already
present (it silently no-ops on a name with no existing record -- which is
exactly the case for a mission that's never been reached, like
"Finger on the Pulse_Available" on a save that's never unlocked it);
mass_set_collectibles.py can insert brand-new records, but only for a
handful of hardcoded collectible-category regexes, not an arbitrary name.

set_flag.py does the right thing either way, per name: if a record with
that hash already exists in a ProgressionManagerData* section, its value
is patched in place (file size unchanged, like patch_save.py). If it
doesn't exist yet, a brand new {hash, value} record is inserted at the
end of that section's blob and the file is grown by 8 bytes per insert,
then exactly that many zero bytes are trimmed off the very end of the
file to keep the total size constant (same mechanism as
mass_set_collectibles.py). Every ProgressionManagerData* section is
touched the same way, since which one is "live" varies per save/account
(see FINDINGS.md) and this errs toward consistency across all of them.

Usage:
    # one flag:
    python set_flag.py PROF_SAVE --set "Finger on the Pulse_Available=1" --out PROF_SAVE

    # several at once:
    python set_flag.py PROF_SAVE --set "Foo_Available=1" --set "Bar_Available=1" --out PROF_SAVE

ALWAYS work on a copy first if you're not sure. The game must be fully
closed while you write this edit -- see FINDINGS.md sections 15/15a/15b.
"""
import argparse
import struct
import sys

from save_checksum import recompute_checksums


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
    return keystr, vpos + 4, vallen, vpos + 4 + vallen  # (key, value_start, value_len, next_entry_pos)


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
            key, vstart, vallen, newpos = r
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
    ap.add_argument("--set", action="append", required=True, metavar="NAME=VALUE",
                     help="Flag name and new value, e.g. \"Finger on the Pulse_Available=1\". Repeatable.")
    ap.add_argument("--out", required=True)
    args = ap.parse_args()

    targets = {}
    for spec in args.set:
        if "=" not in spec:
            print(f"error: --set {spec!r} must be NAME=VALUE", file=sys.stderr)
            return 1
        name, val = spec.rsplit("=", 1)
        targets[name] = int(val)

    name_hash = {name: djb2a(name.encode("utf-8")) for name in targets}
    print("targets:")
    for name, val in targets.items():
        print(f"  {name} -> hash 0x{name_hash[name]:08x}, value {val}")

    data = bytearray(open(args.save_file, "rb").read())
    original_size = len(data)
    sections = find_progression_sections(data)
    print(f"\nfound sections: {[s[0] for s in sections]}")

    sections_sorted = sorted(sections, key=lambda s: s[1], reverse=True)
    total_inserted_bytes = 0
    patched_count = 0
    inserted_count = 0

    for key, vstart, vallen in sections_sorted:
        blob = data[vstart:vstart + vallen]
        count = struct.unpack_from("<I", blob, 144)[0]

        existing_positions = {}
        for i in range(count):
            h, v = struct.unpack_from("<II", blob, 148 + i * 8)
            existing_positions[h] = i

        to_insert = []
        for name, val in targets.items():
            h = name_hash[name]
            if h in existing_positions:
                i = existing_positions[h]
                off = 148 + i * 8
                old = struct.unpack_from("<I", data, vstart + off + 4)[0]
                if old != val:
                    struct.pack_into("<I", data, vstart + off + 4, val)
                    print(f"  {key}: patched {name!r} in place, {old} -> {val}")
                    patched_count += 1
                else:
                    print(f"  {key}: {name!r} already {val}, no change")
            else:
                to_insert.append((h, val, name))

        if not to_insert:
            continue

        insert_bytes = b"".join(struct.pack("<II", h, v) for h, v, _ in to_insert)
        new_count = count + len(to_insert)
        header = blob[:144]
        old_records_region = blob[148:148 + count * 8]
        trailing = blob[148 + count * 8:]
        new_blob = header + struct.pack("<I", new_count) + old_records_region + insert_bytes + trailing
        grew_by = len(new_blob) - len(blob)

        data[vstart:vstart + vallen] = new_blob
        struct.pack_into("<I", data, vstart - 4, len(new_blob))  # vallen field sits right before vstart
        total_inserted_bytes += grew_by
        for h, v, name in to_insert:
            print(f"  {key}: inserted new record {name!r} = {v}")
            inserted_count += 1

    if patched_count == 0 and inserted_count == 0:
        print("\nNothing changed anywhere -- not writing output.", file=sys.stderr)
        return 1

    if total_inserted_bytes:
        tail = bytes(data[-total_inserted_bytes:])
        if any(b != 0 for b in tail):
            print("REFUSING: the bytes we'd trim off the end aren't all zero -- aborting.", file=sys.stderr)
            return 1
        del data[-total_inserted_bytes:]

    assert len(data) == original_size, f"size mismatch: {len(data)} != {original_size}"
    recompute_checksums(data)
    open(args.out, "wb").write(data)
    print(f"\nwrote {args.out} ({original_size} bytes, unchanged size). "
          f"{patched_count} record(s) patched, {inserted_count} record(s) newly inserted. "
          f"Header/body checksums recomputed.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
