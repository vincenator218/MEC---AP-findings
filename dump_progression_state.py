"""
dump_progression_state.py -- live-memory dump of Mirror's Edge Catalyst's
PamProgressionData tree (flag groups, flags, missions), using the address
chain and struct offsets from the community FrostbiteGen SDK dump (SDK/*.h).

RUN THIS ON WINDOWS, WITH THE GAME RUNNING, using the game's own bitness of
Python (the game is 64-bit, so use 64-bit Python 3). No pip packages needed
-- everything here is stdlib (ctypes) + the Windows API.

    python dump_progression_state.py [--process MirrorsEdgeCatalyst] [--out progression_snapshot.json]

ground_truth.json MUST be in the same folder as this script (or pass
--ground-truth <path>). It's a small reference file extracted from the
already-fully-solved static PlayerProgressionData.bin -- the exact real
names/counts of every flag group (124), flag (2376), mission (152), and
flag location (324) in the game. This script now uses that as the
authoritative stopping rule for every array it walks in live memory,
instead of trying to infer array lengths from raw pointer arithmetic (see
"WHY GROUND TRUTH" below -- three earlier runs each got this wrong in a
different way once pointer-only heuristics were the only defense).

If it can't find the process, pass --process with the exact or partial exe
name you see in Task Manager (case-insensitive substring match). If
ReadProcessMemory calls fail (dump has zero groups, or every field is None),
try running this script's terminal as Administrator -- some anti-tamper/DRM
setups require the reader to be elevated too.

WHAT THIS CONFIRMS: the whole address-resolution chain the Discord SDK dump
described (PamProgressionSettings singleton -> +0x20 -> PamProgressionData
-> FlagGroups/Missions arrays -> individual flag/mission objects), decoded
using struct offsets pulled directly from SDK/PamProgressionData.h,
SDK/PamProgressionFlag.h, SDK/PamProgressionFlagGroup.h,
SDK/PamProgressionMission.h, SDK/PamProgressionSettings.h,
SDK/PamMissionDescription.h, and the Array<T>/Asset/DataContainer layout
from SDK/FBSDKTypes.h + SDK/Asset.h + SDK/DataContainer.h.

WHY GROUND TRUTH: the first three live runs each got the FlagGroups/
Missions/ProgressionFlagLocations array sizes wrong in a different way
(5000-capped groups, then ~50x too many flags, then 400 "flag groups" and
2759 "missions") even after fixing the actual pointer-layout bug (Array<T>
fields are 8-byte pointers to an out-of-line header, not inline structs).
The root problem: every object of a given type (every PamProgressionFlag,
every PamProgressionFlagGroup, ...) appears to live in one shared
contiguous allocation pool, so once a walk drifts even slightly past the
true end of "its" array, it keeps finding REAL, VALID, correctly-shaped
objects -- just ones that belong to a different group/array. No amount of
"does this pointer look valid / does this object look well-formed" checking
can tell those apart, because they really are well-formed objects. What
CAN tell them apart is knowing, from the file we've already fully reverse
engineered, exactly which names and exactly how many objects are supposed
to be there -- so this version reads live objects and cross-checks each
one's Name (or, for missions/locations, its index/hash) against the real
set from ground_truth.json, and hard-stops every array at its real known
count. See FINDINGS.md sec 10c for the full diagnosis.

WHAT THIS DOES NOT YET ANSWER: none of the classes read here expose a
"current value" / "is this flag set for my save" field -- only the static
config (Name, MaxValue, Cost, Reputation, SyncStatName, ...). That's the
next open question for the AP integration: run this once, then trigger one
specific flag in-game (e.g. destroy one SecurityCamera) and diff two
snapshots' raw bytes around a flag's known address to see if anything
changes nearby -- if nothing does, the live value likely lives in a
separate save/stats system this SDK dump doesn't cover, and that needs its
own SDK header (ask in the Discord: "what holds the CURRENT value/count for
a PamProgressionFlag, not just its config?").
"""

import argparse
import ctypes
import ctypes.wintypes as wt
import json
import struct
import sys
from collections import Counter
from pathlib import Path

PROCESS_VM_READ = 0x0010
PROCESS_QUERY_INFORMATION = 0x0400
TH32CS_SNAPPROCESS = 0x00000002
TH32CS_SNAPMODULE = 0x00000008
TH32CS_SNAPMODULE32 = 0x00000010

kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)

# ---- offsets pulled straight from the SDK headers (see module docstring) --
# Static slot holding a pointer to the PamProgressionSettings singleton.
# (== SDK/PamProgressionSettings.h GetInstance(): Module + this offset)
PAM_PROGRESSION_SETTINGS_PTR_SLOT = 0x257cb98
# PamProgressionSettings::Offsets::PlayerProgressionData
OFF_SETTINGS_PLAYERPROGRESSIONDATA = 0x20

# PamProgressionData::Offsets
OFF_PD_FLAGGROUPS = 0x18
OFF_PD_MISSIONS = 0x20
OFF_PD_SYS_FLAGS = 0x28
OFF_PD_SYS_MISC = 0x30
OFF_PD_SYS_BRONZE = 0x38
OFF_PD_SYS_SILVER = 0x40
OFF_PD_SYS_GOLD = 0x48
OFF_PD_FLAG_LOCATIONS = 0x50  # Array<PamProgressionFlagLocation>, inline elements

# PamProgressionFlagGroup::Offsets (also the base layout PamProgressionMission inherits)
OFF_FG_NAME = 0x10
OFF_FG_NAMEHASH = 0x18
OFF_FG_FLAGS = 0x20  # Array<PamProgressionFlag*>

# PamProgressionFlag::Offsets
OFF_FLAG_NAMEHASH = 0x10
OFF_FLAG_MISSIONINDEX = 0x14
OFF_FLAG_NAME = 0x18
OFF_FLAG_MAXVALUE = 0x20
OFF_FLAG_COST = 0x24
OFF_FLAG_REPUTATION = 0x28
OFF_FLAG_SYNCSTATNAME = 0x30
OFF_FLAG_CLAMP = 0x38
OFF_FLAG_SYNCTOONLINE = 0x39

# PamProgressionMission::Offsets (fields start after the inherited
# PamProgressionFlagGroup layout, which is 0x40 bytes)
OFF_MISSION_INDEX = 0x40
OFF_MISSION_COMPLETEDFLAG = 0x48   # PamProgressionFlag*
OFF_MISSION_AVAILABLEFLAG = 0x50   # PamProgressionFlag*
OFF_MISSION_DESCRIPTION = 0x58     # PamMissionDescription, INLINE (0x50 bytes)
OFF_MISSION_REPUTATION = 0xA8
OFF_MISSION_CURRENCY = 0xAC
OFF_MISSION_TYPE = 0xB0

# PamMissionDescription::Offsets (relative to the inline struct's own start)
OFF_MD_FLAGNAMEHASH = 0x0
OFF_MD_ACTIVENAME = 0x8
OFF_MD_ACTIVEDESC = 0x10
OFF_MD_AVAILABLENAME = 0x18
OFF_MD_AVAILABLEDESC = 0x20
OFF_MD_OBJECTIVES = 0x28  # Array<const char*> -- not walked here, skipped
OFF_MD_AVAILABLEOBJ = 0x30
OFF_MD_ACCEPTLABEL = 0x38
OFF_MD_MISSIONTEXTURE = 0x40
OFF_MD_LOADSCREENTEXTURE = 0x48

# PamProgressionFlagLocation::Offsets (inline array element, 0x50 bytes each)
OFF_LOC_TRANSFORM = 0x0   # LinearTransform, 0x40 bytes, not decoded here
OFF_LOC_NAMEHASH = 0x40

ARRAY_STRUCT_SIZE = 0x20  # Array<T>: firstElement, lastElement, arrayBound, allocator (4 x 8 bytes)
PTR_SIZE = 8


class PROCESSENTRY32(ctypes.Structure):
    _fields_ = [
        ("dwSize", wt.DWORD), ("cntUsage", wt.DWORD), ("th32ProcessID", wt.DWORD),
        ("th32DefaultHeapID", ctypes.POINTER(ctypes.c_ulong)), ("th32ModuleID", wt.DWORD),
        ("cntThreads", wt.DWORD), ("th32ParentProcessID", wt.DWORD), ("pcPriClassBase", ctypes.c_long),
        ("dwFlags", wt.DWORD), ("szExeFile", ctypes.c_char * 260),
    ]


