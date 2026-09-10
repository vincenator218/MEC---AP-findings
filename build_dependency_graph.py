#!/usr/bin/env python3
"""
build_dependency_graph.py -- assembles the real mission/reward/flag
dependency graph, now that GUID references decode (FINDINGS.md sec 6)
and every name resolves for free (sec 9). This is the "next concrete
step" flagged at the end of sec 10g/10k/10l and in the closing
"Where to go from here" list.

Two source files, both already fully exported:
  - PlayerProgressionData.bin: PamProgressionFlag, PamProgressionFlagGroup,
    PamProgressionMission (extends FlagGroup -- carries MissionIndex,
    CompletedFlag, AvailableFlag, MissionDescription Sids, Reputation,
    Currency, MissionType).
  - RewardsData.bin: PamReward (RunnerKitGuid, AchievementData,
    RewardConditions[], CompareConditionsType, ConditionsCountThreshold)
    and every PamRewardCondition subtype (PamProgressionFlagRewardCondition,
    PamProgressionFlagGroupRewardCondition,
    PamProgressionMissionCompletedRewardCondition, plus PamFlowRewardCondition/
    PamMoveSeqRewardCondition/PamKillAIRewardCondition/PamStatsRewardCondition/
    PamNamedChallengeRewardCondition/PamEchoCustomizedRewardCondition, which
    don't reference progression flags/groups/missions at all and are kept
    only for completeness).

Key wrinkle discovered while writing this: RewardsData.bin's DbObject-typed
list fields (PamReward.RewardConditions, and
PamProgressionMissionCompletedRewardCondition.Missions) show the SAME
over-inclusive-membership bug documented for PamProgressionFlagGroup.Flags
in FINDINGS.md sec 2/5 -- the raw list mixes in refs to totally unrelated
objects (including bare self-refs to the root PamRewardsData asset). The
fix here is simpler than the live-memory case though: everything that
belongs in RewardsData.bin's own lists (PamReward, every RewardCondition
subtype) resolves as a *local* ref (an object defined in this same file),
while every real target these conditions check -- a PamProgressionFlag,
PamProgressionFlagGroup, or PamProgressionMission -- lives in the OTHER
file (PlayerProgressionData.bin) and therefore resolves as an *external*
ref. So: keep local refs only when filtering RewardConditions (and require
the type to be a real RewardCondition subclass, dropping self-refs to
PamReward/PamRewardsData), and keep external refs only when resolving what
a condition actually points at (a flag/group/mission), cross-referenced
against the guid tables already extracted from PlayerProgressionData.bin.

Run from this folder:
    python3 build_dependency_graph.py
Writes dependency_graph.json next to this script, plus prints a summary.
"""
import json
import re
import sys
from collections import defaultdict
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
import ebx_parser as ep

REF_RE = re.compile(r"(local|external) ref: (?:(?P<type>\w+) )?guid=(?P<guid>[0-9a-f]{32})|instance=(?P<einst>[0-9a-f]{32})")


def ref_kind_type_guid(s):
    """Parse a '<local ref: Type guid=...>' or '<external ref: instance=... in file=...>'
    string into (kind, type_name_or_None, guid_hex)."""
    if not isinstance(s, str):
        return None
    if s.startswith("<local ref:"):
        m = re.match(r"<local ref: (\w+) guid=([0-9a-f]{32})>", s)
        if m:
            return ("local", m.group(1), m.group(2))
    elif s.startswith("<external ref:"):
        m = re.match(r"<external ref: instance=([0-9a-f]{32}) in file=([0-9a-f]{32})>", s)
        if m:
            return ("external", None, m.group(1))
    return None


REWARD_CONDITION_TYPES = {
    "PamProgressionFlagGroupRewardCondition",
    "PamProgressionFlagRewardCondition",
    "PamProgressionMissionCompletedRewardCondition",
    "PamFlowRewardCondition",
    "PamMoveSeqRewardCondition",
    "PamKillAIRewardCondition",
    "PamStatsRewardCondition",
    "PamNamedChallengeRewardCondition",
    "PamEchoCustomizedRewardCondition",
}


