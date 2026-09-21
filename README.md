# Mirror's Edge Catalyst → Archipelago — Reverse Engineering Notes

Goal: build an [Archipelago](https://archipelago.gg/) randomizer integration
for **Mirror's Edge Catalyst** (Frostbite engine, EA/DICE, PC/Steam). This
document is the organized, "pick this up cold" summary. The full
chronological research log — every dead end, every debugging session,
screenshots and all — lives in [`FINDINGS.md`](FINDINGS.md) alongside it;
read that if you want the *why* behind a decision, read this for the *what*
and *how*.

## Where this stands right now

**The hard problem is solved and proven live, end to end.** Mirror's Edge
Catalyst's save file holds every piece of per-save progress as a flat,
readable/writable hash table, and a working Archipelago integration already
exists on top of it:

1. **Reading works.** `decode_save.py` turns any `PROF_SAVE` file into full
   JSON with real names for ~99% of every record — collectibles, missions,
   security hubs, grid nodes, billboard hacks, everything.
2. **Writing works, confirmed live in-game, three different ways:**
   - Flipping one existing record dropped the in-game GridLeaks counter by
     exactly 1, nothing else changed.
   - Bulk-inserting 323 "collected" records made a real, physical GridLeak
     the player was standing in front of **disappear from the world** — the
     actual object-spawn flag, not just a UI cache.
   - Pushing a category to a true 100% and reloading triggered a real
     **"RUNNER KIT DROPPED"** in-game notification — the full mission→reward
     chain firing for real, purely from a save-file edit.
3. **A working Archipelago proof of concept exists.**
   `me_catalyst_hint_bridge.py` watches the save file and fires a real AP
   hint the moment you collect a GridLeak in-game — **tested live against a
   real Archipelago room, every GridLeak sent a hint, every time.**
4. **The file format itself is fully decoded, including both of its CRC32
   integrity checksums**, cross-referenced against an independent save
   editor ([`ploxxxy/frostnibble`](https://github.com/ploxxxy/frostnibble),
   linked by Meteor) and verified byte-exact against the project's own
   original, unedited save files — see "The save file format" below.

All of this needs **zero live game-memory access** — no injection, no
Cheat Engine, nothing running alongside the game. It's pure save-file
read/write, which is what makes it viable as the actual foundation for a
randomizer client.

**What's not done yet:**

- Only GridLeaks is wired into the hint bridge — other categories
  (Secret Bags, Electronic Parts, Audio Pickups, Intel, missions, security
  hubs) are all named and readable, they just need their own hash tables
  added to the bridge (mechanical, same pattern).
- Only "mark collected/uncollected" has been tested, and it's now
  confirmed the game has to be **fully closed** while the save is edited
  — editing while it's running gets silently overwritten by the game's
  own stale in-memory state, but closed-edit-then-launch works reliably
  (tested directly both ways — see `FINDINGS.md` §15/§15a/§15b). So a
  receive-item design needs to queue items and apply them between
  sessions, not try to inject them into an already-running one.
- No real in-world coordinates for individual collectibles have been found,
  which would matter for a "go find this specific item" style check.

See "Open questions / next steps" near the bottom for the full list.

## Use what's already built

You don't need to regenerate anything to use the tools below — the parsed
static data (`gameconfig_dumps/`) and the hash tables are already in this
repo. All you need is a copy of your own `PROF_SAVE` file — confirmed
location: `Documents\Mirrors Edge Catalyst\settings\PROF_SAVE`.
**Always work on a copy, and set Steam offline before testing an edited
save in-game** — see "Lessons learned" for why.

```
# Read: decode a save to full JSON, names resolved
python decode_save.py PROF_SAVE gameconfig_dumps\PlayerProgressionData_full.txt --out decoded.json

# Write: flip one existing record (safest possible edit)
python patch_save.py PROF_SAVE --name "ElectronicPartsAcSh_Chip07Taken" --value 0 --out out.sav

# Write: bulk-collect a whole category, holding a few back to still find in-game
python mass_set_collectibles.py PROF_SAVE gameconfig_dumps\PlayerProgressionData_full.txt --category GridLeaks --leave-uncollected 3 --out out.sav

# Write: reset a category to a clean 0/N starting state
python clear_category.py PROF_SAVE gameconfig_dumps\PlayerProgressionData_full.txt --category GridLeaks --out out.sav

# The Archipelago proof of concept
pip install websockets
python me_catalyst_hint_bridge.py --save "PROF_SAVE" --host <ap-server-host> --port <port> --slot <your-slot-name>
```

Full details on each tool, and on the file format they all operate on, are
below. If you ever need to *regenerate* the static data dumps from scratch
(new game version, missing a file, etc.), see "Static game data (EBX)"
further down — that's optional background, not a prerequisite.

---

## The save file format

Mirror's Edge Catalyst's save file (`PROF_SAVE`) holds every piece of
per-save progress, is **not compressed or encrypted** (whole-file entropy
~0.4 bits/byte — trivially readable with `strings`), and both reading and
writing it are confirmed to work exactly as the live game expects (see the
tested-live list above).

### File format

Cross-referenced and confirmed byte-exact against
[`ploxxxy/frostnibble`](https://github.com/ploxxxy/frostnibble) (a
pre-existing web save editor, linked to us by Meteor — see
`FINDINGS.md` §14 for the full derivation), which pinned down the header
precisely:

```
offset  0  u64   magic "FBCHUNKS"
offset  8  u16   version            (1)
offset 10  u32   headerSize         (8)
offset 14  u32   bodySize           (file_size - 26; fixed 1,024,000-byte capacity)
offset 18  u32   headerHash         (CRC32 checksum, see below)
offset 22  u32   headerEntries      (section count; 13 observed)
offset 26  u32   bodyHash           (CRC32 checksum, see below)
offset 30  —     headerEntries sections, each:

  section := u32 entry_count, entry_count * entry

  entry := u32 type            (1=Float-as-text, 2=Integer-as-text, 3=Long,
                                 4=String-as-text, 5=Binary blob)
           u32 keylen          (strlen(key)+1, NUL included)
           keylen bytes        key, NUL-terminated ASCII
           u32 vallen
           vallen bytes        value (ASCII text, or binary for type 5)
```

Most of the 13 sections are empty (`entry_count = 0`); in every save
examined the real data lives in a handful of them, including the one
holding the `ProgressionManagerData*` blobs below. Everything after the
last used entry is solid zero padding out to a fixed file size
(1,024,026 bytes observed = 26-byte header + 1,024,000-byte body
capacity) — the game pre-allocates a big buffer and only a small fraction
is ever actually used. This matters for editing: you can grow the used
region and shrink the padding (or vice versa) and the game doesn't seem
to care, as long as total file size stays constant.

**Checksums:** both `headerHash` and `bodyHash` use a non-standard CRC32
(standard table/polynomial, seeded with `0x12345678` instead of the usual
`0xFFFFFFFF` — exactly `zlib.crc32(data, 0x12345678)` in Python), with
**no byte-swap on either field**: `headerHash = crc32(le_bytes(headerEntries))`,
`bodyHash = crc32(data[30:end_of_file])`. Verified against the project's
own two original, completely unedited save files (predating any tool
touching them) — both match exactly. (An earlier version of this doc had
`bodyHash` byte-swapped, copied from `frostnibble`'s write code — that
turned out to be a bug specific to their tool, not the real format; see
`FINDINGS.md` §15a for the full story, including how it got caught.) None
of our live in-game write tests showed the game rejecting a save with a
stale `bodyHash`, so it doesn't appear to be strictly enforced at load —
but `save_checksum.py` (below) recomputes both correctly, and every write
tool calls it before writing output, so this is a non-issue either way.

Three `type=5` entries hold the real progression data: `ProgressionManagerData`,
`ProgressionManagerData_<accountID1>`, `ProgressionManagerData_<accountID2>`
(one per linked platform account — not byte-identical copies; not fully
understood which is authoritative, see Open Questions).

### The per-save state table

Inside a `ProgressionManagerData` value:

```
144 bytes   player transform/session floats (position, camera, etc. — unused)
u32         record_count
record_count * { u32 name_hash, u32 value }
```

A flat hash table. `value` is usually `1` (boolean "I have this"), but also
shows up as small counters (2–112 range, e.g. mission playtime-ish stats)
and Unix timestamps on some entries.

### The hash: djb2a, cracked

```python
def djb2a(data: bytes) -> int:
    h = 5381
    for b in data:
        h = ((h * 33) ^ b) & 0xFFFFFFFF
    return h
```

Applied to the **UTF-8 bytes of the item's internal name** (`Name` /
`SyncStatName` / `ActiveNameSid` / etc. from the static game data), **no
trailing NUL**. Building a candidate dictionary from every resolved name
string already known from `PlayerProgressionData_full.txt` (3,342 unique
strings, zero collisions) resolves **99%+ of every record on the first
try** — this is the same djb2a used by the static EBX data's own `Hash`
field type (see "Static game data" below); turns out to be the engine's
general string-hashing primitive.

Example of what a decoded record looks like:

```
TheViewGridLeaks_TheViewCompulsionOrbD0E15D36-8F75-42A9-8176-4E6DDBCA17B9 = 1
ElectronicPartsAcSh_Chip07Taken               = 1
SecurityHubs_Anchor03State                    = 4
Vive La Resistance Debriefing_CompletedTime   = 112
```

### Coverage: not just collectibles

Checked what else is tracked this way — short answer, almost everything,
individually:

- **Story missions**: `<Mission Name> [Briefing/Debriefing]_CompletedTime`
  per mission (value looks like an elapsed-time stat, not a boolean).
- **Opportunity (side) missions**: `OW Opp <zone>Ph<N> <NN>_Available` while
  open, `..._CompletedTime` once done — 40 total known, exact match to the
  in-game "Opportunity Missions" count.
- **Security Hubs**: `SecurityHubs_<Name>State` (a tier value) +
  `SecurityHubsCompleted_<HubName>` (clean boolean) — 8 found, matches "8/8".
- **Grid Nodes**: `GridNodes_<District>Completed`.
- **Billboard Hacks**: `HackableBillboards_<zone code>`.
- **World-state doors/gates**: `Doors_<name>` — booleans for every
  unlockable door/gate/vent, no UI counter tied to these but same pattern.

### Tools

- **`decode_save.py PROF_SAVE static_dump.txt [--out out.json]`** — parses
  every block, decodes every `ProgressionManagerData*` table, resolves
  names, writes full JSON. Start here for reading.
- **`patch_save.py PROF_SAVE --name "..." --value N --out out.sav`** —
  flips one *existing* record's value in place. Fixed-size edit, safest
  possible mutation (no length-prefix or record-count changes).
- **`mass_set_collectibles.py PROF_SAVE static_dump.txt --category GridLeaks
  --leave-uncollected N --out out.sav`** — inserts brand-new records for
  every real item in a category not already present, growing the blob and
  shifting/re-padding the file to keep size constant. Only `GridLeaks` is
  wired up as a category pattern right now; trivial to add more (see the
  `CATEGORY_PATTERNS` dict — one regex per category, naming patterns
  documented above and in `FINDINGS.md` §10h/§12d).
- **`clear_category.py PROF_SAVE static_dump.txt --category GridLeaks
  --out out.sav`** — the inverse: removes every record for a category
  outright (not just value=0), for a clean "0/N" starting state.
- **`save_checksum.py`** — shared helper (imported by the three tools
  above, not usually run directly) that recomputes the header's two CRC32
  checksums after an edit; run standalone against any save
  (`python save_checksum.py PROF_SAVE`) to check whether its checksums are
  currently valid or stale.

### Confirmed live, in-game (not just decoded — actually tested)

1. **Read**: `decode_save.py` output matches the in-game World Progression
   screen's real numbers closely (a couple of small mismatches turned out
   to be name-matching precision on the analysis side, not save-format
   issues).
