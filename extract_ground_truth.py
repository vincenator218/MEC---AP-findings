#!/usr/bin/env python3
"""Extract an authoritative ground-truth reference from the already fully
solved static EBX file (PlayerProgressionData.bin), for use as a
cross-validation oracle by dump_progression_state.py's live-memory array
walker.

Why this exists: three live runs of dump_progression_state.py each produced
wildly wrong array sizes (5000-capped groups, 143k total flags, 400 "flag
groups", 2759 "missions", a 20000-capped location list, and even an
internally-impossible bound<last pointer combo) because the raw C++
Array<T> byte layout cannot be told apart, by pointer-plausibility checks
alone, from neighboring same-type objects in what looks like a shared
allocation pool. Rather than guess the pointer layout further, this script
pulls the exact real numbers and names out of the file we've already fully
reverse engineered, so the live walker can stop at the RIGHT count/name
instead of the first "plausible-looking" one.

Run this once (in the cloud sandbox or anywhere ebx_parser.py + the .bin
live) to (re)generate ground_truth.json; dump_progression_state.py loads
that JSON at start and uses it to bound/validate every array it walks.
"""
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
import ebx_parser as ep


def main():
    src = Path(__file__).resolve().parent.parent / "gameconfigs" / "PlayerProgressionData.bin"
    out = Path(__file__).resolve().parent / "ground_truth.json"
    if len(sys.argv) > 1:
        src = Path(sys.argv[1])
    if len(sys.argv) > 2:
        out = Path(sys.argv[2])

    data = src.read_bytes()
    ebx = ep.parse_ebx(data, source_name=src.name)

    flags = []
    groups = []
    missions = []

    for guid, inst in ebx.instances:
        g = guid if isinstance(guid, str) else guid.hex()
        f = {fd.name: v for fd, v in inst.fields}
        if inst.desc.name == "PamProgressionFlag":
            flags.append({
                "guid": g,
                "name": f.get("Name"),
                "name_hash": f.get("NameHash"),
                "mission_index": f.get("MissionIndex"),
            })
        elif inst.desc.name == "PamProgressionFlagGroup":
            own_flags = f.get("Flags")
            # own_flags is a list of "<local ref: TypeName guid=...>" strings
            # when the group's own .Flags field resolved at all (see
            # FINDINGS.md -- unreliable/partial: only ~104 of 124 groups
            # come back non-empty, and it's a DbObject-style flat GUID list
            # so it can mix in non-Flag refs). Record what we got as a
            # best-effort membership hint, but the *count* is trustworthy
            # when nonzero -- it comes straight from the file's own
            # arrayRepeater, not a guess.
            member_guids = []
            if isinstance(own_flags, list):
                for item in own_flags:
                    if isinstance(item, str) and "guid=" in item:
                        member_guids.append(item.split("guid=", 1)[1].rstrip(">"))
            groups.append({
                "guid": g,
                "name": f.get("Name"),
                "name_hash": f.get("NameHash"),
                "flags_count": len(own_flags) if isinstance(own_flags, list) else None,
                "member_guids": member_guids,
            })
        elif inst.desc.name == "PamProgressionMission":
            missions.append({
                "guid": g,
                "mission_index": f.get("MissionIndex"),
            })

    # Cross-reference: guid -> flag record, so we can turn each group's
    # member_guids into real flag names wherever the guid happens to belong
    # to a PamProgressionFlag (member_guids can include non-Flag types too,
    # per the DbObject caveat above -- those are just left as bare guids).
    flags_by_guid = {r["guid"]: r for r in flags}
    for grp in groups:
        names = []
        for mg in grp["member_guids"]:
            fr = flags_by_guid.get(mg)
            if fr is not None:
                names.append(fr["name"])
        grp["member_flag_names"] = names

    ground_truth = {
        "source_file": src.name,
        "totals": {
            "num_flag_groups": len(groups),
            "num_flags": len(flags),
            "num_missions": len(missions),
            # ProgressionFlagLocations resolves as genuine nested inline
            # complexes (not a GUID/DbObject list), so its length is
            # unconditionally trustworthy straight off the parsed root.
        },
        "flags": flags,
        "flag_groups": groups,
        "missions": missions,
    }

    # Pick up ProgressionFlagLocations directly from the root instance --
    # these are genuine nested inline complexes (not a GUID/DbObject list),
    # so both the count AND each element's own fields are unconditionally
    # trustworthy straight off the parsed root, unlike FlagGroups/Missions.
    flag_locations = []
    for guid, inst in ebx.instances:
        if inst.desc.name == "PamProgressionData":
            for fd, v in inst.fields:
                if fd.name == "ProgressionFlagLocations" and isinstance(v, list):
                    ground_truth["totals"]["num_flag_locations"] = len(v)
                    for item in v:
                        if hasattr(item, "fields"):
                            fmap = {f2.name: v2 for f2, v2 in item.fields}
                            flag_locations.append({"name_hash": fmap.get("NameHash")})
            break
    ground_truth["flag_locations"] = flag_locations

    out.write_text(json.dumps(ground_truth, indent=2))
    t = ground_truth["totals"]
    print(f"Wrote {out}")
    print(f"  flag groups:      {t['num_flag_groups']}")
    print(f"  flags:            {t['num_flags']}")
    print(f"  missions:         {t['num_missions']}")
    print(f"  flag locations:   {t.get('num_flag_locations', '?')}")
    known_member_sum = sum(g['flags_count'] or 0 for g in groups)
    nonzero = sum(1 for g in groups if (g['flags_count'] or 0) > 0)
    print(f"  groups with a known per-group flag count: {nonzero}/{len(groups)} "
          f"(covering {known_member_sum} of {len(flags)} flags)")


if __name__ == "__main__":
    main()