class MODULEENTRY32(ctypes.Structure):
    _fields_ = [
        ("dwSize", wt.DWORD), ("th32ModuleID", wt.DWORD), ("th32ProcessID", wt.DWORD),
        ("GlblcntUsage", wt.DWORD), ("ProccntUsage", wt.DWORD),
        ("modBaseAddr", ctypes.POINTER(ctypes.c_byte)), ("modBaseSize", wt.DWORD),
        ("hModule", wt.HMODULE), ("szModule", ctypes.c_char * 256), ("szExePath", ctypes.c_char * 260),
    ]


def find_pid(name_substr):
    snap = kernel32.CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0)
    if snap == -1:
        raise OSError("CreateToolhelp32Snapshot(process) failed")
    entry = PROCESSENTRY32()
    entry.dwSize = ctypes.sizeof(PROCESSENTRY32)
    matches = []
    try:
        if kernel32.Process32First(snap, ctypes.byref(entry)):
            while True:
                name = entry.szExeFile.decode(errors="ignore")
                if name_substr.lower() in name.lower():
                    matches.append((entry.th32ProcessID, name))
                if not kernel32.Process32Next(snap, ctypes.byref(entry)):
                    break
    finally:
        kernel32.CloseHandle(snap)
    return matches


def get_main_module_base(pid):
    snap = kernel32.CreateToolhelp32Snapshot(TH32CS_SNAPMODULE | TH32CS_SNAPMODULE32, pid)
    if snap == -1:
        raise OSError(f"CreateToolhelp32Snapshot(module) failed for pid {pid} "
                       f"(try running this script as Administrator)")
    entry = MODULEENTRY32()
    entry.dwSize = ctypes.sizeof(MODULEENTRY32)
    base = None
    name = None
    try:
        if kernel32.Module32First(snap, ctypes.byref(entry)):
            # first module returned for a process is always its main EXE --
            # exactly what fb::GetModuleBase() (== GetModuleHandle(NULL)) means.
            base = ctypes.addressof(entry.modBaseAddr.contents)
            name = entry.szModule.decode(errors="ignore")
    finally:
        kernel32.CloseHandle(snap)
    return base, name


