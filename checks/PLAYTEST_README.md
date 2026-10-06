# Mirror's Edge Catalyst → Archipelago: ability requirements playtest

Thanks for helping. This is for an **Archipelago randomizer** for Mirror's Edge Catalyst.
In a randomizer, your abilities get handed out as items, so the generator has to know which
activities are **impossible** without a given ability — otherwise it will hand someone a
mission they physically cannot finish, and the run dead-ends.

Nobody has that list. That's what we're building.

## What you're testing

**Side missions and runs only** (runs = the free-roam OPPORTUNITY markers, listed under the
Runs tab in the replay menu). 43 activities in total: 11 side missions, 32 runs.

Not in scope: **main story missions** and the **timed countdown deliveries**. Both behave
differently and probably won't be part of the randomizer.

> One confusing bit: the game reuses the word "delivery". Two of the three *run* types are
> called **fragile delivery** and **covert delivery** — those **are** in scope. The ones we're
> skipping are the separate countdown deliveries, which never appear in the Runs tab.

## The save

`PROF_SAVE_testing` gives you:

- the story **finished** and the whole city open, so you can fast travel anywhere
- every side mission and run **already unlocked** in the menus — start any of them directly
- **no abilities at all.** No Shift, no Coil, no Double Wallrun, no MAG Rope, 4 stamina bars
- **500,000 XP**, so you can buy whatever you need the moment you need it

Nothing is marked as completed, so your own times still record normally.

⚠️ **The save has the story complete, so the menus spoil the ending.** If you haven't
finished Catalyst and care about that, sit this one out.

### Installing it

1. **Close the game completely.**
2. Go to `Documents\Mirrors Edge Catalyst\settings\`.
3. **Back up your own `PROF_SAVE`** somewhere outside that folder. Don't skip this — the
   game overwrites this file constantly and there's no undo.
4. Copy `PROF_SAVE_testing` into that folder and rename it to `PROF_SAVE` (no extension).
5. Launch the game. If Steam Cloud tries to restore your old save, pick the local version.

When you're done, close the game and put your backup back.

If the save loads and your abilities are all still there, **tell me** — don't just play on.
The file carries a section tied to my own EA account id, and it's possible the game picks a
different section on your machine. You'd be the first person to find that out, and it's worth
knowing.

## What to do

1. Pick any activity from the sheet and start it with nothing unlocked.
2. If you get stuck, buy the ability you need from the skill tree and carry on.
3. Fill in the row: **which abilities you had to buy**, and roughly where it blocked you.

That's the whole job. One column. Skip anything you don't feel like playing — a handful of
rows still helps, and you can claim a district in the thread so we don't all test the same six.

### Filling it in well

- **Blank means "not tested", not "needs nothing".** If you finished something with zero
  unlocks, write **nothing needed** — that's a real, useful answer.
- Answer for a **normal** run, not a perfect one. If you cleared something with a trick most
  players would never find, say so in the notes.
- **Bought something you didn't actually need?** Say that too: *"bought Coil, could've done
  it without"* is as useful as a requirement.
- Name the ability the way the skill tree does, and for the rope say which use — swing,
  pull up, pull down.
- Say where it blocked you, even roughly: *"the gap on the roof after the second checkpoint"*.
  If we ever have to re-check a row, that's what saves the time.
- Guessing is worse than leaving it blank. A wrong "nothing needed" is what soft-locks
  somebody's seed three hours in.

## Questions worth answering if you notice them

- Anything that's **impossible** rather than just hard without an ability? Flag it loudly.
- Any activity that **can't be failed** no matter what you lack? Also useful.
- Anything where **stamina** was the wall (a fight or a fall you couldn't survive on 4 bars)?
  Stamina tiers are items too and we have the least idea about those.
