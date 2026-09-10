"""
dump_region.py -- brute-force wide memory region dump, for hunting the
still-unknown live "current value / completed" state when per-flag
128-byte windows (raw_dump_flags.py) showed ZERO changed bytes across two
real collection events.

Rather than guess which object holds the state, this reads a big
contiguous span of the SAME memory arena all the known PamProgressionFlag/
PamProgressionFlagGroup/PamProgressionMission objects live in (computed
from the real address range those objects were found at, via the exact
same ground-truth-bounded walk dump_progression_state.py uses -- so this
region reliably covers "the pool"), page by page so a handful of unmapped
pages don't fail the whole read, and saves it to a compact binary file
plus a small header JSON (base address, size, which pages were readable).

Run this the same way as the other scripts (same folder, game running):

    python dump_region.py [--process MirrorsEdgeCatalyst] [--out region_dump]
    (writes region_dump.bin + region_dump.json)

Take one dump, do ONE specific thing in-game (collect one item, complete
one objective -- ideally something you can point to precisely), take
another dump, then hand both pairs of files back for a byte-level diff of
the entire region -- not just the objects we already know the shape of.
"""
import argparse
import ctypes
import json
import sys

import dump_progression_state as dps

PAGE_SIZE = 0x1000
MARGIN = 0x4000  # pad this many bytes before the lowest / after the highest known object


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--process", default="MirrorsEdgeCatalyst")
    ap.add_argument("--out", default="region_dump")
    ap.add_argument("--ground-truth", default=None)
    args = ap.parse_args()

    from pathlib import Path
    gt_path = args.ground_truth or (Path(__file__).resolve().parent / "ground_truth.json")
    gt = dps.GroundTruth(gt_path)

    matches = dps.find_pid(args.process)
    if not matches:
        print(f"No running process matching '{args.process}' found.", file=sys.stderr)
        sys.exit(1)
    if len(matches) > 1:
        print(f"Multiple matches for '{args.process}': {matches}.", file=sys.stderr)
        sys.exit(1)
    pid, exe_name = matches[0]
    print(f"Found process: {exe_name} (pid={pid})")

    base, module_name = dps.get_main_module_base(pid)
    if not base:
        print("Could not resolve main module base.", file=sys.stderr)
        sys.exit(1)

    mem = dps.MemReader(pid)
    try:
        settings_ptr = mem.u64(base + dps.PAM_PROGRESSION_SETTINGS_PTR_SLOT)
        pd_ptr = mem.u64(settings_ptr + dps.OFF_SETTINGS_PLAYERPROGRESSIONDATA)
        if not pd_ptr:
            print("PlayerProgressionData pointer is NULL.", file=sys.stderr)
            sys.exit(1)
        print(f"PamProgressionData* -> {hex(pd_ptr)}")

        # Walk everything exactly like dump_progression_state.py, just to
        # collect the real address range objects were actually found at.
        addrs = [pd_ptr]

        def accept_group_slot(addr):
            group_ptr = mem.u64(addr)
            if not mem.looks_valid_ptr(group_ptr):
                return False
            return gt.accept_group(mem, group_ptr)

        for slot_addr in dps.walk_oracle_bounded(
                mem, pd_ptr + dps.OFF_PD_FLAGGROUPS, dps.PTR_SIZE, gt.num_groups(),
                accept_group_slot, tag="PamProgressionData.FlagGroups"):
            group_ptr = mem.u64(slot_addr)
            addrs.append(group_ptr)
            group_name = mem.cstring(group_ptr + dps.OFF_FG_NAME)
            budget = gt.group_flag_budget(group_name)
            if budget is None:
                budget = len(gt.remaining_flag_names)

            def accept_flag_slot(addr):
                flag_ptr = mem.u64(addr)
                if not mem.looks_valid_ptr(flag_ptr):
                    return False
                return gt.accept_flag(mem, flag_ptr)

            for fslot in dps.walk_oracle_bounded(
                    mem, group_ptr + dps.OFF_FG_FLAGS, dps.PTR_SIZE, budget,
                    accept_flag_slot, tag=f"Flags of {group_name}"):
                addrs.append(mem.u64(fslot))

        low = min(addrs) - MARGIN
        high = max(addrs) + MARGIN
        low -= low % PAGE_SIZE
        high += (PAGE_SIZE - high % PAGE_SIZE)
        size = high - low
        print(f"Dumping region {hex(low)}..{hex(high)} ({size} bytes, {size // PAGE_SIZE} pages)")

        data = bytearray(size)
        readable_pages = []
        for off in range(0, size, PAGE_SIZE):
            page = mem.read(low + off, PAGE_SIZE)
            if page is not None:
                data[off:off + PAGE_SIZE] = page
                readable_pages.append(True)
            else:
                readable_pages.append(False)

        n_ok = sum(readable_pages)
        print(f"  {n_ok}/{len(readable_pages)} pages readable")

        bin_path = args.out + ".bin"
        json_path = args.out + ".json"
        with open(bin_path, "wb") as f:
            f.write(bytes(data))
        with open(json_path, "w", encoding="utf-8") as f:
            json.dump({
                "base": hex(low),
                "size": size,
                "page_size": PAGE_SIZE,
                "readable_pages": readable_pages,
                "known_object_addresses_sample": [hex(a) for a in addrs[:5]],
            }, f, indent=2)
        print(f"Wrote {bin_path} and {json_path}")
    finally:
        mem.close()


if __name__ == "__main__":
    main()
