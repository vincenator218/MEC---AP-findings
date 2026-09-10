"""
read_addresses_v2.py -- deeper follow-up to read_addresses.py: dumps a
wider window at each given address, AND follows any 8-byte-aligned value
that looks like a plausible live pointer one level deep (dumping what's
there too, and trying to read it as a C string), so we can figure out
what these objects actually are and how they connect to data we already
understand (flag groups, Sid strings, etc).

Usage: same as read_addresses.py
    python read_addresses_v2.py 1DAE1750 1DB5A548 1DB5E5F8 1DFCE3B8 25AD27A8 25B76528
"""
import argparse
import struct
import sys

import dump_progression_state as dps


def try_cstring(mem, ptr, maxlen=64):
    if not ptr:
        return None
    raw = mem.read(ptr, maxlen)
    if raw is None:
        return None
    text = raw.split(b"\x00", 1)[0]
    if not text:
        return None
    try:
        s = text.decode("utf-8")
    except UnicodeDecodeError:
        return None
    if all(32 <= ord(c) < 127 for c in s) and len(s) >= 2:
        return s
    return None


def dump_window(mem, addr, size, label):
    raw = mem.read(addr, size)
    if raw is None:
        print(f"{label} @ {hex(addr)}: UNREADABLE")
        return
    print(f"{label} @ {hex(addr)}:")
    for off in range(0, len(raw) - 7, 8):
        u64 = struct.unpack_from("<Q", raw, off)[0]
        i64 = struct.unpack_from("<q", raw, off)[0]
        f64 = struct.unpack_from("<d", raw, off)[0]
        note = ""
        if mem.looks_valid_ptr(u64):
            s = try_cstring(mem, u64)
            if s:
                note = f"  <-- looks like a pointer to string: {s!r}"
            else:
                note = "  <-- looks like a valid live pointer (unreadable-as-text target)"
        print(f"  +0x{off:02x}: u64={u64:<20d} i64={i64:<20d} f64={f64:<12.4f} hex={raw[off:off+8].hex()}{note}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("addresses", nargs="*")
    ap.add_argument("--file", default=None)
    ap.add_argument("--process", default="MirrorsEdgeCatalyst")
    ap.add_argument("--window", type=int, default=96)
    args = ap.parse_args()

    addr_strs = list(args.addresses)
    if args.file:
        with open(args.file) as f:
            addr_strs += [line.strip() for line in f if line.strip()]
    if not addr_strs:
        print("No addresses given.", file=sys.stderr)
        sys.exit(1)
    addrs = [int(a, 16) for a in addr_strs]

    matches = dps.find_pid(args.process)
    if not matches:
        print(f"No running process matching '{args.process}' found.", file=sys.stderr)
        sys.exit(1)
    if len(matches) > 1:
        print(f"Multiple matches: {matches}.", file=sys.stderr)
        sys.exit(1)
    pid, exe_name = matches[0]
    print(f"Found process: {exe_name} (pid={pid})")

    mem = dps.MemReader(pid)
    try:
        for a in addrs:
            dump_window(mem, a, args.window, "ADDRESS")
            print()
    finally:
        mem.close()


if __name__ == "__main__":
    main()
