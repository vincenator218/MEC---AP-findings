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

**Correction, added later (§19-adjacent): round 1's "Steam Cloud"
diagnosis above was wrong.** Retested much later with Steam online (not
offline) on a game-closed edit, and the edit held fine -- no cloud
reversion. Round 1's actual cause is now believed to be a mis-executed
command on that very first attempt (a mis-paste), not cloud sync fighting
the write. Combined with §15/§15a/§15b's later, much more rigorous
finding (a *running* game session never re-reads the save file at all,
completely independent of Steam's online/offline state), the honest
conclusion is: **Steam Cloud sync has never actually been shown to
interfere with a save edit in this entire project.** The "set Steam
offline first" caution baked into some tool docstrings below predates
this correction and is stricter than necessary -- harmless to keep doing,
but not something a receive-item design needs to rely on or automate
around.

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

**Correction (later):** that's wrong. This save had **all 324** GridLeaks set, across
every district, so the reward "Collect every gridLeak in Glass" means the whole city
(Glass), not the Construction group. The group sums in §10h stand:
`ConstructionGridLeaks` = Rezoning (Omnistat Tunnels 24 + Development Zone 50 = 74).

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

## 15. Open concern: does a live game session ever re-read the save file, or only reload it?

Raised directly: if a future AP client wants to *grant* a received item
mid-session by writing into the save file, will the already-running game
actually notice? Worth being precise about what §12/§13 actually showed,
because the two directions aren't equally proven:

- **Game -> file, confirmed continuous, no special trigger needed.** §13's
  hint bridge polls the save file every few seconds *while the player is
  actively playing* and picks up every new collection in near-real-time --
  so the running game does write per-item state out to disk during live
  play, not just at an explicit "Save Game" menu action.
- **File -> game, only confirmed at a load boundary, not proven mid-play.**
  Re-reading §12b's own wording closely: the disappearing GridLeak was
  observed "the moment **the edited save loaded**" -- i.e. there was a
  load event (the player swapped the file in, then continued/loaded the
  save) between the edit and the effect. Every other confirmed write test
  (§12a's counter drop, §12c's RunnerKit drop) followed the same
  edit-then-load pattern. **None of them tested editing the file while an
  already-running session just kept playing, with no menu/reload/respawn
  in between.** So "will a live session pick up an external edit with zero
  trigger at all" is genuinely untested, not confirmed -- and the more
  likely architecture (common in this kind of engine) is that progression
  state gets loaded into memory once at a load boundary and only flows
  memory-to-disk from there, not the other way, until the next load.

**Why this matters for "receive item mid-game":** if that guess is right,
writing a newly-received item into the save file while the player keeps
playing uninterrupted would do exactly what the concern predicts --
nothing, until *something* forces the game to reload progression state
from disk. The open question is how cheap that "something" is. Candidates,
cheapest to most disruptive, none tested yet:
1. Opening/closing the pause menu.
2. A checkpoint respawn (dying, or using an in-game "reset to checkpoint").
3. Crossing a district/zone streaming boundary (this is an open-world
   Frostbite game -- streaming loads happen constantly as you move, and
   might carry a partial resync with them).
4. Fully reloading the save from the main menu.
5. Fully restarting the game process.

**Save file location, confirmed:** `Documents\Mirrors Edge Catalyst\settings\PROF_SAVE` (previously unconfirmed/guessed at in this doc).

**Suggested next test, cheap and conclusive:** with Steam offline, start a
session, note a specific not-yet-collected item, then *while staying in
that same session* edit the save to mark something new as collected/
granted -- but this time deliberately test the candidate triggers above
one at a time (just keep walking first and confirm nothing changes; then
try opening/closing the pause menu; then try a checkpoint respawn; then a
zone transition) rather than going straight to a full save-reload like
every test so far has. Whichever is the *cheapest* trigger that actually
works is the one a receive-item flow should lean on -- e.g. if a pause-menu
open/close is enough, a companion tool could plausibly even simulate that
input automatically after writing a new item; if only a full relaunch
works, a receive-loop instead has to queue items and tell the player
"restart to receive," which is a materially worse experience worth knowing
about now rather than after a client is built around the wrong assumption.

### 15a. Ran the test. Result: a live session overwrites an external edit with its own stale state -- and this surfaced a real checksum bug as a side effect.

With Steam confirmed offline, mass-set all 324 GridLeaks to collected
while the game was already running, then walked through the trigger
ladder: standing still, pause menu open/close, a checkpoint respawn, a
zone transition, and an explicit Load/Continue -- **none of them showed
any change.** Collected one real GridLeak manually along the way (it was
still there and pickable, confirming none of the lighter triggers had any
effect up to that point), then did a full quit and relaunch as the final
step. **Still no change -- World Progression GridLeaks stayed at the
original baseline**, not the expected 324/324.

This breaks the pattern of every earlier confirmed write test (§12a-§12c),
which all worked. The difference this time: the game process was left
*running* through the entire edit, instead of being closed first. Checked
what was actually on disk afterward with `save_checksum.py`, and its
`bodyHash` no longer matched what our own tool had written -- **direct
proof the file was rewritten by something else after our edit**, since
nothing else in this pipeline writes that field. The most likely
mechanism: the already-running game process holds its own complete
in-memory copy of progression state, loaded *before* the file was edited.
Collecting the GridLeak manually got tracked against that old in-memory
copy, and at some point (the manual collection's own write-out, an
autosave, or the quit itself) the game wrote its **entire** in-memory
state back to disk -- silently overwriting all 323 externally-inserted
records with the stale pre-edit picture, before the "reload" ever had a
save reflecting our edit to actually load. Steam Cloud was ruled out
(confirmed offline throughout), so this looks like the real explanation,
not a repeat of §12a round 1's confound.

**Practical fix for testing (and a real constraint for any future receive
design):** the game must be **fully closed, not just at a menu**, before
externally editing the save -- otherwise a live process can and will
clobber the edit with its own state at its next write-out. Every earlier
successful write test (§12a-§12c) was, in hindsight, very likely done with
the game not actively running through the edit -- which is exactly why
they worked and this one didn't. This doesn't yet answer whether an
*already-launched* session can ever be made to pick up new state without
a full relaunch -- it just rules out "edit while it's running and hope" as
a way to test that.

**Side effect: this exposed a real bug in §14's checksum formula.**
Comparing the stored (post-overwrite, game-authored) `bodyHash` against
what our tool would compute revealed they differed by exactly a 4-byte
reversal -- i.e. our formula's byte-swap was backwards. Checked directly
against the project's two *original* save files (`PROF_SAVE` and
`PROF_SAVE_backup`, uploaded early in this project, never touched by any
of our tools or by `frostnibble`'s editor): both have `bodyHash` stored as
the **plain, un-swapped** CRC32 -- exactly matching what the game had just
written, and *not* matching §14's swapped formula (copied from
`frostnibble`'s `writer.ts`, which applies a `swapEndian()` before writing
that its own `reader.ts` never undoes on read -- an asymmetric bug in
their code, harmless for their own round-trips since they never diffed
against a real game-authored save, but not something to propagate).
Confirmed the `frostnibble`-bundled sample save §14 validated against
*does* need the swap -- meaning that specific sample file had itself been
through `frostnibble`'s own writer at some point, not a pristine
game-authored save; the two original uploads settle which convention the
real game actually uses.

This also retroactively identifies an old, never-resolved loose end: an
early raw byte sequence `e95dbf3f`, noted in this project's early
exploration but never identified. That's the byte-swapped misreading of
this exact `bodyHash` field (`0x3fbf5de9` reversed) -- a small, satisfying
bit of closure.

**Fixed**: `save_checksum.py`'s `recompute_checksums()` no longer applies
any swap to `bodyHash` -- it's now `custom_crc32(data[30:])` directly,
matching `headerHash`'s already-correct plain formula. Re-verified against
both original save files (now `OK`/`OK`) and against `frostnibble`'s
bundled sample (now correctly reports a `bodyHash` mismatch, as expected
for a file carrying their write bug).

### 15b. CONFIRMED -- editing with the game fully closed, then launching, works. The open question from §15/§15a is answered.

Redid the test properly: closed the game completely, ran
`mass_set_collectibles.py` against the live `PROF_SAVE` (writing directly
back to the same path -- confirmed safe, since the tool reads the whole
input into memory before it writes anything) with the game **not
running**, then launched fresh and loaded the save.

**Result: World Progression read 324/324 GridLeaks.** The edit stuck.

This closes the loop §15 opened and §15a partially answered:

- A **live, already-running** game session will *not* pick up an external
  save edit, and will actively overwrite it with its own stale in-memory
  state at its next write-out (§15a) -- confirmed by directly testing it
  and watching it fail.
- Editing while the game is **fully closed**, then launching, reliably
  works -- confirmed by directly testing it and watching it succeed,
  cleanly, no ambiguity.

**Practical conclusion for a receive-item design:** granting an item by
writing into the save file only reliably works when the game process is
not running at the time. The safe pattern for a future client: queue
received items, write them into the save while the game is closed (or
between sessions), and have them show up the next time the player
launches -- not attempt to inject them into an already-running session.
Whether some in-game action can force an already-running session to
safely reload from disk without stomping its own concurrent progress
remains untested and would need a different kind of experiment (see the
narrower open items still listed below) -- but "close, edit, launch" is
now a fully confirmed, reliable mechanism on its own, which is enough to
build a first working receive-path around.

**Quick follow-up, opposite direction:** re-ran the live-edit test with the
game open, this time using `clear_category.py` to strip all 324 GridLeak
records out entirely (rather than inserting "collected" ones) -- same
result as §15a: no change in-game, GridLeaks count stayed put, nothing
reappeared. Confirms this isn't specific to insertion; a live session
ignores external edits in both directions (add or remove), consistent
with the "the running process's own in-memory state is authoritative
until the next load" explanation.

## 16. Time trial results are not in this save format; and a new clue on which `ProgressionManagerData*` section is live

Asked directly: are individual Time Trials tracked per-item like GridLeaks
(e.g. a per-track star rating or best time)? Checked three ways before
testing live: the resolved 99% of the save (nothing shaped like it --
only two unrelated tutorial flags, `GameContentTutorials_HaveEditedTimeTrial`
and `SystemTutorials_BeenShownTimeTrialInfo`), the small number of
still-unresolved hashes (8 total, same 8 across all three sections, none
of their values fit a 1-3-star or per-track pattern), and the static game
data (`PamplonaLayerInclusionTable_full.txt` has a `TimeTrialTrackId`
field, but it's a world-streaming-layer criterion listing track IDs 1-8,
not a results structure).

**Confirmed empirically, not just guessed:** completed a real time trial
in-game, then diffed the save against the pre-completion snapshot.
**Zero new records and zero changed values attributable to the time
trial.** The only diffs were from an actual Audio Pickup collected along
the way (`AudioPickupGridLeaks_AudioPickup_NoahIcarus_5`, plus its
matching `Collectables_GreenOrbsCollected`/`GreenCollectiblesStory_IcarusNoah`
counters) and the in-game clock advancing (`TimeOfDay_CurrentTime`).
**Conclusion: Time Trial results are not stored in this save format at
all** -- almost certainly server-side (an EA leaderboard/ghost-time
system), which would explain their total absence here.

**Side finding, useful for an open question:** of the three
`ProgressionManagerData*` sections, only `ProgressionManagerData_2411670393`
picked up any of this real gameplay (the Audio Pickup collection, the
clock, `Collectables_OrbsCollected` jumping to 324 reflecting the earlier
GridLeak edit) -- the other two sections showed no changes at all since
the last edit. That's a real, if not yet conclusive, data point toward
"which section is authoritative" (still open, see below): worth
specifically watching `_2411670393` in future tests as the more likely
candidate for the live/authoritative copy, though this is one observation,
not a controlled test.

**Second confirmation, different trial:** completed "The Scenic Route"
(new best time 01:58:89, 1 star) and diffed again -- same result, zero
records added or changed that relate to it (the only diffs were an
unrelated movement-tutorial counter, the clock, and a combat pickup). The
in-game result card also displayed a name ("King_Dalapa") alongside the
time and stars -- reads like an online account/leaderboard identity, not
anything sourced from the local save, which lines up with the
server-side-leaderboard conclusion above. Two different trials, same
negative result, both times the only section that changed at all was
again `ProgressionManagerData_2411670393` -- reinforcing the §16
observation on which section stays live during real play.

## 17. Randomizer design idea: skip the story, gate movement/combat abilities as AP items, use time-trial-route electronics as checks

Your proposal: don't bother tracking story missions as AP content at all --
ship a starting save with the story already marked complete (so the whole
map, fast travel, security hubs etc. are open) but with none of the
movement/combat ability unlocks granted, then have Archipelago items grant
those abilities one at a time. Time Trials (which the game already
naturally gates behind completed abilities/movement) become the
"content" the player replays for enjoyment, and since individual
completions/times aren't save-tracked (§16), use the Electronic Parts
that happen to sit along trial routes as the actual location checks
instead.

**The ability system exists exactly as described, and it's a real,
sizeable item pool.** Static data has a `Unlocks_*` flag family -- 58
distinct names, covering movement (`Unlocks_DoubleWallrun`, `FastClimb`,
`ExtendedSlide`, `Shift`/`ShiftFluency`, `QuickTurn`,
`SkillWindowSkillRoll`/`Springboard`/`WallClimb`, `StartBoost`, `Focus`
and its tiers) and combat/health tiers alongside them. Confirmed live in
your own save: 34/58 already unlocked, 24 still locked -- direct proof
these are independently tracked per-flag booleans, stored exactly like
every other record in this table (`{hash, name, value}`). They're
readable and writable with the tools that already exist -- `patch_save.py
--name Unlocks_DoubleWallrun --value 0` works today, no new code needed
for a single flag; a small bulk-set/bulk-clear helper (same shape as
`mass_set_collectibles.py`) would be a few minutes of work if bulk
locking/unlocking all 58 at once is wanted.

**The currency behind them, also confirmed:** `XP`, `XP_Gained`, and
`XP_Used` -- in the reference save, `81952` gained / `29000` spent. This
matches the described mechanic exactly (points earned from missions/side
missions, spent at will in a skill tree) rather than any single mission
directly granting a specific ability -- with one confirmed exception,
**the grapple hook is hard story-gated**, tracked separately as
`CriticalPathProgression_HasCollectedMagRopePullDown/PullUp/Swing/LineConnector`,
distinct from the general `Unlocks_*` list (makes sense narratively -- you
need it to physically progress the critical path, so it can't be
optional).

**What this means for the "ship a save" plan, concretely:** mark story
missions complete, leave every `Unlocks_*` flag unset, and either zero or
cap `XP_Gained`/`XP_Used` so the player can't just open the skill menu and
buy every ability immediately after booting the save -- the abilities only
existing as AP-grantable items depends on the player not having free
points sitting there to spend on their own. Two things this idea still
needs a live test to confirm (nothing found in the static reward data
settles them either way):
- Does forcing every mission's `_CompletedTime` flag actually leave the
  `Unlocks_*` flags alone, or does something at load time recompute/grant
  them based on mission state? (The reward data mined so far only shows
  `Unlocks_*` flags used as *conditions* for cosmetic RunnerKit rewards,
  never as something a specific mission's completion directly sets --
  which is a good sign, but isn't the same as watching it happen live.)
- Does removing a currently-*true* `Unlocks_*` flag (e.g. on this
  reference save, which already has 34 of them) actually disable that
  ability in-game, the same way §12b confirmed GridLeaks' flag controls
  the physical object? This is the same kind of test already run
  successfully for collectibles, just not yet run for this category.

**On using electronics as the check substitute for time trials:** sound
plan, since it sidesteps §16's dead end entirely by using a category
that's already fully save-tracked (`ElectronicPartsXxYy_ChipNNTaken`,
confirmed per-item since early in this project). The one gap: this
project has no world-coordinate data for anything, so which specific
chips sit on which specific trial routes isn't something the save or
static data can answer -- that mapping can only come from actually running
each route and noting what's there.

