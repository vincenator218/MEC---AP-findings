#!/usr/bin/env python3
"""
me_catalyst_hint_bridge.py -- proof of concept: every time you collect a
GridLeak in Mirror's Edge Catalyst, ask your Archipelago server to turn one
of your still-missing locations into a hint.

This is a standalone "HintGame" companion client, the same pattern as
vincenator218/AP---Dino-run's dino-runner (it connects read-only, with
items_handling=0 and tags=['HintGame', ...], and its whole job is calling
LocationScouts with create_as_hint=true at the right moment) -- just with
ME:C save-file collection events as the trigger instead of dino-run score
milestones. No browser, no local web page, no changes to the dino-run repo
needed: this runs standalone, and can run *alongside* the dino-run page
(or anything else) connected as a second companion to the same slot.

Requirements:
    pip install websockets

Usage:
    python me_catalyst_hint_bridge.py \
        --save "C:\\path\\to\\PROF_SAVE" \
        --host archipelago.gg --port 12345 --slot YourSlotName

    (add --password if the room has one; --poll-interval to change how
    often the save file is checked, default 3 seconds)

How it detects a new collection: polls the save file, decodes every
GridLeak record via the pre-baked gridleaks_hashes.json (324 known real
names -> hashes, built from the static game data -- see FINDINGS.md §12),
and diffs the set of value==1 hashes against the previous poll. Any hash
that's newly 1 (in *any* of the file's ProgressionManagerData* sections --
which section is authoritative for gameplay isn't 100% pinned down yet,
see FINDINGS.md §12b, so this checks all of them to be safe) fires one
hint request.

This is deliberately minimal for a first proof of concept: one trigger
category (GridLeaks), no reconnect/backoff logic, uniform-random pick among
still-missing/not-yet-hinted locations (no progression-item weighting like
the dino client's getRandomMissingLocation does). Easy to extend once this
works end to end -- see the bottom of the file for notes on that.
"""
import argparse
import asyncio
import json
import random
import struct
import sys
import time
import uuid

try:
    import websockets
except ImportError:
    print("Missing dependency: pip install websockets", file=sys.stderr)
    sys.exit(1)


# ---------------------------------------------------------------------------
# Save file parsing (trimmed down from decode_save.py / patch_save.py --
# see FINDINGS.md §12 for the full format writeup)
# ---------------------------------------------------------------------------

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
    return keystr, data[vpos + 4: vpos + 4 + vallen], vpos + 4 + vallen


def find_progression_blobs(data, start_pos=46):
    n = len(data)
    pos = start_pos
    blobs = []
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
            key, val, newpos = r
            entries.append((key, val))
            bpos = newpos
        if not ok:
            break
        for key, val in entries:
            if key.startswith("ProgressionManagerData"):
                blobs.append(val)
        pos = bpos
    return blobs


def read_collected_gridleaks(save_path, hash_table):
    """Returns the set of GridLeak names currently at value==1, in ANY
    ProgressionManagerData* section."""
    data = open(save_path, "rb").read()
    collected = set()
    for blob in find_progression_blobs(data):
        count = read_u32(blob, 144)
        for i in range(count):
            h, v = struct.unpack_from("<II", blob, 148 + i * 8)
            if v == 1:
                name = hash_table.get(f"0x{h:08x}")
                if name:
                    collected.add(name)
    return collected


# ---------------------------------------------------------------------------
# Minimal Archipelago "HintGame" client -- same protocol as ap-client.js
# ---------------------------------------------------------------------------

