#!/usr/bin/env python3
"""
save_checksum.py -- computes and patches the two CRC32 integrity fields
that live in every PROF_SAVE header, so our write tools stop leaving them
stale after an edit.

Full header layout (confirmed byte-exact against ploxxxy/frostnibble's
save editor -- see FINDINGS.md §14 for the derivation and a worked
example against a real save file; that repo was shared with us by Meteor
on Discord):

    offset  0 (u64 LE): magic "FBCHUNKS"
    offset  8 (u16 LE): version
    offset 10 (u32 LE): headerSize   (always 8 in every save we've seen)
    offset 14 (u32 LE): bodySize     (== file size - 26; a fixed 1,024,000
                                       -byte capacity in every save we've
                                       seen, not something we need to
                                       touch)
    offset 18 (u32 LE): headerHash   = crc32(LE bytes of headerEntries)
    offset 22 (u32 LE): headerEntries (section count -- our tools never
                                        add/remove whole sections, only
                                        records inside them, so this
                                        never changes and headerHash
                                        never goes stale)
    offset 26 (u32 LE): bodyHash     = byteswap32(crc32(data[30:EOF]))
    offset 30:          entries begin (headerEntries sections, each a u32
                         count followed by that many [type,key,value]
                         records -- see FINDINGS.md §12)

Both hashes use a *non-standard* CRC32: the normal CRC-32 polynomial/
table, but seeded with 0x12345678 instead of the usual 0xFFFFFFFF.
That's exactly Python's zlib.crc32(data, 0x12345678) -- zlib.crc32's
second argument is the running/starting CRC and it already does the
invert-in/invert-out bookkeeping internally, so no manual bit flipping
is needed on our end.

None of our own live-in-game write tests (see FINDINGS.md §12a-§12c, "write
path confirmed") showed the game rejecting or resetting a save with a
stale bodyHash, so this doesn't appear to be strictly enforced at load
time -- but it costs nothing to keep correct (Steam Cloud or a future
game update could start caring), so patch_save.py, mass_set_collectibles.py
and clear_category.py all call recompute_checksums() on the buffer right
before writing their output.
"""
import struct
import zlib

CUSTOM_CRC32_SEED = 0x12345678


def custom_crc32(data: bytes) -> int:
    """The engine's CRC32 variant: standard table/polynomial, non-standard
    seed. zlib.crc32(data, value) treats `value` as the running CRC coming
    in, which is exactly the ~INITIAL / process / ~result pattern the
    game's own C = ~INITIAL; ...; return ~C implementation uses."""
    return zlib.crc32(data, CUSTOM_CRC32_SEED) & 0xFFFFFFFF


def swap32(value: int) -> int:
    return struct.unpack(">I", struct.pack("<I", value))[0]


def recompute_checksums(data: bytearray) -> None:
    """Patches offsets 18 (headerHash) and 26 (bodyHash) in place so they
    match the current contents of `data`. Safe to call on any buffer that
    still has the standard 30-byte FBCHUNKS header described above."""
    header_entries = struct.unpack_from("<I", data, 22)[0]
    header_hash = custom_crc32(struct.pack("<I", header_entries))
    struct.pack_into("<I", data, 18, header_hash)

    body_hash = swap32(custom_crc32(bytes(data[30:])))
    struct.pack_into("<I", data, 26, body_hash)


if __name__ == "__main__":
    import sys

    if len(sys.argv) != 2:
        print("usage: python save_checksum.py PROF_SAVE   (checks, doesn't write)", file=sys.stderr)
        sys.exit(1)

    data = bytearray(open(sys.argv[1], "rb").read())
    stored_header_hash = struct.unpack_from("<I", data, 18)[0]
    stored_body_hash = struct.unpack_from("<I", data, 26)[0]

    check = bytearray(data)
    recompute_checksums(check)
    computed_header_hash = struct.unpack_from("<I", check, 18)[0]
    computed_body_hash = struct.unpack_from("<I", check, 26)[0]

    print(f"headerHash: stored 0x{stored_header_hash:08x}  computed 0x{computed_header_hash:08x}  "
          f"{'OK' if stored_header_hash == computed_header_hash else 'MISMATCH (stale)'}")
    print(f"bodyHash:   stored 0x{stored_body_hash:08x}  computed 0x{computed_body_hash:08x}  "
          f"{'OK' if stored_body_hash == computed_body_hash else 'MISMATCH (stale)'}")
