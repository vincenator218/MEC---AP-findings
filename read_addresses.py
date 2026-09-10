"""
read_addresses.py -- reads a handful of raw, already-resolved addresses
(e.g. ones narrowed down in Cheat Engine) and prints their value under
several plausible interpretations (int8/16/32/64, float, plus a raw hex
window), so we can figure out what they actually represent by comparing
against known real numbers (like a district's real GridLeaks count).

These are meant to be literal addresses (what Cheat Engine shows in its
address column after a scan) -- NOT offsets from the module base like the
other scripts in this folder use, so no "+ module base" math is applied.

Usage:
    python read_addresses.py 1DAE1750 1DB5A548 1DB5E5F8 1DFCE3B8 25AD27A8 25B76528
    (or put one hex address per line in a text file and pass --file addrs.txt)
"""
import argparse
import ctypes
import struct
import sys

import dump_progression_state as dps


def describe(mem, addr):
    out = {"address": hex(addr)}
    raw = mem.read(addr, 32)
    if raw is None:
        out["error"] = "unreadable"
        return out
    out["hex"] = raw.hex()
    out["int8"] = struct.unpack_from("<b", raw, 0)[0]
    out["uint8"] = struct.unpack_from("<B", raw, 0)[0]
    out["int16"] = struct.unpack_from("<h", raw, 0)[0]
    out["uint16"] = struct.unpack_from("<H", raw, 0)[0]
    out["int32"] = struct.unpack_from("<i", raw, 0)[0]
    out["uint32"] = struct.unpack_from("<I", raw, 0)[0]
    out["int64"] = struct.unpack_from("<q", raw, 0)[0]
    out["float32"] = round(struct.unpack_from("<f", raw, 0)[0], 4)
    out["float64"] = round(struct.unpack_from("<d", raw, 0)[0], 4)
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("addresses", nargs="*", help="hex addresses, e.g. 1DAE1750")
    ap.add_argument("--file", default=None, help="text file with one hex address per line")
    ap.add_argument("--process", default="MirrorsEdgeCatalyst")
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
            info = describe(mem, a)
            print(info)
    finally:
        mem.close()


if __name__ == "__main__":
    main()