def load_progression(path):
    data = path.read_bytes()
    ebx = ep.parse_ebx(data, source_name=path.name)

    flags_by_guid = {}
    groups_by_guid = {}
    missions_by_guid = {}

    for guid, inst in ebx.instances:
        g = guid if isinstance(guid, str) else guid.hex()
        f = {fd.name: v for fd, v in inst.fields}
        if inst.desc.name == "PamProgressionFlag":
            flags_by_guid[g] = {
                "guid": g,
                "name": f.get("Name"),
                "name_hash": f.get("NameHash"),
                "mission_index": f.get("MissionIndex"),
                "max_value": f.get("MaxValue"),
                "clamp": f.get("Clamp"),
            }
        elif inst.desc.name == "PamProgressionFlagGroup":
            groups_by_guid[g] = {
                "guid": g,
                "name": f.get("Name"),
                "name_hash": f.get("NameHash"),
            }
        elif inst.desc.name == "PamProgressionMission":
            completed = ref_kind_type_guid(f.get("CompletedFlag"))
            available = ref_kind_type_guid(f.get("AvailableFlag"))
            desc = f.get("MissionDescription")
            desc_fields = {}
            if hasattr(desc, "fields"):
                desc_fields = {fd.name: v for fd, v in desc.fields}
            missions_by_guid[g] = {
                "guid": g,
                "mission_index": f.get("MissionIndex"),
                "completed_flag_guid": completed[2] if completed else None,
                "available_flag_guid": available[2] if available else None,
                "active_name_sid": desc_fields.get("ActiveNameSid"),
                "active_long_desc_sid": desc_fields.get("ActiveLongDescriptionSid"),
                "available_name_sid": desc_fields.get("AvailableNameSid"),
                "available_long_desc_sid": desc_fields.get("AvailableLongDescriptionSid"),
                "reputation": f.get("Reputation"),
                "currency": f.get("Currency"),
                "mission_type": f.get("MissionType"),
            }
    return flags_by_guid, groups_by_guid, missions_by_guid


def load_rewards(path):
    data = path.read_bytes()
    ebx = ep.parse_ebx(data, source_name=path.name)

    rewards = {}
    conditions = {}  # guid -> {"type": ..., raw fields dict}

    for guid, inst in ebx.instances:
        g = guid if isinstance(guid, str) else guid.hex()
        tname = inst.desc.name
        f = {fd.name: v for fd, v in inst.fields}
        if tname == "PamReward":
            raw_list = f.get("RewardConditions")
            cond_guids = []
            if isinstance(raw_list, list):
                for item in raw_list:
                    parsed = ref_kind_type_guid(item)
                    if parsed and parsed[0] == "local" and parsed[1] in REWARD_CONDITION_TYPES:
                        cond_guids.append(parsed[2])
            ach = ref_kind_type_guid(f.get("AchievementData"))
            rewards[g] = {
                "guid": g,
                "achievement_data_ref": ach[2] if ach else None,
                "runner_kit_guid": f.get("RunnerKitGuid"),
                "condition_guids": cond_guids,
                "compare_conditions_type": f.get("CompareConditionsType"),
                "conditions_count_threshold": f.get("ConditionsCountThreshold"),
                "name_hash": f.get("NameHash"),
            }
        elif tname in REWARD_CONDITION_TYPES:
            entry = {"type": tname}
            if tname == "PamProgressionFlagGroupRewardCondition":
                parsed = ref_kind_type_guid(f.get("FlagGroup"))
                entry["flag_group_guid"] = parsed[2] if parsed else None
            elif tname == "PamProgressionFlagRewardCondition":
                parsed = ref_kind_type_guid(f.get("ProgressionFlag"))
                entry["progression_flag_guid"] = parsed[2] if parsed else None
                entry["threshold"] = f.get("Threshold")
                entry["report_flag_values_as_count"] = f.get("ReportFlagValuesAsCount")
            elif tname == "PamProgressionMissionCompletedRewardCondition":
                raw_list = f.get("Missions")
                mission_guids = []
                if isinstance(raw_list, list):
                    for item in raw_list:
                        parsed = ref_kind_type_guid(item)
                        if parsed and parsed[0] == "external":
                            mission_guids.append(parsed[2])
                entry["mission_guids"] = mission_guids
            else:
                # PamFlowRewardCondition / PamMoveSeqRewardCondition /
                # PamKillAIRewardCondition / PamStatsRewardCondition /
                # PamNamedChallengeRewardCondition / PamEchoCustomizedRewardCondition:
                # none of these reference a progression flag/group/mission,
                # so just keep whatever scalar fields came back for reference.
                for k, v in f.items():
                    if k != "$" and not isinstance(v, (list, dict)) and not hasattr(v, "fields"):
                        entry[k] = v
            conditions[g] = entry
    return rewards, conditions