2. **Write (edit)**: flipping one existing GridLeak record from `1`→`0`
   (via `patch_save.py`) and reloading the save **dropped the World
   Progression GridLeaks count by exactly 1**, with nothing else on screen
   changed.
3. **Write (insert)**: bulk-inserting 323 new "collected" records (via
   `mass_set_collectibles.py`) and reloading **made a real, physical
   GridLeak the player was standing in front of disappear from the world**
   — this is the actual object-spawn flag, not a UI-only cache.
4. **Rewards fire correctly**: pushing a category to a true 100% (324/324
   GridLeaks) and reloading triggered a real **"RUNNER KIT DROPPED"**
   notification in-game — the full mission→reward chain from the static
   data's `dependency_graph.json` firing for real, purely from a save-file
   edit.

**Gotcha**: Steam Cloud will silently re-sync your original save over an
edited one if it's online — always set Steam offline before swapping in a
test save, or a "no change" result might just be cloud sync fighting you,
not a real negative result.

---

## The Archipelago hint bridge (working proof of concept)

`me_catalyst_hint_bridge.py` is a standalone Python script proving out the
actual use case: **real ME:C gameplay driving a real Archipelago
multiworld reaction**, with no browser and no live game-memory access
anywhere.

It's modeled on [`vincenator218/AP---Dino-run`](https://github.com/vincenator218/AP---Dino-run),
whose dino-runner game connects to an AP room as a read-only "HintGame"
companion (`items_handling: 0`, `tags: ['HintGame', ...]`) and, on a score
milestone, sends `{cmd: 'LocationScouts', locations: [id], create_as_hint: true}`
to turn one of the player's still-missing locations into a hint. That
whole mechanism doesn't care what triggers it — so this script speaks the
same minimal protocol directly (no browser, no `ap-client.js`/`ap-ui.js`
needed) and swaps the trigger for "a new GridLeak just got collected,
detected by polling the save file."

