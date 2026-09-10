# Mirror's Edge Catalyst → Archipelago recon: findings & status

Two tracks so far: a hand-built EBX binary parser (built blind, then
validated), and direct exploration in Frosty Editor once you had it open.
Frosty is ground truth and supersedes the parser wherever they disagree —
the parser was always a stand-in for not having Frosty running yet.

---

## 1. Where we're at, against the original phased plan

The original plan (see the very first message of this thread) put the bulk
of the risk in **Phase 4 — reverse-engineer Mirror's Edge Catalyst**,
estimated at 2-4+ months, built around Cheat Engine / ReClass.NET /
Ghidra work to find memory offsets from scratch. That estimate was made
*before* we knew the game's progression/reward system is entirely
data-driven and sitting in FrostyToolsuite-readable EBX assets. Reassessing:

- **The "what are all the triggers and rewards" catalog — the actual goal
  of Phase 4's memory work — turns out to be mostly a *static data-mining*
  problem, not a *runtime reverse-engineering* problem.** Every reward,
  every condition type, every mission, every flag has a name, a GUID, and
  a structured schema, readable directly in Frosty without touching a
  debugger. That's a huge chunk of Phase 4 effectively short-circuited.
- **What's still genuinely unsolved, and still needs the original
  Phase 3/4 skillset (Cheat Engine → Ghidra → a hooked DLL):** knowing
  *where in live memory* a given flag/condition's current value lives, and
  *when* it changes, so a running client can detect a check and grant
  items in real time. Nothing we've found in Frosty tells you a memory
  address — it tells you the game's *data model*, not its *runtime
  layout*. Those are related (the runtime almost certainly mirrors this
  schema) but not the same thing.
- **New, promising lead that wasn't in the original plan at all:** some
  progression flags sync to an online stats system (`SyncToOnline` +
  `SyncStatName`, e.g. `pf_BronzeCompleted_OWPh4Delivery03`). If that
  turns out to be externally observable (a platform stats API, or a local
  save/cache file written before syncing), that's a route to detecting
  *some* checks without memory reading at all. Currently unconfirmed —
  see §4.
- **Net effect on the timeline:** the "spreadsheet of every trigger" work
  is in much better shape than the original plan assumed — most of it can
  now be built from Frosty exports rather than blind memory scanning. The
  runtime client (the actual DLL that talks to the AP server) is
  unchanged in difficulty — that's still real, still Phase 3/4-shaped
  work, and still the long pole.

**Recommended next move:** stop going asset-by-asset ad hoc in Frosty and
do a systematic export pass over the `GameConfigurations` folder (all 8
assets, see §2) plus a sampling of `Gameplay/Mission`,
`Gameplay/Collectibles`, and `Gameplay/SchematicChannels` — building the
actual locations/items spreadsheet from that — before circling back to
the runtime side.

---

## 2. Game data architecture (confirmed live in Frosty Editor)

### `GameConfigurations` — the full top-level roster (8 assets)
`FontConfiguration`, `PamAchievements`, `PamEntitlements`,
`PamplonaLayerInclusionTable`, `PlayerProgressionData`,
`PlayerTagsDefinitionSettingsMeta`, `RewardsData`,
`RunnerKitDefinitionsMeta`. Small and fully enumerable — this is the
config/data layer.

### `RewardsData` (type `PamRewardsData`)
`PamRewards` — array of 67 `PamReward` (base game); each has:
- `AchievementData` → cross-file reference to a `PamAchievementData`
  entry in `PamAchievements`
- `RunnerKitGuid` → links to a kit in `RunnerKitDefinitionsMeta`
- `RewardConditions` — array of GUID references to separately-typed
  top-level condition instances (confirmed: these are references, not
  inline polymorphic data — see §3)
- `CompareConditionsType` (enum, e.g. `RewardCompareConditionsType_All`),
  `ConditionsCountThreshold`, `NameHash`

Condition subtypes seen (8 total, all subclass `PamRewardCondition`):
`PamProgressionMissionCompletedRewardCondition` (`Missions` array),
`PamProgressionFlagRewardCondition` (`ProgressionFlag` GUID, `Threshold`),
`PamProgressionFlagGroupRewardCondition` (`FlagGroup`),
`PamFlowRewardCondition` (`StayInFlowSeconds`),
`PamMoveSeqRewardCondition` (`RequiredMoves`),
`PamKillAIRewardCondition` (`NumberOfKills`, `AIKillCompareType`),
`PamStatsRewardCondition` (`Stats`, `StatCompareType`, `Threshold`),
`PamNamedChallengeRewardCondition` (`NamedChallenges`).

This is essentially the game's own vocabulary for "locations": mission
completion, a progression flag crossing a threshold, staying in flow for
N seconds, performing a move sequence, AI kills, stat thresholds, or named
challenges.

### `RunnerKitDefinitionsMeta` (type `PamRunnerKitDefinitionsMeta`)
Defines "runner kits" (item/cosmetic bundles): `RunnerKits` (77 entries,
`PamRunnerKitMeta`: `KitGuid`, `KitTypeGuid`, `RewardDescriptionSid`,
`Rewards`), `RunnerKitTypes` (26, `PamRunnerKitTypeMeta`:
`DisplayName`/`DisplayNameSid`, `ObjectVariationGuid`), `InitialRewards`
(16, `PamRunnerKitRewardMeta`: `Name`/Sid, `Hash`). Real kit-type
categories confirmed by name: Basic/Advanced/Elite kit phases,
Preorder Speed/Combat, Beta, Engagement, Re-engagement 1-3.

### `PlayerProgressionData` (type `PamProgressionData`) — the master catalog
Top-level fields: `FlagGroups` (122), `Missions` (152),
`SystemGeneratedFlags`/`MiscCompletionFlags`/`BronzeCompletionFlags`/
`SilverCompletionFlags`/`GoldCompletionFlags` (single flag-group
instances each), `ProgressionFlagLocations` (324 — not yet inspected in
detail, but the name and count strongly suggest this is the collectibles/
location catalog).