class HintBridge:
    def __init__(self, host, port, slot, password):
        self.host = host
        self.port = port
        self.slot = slot
        self.password = password
        self.ws = None
        self.connected = False
        self.missing_locations = set()
        self.sent_hints = set()
        self.location_names = {}  # id -> name, if the data package covers our game

    async def connect_and_run(self, save_path, hash_table, poll_interval):
        url = f"wss://{self.host}:{self.port}"
        print(f"[bridge] connecting to {url} as slot {self.slot!r} ...")
        async with websockets.connect(url) as ws:
            self.ws = ws
            await self.send({"cmd": "GetDataPackage"})
            await asyncio.gather(
                self._recv_loop(),
                self._poll_loop(save_path, hash_table, poll_interval),
            )

    async def send(self, packet):
        await self.ws.send(json.dumps([packet]))

    async def _recv_loop(self):
        async for message in self.ws:
            try:
                packets = json.loads(message)
            except json.JSONDecodeError:
                continue
            if isinstance(packets, dict):
                packets = [packets]
            for packet in packets:
                await self._handle_packet(packet)

    async def _handle_packet(self, packet):
        cmd = packet.get("cmd")
        if cmd == "DataPackage":
            data = packet.get("data", {})
            games = data.get("games", {})
            for gname, gdata in games.items():
                for lname, lid in gdata.get("location_name_to_id", {}).items():
                    self.location_names[lid] = f"{gname}: {lname}"
            await self.send({
                "cmd": "Connect",
                "game": "",
                "name": self.slot,
                "uuid": str(uuid.uuid4()),
                "version": {"major": 0, "minor": 5, "build": 0, "class": "Version"},
                "items_handling": 0,
                "tags": ["HintGame", "MirrorsEdgeCatalyst"],
                "password": self.password,
            })
        elif cmd == "Connected":
            self.connected = True
            self.missing_locations = set(packet.get("missing_locations", []))
            print(f"[bridge] connected. {len(self.missing_locations)} missing locations known.")
        elif cmd == "RoomUpdate":
            if "missing_locations" in packet:
                self.missing_locations = set(packet["missing_locations"])
        elif cmd == "PrintJSON":
            text = "".join(p.get("text", "") for p in packet.get("data", []) if isinstance(p, dict))
            if text:
                print(f"[server] {text}")
        elif cmd == "ConnectionRefused":
            print(f"[bridge] connection refused: {packet.get('errors')}", file=sys.stderr)
        elif cmd == "Error":
            print(f"[bridge] server error: {packet}", file=sys.stderr)

    def send_hint_sync_pick(self):
        available = [loc for loc in self.missing_locations if loc not in self.sent_hints]
        if not available:
            return None
        return random.choice(available)

    async def send_hint(self, reason):
        if not self.connected:
            print(f"[bridge] ({reason}) not connected yet, skipping")
            return
        loc = self.send_hint_sync_pick()
        if loc is None:
            print(f"[bridge] ({reason}) no un-hinted missing locations left")
            return
        self.sent_hints.add(loc)
        name = self.location_names.get(loc, f"location #{loc}")
        print(f"[bridge] ({reason}) requesting hint for {name}")
        await self.send({"cmd": "LocationScouts", "locations": [loc], "create_as_hint": True})

    async def _poll_loop(self, save_path, hash_table, poll_interval):
        last_collected = None
        while True:
            try:
                collected = read_collected_gridleaks(save_path, hash_table)
            except FileNotFoundError:
                print(f"[bridge] save file not found: {save_path}", file=sys.stderr)
                await asyncio.sleep(poll_interval)
                continue
            except Exception as e:
                print(f"[bridge] error reading save: {e}", file=sys.stderr)
                await asyncio.sleep(poll_interval)
                continue

            if last_collected is not None:
                newly_collected = collected - last_collected
                for name in newly_collected:
                    print(f"[bridge] detected new GridLeak: {name}")
                    await self.send_hint(f"GridLeak collected: {name}")
            last_collected = collected
            await asyncio.sleep(poll_interval)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--save", required=True, help="Path to your PROF_SAVE file")
    ap.add_argument("--host", required=True, help="Archipelago server hostname")
    ap.add_argument("--port", type=int, default=38281)
    ap.add_argument("--slot", required=True, help="Your slot name in the room")
    ap.add_argument("--password", default="")
    ap.add_argument("--poll-interval", type=float, default=3.0, help="Seconds between save-file checks")
    ap.add_argument("--hash-table", default="gridleaks_hashes.json", help="Path to the GridLeak hash->name table")
    args = ap.parse_args()

    hash_table = json.load(open(args.hash_table))
    print(f"[bridge] loaded {len(hash_table)} known GridLeak names")

    bridge = HintBridge(args.host, args.port, args.slot, args.password)
    try:
        asyncio.run(bridge.connect_and_run(args.save, hash_table, args.poll_interval))
    except KeyboardInterrupt:
        print("\n[bridge] stopped")


if __name__ == "__main__":
    main()

# ---------------------------------------------------------------------------
# Notes for extending past this proof of concept:
# - Other categories: build a hash table the same way gridleaks_hashes.json
#   was built (see FINDINGS.md §12's real_names_for_category-style regex,
#   just swap the CATEGORY_PATTERNS entry) for SecretBag/ElectronicParts/
#   AudioPickup/Intel/missions/security hubs -- §12d has the exact naming
#   patterns for each. Merge them into one {hash: (category, name)} table
#   and this script barely changes.
# - Smarter location picking: port getRandomMissingLocation's progression-
#   item weighting (ap-client.js) if plain random hints feel too weak/too
#   strong.
# - Death Link: same Bounce-packet pattern ap-client.js uses, tied to
#   something in-game instead of a dino crash -- e.g. a player death event,
#   if that's ever found in the save/live memory.
# - Resilience: no reconnect-on-drop logic yet -- fine for a POC session,
#   worth adding before leaving this running unattended for a long time.