class MemReader:
    def __init__(self, pid):
        self.handle = kernel32.OpenProcess(PROCESS_VM_READ | PROCESS_QUERY_INFORMATION, False, pid)
        if not self.handle:
            raise OSError(f"OpenProcess failed (err={ctypes.get_last_error()}) -- "
                           f"try running this script as Administrator")

    def close(self):
        kernel32.CloseHandle(self.handle)

    def read(self, addr, size):
        if not addr:
            return None
        buf = ctypes.create_string_buffer(size)
        n = ctypes.c_size_t(0)
        ok = kernel32.ReadProcessMemory(self.handle, ctypes.c_void_p(addr), buf, size, ctypes.byref(n))
        if not ok or n.value != size:
            return None
        return buf.raw

    def u64(self, addr):
        b = self.read(addr, 8)
        return struct.unpack("<Q", b)[0] if b else 0

    def u32(self, addr):
        b = self.read(addr, 4)
        return struct.unpack("<I", b)[0] if b else None

    def i32(self, addr):
        b = self.read(addr, 4)
        return struct.unpack("<i", b)[0] if b else None

    def i16(self, addr):
        b = self.read(addr, 2)
        return struct.unpack("<h", b)[0] if b else None

    def u8(self, addr):
        b = self.read(addr, 1)
        return b[0] if b else None

    def cstring(self, ptr_addr, maxlen=256):
        """Reads a `const char*` FIELD: first dereferences the pointer stored
        at ptr_addr, then reads a null-terminated string from where it points."""
        ptr = self.u64(ptr_addr)
        if not ptr:
            return None
        raw = self.read(ptr, maxlen)
        if raw is None:
            return None
        return raw.split(b"\x00", 1)[0].decode("utf-8", "replace")

    def looks_valid_ptr(self, ptr):
        """Cheap plausibility + liveness check: is this actually a pointer
        into this process's address space right now. Necessary but NOT
        sufficient on its own -- see module docstring's "WHY GROUND TRUTH"
        -- neighboring objects in a shared pool pass this just as easily as
        the right one, so this is only used to avoid crashing on garbage,
        never as the reason to accept an element as real."""
        if not ptr or ptr < 0x10000 or ptr > 0x00007FFFFFFFFFFF:
            return False
        return self.read(ptr, PTR_SIZE) is not None

    def resolve_array_first_element(self, array_field_addr, elem0_check=None, tag=""):
        """Every `Array<T>`-typed field in the SDK headers is only 8 bytes
        wide (checked the byte gap to the next field across half a dozen
        classes -- always exactly 8, never the 32 you'd need for an inline
        {first,last,bound,allocator} struct). So the field itself holds a
        POINTER (call it x), not the struct inline. Two hypotheses for what
        x points to, tried in order and validated with `elem0_check` (a
        callable taking a candidate "first element address" and returning
        True if element 0 there looks like a real, ground-truth-verifiable
        object of the expected type):

          A) x points to an out-of-line {first,last,bound,allocator}
             header (matches FBSDKTypes.h's Array<T> declaration, just not
             stored inline).
          B) x directly IS the first element's address, with no separate
             header we can find.

        The (last-first)/elemSize span from hypothesis A is NOT used as a
        trusted count anymore (see module docstring) -- only to locate
        element 0. Every array's actual walked length is now bounded by its
        known real count from ground_truth.json, applied by the caller.

        Returns the starting address, or None if neither hypothesis
        produces a ground-truth-verifiable element 0."""
        x = self.u64(array_field_addr)
        if not self.looks_valid_ptr(x):
            print(f"    [{tag}] field pointer invalid: {hex(x) if x else 'NULL'}")
            return None

        raw = self.read(x, ARRAY_STRUCT_SIZE)
        if raw is not None:
            first, last, bound, allocator = struct.unpack("<QQQQ", raw)
            if self.looks_valid_ptr(first):
                if elem0_check is None or elem0_check(first):
                    print(f"    [{tag}] mode=A(out-of-line header) x={hex(x)} first={hex(first)}")
                    return first

        if elem0_check is None or elem0_check(x):
            print(f"    [{tag}] mode=B(field IS first element) x={hex(x)}")
            return x

        print(f"    [{tag}] neither hypothesis produced a ground-truth-verifiable "
              f"element 0 (x={hex(x)}) -- giving up on this array")
        return None


def walk_oracle_bounded(mem, array_field_addr, elem_size, max_count, accept_fn, tag=""):
    """Walks an array (of INLINE elements, or of POINTERS if elem_size ==
    PTR_SIZE and the caller dereferences inside accept_fn -- see callers)
    starting at whatever resolve_array_first_element finds, calling
    accept_fn(candidate_addr) -> bool for every slot. accept_fn is expected
    to check the live object's identity (name / index / hash) against
    ground_truth.json and track which known real objects have already been
    consumed this run, so it rejects both garbage AND real-but-wrong-array
    neighbors -- see module docstring.

    Stops as soon as either: (a) max_count accepted elements have been
    collected (the known real count for this array -- the hard, authoritative
    stop this whole rewrite exists to add), or (b) the pointer itself stops
    looking valid, or (c) too many consecutive slots in a row get rejected
    by accept_fn (a handful of tolerated holes, same as before, but capped
    much tighter now since accept_fn is a much stronger signal than raw
    pointer validity).

    IMPORTANT: accept_fn has side effects (it consumes the matched name/
    index/hash from GroundTruth's "remaining" pools, so the same real object
    can't be double-counted from two different candidate addresses).
    resolve_array_first_element() already calls accept_fn once on whichever
    candidate validates element 0, as part of choosing between its two
    address hypotheses -- so that first element is already consumed by the
    time this function gets `first` back. The scan below accounts for that:
    it yields `first` immediately without calling accept_fn on it a second
    time (a second call would spuriously fail, since the name it matched was
    already removed from the pool), then continues scanning from the next
    slot with fresh accept_fn calls as normal."""
    if max_count <= 0:
        print(f"    [{tag}] budget is 0 (nothing left to match) -- skipping this array")
        return
    first = mem.resolve_array_first_element(array_field_addr, accept_fn, tag)
    if first is None:
        return
    yield first
    accepted = 1
    consecutive_rejected = 0
    max_consecutive_rejected = 10
    # Hard safety backstop independent of ground truth, in case of a huge
    # unbounded drift before even the first real element is found again --
    # should never be hit in practice since max_count is normally reached
    # first for a correctly-located array.
    hard_scan_limit = max(max_count * 20, 500)
    i = 1
    while i < hard_scan_limit and accepted < max_count:
        addr = first + i * elem_size
        if not mem.looks_valid_ptr(addr):
            consecutive_rejected += 1
            if consecutive_rejected >= max_consecutive_rejected:
                return
            i += 1
            continue
        if accept_fn(addr):
            yield addr
            accepted += 1
            consecutive_rejected = 0
        else:
            consecutive_rejected += 1
            if consecutive_rejected >= max_consecutive_rejected:
                return
        i += 1


