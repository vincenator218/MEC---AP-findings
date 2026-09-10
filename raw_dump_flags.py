"""
raw_dump_flags.py -- companion to dump_progression_state.py for hunting down
the still-unknown "current value / is this flag set for my save" field.

WHY THIS EXISTS: dump_progression_state.py only decodes the fields the SDK
headers actually declare (Name, NameHash, MissionIndex, MaxValue, Cost,
Reputation, SyncStatName, Clamp, SyncToOnline) -- all static config, none of
which changed at all (checked byte-for-byte) between a snapshot taken
before and after collecting a real in-game item. So whatever tracks "have I
picked this up" for THIS save lives at some byte offset inside (or right
after) the PamProgressionFlag struct that the SDK dump just didn't name.

This script re-locates every real flag object exactly the same way
dump_progression_state.py does (same address chain, same ground-truth-
bounded walk, so results are 1:1 comparable), then dumps a wide raw hex
window starting at each flag's own base address -- not just the named
fields -- so we can diff/eyeball for a byte that looks like a per-save
completion flag.

RUN THIS THE SAME WAY as dump_progression_state.py, same folder (needs
ground_truth.json next to it), while the game is running:

    python raw_dump_flags.py [--process MirrorsEdgeCatalyst] [--out raw_flags_dump.json] [--window 128]

Produces a JSON: {flag_name: {"group": groupName, "address": "0x...",
"hex": "<window_bytes as hex string>"}, ...} for every matched real flag.
"""
import argparse
import json
import sys

import dump_progression_state as dps


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--process", default="MirrorsEdgeCatalyst")
    ap.add_argument("--out", default="raw_flags_dump.json")
    ap.add_argument("--window", type=int, default=128,
                     help="bytes to dump starting at each flag object's own base address")
    ap.add_argument("--ground-truth", default=None)
    args = ap.parse_args()

    from pathlib import Path
    gt_path = args.ground_truth or (Path(__file__).resolve().parent / "ground_truth.json")
    gt = dps.GroundTruth(gt_path)
    print(f"Loaded ground truth: {gt.num_groups()} flag groups, {gt.num_flags()} flags")

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

        def accept_group_slot(addr):
            group_ptr = mem.u64(addr)
            if not mem.looks_valid_ptr(group_ptr):
                return False
            return gt.accept_group(mem, group_ptr)

        out = {}
        group_count = 0
        for slot_addr in dps.walk_oracle_bounded(
                mem, pd_ptr + dps.OFF_PD_FLAGGROUPS, dps.PTR_SIZE, gt.num_groups(),
                accept_group_slot, tag="PamProgressionData.FlagGroups"):
            group_ptr = mem.u64(slot_addr)
            group_name = mem.cstring(group_ptr + dps.OFF_FG_NAME)
            group_count += 1

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
                flag_ptr = mem.u64(fslot)
                name = mem.cstring(flag_ptr + dps.OFF_FLAG_NAME)
                raw = mem.read(flag_ptr, args.window)
                out[name] = {
                    "group": group_name,
                    "address": hex(flag_ptr),
                    "hex": raw.hex() if raw is not None else None,
                }

        print(f"Dumped {len(out)} flags across {group_count} groups")
        with open(args.out, "w", encoding="utf-8") as f:
            json.dump(out, f, indent=2)
        print(f"Wrote {args.out}")
    finally:
        mem.close()


if __name__ == "__main__":
    main()