**Also investigated: intercepting the game's own network traffic**, since
its online services are confirmed shut down (EA, December 8 2023) and the
in-game leaderboard now only ever shows the local player. There's a real,
active community effort around exactly this for this specific game:
[Beat Revival](https://github.com/Beat-Revival) reroutes the game's
requests to a local server (Docker-based), currently restoring
achievements only; [`ploxxxy/pamplona-future`](https://github.com/ploxxxy/pamplona-future)
(same author who linked `frostnibble` via Meteor) was explicitly working
toward Time Trials, Dash leaderboards and Beat L.E. support but is now
archived/obsolete; its active successor
[`grid-leak/blaze`](https://github.com/grid-leak/blaze) reimplements EA's
"Blaze" backend protocol in Rust, currently handling session/auth/config
but explicitly not yet leaderboards or time trials. None of these have
published the actual time-trial wire format -- but the infrastructure to
redirect the game's connection to a capturing proxy is proven to work
(it's how achievements got fixed), so standing one up ourselves and
watching what the game tries to send on a time-trial completion is a
real, viable next step if it's worth pursuing. It's a genuinely separate
kind of project from everything else here, though (Docker/Rust tooling,
DNS or hosts-file redirection, a real MITM setup) rather than an extension
of the save-file tools -- worth treating as its own track rather than a
quick add-on.

## 18. Reconciling the in-game skill-tree screenshot against the 58-flag `Unlocks_*` catalog -- and a real (but ultimately dead-end) lead on where a category tag might live

The skill-tree UI screenshot shows: `OFFLINE MODE`, `UPGRADE POINTS
27,666 / 28,000 XP`, and three tabs -- **Movement 19/19**, **Combat
18/20**, **Gear 11/11** -- 50 nodes total across the three tabs, against
the 58 raw `Unlocks_*` flags §17 found in static data. (One example node
shown in full: "Free Running 2," keybind Left Ctrl, "slide, crawl under,
or slide down obstacles and through small openings" -- consistent with
the `Unlocks_ExtendedSlide`-style movement flags already catalogued.)

That 27,666/28,000 figure is very likely progress *toward the next
point*, not the same cumulative total as the `XP_Gained=81952` seen
in an earlier save snapshot -- those are two different numbers (one a
running total, one a per-point meter) and shouldn't be read as
contradicting each other.

The 50-vs-58 gap (8 flags) is still best explained the same way as
before -- by flag name, not by a confirmed static-data tag -- as the 5
`IncreasedHealth0`-`IncreasedHealth4` tiers plus `ScavengeLevel`,
`CombatScavengeLevel`, and `Placeholder`: none of those read as a
discrete unlockable *move* the way every other flag name does, so
they're the most likely candidates for stat-only/hidden flags that
don't get their own skill-tree icon.

**Went looking for an explicit category/tab tag to confirm this rather
than just infer it from names**, and found something structurally
promising, then it fell through:

- `PlayerProgressionData`'s schema has a real grouping construct,
  `PamProgressionFlagGroup` (`Name`, `NameHash`, and a `Flags` list of
  refs to `PamProgressionFlag`/other entries) -- exactly the shape a
  Movement/Combat/Gear breakdown would need. There are 124 of these
  group instances in the static dump.
- One of them is literally named `'Unlocks'` (guid
  `7429b7eaf477854caeb1decf691ad093`) and its `Flags` list has almost
  exactly the right count (~58 entries) -- looked like a direct hit.
- It isn't, on closer inspection: that list mixes `PamProgressionFlag`
  refs with several `PamProgressionMission` refs, which the 58-flag
  ability catalogue never included -- so this "Unlocks" group is a
  broader **online-stat-sync bucket** (its own fields,
  `SyncSumOfFlagValuesToOnline`/`ForceSyncAllFlagsToOnline`, only make
  sense for something reporting to EA's now-dead backend), not the
  client-side skill-tree UI's tab grouping.
- Every other `PamProgressionFlagGroup` name in the dump is a
  collectible/mission/system category (`DowntownGridLeaks`,
  `SecretBagAcEv`, `SystemTutorials`, `CriticalPathProgression`, etc.) --
  none named or shaped like "Movement"/"Combat"/"Gear".

**Conclusion: the Movement/Combat/Gear split is a front-end/UI concept
that isn't encoded anywhere in this EBX config dump.** It's almost
certainly defined in localization/UI layout data this project hasn't
pulled (icon layout tables, menu definitions) rather than in
`PlayerProgressionData` alongside the flags themselves. The
health-tiers-plus-three-misc-flags mapping for the 8-flag gap stands as
the best available answer, but stays a name-based inference, not a
confirmed static-data fact -- flagged here rather than quietly upgraded
to "confirmed."

## 19. **CONFIRMED LIVE -- clearing an already-true `Unlocks_*` flag disables the ability in-game.** Last open test from §17/§18 is settled.

Ran it exactly like the GridLeaks test (§12b), just in the other
direction and on an ability flag instead of a collectible: game fully
closed, `patch_save.py --name Unlocks_ExtendedSlide --value 0` writing
directly back over the real `PROF_SAVE`, then a fresh launch.

Two independent signals both confirm it took effect:

- **The Progression menu's owned-count changed.** Before the edit,
  Movement showed `19/19` (§18's screenshot). After, it shows `18/19` --
  a direct, unambiguous drop of exactly the flag that was cleared. This
  is the game re-deriving its own UI state from the save at load time,
  not something we're reading into a static screenshot.
- **The actual move changed in gameplay**, in exactly the way the
  tooltip predicts rather than in some vague "it's gone" way: Extended
  Slide's description is "+ Slide distance -- reduces deceleration in a
  slide, increases the distance before Faith transitions to a crawl."
  With it cleared, the base Slide move still works (you can still slide
  under things), but it doesn't carry as far / transitions to a crawl
  sooner -- which is exactly what removing a *distance modifier* on top
  of an always-available base move should look like. Nothing broke,
  nothing crashed, no attempt to "give it back."

This is an important nuance for the item pool, not just a pass/fail: not
every `Unlocks_*` flag gates a whole move from nonexistent to existing --
some (like this one) gate a base move's *unlocked-vs-upgraded* version.
The tiered-looking names already noted in §17 (`Focus` /
`Focus_ReachFlow_Increase` / `Focus_ReachFlow_IncreaseExtra`, the
`FlowAttack`/`FlowAttack_PowerAttack`/`FlowAttack_Special_PowerAttack`
family, `ImpactAttack_PowerAttack`/`_Special_PowerAttack`) are very
likely the same pattern -- a base move plus one or two upgrade flags on
top of it, rather than three independent moves. Worth keeping in mind
when designing item "impact" for AP: a base-move flag (no game feature
exists without it) and an upgrade-tier flag (the feature already works,
just weaker) are different weights of item, even though both are
mechanically identical `patch_save.py` edits.

**Combined with §15b (closed-game edits load correctly, live-session
edits don't) and §12b (the same test already passed for a collectible
category), this closes out every open item from §17/§18's design-viability
list except one:** whether forcing mission-completion flags to "done"
leaves `Unlocks_*` flags alone at load time, or whether something
recomputes/grants them. That's the one remaining test before the
ability-gating randomizer design can be called fully proven end to end.

## 20. **CONFIRMED -- no mission-completion cascade. The ability-gating design is now proven safe end to end.**

Built `clear_all_unlocks.py` (new, in `runtime/`): clears every one of the
58 known `Unlocks_*` names at once, in place, no resize -- same safe
pattern as `patch_save.py`, just batched. Verified in-sandbox against your
last uploaded save before shipping it (all 34 currently-true flags found
and zeroed across all 3 sections, checksums OK).

Ran it for real: game closed, cleared all 34 currently-true flags,
launched, played a real session with missions left exactly as already
completed (nothing fabricated). Progression menu showed Movement 10/19,
Combat 2/20, Gear 5/11 -- down substantially from 18/19, 18/20, 11/11, but
not all the way to zero, which needed settling one way or the other
before calling this safe.

**Settled it by diffing the actual save file, not the UI.** Uploaded the
post-session save and compared every single record against the pre-clear
save: only 35 keys differ in the whole file. 34 are exactly our edit,
still sitting at `0` -- not one came back. The 35th is
`TimeOfDay_CurrentTime`, the in-game clock, unrelated. No records were
added or removed anywhere.

**Conclusion: clearing `Unlocks_*` flags is stable through real
gameplay and real mission progress -- nothing recomputes or re-grants
them at load or during play.** This was the last open item from §17/§18/§19's
design-viability list. Combined with §15b (closed-game edits load
correctly) and §19 (clearing an already-true flag does disable the
ability, both signals: menu count and actual physics), the full
ability-gating design -- ship a save with the story finished and every
`Unlocks_*` flag unset, then grant them one at a time as AP items -- is
now proven viable end to end, with every step backed by an actual live
test rather than an inference from static data.

**Open, but lower-stakes: the 17 nodes (10 Movement/2 Combat/5 Gear) that
stayed "owned" even with every `Unlocks_*` flag cleared.** Since the save
diff shows nothing else changed, these aren't cascade-granted -- they
were never gated by any of the 58 known flags to begin with, and are
presumably a handful of baseline moves the game always displays as
available regardless of save state. Not a threat to the design (they
just wouldn't be usable as gate-able AP items themselves), but worth
identifying eventually -- likely candidates are basic moves like the
starting Roll/Slide/Wallrun/block that a fresh, unmodified new save would
also show as owned, though that hasn't been confirmed against an actual
fresh save.

## 21. A community "100%" save, decoded and cross-checked -- the real `Unlocks_*` pool is 34, not 58

Checked a heavily-completed community save file (checksums valid, decoded
cleanly, 1400-1500+ records per section vs ~1050-1075 in your own save).
Collectibles confirm it's genuinely close to fully finished: **GridLeaks
324/324** (exactly matching the known total from §12), Electronic Parts
251/252, Audio Pickups 45/45, Secret Bags 40/41, Intel 79/81, Green Orbs
80/99 -- not literally perfect in every category, but unambiguously an
end-game/near-completionist save, good enough as a real ceiling reference.

**The important result: only the same 34 `Unlocks_*` names that exist in
your own save exist here too -- none of the other 24 static-data-catalogued
names ever appear as a record, at any value, in either save.** And
`XP_Used` is `29000` in both saves, identical down to the number --
exactly the same total spend on exactly the same 34 abilities.

That's not a coincidence between two unrelated saves. It's strong
evidence that **34, not 58, is the real ceiling for what a normal single
playthrough can ever unlock.** The other 24 names in
`PlayerProgressionData` (`IncreasedHealth3`/`4`, `SkillWindowSpringboard`,
`SkillWindowWallClimb`, `StartBoost`, `ShiftFluency`, `ImpactMomentum`,
`HardLandingLowDrain`, `LowDrainAtLowSpeed`, `LowDrainInFlow`,
`CombatFluency`, `CombatReticle`, `GetSpeedAttack`, `BreachDoors`,
`CityAlertDisrupt`, `CityAlertSafePositions`,
`Disrupter_Increase_AngleOfEffect`, `Disruptor_Extra_Battery`,
`ScavengeLevel`, `CombatScavengeLevel`, `Placeholder`, and the three
`SkillMoveInvulnerabilityLevel0/1/2`) are very likely unused/vestigial,
gated behind something a normal playthrough never reaches (New Game+?
a difficulty tier? cut content?), or simply never wired to any purchase
path at all -- not a gap in either save, a gap in the feature.

**This changes the AP item-pool math for the better: it's a clean,
already-fully-reachable 34-item pool, not a 58-item pool where a third of
the items might be unobtainable no matter what the player does.** Doesn't
change anything about §19/§20's viability conclusions -- gating and
clearing these flags is already proven safe -- just makes the practical
pool size a confirmed fact instead of an assumption.

Still open: a genuinely fresh, brand-new save is the one thing that would
settle the remaining §18/§20 question (which of the 50 UI tree slots, and
which of these 34 flags, are true from the very start vs. actually
earned) -- the 100% save answers "what's the ceiling," not "what's the
floor."

## 22. A full 17-checkpoint story save set -- real per-mission unlock timeline, and the missing mechanism finally explained

Found a community save collection: one `PROF_SAVE` per story mission,
`0percent00Birdman` through `0percent16TheEnd` (named for 0% *missable
collectibles* at that checkpoint, not 0% progression -- all 17 checksum
clean, all decode cleanly).

**First pass used the wrong section and gave a misleading "nothing ever
changes" read -- caught before reporting it.** Each of these files has
only *two* `ProgressionManagerData*` sections, and they tell completely
different stories: one (plain key `ProgressionManagerData`, ~900+
records) is frozen at 32 `Unlocks_*` flags and `XP_Used=27000` in every
single one of the 17 files -- a stale, pre-built donor/template slot that
never gets touched. The other (key
`ProgressionManagerData_1000106553270`, starting at just 57 records) is
the real one: its record count climbs steadily (57 -> 373) and its
`XP_Used` climbs in step with real mission progress (1000 -> 2000 ->
3000 -> 6000 -> 8000 -> 12000) across the 17 checkpoints. That's the
authoritative section for this save -- exactly the "up to 3 sections,
one per linked platform, and they can legitimately disagree" note from
`patch_save.py`'s own docstring, now seen directly.

**Re-ran the diff against the correct section and got a real, clean
per-mission unlock timeline** (flags only ever added, never lost, across
all 17 missions):

| Checkpoint | Unlocks total | XP_Used | Newly true this mission |
|---|---|---|---|
| Birdman | 5 | 1000 | Focus, Glove, HandToHandCombat, MoveEnemyAttack, Shift |
| Old Friends | 6 | 2000 | QuickTurn |
| Be Like Water | 7 | 2000 | FlowAttack |
| Back In The Game | 7 | 2000 | -- |
| Mischief Maker | 8 | 3000 | SkillWindowSkillRoll |
| Savant | 8 | 3000 | -- |
| Gridnode | 8 | 3000 | -- |
| Benefactor | 8 | 3000 | -- |
| Fly Trap | 11 | 6000 | Coil, DoubleWallrun, FastClimb |
| Sanctuary | 11 | 6000 | -- |
| Encroachment | 11 | 6000 | -- |
| Viva La (Resistance) | 13 | 8000 | Disruptor_StunHumans, ExtendedSlide |
| Payback | 13 | 8000 | -- |
| Prisoner X | 13 | 8000 | -- |
| Kingdom Come | 17 | 12000 | Disruptor_Overload, Disruptor_StunMech, Focus_ReachFlow_Increase, LowerHealthProtector |
| Tickets Please | 17 | 12000 | -- |
| The End | 17 | 12000 | -- |

**This finally explains the mechanism behind §20's result, instead of
just confirming it empirically.** `PamProgressionFlag` in the static
schema has a `.MissionIndex` field -- each ability has a story-progress
gate on when it becomes *purchasable*, separate from whether it's been
purchased. Missions unlock *availability* (new nodes appear as spendable
in the tree once you've reached that point in the story); they never
grant the flag directly. The actual `value: 0 -> 1` flip only ever
happens two ways: the player spending XP in the menu (the real game's
only in-game path), or a tool like ours writing the record directly. That
is exactly why §20's test came back clean -- there was never a mechanism
by which finishing a mission could re-buy something on its own, in this
game or through our edits.

**Caveat on this data:** this checkpoint set isn't a truly blank-slate
new game either -- even the first file (`Birdman`) already has
`GoldCompleted_Release` and `GoldCompleted_Reunion` true, meaning the
prologue's first two missions are already done and 5 abilities already
bought before "Birdman" even starts. So it doesn't answer the exact
"floor" question a truly fresh save would (still open, per §21) -- but it
answers a more useful question instead: the real order and pace a normal
playthrough naturally acquires these abilities in, which is genuinely
useful reference data for pacing an AP item pool (e.g. `HandToHandCombat`
and `Shift` this early confirms they're basically starting-kit moves in
vanilla play, while `Disruptor_Overload`/`Focus_ReachFlow_Increase` don't
even become purchasable until near the end of the story).

## 23. **The floor, finally confirmed: a genuinely fresh save has ZERO `Unlocks_*` records at all**

Got a real one this time -- a brand new game, saved one second after the
first cutscene. Checksums valid, decodes clean.

It has **four** `ProgressionManagerData*` sections, not the usual 2-3 --
and three of them (`ProgressionManagerData_2380105275`,
`ProgressionManagerData_2348898310`, and plain `ProgressionManagerData`,
1441-1512 records each) turned out to be **byte-for-byte identical** to
the community "100%" save decoded in §21. Not similar -- identical, every
record. That's not a coincidence; it means those three slots are stale
leftovers from having that downloaded file present in the settings
folder at some point, sitting in unused linked-account slots that a new
game doesn't reset. The fourth section, `ProgressionManagerData_2411670393`,
is the real one -- same exact key name §16 already flagged as "the one
that shows real gameplay changes" in this same player's other saves,
now confirmed brand new with only **14 records total**.

**All 14 of them, in full:**
`Collectables_TotalGreenOrbCount=45`, `Collectables_TotalOrbCount=324`,
`Collectables_TotalCombatDropCount=50`, `Collectables_TotalIntelCount=42`
(static per-region totals, not progress), `Global_SafeSpawnAllowedOnMission=1`,
`Global_DisableAbortMenuOption=1`, `Global_SunRotation=88`,
`Global_HasSeenFirstCutscene=1`, `Global_FaithAppearance=1`,
`Generated_ActiveMission=35`, `Generated_LastSavedCheckpoint=833973299`,
`TimeOfDay_CurrentTime=16202`, `TimeOfDay_NextMission=18000`,
`Release_Available=1`.

**Zero `Unlocks_*` records. Zero `XP`/`XP_Gained`/`XP_Used` records.**
Not one ability flag exists yet, in any state -- not `0`, just genuinely
absent, exactly like every other never-touched record in this save
format works. This is the cleanest possible confirmation of the
"absence = locked" pattern this whole design has been built on: a real,
completely untouched save starts with nothing, and every one of the 34
reachable `Unlocks_*` flags (§21) gets created for the first time only
when the player actually buys it.

**This retroactively answers §20's "17 mystery nodes" too, at least in
part:** they can't be some baseline default granted from save-file state,
because a real fresh save has no ability-related records to grant them
from. Whatever was keeping those 17 nodes looking "owned" in that test
must be either a different flag family entirely (not the 58-name
`Unlocks_*` catalog) or a UI-only display quirk -- not a save-state
default. Settling exactly which is still open, but it's now clearly a
narrow, low-stakes question rather than something that could undermine
the design.

**Bottom line for the "ship a save with story finished, abilities
locked" plan: that target state is not some artificial configuration
we're forcing the game into -- it's the game's own real starting state**
(just with mission-completion flags additionally set). Every open
question from §17 through §23 is now closed with a real, checksum-valid
save file backing it up.

## 24. Could missions be unlocked/played in any order instead of using time trials? -- checked the real data, answer is nuanced

Two sources checked: the mission table already built in §11's
`dependency_graph.json` (152 `PamProgressionMission` entries, each with a
resolved `CompletedFlag`/`AvailableFlag` name), and a full flag-by-flag
diff between every consecutive pair of the §22/§23 story checkpoints
(this time capturing *everything* that changes, not just `Unlocks_*`).

**The story is a strict linear chain, not a branching one.** Every
transition confirms the same pattern: finishing mission N sets exactly
one thing that matters for sequencing -- the next mission's `_Available`
flag (`Old Friends` completing sets `Be Like Water_Available`; `Fly Trap`
completing sets `Sanctuary_Available`; and so on, unbroken, all the way
to `The End`). There's no sign anywhere in 152 mission entries or 17
checkpoint transitions of alternate branches or a non-linear main story --
side content branches off the spine, but the spine itself is one line.
So "play mission 14 before mission 3" in the literal Archipelago sense
isn't how this game's story is built, and treating it as if it were would
mean fighting the game's own structure rather than working with it.

**More important: each transition is not just one flag.** Real diffs
between checkpoints show 15-50+ records changing per mission, and it's
not noise -- alongside the `_Available` flag there's consistently a
`CharacterState_<Npc>` counter advancing (Nomad, Icarus, Rebecca, Plastic
-- looks like a per-character "story stage" used to pick dialogue/AI
behavior), a monotonic `Global_CityUnlockState` counter (1 -> 9 over the
whole story, looks like the real district-access gate), specific
`Doors_*`/`TrainstationStates_*`/`DowntownStates_*` flags for exact level
geometry (doors opening, cranes moving, ziplines becoming usable),
`LMSProgression_*` scene-sequencing flags, and a wave of side-content
`_Available` flags that come along for the ride. Setting only a target
mission's own `_Available` flag and skipping the rest of this would very
likely leave the world in a state the game never actually produces on
its own -- locked districts despite an "available" mission inside them,
doors that were never told to open, NPCs stuck on the wrong dialogue
stage. This is a fundamentally different (and riskier) kind of edit than
flipping an `Unlocks_*` flag, which we've now proven six ways to be
completely self-contained.

**But there's a safer version of the same idea, and we already have the
building blocks for it.** Because the §22 checkpoint set gives a real,
complete, game-authored state snapshot at all 17 story points -- not a
guess at which flags matter, the actual full set the game itself produces
-- "unlock the next chunk of the story" could be implemented as
**installing the next checkpoint's entire captured state wholesale**,
rather than hand-picking which of 50+ flags to set. That sidesteps the
guesswork entirely: instead of reverse-engineering the minimum required
flag set per mission (error-prone, easy to miss one), it reuses a state
the game has already proven it can produce and load correctly (since it
came from a real playthrough). This reframes the AP design from "items
unlock mission access in arbitrary order" to "items unlock the next fixed
checkpoint" -- less flexible than true any-order, but something we could
plausibly build with real confidence instead of hoping we found every
required flag.

**Untested, and the right next step if this direction is worth
pursuing:** take one checkpoint file (e.g. jump straight to
`0percent08FlyTrap`, mid-story) and load it directly as a save, game
closed, to see whether the game picks up cleanly at that exact point --
right area, right doors open, next mission triggerable -- with nothing
earlier in the story actually played. If that works cleanly, checkpoint-
splicing is a solid, low-risk mechanism for "story gate" style AP
progression. If it doesn't, that's worth knowing before designing
anything around it.

## 25. Side missions can be force-unlocked into the Replay menu -- found the real flag, confirmed live

Follow-up to §24's own suggestion, prompted by a better idea: instead of
skipping ahead in the linear main story, use the game's own **Missions ->
Side Missions replay menu**, which lets you jump directly into any
already-unlocked side mission ("replaying a mission will keep your
current progress"). Side missions are individually flagged (confirmed in
static data: `<Name>_Available`, `<Name>_CompletedTime` +
`_CompletedTimestampPart1/2`, `SilverCompleted_<Name>`, and sometimes
`<Name>_Timer`/`<Name>_GridLeaks`), so if the game will accept a
synthetic "already done" state and drop the player straight into it, this
sidesteps §24's whole world-state-entanglement concern -- side missions
look far more self-contained than the main story spine.

Built `set_flag.py` (new, in `runtime/`) for this, since it's a genuinely
different case from every prior tool: `patch_save.py` can only flip a
record that already exists, and a mission the player has never reached
has no record at all yet (same "absence = locked" pattern as
everything else, confirmed again here). `set_flag.py` patches in place if
a record exists, or inserts a brand-new one (growing the blob, trimming
equal padding off the end, same mechanism as `mass_set_collectibles.py`)
if it doesn't -- verified against a sandbox copy first, checksums OK.

**Two real, live, closed-game tests were needed to find the right flag:**
- Try 1: `Finger on the Pulse_Available = 1` (already true in an older
  save of the player's own, coincidentally) -- did not appear in the Side
  Missions list. Ruled out `_Available` as the visibility gate.
- Try 2: `Finger on the Pulse_CompletedTime = 2699` (a real value copied
  from the community 100% save) -- also did not appear. Ruled out
  `_CompletedTime` alone.
- Try 3: `SilverCompleted_Finger on the Pulse = 1` -- **worked.** The
  mission immediately appeared in the Side Missions replay list after
  relaunch, in its correct alphabetical slot, fully selectable, with
  nothing else in the save touched.

**This is the real mechanism: `SilverCompleted_<Mission Name>` (the
same per-mission completion-tier flag family already seen gating things
like the main story's `GoldCompleted_<Mission>` flags) is what the Side
Missions UI actually checks -- not availability, not a timer. That was
not discoverable from static data alone (the mission catalog in
`dependency_graph.json` has no entry linking to any of "Finger on the
Pulse"'s own flags at all, a known gap per §11) -- only found by
systematically testing the real candidates live.

**Both follow-up questions confirmed live, in two more real, closed-game
rounds:**

- **Round 1 (aborted on purpose):** selected "Finger on the Pulse" from
  the Side Missions list and it loaded in with no problem at all --
  right location, right briefing text, no missing geometry, nothing
  broken from never having organically reached it. Quit out without
  finishing. Uploaded the resulting save afterward: `CompletedTime`
  and `SilverCompleted_` were both still exactly our synthetic values
  (`2699`, `1`) -- unchanged, as expected, confirming an abort doesn't
  silently "complete" or otherwise disturb the record.
- **Round 2 (played it for real):** selected it again, this time
  actually finished it ("Help Plastic expand her METAGRID access --
  tap all the DATAPOINTS before the firewall shuts down"). The in-game
  result screen showed a real completion time, `00:22.36` -- a
  genuinely different value from the synthetic `2699` (26.99s) we'd
  written. The game overwrote our placeholder with the real result on
  its own, no extra tooling involved.

**Both halves of the mechanism now hold.** A side mission can be
force-unlocked into the Replay menu with one flag
(`SilverCompleted_<Name>`), it loads into a fully coherent, playable
instance regardless of whether the player ever organically reached it,
and a real completion afterward cleanly overwrites the synthetic seed
with genuine data -- meaning "the AP item unlocked it" and "the player
actually finished it" are automatically distinguishable, for free, with
no new detection logic needed beyond watching whether the value changed.
This is a materially stronger foundation for AP location checks than
either time trials (§16, never save-tracked) or skipping ahead in the
main story (§24, heavily world-state-entangled): individually flaggable,
individually verifiable-as-done side missions, using a tool
(`set_flag.py`) general enough to apply to any of them by name. This
result now stands alongside §19/§20/§23 as one of the handful of things
in this whole project proven end to end on real hardware, not just
inferred from static data.

## 26. Starting point for next session

Where this left off, and what was floated for next time:

**Next session's main goal:** start turning this into an actual small
Archipelago implementation -- pulling together the full side-mission
catalog (names + their `SilverCompleted_`/`_Available` flags, same
approach as the ability catalog in §21) alongside the ~34 reachable
`Unlocks_*` abilities, and sketching the real item/location JSON
structure. Both mechanisms (§19/§20/§23 for abilities, §25 for side
missions) are now proven end to end -- this is building on solid ground,
not still-open research.

**The elephant in the room, raised by the user and worth designing
around honestly:** every receive-item mechanism proven so far needs the
game closed to take effect (§15/§15a/§15b) -- there is still no confirmed
way to grant an item into an *already-running* session. A real AP client
would need to either (a) require a restart/relaunch to pick up new items
(clunky but simple, and 100% proven to work), or (b) find some way to
poke a running session, which is unexplored territory this project has
not touched.

**One idea floated for (b), not yet investigated: feed XP live via Cheat
Engine instead of granting moves/missions directly** -- the reasoning
being that a numeric currency might be a simpler live-injection target
than a boolean unlock flag, letting the player buy things themselves
without a restart. Worth being upfront about the relevant history before
chasing this: this project's own earlier live-memory work (see "Live
memory access (superseded)" in README.md) already ran into a specific,
relevant wall -- the address chain it found for progression data exposed
only *static config*, and a separate reflection-based field-write
mechanism it traced for aggregate UI counters (e.g. "GridLeaks: 181/324")
turned out to update the on-screen number without ever touching the real
per-save state underneath. If XP's live/UI value turns out to be the
same kind of display-only copy, writing to it would look like it worked
in the moment and then get silently discarded at the next autosave --
the exact same failure shape as §15a's very first (misdiagnosed) test.
**The cheap first sub-test, before building anything around this idea:**
use Cheat Engine to write a large value to whatever address displays the
in-game XP counter, let an autosave happen, then check the save file's
`XP`/`XP_Gained`/`XP_Used` records (via `decode_save.py`) to see whether
the write actually stuck or got overwritten. That one experiment settles
whether this path is worth building on before any more time goes into
it.

---

## §27: Beat Revival investigated -- time trials are NOT currently restored, and time trials remain unusable as an AP mechanism

The user asked whether Beat Revival (the community project reverse-engineering
EA/DICE's shut-down MEC server software -- https://www.beatrevival.me/,
GitHub org https://github.com/Beat-Revival) has brought back custom/community
time trials, since that could revive the time-trial-as-AP-item design this
project shelved earlier (time trial results were never found to be locally
save-tracked -- see the earlier, pre-§18 sections of this file).

**Short answer: no, not yet, and this is stated explicitly and recently by
Beat Revival's own community documentation -- time trials are named as a
planned *future* feature, not a current one.**

### What was checked

- **beatrevival.me homepage** -- generic marketing copy only, no feature
  specifics, no changelog.
- **Beat Revival's own blog** (blog.beatrevival.me), all 4 posts read:
  - "Welcome!" (14 Dec 2023)
  - "Interception (Progress Report 1)" (14 Dec 2023) -- pure network
    protocol reverse-engineering (breaking Blaze's ProtoSSL encryption via
    an EA-MITM attack, the `catalyst-mitm` tool converting the binary Blaze
    protocol to JSON). No player-facing features.
  - "Progress Report 2" (25 Feb 2024) -- decrypting the TDF packet format,
    building API/Blaze server emulators, getting the game to talk to the
    emulated server at all. Still no player-facing features.
  - "Progress Report 3" (21 Jun 2024, the most recent post -- **over two
    years old as of this writing**) -- first player-facing progress:
    initial handshake + web API requests working, "Beat L.E" (an in-game
    placement/leaderboard-adjacent feature) partially working but "a lot of
    values are still hardcoded," online-exclusive achievements unlockable
    again via the EA App, plus runner-kit unlocks, player stats, and
    division/ranking *data* showing up. **No mention of time trials in any
    of the 4 posts.**
- **GitHub org** (github.com/Beat-Revival) -- still only 4 repos
  (`project-website`, `redirector`, `blog`, `.github`); the actual protocol
  work lives in contributors' personal repos (`catalyst-mitm`, `tdf.js`,
  and the archived `pamplona-future` / its successor `grid-leak/blaze`,
  already known from earlier project research to not yet implement
  leaderboards or time trials).
- **The current, non-obsolete Steam guide** -- "[2026] FIX ACHIEVEMENTS
  USING LOCAL SERVER" (steamcommunity.com/sharedfiles/filedetails/?id=3464761006),
  which explicitly supersedes the older "[OBSOLETE] Achievement fix" guide
  and is dated to this year. **This is the single clearest, most current
  piece of evidence found.** It states outright: *"At this point, server is
  able to provide achievement-popping experience only."* Two specific
  achievements ("User Generated Finisher" and "You can't keep me down")
  are called out as still unobtainable because they're *"tied to user
  created activities"* and *"may be obtainable in future, when developers
  of Beat Revival implement Time Trials and Beat L.E."* -- i.e. Time Trials
  are explicitly named as a **planned, not-yet-built** feature.
- Several other sources (the "Mirror's Edge Catalyst Online is BACK! | Beat
  Revival Open Beta" YouTube video, a TrueSteamAchievements forum thread,
  a Steam discussion thread about achievements) were also checked; none of
  them mention time trials, ghost data, or leaderboards as working. The
  YouTube video itself could not be fetched (persistent HTTP 429 from the
  fetch proxy across several retries) -- flagged here as an unresolved gap,
  but everything else found (especially the 2026-dated Steam guide, which
  is more current than a video whose only known title is "Open Beta")
  points the same direction, so this isn't treated as a blocker on the
  conclusion.

### What "Open Beta" actually seems to mean

Putting the sources together: Beat Revival's "Open Beta" is about restoring
basic server connectivity and achievement-popping (including
online-exclusive achievements that were impossible after the real servers
shut down), plus some early, partially-hardcoded groundwork for "Beat L.E"
(seems to be the in-game leaderboard/placement UI) and division/rank data
display. It is explicitly **not** yet a working time trial or ghost-racing
system. The user's belief that time trials were already back is
understandable given the "Online is BACK!" video title, but the project's
own most current documentation says otherwise.

### What this means for the AP design

This doesn't change the earlier conclusion: **time trials are still not a
usable AP check/item mechanism**, for two independent reasons now instead
of one --
1. (Original reason, unchanged) time trial results were never found to be
   tracked in the local save file at all -- there's nothing for this
   project's save-editing toolchain to read or write regardless of server
   state.
2. (New) even the online side of time trials -- the part a Beat Revival
   server would need to serve -- isn't implemented yet by Beat Revival's
   own account, so there's no live system to hook into either.

If Beat Revival ships real Time Trial support later, it would be worth
revisiting -- but that would mean depending on a third-party unofficial
server project's roadmap landing, which is a much less solid foundation
than the two mechanisms already proven firsthand in this project (§19/§20/
§23 for abilities, §25 for side missions). No action item follows from this
section beyond "keep an eye on Beat Revival's blog if interested" -- it's a
dead end for now, not a path to build on.

Sources checked: [beatrevival.me](https://www.beatrevival.me/) |
[Beat Revival blog](https://blog.beatrevival.me/posts/) |
[Progress Report 3](https://blog.beatrevival.me/posts/progress-report-3/) |
[Beat-Revival GitHub org](https://github.com/Beat-Revival) |
[2026 achievements-only Steam guide](https://steamcommunity.com/sharedfiles/filedetails/?id=3464761006)

**Addendum, same session:** user's take -- worth exploring Beat Revival's
own MITM/protocol work (`catalyst-mitm`, the tool from §27's Progress
Report 1 that decrypts the Blaze traffic between game and server) at some
point, specifically to see what it reveals about in-game time trial data
once/if that traffic exists to observe. Explicitly **not** the current
priority -- logged here as a parked idea to come back to, not a task.

**Addendum, XP sub-test in progress:** clarified that the on-screen XP
number is a cumulative/lifetime counter, not a spendable balance -- buying
an ability consumes a skill point behind the scenes but does **not**
decrement the displayed number, and the display simply stops changing once
it hits 29000 (matches the known real single-playthrough `XP_Used` ceiling
from §21/§22, "you are done" once every reachable ability is bought).
Practical effect on the Cheat Engine scan: there is no real "decrease"
event to scan against, so the exact-value narrowing attempted first (4
rounds, still ~800 candidates -- likely noise from matching a small,
unremarkable integer against a lot of incidental memory) was abandoned in
favor of restarting clean with Unknown-initial-value -> Increased-value
(repeated 2-3x on real XP gains only), the same technique that narrowed
the GridLeaks counter down to ~6 candidates in §10e. Test still in
progress as of this note.

**Addendum, re-confirmed on a fresh save:** user raised a reasonable
alternative explanation for the "dump_progression_state.py only shows
static config" finding -- what if that only *looked* static because the
original test was run on an almost-100%-complete save, where nearly every
flag was already instantiated? Tested directly: re-ran
`dump_progression_state.py` on a brand-new, near-0% save and diffed the
output against the old baseline snapshot. Result: **identical** --
122/124 flag groups, 1506/2376 flags matched, 152/152 missions, 324/324
locations, same exact flag names, and identical `maxValue`/`cost`/
`reputation` for every one of the 1506 flags, zero differences. This
confirms (rather than just assumes) that this address chain really is
reading `PamProgressionSettings`' shared static rules object, completely
independent of which save is loaded -- not an artifact of testing on a
near-complete save. The XP Cheat Engine sub-test (previous addendum,
above) remains separately open/unresolved.

**Addendum, terminology + re-check:** user clarified the in-game/community
name for time trials is "Dash" (confirmed by this project's own earlier
notes, above -- `pamplona-future`'s own repo description lists "Time
Trials" and "Dash leaderboards" as separate features). Re-ran the §27 web
research using "Dash" instead of generic "time trial" wording to make sure
the right term hadn't surfaced anything missed -- it didn't: same sources,
nothing new, §27's conclusion (Beat Revival doesn't have this live yet)
stands. Also spot-checked the static PlayerProgressionData dump for
"Dash"-named flags: `Demo_CompletedDash` and per-mission ones like
`"Birdman's Route_OnDash"` exist, but both look like route/mode markers
(no `SyncStatName`, `SyncToOnline=0`) rather than anywhere an actual
completion time is stored -- doesn't reopen the "time trial results aren't
save-tracked" finding, just recorded for completeness.

---

## §28: Survey of how other Archipelago clients solve "grant an item into an already-running game"

User asked how other AP integrations solve the exact problem blocking this
project (no live receive without a restart), to find other avenues to
research. Checked two real, public AP clients for native/closed-source PC
games (not Unity-with-a-scripting-layer, a closer analogue to ME:C's
Frostbite engine than most AP worlds):

- **[Super Meat Boy AP](https://github.com/PixelShake92/Super-Meat-Boy-AP)**
  -- raw live-memory read/write via `pymem` (Python wrapper over
  ReadProcessMemory/WriteProcessMemory, same OS-level mechanism Cheat
  Engine uses). Confirms the address-hunting approach this project has
  been doing by hand is a real, legitimate pattern other AP clients ship
  with -- the open problem here is finding the *right* (live, mutable)
  object, not the technique itself.
- **[Sonic Heroes AP](https://github.com/EthicalLogic-Archipelago-Org/Sonic-Heroes-AP-Client)**
  -- DLL injection via **Reloaded-II**, a general-purpose Windows game mod
  loader not tied to any specific engine. Once injected, the mod calls the
  game's own real functions/objects directly instead of guessing at memory
  layout from outside -- generally the more robust of the two patterns.

Full option list compiled for the user, roughly in order of new-tooling
cost:
1. Keep hunting for the live, mutable equivalent of `ProgressionManagerData`
   (current approach; the target is real, just not yet located -- distinct
   from the confirmed-static `PamProgressionSettings` and the confirmed
   display-only UI-counter writes from the earlier live-memory work).
2. DLL injection (Reloaded-II or similar) once the actual "buy ability"
   function is located (e.g. by breaking on the write to `XP_Used` and
   reading the surrounding function, the same "find out what writes"
   technique already used successfully for the GridLeaks counter) --
   call/hook the real function instead of poking raw bytes.
3. **Frida** -- a popular engine-agnostic dynamic instrumentation
   framework, lower-ceremony than a full injected DLL mod loader, worth
   trying for hooking/calling native functions directly.
4. **Leverage Beat Revival's own infrastructure**: several
   `PamProgressionFlag` entries carry a `SyncToOnline` field -- if the
   game's real online-sync path is a genuine live-apply mechanism, a local/
   fake EA server (which Beat Revival's `catalyst-mitm`/redirector tooling
   already proves is achievable) could be a ready-made live write path.
   Worth raising in the Discord alongside the existing question about where
   the mutable per-save state lives.
5. Input automation as a fallback (script the exact keypresses to buy an
   ability through the real menu), only viable once/if getting spendable
   points in live is solved some other way -- sidesteps write-correctness
   risk entirely by using the game's own legitimate purchase path.

Also pointed the user at the wider Archipelago GitHub ecosystem
(`github.com/ArchipelagoMW` and community `-AP`/`APWorld` repos) as
primary-source prior art worth browsing directly for other native-PC-game
clients' exact address-hunting/hooking code.

---

## §29: PamProgressionFlagEntityData -- likely the missing live "current value" object (major lead)

Following up on §28's option list, searched the `SDK/` header dump (the
same `SDK.zip`/FrostbiteGen tool from §10 that already gave the correct,
working `PamProgressionSettings` address chain -- not a new/unproven
source) for a live counterpart to the confirmed-static
`PamProgressionFlag`. Found **`PamProgressionFlagEntityData`**:

```
PamProgressionFlagEntityData : EntityData   // total size 0x40
  Realm                  @ 0x18
  FlagGroup* (pointer)   @ 0x20   -> PamProgressionFlagGroup*
  Flag* (pointer)        @ 0x28   -> PamProgressionFlag* (the static one)
  Value (int)            @ 0x30   <-- live, mutable current value
  GeneratedFlagNameHash  @ 0x34
  ValueAsBool            @ 0x38
  OnlySetValueOnEvent    @ 0x39
  OnlyReadValueOnEvent   @ 0x3a
```

One instance's address is given directly by the header:
`GetInstance()` reads a pointer from `fb::GetModuleBase() + 0x2873500`.
`GetTypeInfo()` (usable as a vtable-scan seed to enumerate every live
instance, not just this one) is at `module + 0x28734e0`.

**Why this is a strong lead and not just a guess:** `PamProgressionFlagEntityData`
was independently identified *months earlier*, from a completely different
angle (static EBX/prefab parsing, §7) -- every "green" collectible pickup's
level prefab contains one, and its `.FlagGroup`/`.Flag` fields were already
proven (via the GUID-resolution fix in §6) to resolve to real
`PamProgressionFlagGroup`/`PamProgressionFlag` instances. That's the same
class, doing "bind a flag to a live game thing," confirmed from the
world-data side long before this live-memory header surfaced its `Value`
field. §10's own open question ("none of the classes we checked expose a
current-value field") was scoped only to the three classes a Discord
modder pointed at at the time (`PamProgressionData`/`FlagGroup`/`Settings`)
-- this class just hadn't been looked at yet.

**Not yet tested live.** Proposed protocol, in order of confidence:
1. Resolve `module + 0x2873500` as a pointer in Cheat Engine (Add Address
   Manually, tick Pointer). Check `+0x28` looks like a valid pointer into
   the already-known static `PamProgressionFlag` pool, and read `+0x30`
   as a sanity check.
2. That's likely only one arbitrary instance, not necessarily a flag we
   care about -- use `GetTypeInfo()` (`module+0x28734e0`) to vtable-scan
   for every live `PamProgressionFlagEntityData` instance (see §28's RTTI/
   vtable-scan writeup), then match each one's `+0x28` pointer against the
   known static address for a specific flag (start with `Unlocks_ExtendedSlide`,
   the project's established safe repeat-test case) to find the right
   instance.
3. Write to that instance's `+0x30` Value field with the game running and
   see if it takes effect live, no restart -- the actual test this whole
   thread has been building toward.

**If confirmed, this solves both open threads at once**: `XP_Gained`/
`XP_Used` are just more named `PamProgressionFlag` entries in the same
static catalog, so the same mechanism would cover live XP writes too, not
just ability/mission flags.

**Update -- steps 1 and 2 done live, exactly as planned, and it worked
mechanically.** In-game, on `MirrorsEdgeCatalyst.exe` at module base
`0x140000000`:

- `module+0x2873500` resolved as a pointer; its `+0x0` (real C++ vtable,
  not `GetTypeInfo()` -- see the correction below) read as
  `5398652632` (`0x141C8E6D8` = `module+0x1C8E6D8`), confirming a live,
  standard, non-Frostbite-quirky vtable at instance offset 0.
- *(Correction to the plan above: `GetTypeInfo()` at `module+0x28734e0`
  turned out to be a separate Frostbite reflection descriptor, not the
  actual vtable pointer -- confirmed by reading `DataContainer.h`'s
  `GetEntry(instance, index) { return (*(void***)instance)[index]; }`
  and `EntityData.h`'s own distinct vtable func table. The simpler, correct
  seed for a vtable scan is just the live vtable pointer read directly off
  the one already-resolved instance, as done above.)*
- Exact-value memory scan (8 Bytes) for `5398652632` -> **633 raw hits**.
- Lua filter (non-null `+0x28` Flag pointer) -> **519 real instances**.
- Lua name-resolution (read `Flag->+0x18` as a C string) -> full
  `Name = Value (entity base=...)` table for all 519, sorted and pulled
  for offline analysis.

**The 519-entity table changes the picture, though.** Parsed
programmatically (253 unique flag names across the 519 instances):

- **All 146 instances of every `Unlocks_*` / `XP_*` name read exactly 0.**
  Not "mostly" -- *all* of them, across all 44 unique `Unlocks_*` names
  and both `XP_Used`/`XP_Gained`, including `Unlocks_ExtendedSlide` (the
  project's standard test flag, known to be *unlocked* on the current
  save) and `XP_Gained`/`XP_Used` (known from `decode_save.py` to be
  27481/27000 on the current save). Every single one of these
  progression-catalog instances is sitting at its type's default value,
  not the save's real value.
- **Only 22 of the 519 instances are nonzero at all**, and none of them
  are progression/unlock flags. They're level/scene state:
  `CharacterState_Nomad` (2, 4, 6 across 3 instances), `Collectables_OrbsEnabled`
  (2), `Global_SunRotation` (88), and 14 `Music_MusicSegment` instances
  holding distinct values 1-14 (almost certainly "which music layer/cue
  is this segment object currently playing").
- **3 of the 519 are garbage** -- corrupted/unreadable names, absurd
  values (~7.6-11 million), at addresses `142873530`, `2D6B2C40`,
  `2D6B2C38`. The latter two are the *exact same addresses* from this
  investigation's very first live screenshot (`P->2D6B2C38`/`P->2D6B2C40`,
  both read as `0` at that time). They now read huge garbage -- almost
  certainly a coincidental 8-byte match on the vtable-pointer value in
  memory that was never actually a live instance, or a heap slot that's
  since been reused for something else. Not a lead; the raw exact-value
  scan has no type-safety, so a few false positives out of 633 is
  expected and these should just be filtered out (e.g. validate the
  `Flag` and `Name` pointers land inside sane module/heap ranges before
  trusting an entry).

**Working interpretation:** `PamProgressionFlagEntityData` is real and its
`Value` field is genuinely live/mutable -- but the 519 instances found by
a class-wide vtable scan are dominated by *level-placed, per-object*
entities (music cues, per-level lighting/sun state, a specific NPC's
state machine, a specific collectible's on/off toggle) that happen to use
the same class as a generic "named int with a value" container. The
`Unlocks_*`/`XP_*` instances found this way look like they're either (a)
freshly-constructed default/template copies that only get pushed the real
save-backed value at the moment something actually queries them (lazy
sync), or (b) a genuinely different, disconnected copy from whatever
struct actually backs the persisted save state -- not yet distinguishable
from this data alone.

**Proposed next steps, cheapest/most informative first:**
1. **Prove the write mechanism on a safe, currently-nonzero instance**
   first, decoupled from the progression question entirely -- e.g. write
   a different segment ID to one of the 14 live `Music_MusicSegment`
   instances, or a different value to the one live `Global_SunRotation`
   instance, and watch/listen for an immediate in-game effect. Cheap,
   fast, and answers "does writing to this class's `+0x30` do anything at
   all" before spending more time on the harder progression-specific
   question.
2. **Test the lazy-sync hypothesis**: re-run the same scan right after
   doing something that should force the game to read
   `Unlocks_ExtendedSlide`'s real value -- e.g. open the Progression/moves
   menu, or walk up to whatever normally checks that ability -- and see if
   that specific instance flips from `0` to `1`. If it does, the sync
   point is identified and a live write becomes plausible right after
   triggering it.
3. **Decode `Realm`** (`+0x18`, currently undecoded, likely a small enum)
   on a couple of instances -- e.g. one of the two `Unlocks_ExtendedSlide`
   entities (bases `15B713AE8`, `15B96F800`) vs. one of the live
   `Music_MusicSegment` entities -- to see whether it distinguishes
   "authoritative/global" scope from "local/per-object" scope, which
   would explain why an `Unlocks_*` flag shows up twice while
   `Music_MusicSegment` shows up 14 times.

**Update -- step 1 (prove the write mechanism) done, with a genuinely
important positive result.** Wrote `270`, then `360`, to
`Global_SunRotation`'s `Value` field (`15BD91548 + 0x30 = 15BD91578`, 4
bytes) with the game running. No visible sky/lighting change either
time -- but critically, **the written value stuck**: re-checking the
address afterward still showed `360`, and it *survived a death and small
(checkpoint) reload*, still reading `360` on respawn. This rules out "the
game is continuously overwriting this field from elsewhere" (would have
snapped back to something near the real sun position) and instead shows
this class's `Value` field is genuinely live-writable **and persists
across at least a checkpoint-level reload, not just within the same
frame** -- which is direct evidence against the "no live receive without
a full game restart" problem, independent of whether `Global_SunRotation`
itself does anything visible.

Most likely explanation for the lack of visual effect: this instance
either isn't the copy actually driving the skybox renderer (matches the
Frostbite "default vs. active instance" duplication quirk flagged
earlier), or `Global_SunRotation` isn't a continuous render input at all
(e.g. scripted-cutscene keyframe data, or feeds something non-visual).
Not chasing that further for now -- the mechanism is validated, which is
the part that matters.

**Next: test it directly on `Unlocks_ExtendedSlide`.** Two instances
found: base `15B713AE8` and base `15B96F800`. For each, write `1` to
`Value` (`+0x30`) and also `1` to `ValueAsBool` (`+0x38`, 1 byte) in case
the game reads the bool field rather than re-deriving it from the int:
- `15B713AE8 + 0x30 = 15B713B18` (Value, 4 bytes)
- `15B713AE8 + 0x38 = 15B713B20` (ValueAsBool, 1 byte)
- `15B96F800 + 0x30 = 15B96F830` (Value, 4 bytes)
- `15B96F800 + 0x38 = 15B96F838` (ValueAsBool, 1 byte)

Then check the in-game Moves/Progression menu for a visible "unlocked"
state, and separately test the actual mechanic (slide under something
that requires the extended distance) to see if it's functionally granted,
not just cosmetically shown.

**Update -- test result and a self-correction.** Wrote `1` to both
`Value` and `ValueAsBool` on both `Unlocks_ExtendedSlide` instances. No
change: the ability screen still showed "LOCKED: Complete mission
BENEFACTOR" before and after (identical screenshots), and the slide
mechanic itself was tested in-game and does not appear to actually grant
the extra distance either.

Before interpreting that, a correction to the framing used earlier in
this section: I compared the live-session values (all `Unlocks_*`/`XP_*`
reading 0) against `decode_save.py`'s output for the player's *main*
`PROF_SAVE` (`XP_Used=27000`, `XP_Gained=27481`, from earlier this
project) and called it a contradiction. That was comparing two different
saves -- the entire live-memory investigation in this section has been
running against the *fresh* save made specifically for this testing (`"I'll
restart a fresh save"`), not the main save. A fresh/early save reading 0
across the board is not a red flag at all; per §23, a genuinely fresh save
has zero `Unlocks_*` records full stop. So the "146 instances, all 0" data
point doesn't actually indicate wrong/default/disconnected instances --
it's consistent with these being the real, correctly-read live values for
this save's real (early) progress. Worth keeping in mind, but it doesn't
change today's negative result.

**Why the write likely had no effect: confirmed via this project's own
earlier data (§22) that every ability is mission-gated on *purchasability*,
separately from the owned flag.** `PamProgressionFlag`'s static schema has
a `.MissionIndex` field, and §22's real 17-checkpoint timeline shows
`ExtendedSlide` doesn't become purchasable until the "Viva La
(Resistance)" checkpoint (well after "Benefactor"). Cross-checked against
`runtime/dependency_graph.json`'s `missions` list: the actual story
mission named "Benefactor" is `mission_index: 81` (`PamProgressionMissionType_Gold`,
active/available name IDs resolve to `ID_MIS_MQ08...`, i.e. Main Quest 8),
with `completed_flag_name: "Benefactor_Timer"` -- almost certainly the
flag the ability-shop screen's "Complete mission BENEFACTOR" check reads
(a nonzero completion timestamp = mission done, matching the
`X_CompletedTime`/`X_Timer` naming pattern used elsewhere in this data).
That flag is **not currently live** in our 519-entity dump -- only
`Benefactor_HelicopterCrowds` showed up, meaning the level content that
would instantiate `Benefactor_Timer` isn't currently streamed in at the
player's location. Most likely explanation for the failed test: the
ability system's unlock check is gated on mission-complete first (both for
the shop UI and for the actual slide mechanic), and without `Benefactor_Timer`
set, nothing even looks at `Unlocks_ExtendedSlide`'s value -- so the write
may well have been fine, just invisible behind an earlier gate. This
doesn't yet distinguish that from "wrong instance found" as an
explanation, but it's the more likely one given `Global_SunRotation`
already proved the write path itself works and persists.

**Every `Unlocks_*` flag is mission-gated in some way (per §22), so there
is no gate-free ability to test on a fresh save** -- the earliest
possible unlocks (`Focus`, `Glove`, `HandToHandCombat`, `MoveEnemyAttack`,
`Shift`) still require the prologue (`Release`, `Reunion`) to be done
first. **Next step:** check the in-game Moves/Progression menu for any
ability currently showing a point cost (purchasable) rather than "LOCKED:
Complete mission X" -- if the player has cleared the prologue, one should
be available. Testing a live write on an already-purchasable-but-unbought
ability removes the mission-gate confound entirely and would cleanly
confirm (or rule out) whether this class is genuinely the live
authoritative store the ability system reads from.

**Update -- clean test run, and this hypothesis is now most likely dead
for progression purposes.** Player's actual (different, further along than
the fresh save used for the earlier tests) save had a genuinely gate-free
case: Combat tree, `Unlocks_PositionalAdvantage`, shown red/available
(no lock, no mission gate) with 5,375/6,000 points banked. Found and wrote
`1` to `Value` (`+0x30`) and `ValueAsBool` (`+0x38`) on all three live
instances of that flag:
- base `15A77A520`
- base `15B714218`
- base `15BB81D30`

Closed and reopened the Progression menu afterward. **No change** --
still showed as available-but-unpurchased, identical to before. With no
mission gate to blame this time, and a clean write to all three known live
copies, this is a real negative result, not just "found the wrong
instance among duplicates."

**Conclusion: `PamProgressionFlagEntityData`'s live-writability and
persistence (proven via `Global_SunRotation`) are real, but this class is
most likely *not* what the ability/unlock system actually reads from.**
Best explanation: it's a generic "named int+bool flag on a level object"
component used broadly for level scripting (matches everything actually
observed live -- music cue IDs, sun angle, an NPC's state machine, a
collectible toggle) that happens to share the same class as the
*definition* side of progression flags (already proven in §7/§10/§18 via
static `.FlagGroup`/`.Flag` fields on prefabs), without being the
*storage* side the running game consults for "is this owned."

**The more architecturally-plausible lead, already sitting in the SDK
dump and not yet chased:** `PamClientProgressionFlagEntity` (`Entity`,
size `0x58`) and `PamServerProgressionFlagEntity` (`Entity`, size `0x88`)
-- both explicitly named for a client/server split, both flagged by the
SDK generator with "No traversal chain found... use `fb::PatternScan()` or
manual pointer chains," and both undecoded (raw byte blobs, no field
offsets known). There's also `PamServerProgressionPurchaseEntity`
(`Entity`, size `0x40`, same "no traversal chain" warning) which, by name,
sounds like it could be the actual "buy this ability" handler rather than
passive storage. A client/server-replicated progression store would
explain everything cleanly: it fits this game's asymmetric online
features (ghost data / social play), and it would sit in a completely
different part of the object graph than the level-scripting flag class we
just spent this whole thread testing -- which is exactly why the
FrostbiteGen tool couldn't auto-resolve a traversal chain to it the way it
did for `PamProgressionFlagEntityData`.

Three ways forward from here, meaningfully different in cost and risk:
1. **Hunt `PamClientProgressionFlagEntity`/`ServerProgressionFlagEntity`
   directly** via Cheat Engine's "find out what accesses this address"
   breakpoint technique -- set a break-on-access on a known *static*
   flag-definition address (e.g. the long-established
   `PamProgressionSettings`/`PamProgressionFlag` static chain from early
   in this project), open the ability menu to force the game to read it,
   and step through the resulting breakpoint hits in the disassembler to
   trace the code path down to wherever it actually stores "owned."
   Significantly more advanced than anything done so far (live
   disassembly, register/stack reading, likely no symbols) and slow, but
   directly targets the real object.
2. **Skip memory-hunting and call the game's own purchase function**
   instead (the DLL-injection/Frida route surveyed in §28) -- if
   `PamServerProgressionPurchaseEntity` or similar exposes a "purchase"
   method, hooking/calling it directly sidesteps the "which struct is
   authoritative" question entirely, since the game's own code already
   knows where to write. Requires standing up an injected DLL or Frida
   script, i.e. new tooling, but is the most robust long-term answer to
   the underlying "no live receive" problem either way.
3. **Stop live-memory hunting for now** and pick it up fresh next
   session -- this thread has produced a real, useful, fully-documented
   result (the write mechanism and persistence are proven real, this
   specific class is proven not to be the answer, and the next two best
   leads are named and reasoned out) even though it didn't land the final
   answer tonight.

**Session ended here, by choice (option 3 above).**

## 30. Starting point for the next session (supersedes §26 for the restart-problem thread)

**What's actually settled now, stated plainly so it doesn't need
re-deriving:**
- The "no live receive without a restart" problem (§15/§15a/§15b/§26) is
  still open -- nothing found this session lets an item be granted into
  an already-running session in a way that sticks and is reflected by the
  game's own systems.
- But two real, reusable facts came out of tonight's work: (1) a class's
  `Value` field being technically live-writable and even surviving a
  checkpoint reload does **not** mean it's the object the game logic
  reads from -- both need to be checked separately, and only checking the
  first one is how this thread almost mis-reported a false positive; (2)
  `PamProgressionFlagEntityData` (found via the vtable-scan technique in
  §29) is now fairly conclusively a generic level-scripting "named flag"
  component, not the progression store -- confirmed by two independent
  negative tests (`Unlocks_ExtendedSlide` under a mission gate,
  `Unlocks_PositionalAdvantage` with no gate at all), both after writes
  that provably stuck in memory.

**Next session, pick one of the two live leads named in this update to
§29** (both already reasoned out above, no need to re-research):
1. `PamClientProgressionFlagEntity` / `PamServerProgressionFlagEntity` --
   client/server-replicated, no auto traversal chain in the SDK dump.
   Approach: CE "find out what accesses this address" breakpoint on a
   long-known static flag address (the original
   `PamProgressionSettings`/`PamProgressionFlag` chain), triggered by
   opening the ability menu, then trace the disassembly from the
   breakpoint hit.
2. `PamServerProgressionPurchaseEntity` -- sounds by name like the actual
   "buy ability" handler. If a DLL-injection/Frida approach (§28) gets
   built, hooking or calling this directly would sidestep the "which
   struct is authoritative" question altogether.

**Also still on the shelf, unchanged from §26:** the full side-mission +
ability item/location JSON catalog build-out (deprioritized again this
session in favor of the restart-problem investigation) -- both underlying
mechanisms are proven, so this is ready to build whenever the
restart-problem thread is paused or solved.

**Update -- the cheap XP-display sub-test was attempted same night,
inconclusive, still open.** With the Progression menu showing `5,385 /
6,000 XP` live, tried an Exact Value / 4 Bytes scan directly for the
on-screen number (`5385`) instead of the raw `XP_Gained`-style catalog
value. First scan: ~1000-1048 hits, essentially unchanged across many
Next Scan passes while sitting in the menu -- consistent with world
simulation being paused/throttled while a menu is open, so nothing else
in memory was changing to filter the noise out. After leaving the menu
and moving around, it finally started shrinking (1,048 -> ~800) but the
session ended there for the night before it could be narrowed further or
tested for a real write+autosave persistence check.

**Not yet ruled out:** the displayed points value might not live at a
single stable address at all -- some UI systems recompute a shown number
like this at render time from other underlying data rather than caching
it as one persistent int, which would explain the unusually slow
narrowing even with the game running. Worth continuing the same
narrowing process (Next Scan while actually moving/playing, not
menu-idle) before concluding either way -- this sub-test is genuinely
still open, not negative yet.

## 31. Attempted RTTI-based vtable derivation for the client/server flag
entities -- the MSVC RTTI premise was wrong, but a real, different lead
turned up instead

Picked up §30's first lead: finding `PamClientProgressionFlagEntity` /
`PamServerProgressionFlagEntity` live, since neither has a `GetInstance()`
traversal chain in the SDK. The plan was to derive each class's real
vtable analytically from MSVC RTTI (`GetTypeInfo()` address -> assumed
`TypeDescriptor` -> scan for the `RTTICompleteObjectLocator` referencing
it -> scan for what points at *that* -> vtable), instead of the harder
live-breakpoint technique floated in §30, reusing the same "exact-value
scan for a known pointer" method that already worked for
`PamProgressionFlagEntityData`.

**The premise was wrong.** A live-memory scan for the literal
`TypeDescriptor` RVA bytes (`50 FE 85 02` for the Client class), with
every protection filter removed (Writable and Executable both unchecked,
full "All" region), found **zero** matches anywhere in the process. That
rules out standard MSVC RTTI being what `GetTypeInfo()` points to for
these two classes -- consistent with something already learned earlier
this project: `GetTypeInfo()` is a Frostbite-internal reflection
descriptor, not the raw C++ vtable, and evidently not a standard
`type_info`/`TypeDescriptor` object either.

**But the raw bytes at that address are real, structured data, not
garbage -- and they contain something useful.** Reading 64 bytes starting
at `PamClientProgressionFlagEntity::GetTypeInfo()`'s own address
(`14285FE50`) directly: bytes at struct offset `+0x15` are
`B0 86 7E 42 01 00 00 00`, which as a little-endian pointer is
`module+0x27E86B0` -- **exactly** `Entity::GetTypeInfo()`'s own address
(`PamClientProgressionFlagEntity`'s base class). Not a coincidence at
that level of precision. So whatever this structure actually is, it's a
real, per-class Frostbite reflection object with at least one meaningful
field: a back-pointer to the parent class's equivalent structure. The
offset being unaligned (`0x15`, not a clean 4/8 boundary) suggests this
is packed/serialized reflection data rather than a plain compiler-emitted
C++ struct, which makes further manual field-guessing slow going.

**Where this leaves things:** the MSVC-RTTI vtable-derivation plan is
dead for these two classes -- there's no `RTTICompleteObjectLocator` to
find because there's no real C++ RTTI backing `GetTypeInfo()` here.
Whether this Frostbite reflection structure eventually leads anywhere
(e.g. a pointer to a live-instance registry, or the real vtable, sitting
elsewhere in the same struct) is unknown -- promising in that it's
clearly real, structured, per-class metadata, not proven useful yet.
Session paused here to decide whether to keep hand-decoding this
structure, ask Meteor/the SDK tool's author for a manual traversal chain
to these two specific classes (the tool that generated the SDK already
resolves hundreds of other classes automatically -- these two are just
the ones it couldn't), or fall back to the live-breakpoint technique from
§30 after all.

**Update -- fully decoded what this structure actually is, and it's a
dead end for the original goal (finding live instances), though a real,
confirmed finding in its own right.** Dumped the raw bytes at
`GetTypeInfo()` for `PamClientProgressionFlagEntity`,
`PamServerProgressionFlagEntity`, and (for comparison) the already-working
`PamProgressionFlagEntityData`, then cross-referenced every 8-byte window
across all of them for anything landing in the module's address range.

Both unresolved classes share an identical field layout (byte-for-byte
matching structure, just different content per field) that the known-good
class does *not* share -- consistent with `PamProgressionFlagEntityData`
extending a different base (`EntityData`) than the other two (`Entity`
directly), so a different reflection layout for that hierarchy is
expected, not a contradiction.

Two fields fully decoded and confirmed on both classes:
- **`+0x15`: a pointer to the base class's own `GetTypeInfo()`** -- both
  resolve to `module+0x27E86B0`, exactly `Entity::GetTypeInfo()`. Direct
  confirmation this is real per-class reflection metadata with a working
  parent-class back-reference, not garbage.
- **`+0x07`: a pointer to `(this record's own address) + 0xA0`** --
  confirmed on *both* classes independently (`14285FE50 -> 14285FEF0`,
  `1428641A0 -> 142864240`). Followed that pointer and dumped the target:
  it's **another record with the identical shape** (same `+0x15`
  back-pointer to `Entity::GetTypeInfo()`, same `+0x07` pattern pointing
  to *its own* `+0xA0`, confirmed by dumping a third link in the chain
  from the second one). This is a **linked list of fixed-size
  (~0xA0-byte) type-descriptor records**, walkable via the `+0x07` "next"
  pointer -- almost certainly Frostbite's global reflection type registry
  (every `Entity`-derived class in the game gets a node), not anything
  specific to progression flags or live instances.

**Conclusion: this data answers "what class is this" and "what's its
parent class," not "what live objects of this class currently exist."**
It's the class-level registry, structurally analogous to what
`GetTypeInfo()` already gave us to begin with -- walking it further just
visits *other classes'* descriptor nodes, not instances of these two.
Continuing to decode the remaining undecoded fields in this same record
(the still-unexplained bytes at `+0x00`-`+0x06` and `+0x0F`-`+0x14`) is
unlikely to change that conclusion, since nothing about a flat class
registry would carry a live-instance list. Real, useful reverse-engineering
result (confirms the shape of the engine's type-registration system, in
case that's useful for a future, different investigation), but a dead end
for the specific goal this thread was chasing.

---

## §32. Live-breakpoint technique succeeds: real code found reading a `PamProgressionFlag` object

Continuing the "hunt the client/server flag entity" session, after the `Name`
field (`+0x18`) produced zero hits under extensive testing, three numeric
fields on the same live `Unlocks_PositionalAdvantage` flag object (address
`0x2A192820` this session, per `progression_snapshot.json`) were broken on
simultaneously via Cheat Engine's "Find out what accesses this address":

| Field | Offset | Address | Hits | Instruction(s) |
|---|---|---|---|---|
| `cost` | `+0x24` | `2A19285C` | 1 | `143A1BF8A - 8B 41 24 - mov eax,[rcx+24]` |
| `maxValue` | `+0x20` | `2A192858` | 1 | `143A1BFD8 - 8B 41 20 - mov eax,[rcx+20]` |
| `nameHash` | `+0x10` | `2A192848` | 2 | `1439E2274 - 8B 51 10 - mov ecx,[rax+10]`<br>`143A1BF63 - 8B 41 10 - mov eax,[rcx+10]` |

This is the first positive result from the live-breakpoint technique this
project has produced. It proves real game code touches this exact
`PamProgressionFlag` object during live execution (menu open, most likely —
these are classic "populate a UI row" reads), which the earlier
`PamProgressionFlagEntityData` line of investigation never achieved (that
class was write-tested directly and shown to be inert instead).

Two observations worth tracking into the next step:

- `143A1BF8A` (cost) and `143A1BFD8` (maxValue) are only `0x4E` bytes apart
  and both read off `rcx` — almost certainly the same function, reading
  multiple fields off the same object pointer to build one UI element
  (e.g. an ability tile: cost to display, maxValue for a pips/level bar).
  This is the more promising thread to pull first, since it's a single
  function with multiple confirmed field reads to anchor on.
- The two `nameHash` hits are at different addresses and use different
  register pairs (`rax`->`ecx` vs `rcx`->`eax`), i.e. two distinct call
  sites. `143A1BF63` is close to the cost/maxValue pair (same function,
  reading `nameHash` too, presumably to key a localization/lookup table —
  consistent with the earlier hypothesis for why the raw `Name` pointer
  itself was never read). `1439E2274` is a separate, currently unidentified
  call site — possibly earlier UI construction (building the full ability
  list) rather than a per-row detail read.

**Important framing point:** this `PamProgressionFlag` struct (fields
`nameHash`, `missionIndex`, `name`, `maxValue`, `cost`, `reputation`,
`syncStatName`, `clamp`, `syncToOnline`) is the *static definition* of an
ability slot — cost and maxValue are constants, not per-save state. Finding
code that reads them confirms UI code walks this table, but does **not** by
itself locate the runtime "is this owned" bit, which must live somewhere
else (a separate owned/purchased array or bitset, most likely indexed by
the same `nameHash` or by position in the `PamProgressionFlagGroup.Flags`
array). The next step is to use these confirmed hit addresses as an entry
point into the surrounding disassembly and look for a sibling read (off the
same base pointer, or a related one) of what would be an "owned" boolean —
or a call out to a function that returns one.

**Not yet done:** opening the disassembler on any of these hits. That's the
immediate next action for the next session/step.

---

## §33. Disassembly of the hit addresses: identified as a stat-formatting function, not the ownership check

Opened the disassembler on the `cost` hit (`143A1BF8A`) and the `nameHash`
hit (`143A1BF63`). Both land in the **same function**, roughly spanning
`MirrorsEdgeCatalyst.exe+3A1BF4x` to `+3A1BFF2` (`3A1BF63 < 3A1BF8A`, both
inside one `push rbx ... pop rbx; ret` body). This also explains the earlier
"two nameHash call sites" observation only partially: `143A1BF63` is one of
them (inside this function); the other, `1439E2274`, is a separate,
still-unexamined call site elsewhere.

**Function shape (prologue seen at the bottom of the disassembler view):**
```
push rbx
sub  rsp, 20
mov  rbx, rcx          ; rbx = "this" (a UI element/widget pointer)
add  rcx, 48
cmp  qword ptr [rcx], 00
je   +...
```
Then a repeating block runs once per "stat slot" at `rbx+30`, `rbx+38`,
`rbx+40`, `rbx+50` (slot addresses aren't evenly spaced — not a simple
array, more likely distinct named fields on a UI widget struct: probably
nameHash-slot, cost-slot, maxValue-slot, reputation-slot):
```
cmp  qword ptr [rbx+<slot>], 00      ; is this UI slot's target object set?
mov  rax, [rbx+28]                   ; rax = pointer field on the widget
mov  rcx, [rax+20]                   ; rcx = the PamProgressionFlag* itself
mov  eax, [rcx+<field>]              ; read nameHash(+10) / maxValue(+20) / cost(+24) / reputation(+28)
lea  rcx, [rbx+<slot>]               ; rcx = destination slot pointer
mov  [rsp+30], eax                   ; stash raw value on the stack
je   ...                             ; (tests the earlier cmp's flags) skip if slot pointer was null
lea  rdx, [rsp+30]
mov  r8b, 01
call MirrorsEdgeCatalyst.exe+2A430F0 ; generic value->text formatter, called once per slot
```
`+2A430F0` is called identically for all four fields (same calling
convention: `rcx`=destination slot, `rdx`=`&rawValue`, `r8b`=1) — almost
certainly a generic "format this number into this UI text slot" helper, not
anything progression-specific.

**Conclusion: this function formats an ability's stat panel (name-hash
lookup key, cost, maxValue, reputation) into on-screen text. It does not
branch on, or reveal, ownership state at all** — it unconditionally
formats whatever the flag object's static fields say, gated only by
"does this UI slot exist" (a widget-construction guard), not "is this
ability owned." The immediately-following code in the same memory region
(a call into an `"Enlighten"`-tagged function) is unrelated Frostbite
global-illumination code that happens to sit next in the binary — a red
herring, not connected to progression at all.

**Next step, not yet done:** find the *caller* of this stat-formatting
function, since the caller is what decides whether/how to show this panel
per ability, and is a much likelier place to find an ownership branch.
Approach: set a plain execution breakpoint on the function's first
instruction (the `push rbx` seen in the prologue), trigger the ability
detail UI again in-game, and when it breaks, read the return address off
the stack (top of stack right after `push rbx`, or via CE's Stack pane) to
identify the call site, then jump there with Ctrl+G.

---

## §34. Caller identified via execution breakpoint + call stack

Set a plain execution breakpoint on the stat-formatter function's entry
point (`push rbx` at `143A1BF30`, confirmed by `RIP` matching exactly on
hit). Triggering the ability detail UI again hit it, and Cheat Engine's
Memory Viewer showed the full call stack (not just the immediate return
address), 17 frames deep down to `ntdll.RtlUserThreadStart` — consistent
with this being deep inside nested UI/menu framework code.

**Immediate caller (top of stack, the address right after whichever `call`
invoked the stat-formatter): `MirrorsEdgeCatalyst.exe+3A11461`.**

Rest of the stack, for reference (each is a return address into
progressively higher-level UI code, not yet examined):
`3A101BA`, `31671E3`, `31C45D7`, `325362F`, `3254584`, `2D37D37`,
`2D39138`, `2A98B07`, `2A98555`, `326930C`, `31A4ECF`, `2A2E069`,
`2A315B5`, `agsGetEyefi...` (partial symbol, an AGS/AMD-related import,
likely an unrelated thunk in this same jump table), `2A6342B`, `2C7884D`,
then MSVCR120/KERNEL32/ntdll thread-launch boilerplate.

**Next step (not yet done):** jump to `+3A11461` (the actual `call`
instruction is ~5 bytes earlier, around `+3A1145C`), and read the
surrounding code for a branch that could be gating *whether*/*how* the
stat panel gets built — e.g. an owned-vs-locked UI state check. This is
the current best candidate location for the actual ownership/purchase
check.

---

## §35. Caller identified as tile-display-data builder (text + stats), not ownership; confirms localization-by-ID hypothesis

Jumped to the caller (`+3A11461`) and confirmed the exact call site:
`3A1145C: call MirrorsEdgeCatalyst.exe+3A1BF30` (our known stat-formatter
from §33), immediately followed by `3A11461: nop` — matches the return
address from §34 exactly.

The containing function starts at `3A11257` (prologue: `push rbp/rsi/rdi;
sub rsp,40`, params renamed `rsi=rcx, rbx=rdx, rdi=r8`, then an early
`call +3160100` setup/validation call). Immediately before calling the
stat-formatter, it runs **six near-identical blocks**, each:
```
mov  [rsp+28], r14
mov  [rsp+20], <context pointer, usually a fixed lea to +27B0D38>
mov  r9d, <32-bit constant, shown decoded as a small decimal in the CE comment>
mov  r8, rdi
lea  rdx, [rsp+68]
mov  rcx, [rbx]
call MirrorsEdgeCatalyst.exe+31462A0
mov  rax, [rsp+68]
mov  [rsi+<slot>], rax
```
with `r9d` constants `236`, `0`, `149`, `207` (plus two more not fully
captured) and destination slots `rsi+30/38/40/48/50/58` in sequence, then
finally `mov rcx, rsi; call +3A1BF30` (our stat-formatter) to fill in the
numeric fields on the same object.

**This is a "resolve localized text by numeric ID" pattern** — six calls
into `+31462A0` with distinct small-integer IDs, writing each resolved
value into consecutive slots on the tile object. This directly confirms
the hypothesis from the earlier `Name`-field zero-hit result (§ from prior
session): ability names/descriptions aren't read from a raw string pointer
on the `PamProgressionFlag` object at all — they're looked up by ID through
a separate localization table, which is why breaking on that pointer never
fired.

**Conclusion: this whole function (`3A11257`+) builds one ability tile's
full display payload — six localized text fields, then four numeric
stats — unconditionally, for every tile regardless of ownership.** No
ownership branch found in it. This is expected: locked tiles still need a
name, description, and cost shown.

**Next step (not yet done):** climb one more frame in the call stack to
`MirrorsEdgeCatalyst.exe+3A101BA` (the next return address from §34's
stack), which is a better candidate for the actual per-row ownership/lock
logic (icon selection, "owned" badge, enabling the Buy button) than the
pure content-population code found here.

---

## §36-37. Exact match found: code references `PamClientProgressionFlagEntity::GetTypeInfo()` directly during ability-tile construction

Climbing the call stack from the stat-formatter (§34) surfaced a family of
near-identical sibling functions (seen at `3A100A0` and `3A10160`), each
shaped like:
```
call <hash-resolve function, +31668F0>      ; resolve some object by a 32-bit hash constant
test rax,rax / rbx,rbx ...                  ; null checks
mov  r8,[rbx+000000D0]                      ; read a field off the outer "this"
call <per-field helper, e.g. +3A11260 or +3A11330>
mov  rsi,rax
...
lea  rdx,[<a type-descriptor address>]
mov  rcx,rsi
call MirrorsEdgeCatalyst.exe+3166EA0        ; (rcx=widget, rdx=type descriptor, r8=extra)
mov  rcx,rbx
call +3168210
xor  r8d,r8d
mov  rdx,rsi
mov  rcx,rbx
call +31668A0
mov  rax,rsi
ret
```

**First instance** (`3A10160`) loaded `rdx` from `module+0x285FDB0` — exactly
`0xA0` (one type-registry record stride, confirmed in §31) before the known
`PamClientProgressionFlagEntity::GetTypeInfo()` RVA (`0x285FE50`). Verified
by direct calculation, not approximation.

**Second instance** (`3A100A0`, a sibling of the first with a different hash
constant) loaded `rdx` from `module+0x285FE50` directly — this is the
*exact, literal* RVA for `PamClientProgressionFlagEntity::GetTypeInfo()`
from the SDK header, byte-for-byte identical, not merely nearby.

**This is the first confirmed reference in live game code to this specific
class's type info found so far.** Both instances funnel into the same
function, `MirrorsEdgeCatalyst.exe+3166EA0`, called with (widget object,
type descriptor, extra pointer). Its return value is not tested/branched
on in either call site, which argues against a simple pass/fail
cast-and-check and leans toward something like "register/subscribe this
widget to entities of this type" — a live-update wiring mechanism, which
if true would mean `+3166EA0`'s internals are where the game actually
locates or tracks live `PamClientProgressionFlagEntity` instances.

**Next step, not yet done:** disassemble `MirrorsEdgeCatalyst.exe+3166EA0`
itself. This is currently the highest-value unknown function in the whole
trace, since it's the one piece of code definitively tied to the class
that defeated the entire previous session's RTTI/type-registry hunt.

---

## §38. `+3166EA0` disassembled: a generic dirty-flag utility, not a type check — correcting the §37 hypothesis

`MirrorsEdgeCatalyst.exe+3166EA0` turned out to be a **tiny 18-byte
function**, not the large block initially visible in the same screenshot
(that larger block, starting at `+3166EC0` after `int 3` padding, is a
separate, unrelated function that just happens to sit next in memory —
same pattern as the `"Enlighten"` red herring in §33; not part of this
call chain and shouldn't be read into).

The actual body of `+3166EA0`:
```
or   dword ptr [rcx+18], 02      ; set bit 0x02 in a flags field on rcx (the widget)
test r9b, r9b
je   +3166EB2                    ; -> ret
mov  rax, [rcx]                  ; rax = rcx's vtable
mov  rdx, r8                     ; overwrite rdx (the type-descriptor arg!) with r8
jmp  qword ptr [rax+68]          ; tail-call rcx's vtable slot +0x68, passing (rcx, r8)
ret
```

**Correction to §37's hypothesis: the type-descriptor pointer passed in
`rdx` at the call site is not used by this function at all** — it's
clobbered by `mov rdx,r8` before the one branch that would do anything
with it, so it never reaches the vtable dispatch either. This function is
just "mark this widget dirty (flag `0x02` at `+0x18`), and conditionally
forward a virtual call passing a *different* argument (`r8`)." Generic UI
widget-property-binding plumbing, not a type check/cast.

**This specific lead is a dead end.** The exact-address match to
`PamClientProgressionFlagEntity::GetTypeInfo()` found in §37 is still a
real, verified fact about what the caller loads into a register — but
whatever consumes it meaningfully (if anything does) isn't this function.
It's possible the type-descriptor argument is simply dead/vestigial in
this particular call-site instantiation of a templated helper (common in
Frostbite's generated property-binding code, where the same call shape is
reused across many field types regardless of whether every parameter is
needed by every specialization).

**State of the investigation:** several call-stack frames climbed so far
(stat-formatter -> tile-content-builder -> per-widget-type helper) have
all turned out to be generic UI/content-binding infrastructure, not an
ownership check. The `PamProgressionFlag` object itself (nameHash,
missionIndex, name, maxValue, cost, reputation, syncStatName, clamp,
syncToOnline) is confirmed to hold only the *static definition* of an
ability slot -- no candidate "owned" field exists on it. The live
ownership/purchase state is very likely stored on a completely separate
object, not discoverable by continuing to climb display-code call stacks
that were only ever going to explain *what gets shown*, not *whether it's
unlocked*.

**Open options for next session, not yet decided:**
1. Keep climbing the call stack (many frames remain per §34's captured
   stack, but risk of more generic UI glue is high based on this pattern).
2. Pivot to a direct value-scan technique: use Cheat Engine's classic
   "Unknown initial value -> scan for changed value" workflow timed around
   an actual in-game ability purchase, rather than continuing to trace
   display code -- this could locate the authoritative live flag much
   faster than further disassembly climbing.
3. Stop here for the session; substantial forward progress has been made
   documenting the UI construction pipeline even though the core "owned"
   question remains open.

---

## §39. Next frame up (`+31671E3`) is generic vector/transform math — call stack has left progression-specific territory

Jumped to the next call-stack frame, `MirrorsEdgeCatalyst.exe+31671E3`
(a `jmp` to `+3167674`, meaning the real return context is a few
instructions earlier around `+3167188`). Unlike every frame examined so
far, this one is unambiguously **generic engine-level code**, not
UI-content binding:

- Heavy SIMD throughout: `movaps`/`movss`/`pshufd` moving 16-byte XMM
  registers in/out of `[rdi+40]`, `[rdi+50]`, `[rdi+60]`, `[rdi+70]` —
  the classic shape of a 4-row matrix or a set of 4 vector/quaternion
  slots (transform/animation blending).
- A small `dec ecx; je ...` chain (three cases) — a switch on a small
  integer enum, most likely a layout/anchor-type or interpolation-mode
  selector.
- A comparison against the sentinel constant `0xAFAFAFAF` — a classic
  "uninitialized memory" debug-fill pattern, further suggesting this is
  generic/shared code with defensive checks, not something specific to
  one particular UI element type.
- Calls out to `+46513D0` and `+2A424B0`, both unnamed and consistent
  with generic math/formatting helpers rather than progression-specific
  logic.

**Assessment: this frame is very likely a generic UI transform/animation
update routine, shared by every widget in the menu system (position,
scale, blend state), not anything progression- or ownership-specific.**
Combined with the outcome of §38 (the immediately-lower frame was also
generic, a dirty-flag/vtable-dispatch utility), this is a second
consecutive frame with no connection to ability-specific data. The call
stack from here upward is likely to continue through general
engine/rendering machinery (frame update, layout, animation) rather than
back toward per-ability ownership logic, since that logic is more likely
computed earlier -- when the ability list's data is first built/filtered,
before any of this per-widget rendering machinery runs -- than
discoverable by climbing further up a rendering call stack.

Flagged to the user as a signal worth reconsidering the "keep climbing"
approach in favor of the direct live-purchase value-scan alternative
(option 2 from §38), pending their decision.

---

## §40. Pivot: live purchase value-scan (in progress)

Decided to stop climbing the display-code call stack (§39) and pivot to
a direct memory value-scan technique, timed around a real in-game ability
purchase, to find the authoritative "owned" state directly rather than
inferring it from UI code.

**Planned procedure (CE main scanner, not Memory Viewer):**
1. Pick a currently-locked-but-affordable, mission-unlocked ability as the
   test target (note its name and known `PamProgressionFlag` address from
   `dump_progression_state.py`/`progression_snapshot.json` for later
   cross-referencing).
2. First Scan: Value Type `4 Bytes`, Scan Type `Unknown initial value`.
3. In-game, purchase that ability.
4. Next Scan: Scan Type `Changed value` (try `Increased value` too if
   `Changed value` is unmanageably large -- an owned/purchased-count flag
   going from 0 to a positive value is a very plausible pattern).
5. Prune remaining noise with 2-3 rounds of `Next Scan` -> `Unchanged
   value` while sitting idle for a couple seconds each round, to kill off
   animation/timer values that keep changing independent of the purchase.
6. If the result set is still large, repeat the whole process on a
   *second*, different ability (fresh `New Scan`) and cross-reference:
   look for a hit in both result sets at the same relative offset from
   each ability's own known flag-object address -- strong evidence of a
   per-ability array entry (owned/purchased state stored in a parallel
   array to `PamProgressionFlagGroup.Flags`, indexed the same way).
7. If `4 Bytes` doesn't produce a clean candidate, retry the same
   procedure with Value Type `Byte` (owned/purchased could plausibly be a
   1-byte bool rather than an int).

Not yet executed at time of writing -- next screenshot(s) should show the
scan results.

---

## §41. Save-file edit: boosted `XP_Gained` for easier testing

Between value-scan setup steps, boosted `XP_Gained` in the live `PROF_SAVE`
to make testing many ability purchases easier (target ability chosen:
"Fiber Weave", +1 Stamina, Combat tree).

Read current values first (via `patch_save.py`'s own hash/section-walking
logic against a staged copy of the real save):

| Section | XP_Gained (old) | XP_Used |
|---|---|---|
| `ProgressionManagerData_2411670393` | 5405 | 5000 |
| `ProgressionManagerData` | 27481 | 27000 |
| `ProgressionManagerData_1000106553270` | 7357 | 6000 |

Patched `XP_Gained` -> `999999` in all three sections with `patch_save.py`
(file size unchanged, checksums recomputed), left `XP_Used` untouched so
whichever section the game actually reads has a large spendable pool.
Backed up the pre-edit save alongside it as `PROF_SAVE.before_xpboost`.
Confirmed game was fully closed before writing (per the established
§15/§15a/§15b safe-write rule), then wrote both files to
`Documents\Mirrors Edge Catalyst\settings\`.

Not yet verified in-game that the displayed "Upgrade Points" number
changed as expected -- worth noting the earlier open question (referenced
elsewhere in this doc) that the on-screen number doesn't always equal the
raw `XP_Gained - XP_Used` for a single section cleanly; this is a
practical test of that too.

---

## §42. Value-scan breakthrough: found a live category owned-count write, single clean write site

Following the pivot to a direct value-scan (§40-41), narrowed a purchase
of "Fiber Weave" (+1 Stamina, Combat tree, 5/20 -> 6/20) from 5.7M
candidates down to 4 via: `Unknown initial value` -> `Increased value` ->
several rounds of idle `Unchanged value` pruning -> a final `Exact value
= 6` filter (since the Combat tree count was known to land on exactly 6).

Final 4 candidates:
| Address | First | Previous | Value |
|---|---|---|---|
| `03DE3010` | 5 | 6 | 6 |
| `25CD12A8` | 5 | 6 | 6 |
| `25CD2E68` | 5 | 6 | 6 |
| `2E0136094` | 0 | 6 | 6 (outlier -- doesn't fit the 5->6 pattern, likely coincidental, deprioritized) |

Ran "Find out what writes to this address" on all three 5->6 candidates
simultaneously. Result:
- `25CD2E68` and `25CD12A8`: **identical single hit**,
  `1439E19AA - 89 43 28 - mov [rbx+28],eax` (module RVA `0x39E19AA`,
  computed and verified). Same write instruction for both addresses --
  strong evidence these are two live instances of the same per-category
  struct (most likely Combat's and Movement's category-count objects,
  both updated through one shared function), with the owned/purchased
  count sitting at `+0x28`.
- `03DE3010`: zero hits -- wasn't written during this purchase at all.
  Dropped as a coincidental false positive.

**This is a single, clean write site** -- a sharp contrast to the deep,
generic UI-rendering call stack climbed in §33-39. Since bumping the
category count and flipping the individual ability's owned state almost
certainly happen in the same transaction/function, the code around
`module+0x39E19AA` is the best candidate yet for finally revealing the
per-ability ownership write.

**Next step, not yet done:** open the disassembler at `1439E19AA` (or
nearby) and read the surrounding function.

---

## §43. First transactional (locked) code found -- disassembly of the category-count write function

Opened the disassembler at `1439E19AA` (module RVA `0x39E19AA`, from §42).
This is a genuinely different kind of code from everything examined in
§33-39: **wrapped in a critical section**. Immediately after our target
write, the function calls `ntdll.RtlLeaveCriticalSection` (via
`MirrorsEdgeCatalyst.exe+4815140` import) and returns `true`
(`movzx eax,r13b` where `r13b` was set to `01`). A matching
`EnterCriticalSection` must exist earlier in the function, not yet seen.
This is the first genuinely transactional, non-UI-rendering code found in
the entire investigation.

**The target write is a copy, not an increment:**
```
mov  rax, [rsp+000000A0]
mov  eax, [rax+04]
mov  [rbx+28], eax        ; our known write -- copies rax's +4 field into rbx's +28 field
```
So the actual "+1" computation happens somewhere upstream of this
function (or upstream in a caller), on whatever object `[rsp+A0]` points
to -- this function is a sync/commit step, not the primary counter logic.

**A promising array-walk immediately precedes it**, matching the
length-prefixed `Array<T>` shape already known from
`dump_progression_state.py` (`PamProgressionFlagGroup.Flags`):
```
mov  r15, [r8+28]          ; array data pointer
mov  eax, [r15-04]         ; length (stored 4 bytes before the data -- Frostbite Array<T> convention)
lea  r13, [r15+rax*8]      ; end pointer
cmp  r15, r13
je   <skip>                 ; empty-array guard
...loop body...
```
Inside the loop, a call to `MirrorsEdgeCatalyst.exe+2A34880` is made with
`r8=r15` (the current array element -- quite possibly a specific ability
flag pointer), `rdx=rbp`, `rcx=rbx`. This is the current best candidate
for the actual per-ability ownership write, pending investigation.
Immediately after that call: `inc [r14+68]` -- increments a *different*
counter field on a different object (`r14`), not yet identified.

**Not yet seen:** the true entry point of this function (everything above
is mid-function; screenshots so far start at `39E18FE`). Next step is to
scroll further up in the disassembler to find the `EnterCriticalSection`
call and initial parameter setup, which should identify what each of
`rbx`, `r14`, `r8`, `rbp`, `rsi` actually are.

---

## §44. Function structure clarified: three tree lookups, gated cache-sync write, common inner call

Scrolled up through the rest of this function (`39E1775` through `39E19AA`
now fully mapped). Cleaner picture:

**The function performs three near-identical tree/map search-and-insert
blocks** (classic red-black-tree walk shape: `cmp rbx,rbp/r15; je <empty>;
call +2A34820 <comparator>; cmp [node+20],rsi; setb al; ...` walking left
or right based on the comparison), each keyed against a value held
constant in `rsi` throughout the whole function -- very likely the
ability's `nameHash` or an equivalent unique ID. After each search, if no
matching node was found, a new one is allocated (`call +2A647D0`, a
generic allocator/constructor: `[node]=rsi; [node+8]=0; [node+10]=0`).

**Each of the three blocks ends by calling `MirrorsEdgeCatalyst.exe+2A34880`**
with a consistent register shape (`rcx`=container object, `rdx`=the
found/inserted tree node, `r8`=an iteration cursor, `r9`=a small
int/flag), immediately followed by `inc [r14+68]` (a counter bump on a
shared object, separate from the per-category count). This is the one
piece of actual mutation logic common to all three lookups -- strongest
remaining candidate for where real per-ability state gets written.

**Confirmed: our known write (`mov [rbx+28],eax`, §42-43) is gated,
not unconditional:**
```
mov  rax, [rsp+A0]
mov  eax, [rax+04]
cmp  [rbx+28], eax
je   +39E19B0          ; <-- if already equal, skip straight to the end (no write, no lock release change)
```
This confirms the write is a "sync the cached/displayed count only if it
differs from the canonical value" pattern, not the place where the
canonical value is computed. The real counting/ownership logic is further
upstream -- almost certainly inside the tree-node work or `+2A34880`.

**Next step, not yet done:** disassemble `MirrorsEdgeCatalyst.exe+2A34880`
directly -- it's the one consistent "do the real work" call shared by all
three tree-search blocks in this function, and the best remaining lead
for the actual per-ability ownership mutation.

---

## §45. Major reframe: `+2A34880` is generic red-black-tree insert, not custom ownership logic -- but that changes the hypothesis for the better

Disassembled `MirrorsEdgeCatalyst.exe+2A34880` fully. **This is not
progression-specific code at all -- it's a textbook red-black-tree
insert-and-rebalance routine**, matching the MSVC STL `_Tree_node` layout
almost exactly: node fields `+0x00`=left child, `+0x08`=right child,
`+0x10`=parent, `+0x18`=color byte (checked via `cmp byte ptr[x+18],00`
throughout, classic red/black test). The function links a new node in
under its parent, then performs the standard rotate/recolor fixup
(`+2A348C0` onward: the parent/grandparent color-flip and rotation
pattern is unmistakably `std::map`/`std::set`-style insert-fixup logic).
Confirmed by cross-checking against the earlier `+2A34820`/`+2A34810`
calls too, which fit the shape of a tree comparator and a
"find-or-insert" driver respectively.

**This means `+2A34880` itself has zero ability-specific logic** -- it's
identical, generic container plumbing the engine would use for any
red-black tree anywhere. The three tree-search-and-insert blocks in the
caller (§44) aren't three different progression checks; they're the same
generic "find or insert a key" operation performed against three
different tree instances (fields at `r14+0x40/0x48/0x58/0x70`-ish
offsets -- likely a small set of indices/caches maintained per category
or per manager).

**But this reframes the hypothesis in a promising way.** If ownership
isn't a boolean field at all, but rather **set membership** -- i.e. "this
ability is owned" == "this ability's hash (`rsi` throughout the caller)
is present as a key in this tree" -- then the *insertion itself*, not
some flag write, is the actual grant operation. This would be a clean,
idiomatic design (`std::set<uint32_t>` of owned-ability hashes, or
similar) and would explain why no dedicated "owned" boolean field was
ever found on the `PamProgressionFlag` object (§38) or anywhere else in
this entire investigation: there isn't one. Ownership is presence in a
tree, not a bit.

**If confirmed, this also changes what "grant an ability live" would
require**: not finding-and-flipping a flag, but performing a correct
tree insert with the target ability's hash -- either by replicating the
insert logic directly, or (far simpler and safer) by calling this exact
game code via injection with the right arguments, letting the game's own
insert-and-rebalance logic do the work correctly.

**Next step, not yet done:** identify the actual tree root object (what
`r14` and its `+0x40/+0x48/+0x58/+0x70`-shaped fields belong to), dump/walk
it in Cheat Engine, and check directly: does it now contain a node keyed
by Fiber Weave's hash? And do other, still-locked abilities' hashes
correctly *not* appear? That would definitively confirm or refute the
set-membership hypothesis, and if confirmed, identify exactly which tree
instance is "the" owned-abilities index.

---

## §46. Starting point for the next session

**Immediate first step, no scanning needed:** attach Cheat Engine, set a
breakpoint directly on `MirrorsEdgeCatalyst.exe+0x39E19AA` (the known
category-count sync write from §42-43 -- `mov [rbx+28],eax`). Buy any
ability in-game to trigger it. This instantly gives fresh, current-session
values for `rbx` (the category-count struct) and, by scrolling up in the
same disassembler view, `r14` (the object whose `+0x40/+0x48/+0x58/+0x70`
fields hold what look like tree roots -- see §44-45). No need to repeat
the 5.7M-result value-scan or the call-stack climb; the code addresses are
stable across restarts, only the live heap addresses change.

**What to chase from there:** the set-membership hypothesis from §45 --
that "is this ability owned" means "is this ability's `nameHash` present
as a key in one of these red-black trees," rather than a boolean field
anywhere. Concretely:
1. Identify which of `r14`'s tree-root-shaped fields is the one that
   received Fiber Weave's hash on this purchase (the block whose tree
   search used the matching `rsi` value -- may need to watch which of the
   three tree-search blocks in the `+0x39E19AA`-containing function
   actually inserts vs. just finds-already-present, by single-stepping or
   comparing before/after tree contents).
2. Dump/walk that tree's nodes in Cheat Engine (standard RB-tree walk:
   each node has left-child/right-child/parent/color at
   `+0x00/+0x08/+0x10/+0x18`; the actual key, given the comparator reads
   `[node+20]`, is very likely stored at `+0x20`).
3. Confirm Fiber Weave's known `nameHash` (or an equivalent per-ability
   hash/id -- may need to recompute via the same `djb2a`-style hash used
   for save-file flag names, or find where this tree's key differs from
   that) is now present, and that a still-locked ability's hash is
   correctly absent.
4. If confirmed: this either directly gives a live-grant mechanism
   (replicate the insert, or call the game's own insert function via
   injection with the right register setup) or at minimum tells us
   precisely what a "grant" needs to write and where.

**Status recap for whoever picks this up:** the restart-blocker
investigation has moved from "no leads" (start of this session) to "a
specific, disassembled, cross-verified code path with a concrete,
testable hypothesis about the storage mechanism." This is the strongest
position this thread has been in across the whole project so far.

---

## §47. New session: fresh breakpoint hit, R14 struct decoded, first tree node dumped

Following §46's plan exactly: attached CE, set a breakpoint directly on
the known code address `+0x39E19AA` (no re-scanning needed), bought
"Fiber Weave" again. Hit immediately, confirmed by `RIP` matching.

**Live register capture (this session, will differ next launch):**
- `RBX = 0x25AD2800` (category-count struct)
- `R14 = 0x2BBC3160`
- `R15 = 0x2BBC31A8` (confirmed = `R14+0x48`, as predicted in §44)
- `RSI = RDX = 0x2A1D8848` -- the tree search key throughout the function;
  looks like a heap pointer, not a raw hash, supporting the "keyed by
  object pointer identity" reading of the tree from §45. Best candidate
  for the live `PamProgressionFlag*` of the ability just purchased.

**`R14`'s struct, decoded field by field (all offsets from `R14`):**
| Offset | Value | Interpretation |
|---|---|---|
| `+0x00` | `0x141C64B38` | code pointer (module+0x1C64B38) -- likely vtable |
| `+0x18` | `0x141C64BA8` | another nearby code pointer |
| `+0x40` | ASCII `"2b8a73ff"` | inline debug-tag string, not a pointer |
| `+0x48` | `0x25AD36C0` | heap pointer -- **candidate tree root #1** |
| `+0x58` | `0x25AA0780` | heap pointer (different heap page) -- **candidate tree root #2** |
| `+0x68` | (plain counter) | incremented via `inc [r14+68]` in the purchase code (§43-44) |
| `+0x70` | `0x1423606D0` | code pointer -- a callback/vtable slot, not tree-related |

**First node of candidate tree #1 dumped** (`0x25AD36C0`), matching the
assumed RB-tree node layout (`+0x00`=left, `+0x08`=right, `+0x10`=parent,
`+0x18`=color byte, `+0x20`=key):
- `left = NULL`
- `right = 0x25ADF8C0`
- `parent = 0x25AD5B40`
- `color = 1` (confirms the `+0x18` byte offset cleanly)
- `key = 0x2A1DB700` -- same heap region as `TARGET` (`0x2A1D8848`) but not
  an exact match, and numerically larger. A plain BST search would go
  left for a smaller target, but left is NULL here -- ambiguous whether
  this is genuinely "not found" or whether `0x25AD36C0` is actually a
  sentinel/header node rather than the true root (its `parent` field,
  `0x25AD5B40`, is a plausible alternate root to check).

**Built `walk_ownership_tree.lua`** (committed to
`C:\not garbage\Archipelago\ME-AP\runtime\walk_ownership_tree.lua`) to
automate the rest of this rather than continuing one-field-at-a-time
screenshots. It recursively walks both candidate trees (and each
candidate's parent, in case of a sentinel/header node) searching for
`TARGET = 0x2A1D8848`, printing the full path and every node visited.
Not yet run -- next step.

---

## §48. v1 tree walk: header/root structure clarified, but left/right sense was flipped

Ran `walk_ownership_tree.lua` (v1). Full output revealed the real
structure, and a bug in the walk direction:

**`R14+0x48` (`0x2BBC31A8`) is the tree's embedded header/sentinel node**,
not a separate tree -- its fields: `left=0x25AD36C0`, `right=0x25AA0B00`,
`parent=0x25AA0780`, `color=0`. In standard STL-style RB-tree containers
the header's `parent` field holds the true root. That means **the real
root is `0x25AA0780`** (which is exactly the value stored at `R14+0x58`,
confirming `R14+0x58` is a cached direct pointer to the root). `R14+0x48`
and `R14+0x58` are not two separate trees (§47's original framing) --
they're two different access paths (header vs. cached root) into the
*same* single tree.

**Bug found via the walk output:** descending via the `+0x00` field
(labeled "left" by assumption) from the root produced a strictly
*increasing* key sequence (`2A1DA098 -> 2A1DA458 -> 2A1DA988 -> 2A1DAFB8
-> 2A1DB700`) even though the walk logic only takes that branch when
`target < key` -- backwards from normal BST convention (should decrease).
So either the `+0x00`/`+0x08` fields are the reverse of "left"/"right", or
the tree's comparator sense is inverted. Since the specific semantics
don't matter for our actual question (does `TARGET` appear anywhere),
**wrote `walk_ownership_tree_v2.lua`**: an exhaustive DFS that visits every
node via both child pointers regardless of ordering, with a visited-set
guard against cycles, reporting every key found and whether `TARGET`
(`0x2A1D8848`) appears anywhere in the tree. Committed to
`runtime/walk_ownership_tree_v2.lua`. Not yet run -- next step.

---

## §49. v2 tree walk: TARGET found -- but at the same node as the count-write, raising a new ambiguity

Ran `walk_ownership_tree_v2.lua` (exhaustive DFS from the confirmed real
root `0x25AA0780`). Result: **25 total nodes visited, and `TARGET`
(`0x2A1D8848`) IS present**, at node `0x25AD2800`.

All 25 keys found (sorted): `2A1D87F8, 2A1D8848, 2A1D8A58, 2A1D8AA8,
2A1D8D18, 2A1D8F28, 2A1D9078, 2A1D9258, 2A1D9358, 2A1D97C0, 2A1D9A68,
2A1D9DA8, 2A1D9FC8, 2A1DA098, 2A1DA0E8, 2A1DA138, 2A1DA2D0, 2A1DA458,
2A1DA508, 2A1DA8B8, 2A1DA988, 2A1DAD48, 2A1DAFB8, 2A1DB270, 2A1DB700`.
All fall within a tight, contiguous-looking range (`2A1D87F8`-`2A1DB700`,
~0x2F00 apart, evenly-ish spaced), consistent with 25 same-sized objects
packed in one heap region -- plausibly all 25 (or close to it) of the
Combat category's `PamProgressionFlag` objects, or all currently-visible
tile records, not obviously distinguishable from the key list alone.

**Important wrinkle: node `0x25AD2800` is the *exact same address* as
`RBX` captured at this session's `+0x39E19AA` breakpoint** (§47) -- i.e.
the object whose `+0x28` field is the count-sync write target from
§42-43. So this one object is simultaneously: (a) a node in this tree,
keyed at `+0x20` by the just-purchased ability's own pointer, and (b) the
thing that receives the "sync the displayed count" write.

**This is genuinely ambiguous between two readings**, both consistent
with every observation so far:
1. **Ownership-as-membership (§45's original hypothesis) is correct**:
   this tree tracks owned abilities, keyed by their live pointer: each
   node also caches a display-relevant count.
2. **This is actually a UI-side display/format cache**, keyed by
   whatever data pointer the currently-rendered tile is bound to
   (owned or not), holding cached formatted/synced values for that
   tile -- not an authoritative ownership store at all.

**Proposed disambiguating test, not yet run:** capture the live pointer
of a still-*locked* ability (one never purchased) the same way Fiber
Weave's was captured (via the tile-builder breakpoint chain, §33-39, or
another live-breakpoint route), then re-run `walk_ownership_tree_v2.lua`
with that pointer as `TARGET`. If a locked ability's pointer is found in
this tree, it's a display cache (hypothesis 2). If only owned abilities
ever appear regardless of recent viewing, it supports hypothesis 1.

Session paused here pending the user's choice of whether to run this
test now or pick it up later.

---

## §50. Disambiguating test result: ownership-as-tree-membership CONFIRMED

Built an automated capture tool instead of continuing manual step-by-step
register reads (which had twice produced a clobbered `RCX` from
over-stepping past the breakpoint). `runtime/log_tile_pointers.lua`
installs a `debugger_onBreakpoint` handler on the existing
`MirrorsEdgeCatalyst.exe+3A1BF63` breakpoint (the `nameHash` read inside
the tile stat-formatter, `mov eax,[rcx+10]`): at the exact instant the
breakpoint fires -- before anything can execute and clobber `RCX` -- it
reads `RCX` (the struct pointer) and computes `nameHash = [RCX+0x10]`
directly via `readInteger`, logs both, and auto-continues (`return 1`).
Reopening the progression menu fired it ~37 times per pass (one per
visible tile), auto-continuing cleanly with zero manual stepping.

Cross-referenced all 37 captured `(pointer, nameHash)` pairs against the
static hash dictionary (`runtime/hash_lookup.py`, same djb2a dictionary
`decode_save.py` uses) **and** against the live save file (staged via the
device bridge, checked with `runtime/resolve_and_check.py` against all 3
`ProgressionManagerData*` sections). This immediately resolved an earlier
loose end from §49 too: `Unlocks_Focus_ReachFlow_Increase` (the very
first capture, thought possibly-locked) turned out to already be owned
(`value=1`) -- the name mismatch with what's visible in the in-game Focus
tab is expected, since the tile UI resolves a separate localized display
string, not the raw internal `Name`/`SyncStatName`.

Three candidates came back **absent from every single save section**
(not merely `0` -- no record exists at all, the strongest possible
signal of "never purchased, ever"):
- `2A1729E8` -> `Unlocks_FlowAttack_Special_PowerAttack`
- `2A16E5F0` -> `Unlocks_FlowAttack_PowerAttack`
- `2A16D1F0` -> `CriticalPathProgression_HasCollectedAlertRadar` (excluded --
  a collectible/story flag, not a skill-tree ability)

Picked `2A1729E8` (`Unlocks_FlowAttack_Special_PowerAttack`) as the
confirmed-locked target and re-ran `walk_ownership_tree_v2.lua` with
`TARGET = 0x2A1729E8` against the same tree (`ROOT = 0x25AA0780`, same
live session, same 25-node tree as §49). Ran it **twice** for safety:

```
RESULT: target 2A1729E8 was NOT found among the 25 node(s) visited.
```

(identical both times). Meanwhile Fiber Weave's pointer (`2A1D8848`,
owned) IS in that same 25-node tree, at the same node found in §49.

**Conclusion: hypothesis 1 from §45/§49 is confirmed.** The red-black
tree rooted at `R14+0x58` (`0x25AA0780` this session, cached directly;
also reachable via the header at `R14+0x48`) is the authoritative
per-category ownership store -- an ability is "owned" if and only if its
live struct pointer is a key in this tree. It is not a display cache:
only owned abilities appear in it, confirmed both by presence (Fiber
Weave) and by absence (a genuinely-never-touched ability), cross-checked
against the actual save file rather than assumed from UI naming.

**Practical implication for the original goal (grant an ability live,
no restart):** the purchase-commit function at `+0x39E19AA`'s surrounding
code (§43-45) already shows *how* an insert happens -- three RB-tree
search-and-insert blocks via the generic container routine at `+2A34880`,
followed by the gated cache-sync write. If we can call into that same
insert logic ourselves (or the whole purchase-commit function) with a
chosen ability's live pointer substituted in place of whatever the UI
purchase button would normally supply, that should be functionally
equivalent to "receiving" that ability -- without going through the
purchase-menu UI at all, which is exactly the mechanism an Archipelago
item-receive handler needs.

**Next step, not yet started:** find the purchase-commit function's true
entry point (walk backward from `+0x39E19AA` to the prologue) and its
calling convention (what `RBX`/the target pointer need to be set to on
entry -- captured by breakpointing entry during a normal purchase, the
same way Fiber Weave's pointer was captured at the write site). Then
attempt an actual live call into that function via Cheat Engine's Auto
Assembler / "execute code at address," substituting a locked ability's
pointer, and check whether the game then treats it as owned (UI
reflects it, ability becomes usable) -- the first real test of live
ability-granting.

---

## §51. Open concern: is §50's disambiguation test actually apples-to-apples? Two different object pools found

While hunting for the purchase-commit function's true entry point (following
the `+39E19AA` call stack, which this time showed a completely different,
non-UI chain: immediate caller `+39E24A9`, called from `+39E1700` -- see
next section), bought a second, different ability (`Shock Protector`,
Combat category, confirmed via in-game screenshot) with the same
`+39E19AA` breakpoint set. Captured `RDX`/`RSI` at the write site again:
**`0x2A1D8848` -- the exact same value captured for Fiber Weave's purchase**,
a completely different ability.

This is a red flag. Cross-referencing against §50's own data:
`Unlocks_LowerHealthShockProtector` (Shock Protector's actual definition
struct, resolved via nameHash `0x56E000EC`) has pointer `0x2A187AF0` --
nowhere near `0x2A1D8848`. In fact **every single "Unlocks_*" definition
struct pointer captured by `log_tile_pointers.lua` in §50 falls in the
`0x2A16xxxx`-`0x2A19xxxx` range**, while **every key found in the
ownership tree walk (§49/§50) falls in the `0x2A1D87xx`-`0x2A1DB7xx`
range** -- two distinct, non-overlapping heap regions / object pools.

**This means the tree we walked and the "Unlocks_*" definition structs
the UI reads from are NOT the same kind of object.** `0x2A1D8848` staying
constant across two different ability purchases in the same category
strongly suggests it's something category-scoped, not ability-scoped --
plausibly the category's own summary/progress-counter record (consistent
with the `+39E19AA` write itself, `mov [rbx+28],eax`, plausibly just
updating the on-screen "X/20" counter, not an ownership flag).

**Why this matters for §50's conclusion:** the disambiguating test used
`0x2A1729E8` (a locked ability's *definition* struct pointer, from the
`0x2A16xxxx`-range pool) as `TARGET` against a tree keyed by
`0x2A1Dxxxx`-range objects. If those pools are simply incompatible
namespaces, the locked ability's definition pointer was *never going to
be found in that tree regardless of ownership status* -- the negative
result could be a trivial type-mismatch, not a real ownership check. The
positive match (`0x2A1D8848` "found") is also suspect now, since it
isn't clearly tied to Fiber Weave specifically at all (same value
appeared for Shock Protector).

**§50's hypothesis-1 conclusion should be treated as unconfirmed pending
further work**, not retracted -- it's still possible the tree really is
an ownership store keyed by some OTHER per-ability object (not the
"Unlocks_*" definition struct, but a distinct per-ability *purchase
record* or *runtime state* object in the `0x2A1Dxxxx` pool) and
`0x2A1D8848` genuinely is that record for whichever ability was *most
recently processed*, not a category-wide singleton -- this hasn't been
ruled out either. Needs a cleaner test.

## §52. True entry point of the purchase-commit function found: `+39E1700`

The call stack captured for this purchase (Shock Protector) was
completely different from the earlier UI-chain capture (§ tile-builder
work) -- immediate caller `+39E24A9`, then `+39DDF91`, `+39E407F`,
`+3A79113`, `+2A395B9`, `+347C5AB`, ... all in deep game-logic address
ranges, nothing resembling the UI-menu-building chain. This is very
likely the real purchase/grant transaction path, distinct from the
UI-refresh pass that happens to also touch the same write instruction.

Found the actual `call` instruction immediately before the return
address: `MirrorsEdgeCatalyst.exe+39E24A4 -- call MirrorsEdgeCatalyst.exe
+39E1700`, landing back at `+39E24A9` (`mov r14,[rbp+000000A8]`) right
after. **`+39E1700` is the confirmed true entry point** of the function
containing the `+39E19AA` write.

**Next step, not yet done:** breakpoint directly on `+39E1700`, buy
another ability, and capture `RCX`/`RDX`/`R8`/`R9` (Win64 fastcall
argument registers) at the exact moment of entry, before the prologue
shuffles anything into `RBX`/`R14`/`R15`/`RSI`. This should also help
resolve §51's open concern -- if one of the true entry arguments is an
ability-specific pointer that changes between the Fiber Weave and Shock
Protector purchases (unlike the mid-function `RDX`/`RSI` we've been
capturing), that's the real per-ability identity to use in a future
disambiguation test, and possibly the right value to substitute when
attempting a live grant later.

Session paused here -- user is going to complete missions to unlock more
abilities to test with.

---

## §53. Major structural finding: the tree is per-category, not global -- explains the whole `RDX`/`RBX` mystery

Tried filtering `+2A34880` (generic tree-insert) by `RCX == 0x2BBC3160`
during a live purchase (Double Wallrun) -- zero matches, despite the
breakpoint clearly still firing constantly from ordinary menu navigation
(confirming §51's finding that `+2A34880` is pervasive, generic,
non-progression-specific plumbing). This ruled out `0x2BBC3160` as the
right filter value for this specific call site.

Pivoted to a much more direct method: **diff the tree's full key list
before and after a purchase**, instead of trying to catch the right
register at the right instant. Captured the full 29-key list right
before buying Double Wallrun, bought it, then captured the full key list
again immediately after:

```
Before: 2A1D87F8, 2A1D8848, 2A1D8A58, 2A1D8AA8, 2A1D8C18, 2A1D8D18,
2A1D8F28, 2A1D9078, 2A1D9258, 2A1D9358, 2A1D97C0, 2A1D9A68, 2A1D9DA8,
2A1D9F78, 2A1D9FC8, 2A1DA098, 2A1DA0E8, 2A1DA138, 2A1DA2D0, 2A1DA458,
2A1DA508, 2A1DA8B8, 2A1DA988, 2A1DAD48, 2A1DAF08, 2A1DAFB8, 2A1DB270,
2A1DB700, 2A1DB7E0

After:  2A1D87F8, 2A1D8848, 2A1D8A58, 2A1D8AA8, 2A1D8C18, 2A1D8D18,
2A1D8F28, 2A1D9078, 2A1D9258, 2A1D9358, 2A1D97C0, 2A1D9A68, 2A1D9DA8,
2A1D9F78, 2A1D9FC8, 2A1DA098, 2A1DA0E8, 2A1DA138, 2A1DA2D0, 2A1DA458,
2A1DA508, 2A1DA8B8, 2A1DA988, 2A1DAD48, 2A1DAF08, 2A1DAFB8, 2A1DB270,
2A1DB700, 2A1DB7E0
```

**Identical, zero new keys.** Buying Double Wallrun (Traversal category)
did not touch this tree at all.

**This resolves the §51/§52 mystery cleanly: the tree rooted at
`0x25AA0780` is scoped to ONE category (almost certainly Combat), not a
global ownership store.** Every ability we've successfully seen affect
this specific tree -- Fiber Weave, and very likely Shock Protector -- is
Combat. Climb Efficiency and Double Wallrun are both Traversal-category
abilities ("climb pipes/ladders faster", "wallrun") and neither one grew
this tree at all, which is exactly what a Combat-only tree should do.
The earlier confusing result (§51/52: `RDX`/`RSI`/`RBX` reading identical
values across Fiber Weave/Shock Protector/Climb Efficiency purchases) is
now explained too -- the outer function `+39E1700` is a shared, generic
per-category worker (same code path for every category), but which
specific tree instance it operates on for a given call is selected by
something not visible as a simple constant argument at entry; the
constant `RDX=0x2A1D8848` and similar values we kept seeing are shared
scaffolding, not per-ability content, exactly as suspected.

**Practical implication:** §50's disambiguation test (locked-vs-owned
tree membership) remains valid *for the Combat category specifically*
-- both the owned probe (Fiber Weave) and the locked probe
(`Unlocks_FlowAttack_Special_PowerAttack`) were Combat abilities tested
against the Combat tree, so that comparison was apples-to-apples after
all, just narrower in scope than assumed at the time.

**Next step, not yet done:** to extend this to other categories (and to
find the true per-ability key format for a live grant), repeat the
before/after tree-diff technique for a Traversal purchase -- but first
need to locate the Traversal category's own tree root, the same way
`0x25AA0780` was found for Combat (via a breakpoint hit during a
Traversal purchase, reading the equivalent of `R14+0x58` for whatever
manager instance is active then). Not attempted yet this session.

Session paused here for the day -- meaningful progress on understanding
the tree/category structure, but the live-grant mechanism itself (how to
insert without going through the UI) is still not attempted. Combat
category is the best-understood one and the most promising to attempt
first when resuming.

---

## §54. §53 re-confirmed: Focus Shield (Movement) also leaves the Combat tree untouched

Bought "Focus Shield +" -- confirmed via in-game screenshot to be a
**Movement** category ability (listed under "MOVEMENT 17/19", not
Combat), despite its combat-flavored description. A `+39E19AA`
breakpoint hit around this purchase showed `R14`/`R15`/root values
identical to the Combat tree (`0x25AA0780`), which briefly looked like
it contradicted §53. Resolved by re-running the before/after key-list
diff: **the tree is still exactly the same 29 keys, unchanged.** So that
register capture was a false lead -- just another one of this function's
many unrelated firings (confirmed non-purchase-exclusive since §52),
not the actual Focus Shield commit.

**§53 stands, now confirmed by two independent Movement purchases**
(Double Wallrun and Focus Shield) both leaving `0x25AA0780` completely
untouched. The tree-diff technique is the reliable signal here --
register snapshots at this breakpoint are not, since the function fires
too often for unrelated reasons to trust any single hit's register
values without corroboration.

**Next step, not yet done:** find Movement's own tree. Since `R14`
(`0x2BBC3160`) is confirmed shared/global across categories (identical
value seen for every purchase regardless of category), the Movement
tree is most likely NOT a different `R14` instance but a different
*offset* within the same `R14` object -- i.e. `R14` is plausibly a
top-level manager holding one header/root pair per category (Combat's
being at `+0x48`/`+0x58`). Proposed approach: dump a wider swath of `R14`
fields (e.g. `+0x80` through `+0xD0` or further) looking for a second
header-shaped pattern (left/right/parent triple matching the
`_Tree_node`-style layout already confirmed for Combat) -- not yet
attempted.

Session paused here -- strong, clean confirmation of the per-category
tree structure across two categories now (proven present for Combat,
proven absent for Movement in the same known tree), which is solid
groundwork for whoever picks this up next, whether that's later today
or a future session.

---

## §55. Session wrap-up: reset tonight's test purchases so Movement has more unlocked-but-unpurchased abilities for next time

Only one Movement ability was left available to unlock, which would have
blocked next session's plan to find Movement's own ownership tree (needs
at least one, ideally several, fresh purchases to test with). With the
game confirmed closed, used `set_flag.py` to reset the three Movement
abilities purchased for testing tonight back to locked (value 1 -> 0,
across all 3 `ProgressionManagerData*` sections):

- `Unlocks_DoubleWallrun` (hash `0xf139b4b3`) -- Double Wallrun
- `Unlocks_FastClimb` (hash `0x6f18bef0`) -- Climb Efficiency (name match,
  reasonably but not 100% confident)
- `Unlocks_Focus` (hash `0x2c9cc1d5`) -- best guess for Focus Shield +;
  no exact "shield"-named flag was found in the decoded save, so this is
  the least certain of the three. If Focus Shield doesn't show back up as
  locked/purchasable, this guess was wrong and the real flag name is
  still unknown.

Backup kept as `PROF_SAVE.before_movementreset` alongside the usual
`patch_save.py`/`set_flag.py` safety pattern. XP was not touched (still
at the 999999 surplus from earlier in the project).

**Starting point for next session:**
1. Verify in-game that Double Wallrun, Climb Efficiency, and (hopefully)
   Focus Shield show up as locked/purchasable again.
2. Resume the Movement-tree hunt from §54: dump a wider swath of `R14`
   (`0x2BBC3160`, should still be stable if the game hasn't been patched)
   fields beyond `+0x48`/`+0x58` (Combat's known offsets) looking for a
   second header-shaped left/right/parent triple for Movement.
3. Once found, repeat the before/after key-diff test (§53/54's reliable
   method) on a fresh Movement purchase to confirm.
4. Longer-term goal unchanged: once both categories' tree mechanics are
   fully understood, attempt an actual live "grant ability" test by
   constructing a node and inserting it the way `+2A34880`/the
   `+39E1700` function chain does, without going through the UI purchase
   flow -- this is the original multi-session goal and still hasn't been
   attempted yet, though tonight's work (true entry point found, tree
   structure understood, per-category model confirmed) puts it much
   closer than before.

---

## §56. LIVE GRANT PATH FOUND: the global flag hashmap at `[module+0x257C9D8]` controls abilities; changes apply on respawn

This supersedes the tree model from §45–§55. The `R14+0x48/+0x58` trees are
a **stat/achievement registry**, not ability ownership. There is no need to
build tree nodes. A live grant is a **4-byte value write**.

### How we got here
- Breakpoint logging at the entry of `+39E1700` (`runtime/log_purchase_entry.lua`):
  every call comes from `+39E24A9`, and RCX is the same object on every call
  (vtable `+1C64B38`). RDX iterates 18 stat records (vtable `+1C95530`,
  tag `0xB1000002`, GUIDs at +0x18/+0x40, target at +0x34, e.g. 0x144 = 324 GridLeaks).
  R8 points to a (current, target) pair. So `+39E1700` is **stat-progress sync**,
  not purchase commit. The caller `+39E1F20` is the achievement/stat
  evaluator. It dispatches on criterion type descriptors `+2876BA8`, `+2876D30`,
  `+2876A20`, `+2876828`, `+2876940`.
- The flag-threshold criterion (`+2876D30`) reads a progression flag by
  hash lookup at `+39E2268..+39E22D9`. That lookup revealed the store.
- **Dead end, now retracted:** the `[0xAFAFAFAF|count]` + (hash,value) arrays
  found by AOB scan (`identify_stat_objects.lua` Test A, `dump_record_array.lua`,
  `progression_poke.lua` v1/v2) are **frozen save snapshots**. There are three
  copies per ProgressionManagerData section. Their clocks never tick, their heap
  memory is freed and reused, and writing to them does nothing. Do not write
  to them. v1 of progression_poke also chose the wrong arrays ("highest clock =
  live" was a bad inference).

### The store
```
tbl     = qword [MirrorsEdgeCatalyst.exe + 0x257C9D8]   ; static root, stable across restarts
buckets = qword [tbl + 0x20]
nbuck   = dword [tbl + 0x28]                            ; 3739 this session
node    = buckets[hash % nbuck]
walk:   dword [node+0x00] = djb2a name hash
        qword [node+0x08] = PamProgressionFlag definition ptr
        dword [node+0x18] = VALUE
        qword [node+0x28] = next in chain
```
- 2,374 entries, longest chain 6. It holds **every** flag, including ones never
  bought (value 0). For example, `Unlocks_FlowAttack_Special_PowerAttack` is
  present with value 0. So a grant is a value write; no insert is needed.
- It is newer than the save on disk (XP_Gained 1002684 vs 1002674 on disk), so
  this is where the game saves *from*.
- Tool: `runtime/flag_hashmap.lua` (TARGET_HASH / NEW_VALUE; nil = read-only).

### The decisive test (Switch Place = `Unlocks_MoveEnemyBack`, 0x67800619)
Done in one session, all in-game, no save edits:

| step | table value | action | could use Switch Place? |
|---|---|---|---|
| 1 | 1 → **0** | none | yes (still active) |
| 2 | 0 | died / respawned | **no** |
| 3 | 0 → **1** | none | no (still inactive) |
| 4 | 1 | died / respawned | **yes** |
| 5 | 1 → **0** | none | yes |
| 6 | 0 | died / respawned | **no** |

The result reproduced in both directions, and the respawn was the only
variable each time. Conclusions:
- **The hashmap value is authoritative for gameplay.**
- The player's ability set is **rebuilt from the table on respawn**, not read
  every frame. A write takes effect at the next death/checkpoint reload.
- The **Progression menu UI showed "unlocked" the whole time**. It reads a
  separate cache (probably built at level load), so the UI is **not** a
  reliable indicator in any future test. Only test the move itself.

### Side findings
- Switch Place = `Unlocks_MoveEnemyBack` (0x67800619) is confirmed.
- §55's "Focus Shield = `Unlocks_Focus`" is **probably wrong**: `Unlocks_Focus`
  had been pruned from the live save section. The real Focus Shield flag is still unknown.
- Backup taken before any live writes:
  `Documents\Mirrors Edge Catalyst\settings\PROF_SAVE.before_livepoke`
  (305 records; DWR, FastClimb and MoveEnemyBack = 1; XP_Used 17000).

### Mistakes this session (so we don't repeat them)
- Predicted that `+39E1700`'s RCX would differ per category. It was constant.
  The function was misidentified from the start (§52).
- Called the snapshot arrays "the live store" before a write test. The test
  disproved it.
- Wrong-length RVA typed (`+39E1F2` vs `+39E1F20`). Also, CE's Lua Engine
  keeps old pasted text, so re-executing without re-pasting reruns the old script.

### Next steps
1. **Grant test (0 → 1 on a never-bought ability):** write 1, die, and try the move.
   Revoke is proven; grant is the same write in the other direction, but it
   still has to be verified with a flag that was never set.
2. Grant/revoke Double Wallrun (0xF139B4B3) to confirm Movement works the same way.
3. **Find the respawn "apply abilities" routine** so the AP client can
   trigger it directly instead of needing a death. Method: CE "find out what
   accesses" on a node's `+0x18` value, then die. The reads that fire during
   respawn identify the rebuild function.
4. Optional: find the UI cache, so the menu reflects AP grants too.
5. XP_Used should probably be left alone for AP grants. Decide whether AP items
   should also adjust the XP counters or bypass them entirely.

---

## §57. GRANT PROVEN: never-owned flags, including a mission-locked one, take effect on respawn

The multi-session goal ("grant an ability live, without a save edit and
restart") is **achieved**. §56 proved revoke-and-restore; this proves the
direction that matters.

### The test
Target: the Combat stamina column ("+1 STAMINA"), which the menu shows as
Graphene Weave (purchasable) and Carbon Weave (**LOCKED: Complete mission
SANCTUARY**). Flags `Unlocks_IncreasedHealth0..4`, hashes from djb2a:

| flag | hash | before | after grant |
|---|---|---|---|
| `Unlocks_IncreasedHealth0` | `848D8855` | 1 | 1 (untouched) |
| `Unlocks_IncreasedHealth1` | `848D8854` | 0 | 1 |
| `Unlocks_IncreasedHealth2` | `848D8857` | 0 | 1 |
| `Unlocks_IncreasedHealth3` | `848D8856` | 0 | 1 |
| `Unlocks_IncreasedHealth4` | `848D8851` | 0 | 1 |

Procedure: write the four zeros to 1 in the hashmap at `[module+0x257C9D8]`,
then die. **Health bar went from 4 segments to 8.** Four flags, four segments,
one per flag.

### What this establishes
1. **A grant is a 4-byte write.** No node construction, no insert, no call into
   the purchase path. Every flag already exists in the table with value 0.
2. **The mission gate is UI-only.** Carbon Weave requires mission SANCTUARY
   to *buy*. The flag write applied anyway. The gate lives in the progression
   menu's purchasability check, not in the ability itself. Expect the same for
   other mission-gated and XP-gated items -- worth spot-checking one more
   category before relying on it.
3. **Passive stat upgrades apply on respawn too**, same as active moves (§56).
   The earlier worry that passive stats might only apply at level load was wrong.
4. **XP is not involved.** `XP_Used` stayed 17000 across the grant. The game
   never charged for these, so an AP client can grant items without touching
   the XP economy at all.
5. The tool `runtime/grant_test.lua` (MODE read/grant/restore, with a control
   check on `Unlocks_MoveEnemyBack` before any write) is the working pattern
   for this: never write unless a known flag reads its known value first.

### Confirmed model, end to end
```
AP item received
  -> lookup(hash) in [MirrorsEdgeCatalyst.exe+0x257C9D8]
  -> write 1 to node+0x18
  -> player respawns (death / checkpoint)
  -> ability is live
```
The menu still shows stale state throughout (§56) -- cosmetic only.

### Remaining work for the AP client
1. **Remove the death requirement.** Find the routine that rebuilds the
   player's ability set on respawn and call it directly. Method: CE "find out
   what accesses this address" on a granted node's `+0x18`, then die, and read
   which code touches it during the respawn.
2. **Refresh the progression menu's cache** so granted items display correctly.
   Cosmetic, but confusing for a player otherwise.
3. **Verify the gate bypass generalises** -- try one XP-gated and one
   story-gated item outside the stamina column.
4. Build the hash -> in-game-name map for the item pool. `Unlocks_*` names come
   from the existing djb2a dictionary; the menu display names (Carbon Weave,
   Graphene Weave, ...) still need to be matched to flags, probably via the
   UI/localisation data rather than the flag names.

---

## §58. The respawn ability-rebuild call chain, decoded

Goal: stop requiring a death for a granted flag to take effect. Method: CE
"find out what accesses" on a granted node's `+0x18`, then a stack-walking
breakpoint logger (`runtime/trace_flag_read.lua`) across a death.

### The read
"Find out what accesses" on `<node>+0x18` during a respawn produced exactly ONE
instruction, hit ONCE:

```
MirrorsEdgeCatalyst.exe+39DA8DD   mov eax,[rax+18]
```

`RAX` is the hashmap node; `+0x18` is the value field from §56. It is the
generic flag-value getter, shared by every lookup, so the instruction itself
says nothing -- the CALLERS do.

### Timing (this is the useful part)
With the logger filtering on `Unlocks_MoveEnemyBack`'s node:
- **0 hits** across ~10s of normal play.
- **1 hit** during the death/respawn.

So the flag is **not polled**. It is read once, when the player is rebuilt.
That is why a write only takes effect on respawn (§56/§57), and it means the
rebuild is a discrete routine that can, in principle, be invoked on demand.

### The chain
Stack at the moment of the read (innermost first):

```
+3A77E14 < +31250EE < +1A5BDB8 < +3149001 < +33542D6 < +33604F0 < +337442E
```

`runtime/analyze_chain.lua` resolved each frame. Note that CC-padding is only a
heuristic for finding function starts -- it landed a few bytes early twice. The
**call targets in the disassembly are authoritative**, and give:

```
+337440B --call--> +3354280 --call--> +31250A0 --call [r14+08]--> +3A77DB3 --call--> +39DA880
                                                                                       |
                                                                          contains the getter +39DA8DD
```

- **`+3A77DB3`** -- per-item ownership query. Its body confirms the §56 store
  from the game's own code:
  ```
  mov rcx,[14257C9D8]     ; the flag table global
  call +39DA170           ; resolve the flag definition
  mov [rbx+80],rax        ; cache the definition on the object
  mov rdx,[rbx+80]
  mov rcx,[14257C9D8]
  call +39DA880           ; read the value  <- +39DA8DD is inside this
  ```
  So `rbx` is an item object with the flag definition cached at `+0x80`.
- **`+31250A0`** -- calls through `[r14+08]`, i.e. dispatches over a list of
  items. This is the shape of "rebuild every ability" and is the prime
  candidate for the routine the AP client should invoke.
- **`+3354280`**, **`+337440B`** -- its callers, progressively higher-level.
- Frames `+1A5BDB8`, `+3149001`, `+33604F0` are **not trusted**: one had no
  resolvable start, one disassembled misaligned, one is padding. With a single
  captured hit there is no frequency signal to separate real frames from stale
  stack slots, so these are treated as junk unless later evidence revives them.

### Next
`runtime/log_apply_candidates.lua` breaks on the entries of `+31250A0`,
`+3354280` and `+3A77DB3` across an idle period and a death, to establish:
when each fires (a per-frame routine is not a rebuild), what `this` pointer it
takes, and how many items it iterates. The `this` pointer is what an AP client
would capture and reuse.

Likely final shape for the client: rather than calling the rebuild from an
injected thread (wrong thread = crash risk), hook a routine that already runs on
the game thread and have it invoke the rebuild when the client sets a "pending
grant" flag.

---

## §59. Each ability is enforced by ONE flag-check entity that evaluates once, at respawn

### Correction to §58
The breakpoint at `+3A77DB3` never fired because `+3A77DB3` isn't a real
function start. `+31250A0` and `+3354280` came from actual `call` targets, but
`+3A77DB3` is only reached through `call [r14+08]`. Its "start" was the
CC-padding guess, which had already been shown to land a few bytes off twice.
The fix was to break at `+3A77E14`, which is known to execute because it was the
captured return address.

### Also from the §58 follow-up (`log_apply_candidates.lua`)
- `+3354280`: 0 hits idle, 12 during the death. There were 12 distinct `this`
  objects, all of one class (vtable `+1C3FCB0`).
- `+31250A0`: 0 hits idle, 31 during the death, on at least 3 object classes
  (`+1B962C8`, `+1B96170`, `+1AE33B8`). It is a generic dispatcher, not an
  ability routine.
- Conclusion: there is no single "rebuild abilities" function. A respawn
  re-creates the player's logic entities, and each one checks its own flag as it
  initialises.

### The flag-check site `+3A77E14` (`runtime/log_item_checks.lua` v2)
At `+3A77E14`: `RBX` = the entity doing the check, `[RBX+0x80]` = the pointer it
cached, and `EAX` = the flag value it got back. `[RBX+0x80]` matches the
hashmap node's **`+0x10`** field, not `+0x08` (v1 indexed `+0x08` and got
UNRESOLVED everywhere). With both indexed, every flag resolved.

All checking entities share one class, vtable **`+1C7B168`**: a generic "check a
progression flag" logic entity. There are hundreds of them across the level.

Split by window (idle ~10s, then a death):

| group | count | notes |
|---|---|---|
| RESPAWN-ONLY | 46 flags | **every known `Unlocks_*` flag is here** |
| ALWAYS | 34 flags | polled continuously; includes `XP_Gained` (66 entities) and counters |
| IDLE-ONLY | 8 flags | one-off level checks |

**Every ability flag we can name** (`Unlocks_MoveEnemyBack`, `DoubleWallrun`,
`FastClimb`, `Shift`, `ExtendedSlide`, `Focus`,
`FlowAttack_Special_PowerAttack`, `IncreasedHealth0..4`) is:
- checked **only** during the respawn,
- checked **exactly once**,
- by **exactly one entity**, e.g. `Unlocks_MoveEnemyBack` by entity `1B9473E0`
  (heap address; changes each respawn).

The returned values match ownership. The other ~35 RESPAWN-ONLY hashes with
value 0/1 are very likely the remaining `Unlocks_*` abilities, and can be named
offline with the djb2a dictionary.

### What this means
The ability system is **one small entity per ability**. It asks the table once
when the player is (re)built, then (presumably) enables or disables its ability.
So "apply a grant without dying" becomes: **make that one entity evaluate
again.** That needs:
1. The entity's real evaluate function. Capture the target of `call [r14+08]` at
   `+31250EA` rather than guessing a start address again.
2. Confirmation that the checking entity persists after the respawn, so it can
   be poked later. It may instead be a one-shot that is destroyed.
3. Its arguments. Then a test: write a flag, invoke the entity's evaluate on the
   game thread, and see whether the ability changes with no death.

Fallback if (2) fails: the AP client applies grants at the next death or
checkpoint. §57 shows that works for any flag, mission-gated ones included.

### SAVE-STATE WARNING found in this run
All five `Unlocks_IncreasedHealth0..4` returned **1** at this respawn. §57
restored them to `1,0,0,0,0` and confirmed 4 bars in-game, but in this fresh
session all five are 1. The likely cause: the death right after the §57 grant
hit a checkpoint autosave with the granted state, and the game never saved again
after the in-memory restore. The on-disk save now probably has +4 stamina.
**Rule going forward:** a test grant followed by a death can reach disk. Restore
before any death that isn't part of the test, or back up and restore the save
file afterwards.

---

## §60. The evaluate event, captured: `+33604F0(sender, event, entity)`, and the entity survives the respawn

`runtime/capture_evaluate.lua` puts breakpoints on `+31250EA` (the
`call [r14+08]`) and `+3A77E14` (inside the check), and correlates the two for
`Unlocks_MoveEnemyBack`:

```
=== 67800619 checked by entity 1E20AC20 (vtable +1C7B168), value EAX=1 ===
   last call via +31250EA: target +33604F0
      RCX=2979FD340 [+1C3FCB0]  RDX=32AEE730 [+1A5BDB8]  R8=1E20AC20 [+1C7B168]
```

- **`+33604F0` is the real function** that runs the check. It's a call target,
  so its start address is known, not guessed. This retires the `+3A77DB3` guess
  for good.
- **Arguments:**
  - `RCX` = **sender**, class vtable `+1C3FCB0`. It's the same class `+3354280`
    ran on in §59, so `+3354280` is a sender method that fires an event at each
    connected target.
  - `RDX` = **event object**, stack-allocated, vtable `+1A5BDB8`. That vtable
    showed up as a "frame" in the §58 stack trace; it was never a caller, just
    this object's vtable left on the stack.
  - `R8` = **receiver = the flag-check entity** itself. The source is
    `lea r8,[rdi-08]`, so `R8` *is* the entity. The script's "R8+8==entity"
    test used the wrong formula.
- **The entity survives the respawn.** `alive()` afterwards showed the same
  vtable and the same cached `[+0x80]`. A new entity is made each respawn (the
  last run's Switch Place checker was `1B9473E0`, this one is `1E20AC20`), but
  it lives until the next one. So it can be poked after the fact.
- Call volume per respawn: 1205 calls through `+31250EA`, split between two
  targets, `+2C6F890` (x796) and `+33604F0` (x409). There were 227 checks at
  `+3A77E14`.

### Model
Respawn → a sender (class `+1C3FCB0`) fires an event (`+1A5BDB8`) at each
connected entity through `+33604F0(sender, event, entity)` → each flag-check
entity (`+1C7B168`) reads its flag once and switches its ability on or off.

### Next: `runtime/dump_event.lua` (read-only)
Before replaying anything live, capture exactly what would be sent:
- disassembly of `+33604F0`, to see how it dispatches to the entity;
- the event object's bytes, copied at the moment of the call (it's on the
  stack);
- the sender's header and whether it's still alive after the respawn;
- the entity's vtable, to find its event-handler slot.

Then the live test: write `Unlocks_MoveEnemyBack` = 0, replay the captured
event into the current Switch Place entity **without dying**, and check whether
Switch Place stops working. Restore the flag before any death (§59 autosave
rule).

### Process note (corrected in §65)
FINDINGS.md appeared to be overwritten by older copies. I first blamed an editor
on the user's machine. **That was wrong. The fault was in Claude's own file
transfer; see the §65 correction.**

---

## §61. LIVE APPLY WITHOUT DEATH: `+3A75790(entity, value, 1)`

**This removes the last blocker. A granted flag can take effect immediately,
with no death, respawn, or restart.**

### How it was found
Static disassembly (`runtime/dump_event.lua`, plus a two-function read):

```
+33604F0(sender, event, entity):   router
    if [event+08] != 0 -> virtual call on that object
    else               -> jmp +31661C0(entity, event)

+31661C0(entity, event):           gate
    r8d = [entity+18]
    if bit 3 set -> ret             (NB: both live entities had bit 3 SET, see below)
    if bit 0x40 set -> jmp vtable[0x90] else jmp vtable[0x78]   (slot 15)

+3A77DC0(entity) = vtable slot 15: the flag check
    call +316ADC0
    data = [entity+28]
    if byte [data+3A] != 0 -> ret
    if [entity+80] == 0:
        h = [data+34]; if h != 0 -> +39DA170(table, h) else [data+28]
        [entity+80] = that            (the node+0x10 pointer, §59)
    eax = +39DA880(table, [entity+80])   -- the flag value
    jmp +3A75790(entity, value, 1)       <-- APPLY
```

The check never reads the event's contents, so replaying the event isn't
needed. The whole ability switch is one call: **`+3A75790(rcx=entity,
edx=value, r8b=1)`**.

The previous guess `+3A77DB3` was 13 bytes before the real start `+3A77DC0`.
Vtable slot 15 is the authoritative entry point.

### Finding the entity with no death
Scan writable memory for the 8-byte vtable `MirrorsEdgeCatalyst.exe+1C7B168`.
This run found 1172 such objects. Match either field:
- `[[entity+0x28]+0x34] == hash`. For Switch Place this was **0**, so the
  entity uses the `[data+28]` path instead.
- `[entity+0x80] == node+0x10` for the flag's table node. This is what matched,
  but it only works after the entity has checked once.

For `Unlocks_MoveEnemyBack` this found **2** candidates:

| entity | `[+18]` flags | note |
|---|---|---|
| `1DAFBEB0` | `121F` | probably the previous respawn's entity, not yet freed |
| `1E1239F0` | `321F` | the one `dump_event.lua` captured at the latest respawn; used for the test |

Both have bit 3 set, so bit 3 isn't "inactive" as I first labelled it. The
difference is **`0x2000`**, which is set only on the current entity. That's a
candidate "live / attached" bit, not yet proven. A client needs a reliable way
to pick the live entity. Calling `+3A75790` on a freed object could crash.

### The test (`runtime/live_apply_test.lua`, no death at any point)
1. `revoke()`: table `67800619` 1→0, then `executeCodeEx(+3A75790, 1E1239F0, 0, 1)`.
   **Switch Place could not be used.**
2. `grant()`: table 0→1, then `executeCodeEx(+3A75790, 1E1239F0, 1, 1)`.
   **Switch Place worked again.**

Both calls returned `rax=0`. There was no crash, even though `executeCodeEx`
runs the call on a new remote thread rather than the game thread.

### Status of the original goal
| requirement | status |
|---|---|
| where ownership lives | §56 flag table `[+0x257C9D8]`, value at `node+0x18` |
| grant a never-owned / mission-locked item | §57, proven (applies on respawn) |
| apply without dying | **§61, proven for revoke and re-grant of Switch Place** |
| find the entity without dying | vtable scan + `[+80]==node+10`; live-entity selection still open |

### Open items
1. **Repeat with a never-owned flag, live.** For example, grant
   `Unlocks_IncreasedHealth1` and watch the stamina bar go 4→5 with no death.
   This checks the method on a passive stat and on a flag whose entity has never
   applied "1" before.
2. **Live-entity selection.** Test whether bit `0x2000` of `[+18]`
   distinguishes live from stale, across a couple of respawns.
3. **Entities that haven't cached `[+80]` yet** (hash at `data+34` = 0 and not
   yet evaluated) can't be matched by the `[+80]` method. Need a fallback, e.g.
   resolve `[data+28]` against node+0x10.
4. **Threading.** It worked from a remote thread twice, but the real client
   should call from the game thread (a small hook) to avoid rare races.
5. The progression menu still shows stale state (§56). Cosmetic.

---

## §62. §61 NOT REPRODUCED: the live call returned but the change only applied after a death

This is a second run of `live_apply_test.lua` (fixed picker) in a fresh game
session. The target entity was chosen by the `0x2000` rule.

```
revoke()  -> +3A75790(1E11D5C0, 0, 1)   table 1->0   rax=0
revoke()  -> +3A75790(1E11D5C0, 0, 1)   table 0->0   rax=0
   (death) -> new entity 1B663570 (321F); 1E11D5C0 gone
grant()   -> +3A75790(1B663570, 1, 1)   table 0->1   rax=0
```

User report: **both revoke and grant "worked, but I had to die for it to
apply".** The calls returned normally with no crash, but the ability didn't
change until the next respawn. That is just the ordinary §56/§57 table path.

### This contradicts §61
In §61, the same call on the same kind of entity (`321F`) turned Switch Place
off and on with no death. So there is one success and one failure, and I can't
yet say whether the live call works. **§61's "proven" is downgraded to "seen
once, not reproduced".** Candidate differences to rule out:
- Something about the §61 session. The entity had just been captured by
  `dump_event.lua` with breakpoints on `+33604F0`/`+3A77E14` during the
  respawn, and those breakpoints were then removed.
- `+3A75790` may only fire its output when the value differs from a stored
  "last value" in the entity, or it may depend on other entity state.
- The long-lived `121F` entity (fixed address across deaths) may be the one
  that actually drives the ability, with the `321F` one only mattering at
  respawn.
- The §61 revoke observation itself: one observation only.

### Also observed
- Right after loading, before any death, only the `121F` entity exists for the
  flag (plus the `[+80]` match). The `321F` entity appears after the first
  respawn.
- The crash in the previous session (a repeated `revoke()`) is still
  unexplained. The picker is now validated per call, and no crash occurred in
  this run.

### Next
`runtime/diag_apply.lua`: disassemble `+3A75790` to see what it depends on,
then snapshot and diff the target entity's memory around each call. This shows
whether the call changes anything, and lets us test the `121F` entity as the
target.

### Process (corrected in §65)
The "reverted to a one-version-old copy" problem was blamed on a sync tool or
editor on the user's machine. **That was wrong. See the §65 correction.**

---

## §63. What `+3A75790` actually does: it updates the entity's outputs; nothing downstream re-reads them live

`runtime/diag_apply.lua` disassembled `+3A75790` and diffed the entity's first
0x100 bytes around each call. Switch Place was tested after every call.

### Disassembly, annotated
```
+3A75790(rcx=entity, edx=value, r8b=flag):
  if !([entity+18] & 8) -> return        ; bit 3 = ENABLED (every entity had it; §61's "INACTIVE" label was backwards)
  changed = ([entity+78] != value); [entity+78] = value
  if !changed && !flag -> return
  port = [entity+68]                     ; int output port
  if port && !(port settled && [[port]] == value):
      +2A430F0(entity+68, &value, 1)     ; push value to connected entities
  b = (value > 0)
  port = [entity+70]                     ; bool output port
  if port && !(port settled && [[port]] == b):
      +2A430F0(entity+70, &b, 1)         ; push bool to connected entities
  mode = data->vtable[0x20]()            ; data = [entity+28]
  if mode == 2 && flag == 0:
      +347E420(entity+30, 1)             ; fire an EVENT -- skipped when flag=1
  ...
```
The respawn path always calls with `flag = 1` (`mov r8b,01` at `+3A77E14`), so the
event branch never runs there.

### Probe results (fresh session, no deaths during the probes)
| call | entity | diff | Switch Place |
|---|---|---|---|
| `+3A75790(live 321F, 0, 1)` | `1B8ACB10` | `+078: 1→0` | **still usable** |
| `+3A75790(live 321F, 1, 1)` | `1B8ACB10` | `+078: 0→1` | usable |
| `+3A75790(persist 121F, 0, 1)` | `1DAFB640` | `+078: 1→0` | **still usable** |
| `+3A75790(persist 121F, 1, 1)` | `1DAFB640` | `+078: 0→1` | usable |

So the call **runs and takes effect inside the entity**: `[+78]` holds its
current value, and the output ports are updated through `+2A430F0`. But the
ability does **not** change live. That matches §62 and contradicts §61.

### Interpretation
The flag-check entity is only a source. Whatever consumes its output (the
thing that actually enables the move) evidently reads that output **once, when
it is itself created at respawn**, and doesn't react to later changes. §61's
single live "success" is now the outlier. It is not reproduced in two later
sessions (§62, §63) and should not be relied on. The likeliest explanation is an
observation coincidence.

### Remaining cheap experiment
Call with `flag = 0`: `probe(v, "live", 0)`. If `mode == 2` for this entity,
that fires the `+347E420` event, which the respawn path never does. If a
consumer listens for that event, the change could apply live.

### If that fails
- **Pragmatic:** grants apply at the next death or checkpoint (proven, §57). An
  AP client can write the flag immediately and tell the player "applies on next
  respawn".
- **Deeper:** follow the output ports at `[entity+68]`/`[entity+70]` to the
  consumer entity, find how it enables the move, and poke that instead.

---

## §64. LIVE APPLY WORKS with `flag = 0`: `+3A75790(entity, value, 0)`

Same session setup as §63 (die once after loading, target = the `0x2000`
entity). The only change is the third argument.

```
probe(1, live, 0)   table 1->1   rax=1536   no bytes changed   (value unchanged + flag 0 -> early return; expected)
probe(0, live, 0)   table 1->0   entity+078: 1->0             Switch Place: CAN'T use
probe(1, live, 0)   table 0->1   entity+078: 0->1             Switch Place: CAN use
check()             table = 1
```

Compare §63 (`flag = 1`): the same value changes, the same `+78` updates, and
Switch Place was **unaffected**.

### Why, from the §63 disassembly
With `flag = 1` (what the respawn path passes), `+3A75790` only updates the
entity's value and its output ports. With `flag = 0`, and when the entity's
`data->vtable[0x20]()` returns 2 (mode function `+473BDA0` for this entity),
it **also fires `+347E420(entity+30, 1)`, an event**. So the consumer that
enables the move reacts to that **event**, not to the port values. At respawn
the consumer is freshly created and reads the port value directly. Live, it
only reacts to the event.

**Rule:** a live apply is `+3A75790(entity, newValue, 0)` with `newValue`
**different** from `[entity+78]`. If they're equal and the flag is 0, the
function returns immediately (first row above).

### Status
- One session, one revoke and one grant, both behaving as predicted. This is
  consistent with the disassembly, but **one run**. §61 "worked" once with
  `flag = 1` and was never reproduced, so this needs an A/B replication in one
  session before it is called proven.
- §61 stays unexplained.

### Next
1. A/B in one session: `flag = 1` revoke (expect no effect), then `flag = 0`
   revoke/grant twice (expect effect each time).
2. Generality: a different flag, ideally a never-owned passive
   (`Unlocks_IncreasedHealth1`, watch the bar 4→5 live).
3. Other entities may use a different mode than 2, and the event only fires in
   mode 2. Check the mode per flag of interest.
4. Threading: the calls still run on a remote thread. No crash in this run.

---

## §65. `flag = 0` live apply replicated (second session); the within-session control is still missing

A new session: die once after load, then `diag_apply.lua`, target = the
`0x2000` entity `1BDEBA30`.

The protocol asked for `probe(0,"live",1)` first, as the control. **The log
shows the first three calls were `probe(1, …)`**, i.e. `1→1` with no change and
an early return. So they were no-ops, and the user's note "still worked" after
them is expected and tests nothing. The informative part:

```
probe(0, live, 0)   table 1->0   entity+078: 1->0   Switch Place: NOT usable
probe(1, live, 0)   table 0->1   entity+078: 0->1   Switch Place: usable
check()             table = 1
```

### Evidence tally for live apply via `+3A75790`
| session | flag | revoke took effect live? |
|---|---|---|
| §61 | 1 | yes (**unexplained**, never reproduced) |
| §62 | 1 | no |
| §63 | 1 | no (live and persist entities) |
| §64 | 0 | **yes**, grant too |
| §65 | 0 | **yes**, grant too |

This is consistent with the §63 disassembly: `flag = 0` fires the
`+347E420` event, which is what the live consumer reacts to. The one missing
piece is a `flag = 1` vs `flag = 0` comparison **in the same session**. It's
cheap, so it's folded into the next test.

### Next: generality (`diag_apply.lua` v3)
`target(hash, name)` switches the flag under test and records its current value
as the restore point. Test on a **never-owned passive**,
`Unlocks_IncreasedHealth1` (`848D8854`, value 0, stamina 4 bars), with the
control included:
1. `probe(1,"live",1)` → expect bars unchanged (4)
2. `probe(0,"live",1)` → reset, no visible change
3. `probe(1,"live",0)` → expect **5 bars live**
4. `probe(0,"live",0)` → expect 4 bars
5. `check()` → must show the original value 0

Its entity's mode function must also return 2 for the event to fire. The script
prints `data->vtable[0x20]`. It was `+473BDA0` for Switch Place.

### §65 correction: the "reverted files" were Claude's fault
The user confirmed that nothing on their machine has FINDINGS.md open, and no
sync tool is involved. The one-version-behind files came from Claude's transfer
method: files edited in Claude's workspace with shell commands were copied to
the user's folder from a path that could serve an older snapshot. The fix, used
from §65 on, is to deliver the file first, commit it by its delivered-file ID,
and verify the size with a directory listing afterwards. §60 and §62 wrongly
blamed an editor or sync tool; they have been corrected. The user did nothing
wrong.

---

## §66. Live GRANT of a never-owned upgrade works: stamina 4→5 bars with no death

Session: die once after load, then `diag_apply.lua` v3 with
`target(0x848D8854, "IncreasedHealth1")`. The flag was 0 (never owned) and the
stamina bar showed 4. Entity `1DFAB400` (`321F`), mode function `+473BDA0`, the
same as Switch Place's.

| call | table | `entity+78` | predicted | observed |
|---|---|---|---|---|
| `probe(1,"live",1)` | 0→1 | 0→1 | 4 bars (control) | **5 bars** |
| `probe(0,"live",1)` | 1→0 | 1→0 | (reset, not checked) | **4 bars** (user confirmed afterwards) |
| `probe(1,"live",0)` | 0→1 | 0→1 | 5 bars | **5 bars** |
| `probe(0,"live",0)` | 1→0 | 1→0 | 4 bars | **4 bars** |
| `check()` | 0 = original | | | OK |

### What this shows
- **For this port-driven passive, the r8 flag doesn't matter, in either
  direction.** With flag 1 and with flag 0, the value went 4→5 on grant and
  5→4 on revoke. Switch Place (event-driven) needed flag 0. So **always call
  with flag 0**: it covers both kinds of consumer.
- **A never-owned passive upgrade was granted live and revoked live.** This is
  the Archipelago use case: an item the player hasn't earned, arriving
  mid-play.
- **My control prediction was wrong for stamina.** With `flag = 1` (no event,
  only the output ports updated) the bar also changed. So consumers differ:
  - Switch Place's consumer reacts only to the **event** (`flag = 0`, §63–§65).
  - The stamina consumer reacts to the **output port value** (`flag = 1` is
    enough).
- `flag = 0` does both: it updates the ports **and** fires the event. So it
  covers both kinds of consumer.

### The recipe for a live grant/revoke (as it stands)
1. Write the value into the §56 table: `node(hash)+0x18 = v`. This persists to
   the save and to later respawns.
2. Find the live check entity. Scan for vtable `+1C7B168`, keep those with
   `[e+0x80] == node+0x10`, then pick the one with `[e+0x18] & 0x2000`.
3. Call `+3A75790(e, v, 0)`. `v` must differ from `[e+0x78]`, or the function
   returns early.

Proven on 2 flags (one active move, one passive stat), in both directions,
across 3 sessions for `flag = 0`.

### Remaining for a real client
1. **Entity discovery without a death after load.** Right after loading, only
   the `121F` entity exists and `[+80]` isn't cached on the respawn entity yet.
   Test whether calling on the `121F` entity with `flag = 0` works, or resolve
   the entity through `[data+28]` instead of `[+80]`.
2. **Threading.** `executeCodeEx` calls from a remote thread. There was one
   crash earlier, of unconfirmed cause, and none in 4 sessions since. The
   client should make the call on the game thread via a hook.
3. **Coverage.** Name the other ~35 respawn-only flags (§59) and spot-check that
   a few more abilities (e.g. Double Wallrun, the Gear tab) use the same entity
   class and mode.
4. The progression menu UI is still stale (§56). Cosmetic.

---

## §67. Double Wallrun: live revoke + grant on a fresh launch, **no death needed**

Session: the game was launched and loaded, with **no death**. Then `diag_apply.lua` v3 was run with
`target(0xF139B4B3, "DoubleWallrun")`.

- The load printed `live (0x2000) candidates: 1   persistent candidates: 1`, so
  the `0x2000` respawn entity **already exists right after loading**.
- Entity `1B941EF0`, flags `321F`, mode function `+473BDA0`. This is the same
  class, flags and mode as Switch Place and IncreasedHealth1.
- The table value was 1 (owned), and Double Wallrun worked before the test.

| call | table | `entity+78` | observed |
|---|---|---|---|
| `probe(0,"live",0)` | 1→0 | 1→0 | double wall-run **stopped working** |
| `probe(1,"live",0)` | 0→1 | 0→1 | double wall-run **works again** |
| `check()` | 1 = original | | OK |

The `+3A75790` disassembly matches §63 byte for byte.

### What this changes
1. **The "die once after load" requirement was wrong,** at least for a normal
   launch-and-load. The level load spawns the player the same way a respawn
   does, so the `0x2000` entity is created and caches `[+80]` at load. The
   rule came from early runs (§61/§62) that were confounded by `flag = 1`, and
   it was never tested separately. Every later protocol simply included the
   death. §66's remaining item 1 ("entity discovery without a death") is
   **resolved for the fresh-load case**. Not yet tested: after fast travel,
   after starting or replaying a mission, and after a checkpoint reload.
2. **The recipe now covers 3 flags and 3 kinds of ability:** an active combat
   move (Switch Place), a passive stat (stamina), and a movement ability
   (Double Wallrun). All three use the same entity class and mode function.
3. The recipe is unchanged: write to the table, then find the `+1C7B168`
   entity with `[+80] == node+0x10` and `[+18] & 0x2000`, then call
   `+3A75790(e, v, 0)`.

### Remaining for a real client
1. Check that entity discovery still works after fast travel, a mission
   start/replay, and a checkpoint reload. The `0x2000` entity is rebuilt on
   respawn, so the client must re-scan before every grant, which the scripts
   already do.
2. Threading: make the call on the game thread through a hook, not with
   `executeCodeEx`.
3. Coverage: spot-check one Gear-tab item and one flag from the "24" group on
   its own.
4. The menu UI is still stale. Cosmetic.

---

## §68. The live entity survives a mission start and fast travel. Grants keep working.

This is the same game session as §67 (launched, no death). `diag_apply.lua` v3 was loaded
once. Each round was `probe(0,"live",0)`, then `probe(1,"live",0)`, then
`check()` on `DoubleWallrun` (`F139B4B3`).

| state | entity found | result |
|---|---|---|
| fresh load (§67) | `1B941EF0` `321F` | revoke stopped the move, grant restored it |
| after **starting a mission** | `1B941EF0` `321F` | same, as expected |
| after **fast travel** | `1B941EF0` `321F` | same, as expected |

Each time there was exactly one `0x2000` candidate. `check()` returned OK (1) every
time.

### What this shows
- **Neither a mission start nor fast travel rebuilds the check entity.** It is
  the same object at the same address, with the same flags and the same `data` (`15B96F500`).
  By contrast, a **death** creates a new `0x2000` entity (§59/§61). The re-scan
  in every probe already handles that: the §64–§66 tests all ran after a death.
- So live grants have now worked in every state tested: fresh load, after a
  death, after a mission start, and after fast travel. They have worked for 3
  abilities, in both directions.

### Still untested
- Checkpoint reload / "restart from checkpoint".
- Going to the main menu and loading again without closing the game.
- Whether a grant made **during** a mission survives the mission ending.
- Threading. It stays the main engineering item: the call must run on the game thread
  through a hook in the real client.

### §68 addendum: checkpoint restart rebuilds the entity, and the re-scan handles it

This is the same game session. Using "restart from checkpoint" from the pause menu, then the same
three calls:

| state | entity found | `data` | result |
|---|---|---|---|
| after **checkpoint restart** | **`1D5BB5B0`** `321F` (new) | `15B96F500` (unchanged) | revoke stopped the move, grant restored it |

- The restart **replaced** the `0x2000` entity. Its address changed, as it
  does on a death. The script's per-call re-scan found the new one with no
  reload, and it was still the only candidate. That is the behavior a client
  needs.
- The entity's `data` pointer (`[e+0x28]`) did **not** change. `data` is the
  static per-ability definition. The entity is the per-spawn instance. So a client
  could cache `data` per ability and find the live entity faster by
  matching `[e+0x28] == data` plus the `0x2000` bit, instead of going through `[+80]`.
  This hasn't been needed so far. It is an option if scan cost matters.

**Live grants tested so far:** fresh load, death, mission start, fast travel
and checkpoint restart all pass. A "quit to main menu and reload" state **does not
exist** in this game. The pause menu's start screen is a still image over the
map, and leaving it returns straight to gameplay with no load (confirmed by the user).
So that covers every in-session state that rebuilds, or might rebuild, the
entity. The only other load is closing and relaunching the game, which is the fresh-load case (§67).

---

## §69. MAG Rope Swing (a story-gated gear flag) uses the same mechanism. Live revoke + grant works.

Same game session as §67/§68. `target(0xE77600AB, "MagRopeSwing")` =
`CriticalPathProgression_HasCollectedMagRopeSwing`. This is **not** an `Unlocks_*`
flag. The story grants it (Savant Extraordinaire, "Getting Magrope").

- Table value 1 (owned). **Live candidates = 1.** The entity has `flags 321F`, `data 15B96F090`
  (a different per-ability definition from Double Wallrun's `15B96F500`), and mode
  function `+473BDA0`. It is the same `+1C7B168` class as every ability tested so far.

| call | entity | table | result (user) |
|---|---|---|---|
| `probe(0,"live",0)` | `1DA02F40` | 1→0 | swing stopped working |
| `probe(1,"live",0)` | **`1B889240`** | 0→1 | swing works again |
| `check()` | | 1 = original | OK |

### What this shows
- **The gear from story progression is gated the same way.** The
  `CriticalPathProgression_HasCollectedMagRope*` flags are enforced by the same
  flag-check entities and respond to the same `+3A75790(e, v, 0)` call. So the
  grapple can be an Archipelago item, and so can each of its uses separately (Swing,
  PullUp, PullDown, and LineConnector, which is absent from this save).
- The recipe now covers 4 flags across 4 kinds: a combat move, a passive stat,
  a movement ability, and story-gated gear.

### The address change: a death between the calls (user confirmed)
The user **died between the revoke and the grant**, while the flag was 0. That
explains the new entity (`1DA02F40` → `1B889240`). It also shows more than the
planned test did:
- The entity rebuilt on respawn read the table value **0**, and the swing stayed
  off after the respawn.
- The grant was then applied to that **new** entity, found by the per-call
  re-scan, and it turned the swing back on without another death. So the grant
  fixed it, not the respawn.
- This is the §59 autosave risk: a death with a test value in the table. The table
  is back to 1, so any later save writes 1. Before closing the game, reach a
  checkpoint or autosave, or check the save file afterwards
  (`CriticalPathProgression_HasCollectedMagRopeSwing` must be 1).

### Not yet tested
- PullUp (`0xE17601CF`), PullDown (`0x16F58B58`) and LineConnector (`0xD68DA442`)
  on their own. LineConnector has no record in this save, so check that it
  exists in the table before targeting it.
- Whether removing MAG Rope in a save where the story has already passed a
  rope-required point can soft-lock traversal. That is a logic and design question for
  the AP world, not a mechanism question.

---

## §70. Full census of live flag-check entities: 28 live, and basic climbing isn't among them

`runtime/list_live_checks.lua` (read-only) was run in the same session, after §69. It found 1121 entities of
class `+1C7B168`, and every one resolved to a flag through `[+80]`. **28 have the
`0x2000` "live" bit.** Every one of them is a player ability, except one tutorial counter:

| group | flags (value in this save) |
|---|---|
| Movement | DoubleWallrun 1, ExtendedSlide 1, FastClimb 1, QuickTurn 1, Coil 1, Shift 1, SkillWindowSkillRoll 1 |
| Combat | FlowAttack 1, FlowAttack_PowerAttack 0, FlowAttack_Special_PowerAttack 0, ImpactAttack_PowerAttack 0, ImpactAttack_Special_PowerAttack 0, HandToHandCombat 1, MoveEnemyAttack 1, MoveEnemyBack 1, CombatRecovery 0 |
| Gear: Disruptor | Disruptor_StunHumans 0, Disruptor_StunMech 0, Disrupter_IncreaseRange 0 |
| Gear: stamina | IncreasedHealth0 1, 1 1, 2 0, 3 0, 4 0 |
| Gear: MAG Rope | MagRopeSwing 1, MagRopePullUp 1, MagRopePullDown 0 |
| (not an ability) | `MoveTutorials_NumberHeavyLandings` 0 |

So **27 ability flags can be granted live with the §67 recipe as it stands.** Five of
them are proven (§66–§69). The rest share the same entity class and mode, and they sit in the
same `data` block (`15B96E9xx`–`15B96FCxx`).

### Answers
- **Basic climbing, vault and wallrun have no flag.** No live entity checks anything
  like that, and no flag in the 2376-name table names it. That confirms §20/§23: the
  "17 always-owned nodes" are hard-wired moves, not items. FastClimb is the
  only climb-related flag, and it's an upgrade.
- **IncreasedHealth3/4 have live entities.** That supports §57: they are real, grantable
  flags even though they are outside §21's 34.
- **MagRopePullDown is 0 in memory and has a live entity**, while the old decoded save
  showed 1. That save is a different, older file, so there's no contradiction. It's just
  the current state.
- `LineConnector` has **no** entity. It may be unused, or only enforced
  elsewhere.

### 12 of §21's 34 reachable abilities have no **live** (`0x2000`) entity
**Correction, same day:** the first version of this paragraph said these have
no entity at all and are "owned". Both claims were wrong. Cross-checking the census rows shows
each one **does** have persistent `121F` entities, and several are **0** in the
current save:

| flag | hash | value | `121F` entities |
|---|---|---|---|
| Disruptor_Overload | B75C826E | 0 | 22 |
| ExtendedComboVulnerability | 87156FC6 | 1 | 1 |
| Focus | 2C9CC1D5 | 0 | 2 |
| Focus_FlowAttackFluency | 12B6DD5E | 0 | 2 |
| Focus_ReachFlow_Increase | B4F7A73E | 1 | 2 |
| Focus_ReachFlow_IncreaseExtra | 80E2C6E4 | 0 | 2 |
| Glove | 2CB07F0E | 1 | 2 |
| LowerHealthEnforcer | 071FEB22 | 1 | 1 |
| LowerHealthProtector | C0B346D0 | 1 | 1 |
| LowerHealthSentinel | 243C4904 | 0 | 1 |
| LowerHealthShockProtector | 56E000EC | 1 | 1 |
| PositionalAdvantage | EC427EC6 | 1 | 1 |

So these abilities aren't applied through a per-spawn player entity. Either the
game reads the table directly when they're used, or they're applied by the
persistent entities. **Next test:** write to the table only, with no call, and see whether
the ability changes. If it doesn't, try `+3A75790(persist entity, v, 0)`.

### Other observations
- Many ability flags also have **many persistent (`121F`) entities**: PullUp has 23,
  Swing 7, StunHumans/StunMech about 20 each. These are probably world objects (grapple
  points, Disruptor targets) that check the flag for their own state, such as whether to show
  a prompt. The §69 Swing test didn't touch them, and the swing still worked. If a
  granted ability ever looks half-enabled (the move works but a world prompt is
  missing), these are the first place to look.
- The remaining ~1090 persistent entities are level-script flags (counters,
  door states, a timestamp and so on). They're not relevant to items.

---

## §71. Unlocks_Focus: a table write alone applies on the next death. Whether it applies live is **inconclusive**.

Same session. `Unlocks_Focus` (`2C9CC1D5`) has no `0x2000` entity, only 2 persistent
`121F` ones (§70 table). Its data pointers are `15A90AAE0` and `15B713C00`. The latter
is in the same `15B71xxxx` block as the persistent twin of every live ability
(for example DoubleWallrun `15B7143A8`, MoveEnemyBack `15B7140D8`).

Test: `setflag` wrote the §56 table directly, with no function call.
- **No visible live change**, but the check was weak. **Correction (user, same
  session):** the only thing observed was whether the Focus **bar** appeared. The bar
  may only be (re)built at respawn, so the ability could have been active with no bar.
  For comparison, the stamina bar did update live in §66. So "not live" is **unproven**.
  A proper check is gameplay: take fire while sprinting with the flag at 1, and again at 0.
- **After a death, the change applied.** The user saw the focus shield appear or
  disappear, depending on the value written. So the flag is read when the player
  respawns, just not through a `0x2000` entity. This is the same "respawn-only" behavior
  §57 saw for every flag before `+3A75790` was found.

So a restart-free grant of these 12 abilities still works **at the next death or
checkpoint restart**. That's an acceptable fallback for Archipelago. A true live grant
needs whatever the respawn path does for them.

**Next:** `runtime/persist_apply_test.lua` calls `+3A75790(e, v, 0)` on the
persistent entities, one at a time or all together, and has a `restore()` that
checks itself.

**Save caution:** the user died with a test value in the table. The value that was
autosaved must be checked before the game is closed.

---

## §72. Focus granted and revoked **live** by calling `+3A75790` on a persistent entity

Same session. The flag started at 0 (confirmed by a death). `runtime/persist_apply_test.lua` listed:

| # | entity | flags | `entity+78` | data |
|---|---|---|---|---|
| 1 | `1DA089D0` | `121F` | 0 | `15A90AAE0` |
| 2 | `1DBC2D00` | `121F` | **1** (stale) | `15B713C00` |

- `apply(1, 1)`: table 0→1, then `+3A75790(1DA089D0, 1, 0)`. **Focus granted live.** The user
  confirmed it in-game.
- `restore()`: table →0, then the call with 0 on both entities, since each had
  `+78 ≠ 0`. **Focus removed live.** The user confirmed it.

### What this shows
- **Abilities without a `0x2000` entity can still be granted live.** Call the same
  function, `+3A75790(e, v, 0)`, on the right **persistent** entity. For Focus that is
  the one with data `15A90AAE0`.
- Entity #2 (`15B713C00`, in the `15B71xxxx` block that pairs with every live ability)
  held a **stale 1** while the table was 0, and Focus was **off**. So that entity
  isn't what enforces Focus, or at least doesn't do so on its own. The grant came from #1 alone.
  The revoke called both, so it doesn't say which one mattered.
- This also explains §71: the respawn re-evaluates these entities, which is why a table-only
  write took effect at the next death.

### Client recipe, extended
1. Write the value to the §56 table.
2. Find every `+1C7B168` entity with `[e+0x80] == node+0x10`.
3. If one has `0x2000`, call `+3A75790(e, v, 0)` on it (§67). **Otherwise, call
   it on every persistent entity for that flag.** For Focus, calling both is harmless and covers
   the one that matters.
4. Untested: flags with many persistent entities, for example Disruptor_Overload with 22.
   Those are probably world objects (Disruptor targets). Calling all of them is likely fine, but
   test one before relying on it.

**Tally:** live grant and revoke is proven on 5 flags. Four use the live entity: MoveEnemyBack,
IncreasedHealth1, DoubleWallrun and MagRopeSwing. One uses a persistent entity: Focus. The other 23
live-entity abilities (§70) share the first four's setup but haven't been tested one by one.

---

## §73. Disruptor_Overload: calls on 24 then 17 entities all returned, and the game crashed **after** `restore()` reported OK

Same session, `persist_apply_test.lua`, `Unlocks_Disruptor_Overload` (`B75C826E`),
table 0. At selection there were **12** `121F` entities: one `15B71` twin (`15B7137F0`), one lone entity
`[5] 1CCE7110` with data `15A848560` (picked by analogy with Focus's `15A90AAE0`), and 10 with
data `15BB11400`. The §70 census had 22 at another moment.

Full log sequence:
1. `apply(5, 1)`: table →1, and the call on `1CCE7110` returned.
2. `applyall(1)`: the re-scan found **24** entities by then, and all 24 calls returned.
3. `restore()`: table →0. The re-scan found 17 entities with `+78 ≠ 0`, called each with 0,
   and all returned. It printed **"restored to 0 -- OK, safe to die"**.
4. **The game crashed after that**, during play. No call was in flight.

**In-game effect (user):** after step 1 and after step 2, nothing visible happened near enemies. The
Overload UI indicator the user expected never appeared. This is **inconclusive**, for the same
reason as §71: the check was a UI element, and those may only rebuild at respawn. A better check
is `setflag` to 1 (table only, no calls), then a death, then a look near enemies. That
tests whether the flag itself grants Overload. If it does, the respawn path is at least a safe
fallback for this ability.
**Update (user):** the user thinks they may have been looking for the effect of a
**different** ability than Disruptor Overload. So §73 says nothing either way about whether
Overload can be granted. Only the crash observation stands.

### Observations
- **These entities stream with the world.** There were 12 at selection, 24 a moment later, and
  `restore()` found several addresses that weren't in the `applyall` list
  (`1B304140`, `1B415610`, `1B96DFE0`, `1CBC2F40`, `1CBC6150`, `1CD5D920`, `1D5B6150`,
  `1DF972C0`, `1E0D81F0`) that already had `+78 = 1`. Newly streamed-in entities read
  the table **while it was 1** and evaluated themselves. So these are world objects
  (probably Disruptor targets) that each check the flag on spawn, not a
  player-ability consumer.
- A crash **after** every call returned points to the flips themselves leaving world
  objects in a bad state, not to a fault in the call. Fired from another thread, mode 2 with
  `r8=0` sends each object's event with no sync to the frame. The Cheat Engine thread
  could also have been racing the world streaming. Not distinguished.

### Consequences for the client
- **Don't broadcast `+3A75790` to world-object entities.** For flags like Overload, write
  the table (world objects read it when they stream in), and call at most the player-side
  entity. That would be the `15A848xxx` one, *if* the user confirms `apply(5,1)` alone
  worked.
- Every real call must go through a game-thread hook. There have now been two crashes around
  remote-thread calls.

Save: `restore()` had put the table back to 0 before the crash. Still check
on disk: Overload 0, Focus 0, MagRopeSwing 1, DoubleWallrun 1.

### §73 addendum: the test value reached the save
After relaunching, `checksave()` (runtime/setflag.lua, read right after load, so it reflects
disk) showed **`Unlocks_Disruptor_Overload = 1`**. It was 0 before the test (§70 census, and
the `persist_apply_test` load). `restore()` had set it back to 0 in memory, but an autosave
happened while it was 1, during the `apply`/`applyall`/test window. The crash then stopped any later
save from writing 0. The other three test flags were correct (Focus 0, MagRopeSwing 1,
DoubleWallrun 1).

- For testing: the rule "restore before any death **or checkpoint**" isn't enough on its own. An
  autosave can happen while you're just moving around the city. Keep test windows short, and
  run `checksave()` after every session.
- For the client, this is good news: a live table write is persisted by the game's
  own autosave, so AP grants survive with no save editing.
- **Fixed and verified on disk.** In the relaunched session: `setflag(0xB75C826E, 0)`, waited for an autosave,
  closed the game, relaunched, and `checksave()` right after load showed all four OK
  (Overload 0, Focus 0, MagRopeSwing 1, DoubleWallrun 1). Together with the accidental 0→1
  write above, this proves **in both directions** that a live table write alone is persisted by
  the game's autosave.

---

## §74. Side missions: a live `SilverCompleted_` write alone does **not** add the mission to the replay menu

`runtime/sidemissions.lua` (table writes only, no calls). State at load: only
**Birdman's Delivery** (Silver 1, CompletedTime 4380) and **Two Pigeons With One Stone**
(1, 5173) are unlocked. The Meta Grid has `_Available = 1` but Silver 0. All the others are 0.

- `smset(10, 1)`: `SilverCompleted_Top of the World` (`FB1C79F9`) 0 → 1. **The mission did
  not appear** in Missions → Side Missions.
- `smrestore()`: back to 0. Confirmed with `sm()`.

### Why this doesn't contradict §25
§25's successful closed-game unlock **also** had `Finger on the Pulse_CompletedTime = 2699`
in the save. It was left over from try 2, and §25 round 1 confirms both were present. So the working
state was **Silver 1 + CompletedTime ≠ 0**, not Silver alone. Two explanations remain:
1. The menu needs both flags. Next test: also write `Top of the World_CompletedTime`
   (`0792DC9B`) live.
2. The menu list is built from the save or table only at load, or at a checkpoint.
   If so, a live write would show up after a checkpoint restart or death. Next test: the same write,
   then a checkpoint restart.

Either way, for Archipelago a "side mission unlocked" item that shows up at the next
restart or reload is still usable. The design already treats side missions as
locations first.

### §74 follow-up: Silver + CompletedTime written live, then a **checkpoint restart**, and the mission appears
The same session wrote both values live: `SilverCompleted_Top of the World = 1` and
`Top of the World_CompletedTime` (`0792DC9B`) = 2699.
- Closing and reopening the pause menu: **not** in Missions → Side Missions.
- After **restart from checkpoint**: **it appeared** in the Side Missions list.

**Conclusion:** the replay list is built at load (a checkpoint restart counts), not when
the menu opens. So a live table write is enough to unlock a side mission as an AP item. It
shows up at the next checkpoint restart, death, fast travel or relaunch. That last point is
untested for death and fast travel.

Still open:
- Is CompletedTime needed? Test Silver alone + checkpoint restart. If Silver alone works,
  the client can leave `_CompletedTime` at 0, and **completion detection becomes trivial**
  (`_CompletedTime` goes 0 → nonzero means the player really finished it).
- Does the unlocked mission load and play correctly from a live-written state? §25 proved
  this only for a save-edit unlock.
- After `smrestore()`, the mission presumably stays in the list until the next reload. Not
  checked.

### §74 follow-up 2: **`SilverCompleted_` alone is enough.** CompletedTime isn't needed.
Only `smset(10, 1)` was written (`Top of the World_CompletedTime` stayed 0), then a checkpoint restart:
**the mission appeared in the Side Missions list.** Restored afterwards, and `sm()` showed row 10 at `0 0 0`.

So the first §74 attempt failed only because nothing reloaded, and the `CompletedTime = 2699` in
§25 was incidental. **Client design:**
- Unlock item: write `SilverCompleted_<m> = 1` live. It appears in the replay list at the next load
  (checkpoint restart, and presumably death, fast travel or relaunch).
- Location check: `<m>_CompletedTime` goes **0 → nonzero** when the player really
  finishes the mission. The client never writes it, so there's no synthetic seed to compare against.