class GroundTruth:
    """Loads ground_truth.json (see extract_ground_truth.py) and hands out
    accept_fn callables + hard counts for each array this script walks.
    Every "consumed" set below is global for the whole run, not per-group --
    a real flag/group/mission only exists once, so once its name/index has
    been matched to a live object it's removed from the pool of names any
    OTHER candidate element is still allowed to match. That's what stops the
    walk from double-counting a neighbor from the shared allocation pool
    under a name that's still technically "real" but already spoken for."""

    def __init__(self, path):
        data = json.loads(Path(path).read_text())
        self.totals = data["totals"]
        self.flags_by_name = {f["name"]: f for f in data["flags"] if f["name"]}
        self.groups_by_name = {g["name"]: g for g in data["flag_groups"] if g["name"]}
        self.mission_indices = {m["mission_index"] for m in data["missions"]
                                 if m["mission_index"] is not None}
        self.location_namehash_budget = Counter(
            l["name_hash"] for l in data.get("flag_locations", []) if l["name_hash"] is not None)

        self.remaining_group_names = set(self.groups_by_name)
        self.remaining_flag_names = set(self.flags_by_name)
        self.remaining_mission_indices = set(self.mission_indices)
        # Locations don't have unique names -- track only a total budget,
        # decremented per matched namehash (falls back to "any" budget once
        # a specific hash's known multiplicity is exhausted, since 324 total
        # is the real hard limit regardless).
        self.locations_accepted = 0

    def num_groups(self):
        return self.totals["num_flag_groups"]

    def num_flags(self):
        return self.totals["num_flags"]

    def num_missions(self):
        return self.totals["num_missions"]

    def num_locations(self):
        return self.totals.get("num_flag_locations", 0)

    def group_flag_budget(self, group_name):
        """How many flags this specific group is known to really have, or
        None if the static side's own .Flags field didn't resolve for it
        (see extract_ground_truth.py -- ~20/124 groups) -- caller falls back
        to the shared global flag budget for those."""
        g = self.groups_by_name.get(group_name)
        if g is None:
            return None
        return g.get("flags_count") or None

    def accept_group(self, mem, group_addr):
        name = mem.cstring(group_addr + OFF_FG_NAME)
        if name in self.remaining_group_names:
            self.remaining_group_names.discard(name)
            return True
        return False

    def accept_flag(self, mem, flag_addr):
        name = mem.cstring(flag_addr + OFF_FLAG_NAME)
        if name in self.remaining_flag_names:
            self.remaining_flag_names.discard(name)
            return True
        return False

    def accept_mission(self, mem, mission_addr):
        idx = mem.u32(mission_addr + OFF_MISSION_INDEX)
        if idx in self.remaining_mission_indices:
            self.remaining_mission_indices.discard(idx)
            return True
        return False

    def accept_location(self, mem, loc_addr):
        if self.locations_accepted >= self.num_locations():
            return False
        nh = mem.i16(loc_addr + OFF_LOC_NAMEHASH)
        if self.location_namehash_budget.get(nh, 0) > 0:
            self.location_namehash_budget[nh] -= 1
            self.locations_accepted += 1
            return True
        # Unknown/exhausted specific hash -- still allow it against the
        # overall 324 budget rather than rejecting outright, since location
        # namehashes collide a lot in the real data (see extract_ground_truth
        # output) and being too strict here would just re-introduce the
        # under-counting problem for a field where the total-count backstop
        # is what actually matters.
        self.locations_accepted += 1
        return True