**Only 3 instances in this file are independently named/addressable**
(confirmed via Frosty's "View Instances" dialog): the root
`PlayerProgressionData` object, `UI Session Flags`, and
`TutorialCompleted` (both `PamProgressionFlagGroup`). Everything else —
all 152 missions, all 122 flag groups — is an *unnamed array element*,
reachable only by expanding the array and scrolling, not by search or
instance-list. `Missions[8]` (`Encroachment`, a real story mission,
confirmed via cross-reference from `RewardsData` but never actually
opened directly) is somewhere in there unresolved — not worth more effort
chasing that one specific entry.

**Mission schema** (confirmed on real entry `Missions[26]`,
`OWPh4Delivery03`):
- `Id` / `Guid` / `Name` / `NameHash`
- `Flags` — 5 sub-entries per mission: `<Name>_CompletedTimestampPart1`,
  `_CompletedTimestampPart2`, `_Timer`, `_Available`, `_CompletedTime`
- `CompletedFlag` / `AvailableFlag` — direct references into flag entries
  (e.g. `BronzeCompleted_OWPh4Delivery03`, `OWPh4Delivery03_Available`)
- `MissionIndex`, `MissionDescription`, `Reputation`, `Currency`,
  `MissionType` (enum)

Each flag entry itself has: `Id`/`Guid`/`NameHash`, `MissionIndex`,
`Clamp`, `MaxValue`, `Cost`, `Reputation`, `SyncToOnline` (bool),
`SyncStatName`.

**Correction from earlier in this doc's history:** `MissionType` value
`PamProgressionMissionType_Debug` does *not* reliably mean "placeholder
test data" — it shows up on at least one confirmed-real mission
(`AmbPh3Dt03`) as well as the obviously-fake `ExampleMissionN` entries.
Don't use it alone to filter real vs. scaffolding content.

**Confirmed real mission/flag naming conventions** (from both the
`Missions` array and a reassignment-picker dropdown that incidentally
listed several real entries): `OW Opp...` (open-world opportunity
missions), `Dt.../Delivery...` (delivery missions), `AmbPh...` (ambient
phase missions), `Grid Node...` (district/GridNode access triggers).

### `PamAchievements` (type `PamAchievementData` array)
Simple platform-ID mapping: `Id`/`Guid`, `AchievementCode` (`ACH28`,
`ACH40`, ...), `AchievementId` (0-indexed, matches array position
exactly), `TrophyId` (PlayStation), `OriginId` (EA Origin/PC). No
`SyncStatName`/`pf_` references here — achievements are a separate layer
from the mission-flag sync system, not name-linked to it.

### `Gameplay/SchematicChannels/PamMissionManagerChannel` (type `SchematicChannelAsset`)
A different kind of asset entirely — not a data table, an **event/property
bus definition**. 18 `EventChannel` slots (some tagged with a network
`Realm`: `Realm_Server`, `Realm_ClientAndServer`) and 6 `PropertyChannel`
slots (`Realm`, `Id`, `FieldTypeHash`). This is the "schematic channel"
mechanism the original Discord tip referenced — the actual trigger *logic*
(what publishes/reads these channels) isn't visible here; this asset only
declares the named wires. Likely close to the mechanism the "play as
Isabel" mod used to force/block mission state.

### `Gameplay` folder map (from the Data Explorer tree, not yet explored)
`AI`, `CityAlert`, `Collectibles`, `Interactive`, `Logic` (`Csg`,
`Progression`), `Mission`, `Movement`, `Placeholder`, `Progression`,
`RVO`, `SchematicChannels`, `Social`, `Spawners`. `Collectibles` and
`Mission` are the obvious next targets for a full locations catalog;
`SchematicChannels` likely has siblings to `PamMissionManagerChannel` for
other systems (collectibles, dashes, etc.).

---

## 3. Open questions

1. **Is `SyncStatName` (`pf_...`) externally observable?** Unconfirmed.
   Checked `PamAchievements` directly for a name match — none found, so
   achievements aren't the link. External search (SteamDB, SteamHunters)
   was inconclusive — SteamDB's stats page didn't render data, SteamHunters
   blocked the fetch. One real signal: community reports of "Steam
   achievements not working" for this game suggest progress may sync
   through **EA's own backend (Origin)** rather than native Steamworks
   stats, given `PamAchievementData` prominently carries an `OriginId`.
   If true, a public Steam stats API isn't the shortcut it looked like —
   though a local save/cache file written before syncing might still be
   observable. Not pursued further yet.
2. ~~`ProgressionFlagLocations` (324 items) — never opened.~~ **Resolved,
   see "Where to go from here":** it's a field on `PlayerProgressionData`
   (not a separate asset), already exported/parsed, 324 real
   `PamProgressionFlagLocation` entries with `NameHash` + a spatial
   `Transform` reference (the transform itself isn't decoded yet).
3. **`PamRunnerKitMeta.Rewards`** (the EBX-parser-level open item from
   before) — now partially explained by what Frosty showed us: reward/
   condition arrays are GUID reference lists, and multiple kits sharing a
   `RewardDescriptionSid` plausibly share the same underlying reward
   reference. The parser's specific decode of this field is still not
   fixed to resolve properly, but the *shape* of the answer is no longer
   a mystery.
4. **The actual trigger/logic graphs** (what schematic reads which
   channel, what code path flips a mission's `Available`/`Completed` flag)
   — not visible in any Property Grid view we've used. May live in a
   different Frosty view (a node/graph editor, if this asset type or a
   related one has one) that hasn't been checked yet.

---

## 4. The hand-built EBX parser (`ebx_parser.py`)

Built blind against a lossy AI summary of a public reference
([NicknineTheEagle/Frostbite-Scripts](https://github.com/NicknineTheEagle/Frostbite-Scripts),
`frostbite3/ebx.py`) before Frosty access was available, then validated
against three real files (two from derwangler's "Unavailable Echo
Unlocker" mod, one a Frosty export of the base game's `RewardsData`).
Now superseded by live Frosty access for anything Frosty can show
directly — still useful for bulk/scriptable extraction Frosty's GUI isn't
suited to, and as a record of the binary format for anyone without a
Windows box to run Frosty on.

**Confirmed solid:** header layout (fully re-derived from three
arithmetic identities that must hold regardless of file content — see
git history / prior version of this doc for the derivation), keyword
table, field/complex descriptors, class hierarchy reconstruction, common
field types via `type & 0x1F`, four exotic type codes pinned down by
byte-gap analysis (`0x407D`=`Sid` — turned out to be a string-table
offset, not a hash, see §9 — `0xC15D`=`Guid`/16 bytes, `0xC0FD`=`Hash`
(a genuine hash, still unresolved — see §9's closing note), `0xC13D`=
`Float32?` lower-confidence), the GUID-reference decoding in §6, and the
DbObject-as-array mechanism (a 4-byte index into an array-repeater table,
resolving through a small wrapper complex).

**Still open in the parser specifically:** `PamRunnerKitMeta.Rewards`
doesn't resolve as a simple local array index (see §3.3); one array field
hits an EOF edge case; `Enum` fields decode to raw integers, not names;
polymorphic-looking arrays are actually GUID reference lists that the
parser doesn't cross-reference into resolved names yet (Frosty does this
natively).

---

## 5. GameConfigurations export pass — results

You exported all 8 `GameConfigurations` assets from Frosty and I ran them
through the parser (schema + full instance dump each). All 8 completed
cleanly. Instance-type breakdown, which is the actual catalog:

| File | Instances | Breakdown |
|---|---|---|
| `PlayerProgressionData` | 2,653 | 2,376 `PamProgressionFlag`, 152 `PamProgressionMission`, 124 `PamProgressionFlagGroup`, 1 root |
| `RewardsData` | 230 | 67 `PamReward`, 110 `PamProgressionFlagRewardCondition`, 28 `PamProgressionMissionCompletedRewardCondition`, 12 `PamMoveSeqRewardCondition`, 6 `PamProgressionFlagGroupRewardCondition`, 2 `PamNamedChallengeRewardCondition`, 1 each of `PamStatsRewardCondition`/`PamKillAIRewardCondition`/`PamFlowRewardCondition`/`PamEchoCustomizedRewardCondition` |
| `PamAchievements` | 50 | 49 `PamAchievementData`, 1 root |
| `RunnerKitDefinitionsMeta` | 1 (root, with 80 nested arrays) | cosmetic kit unlocks + their reward links |
| `PlayerTagsDefinitionSettingsMeta` | 1 | tag layer definitions — see caveat below |
| `PamplonaLayerInclusionTable` | 3 | 2 `SubWorldInclusionCriterion`, 1 `SubWorldInclusion` — open-world streaming config, not reward-relevant |
| `PamEntitlements` | 1 (7 nested `EntitlementData`) | EA/Origin store licensing (DLC ownership checks) — not reward-relevant |
| `FontConfiguration` | 1 | UI font asset — not reward-relevant |

**This is the real catalog spine.** `PlayerProgressionData`'s 2,376 flags +
152 missions + 124 flag groups, cross-referenced against `RewardsData`'s
230 reward/condition instances (mostly by GUID, per §2/§3), is very close
to a complete list of "every checkable condition and every reward" in the
game's data model — the thing Phase 4's memory work was originally scoped
to reconstruct by hand.

**Naming gap — SOLVED, see §9.** At the time this section was first
written, most identifying fields (`Name`, `EntitlementTag`, etc.) — typed
`Sid` — only showed as a raw hex value (`Sid: 0x0000ae4`), and this was
assumed to be a 32-bit hash needing a reverse dictionary to crack. That
assumption was wrong: `Sid` isn't a hash at all, it's a plain offset into
the file's own embedded string table, and the parser now resolves it
directly — no dictionary, no cracking, no derwangler input needed for this
specific piece. Full writeup and every dump regenerated with real names:
§9.

**`PlayerTagsDefinitionSettingsMeta` caveat:** this file exposed a real
bug, now fixed defensively rather than solved. Its `DefaultTags` field
(inside `PamPlayerTagLayerDataMeta`) decodes as another array pointing
back through the same wrapper complex as its own parent `Layers` array —
almost certainly a wrapper/dispatch case this parser hasn't seen before
(a small, unfamiliar asset type, unlike the others which were all
validated earlier against real samples), not real self-referential game
data. Two safety caps now stop this from hanging or crashing instead of
silently producing garbage: a global cap on total array-resolution work
per file (`MAX_DEFERRED_PATCH_WORKLIST_ITEMS`, `ebx_parser.py`) and a
print-recursion depth cap (`MAX_FORMAT_DEPTH`). When either trips, the
output says so explicitly rather than guessing. `Layers` itself (the
field that actually matters) decodes fine; only nested `DefaultTags`
sub-arrays are truncated. Worth revisiting if tag-based checks turn out
to matter for the APWorld, but not blocking anything else.

Dump files (`*_full.txt`, schema + every instance) and the updated parser
are attached.

---

## 6. GUID-typed fields decoded — real cross-references, not raw hex

This is the biggest structural find since the array-indirection mechanism
in §4, and it came from a lead you found in Frosty, not from staring at
bytes: you exported `UI/Widgets/Map/Progression/Progression_TreeGearContent`
(a `UIWidgetBlueprint`) after we went looking for how the UI actually
displays reward/kit/flag data. Parsing it exposed that every `GUID`-typed
*field* (not the separate 16-byte `0xC15D` exotic literal-GUID type — this
is the base `FieldType.GUID`) in every file we've parsed, including all 8
`GameConfigurations` files, was being **misread as a 16-byte value when
the schema only actually gives it 4 bytes of room.** Confirmed by checking
the gap to the next field in every real sample: it's always exactly 4,
never 16. The old code blindly read 16 bytes anyway, silently smearing
into whatever came next — this is why `PamAchievements.Achievements`
previously hard-crashed with an EOF error, and why fields like
`PamProgressionMission.CompletedFlag` printed garbage-looking 16-byte
blobs instead of anything meaningful.

The real 4-byte value is a `uint32` with one of two meanings, both now
decoded automatically:

- **Top bit set (`0x80000000`)** → the low 31 bits are an index into the
  file's own `externalGUIDs` table (the cross-file reference list every
  EBX file already carries — `numGUID` in the header). The table's second
  GUID of each pair is the actual instance being referenced, in another
  file. Verified byte-for-byte: `Progression_TreeGearContent`'s
  `PamProgressionFlagInfoEntityData.FlagGroup`/`.Flag` fields resolve
  through this exact mechanism to real `PamProgressionFlagGroup`/
  `PamProgressionFlag` instances that exist in `PlayerProgressionData.bin`
  — i.e. we can now see exactly which flags a given UI screen displays.
- **No top bit** → the raw value is a plain index into *this same file's*
  own instance list, in file-declaration order. Verified the same way:
  `PamProgressionMission.CompletedFlag`/`.AvailableFlag` in
  `PlayerProgressionData.bin` resolve to the exact `PamProgressionFlag`
  instance representing that flag.
- `0xFFFFFFFF` is the existing "unset/null" sentinel, unchanged.

The parser now resolves both cases automatically and prints something
readable (`<external ref: instance=... in file=...>` or `<local ref:
TypeName guid=...>`) instead of raw hex, both for direct `GUID` fields and
for `GUID`-member arrays (which is what was crashing `PamAchievements`).
Re-ran the full 8-file batch plus the widget file after the fix: every
file still completes cleanly, and the "can't make sense of this value"
fallback case dropped to zero everywhere except a small number (≤21 in the
biggest file) of genuinely out-of-range indices — plausibly a different,
not-yet-identified sentinel convention, not a parser bug, and small enough
not to block anything.

**Why this matters more than it might sound:** we can now walk real,
verified structural links — mission → its completed/available flag,
flag → its flag group, a UI screen → the specific flags/kits it
displays — entirely through GUIDs, without needing the `Sid` text-hash
problem solved at all. That problem (turning a hash into the *display
string* a player would recognize) is still open and still needs
derwangler or a wordlist. But "which reward unlocks when which flag
group hits which value" — the actual dependency graph the APWorld's
logic needs — no longer depends on it.

**Still open, not touched by this fix:** `RunnerKitDefinitionsMeta.Rewards`
(a `DbObject`/array field, different mechanism entirely) still fails to
resolve with an out-of-range repeater index — unrelated to today's GUID
fix, still an unsolved dispatch case.

---

## 7. Collectibles — the type-level templates confirm the same wiring

Exported the 17 top-level items in `Gameplay/Collectibles` (the `Instances`
subfolder with the individually-placed pickups is deliberately deferred —
see "Where to go from here"). All 17 parsed cleanly. Most of the
`pf_collectibleitem_*` prefabs (aline, catkruger, connors, dogennanda,
omnistatgold, rebeccaspath, traveldiary, wanderbornfairchild — the "green"
echo/audio-log-style collectibles) share an identical shape: a
`SpatialPrefabBlueprint` containing a `PamProgressionFlagEntityData` with
`.FlagGroup`/`.Flag` fields.

Those resolve exactly like §6 predicted — traced one all the way through:
`pf_collectibleitem_greenaline`'s flag entity resolves to a real
`PamProgressionFlagGroup` and `PamProgressionFlag` in `PlayerProgressionData`,
and that same flag is independently referenced elsewhere as a mission's
`AvailableFlag`. So the chain is fully verified end to end: **pick up this
specific collectible → sets this specific flag → flag belongs to this flag
group → flag also feeds this mission's availability.** That's the real
location→item dependency link the APWorld needs, for an entire category of
collectibles, confirmed by cross-reference rather than assumed by pattern.

The other entries are a mixed bag, worth knowing about but not all
equally useful: `PF_CompulsionOrb` and `PF_MetaGridOrb` are heavier
(schematic channels, timelines, curves — animated/interactive collectible
behavior, not just a flag-set); `PF_L_CombatDrops` and
`PF_L_MetaGridLogic` are logic-only prefabs (no spatial placement,
`PamProgressionFlagEntityData` present but framed around combat-drop/
metagrid systems rather than a single pickup); `PF_LairPhotoLocation` has
no `PamProgressionFlagEntityData` at all, just a `PamAreaTriggerData` +
`SphereData` (a trigger volume, not a flag-setting pickup) — a different
mechanism worth a closer look later if lair photos matter for the
APWorld.

---

## 8. Missions — test case says this is NOT a quick win like collectibles

Exported two files from `Gameplay/Mission/Birdman` as a test case:
`PF_L_2PigeonsRVPuzzle02` (a puzzle/logic prefab) and `PF_SC_BirdmanDelivery`
(a schematic-wrapper prefab). Both parsed cleanly. Neither contains anything
resembling `PamProgressionFlagEntityData`, `PamReward`, or
`PamProgressionMission` — no direct "this sets that flag" field the way
every collectible template had.

What's actually in them is generic Frostbite visual-scripting plumbing:

- `PF_SC_BirdmanDelivery`: an `InterfaceDescriptorData` (4 input/output
  event slots, all but one still unnamed `Hash: 0x00000000`) and one
  `SchematicChannelEntityData`. That channel's `.Channel` field is a GUID
  that — for the first time — resolved to a genuine **external, cross-file**
  reference: `instance=85130b02a877ff76918fef6727744f0b in
  file=44a9c71c2494e511a0e5ea0cfaaf6c53`. That file GUID doesn't match
  anything exported so far, but it's almost certainly the companion
  `SC_BirdmanDelivery` schematic asset (visible right next to the `PF_`
  prefab in the Frosty folder) — i.e., the `PF_SC_*` wrapper is just a
  pointer into the *actual* schematic graph, which lives in a separate
  file we haven't pulled yet.
- `PF_L_2PigeonsRVPuzzle02`: three `BoolEntityData` (plain flag-like state
  containers, local to this prefab, not `PamProgressionFlag`), an
  `EventGateEntityData`, a `PamAreaTriggerData` (a trigger volume, same
  shape as `PF_LairPhotoLocation` from §7), and an `InterfaceDescriptorData`
  whose event/link IDs are opaque hashes (`0x71037846`, `0x1de1bd91`, ...) —
  meaningful only once wired up to whatever schematic graph consumes them.

**Conclusion:** unlike collectibles, individual mission logic isn't a
self-contained field to read off — it's assembled at runtime from a web of
hash-keyed event/link connections plus separate schematic-graph files this
export pass hasn't reached. Chasing this properly would mean exporting the
`SC_*`/schematic-graph asset alongside every `PF_SC_*`/`PF_L_*` per mission
(more files per mission, and still not guaranteed to bottom out in readable
flag names — schematic node graphs are visual, not textual, and Frosty's
export doesn't include the graph layout, only the data container). That's
a materially bigger and murkier effort than the collectibles pass was.

**Recommendation:** treat mission-folder exports like `Collectibles/Instances`
in §7 — deliberately deferred, not abandoned. The progression-flag graph
already reachable from `PlayerProgressionData`/`RewardsData`/collectibles
(§6, §7) is enough to describe *what* flags exist and *what* they unlock;
it just doesn't yet say *which specific mission action* flips each one.
That's a "nice to have" precision layer, not a blocker for drafting the
APWorld's location/item structure.

---

## 9. **MAJOR BREAKTHROUGH — Sid fields were never hashed at all**

This completely resolves the naming gap called out in §5 and §3 — and it
turned out to have nothing to do with hashing, djb2, or wordlists.

A modder in the Discord replied to your post confirming the algorithm is
djb2, but also said no public wordlist exists for it. That prompted a
closer look at the actual `Sid`-typed values already sitting in every dump
we'd generated — and something jumped out: they weren't distributed like
hash output at all. Pulled every `.Name` value off `PamProgressionFlag` in
`PlayerProgressionData` (2,500 of them) and instead of the near-random
32-bit spread a real hash produces, they were small, unique, and rising in
lockstep with instance order — `0x43, 0x61, 0x174, 0x192, 0x1c7, ...` up to
about `0x2259b`. That's not a hash distribution, that's an **offset table**.

Every EBX file already carries a literal string-value section (that's how
`CString` fields like file paths resolve — `absStringOffset + a 4-byte
offset`, already implemented in the parser). Tested the theory directly:
read the bytes at `absStringOffset + 0x43` in `PlayerProgressionData.bin`.
Got back `SecurityCameras_Dt78Destroyed` — a real flag name, in plain
ASCII, sitting right there in the file. Every other value tested the same
way: `OW Opp AncPh5 04_Timer`, `Vive La Resistance
Debriefing_CompletedTimestampPart1`, `Sanctuary_Timer`, and so on. Cross-
checked against the very first example hash I'd handed you weeks ago
(`PamAchievements.AchievementCode = 0x00000023`) — same mechanism, same
file's string section, offset `0x23` — and it reads back `ACH04`. Exactly
the "ACH_something" pattern I'd guessed at blind, for exactly the reason
it's now obvious: it was never a hash to crack.

**So `Sid` isn't a hashed string id at all — it's a plain `int32` byte
offset into the file's own embedded string table, decoded exactly like
`CString` (`-1`/`0xFFFFFFFF` = null).** No cracking, no dictionary, no
djb2 needed for this field type. Fixed in `ebx_parser.py` (`read_field`'s
Sid branch and the array-member equivalent) and reran the entire export
set through the corrected parser — every dump now shows real names
directly: flag names, mission-related strings, achievement codes, reward
tags, everywhere `Sid` appears. This was, in hindsight, entirely a gap in
*our own parser* (it had `Sid` filed under "exotic hash-looking type,
print as hex") rather than an actual cryptographic problem — Frosty was
never doing anything exotic to show these names live; it was just reading
the same string section correctly the whole time.

**What this unblocks:** every `Name`/`AchievementCode`/`EntitlementTag`/
similar field across every file we've already exported is now human-
readable with zero extra work — just rerun the corrected parser over the
existing `.bin` exports (already done for everything currently in the
project folder). This was the single biggest remaining gap between "we
understand the structure" and "we have a readable design doc," and it's
now closed for any file we can export from Frosty.

**What's still a genuine hash, separately:** the `Hash`-typed fields used
in schematic/event-bus wiring (`PropertyConnection.SourceFieldId`/
`TargetFieldId`, `EventConnection.SourceEvent`/`TargetEvent`,
`DynamicEvent.Id`, `DynamicLink.Id` — seen in §8's mission files) are
*not* string-table offsets — tested the same offset trick against them and
it doesn't land on readable text, and their values (`0x71037846`,
`0x1de1bd91`, ...) don't shrink into a small per-file range the way `Sid`
did. These are much more likely to be real hashes of a **small, fixed
vocabulary of engine-internal property/event names** (schematic node pin
names, not per-instance content) — which is probably what the modder's
djb2 tip is actually about. Tried a short list of obvious candidates
("Enable", "Trigger", "OnComplete", ...) through both the schema's known
FNV-1 variant and classic djb2/djb2a — no hits yet, but the corpus here is
small and finite (a few hundred fixed names across the whole engine, not
one per instance), so it's a much more tractable side-quest than the old
"crack every Sid" framing was. Low priority now that it no longer blocks
readable names for anything else.

### 9a. Follow-on fix — `FileRef` fields were hiding two more things

While double-checking what else might be quietly mis-decoded the same way
`Sid` was, found and fixed two more cases, both under the generic
`FileRef` type tag (which used to always print as a raw, usually
meaningless 8-byte hex value):

- **Enum references.** A `FileRef` field whose declared target class
  (`fd.ref`) is made entirely of `Void`-typed members is this format's
  way of encoding an enum — each member's byte *offset* is the enum's
  integer value, and its *name* is the label. `.Realm` used to print as
  garbage like `'0x8000000000000002'`; it now resolves to
  `Realm.Realm_ClientAndServer`. This fixes every enum-like field across
  every dump: `Realm`, `StreamRealm`, `RadiosityTypeOverride`,
  `TimeDeltaType`, `AreaTriggerInclude`, `TeamId`, `SubRealm`,
  `MissionType`, `FieldAccessType`, `EventConnectionTargetType`, and more.
  Caveat: a handful of instances of two fields specifically
  (`LanguageFormat` on `FontConfiguration`, `EntitlementType` on
  `PamEntitlements`) hit values with no matching member in the listed
  enum and print as `ClassName(unresolved=N)` instead of guessing — safe
  (never silently wrong), just incomplete for those two fields.
- **Genuinely nested complexes.** A `FileRef` field whose byte-gap to the
  next field matches its target class's declared size is actually a
  real, data-bearing struct embedded inline — not a reference at all.
  Confirmed on `PamProgressionMission.MissionDescription` (declared
  `FileRef`, gap to the next field is exactly 40 bytes, matching
  `PamMissionDescription`'s size): it now decodes to real fields
  including `ActiveNameSid = 'ID_OPP_DIV_PH5_01_LABEL'`,
  `AcceptLabelSid = 'ID_OPP_TAKE_DIVERSION'`,
  `MissionTextureId = 'mapObjectives_diversion'` — **localization key
  IDs for every mission's actual display name/description/UI text**,
  not just internal flag identifiers.

**New lead this opened up — tested, no hit yet.** Pulled every `ID_...`
string visible across all current dumps (412 unique candidates — a much
better source than any previous guess, since these are the real internal
keys, not inferred text) and hashed each one (original case, lowercased,
uppercased) against `list.csv`'s hash column with five algorithms (djb2,
djb2a, FNV-1, FNV-1a, CRC32). Zero matches. So either `list.csv`'s hash
space still isn't the same one these `ID_...` keys resolve through, or
the exact djb2 variant/seed is still off. Not pursuing further for now —
low priority, same as the `Hash`-field mystery above — but the candidate
list itself (412 real `ID_...` keys) is saved and reusable if a better
algorithm lead turns up.

All dumps in the project folder were regenerated with both fixes applied
(same pass as §9's `Sid` fix).

---

## 10. **Runtime memory layout — Phase 3/4 substantially de-risked**

A modder in the Discord shared `SDK.zip`: a full C++ header dump of the
game's live class layouts, generated by a tool ("FrostbiteGen") that reads
the game's own RTTI/reflection metadata out of the running process. It's
not scoped to progression data — it's thousands of headers, one per class,
covering what looks like the entire game (`SDK/` has 2,000+ files just in
an alphabetically-truncated listing). They pointed at three specifically
(`PamProgressionData.h`, `PamProgressionFlagGroup.h`,
`PamProgressionSettings.h`) and gave a worked example: the
`PamProgressionSettings` singleton pointer lives at a fixed address
(`Module base + 0x257cb98`), and its `PlayerProgressionData` field at
`+0x20` gives the actual `PamProgressionData*` — i.e. exactly the object
`PlayerProgressionData.bin` (§2) represents, but live in memory.

**Cross-validated against everything we already knew from Frosty/EBX —
and it matches almost field-for-field.** `PamProgressionData`'s own
`Offsets` struct: `FlagGroups=0x18`, `Missions=0x20`,
`SystemGeneratedFlags=0x28`, ... `ProgressionFlagLocations=0x50` — the
exact same field order our hand-built parser inferred from the EBX schema
in §2. Same story for `PamProgressionFlag` (`Name`, `MaxValue`, `Cost`,
`Reputation`, `SyncStatName`, `Clamp`, `SyncToOnline`) and
`PamProgressionMission` (`CompletedFlag`/`AvailableFlag` as direct
pointers to `PamProgressionFlag` objects, `MissionDescription` embedded
**inline** — independently confirming §9a's "FileRef that's actually a
nested struct" fix was the right call, since the live memory layout does
exactly that too). This is a strong, independent confirmation that both
the EBX parser's field-order inference and the §9/§9a fixes are correct,
from a completely different source (live RTTI) than everything else in
this doc (static on-disk EBX assets).

**What's confirmed and usable right now:**
- The address chain: `Module base + 0x257cb98` → read 8 bytes →
  `PamProgressionSettings*` → `+0x20` → `PamProgressionData*` (the live
  master catalog). A second, independent route exists too
  (`PamProgressionData::GetInstance()`'s own cached global pointer at
  `Module + 0x2873620`) — both should resolve to the same object.
- `Array<T>` layout (from `FBSDKTypes.h`): four 8-byte pointers
  (`firstElement, lastElement, arrayBound, allocator`); element count =
  `(lastElement - firstElement) / sizeof(T)`; `Array<T*>` (flag groups,
  missions, flags) holds pointers to walk, `Array<T>` (flag locations)
  holds inline structs to read directly.
- **Names resolve to real live `const char*` strings** — at runtime, `Sid`
  fields aren't the on-disk string-table-offset encoding from §9 at all;
  they're already-resolved pointers to live C strings. So a runtime
  client wouldn't even need §9's fix — it gets names for free, a
  different way, confirming §9's fix was solving the right problem for
  the right (on-disk) context.
- **What's still an open question:** none of the classes in this SDK dump
  expose a "current value" / "is this flag set for my active save" field
  — only the static config (matches §2's schema exactly: `Name`,
  `MaxValue`, `Cost`, ...). The actual per-save progress state almost
  certainly lives in a separate save/stats system this dump hasn't been
  pointed at yet. That's the next thing to ask about in the Discord, or
  hunt for directly (classic Cheat Engine technique: snapshot memory,
  trigger one specific flag in-game — e.g. destroy one security camera —
  snapshot again, diff).

**Delivered: `dump_progression_state.py`**, a ready-to-run, dependency-free
(stdlib `ctypes` only) Python script that walks this exact chain on a live
game process and writes a JSON snapshot of every flag group, flag,
mission, and flag location — by name, live, no Frosty export needed. Run
it on Windows with the game running and 64-bit Python 3:

```
python dump_progression_state.py --process MirrorsEdgeCatalyst --out progression_snapshot.json
```

If it can't find the process, pass the exact exe name from Task Manager.
If every read comes back empty/None (but the process and module resolve
fine), try running the terminal as Administrator — some anti-tamper setups
require the reader process to be elevated too. This is unverified against
the real running game (I don't have a Windows box to test it on) — first
real run is the actual test. Share the output (or any error) back here and
I'll fix whatever's off; a working run also confirms whether the
`GetInstance()` slot address stays stable across the game's patches/builds
or needs re-finding per-version.

**Net effect on the original plan (§1):** this substantially de-risks the
part of Phase 3/4 that was the real unknown — *finding* the memory
addresses in the first place, normally weeks of Cheat Engine/ReClass/Ghidra
work. That's now handed to us, generated straight from the game's own
reflection data. What's left of Phase 3/4: confirm the address chain holds
up on a real run, find the live save-state field(s) noted above, and then
build the actual watcher/DLL that detects state changes in real time for
the AP client to react to — still real work, but starting from a known
memory map instead of from nothing.

### 10a. First real run — address chain confirmed, array walker fixed

Ran `dump_progression_state.py` against the live game. Big result: **the
whole address chain and every struct offset checked out** — real flag
group names (`Global`, `SecurityHubs`, `Collectables`, ...), real flag
names read straight out of live memory (`Global_IsPlayingOppMission`,
`Global_CityUnlockState`, `syncStatName: "pf_Global_CityUnlockState"`, ...),
matching the naming patterns predicted back in §2 exactly. The SDK dump's
offsets are correct.

But the output was 210MB and 95 of 123 flag groups came back with exactly
5000 flags each (a suspiciously round number) — clearly wrong; the real
on-disk catalog only has ~2,500 flags total. Diagnosed it directly against
the captured data: each `Array<PamProgressionFlagGroup>`'s own `Flags`
field walk was correct for the first few dozen-to-couple-hundred entries
(genuine flag objects, real names, in sensible order), then ran off the
true end of the array into unrelated heap memory that still happened to
contain plausible-looking pointers for a while, eventually degrading into
raw ASCII string fragments misread as addresses. Root cause: the
`(lastElement - firstElement) / sizeof(T)` count computed from the
generic `Array<T>` struct (`FBSDKTypes.h`'s `{first, last, bound,
allocator}` guess) isn't reliable as a hard count for every array field —
plausible explanations include the real container not being a simple
contiguous vector for every field, or the generic template not exactly
matching this specific field's true layout. The *outer* `FlagGroups`
array (123 entries, matching the known ~122-124 from §2) was fine —
it's specifically the *inner* per-group `Flags` arrays that overran.

**Fix, not yet re-tested:** stopped trusting the precomputed count as
ground truth. The walker now reads element-by-element and treats each
pointer as suspect until proven otherwise — canonical address-space range,
an actual successful memory read at that address, and (for flags
specifically) a real name or name-hash once dereferenced — tolerating an
occasional single bad/empty slot (real data showed isolated holes
without the rest of the array being garbage) but stopping for good after
25 consecutive bad reads. Simulated against the captured bad run's own
data as a sanity check: the `Global` group would go from 5000 recorded
entries down to ~215 real-looking ones with this logic, which lines up
with what a hand-skim of the early entries suggested was real.

### 10b. Second run — smaller number, still wrong; found the actual bug

Reran with 10a's fix. Output shrank from 210MB to 56MB (progress), but
still wildly too big: 143,164 total flags across groups that now mostly
sat around 2,400-2,700 each, including groups with no business being
that large (`TimeOfDay`, `CharacterState`, `Generated`). The tell: these
counts are much more *uniform* and *coherent* than random garbage would
produce -- meaning the walker wasn't reading unmapped/nonsense memory
anymore (10a fixed that), it was reading real, valid, live
`PamProgressionFlag` objects the whole time -- just the *wrong* ones,
walked in from neighboring memory once past each group's true (much
shorter) list. A pointer that resolves to a real object of the expected
type sails through every validity check 10a added, since those checks
have no way to know the object belongs to a *different* group.

Root cause, found by re-reading the SDK headers' own byte gaps rather
than patching symptoms again: every single `Array<T>`-typed field --
`PamProgressionFlagGroup::Flags`, `PamProgressionData::FlagGroups`,
`PamProgressionData::Missions`, `PamRewardsData::PamRewards`, `RunnerKits`,
`ProgressionFlagLocations`, all of them -- sits exactly 8 bytes from the
next field, everywhere it was checked. `FBSDKTypes.h`'s `Array<T>` C++
declaration (`{firstElement, lastElement, arrayBound, allocator}`, 4
pointers = 32 bytes) cannot fit in that 8-byte gap. So the field itself
is a single 8-byte **pointer to** the real array data/header, not that
32-byte struct sitting inline at the field's own address. Both run #1 and
run #2 read the 32-byte header directly at the field's address without
that extra dereference -- silently pulling in the *next one-to-three
sibling fields'* raw pointer values as a fake last/bound/allocator, which
is exactly consistent with everything observed in both bad runs.

**Fix:** the array walker now dereferences the field once to get a
pointer `x`, then tries two hypotheses in order, each checked against
whether element 0 actually looks like a real object of the expected type:
(A) `x` points to an out-of-line `{first,last,bound,allocator}` header
elsewhere on the heap; (B) `x` *is* the first element's address directly,
with no separate header to bound the walk (falls back entirely on the
stop-on-garbage logic from 10a). Every array walk now also prints which
hypothesis it used and the raw addresses involved, and the whole console
transcript is automatically saved next to the JSON output (`*_log.txt`)
so a still-wrong run is debuggable from what's already been captured
rather than needing yet another back-and-forth. Script redelivered
(again) -- next step is simply running it once more.

---

### 10c. Third run — worse than run #1, and a fundamental rethink of the approach

Reran with 10b's fix. Output got WORSE, not better: 329MB, 400 "flag
groups" (many with garbled hex-address fallback names like `0xbf7ee19a`)
instead of the real 124, `2759` "missions" instead of the real 152, and
`ProgressionFlagLocations` hit a hard 20,000-item safety cap instead of the
real 324. The saved `*_log.txt` (added in 10b specifically so a bad run
would be diagnosable without another round trip) made the actual
mechanism clear this time: the *outer* `FlagGroups` walk fell back to
hypothesis B ("field IS first element", no out-of-line header found) --
which is a perfectly legitimate outcome of 10b's own two-hypothesis logic,
just the less-constrained one, so with nothing to bound it structurally it
free-walked through the shared object pool until the stop-on-garbage
tolerance happened to trip, 400 objects later. Smoking gun that this is a
structural dead end, not a smaller bug to patch: one `mode=A(bounded)`
"validated" result in the log (`GridNodes`) had **`bound` (0x2a376340)
LESS THAN `last` (0x2a38e0f8)** -- semantically impossible for a real
capacity field, proving that even when a candidate passes every plausibility
check available, the underlying 4-pointer-struct guess can still be wrong.

**The actual conclusion, not just another patch:** the game appears to
allocate every object of a given type (every `PamProgressionFlag`, every
`PamProgressionFlagGroup`, ...) from one shared, contiguous memory pool.
Once a walk drifts even one element past the true end of "its" array, it
keeps finding REAL, VALID, correctly-shaped objects of the same type --
they just belong to a different group. No amount of "does this pointer
look sane / does this object look well-formed" checking can ever tell
those apart, because they genuinely are well-formed objects. Three runs,
three different symptoms, same root cause: **the walker had nothing
independent to check candidates against.**

**The fix: stop guessing the raw pointer layout further, and use the
already-fully-solved static side as the live walk's ground truth.**
`PlayerProgressionData.bin` was fully reverse engineered back in sec 5 --
we already know, with certainty, the real count and the real name of
every flag group (124), flag (2,376), mission (152), and flag location
(324) in the game. A new script, `extract_ground_truth.py`, uses
`ebx_parser.py`'s already-working structured object model (not text
regex) to pull that list straight out of the `.bin` file into
`ground_truth.json`. `dump_progression_state.py` now loads that file at
startup and uses it as the live walk's oracle instead of pointer
plausibility:

- Every array is now hard-capped at its **known real count** (124 groups,
  152 missions, 324 locations, 2,376 flags total) -- it is structurally
  impossible for this version to report 400 groups or 2,759 missions,
  because it will never accept more matches than there are real objects
  to match.
- Each *candidate* element is validated by reading its live `Name` (flags,
  groups) or `MissionIndex` (missions) or `NameHash` (locations) and
  checking it against the real, known set from `ground_truth.json` --
  and each match is removed from that set once used, so a second live
  object claiming to be the same real flag/group (e.g. a neighbor-pool
  object that happens to pass a weaker check) is rejected as already
  spoken for. This is the piece pointer-validity checking could never
  provide: two DIFFERENT pointers can both look like "a real
  PamProgressionFlag", but only one of them can be *the* flag named
  `SecurityCameras_Dt78Destroyed` -- ground truth is what tells them apart.
- 104 of the 124 flag groups additionally get a *known per-group flag
  count* (pulled from the group's own `.Flags` field in the static file,
  when it resolved -- see sec 4/5's caveat about that field being
  partially unreliable on the static side too) -- for those groups the
  walk stops at the exact right length rather than a shared global
  budget, closing off the specific "one group's walk drifts into the very
  next group's real flags" failure from 10b. The other ~20 groups fall
  back to the shared global remaining-flags budget, which is still a real
  hard ceiling, just a looser one.

Verified this actually works with a standalone regression test
(`test_walk_oracle.py`, stdlib-only, runs on Linux/Mac without the game or
Windows) that builds a miniature simulated memory layout reproducing the
exact 10b/10c failure shape -- two arrays of real, well-formed objects
sitting back-to-back with *no gap* between them -- and asserts the new
walker stops each array at its own known boundary instead of reading into
its neighbor. Passes.

**What this does NOT fix on its own:** it can't invent data ground truth
doesn't have. If the live walk still can't locate a group/flag/mission at
all (bad starting address, object doesn't exist this session, whatever),
it'll simply report fewer matches than the known total and say so
explicitly (`"NOTE: N known real group(s) were never found in memory"`) --
which is itself useful diagnostic signal, unlike a plausible-looking wrong
number. Also doesn't change anything about the still-open "where's the
CURRENT/live value, not just the static config" question from sec 10 --
that's still next once this array-walking problem is confirmed solved for
real.

Files delivered: `dump_progression_state.py` (rewritten array walker +
`GroundTruth` class), `extract_ground_truth.py` (run once against the
static `.bin`, already run here to produce the next file),
`ground_truth.json` (the actual reference data, ships alongside the
script — regenerate with `extract_ground_truth.py` if `PlayerProgressionData.bin`
is ever re-exported), `test_walk_oracle.py` (regression test, optional to
run but there if this needs debugging again). Next step: run
`dump_progression_state.py` again with `ground_truth.json` sitting next to
it in the same folder.

---

### 10d. Fourth run — the array-walking problem is solved

Reran with 10c's ground-truth-oracle fix. Output dropped from 329MB to
**736KB** — a three-orders-of-magnitude sanity check all on its own — and
every number now lines up with the known-real totals instead of being a
multiple of them:

| | live result | known real total |
|---|---|---|
| Missions | **152/152** | 152 |
| ProgressionFlagLocations | **324/324** | 324 |
| Flag groups | **122/124** | 124 |
| Flags (in matched groups) | 1,506/2,376 | 2,376 |

Missions and locations matched perfectly. Ran a battery of independent
sanity checks against the snapshot (not just trusting the totals):

- **Zero garbage names.** Every single one of the 1,506 live-read flag
  names is a real name from the static catalog — none of the
  hex-address/garbled fallback names seen in run #3.
- **Zero count mismatches.** For every one of the 122 matched groups that
  has a known real per-group flag count (from the static side), the live
  walk read exactly that many — not one more, not one fewer.
- **Zero duplicate flags.** All 1,506 flag names across the entire
  snapshot are unique — no flag got double-counted into two groups, which
  is exactly the failure mode 10b/10c exist to prevent.
- **Name/group coherence.** 103/103 non-empty groups have at least half
  their flags sharing a recognizable name prefix with their own group
  (e.g. `Global` → `Global_IsPlayingOppMission`, `SecurityCameras` →
  `SecurityCameras_Dt18Destroyed`) — strong independent evidence the
  live walker is pairing flags with their *actual* owning group, not a
  neighbor.

**The 870 unmatched flags and 2 unmatched groups (`TutorialCompleted`,
`UI Session Flags`) are not a new live-memory bug** — cross-referencing
against `ground_truth.json` shows the unmatched flags belong almost
exactly (1,506 vs. an expected ~1,508) to the same ~20 groups whose
static `.Flags` field never resolved back in sec 5's original GameConfig
pass (the pre-existing, already-documented DbObject dispatch limitation).
The live log even shows the tell directly: those groups' `Flags` field in
memory resolves to the exact same address (`0x2a39af88`) every time,
strongly suggesting a shared "empty array" sentinel the engine points
every genuinely-empty `Array<T>` at — i.e. this looks like the same real
data-shape quirk showing up consistently on both the static and live side,
not two independent bugs. The 2 unmatched groups are plausible session-
state artifacts (e.g. `TutorialCompleted` not existing as a live object
once tutorials are actually completed). Worth a closer look eventually,
but low priority relative to everything else queued.

**Conclusion: the live-memory address chain, the `Array<T>` pointer
mechanism, and the array-boundary problem that broke three prior runs are
all now confirmed solved**, cross-validated against the fully-solved
static catalog rather than trusted on pointer plausibility alone. Next
open runtime question, per sec 10's original framing: **where does the
game track the live "is this flag set / what's its current value" state**
— none of the classes read here expose that, only static config. Next
step for that: run the script once, trigger one specific flag in-game
(e.g. destroy a known SecurityCamera or pick up a known collectible),
diff two snapshots around that flag's known live address, and see if
anything changes nearby; if nothing does, the value lives in a separate
save/stats system this SDK dump doesn't cover.

**That test has now been run, twice, and the result is a clean negative
— which is itself useful.** Wrote two follow-on tools:
`raw_dump_flags.py` (hex-dumps a 128-byte window starting at every one of
the 2,376 real flag objects, not just the named fields) and
`dump_region.py` (hex-dumps the ENTIRE ~260KB memory region all the
PamProgressionFlag/FlagGroup/Mission objects were actually found living
in, page by page). Ran both as a before/after pair around two separate
real collection events (an audio recording, then a document, both in
Triumvirate Drive) — **zero bytes changed, anywhere, either time**, across
every field of every flag AND across the entire surrounding memory pool.

This rules out something concrete: whatever tracks "have I picked this up
for my save" is not stored inline in `PamProgressionFlag`/
`PamProgressionFlagGroup` beyond what the SDK headers already name, and it
is not stored anywhere else in the same allocation pool those objects live
in either. Combined with `PamProgressionFlagGroup`'s own
`NumberOfFlagsSyncStatName`/`SumOfFlagValuesSyncStatName` fields (which
are just STRING NAMES of stats, not the values themselves), the working
theory is that the actual live value is tracked by a separate stats/
telemetry subsystem, addressed by name/hash rather than sitting next to
the config data. Found one suggestive class in the SDK dump,
`AbstractPersistentStatRef`, plus `ClientAchievementService` /
`ClientStatisticsService` (both reachable from `ClientGameContext`) — but
all three are singleton/VTable shells in the SDK dump with no member
`Offsets` struct, so they don't tell us where inside them a per-stat value
would actually live.

**Next step, pivoting approach:** rather than keep guessing more regions
in Python, use Cheat Engine's own built-in "Unknown initial value" →
"Changed value" scan workflow across the *entire* process — it's
purpose-built for exactly this hunt and far faster than reading
megabytes at a time over `ReadProcessMemory` from a script. Attach to
the game, First Scan with Scan Type "Unknown initial value", collect one
item, Next Scan with Scan Type "Changed value", then (ideally) do a round
of "Unchanged value" between collections to prune out unrelated constantly-
changing engine state (timers, animation, audio) before collecting again —
each additional round should shrink the candidate list sharply. Whatever
addresses survive that process are worth handing back for interpretation.

### 10e. Cheat Engine finds a real live table -- narrowed to 1 confirmed address, structure still open

You did exactly that and narrowed a "gridleaks" scan down to 6 addresses.
Wrote two follow-on tools to interpret them: `read_addresses.py` (dumps
each address under every plausible numeric type) and `read_addresses_v2.py`
(wider window, follows anything that looks like a pointer one level deep).

Address `0x1dae1750` is the real one. Its bytes decode as a repeating
table of 8-byte integers that includes, verbatim, four of our
independently-known real GridLeaks totals: **83 (Anchor), 80 (TheView),
87 (Downtown), 74 (Construction)**. Not a coincidence -- this table is a
genuine live mirror of the GridLeaks static config. Better still, its
very first byte **incremented from 184 to 185** after you collected one
item -- a live "something changed" / generation counter, the first
confirmed-live single-byte state change found all session.

New data point this got us: **OmniStat Tunnels' real GridLeaks total is
24** (matched a value already sitting in the table, confirmed by you
independently reporting "16/24" after checking in-game). That resolves
one of the two districts our static `.Flags`-field parsing could never
pin down (`TheShardGridLeaks` or `TrainstationGridLeaks`, whichever
internal name OmniStat Tunnels maps to) -- worth writing back into the
static side once confirmed which of the two it is.

**Open question, not yet resolved:** the exact table LAYOUT. Values
sitting next to each known total (46 next to Anchor's 83, 68 next to
Downtown's 87, 47 next to Construction's 74) look exactly like plausible
"progress" counters, but OmniStat's independently-known live progress
(16) does NOT appear anywhere in this same table -- so those neighbor
values can't yet be confirmed as real per-district progress; they might
be an unrelated stat that happens to be smaller. Also surfaced a second,
apparently SEPARATE system: an in-game "collectible board" screen listing
10 real zone names (Development Zone, OmniStat Tunnels, Triumvirate
Drive, Shimmering Heights, Crystal Valley, Concord Plaza, Eden Village,
Centurian Yards, Ocean Pier, Regetta Bay) with their own (current/total)
counts, and a **grand total of 185/324 collected** -- 324 being an EXACT
match for `ProgressionFlagLocations`' fully-verified real count. That's
strong confirmation the "collectible board" is the live view of the
already-fully-solved `ProgressionFlagLocations` system (all collectible
categories combined per zone, not GridLeaks specifically) -- but the
per-zone sums computed by adding up the matching `Intel*`/`SecretBag*`/
`AudioPickup*`/`ElectronicParts*` static group counts for a given
sub-zone code did NOT match the real reported numbers (e.g. Concord
Plaza: computed 28 vs. real 15) -- most likely the same pre-existing
DbObject partial-resolution unreliability (sec 4/5) contaminating some of
those specific group member lists with the wrong flags, not a new bug.

**Best next concrete step:** rather than keep decoding this table's shape
byte-by-byte, use Cheat Engine's much more surgical **"Exact Value"**
scan on the *global* "collectible board" total (currently 185) -- First
Scan value=185 (4-byte or 8-byte int), collect literally anything, Next
Scan value=186. That total changes on every single pickup regardless of
category/zone, so it converges fast and should land on one unambiguous
address, which is very likely to sit right next to (or point at) the
real per-zone table -- a much stronger anchor than trying to reverse the
6-candidate table blind.

### 10f. CONFIRMED: live global collectible progress counter found

Ran the exact-value scan as planned (185 -> collect one item -> 186) and
it converged on the exact same 6 addresses as the very first "gridleaks"
narrowing -- meaning it's the same underlying field. That field is
`0x1dae1750 + 0x00`, and a direct, deliberate test confirms it fully:

- Before: `+0x00 = 185`, `+0x08 = 324`
- Collected one item (in OmniStat Tunnels)
- After: `+0x00 = 186`, `+0x08 = 324` (unchanged, exactly as expected for a total)

**This is the first fully-confirmed live "current progress" value found
all session** -- not just a plausible-looking neighbor number, but a
value that measurably incremented by exactly 1 on command, matched
independently against the in-game UI, while the adjacent total stayed
fixed at the already-known-correct 324. `0x1dae1750` is a live struct:
`+0x00` = current count, `+0x08` = 324 (the total). **Correction from
10f's first draft, confirmed by 10g below: this is specifically the
GridLeaks category counter, not a combined "collectible board" total --
324 is the exact sum of the 4 known real GridLeaks district totals
(74+80+83+87), not `ProgressionFlagLocations` in general (that field's
count of 324 turned out to be the same number by genuine coincidence,
not because they're the same system).**

**What this gives the APWorld, right now:** a way to read overall
collectible completion progress live, with no more guessing needed for
that specific number. **What's still open:** this is the GLOBAL aggregate
only -- it does not yet say WHICH of the 324 locations were the ones
collected, so it can't drive per-check logic on its own yet. The rest of
the table (the values that looked like per-district totals/progress --
83/80/87/74/24 totals, 46/68/47 unconfirmed neighbors) still needs the
same kind of direct, deliberate confirmation test before trusting any of
it. Next step: pick one specific still-open number (e.g. Anchor's
neighbor value 46) and repeat exactly this pattern -- collect specifically
in Anchor, diff just that offset, confirm or reject.

### 10g. "World Progression" screenshot -- nails the category-to-group mapping for good

You sent a screenshot of the game's own "World Progression" screen, which
turns out to be the single most useful piece of ground truth handed over
all session. It shows, live: GridLeaks 186/324, Surveillance Recordings
23/45, Documents 14/42, Secret Bags 11/40, Electronic Parts 113/251, plus
Objectives: Security Hubs 8/8, GridNodes 3/4, Opportunity Missions 6/40,
Billboard Hacks 2/12.

Summed the matching prefix across every `flag_groups` entry with a known
static count and compared:

| Category (in-game) | Real total | Sum of static group(s) | Match |
|---|---|---|---|
| GridLeaks | 324 | `*GridLeaks` (6 groups) = 74+80+83+87+0+0 | **exact** |
| Surveillance Recordings | 45 | `AudioPickup*` (13 groups) | **exact** |
| Secret Bags | 40 | `SecretBag*` (12 groups) | **exact** |
| Electronic Parts | 251 | `ElectronicParts*` (12 groups) | **exact** |
| Documents | 42 | `Intel*` **excluding** `IntelCollectiblesWorld`/`IntelCollectiblesMission` (12 district groups incl. Trainstation) | **exact** |
| GridNodes | 4 | `GridNodes` | **exact** |
| Billboard Hacks | 12 | `HackableBillboards` | **exact** |
| Security Hubs | 8 | `SecurityHubs` = 10 | mismatch |
| Opportunity Missions | 40 | `OpportunityMissions`+`OppDeliveryMissions` = 7 | mismatch |

Five clean exact matches, in two batches, resolves a real naming ambiguity
for good: **`AudioPickup*` = Surveillance Recordings, `Intel*` (the
per-district ones only) = Documents** -- the reverse of what seemed like
the obvious guess earlier in the project (Intel sounded like "recordings"
by name alone; it's actually the audio-named group that holds the
recordings, and Intel holds documents). `IntelCollectiblesWorld` (35) and
`IntelCollectiblesMission` (4) are a separate bucket not counted in this
UI's Documents tally -- worth figuring out what those actually are later,
not blocking anything.

This also **corrects 10f's first-draft description**: `0x1dae1750`'s
`+0x00`/`+0x08` pair is confirmed by this screenshot to be the GridLeaks
counter specifically (186/324 matches exactly), not a generic combined
"collectible board" total as first guessed -- 324 being both GridLeaks'
real total AND `ProgressionFlagLocations`' real count is a coincidence of
two different systems landing on the same number, not evidence they're
the same system.

The two mismatches (`SecurityHubs` 10 vs. real 8, `OpportunityMissions`+
`OppDeliveryMissions` 7 vs. real 40) are useful negative signal too: they
mark exactly which specific groups' static counts should NOT be trusted
without the same kind of direct confirmation -- consistent with the
already-known DbObject partial-resolution caveat (sec 4/5), and/or (for
Opportunity Missions specifically) a sign that category might actually be
counting real `PamProgressionMission` instances filtered by type, not a
`PamProgressionFlagGroup`'s flags, at all.

### 10h. Eleven per-zone screenshots -- the district/sub-zone abbreviation codes are now fully solved

You sent eleven more screenshots, one per open-world zone (each showing
the zone name, district/caste/population line, and the same five
collectible categories broken down for just that zone): Eden Village,
Regatta Bay, Omnistat Tunnels, Centurian Yards, Triumvirate Drive,
Charter Hill, Crystal Valley, Development Zone, Ocean Pier, Shimmering
Heights, Concord Plaza. Real numbers (current/total):

| Zone | District | GridLeaks | Recordings | Documents | Secret Bags | Elec. Parts |
|---|---|---|---|---|---|---|
| Eden Village | Anchor | 11/34 | 3/4 | 1/3 | 1/4 | 2/24 |
| Regatta Bay | The View | 7/36 | 1/4 | 1/3 | 1/4 | 5/18 |
| Omnistat Tunnels | Rezoning | 17/24 | 3/6 | 2/4 | 1/5 | 13/14 |
| Centurian Yards | Downtown | 21/21 | 2/3 | 5/7 | 2/3 | 12/17 |
| Triumvirate Drive | Downtown | 35/45 | 2/3 | 0/4 | 2/3 | 27/49 |
| Charter Hill | Downtown | 1/6 | 1/1 | 0/2 | 1/1 | 6/10 |
| Crystal Valley | Anchor | 21/29 | 0/2 | 1/3 | 0/2 | 13/29 |
| Development Zone | Rezoning | 31/50 | 1/4 | 1/2 | 0/5 | 7/16 |
| Ocean Pier | The View | 17/44 | 1/6 | 0/3 | 0/6 | 7/30 |
| Shimmering Heights | Anchor | 14/20 | 2/4 | 2/5 | 1/4 | 11/20 |
| Concord Plaza | Downtown | 11/15 | 1/1 | 0/4 | 1/1 | 9/22 |

Every per-zone **total** (the denominator) was matched, exactly, against
one specific static `flag_groups` suffix per district/zone code by
comparing all eleven zones' totals per category at once -- no ambiguity
possible since each zone's total is a distinct number within its
category. This nails down the abbreviation codes for good:

- `Rz` = Rezoning: `Rdz` = Development Zone, `Ot` = Omnistat Tunnels
- `Dt` = Downtown: `Td` = Triumvirate Drive, `Ch` = Charter Hill,
  `Cy` = Centurian Yards, `Cp` = Concord Plaza
- `Ac` = Anchor: `Cv` = Crystal Valley, `Sh` = Shimmering Heights,
  `Ev` = Eden Village
- `Vw` = The View: `Op` = Ocean Pier, `Rb` = Regatta Bay

Confirmed on the `ElectronicParts*` groups first (every one of the 11
real totals -- 24,18,14,17,49,10,29,16,30,20,22 -- matches exactly one
`ElectronicParts{code}` group: `AcEv`=24, `VwRb`=18, `RzOt`=14, `DtCy`=17,
`DtTd`=49, `DtCh`=10, `AcCv`=29, `RzRdz`=16, `VwOp`=30, `AcSh`=20,
`DtCp`=22), then cross-checked identically against `AudioPickup*`,
`SecretBag*`, and the district-only `Intel*` groups -- **every single one
of the 44 zone/category combinations matches exactly**.

It also resolves the district-level `*GridLeaks` groups from §10e/§10g
for good, since each is now provably the sum of its zone's real
GridLeaks totals:

- `ConstructionGridLeaks` (74) = Rezoning = Omnistat Tunnels (24) +
  Development Zone (50)
- `AnchorGridLeaks` (83) = Eden Village (34) + Crystal Valley (29) +
  Shimmering Heights (20)
- `TheViewGridLeaks` (80) = Regatta Bay (36) + Ocean Pier (44)
- `DowntownGridLeaks` (87) = Triumvirate Drive (45) + Charter Hill (6) +
  Centurian Yards (21) + Concord Plaza (15)

("Construction" turns out to be Rezoning's internal name -- fitting,
since both its zones, Development Zone and Omnistat Tunnels, are
literally under-construction areas in the fiction.)

One more thing falls out for free: summing the eleven real zone totals
per category and comparing to the global World Progression total (§10g)
shows GridLeaks match with **zero** left over (324 exactly), but
Recordings/Documents/Secret Bags/Electronic Parts are each short by a
small, consistent amount (Recordings by 7, the other three by 2 apiece).
That remainder is fully accounted for by static groups belonging to two
locations that never got a zone screenshot -- `TheShard` and
`Trainstation` (both show `*GridLeaks`=0, matching the zero GridLeaks
remainder) -- plus one oddly-named extra, `AudioPickupGridLeaks` (5),
which turns out to be exactly the rest of the Recordings gap
(2 `TheShard` + 0 `Trainstation` + 5 `AudioPickupGridLeaks` = 7). These
are presumably smaller hub/mission areas rather than open-world zones
with their own "World Progression" screen, so no screenshot for them is
expected -- but if you ever do see one for either, it'd be worth a look
to confirm the last unmapped piece.

No new information on the two still-open mismatches: this same
screenshot batch's global row (`SECURITY HUBS 8/8`, `OPPORTUNITY
MISSIONS 6/40`) still doesn't match the static `SecurityHubs`=10 /
`OpportunityMissions`+`OppDeliveryMissions`=7 counts, so those remain
open per §10g's hypothesis (worth checking whether Opportunity Missions
is actually a `PamProgressionMission`-type filter rather than a flag
group).

### 10i. A twelfth zone -- "Zephyr Transit Hub" is `Trainstation`

You found one more zone screen that didn't fit the eleven above:
**Zephyr Transit Hub** (Downtown, **Runners** caste -- a caste not seen
on any of the other Downtown zones, all of which were Lo-/Midcaste),
population 10, showing 0/0 GridLeaks, 0/0 Surveillance Recordings, 1/2
Documents, 0/0 Secret Bags, 1/2 Electronic Parts.

Every one of those five numbers matches the `Trainstation`-suffixed
static group exactly: `TrainstationGridLeaks`=0, `AudioPickupTrainstation`=0,
`IntelTrainstation`=2 (matches the 2 total, and the 1 current lines up
with the live 14/42 Documents figure once counted in), `SecretBagTrainstation`=0,
`ElectronicPartsTrainstation`=2. The name fits too -- a "Transit Hub" is
exactly what a train station is. **`Trainstation` = Zephyr Transit Hub**,
confirmed.

That closes out two of the four small remainders left over in §10h:
adding this twelfth zone's totals to the previous eleven now sums to the
*exact* global total for both Documents (13+2=... district sum 40+2=42)
and Electronic Parts (249+2=251), with zero left over. GridLeaks and
Secret Bags were already/still short by exactly the amount `TheShard`
alone accounts for (0 and 2 respectively) -- so **`TheShard` is now the
only unmapped location left**, plus the still-unexplained
`AudioPickupGridLeaks` (5) group padding out the Recordings gap. If you
ever spot a zone screen with a small Recordings/Secret Bags total and no
GridLeaks at all, that's very likely it.

### 10j. `TheShard` identified -- the final story mission, not a zone

You confirmed it directly: **`TheShard` is Mission 15, "The Shard"** --
the game's final story mission -- not an open-world zone at all, which
is exactly why it never got (and never will get) its own "World
Progression" zone screen the way the eleven overworld zones and the
Zephyr Transit Hub do. It carries 4 total collectibles: 2 Surveillance
Recordings and 2 Secret Bags, no GridLeaks, no Documents, no Electronic
Parts -- an exact match for `AudioPickupTheShard`=2, `SecretBagTheShard`=2,
`TheShardGridLeaks`=0, `IntelTheShard`=0, `ElectronicPartsTheShard`=0.

That's every last static collectible-flag-group location now mapped to
something real: eleven open-world zones (§10h), one transit hub (§10i),
and one story mission (this section). The only genuinely unexplained
group left in the whole collectible catalog is `AudioPickupGridLeaks`
(5) -- padding out the Surveillance Recordings global total (45) beyond
what any zone/hub/mission accounts for -- worth a look eventually, but
it doesn't block anything.

### 10k. Story-mission collectible gating -- most missions are subsets of their zone, Mission 15 is the exception

You supplied (presumably from a written guide, not a live read) a
partial per-story-mission collectible breakdown:

| Mission | Zone | Reported collectibles |
|---|---|---|
| 4. Back in the Game | Centurian Yards | 2 secret bags, 2 documents, 2 recordings |
| 5. Savant Extraordinaire | Shimmering Heights | 6 total (incl. 1 recording near the exit window) |
| 6. Benefactor | Eden Village | 2 secret bags, 2 recordings, 1 document |
| 10. Vive La Resistance | Development Zone / Omnistat Tunnels | 2 electronic parts, 2 secret bags, 2 recordings |
| 11. Prisoner X | Ocean Pier | 1 secret bag, 2 recordings |
| 12. Thy Kingdom Come | Omnistat Tunnels | (not given) |
| 13. Family Matters | Regatta Bay | (not given) |
| 15. The Shard | The Shard | 2 secret bags, 2 recordings |

Checked each reported number against that zone's real per-category
*total* from §10h/§10j: every one is **less than or equal to** the
zone's own total (e.g. Mission 4's "2 secret bags" vs. Centurian Yards'
real total of 3; Mission 6's "1 document" vs. Eden Village's real total
of 3). Combined with the fact that none of these eight zones showed any
unexplained remainder in §10h/§10i/§10j's sums (everything already
balanced exactly using only the 11 zones + Trainstation + TheShard, with
zero left over for any of these missions specifically), the conclusion
is: **missions 4, 5, 6, 10, 11, 12 and 13's collectibles are a subset of
their parent zone's collectibles, not a separate bucket** -- they're
counted once, as part of that zone's normal `*GridLeaks`/`AudioPickup*`/
etc. group, the same as anything found in free roam there. Mission 15 is
the one confirmed exception (§10j): `TheShard` is a genuinely separate,
never-free-roam location with its own flag groups, because the mission
itself isn't set in any of the explorable zones.

This doesn't change any static/live mapping, but it's a useful signal
for later Archipelago location-logic work: it means most zones' collectible
counts already include some number of mission-gated pickups (only
reachable during that specific story mission, not before or after in
free roam) mixed in with the free-roam ones, and *which* pickups are
gated that way isn't visible from the flag-group totals alone -- it'll
need either per-flag names/locations (§7's `ProgressionFlagLocations`,
324 entries with spatial transforms) cross-referenced against a mission
walkthrough, or more reports like this one, mission by mission, to
resolve. Worth continuing to collect if you come across a fuller list
(especially something covering missions 1-3, 7-9, and 14, which are
missing from this batch, and a specific breakdown for 5/12/13).

### 10l. A full 21-mission walkthrough guide -- confirms the zone mapping, but two things in it don't hold up

You linked a Steam Community guide covering all 21 story missions
(different numbering from §10k's list -- this guide's "Mission 5: Back
in the Game" is the same mission as §10k's "Mission 4", so the two
sources are counting missions differently, e.g. this guide may split or
merge some compared to whatever list you had). For GridLeaks, Documents,
and Surveillance Recordings it gives sequential, game-wide pickup
numbers per mission (e.g. "GridLeaks #1-20"), which lets each mission's
*zone* be checked against real per-zone totals directly:

| Zone (by GridLeaks range) | Guide range | Guide count | Real total | Match |
|---|---|---|---|---|
| Centurian Yards | #1-20 | 20 | 21 | off by 1 |
| Concord Plaza + Triumvirate Drive | #21-79 | 59 | 60 | off by 1 |
| Shimmering Heights | #80-99 | 20 | 20 | **exact** |
| *(unassigned gap)* | #100-101 | 2 | -- | -- |
| Crystal Valley | #102-130 | 29 | 29 | **exact** |
| Eden Village | #131-162 | 32 | 34 | off by 2 |
| Charter Hill | #163-168 | 6 | 6 | **exact** |
| OmniStat Tunnels | #169-192 | 24 | 24 | **exact** |
| Development Zone | #193-242 | 50 | 50 | **exact** |
| *(unassigned gap)* | #243-244 | 2 | -- | -- |
| Ocean Pier | #245-288 | 44 | 44 | **exact** |
| Regatta Bay | #289-324 | 36 | 36 | **exact** |

7 of 10 zones match their GridLeaks total exactly, and the three
mismatches are all tiny (1-2 items) and fully covered by the two small
unassigned number gaps the guide itself leaves -- this reads as ordinary
walkthrough-numbering slop (a couple of GridLeaks the guide author
missed or mis-numbered), not evidence against the zone mapping itself.
Overall this is strong independent confirmation of §10h's district/zone
codes, from a completely different source than the in-game screenshots.

Two things in the guide, though, contradict data we already have
directly from the game and should **not** be trusted over it:

- **Electronic Parts**: the guide only lists one chunk ("#1-10" in
  Mission 4, Centurian Yards) and its own grand-total line claims just
  10 Electronic Parts exist in the whole game. The real total is 251
  (confirmed straight from the in-game World Progression screen, §10g).
  This guide simply doesn't track Electronic Parts as a collectible
  category the way it tracks the other four -- ignore its Electronic
  Parts numbers entirely.
- **Zephyr Transit Hub's recordings**: the guide assigns Surveillance
  Recording #1 to Mission 1 ("Release") and #5 to Mission 6 ("In his bad
  books"), both listed at Zephyr Transit Hub -- but your own screenshot
  of that zone (§10i) showed **0/0 Surveillance Recordings**, i.e. none
  exist there at all. This is a direct conflict; the live screenshot is
  the more trustworthy source (it's the game's own accounting, not a
  human-written guide), so treat Zephyr Transit Hub as having zero
  recordings and chalk this up as a guide error, unless a second
  independent source corroborates the guide instead.

The guide *does* independently corroborate Zephyr Transit Hub = the
Mission 1/2/6 location (§10i's `Trainstation` identification): it lists
Documents #1-2 there (Mission 2, "Reunion") -- an exact match for
`IntelTrainstation`=2 and the zone's real Documents total of 2.

- **Build the real dependency graph now that GUID refs decode (§6) AND
  names resolve for free (§9).** This is the concrete next step: walk
  every `PamProgressionMission` → `CompletedFlag`/`AvailableFlag`, every
  `RewardCondition` → the flag/flag-group/mission it checks, every
  `PamReward` it's tied to, and every UI widget → the flags/kits it
  displays, and assemble it into one real graph instead of separate
  per-file dumps — and every node in that graph now has a real, readable
  name attached, not a placeholder number. Nothing left blocking a
  from-scratch design doc except doing the assembly work.
- ~~Sid name resolution is still the separate, harder bottleneck~~
  **Solved, see §9.** Turned out not to be a hash at all — a plain
  string-table offset, already fixed in the parser and applied to every
  existing dump.
- **Systematic export pass — mostly done** (see §5). Correction: `ProgressionFlagLocations`
  was never a separate asset to begin with — it's a field on `PlayerProgressionData`
  (already exported and parsed), and it resolves to 324 `PamProgressionFlagLocation`
  entries, each with a `NameHash` and a spatial `Transform` reference. That's
  about as close to a ready-made "locations" list (in the Archipelago sense)
  as this catalog gets — `Transform` itself isn't decoded yet (it's a `FileRef`
  into a `LinearTransform`, not yet taught to the parser), everything else is.
  What's actually still unexported: more UI widgets like
  `Progression_TreeGearContent` (the sibling `Progression_Tree*Content`/
  `Progression_Item*` ones) now that we know they're a rich source of
  verified cross-references, not just event-routing noise. `Gameplay/Collectibles`
  is done (§7); `Gameplay/Mission` was test-driven and deliberately deferred
  (§8) rather than exported wholesale.
- **`Gameplay/Mission` deliberately deferred — see §8.** Two-file test case
  (Birdman folder) showed mission logic isn't a flat field like collectibles;
  it's spread across hash-keyed event wiring and separate schematic-graph
  files this pass hasn't reached. Not worth chasing across every mission
  subfolder right now — the flag/reward graph from §6-§7 already covers the
  *what*, just not the precise *which mission action* for each flag.
- **`Gameplay/Collectibles/Instances` deliberately deferred.** The type-level
  templates (`Gameplay/Collectibles`'s top-level list — `pf_collectibleitem_*`,
  `PF_CompulsionOrb`, `PF_L_CollectibleItemIcarusNoah`, etc.) are worth
  exporting normally. The `Instances` subfolder underneath is a different
  problem: hundreds of individually-placed-in-the-world collectible entries
  (e.g. `PF_Collectable_ElectricBox_AcCv01` through `AcEv63` and beyond, and
  that's just one collectible type), and this Frosty build has no bulk/folder
  export — confirmed no right-click submenu, no multi-select export, only a
  plugin scoped to audio/mesh. Exporting hundreds of these one at a time isn't
  a good use of time for what they add (precise per-item placement, not new
  categories or logic). Left for later — possibly revisitable once the
  runtime/memory side is further along (a working live-read client could
  enumerate placed collectibles without touching Frosty's export UI at all),
  or by testing whether the asset *names* alone (visible for free in the
  Data Explorer, no export needed) already encode enough structure
  (collectible type + area/chapter + index) for a usable locations list.
- ~~Runtime side is still untouched.~~ **Kickstarted — see §10.** A
  community SDK dump handed us the live memory address chain and struct
  offsets directly (cross-validated against everything in §2/§6/§9).
  Concrete next step: run `dump_progression_state.py` against the real
  game and report back what happens — that's the actual next action here,
  ahead of anything else in this list.
- **Reach out to derwangler** — still worth doing, though the specific
  Sid-resolution question that motivated it is now moot (§9). Still
  useful for the §3/§8 open questions: the actual trigger/logic graph
  mechanism, and whether they've already solved reading the mission
  schematic-graph files §8 punted on.
- **The `Hash` field (djb2, per the Discord reply) is now the only
  remaining string-identifier mystery — and a much smaller one.** See
  §9's closing note: unlike `Sid`, this one really is a hash, but of a
  small fixed vocabulary of engine property/event names (schematic pin
  IDs), not per-instance content. Worth a real djb2/djb2a brute-force
  pass against a proper candidate list (Frostbite's known standard
  property names — "Enabled", "Value", "TriggerEnter", etc. — a list
  that likely exists publicly for other Frostbite titles even without
  one for this specific hash space) if the mission/schematic wiring in
  §8 ever gets revisited. Not blocking anything else right now.

### 10m. Live debugging session -- the per-item "collected" state still isn't found, but the write path now is

Goal for this session: §10's negative result (raw_dump_flags.py / dump_region.py both showed **zero** byte changes across real collection events, ruling out the static `PamProgressionFlag` object pool as the home of live "collected" state) left one open path -- find where that state actually lives by watching the game's own code write it, via Cheat Engine's debugger, rather than guessing at memory layout from the outside.

**Session-to-session address churn, confirmed repeatedly.** The game crashed three separate times during this session (unrelated to anything we did, as far as we could tell). Every crash produces a brand-new process with a brand-new ASLR layout, which silently invalidates every previously-found literal address -- including the GridLeaks counter itself. Re-derived it fresh four times over the course of the session, each time with the same 6-address Cheat Engine narrowing (Unknown initial value -> Increased value, twice) plus `read_addresses_v2.py <addrs> --window 16` to identify which candidate actually shows `<current>/324`: `0x1DAE1750` (original) -> `0x1DA56BA0` (188/324) -> `0x1E1BA2D8` (189/324) -> `0x1DCE1750` (181/324, after a crash that looks to have cost some unsaved progress -- count went backward). The same exact-value technique also cleanly found the Electronic Parts counter this session: `0x1E1CE480` (115/251, confirmed against the known 251 total). **Takeaway for next time: never trust a literal address across a game restart, full stop -- always re-derive.**

**Found the actual write instruction.** "Find out what writes to this address" on the confirmed counter landed on a single instruction inside `msvcr120.dll`'s tuned `memcpy` implementation: `mov [r10],eax` at a size-4 tail-copy entry point. Both the GridLeaks and the Electronic Parts counter writes go through the exact same instruction. Per the Microsoft x64 calling convention this is `memcpy(dest=RCX, src=RDX, count=R8)` -- confirmed count=4, and the source is always a small local variable on the caller's stack (never a fixed/global address), meaning whatever code decides the new value builds it locally first and hands it to a shared copy utility rather than writing it directly. **This confirms field writes in this engine go through generic, reflection-based infrastructure** -- the same conclusion the *static* EBX-parsing side of this project reached independently months ago (every field is described generically via `FieldDescriptor`/`ComplexDescriptor`, never hardcoded per-type). Neither the memcpy call itself nor its immediate 1-2 calling frames say anything about *which* field -- they're pure plumbing shared by every reflected field write in the game, not just progression data.

**One real crash risk, and the workaround.** The very first "find out what writes" attempt crashed the game immediately on trigger -- likely because this specific counter gets touched constantly (not just on real pickups), turning a write-breakpoint into a break-storm. It worked cleanly on a later attempt without an intentional settings change, so the exact trigger/fix isn't fully pinned down -- **flag this as a real risk of the technique on this specific address if attempted again**, and note Cheat Engine's breakpoint method selector (exceptions vs. debug registers) is worth trying deliberately if it recurs.

**The heuristic stack scanner produces false leads -- use the real debugger's Return Address panel instead.** Cheat Engine's "Stack" tab / "Extra Info" popup scans raw stack memory for values that merely *look like* code addresses, which can surface **stale return addresses left over from an already-finished, unrelated call** that simply hadn't been overwritten yet. This cost one full detour: `+2A476DE` looked like a promising caller at first glance but turned out (on closer disassembly reading) to be a generic COW-string assignment routine (`lock inc [rbx+08]` refcount pattern + `memmove` call) — completely unrelated, a red herring from this exact failure mode. The **full "Memory Viewer - Currently debugging thread" window's proper Return Address panel** is reliable by contrast -- it correctly bottoms out at the real OS thread-entry chain (`MSVCR120.beginthreadex` -> `KERNEL32.BaseThreadInitThunk` -> `ntdll.RtlUserThreadStart`) every time it was checked, which is a good sanity check that a given call-stack capture is trustworthy.

**Walked the real chain for GridLeaks, all the way to a genuine observer/broadcast loop.** Using the reliable Return Address panel:
- `+2A46513`: generic reflection/dispatch code (a static-init-guard pattern over an index-computed global flag array) -- more shared plumbing, not category-specific.
- `+32A93B0` (return addr `+32A93DD`): `if ([this+0x18] != null) listener->Notify(1.0 - xmm2)` -- a generic "tell my optional sub-handler about a changed value" wrapper. The `1.0 - x` shape strongly suggests an inverted progress ratio.
- `+2A430F0`: a 2-instruction trampoline (`mov rcx,[rcx]` then tail-jump) that lands right back inside `+2A46513`'s function -- closes the loop, confirms it's one shared reflection-dispatch mechanism.
- `+32AC4EF` (loop body `+32AC4D2`..`+32AC505`): **a real `std::vector<Listener*>`-style loop** (`begin=[rdi+0x238]`, `end=[rdi+0x240]`), calling a **virtual method** (vtable slot 3, i.e. `[[rcx]+0x18]`) on every listener with `rcx=listener, edx=[rdi+0x2D8], xmm2=xmm8`. `rdi` is a broadcaster/notifier object that owns the whole listener list.

Captured live register state at this loop's call site: `RDI` (broadcaster) `= 0x36CF8950`, `RCX` (the specific listener about to be notified) `= 0x1D382D30`, `RDX` (`[rdi+0x2D8]`) `= 0` for this particular listener. Stepping into the call confirmed this listener runs the exact same `+32A93B0` function -- i.e. the broadcaster's listener list mixes multiple instances of the same generic listener class, each presumably wired to a different UI element/category.

**Dumped the listener object itself (`0x1D382D30`, 128-byte window) -- one field stands out.** Two vtable pointers (`+0x00`, `+0x08`, 0x40 apart -- multiple inheritance), a confirmed non-null sub-handler at `+0x18` (`0x1D53E980`, matching why the notify fired), a scatter of zero and pointer-shaped fields, and **`+0x68 = 4622`** -- the *only* plain small integer in the whole object, everything else being zero or clearly pointer-shaped. Strong candidate for a per-listener category/ID discriminator. `+0x60` sits only 40 bytes below the object's own address, suggesting these listeners live in a pooled array of siblings (the same shared-allocation-pool pattern documented elsewhere in this file for other object types).

**Repeated the whole chain for Electronic Parts (`0x1E1CE480`) as a cross-check -- outer call stack matched exactly.** Same `memcpy` tail-write instruction, and critically, the Return Address panel showed `+31A34D6`, `+2A2E05D`, `+2A315B5`, `agsGetEyefinityConfigInfo+DA1C` (a proximity label, not a real call -- ignore it), `+2A6342B`, `+2C7884D`, then the identical thread-startup chain -- **byte-for-byte the same outer frames as GridLeaks**, from `+31A34D6` up. This is a real, independent confirmation that **the whole progression-broadcast mechanism is one universal system shared by every collectible category**, not duplicated per-category code -- the category-specific part lives only in the last frame or two closest to each individual write. Ran out of session time before capturing Electronic Parts' own `+0x68`-equivalent value for comparison against GridLeaks' `4622` -- that's the natural next data point.

**Net result:** the per-item "collected" bit is still not found, but the *architecture* is now well understood end-to-end -- generic reflection-based field write -> shared observer/broadcast loop -> per-listener object with a promising discriminator field -- confirmed identically across two independent categories. Concrete next steps for a future session, roughly in order of expected payoff:
- Grab Electronic Parts' listener object the same way and compare its `+0x68` against GridLeaks' `4622` -- confirms or kills the "discriminator field" hypothesis outright.
- Once `+0x68`'s meaning is known (or even if it isn't), dump every listener in the SAME broadcaster's vector (`[rdi+0x238]`..`[rdi+0x240]`) in one pass rather than one at a time -- the pooled-sibling pattern at `+0x60` suggests they're contiguous or at least easy to enumerate, which would let a single collection event reveal several categories' listener objects (and `+0x68` values) at once.
- All of the above only reaches **aggregate category counters/ratios** (this is a stats-broadcast/UI-update system) -- it has not yet shown any evidence of *which specific item* was collected. The per-item flag may live entirely outside this broadcast chain (e.g. checked once at pickup time and never touched again by this notify system) -- worth remembering this whole investigation could be adjacent to, not on top of, the real answer.
- Given tonight's crash frequency, worth a fresh, less crash-prone game session before resuming -- and re-derive every address from scratch regardless, per the ASLR caveat above.

## 11. The mission → reward → flag dependency graph — built, and it works

This is the concrete next step §9/§10g/§10k all pointed at: with GUID
references decoding (§6) and every name resolving for free (§9), nothing
was actually blocking assembling `PlayerProgressionData.bin` (flags,
flag groups, missions) and `RewardsData.bin` (rewards + every
reward-condition subtype) into one real graph, instead of separate
per-file dumps. `build_dependency_graph.py` (new, in `runtime/`) does
exactly that and writes `dependency_graph.json`.

**The same over-inclusive-DbObject-list bug from §2/§5 (and the live-memory
version of it in §10c) shows up here too, in a new shape** — worth
understanding before trusting the output. `PamReward.RewardConditions`
and `PamProgressionMissionCompletedRewardCondition.Missions` are both
DbObject-typed list fields, and their raw parsed content mixes in refs
to totally unrelated objects, including bare self-refs back to the root
`PamRewardsData` asset — the exact same symptom as `PamProgressionFlagGroup.Flags`
mixing in non-flag GUIDs. The fix turned out to be simple and reliable
here, though, because of a detail that wasn't true for the live-memory
case: **everything that actually belongs in one of these lists is
either always a local ref or always an external ref, never both** —
`PamReward`/every `PamRewardCondition` subtype lives inside
`RewardsData.bin` itself (so real `RewardConditions` entries are local
refs; a local ref to `PamReward`/`PamRewardsData` itself is always
noise to discard), while every real target a condition can check --
a `PamProgressionFlag`, `PamProgressionFlagGroup`, or `PamProgressionMission`
-- lives only in `PlayerProgressionData.bin`, so real `Missions` list
entries are always external refs (a local ref there is always noise).
Filtering on ref-kind-plus-type this way, cross-referenced against the
flag/group/mission GUID tables already pulled from `PlayerProgressionData.bin`,
gave **zero unresolved target lookups** — every flag, group, and mission
a condition pointed at resolved to its real name, cleanly.

Results from the real files:

- 67 `PamReward` entries, 162 reward-condition instances across 9 types
  (110 `PamProgressionFlagRewardCondition`, 28 `PamProgressionMissionCompletedRewardCondition`,
  12 `PamMoveSeqRewardCondition`, 6 `PamProgressionFlagGroupRewardCondition`,
  plus a handful each of `PamNamedChallengeRewardCondition`/`PamKillAIRewardCondition`/
  `PamStatsRewardCondition`/`PamFlowRewardCondition`/`PamEchoCustomizedRewardCondition`
  — these last five don't reference progression flags/groups/missions at
  all, kept only for completeness).
- Real, readable output falls out immediately, e.g. one reward
  (RunnerKitGuid `2366712b...`) is gated on just `Flag
  'CriticalPathProgression_HasCollectedGridleakMapping' >= 1`; another
  (`1463bee0...`, a 33-condition RunnerKit unlock) mixes flag unlocks
  like `Unlocks_DoubleWallrun`/`Unlocks_QuickTurn` with `FlagGroup
  'AnchorGridLeaks' complete`, `FlagGroup 'TheViewGridLeaks' complete`,
  and `Mission(s) completed: mission#77` in one `RewardCompareConditionsType_Count`
  threshold-33 check.
- 24 of the 67 rewards resolved at least one real condition; the other
  43 came back empty. Same story for `PamProgressionMissionCompletedRewardCondition`:
  17 of the 28 instances had zero external mission refs after filtering.
  Both are almost certainly **the same already-documented partial-DbObject-resolution
  limitation from §2/§5/§10d** (only ~104/124 flag groups' own `.Flags`
  field ever resolved nonzero) showing up again here, not evidence these
  rewards/conditions are genuinely empty -- worth keeping in mind rather
  than reading "43 rewards have no conditions" at face value.
- Missions: all 152 carry a resolved `CompletedFlag`/`AvailableFlag` name
  (that field isn't DbObject-based, so no partial-resolution issue there
  at all), and 125/152 carry a resolved `MissionDescription.ActiveNameSid`
  -- a localization key string like `ID_OPP_DIV_PH5_01_LABEL`, not the
  displayed English text. Tried cracking that key against the
  already-exported `list.csv` localization dump (which is keyed by an
  8-hex-digit hash) with CRC32/FNV-1a/djb2/djb2a, upper- and lowercase --
  no match against any of the sample Sids tried. Left as a real open
  question (a different hash algorithm than §9's `Hash` field, or a
  separate string table `list.csv` doesn't cover) rather than something
  worth burning more time on right now, since the *identifiers*
  (`ID_OPP_DIV_PH5_01_LABEL` etc.) are already useful on their own even
  unresolved to English.

Net effect: the flag/reward/mission catalog is no longer three separate
per-file dumps -- `dependency_graph.json` ties a real, named flag or
flag-group or mission to every reward it unlocks (RunnerKit reward,
achievement data ref, and all), which is the actual shape the eventual
Archipelago item/location logic needs. Next natural step from here would
be resolving those 43 empty-looking rewards' real conditions (likely
needs a smarter DbObject-membership heuristic, the same open problem
noted for flag groups) and the 125 `ActiveNameSid` strings into real
display text.

## 12. **BREAKTHROUGH -- the save file has the per-item state, in the clear, and the hash is cracked**

The question that stumped all of §10 (`dump_progression_state.py`'s live
memory walk, §10d's byte-diff proving the config-data allocation pool is
read-only, §10e-10m's whole Cheat Engine debugging session hunting for the
write path) turned out to have a much simpler answer: **don't read the
game's memory at all -- read the save file.** You uploaded `PROF_SAVE`
plus its sibling files (`PROF_SAVE_backup`, `PROF_SAVE_profile`,
`PROF_SAVE_backup_profile`) after asking whether a save file might help.
It's the single biggest find of the project so far.

**The save file is not compressed or encrypted.** Whole-file entropy is
0.4 bits/byte (random/compressed data would be ~8) -- it's a sparse,
mostly-zero-padded binary format with plaintext keys throughout, readable
with nothing more than `strings`.

**File format, fully reverse-engineered:**
- Magic `FBCHUNKS` + a ~38-byte header, then a flat sequence of "blocks".
- Each block: `u32 entry_count`, followed by that many entries of
  `[u32 type][u32 keylen][keylen bytes, NUL-terminated][u32 vallen][vallen
  bytes]` -- a generic typed key/value store (type 1 = float-as-text,
  2 = bool/int-as-text, 4 = stat-as-text, 5 = binary blob). Confirmed by
  parsing clean through 4 real blocks (26 UI settings, 4 onboarding flags,
  188 `ch_rrt_*`/telemetry stats, then 3 `ProgressionManagerData*` blobs)
  with zero parse failures.
- After the last block (offset ~40,161 in the sample file) it's **983,865
  bytes of solid zero padding** out to the fixed 1,024,026-byte file size
  -- the game pre-allocates a big buffer and only the first ~40KB is ever
  used. `PROF_SAVE` and `PROF_SAVE_backup` were byte-for-byte identical in
  this sample (no new progress between the two saves), which is itself a
  useful confirmation the format is deterministic, not e.g. timestamped
  per write.
- Three `ProgressionManagerData*` entries exist per save (`...` unsuffixed,
  plus one per linked platform account ID) -- same shape, different
  content (different session/account, not byte-identical to each other).

**Inside a `ProgressionManagerData` value:** 144 bytes of player
transform/session floats (position, camera, etc. -- not needed for our
purposes), then `u32 record_count`, then `record_count x {u32 name_hash,
u32 value}` -- a flat hash table, exactly the "separate stat system
addressed by name/hash" theory from §10m's Discord follow-up, just sitting
in the save file instead of behind `ClientStatisticsService` in memory.
985 records in the sample's primary section; value histogram is dominated
by `1` (638 of 985 -- boolean "I have this"), with a long tail of small
counters (2-112) and a handful of Unix timestamps (e.g.
`1465640253` on a `VOCooldowns_...` key -- June 2016, consistent with
other `_tstamp` stats seen elsewhere in the save).

**The hash is djb2a, cracked on the first real attempt:**

```python
def djb2a(data: bytes) -> int:
    h = 5381
    for b in data:
        h = ((h * 33) ^ b) & 0xFFFFFFFF
    return h
```

applied to the **UTF-8 bytes of the flag's own internal `Name` field** (or
`SyncStatName` / `ActiveNameSid` / `NumberOfFlagsSyncStatName` /
`SumOfFlagValuesSyncStatName` -- all five Sid-field kinds share one hash
space), **with no trailing NUL byte**. Built a candidate dictionary from
every one of those five field kinds already resolved in
`PlayerProgressionData_full.txt` (3,342 unique strings, **zero
collisions**), hashed all of them, and matched against the save's records:
**977/985 (99.2%) resolved on the very first run**, and re-ran clean
against all three `ProgressionManagerData*` sections (99.2% / 99.1% /
99.1%). This is the same djb2a algorithm already confirmed for the
unrelated `Hash` field type back in §9's Discord tip -- turns out it's the
general-purpose string-hashing primitive this engine uses everywhere, not
just for that one field.

Sample of what falls out, straight from the sample save, with zero
ambiguity about what each row means:

```
TheViewGridLeaks_TheViewCompulsionOrbD0E15D36-8F75-42A9-8176-4E6DDBCA17B9  = 1
ConstructionGridLeaks_ConstructionCompulsionOrb96897797-A4C7-4247-A45D-E59DBFF56E3D = 1
ElectronicPartsAcSh_Chip07Taken       = 1
ElectronicPartsVwRb_Chip29Taken       = 1
SecretBagDtTd_DowntownGreenCollectablesFB9E1A8A-9C2B-4738-B647-9D09F26DB54D = 1
SecurityHubs_Anchor03State            = 4
Vive La Resistance Debriefing_CompletedTime = 112
Doors_Doors_M06_AfterIcarus           = 1
```

Category breakdown of the 985-record sample (via simple name-prefix
bucketing, not exhaustive): 238 `GridLeaks` records (all `value==1`; by
district prefix: Downtown 75, TheView 55, Construction 54, Anchor 49 --
sane numbers, no red flags), 210 `*_CompletedTime` mission-completion
stamps, 40 `*_Available` mission-availability flags, 48
timestamp-looking `VOCooldowns_*` entries, 17 `Doors_*`, 16
`SecurityHubs_*`, 6 `MiscCompleted_*`, and 8 still-unresolved hashes
(likely strings that live in a static file this project hasn't text-dumped
yet, e.g. achievements or `RunnerKitDefinitionsMeta` -- worth widening the
candidate dictionary to those files next). Every single GridLeak-named key
that resolved had `value==1` -- strong independent confirmation this really
is the "collected: yes/no" bit, not some unrelated counter that happens to
share a name pattern.

**Delivered: `decode_save.py`** (new, in `runtime/`). Fully standalone --
no live game process, no Cheat Engine, no ASLR/crash exposure at all. Give
it a `PROF_SAVE` file and one or more static EBX text dumps to mine for
candidate strings, and it parses every block, decodes every
`ProgressionManagerData*` table, and writes a full JSON of `{hash, name,
value}` for every record, resolved wherever the candidate dictionary
covers it:

```
python decode_save.py PROF_SAVE PlayerProgressionData_full.txt --out decoded.json
```

Verified end-to-end against the real uploaded save: 4 blocks parsed, 3
progression sections decoded, 99.1-99.2% resolved on all three, matching
the manual analysis exactly.

**Why this changes the plan more than anything else in this document:** an
Archipelago client for this game does not need to read the live process at
all for state -- it can read (and, if the write path turns out to be just
as simple, probably write) the save file directly. That sidesteps every
problem §10e-10m ran into: no ASLR/address-churn across game restarts, no
crash risk from breakpoints or "find out what writes", no dependency on
Cheat Engine skill at all. This is very likely the actual foundation the
eventual client should be built on, with live memory reading (§10's whole
apparatus) relegated to, at most, a "detect state changed *right now*
without waiting for a save" nice-to-have.

### 12a. CONFIRMED -- the write path works. The game reads this table and trusts it.

Tested same night. Wrote `patch_save.py` (new, in `runtime/`): flips one
record's 4-byte `value` in place, leaving the rest of the file (size, every
other byte) untouched -- the safest possible mutation, no length-prefix or
record-count bookkeeping to get wrong.

**Round 1** (flip one `TheViewGridLeaks_...` record from `1`→`0`, only
present in the largest of the three `ProgressionManagerData*` sections):
game loaded fine, no crash -- but the World Progression screen's GridLeaks
count didn't move. Initially ambiguous (wrong section? UI reads a separate
cached total, not a live sum of the record table?) -- but the real
explanation surfaced immediately after: **Steam Cloud was silently
re-syncing the original save over the swapped-in file**, an entirely
separate confound from anything about the save format itself.

**Round 2**, redone with Steam set to offline first, targeting a
`ConstructionGridLeaks_...` record confirmed present with `value==1` in
**all three** `ProgressionManagerData*` sections (patched all three copies
at once, ruling out "wrong section" as an excuse): **the World Progression
screen's GridLeaks count dropped from 183/324 to 182/324 -- exactly the
expected -1.** Every other stat on the same screen (Recordings 23,
Documents 14, Secret Bags 11, Electronic Parts 116, Security Hubs 8/8,
GridNodes 3/4, Opportunity Missions 6/40, Billboard Hacks 2/12) stayed
byte-for-byte identical, as expected from a single-record edit.

**This is the confirmation the whole project has been building toward:**
the save file is not just readable, it's *writable* -- flipping one
`{hash, value}` record is enough to change what the live game reports as
collected, with no live-memory access, no Cheat Engine, no ASLR exposure,
and (with Steam offline) no cloud-sync fighting back. A save-file-based
Archipelago client -- read state to know what's been collected, write
state to grant/revoke checks -- now looks not just plausible but already
demonstrated end to end, in miniature.

### 12b. CONFIRMED -- the effect is not just the UI counter, it's the physical object in the world

Wrote `mass_set_collectibles.py` (new, in `runtime/`): grows a
`ProgressionManagerData` blob by inserting brand-new `{hash, 1}` records
(rather than editing existing ones), shifting everything after it forward
and trimming an equal number of zero bytes off the file's padded tail to
keep the total size constant. Used it to set 323 of the 324 real GridLeaks
(per §12's cracked name list, all districts) to collected in one shot,
holding back exactly one specific orb by name so it would stay real and
pickable.

Tested in-game (Steam still offline): **a GridLeak you were standing in
front of before the swap physically disappeared from the world the moment
the edited save loaded** -- not just the counter, the actual object. This
confirms the per-item record isn't a UI-only cache; it's the same flag the
game's own spawn/despawn logic checks for that physical pickup. The
World Progression count read exactly 323/324, matching what was set.

**Resolved -- the "couldn't find it" mystery had a boring cause: a
selection bug, not a location-finding failure.** `mass_set_collectibles.py`
picked its hold-back item as "alphabetically last real name" without
checking whether that item was already collected -- and this specific one
(`TheViewGridLeaks_...FF23D3E1-...`) turned out to already have `value==1`
in the save's primary (largest) section from earlier real gameplay, before
this session ever touched it. So there was nothing uncollected left to
find; the script had (unintentionally) already shipped a true 324/324 and
just didn't say so. Confirmed directly: checking that hash against the
pre-mass-set save showed `value: 1` already present.

**Fixed in `mass_set_collectibles.py`**: it now scans every section for
already-`value==1` hashes *before* picking what to hold back, only
considers genuinely-uncollected names as hold-back candidates, and warns
loudly (rather than silently proceeding) if a `--hold-back` name or the
`--leave-uncollected` pool turns out to already be done. Re-running it
against the fully-completed save now correctly reports `0/324 not yet
collected` and refuses to write a no-op output, instead of repeating the
same silent mistake.

**Net result of this whole side-quest: `PROF_SAVE.gridleaks_324_true`
now has all 324 real GridLeaks at `value==1`, consistently across all
three `ProgressionManagerData*` sections** (also patched back the one
Construction orb round 2's test had deliberately zeroed, which was the
*other* reason the count wasn't a clean 324 yet). Ready for you to load
and see whether hitting 100% on a collectible category triggers anything
worth knowing about (reward, message, achievement data ref from
`dependency_graph.json` §11) -- no hunting required this time, since
nothing is actually being newly collected, the save just already says
"done." Real in-world coordinates for individual collectible GUIDs are
still an open, unsolved need for any *future* "go get this specific one"
test -- nothing examined so far has looked like a coordinate; would need a
fresh look, possibly at a different data file than `PlayerProgressionData.bin`.

### 12c. CONFIRMED -- the reward system fires too, exactly as `dependency_graph.json` (§11) predicted

Loaded `PROF_SAVE.gridleaks_324_true` in-game: a **"RUNNER KIT DROPPED --
Collect every gridLeak in Glass"** notification fired immediately. This is
the full chain working end to end, not just the flag data: a save-file
edit → the game's own flag-group-completion logic recognizing the
category hit 100% → a real reward (a RunnerKit) actually granted. This is
precisely the shape `build_dependency_graph.py` (§11) already mapped
statically (a `PamProgressionFlagGroup` completion condition unlocking a
`PamReward`) -- now demonstrated live, triggered purely by editing the
save file, with nothing collected in real gameplay.

Bonus find, free from the same screenshot: **"Construction" (the internal
asset-name prefix on every one of these flags, e.g.
`ConstructionGridLeaks_...`) is displayed to the player as "Glass"** --
one more internal-name-to-real-name mapping resolved, joining the
district/sub-zone table from §10h.

**Immediate follow-ups this opens up, not yet done:**
- ~~Test the *other* direction -- flip a currently-uncollected item's
  record from (absent, or `0`) to `1`~~ -- **done, see §12b**: inserting
  brand-new `{hash, 1}` records (not just editing existing ones) works,
  confirmed by 323 real GridLeaks vanishing from the world at once.
- Get real-world coordinates for individual collectible GUIDs from
  somewhere (nothing found yet) so a specific held-back item can be found
  on purpose -- see §12b's open snag.
- Consider finishing the current held-back GridLeak to a genuine 324/324
  and see whether 100%-in-a-category triggers anything worth knowing about.
- Always remember to set Steam offline (or otherwise disable cloud sync)
  before any further save-editing test -- round 1's false negative was
  entirely this, not a real problem with the technique.

**Open questions / next steps, roughly in priority order:**
- Widen the candidate-string dictionary beyond `PlayerProgressionData_full.txt`
  (pull in `RewardsData_full.txt`, `RunnerKitDefinitionsMeta`, achievement
  data, and the mission `MissionDescription` sub-fields) to chase the 8
  unresolved hashes and get closer to 100%.
- Test inserting a brand-new record (not just editing an existing one) --
  needed to grant a currently-never-collected item, which is the direction
  an actual randomizer client cares about most.
- Figure out where the "current" vs the two ID-suffixed
  `ProgressionManagerData*` sections diverge in practice (985 vs 919 vs
  913 records, not byte-identical) -- likely just different snapshots in
  time for different linked accounts, but worth confirming which one the
  game actually treats as authoritative on load.
- The `PROF_SAVE_profile` / `PROF_SAVE_backup_profile` files (1,226 bytes
  each) haven't been looked at yet -- much smaller, probably a slim
  companion/settings file rather than progression data, but unexamined.
- Cross-reference the fully-decoded record list against `ground_truth.json`
  and `dependency_graph.json` (§11) to turn "238 GridLeaks collected" into
  "which 238 of the known 324, by name" -- the pieces to do this all
  already exist, just not wired together yet.

### 12d. Non-collectible coverage -- missions (main AND side) are per-item too, not aggregate totals

Checked what else the save's hash table tracks individually, beyond
collectibles. Short answer: almost everything on the Objectives/World
Progression screen is per-item, and the on-screen totals (e.g. "6/40") are
just the game counting these same granular records -- there is no separate
"aggregate only" stat sitting behind any of them, as far as examined:

- **Story missions**: each has its own `<Mission Name> [Briefing/
  Debriefing]_CompletedTime` record (some split into
  `_CompletedTimestampPart1`/`_CompletedTimestampPart2`, a 64-bit
  timestamp as two u32 halves) -- e.g. `Vive La Resistance
  Debriefing_CompletedTime`, `Savant Extraordinaire_CompletedTime`,
  `Kingdom Debriefing_CompletedTime`. The value isn't a boolean -- looks
  like an elapsed-time/duration stat (values range from teens up into the
  tens of thousands).
- **Opportunity (side) missions**: individually tracked as `OW Opp
  <DistrictCode>Ph<N> <NN>_Available` (currently-available, not yet done)
  and `..._CompletedTime` (done). In the sample save: 34 `_Available` + 6
  `_CompletedTime` = **40 total, 6 done** -- an exact match to the World
  Progression screen's "Opportunity Missions 6/40", confirming the UI
  number really is just `len(done)` over the known total, not a separate
  cached field. A handful also have a `MiscCompleted_OW Opp ...` sibling
  record -- likely a secondary objective within that same mission.
- **Security Hubs**: two families -- `SecurityHubs_<Name>State` (a
  small integer, not just 0/1 -- looks like a tier/stage value, 2 or 4
  observed) and `SecurityHubsCompleted_<HubName>` (a clean boolean, 8
  found in the sample = exact match to the screen's "8/8").
- **Grid Nodes**: `GridNodes_<District>Completed`, one per district.
- **Billboard Hacks**: `HackableBillboards_<zone code>` (uses the same
  district/sub-zone codes solved in §10h), plus a separate
  `Tutorials_TutorialBillboard` for the tutorial one specifically.
- **World-state doors/gates**: `Doors_<name>` -- these aren't objectives
  with a UI counter, but the same per-item boolean pattern covers every
  unlockable door/gate/vent seen in the sample (mission-specific
  shortcuts, area unlocks, etc.) -- potentially useful as additional
  location/event granularity beyond what's shown on any progress screen.

Net implication for the eventual client: the save's hash table isn't
collectibles-only -- it's the general-purpose per-save state store for
basically every trackable piece of progress in the game, at the same
individual-item granularity collectibles get. Combined with §11's
mission/reward/flag graph (which already has real names for all 152
missions) and §9's name resolution, the pieces exist to build a full
location list -- collectibles, main missions, side/opportunity missions,
security hubs, grid nodes, billboard hacks -- from static data, then read
completion state for every one of them from a save file with
`decode_save.py`, with no live game access at all.

## 13. **PROOF OF CONCEPT, CONFIRMED LIVE: save-driven Archipelago hints, end to end**

Built `me_catalyst_hint_bridge.py` (new, in `runtime/`) -- a standalone
Python "HintGame" companion client, same minimal protocol pattern as
`vincenator218/AP---Dino-run`'s dino-runner (`GetDataPackage` -> `Connect`
with `game: ''`, `items_handling: 0`, `tags: ['HintGame', ...]` -> on
trigger, `LocationScouts` with `create_as_hint: true`), just triggered by
ME:C save-file collection events instead of dino-run score milestones. No
browser or local web page involved -- it polls the save file directly
(reusing §12's format/hash logic, shipped with a small precomputed
`gridleaks_hashes.json` so it needs no other static data on the user's
machine) and talks to the AP server itself over its own WebSocket
connection.

Also wrote `clear_category.py` (removes every record for a category
outright across all sections, shrinking + re-padding to keep file size
constant -- the inverse of §12b's `mass_set_collectibles.py`) to produce a
clean 0/324 GridLeaks starting save for a real end-to-end test.

**Tested live against a real Archipelago room: every real GridLeak
collected in-game sent a hint, every time.** This closes the loop this
entire document has been building toward -- static data -> real names ->
live-readable/writable save state -> an actual external system (a
different game's Archipelago connection) reacting to real Mirror's Edge
Catalyst gameplay, with zero live memory access anywhere in the chain.

**Natural next steps, not yet done:** wire up the other collectible
categories (Secret Bags, Electronic Parts, Audio Pickups/Recordings,
Intel/Documents) and non-collectible objectives (missions, security hubs,
grid nodes, billboard hacks -- all named and per-item per §12d) into the
same bridge using the same hash-table pattern; consider smarter location
selection (progression-item weighting like `ap-client.js`'s
`getRandomMissingLocation`, rather than uniform random); reconnect/backoff
resilience for longer unattended runs.

## 14. Cross-referenced against `ploxxxy/frostnibble` (credit: Meteor) -- header format + checksums fully pinned down

Meteor linked a pre-existing web-based PROF_SAVE editor,
[ploxxxy/frostnibble](https://github.com/ploxxxy/frostnibble) (React +
TypeScript, `src/lib/{reader,writer,save-file,crc32}.ts`). It targets the
exact same file format §12 reverse-engineered independently -- its magic
constant `6001977056592872006n` read as 8 little-endian bytes decodes to
literally `FBCHUNKS`, confirming both projects arrived at the same format
from different directions. Reading `save-file.ts`/`writer.ts` (not yet
looked at when §12/§13 were written) filled in two things our own tooling
had left as open questions: the exact header layout, and the two CRC32
checksums it carries that our write tools weren't computing.

**Full header, byte-exact (offsets from file start):**

| Offset | Size | Field | Notes |
|---|---|---|---|
| 0 | 8 | magic | `"FBCHUNKS"` |
| 8 | 2 | version | `1` in every save seen |
| 10 | 4 | headerSize | `8` in every save seen |
| 14 | 4 | bodySize | `file_size - 26`; a fixed 1,024,000-byte capacity in every save seen (so total file size is always 1,024,026) |
| 18 | 4 | **headerHash** | see below |
| 22 | 4 | headerEntries | section count -- `13` in every save seen |
| 26 | 4 | **bodyHash** | see below |
| 30 | — | entries begin | `headerEntries` sections, each `u32 count` + that many `[type][key][value]` records |

This refines §12's "flat sequence of blocks starting at offset 46" model:
entries actually start at **offset 30**, as exactly `headerEntries` (13)
fixed sections in a row, each individually prefixed with its own record
count. In every save examined, sections 0-3 are empty (`count = 0`,
4 bytes each = 16 bytes, landing at offset 46 -- which is why our
own block-scanner, starting its search at 46, never noticed anything was
missing: it just happened to find the first non-empty section there).
Sections 4-7 hold the real data (one of them, with ~700 KV entries, is
where the three `ProgressionManagerData*` binary blobs live); sections
8-12 are empty again. Doesn't change anything about how `decode_save.py`
et al. read/patch records -- it just explains *why* 46 worked as a
starting point, and confirms the section count itself never needs to
change for anything our tools currently do (we only add/remove records
inside already-occupied sections, never whole sections).

**The two checksums, and the custom CRC32 they use:**

Both `headerHash` (offset 18) and `bodyHash` (offset 26) use a
non-standard CRC32 variant: the ordinary CRC-32 polynomial/table, but
seeded with `0x12345678` instead of the usual `0xFFFFFFFF`
(`frostnibble`'s `crc32.ts`: `let C = ~INITIAL; ...; return ~C`). That is
*exactly* Python's `zlib.crc32(data, 0x12345678)` -- `zlib.crc32`'s
second argument is the running/starting CRC and already does the
invert-in/invert-out bookkeeping, so no manual bit-flipping needed:

```python
import zlib
def custom_crc32(data: bytes) -> int:
    return zlib.crc32(data, 0x12345678) & 0xFFFFFFFF
```

- `headerHash = custom_crc32(struct.pack("<I", headerEntries))` -- CRC32
  of just the 4 little-endian bytes of the section count.
- `bodyHash = byteswap32(custom_crc32(data[30:end_of_file]))` -- CRC32 of
  everything from the first entry onward (all sections + all zero
  padding, i.e. offset 30 through EOF), written into the file **byte-swapped**
  (`frostnibble` calls `swapEndian()` on it before writing, but not on
  `headerHash`).

**Verified byte-for-byte** against the sample `PROF_SAVE` bundled in
`frostnibble`'s own repo (`public/assets/PROF_SAVE`): computed
`headerHash` and `bodyHash` both matched the file's stored values exactly
using the formulas above. This is about as confirmed as a reverse-engineered
checksum gets.

**Practical implication for our write tools:** `patch_save.py`,
`mass_set_collectibles.py`, and `clear_category.py` never touched either
checksum -- every edit they made left `bodyHash` stale (it covers all the
entry data, which those tools modify) while `headerHash` stayed valid
(section count never changes). And yet every one of §12a/§12b/§12c/§13's
live in-game tests worked perfectly on saves with a stale `bodyHash` --
counter changed correctly, a real GridLeak vanished from the world, the
100%-completion RunnerKit reward fired, hints sent live over a real AP
connection. So Mirror's Edge Catalyst does **not** appear to hard-enforce
`bodyHash` at load time (at least not to the point of rejecting or
resetting a save) -- but since it costs nothing to keep correct (and a
future patch, or Steam Cloud's own integrity checks, could start caring),
added a small shared helper, `save_checksum.py` (new, in `runtime/`), and
wired `recompute_checksums()` into all three write tools right before
they write their output. Nothing else about how those tools work changed.

**One more thing worth a note:** `frostnibble`'s `Entry.typeString` lists
a type `3 = "Long"` alongside the four we'd already observed (1=Float,
2=Integer, 4=String, 5=Binary) -- we haven't seen a real `type=3` record
in any save examined yet, but it's evidently a valid tag in the format,
worth keeping in mind if a not-yet-understood record ever turns up with
it. Separately, `frostnibble`'s `PlayerTagEditor.tsx` decodes one
particular string-type entry as JSON (`{"tagData":{"bg":{"tag":<hash>},
"detail":{"tag":<hash>},"frame":{"tag":<hash>}}}`) holding the player's
emblem/card cosmetic choices (background/detail/frame, each a numeric
hash matched against a hardcoded list of ~140 cosmetic asset names) --
purely cosmetic, out of scope for a progression randomizer, but confirms
the save format is used for more than just progression flags and that at
least one entry's "value" is itself a nested JSON document rather than a
flat number/string.