def describe_condition(cond, flags_by_guid, groups_by_guid, missions_by_guid):
    t = cond["type"]
    if t == "PamProgressionFlagGroupRewardCondition":
        grp = groups_by_guid.get(cond.get("flag_group_guid"))
        name = grp["name"] if grp else f"<unresolved {cond.get('flag_group_guid')}>"
        return f"FlagGroup '{name}' complete"
    if t == "PamProgressionFlagRewardCondition":
        flg = flags_by_guid.get(cond.get("progression_flag_guid"))
        name = flg["name"] if flg else f"<unresolved {cond.get('progression_flag_guid')}>"
        thr = cond.get("threshold")
        return f"Flag '{name}' >= {thr}"
    if t == "PamProgressionMissionCompletedRewardCondition":
        names = []
        for mg in cond.get("mission_guids", []):
            m = missions_by_guid.get(mg)
            names.append(f"mission#{m['mission_index']}" if m else f"<unresolved {mg}>")
        return f"Mission(s) completed: {', '.join(names) if names else '(none resolved)'}"
    # generic fallback for the other condition types
    extra = ", ".join(f"{k}={v}" for k, v in cond.items() if k != "type")
    return f"{t}({extra})"


def main():
    root = Path(__file__).resolve().parent.parent
    prog_path = root / "gameconfigs" / "PlayerProgressionData.bin"
    rewards_path = root / "gameconfigs" / "RewardsData.bin"

    print(f"Parsing {prog_path.name} ...")
    flags_by_guid, groups_by_guid, missions_by_guid = load_progression(prog_path)
    print(f"  {len(flags_by_guid)} flags, {len(groups_by_guid)} flag groups, "
          f"{len(missions_by_guid)} missions")

    print(f"Parsing {rewards_path.name} ...")
    rewards, conditions = load_rewards(rewards_path)
    print(f"  {len(rewards)} rewards, {len(conditions)} reward conditions")
    cond_types = defaultdict(int)
    for c in conditions.values():
        cond_types[c["type"]] += 1
    for t, n in sorted(cond_types.items(), key=lambda kv: -kv[1]):
        print(f"    {t}: {n}")

    # Assemble the graph: for every reward, resolve its conditions into
    # readable descriptions, and separately resolve every mission's
    # completed/available flag names.
    graph = []
    unresolved_conditions = 0
    for rg, r in rewards.items():
        cond_descs = []
        for cg in r["condition_guids"]:
            cond = conditions.get(cg)
            if cond is None:
                unresolved_conditions += 1
                cond_descs.append(f"<unresolved condition {cg}>")
                continue
            cond_descs.append(describe_condition(cond, flags_by_guid, groups_by_guid, missions_by_guid))
        graph.append({
            "reward_guid": rg,
            "runner_kit_guid": r["runner_kit_guid"],
            "name_hash": r["name_hash"],
            "compare_conditions_type": r["compare_conditions_type"],
            "conditions_count_threshold": r["conditions_count_threshold"],
            "conditions": cond_descs,
            "num_conditions_found": len(r["condition_guids"]),
        })

    missions_out = []
    for mg, m in missions_by_guid.items():
        cflag = flags_by_guid.get(m["completed_flag_guid"])
        aflag = flags_by_guid.get(m["available_flag_guid"])
        missions_out.append({
            **m,
            "completed_flag_name": cflag["name"] if cflag else None,
            "available_flag_name": aflag["name"] if aflag else None,
        })

    out = {
        "flags_by_guid": flags_by_guid,
        "groups_by_guid": groups_by_guid,
        "missions": missions_out,
        "rewards": graph,
    }
    out_path = Path(__file__).resolve().parent / "dependency_graph.json"
    out_path.write_text(json.dumps(out, indent=2, default=str))
    print(f"\nWrote {out_path}")

    # Summary stats
    rewards_with_conditions = sum(1 for g in graph if g["conditions"])
    rewards_with_runnerkit = sum(1 for r in rewards.values() if r["runner_kit_guid"] and r["runner_kit_guid"] != "Guid: 00000000000000000000000000000000")
    missions_with_names = sum(1 for m in missions_out if m["active_name_sid"])
    print(f"\n{len(rewards)} total rewards, {rewards_with_conditions} have >=1 resolved condition, "
          f"{rewards_with_runnerkit} carry a non-null RunnerKitGuid")
    print(f"{len(missions_out)} missions, {missions_with_names} carry a resolved ActiveNameSid")
    print(f"{unresolved_conditions} condition refs on rewards failed to resolve against the parsed condition table")


if __name__ == "__main__":
    main()
