"""
Regression test for the ground-truth-bounded array walker in
dump_progression_state.py, runnable without Windows or the real game.

Reproduces, in miniature, exactly the failure mode that broke live runs #2
and #3: two arrays of real, well-formed, same-type objects sitting
back-to-back in one shared pool with NO gap between them. A pointer-
plausibility-only walker (the old code) cannot tell where array A's real
members end and array B's real (but wrong-array) members begin, because
both are equally "valid" objects. This test builds exactly that layout and
asserts the ground-truth-bounded walker (walk_oracle_bounded + GroundTruth)
stops array A at its known real count instead of reading into array B.

Run directly: `python3 test_walk_oracle.py` (stdlib only, no pytest needed).
"""
import ctypes
import json
import os
import struct
import sys
import tempfile
import types

# dump_progression_state.py calls ctypes.WinDLL(...) at import time, which
# only exists on Windows. Stub it out so the module (and the pure-Python
# walker logic we actually want to test) can still be imported on Linux/Mac.
if not hasattr(ctypes, "WinDLL"):
    class _FakeDLL:
        def __getattr__(self, name):
            return lambda *a, **k: 0
    ctypes.WinDLL = lambda *a, **k: _FakeDLL()
    ctypes.wintypes = types.SimpleNamespace(DWORD=ctypes.c_uint32, HMODULE=ctypes.c_void_p)
    sys.modules["ctypes.wintypes"] = ctypes.wintypes

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import dump_progression_state as dps


class FakeMem:
    """In-process memory simulator backing the same read()/u64()/i32()/
    cstring()/looks_valid_ptr() API MemReader exposes, plus
    resolve_array_first_element bound straight from the real class (it only
    calls those methods, so it works unmodified against this fake)."""

    def __init__(self):
        self.mem = {}
        self.resolve_array_first_element = types.MethodType(
            dps.MemReader.resolve_array_first_element, self)

    def write(self, addr, data):
        for i, b in enumerate(data):
            self.mem[addr + i] = b

    def zero_fill_region(self, addr, size):
        self.write(addr, b"\x00" * size)

    def alloc_cstring(self, addr, s):
        self.write(addr, s.encode() + b"\x00")

    def read(self, addr, size):
        if not addr:
            return None
        out = bytearray()
        for i in range(size):
            if (addr + i) not in self.mem:
                return None
            out.append(self.mem[addr + i])
        return bytes(out)

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
        ptr = self.u64(ptr_addr)
        if not ptr:
            return None
        raw = self.read(ptr, maxlen)
        if raw is None:
            return None
        return raw.split(b"\x00", 1)[0].decode("utf-8", "replace")

    def looks_valid_ptr(self, ptr):
        if not ptr or ptr < 0x10000:
            return False
        return self.read(ptr, dps.PTR_SIZE) is not None


def build_shared_pool_scenario():
    """5 fake PamProgressionFlag objects, back-to-back with no gap: flags
    0-1 belong to GroupA, flags 2-4 belong to GroupB. GroupA's Array<T*>
    field is mode B (points directly at a slot array); GroupB's field
    points 2 slots further into that SAME contiguous slot array -- exactly
    the "one shared pool, no boundary marker" shape the real game's
    allocator appears to use."""
    mem = FakeMem()
    NAME_AREA, FLAG_OBJ_AREA, SLOT_AREA = 0x500000, 0x600000, 0x700000
    mem.zero_fill_region(NAME_AREA, 0x1000)
    mem.zero_fill_region(FLAG_OBJ_AREA, 0x1000)
    mem.zero_fill_region(SLOT_AREA, 0x1000)

    names = ["Alpha", "Bravo", "Charlie", "Delta", "Echo"]
    flag_addrs = []
    name_addr = NAME_AREA
    for i, nm in enumerate(names):
        obj_addr = FLAG_OBJ_AREA + i * 0x40
        mem.alloc_cstring(name_addr, nm)
        mem.write(obj_addr + dps.OFF_FLAG_NAME, struct.pack("<Q", name_addr))
        mem.write(obj_addr + dps.OFF_FLAG_NAMEHASH, struct.pack("<I", i))
        flag_addrs.append(obj_addr)
        name_addr += 32

    for i, addr in enumerate(flag_addrs):
        mem.write(SLOT_AREA + i * 8, struct.pack("<Q", addr))

    groupA_field_addr, groupB_field_addr = 0x900000, 0x900008
    mem.write(groupA_field_addr, struct.pack("<Q", SLOT_AREA + 0 * 8))
    mem.write(groupB_field_addr, struct.pack("<Q", SLOT_AREA + 2 * 8))

    gt_data = {
        "totals": {"num_flag_groups": 2, "num_flags": 5, "num_missions": 0, "num_flag_locations": 0},
        "flags": [{"name": nm, "name_hash": i, "mission_index": None} for i, nm in enumerate(names)],
        "flag_groups": [
            {"name": "GroupA", "name_hash": 0, "flags_count": 2, "member_guids": [], "member_flag_names": names[:2]},
            {"name": "GroupB", "name_hash": 1, "flags_count": 3, "member_guids": [], "member_flag_names": names[2:]},
        ],
        "missions": [],
        "flag_locations": [],
    }
    gt_path = tempfile.mktemp(suffix=".json")
    with open(gt_path, "w") as f:
        json.dump(gt_data, f)
    gt = dps.GroundTruth(gt_path)
    os.unlink(gt_path)
    return mem, gt, groupA_field_addr, groupB_field_addr


def test_group_walk_stops_at_known_count_not_into_neighbor_pool():
    mem, gt, groupA_field_addr, groupB_field_addr = build_shared_pool_scenario()

    def accept_flag_slot(addr):
        flag_ptr = mem.u64(addr)
        if not mem.looks_valid_ptr(flag_ptr):
            return False
        return gt.accept_flag(mem, flag_ptr)

    def names_for(field_addr, group_name):
        budget = gt.group_flag_budget(group_name)
        slots = list(dps.walk_oracle_bounded(mem, field_addr, dps.PTR_SIZE, budget,
                                              accept_flag_slot, tag=group_name))
        return [mem.cstring(mem.u64(s) + dps.OFF_FLAG_NAME) for s in slots]

    names_a = names_for(groupA_field_addr, "GroupA")
    assert names_a == ["Alpha", "Bravo"], (
        f"GroupA leaked past its known 2-flag boundary into the shared pool: {names_a}")

    names_b = names_for(groupB_field_addr, "GroupB")
    assert names_b == ["Charlie", "Delta", "Echo"], f"GroupB mismatch: {names_b}"

    # Every real flag should be accounted for exactly once, globally.
    assert gt.remaining_flag_names == set(), (
        f"some known real flags were never matched: {gt.remaining_flag_names}")


if __name__ == "__main__":
    test_group_walk_stops_at_known_count_not_into_neighbor_pool()
    print("PASS: ground-truth-bounded walker stays within each array's real "
          "boundary even when a same-type neighbor array sits immediately "
          "after it in memory with no gap (the exact bug behind runs #2/#3).")