```
pip install websockets
python me_catalyst_hint_bridge.py --save "C:\path\to\PROF_SAVE" \
    --host <ap-server-host> --port <port> --slot <your-slot-name>
```

**Tested live against a real Archipelago room: every GridLeak collected
in-game sent a real hint, every time.**

Ships with `gridleaks_hashes.json`, a small precomputed hash→name table
for just the 324 real GridLeaks, so it needs no other static-data files on
the machine actually running it.

To extend to other categories: build a `{hash: name}` table the same way
(see `real_names_for_category` in `mass_set_collectibles.py` for the
pattern — one regex per category) for Secret Bags / Electronic Parts /
Audio Pickups / Intel / missions / security hubs (naming patterns are all
documented above), merge into one table, and the polling loop barely
changes.

---

## A real randomizer game design (skip the story, gate abilities as items)

Full writeup: `FINDINGS.md` §17. Short version: skip tracking story
missions at all — ship a starting save with the story already marked
complete (map/fast travel/security hubs all open) but none of the
movement/combat ability unlocks granted, then have Archipelago items
grant those one at a time. Time Trials become the replayable content the
player actually engages with, and since individual completions aren't
save-tracked (see above), the Electronic Parts sitting along trial routes
serve as the real, save-verifiable checks instead.

This is concretely buildable with what's already been found:

- **58 individually-flagged `Unlocks_*` abilities** (movement, combat,
  health tiers) — confirmed live, not just in static data: a reference
  save has 34/58 unlocked and 24 still locked, and they're already
  readable/writable with `patch_save.py` today, no new tooling needed for
  single flags.
- **`XP` / `XP_Gained` / `XP_Used`** — the skill-point currency behind
  them, confirmed in the same save (`81952` gained / `29000` spent).
  Zeroing or capping this is what stops a player from just buying every
  ability at the menu the moment the save loads.
- **The grapple hook is the one hard exception** — story-gated separately
  (`CriticalPathProgression_HasCollectedMagRope*`), not part of the
  general unlock pool, since it's required to physically progress at all.

Two things still need a live test (not yet run, same style as every other
write test in this project): whether forcing missions "complete" leaves
`Unlocks_*` alone or recomputes/grants them at load, and whether clearing
an already-`true` `Unlocks_*` flag actually disables that ability in-game
the way it did for GridLeaks (§12b).

Also explored: actually intercepting the game's now-dead online traffic,
since EA shut down Catalyst's servers in December 2023 and there's a real
community effort already rerouting this game's network calls
([Beat Revival](https://github.com/Beat-Revival),
[`ploxxxy/pamplona-future`](https://github.com/ploxxxy/pamplona-future),
[`grid-leak/blaze`](https://github.com/grid-leak/blaze)) — none of them
have published the time-trial wire format yet, and doing this ourselves
would be a genuinely separate project (Docker/Rust, DNS or hosts-file
redirection, a real MITM setup), not an extension of the save-file tools.

---

## Tool reference

| Script | Purpose |
|---|---|
| `decode_save.py` | **Read** a save file → full JSON, names resolved |
| `patch_save.py` | **Write**: flip one existing record's value |
| `mass_set_collectibles.py` | **Write**: bulk-insert new "collected" records |
| `clear_category.py` | **Write**: remove every record for a category |
| `save_checksum.py` | Recomputes/checks the header's two CRC32 checksums (used by the three write tools above) |
| `me_catalyst_hint_bridge.py` | Working AP hint-bridge proof of concept |
| `ebx_parser.py` | Parses a raw `.bin` EBX file into Python structures |
| `extract_ground_truth.py` | Builds `ground_truth.json` (flag-group catalog) |
| `build_dependency_graph.py` | Builds `dependency_graph.json` (mission→reward→flag) |
| `dump_progression_state.py` | Live-memory reader (superseded, see below) |

---

## Static game data (EBX)

Background material: this is *how* the real names used everywhere above
were resolved, and it's what `gameconfig_dumps/` already contains
pre-extracted. You only need this section if you're regenerating that data
from scratch (new game version, or a missing/corrupt dump).

The game's asset/config data (`.bin` files, EBX format) describes every
collectible, mission, reward, and progression flag in the game, at design
time. `ebx_parser.py` is a hand-built parser for this format (no official
EBX library was used) that reads a `.bin` file's field reflection metadata
and its instance data, and prints/returns a Python structure.

### Key discoveries

- **`Sid` fields are on-disk string-table offsets, not hashes.** They look
  like small integers but are literally offsets into the file's own string
  table — trivial to resolve to real text once you know that. This was the
  single biggest unlock for getting readable names everywhere (mission
  titles, flag `SyncStatName`s, etc.).
- **A separate `Hash` field type uses djb2a** (`h = ((h*33) ^ byte) & 0xFFFFFFFF`,
  seed 5381) — this turned out to be the *general-purpose* string-hashing
  primitive this engine uses, and resurfaces above for the save file's own
  record keys.
- **`DbObject`-typed list fields are over-inclusive** (`PamProgressionFlagGroup.Flags`,
  `PamReward.RewardConditions`, etc.) — they mix in noise refs alongside the
  real members. The fix: real members are always one specific ref-kind
  (local ref within the same file, or external ref into a specific other
  file, depending on the field) and the noise is the other kind. Filtering
  by ref-kind+type gives clean results.
- **`FileRef` fields can actually be nested structs**, not always file
  references — caught this because a naive parse was silently dropping real
  data (e.g. `PamProgressionMission.MissionDescription`).

### What's extracted

- `PlayerProgressionData.bin` → every `PamProgressionFlag`, `PamProgressionFlagGroup`,
  and `PamProgressionMission` (152 missions, ~2,500 flags), with real names.
- `RewardsData.bin` → every `PamReward` and its `RewardCondition`s (9 known
  subtypes: flag threshold, flag-group completion, mission(s) completed, etc.)
- **Zone/district naming fully solved** by cross-referencing in-game
  "World Progression" screenshots against summed flag-group counts:
  `Rz`=Rezoning, `Dt`=Downtown, `Ac`=Anchor, `Vw`=The View, plus
  `Trainstation`=Zephyr Transit Hub and `TheShard`=the final story mission.
  Separately, the save file revealed the internal name **"Construction"
  displays in-game as "Glass"**.
- **`build_dependency_graph.py`** ties `PlayerProgressionData.bin` and
  `RewardsData.bin` together into one real graph: which flag/flag-group/
  mission-completion unlocks which reward. Output: `dependency_graph.json`
  (67 rewards, 162 conditions, zero unresolved lookups).
- **`ground_truth.json`** (via `extract_ground_truth.py`) is the flat
  catalog of every flag group and its real flag count, used throughout as
  a source of truth to check live/save data against.

### Regenerating the dumps

1. Extract the game's static data as EBX `.bin` files (via Frosty Editor or
   similar) — `PlayerProgressionData.bin` and `RewardsData.bin` at minimum.
2. Parse them with `ebx_parser.py` (see `gameconfig_dumps/*_full.txt` for
   the expected output shape) or re-run `extract_ground_truth.py` /
   `build_dependency_graph.py` to regenerate the JSON catalogs.
3. Run `decode_save.py your_save PlayerProgressionData_full.txt --out
   decoded.json` to confirm the pipeline still resolves ~99% of records
   against your regenerated data.

---

## Live memory access (superseded, kept for reference)

Before the save file was discovered, the plan was to read/write the
game's live process memory. This is **no longer the recommended
approach** — everything above does what this was trying to do, more
reliably, without touching the running game at all. Kept here because the
architectural understanding might still be useful (e.g. for a "detect a
change right now without waiting for a save" nice-to-have).

- Meteor shared a full C++ header dump (`SDK.zip`,
  generated from the game's own RTTI) giving real struct offsets for
  `PamProgressionData` and friends. `dump_progression_state.py` walks
  `module_base + 0x257cb98 → PamProgressionSettings* → +0x20 →
  PamProgressionData*` and reads out every flag/flag-group/mission live —
  confirmed working, matches static data almost field-for-field.
- **Critical finding: this address chain only exposes static config, never
  per-save state.** Byte-diffed the entire live allocation pool around real
  collection events — zero bytes changed, ever. Whatever tracks "have I
  collected this" is not here.
- Spent a long live-debugging session (Cheat Engine, manual disassembly)
  tracing the write path for *aggregate* counters (e.g. "GridLeaks:
  181/324") instead. Found a generic, reflection-based field-write
  mechanism and a shared observer/broadcast system, confirmed identical
  across two independent categories — architecturally interesting, but it
  only ever reaches aggregate UI counters, never the per-item state either.
  This whole thread is what the save-file discovery above made moot.

---

## Repository layout

Everything currently sits flat in the repo root (no subfolders) except the
static dumps and a few early-exploration folders:

```
FINDINGS.md                        full chronological research log (long)
README.md                          this file
.gitignore                         excludes junk/huge/sensitive files, see below
ebx_parser.py                      hand-built EBX/DbObject parser
gameconfig_dumps/                  static .bin -> parsed .txt dumps
build_dependency_graph.py          mission -> reward -> flag graph builder
dependency_graph.json              ...its output
extract_ground_truth.py            builds ground_truth.json
ground_truth.json                  flag-group/location catalog, by name
dump_progression_state.py          live-memory reader (superseded)
dump_region.py, raw_dump_flags.py, read_addresses*.py, test_walk_oracle.py
                                    live-memory debugging tools (superseded)
decode_save.py                     ** read a save file -> full JSON **
patch_save.py                      flip one existing record's value
mass_set_collectibles.py           insert many new records (bulk-collect)
clear_category.py                  remove every record for a category
save_checksum.py                   recomputes the save's two CRC32 checksums
gridleaks_hashes.json              precomputed hash->name table (324 GridLeaks)
me_catalyst_hint_bridge.py         ** working AP hint-bridge proof of concept **
SDK/, Collectibles/, Missions/, ui_widgets/, list.csv, usage_list.txt
                                    earlier exploration / third-party data,
                                    see .gitignore note on SDK/ before pushing
```

**Before pushing this folder publicly**, a `.gitignore` is included that
excludes: Cheat Engine `.CT` tables and other live-memory-era scratch
output (superseded), a ~47MB raw `strings.txt` dump, any real
`PROF_SAVE*` file (can contain account-identifying data), and the `SDK/`
folder specifically — that's the RTTI header dump shared privately on
Discord by Meteor (see Credits), thousands of files, kept locally for
reference but not this project's to redistribute in bulk.

---

## Open questions / next steps

- **Real in-world coordinates for individual collectibles are unknown.**
  Nothing extracted so far (static or save) has looked like a coordinate.
  Needed for any "go find/verify this specific item" workflow that isn't
  luck-based. Worth a fresh look at other data files.
- **Which of the three `ProgressionManagerData*` sections is authoritative**
  isn't fully pinned down — all working tests so far patched all three at
  once to be safe. Worth isolating.
- **Only GridLeaks is wired into the hint bridge.** Other categories need
  their own hash tables (mechanical, same pattern).
- **RESOLVED — the write path needs the game fully closed during the
  edit, confirmed both ways.** First tried editing while the game stayed
  running (`FINDINGS.md` §15a): mass-set all 324 GridLeaks, then tried
  every trigger from standing still up through pause menu, checkpoint
  respawn, zone transition, explicit reload, and a full quit+relaunch —
  none of them showed the edit. A checksum check proved why: the
  already-running process still held its old in-memory progression state
  and wrote that whole state back over our edit before any reload had an
  edited file to actually load. Redid it with the game **fully closed**
  during the edit (§15b): same edit, then launched fresh — **324/324
  GridLeaks, confirmed in-game.** So the rule for a receive-item design is
  settled: the game must not be running while the save is written to;
  queue items and apply them between sessions, don't try to inject them
  into an already-running one. Whether some in-game action can force an
  already-running session to safely reload without losing its own
  concurrent progress is a separate, still-open question, but no longer
  a blocker for a first working design.
- **~1% of records still don't resolve** to a known name — likely need a
  wider static-data source (achievements, `RunnerKitDefinitionsMeta`, full
  `MissionDescription` sub-fields) added to the candidate-string dictionary.
- **`PROF_SAVE_profile`/`PROF_SAVE_backup_profile`** (much smaller, ~1.2KB)
  haven't been examined at all yet.

## Lessons learned / gotchas

- **Steam Cloud will silently overwrite a manually-edited save** if online
  — always go offline before testing an edited save in-game.
- **ASLR invalidates every literal memory address across game restarts** —
  a lesson from the (now superseded) live-memory work, kept here because
  it's a good general reminder if live-memory work is ever revisited.
- **`DbObject`-typed list fields in the static EBX data are over-inclusive**
  — always filter by ref-kind+type, never trust the raw list.
- **The save format's blocks are self-describing but not obviously so** —
  the `[type][keylen][key][vallen][val]` shape only became clear by diffing
  known-length strings against the bytes immediately preceding them.
- **A pre-existing tool for the same format can save a lot of guessing** —
  cross-referencing `ploxxxy/frostnibble` (independently reverse-engineered
  the same save format) pinned down the exact header layout and a CRC32
  checksum we'd been leaving stale, in minutes, that would otherwise have
  taken real effort to notice from the raw bytes alone. Worth checking for
  prior art before assuming something has to be brute-forced from scratch.

## Credits

- **Meteor** (Discord) — shared the `SDK.zip` live RTTI class dump and the
  `PamProgressionData` struct offsets that seeded the live-memory work
  above, pointed at the djb2a hash algorithm that ended up cracking the
  save file, and linked `ploxxxy/frostnibble` (the save file's header
  layout + checksum cross-reference, §14 of `FINDINGS.md`).
