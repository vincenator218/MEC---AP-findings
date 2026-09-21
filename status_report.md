# Mirror's Edge Catalyst → Archipelago: Status Report

*What's actually load-bearing for building the randomizer, as of now. Full history and every dead end lives in FINDINGS.md — this is the curated version.*

## The goal

An Archipelago client for Mirror's Edge Catalyst: story missions stay linear (they're too world-state-entangled to shuffle), but movement/combat abilities and side missions become AP items and locations. The design is "ship a save with the story finished and every ability locked, then grant abilities and mission access one at a time as AP items arrive."

## What's fully solved and ready to build on

**The save file is completely cracked.** It's an uncompressed, plaintext-keyed format (magic `FBCHUNKS`, typed key/value blocks), the checksum is known, and a working toolchain already exists to read and write it (`decode_save.py`, `patch_save.py`, `set_flag.py`, `clear_all_unlocks.py`, and others in `runtime/`).

**The real item pool is known precisely: 34 abilities.** Cross-checking a fresh save, the player's own save, and a community "100%" save nailed this down — 34 `Unlocks_*` flags are the actual reachable pool (not the 58 names that exist in the static game data; the other 24 are vestigial/unreachable in a normal playthrough). A real 17-checkpoint save set also gave the genuine per-mission unlock order and pace a normal playthrough acquires them in, useful for pacing item placement.

**Granting and revoking abilities via save-file edit is proven safe, end to end, on real hardware:**
- Clearing an owned ability flag measurably disables it in-game (menu count drops, the actual move changes) — confirmed live.
- Clearing all 34 at once and playing a real session through real missions doesn't cause anything to silently re-grant itself — confirmed by diffing the save file before/after.
- This is the core mechanism the whole ability-gating design depends on, and it holds.

**Side missions are individually usable as AP locations too.** Each one can be force-unlocked into the in-game Replay menu with a single flag (`SilverCompleted_<Mission Name>`), it loads as a fully coherent playable instance whether or not the player ever reached it organically, and a real completion afterward cleanly overwrites the synthetic placeholder with genuine data — so "AP unlocked it" vs. "player actually finished it" is automatically distinguishable for free.

**A real proof-of-concept has already talked to an actual Archipelago server.** A standalone bridge script polls the save file and sent live hints to a real AP room every time a GridLeaks collectible was picked up in-game, with zero live-memory access involved. The same pattern is ready to extend to the other collectible categories and to missions/abilities.

## The one open blocker: granting an item into an already-running game

Every proven mechanism above requires the game to be **closed** when the save is edited — reading is fine live, but a live edit doesn't take effect until the next launch. There is still no confirmed way to grant an AP item while the player is mid-session, which matters a lot for how good the player experience can be.

This session was spent specifically chasing that problem via live Cheat Engine memory work:

- Found and confirmed a real, live, game class (`PamProgressionFlagEntityData`) whose values genuinely can be written and persist (survives at least a checkpoint reload) — so live writes to this game's memory are possible in principle.
- But two clean tests (one gated behind a story mission, one with no gate at all) showed this specific class is **not** what the game's ability/purchase system actually reads from. It looks like a generic level-scripting flag, not the authoritative progression store.
- The better-justified remaining leads, not yet chased: `PamClientProgressionFlagEntity` / `PamServerProgressionFlagEntity` (client/server-replicated classes in the game's own SDK, likely the real store, but harder to locate — no automatic pointer chain to them), or finding and calling the game's actual "purchase ability" function directly via DLL injection or Frida, which would sidestep the "which memory struct is authoritative" question entirely.
- A cheap side-test (whether the live XP counter shown on screen survives an autosave) was started but left inconclusive.

**Practical takeaway: the safe, 100%-proven mechanism today is save-file edit + game restart.** Clunky, but it works. The live-injection work is a UX improvement to chase in parallel, not a prerequisite — the randomizer is buildable right now around a restart-based receive model.

## Other things settled and out of scope

- **Time trials ("Dash") are not usable as AP checks.** The community mod that restores online features (Beat Revival) has not yet implemented time trials — confirmed via current documentation. Worth revisiting later if that changes.
- **17 movement/combat/gear nodes stay "owned" even with every known ability flag cleared.** These aren't gated by any of the 34/58 known flags at all — they're baseline moves the game always shows as available. Not a threat to the design, just means they can't themselves be gate-able AP items.

## Recommended next steps

1. **Build the actual item/location JSON now** — the data and the gating mechanism are both fully known (34 abilities with real unlock order, side missions individually flaggable), so this is ready to build rather than still-open research. This has been deprioritized twice in favor of the restart-problem investigation.
2. **Design the client around save-edit + restart as the baseline receive mechanism**, and treat live-write as a stretch goal layered on top later, not a blocker.
3. **If continuing the live-write investigation:** the two named leads above (client/server flag entity via a memory breakpoint technique, or calling the real purchase function via injection) are the next concrete things to try, in that order of effort.
