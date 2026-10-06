#!/usr/bin/env python3
"""build_worksheet.py -- generate the crowdsourcing worksheet for activity ability logic.

Input : locations.json (from build_checks.py -- carries the decoded in-game names)
Output: activity_logic_worksheet.csv, activity_logic_worksheet.md

The worksheet goes with the playtest save (tools/save/make_testing_save.py): every
mission and activity is unlocked, no abilities are owned, and there is a pile of XP.
A tester plays an activity, buys whatever they turn out to need, and writes it down --
so the sheet is one free-text field per activity, not a grid of tags.

By default it covers only what a tester can actually start from the menu:
the 11 side missions and the 32 named runs (opportunities). The 18 countdown
deliveries and the 8 interventions have no menu entry and behave differently, so
they are left out unless you pass --all.

Run:  python build_worksheet.py [locations.json] [outdir] [--all]
"""
import csv, json, os, sys

HERE = os.path.dirname(os.path.abspath(__file__))
ARGS = [a for a in sys.argv[1:] if not a.startswith("--")]
ALL = "--all" in sys.argv
SRC = ARGS[0] if len(ARGS) > 0 else os.path.join(HERE, "locations.json")
OUT = ARGS[1] if len(ARGS) > 1 else HERE

INTRO = """# Mirror's Edge Catalyst → Archipelago: what did you have to unlock?

We're building an Archipelago randomizer for Mirror's Edge Catalyst. Abilities (wallrun, shift, coil, stamina, MAG Rope, combat moves) get handed out as items, so we need to know which activities are impossible without them — otherwise the randomizer can hand someone a mission they physically cannot finish.

**The playtest save does the work for you.** It has the story finished and the whole city open, every side mission, opportunity and delivery already unlocked in the menus, **no abilities at all** (not even the MAG Rope), and 500,000 XP to spend.

**How to help:**

1. Back up your own `Documents\\Mirrors Edge Catalyst\\settings\\PROF_SAVE`, then drop the playtest save in its place with the game closed.
2. Pick any activity and try it with nothing unlocked.
3. When you get stuck, buy the ability you need from the skill tree and keep going.
4. Write down **which abilities you had to buy** in the row for that activity, and roughly where it blocked you.

That's it — one column to fill in. Skip anything you don't play; even a handful of rows helps.

**Please note:**

- Answer for a normal run, not a perfect one. If you cleared something with a trick most people would miss, say so in the notes.
- If you bought something and it turned out you didn't need it, say so — "bought Coil, could have done it without" is useful.
- **Nothing** in the blank column means "not tested yet", not "needs nothing". Write *nothing needed* when you finished an activity with no unlocks at all.
- This sheet is **side missions and runs only**. Main story missions and the timed countdown deliveries behave differently and probably won't be part of the randomizer, so don't worry about them.
- Careful, the game reuses the word: two of the three **run** types are called *fragile delivery* and *covert delivery*, and those **are** in the sheet. The ones left out are the separate timed countdown deliveries, which have no entry in the Runs tab at all.
- The run names come straight out of the Runs tab, so they should match what you see in game.
"""

NOTES = """
Types come from the game's own data and were confirmed in game: **fragile delivery**, **covert delivery**, **diversion**.
"""


def main():
    locs = json.load(open(SRC, encoding="utf-8"))
    rows = []

    def strip(name, prefix):
        return name[len(prefix):] if name.startswith(prefix) else name

    for l in locs:
        if l["category"] == "Side Mission":
            rows.append((l["id"], strip(l["name"], "Side Mission - "), "side mission", ""))
    named, interv = [], []
    for l in locs:
        if l["category"] != "Opportunity":
            continue
        label = strip(l["name"], "Opportunity - ")
        if l["note"].startswith("intervention"):
            interv.append((l["id"], label, "intervention (no Runs entry)", l["district"]))
        else:
            named.append((l["id"], label, l["note"], l["district"]))
    rows += named
    if ALL:
        rows += interv
        for l in locs:
            if l["category"] == "Opportunity (Delivery)":
                rows.append((l["id"], strip(l["name"], "Opportunity - "),
                             "countdown delivery", l["district"]))

    with open(os.path.join(OUT, "activity_logic_worksheet.csv"), "w",
              newline="", encoding="utf-8") as f:
        w = csv.writer(f)
        w.writerow(["id", "activity", "in_game_type", "district",
                    "abilities_i_had_to_unlock", "where_it_blocked_me", "reported_by"])
        for r in rows:
            w.writerow(list(r) + ["", "", ""])

    with open(os.path.join(OUT, "activity_logic_worksheet.md"), "w", encoding="utf-8") as f:
        f.write(INTRO)
        f.write("\n| # | activity | type | district | abilities I had to unlock | where it blocked me | who |\n")
        f.write("|---|---|---|---|---|---|---|\n")
        for i, (_id, name, typ, dist) in enumerate(rows, 1):
            f.write(f"| {i} | {name} | {typ} | {dist or '-'} |  |  |  |\n")
        f.write(NOTES)

    print(f"{len(rows)} activities: {sum(1 for r in rows if r[2] == 'side mission')} side missions, "
          f"{len(named)} runs"
          + (f", {len(interv)} interventions, "
             f"{sum(1 for r in rows if r[2] == 'countdown delivery')} deliveries" if ALL else ""))
    return 0


if __name__ == "__main__":
    sys.exit(main())