def dump_flag(mem, flag_ptr):
    return {
        "address": hex(flag_ptr),
        "name": mem.cstring(flag_ptr + OFF_FLAG_NAME),
        "nameHash": mem.u32(flag_ptr + OFF_FLAG_NAMEHASH),
        "missionIndex": mem.u32(flag_ptr + OFF_FLAG_MISSIONINDEX),
        "maxValue": mem.i32(flag_ptr + OFF_FLAG_MAXVALUE),
        "cost": mem.i32(flag_ptr + OFF_FLAG_COST),
        "reputation": mem.i32(flag_ptr + OFF_FLAG_REPUTATION),
        "syncStatName": mem.cstring(flag_ptr + OFF_FLAG_SYNCSTATNAME),
        "clamp": bool(mem.u8(flag_ptr + OFF_FLAG_CLAMP)),
        "syncToOnline": bool(mem.u8(flag_ptr + OFF_FLAG_SYNCTOONLINE)),
    }


def dump_flag_group(mem, group_ptr, gt):
    if not group_ptr:
        return None
    group_name = mem.cstring(group_ptr + OFF_FG_NAME)
    budget = gt.group_flag_budget(group_name)
    if budget is None:
        # No known per-group count -- fall back to whatever's left of the
        # global flag budget (still a real, correct hard ceiling, just a
        # looser one for this specific group).
        budget = len(gt.remaining_flag_names)

    def accept(addr):
        # array_ptrs semantics: `addr` is the address of a slot holding a
        # POINTER to the actual PamProgressionFlag object.
        flag_ptr = mem.u64(addr)
        if not mem.looks_valid_ptr(flag_ptr):
            return False
        return gt.accept_flag(mem, flag_ptr)

    flags = []
    for slot_addr in walk_oracle_bounded(
            mem, group_ptr + OFF_FG_FLAGS, PTR_SIZE, budget, accept,
            tag=f"Flags of {group_name or hex(group_ptr)}"):
        flag_ptr = mem.u64(slot_addr)
        flags.append(dump_flag(mem, flag_ptr))

    return {
        "address": hex(group_ptr),
        "name": group_name,
        "nameHash": mem.u32(group_ptr + OFF_FG_NAMEHASH),
        "flags": flags,
    }


def dump_mission_description(mem, md_addr):
    return {
        "flagNameHash": mem.u32(md_addr + OFF_MD_FLAGNAMEHASH),
        "activeName": mem.cstring(md_addr + OFF_MD_ACTIVENAME),
        "activeDescription": mem.cstring(md_addr + OFF_MD_ACTIVEDESC),
        "availableName": mem.cstring(md_addr + OFF_MD_AVAILABLENAME),
        "availableDescription": mem.cstring(md_addr + OFF_MD_AVAILABLEDESC),
        "availableObjective": mem.cstring(md_addr + OFF_MD_AVAILABLEOBJ),
        "acceptLabel": mem.cstring(md_addr + OFF_MD_ACCEPTLABEL),
        "missionTextureId": mem.cstring(md_addr + OFF_MD_MISSIONTEXTURE),
        "loadScreenTextureId": mem.cstring(md_addr + OFF_MD_LOADSCREENTEXTURE),
    }


def dump_mission(mem, mission_ptr):
    if not mission_ptr:
        return None
    completed_ptr = mem.u64(mission_ptr + OFF_MISSION_COMPLETEDFLAG)
    available_ptr = mem.u64(mission_ptr + OFF_MISSION_AVAILABLEFLAG)
    return {
        "address": hex(mission_ptr),
        # PamProgressionMission inherits PamProgressionFlagGroup's layout,
        # so it has its own Name/NameHash/Flags too, at the base offsets.
        "name": mem.cstring(mission_ptr + OFF_FG_NAME),
        "missionIndex": mem.u32(mission_ptr + OFF_MISSION_INDEX),
        "completedFlag": {"address": hex(completed_ptr), "name": mem.cstring(completed_ptr + OFF_FLAG_NAME)}
        if completed_ptr else None,
        "availableFlag": {"address": hex(available_ptr), "name": mem.cstring(available_ptr + OFF_FLAG_NAME)}
        if available_ptr else None,
        "description": dump_mission_description(mem, mission_ptr + OFF_MISSION_DESCRIPTION),
        "reputation": mem.i32(mission_ptr + OFF_MISSION_REPUTATION),
        "currency": mem.i32(mission_ptr + OFF_MISSION_CURRENCY),
        "missionTypeRaw": mem.u32(mission_ptr + OFF_MISSION_TYPE),
    }


def dump_flag_location(mem, loc_addr):
    return {
        "address": hex(loc_addr),
        "nameHash": mem.i16(loc_addr + OFF_LOC_NAMEHASH),
        # Transform (LinearTransform, 0x40 bytes at +0x0) not decoded here --
        # add if world-space coordinates end up mattering for the APWorld.
    }


class _Tee:
    """Duplicates writes to multiple streams -- used so this run's console
    output (including the per-array diagnostic lines) is also saved to a
    log file automatically, without needing a copy-paste from the
    terminal."""

    def __init__(self, *streams):
        self.streams = streams

    def write(self, data):
        for s in self.streams:
            s.write(data)

    def flush(self):
        for s in self.streams:
            s.flush()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--process", default="MirrorsEdgeCatalyst",
                     help="substring of the game's exe name to match (default: MirrorsEdgeCatalyst)")
    ap.add_argument("--out", default="progression_snapshot.json")
    ap.add_argument("--ground-truth", default=None,
                     help="path to ground_truth.json (default: next to this script)")
    args = ap.parse_args()

    log_path = (args.out[:-5] if args.out.endswith(".json") else args.out) + "_log.txt"
    log_file = open(log_path, "w", encoding="utf-8")
    real_stdout = sys.stdout
    sys.stdout = _Tee(real_stdout, log_file)
    print(f"(full console output is also being saved to {log_path} -- send that "
          f"file along with the .json if anything looks off)")

    gt_path = args.ground_truth or (Path(__file__).resolve().parent / "ground_truth.json")
    if not Path(gt_path).exists():
        print(f"ERROR: ground_truth.json not found at {gt_path}. This script needs it "
              f"(run extract_ground_truth.py, or copy ground_truth.json next to this "
              f"script) -- it's the reference data that tells the live walker the real "
              f"array sizes/names, see the module docstring.", file=sys.stderr)
        sys.exit(1)
    gt = GroundTruth(gt_path)
    print(f"Loaded ground truth: {gt.num_groups()} flag groups, {gt.num_flags()} flags, "
          f"{gt.num_missions()} missions, {gt.num_locations()} flag locations "
          f"(from {gt_path})")

    matches = find_pid(args.process)
    if not matches:
        print(f"No running process matching '{args.process}' found. "
              f"Check Task Manager for the exact exe name and pass --process <name>.", file=sys.stderr)
        sys.exit(1)
    if len(matches) > 1:
        print(f"Multiple matches for '{args.process}': {matches}. "
              f"Pass a more specific --process value.", file=sys.stderr)
        sys.exit(1)

    pid, exe_name = matches[0]
    print(f"Found process: {exe_name} (pid={pid})")

    base, module_name = get_main_module_base(pid)
    if not base:
        print("Could not resolve the main module base address. "
              "Try running this script as Administrator.", file=sys.stderr)
        sys.exit(1)
    print(f"Main module: {module_name} @ {hex(base)}")

    mem = MemReader(pid)
    try:
        settings_ptr_slot = base + PAM_PROGRESSION_SETTINGS_PTR_SLOT
        settings_ptr = mem.u64(settings_ptr_slot)
        print(f"PamProgressionSettings* slot @ {hex(settings_ptr_slot)} -> {hex(settings_ptr) if settings_ptr else 'NULL'}")
        if not settings_ptr:
            print("PamProgressionSettings pointer is NULL -- is the game fully "
                  "loaded into a save/level (not just sitting at the main menu)?", file=sys.stderr)
            sys.exit(1)

        pd_ptr = mem.u64(settings_ptr + OFF_SETTINGS_PLAYERPROGRESSIONDATA)
        print(f"PamProgressionData* -> {hex(pd_ptr) if pd_ptr else 'NULL'}")
        if not pd_ptr:
            print("PlayerProgressionData pointer is NULL.", file=sys.stderr)
            sys.exit(1)

        print(f"Walking FlagGroups (hard cap: {gt.num_groups()} known real groups)...")

        def accept_group_slot(addr):
            group_ptr = mem.u64(addr)
            if not mem.looks_valid_ptr(group_ptr):
                return False
            return gt.accept_group(mem, group_ptr)

        flag_groups = []
        for slot_addr in walk_oracle_bounded(
                mem, pd_ptr + OFF_PD_FLAGGROUPS, PTR_SIZE, gt.num_groups(), accept_group_slot,
                tag="PamProgressionData.FlagGroups"):
            group_ptr = mem.u64(slot_addr)
            fg = dump_flag_group(mem, group_ptr, gt)
            if fg:
                flag_groups.append(fg)
        total_flags = sum(len(g["flags"]) for g in flag_groups)
        print(f"  {len(flag_groups)}/{gt.num_groups()} flag groups matched, "
              f"{total_flags}/{gt.num_flags()} total flags matched")
        if gt.remaining_group_names:
            print(f"  NOTE: {len(gt.remaining_group_names)} known real group(s) were "
                  f"never found in memory: {sorted(gt.remaining_group_names)[:15]}"
                  f"{', ...' if len(gt.remaining_group_names) > 15 else ''}")
        if gt.remaining_flag_names:
            print(f"  NOTE: {len(gt.remaining_flag_names)} known real flag(s) were "
                  f"never matched to any group (may be one of the systemGenerated* "
                  f"groups dumped separately below, or a group whose walk stopped early)")

        print(f"Walking Missions (hard cap: {gt.num_missions()} known real missions)...")

        def accept_mission_slot(addr):
            mission_ptr = mem.u64(addr)
            if not mem.looks_valid_ptr(mission_ptr):
                return False
            return gt.accept_mission(mem, mission_ptr)

        missions = []
        for slot_addr in walk_oracle_bounded(
                mem, pd_ptr + OFF_PD_MISSIONS, PTR_SIZE, gt.num_missions(), accept_mission_slot,
                tag="PamProgressionData.Missions"):
            mission_ptr = mem.u64(slot_addr)
            m = dump_mission(mem, mission_ptr)
            if m:
                missions.append(m)
        print(f"  {len(missions)}/{gt.num_missions()} missions matched")

        print(f"Walking ProgressionFlagLocations (hard cap: {gt.num_locations()} known real locations)...")
        locations = []
        for loc_addr in walk_oracle_bounded(
                mem, pd_ptr + OFF_PD_FLAG_LOCATIONS, 0x50, gt.num_locations(),
                lambda addr: gt.accept_location(mem, addr),
                tag="PamProgressionData.ProgressionFlagLocations"):
            locations.append(dump_flag_location(mem, loc_addr))
        print(f"  {len(locations)}/{gt.num_locations()} flag locations matched")

        # System-generated groups are single pointers, not arrays -- no
        # oracle-bounding needed, but still validate the name against the
        # (by-now-mostly-consumed) known group name pool if any is left, so
        # a bad pointer here doesn't silently produce a garbage object.
        system_groups = {}
        for label, off in [
            ("systemGeneratedFlags", OFF_PD_SYS_FLAGS),
            ("systemGeneratedMiscCompletionFlags", OFF_PD_SYS_MISC),
            ("systemGeneratedBronzeCompletionFlags", OFF_PD_SYS_BRONZE),
            ("systemGeneratedSilverCompletionFlags", OFF_PD_SYS_SILVER),
            ("systemGeneratedGoldCompletionFlags", OFF_PD_SYS_GOLD),
        ]:
            ptr = mem.u64(pd_ptr + off)
            system_groups[label] = dump_flag_group(mem, ptr, gt) if mem.looks_valid_ptr(ptr) else None

        snapshot = {
            "process": exe_name,
            "moduleBase": hex(base),
            "playerProgressionDataPtr": hex(pd_ptr),
            "flagGroups": flag_groups,
            "missions": missions,
            "progressionFlagLocations": locations,
            "systemGeneratedGroups": system_groups,
        }
        with open(args.out, "w", encoding="utf-8") as f:
            json.dump(snapshot, f, indent=2)
        print(f"Wrote {args.out}")
    finally:
        mem.close()


if __name__ == "__main__":
    main()
