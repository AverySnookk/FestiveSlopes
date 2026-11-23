# Festive Slopes: test results

## 0.1.2 (2026-11-22)

**User report on 0.1.1, with screenshots:** too few dressed trees; lights floating around some trees; gingerbread houses half buried in snow. The user's log also showed the whole resort being re-planned every 30 s for nothing.

Lab: Palisades Tahoe, the same save as before, other mods disabled. The saves folder was backed up and restored as before.

| Test | Result |
|---|---|
| Which trees looked wrong | The game's whitebark pine meshes (10 m and 15 m), which have spreading, gnarled crowns. Screenshot of a dressed one confirmed it. They are no longer dressed. Census at moderate: spruce 665, fir 336, pine 84, whitebark pine on the conical 20 m pine mesh 16, gnarled whitebark pine 0 |
| Snow depth source | Read from the game's snow grid (see RESEARCH.md). 7 house spots: 191–302 cm of snow. Under the game's buildings: 8–27 cm |
| Houses on snow | Screenshots of 4 houses: walls, door, windows, canes and fence fully above the snow (`docs/screenshots/gingerbread-house-on-snow.png`). Before: half buried at the same spots |
| Snow change | A house group's recorded snow depth was faked 100 cm lower. The watch noticed it ("snow 301 cm, was 202 when built") and rebuilt that one group: 1 built, 58 kept, 2.1 s |
| Moderate, first visit | 1,123 trees, 6 houses, 123 groups. First decorations 22 s after load, whole resort 65 s. 0 errors |
| Moderate, later visit (cache) | First decorations 5 s after load, whole resort 53 s. 124 tagged actors after the menu round trip (123 groups and the material holder), so no leftovers |
| Festive | 1,494 trees, 6 houses (capped at 1,500), 153 groups, 92 s. 0 errors |
| Wonderland | 1,493 trees, 7 houses (capped), 154 groups, 118–153 s. 0 errors. The re-planned cache file was byte-identical to the previous one |
| Performance while building | Average 10–12 ms per tick, worst 52–81 ms. Before the fixes below the worst was 221 ms |
| Performance idle (snow watch running) | 0.29–0.31 ms per tick, worst 14–17 ms |
| Re-planning | No re-plan during the lab session. The obstacle count did not change in the lab, so forest growth itself was not reproduced. The fix comes from the user's 0.1.1 log: 3 re-plans of 26 s each, all ending "0 built, 53 kept", with no layout change |

**Fixed during testing**
- With twice as many trail stretches, every stretch could also roll a house. Each house try searches its whole trail edge, so planning took 26 s. The house chance is now scaled so the number of houses per metre of trail stays as in 0.1.1. Planning dropped to 16 s.
- Groups of up to 55 decorations (97k vertices) were built in one tick (up to 300 ms per group). Groups are now split at 12 decorations.
- Planning laid out every house's candidate list in one tick (196 ms at wonderland). These lists are now made when each house is tried (15 ms), with an identical result.

## 0.1.1 (2026-11-22)

**User report on 0.1.0:** "doesn't do anything". The log showed the mod working: the layout was planned 41 s after the resort loaded, and the player left at 53 s, before the first group was built.

Lab timing on Palisades Tahoe, moderate density, measured from the resort being up:

| Visit | First decorations (near the camera) | Whole resort | Before (0.1.0) |
|---|---|---|---|
| First visit (no cache) | 14 s | 26 s | about 55–60 s |
| Later visit (cached) | 6 s | 16 s | about 30 s |

The average tick while building is 5.4 ms, with a worst tick of 85 ms during the load-in. There were no errors and no crash. Everything else is unchanged from 0.1.0, whose results follow.

## 0.1.0

**Setup**
- Game: Ski-E-O! Ski Resort Tycoon build CL8231 (UE 5.8), UE4SS 4.0.0, Windows 11, windowed 1600×900.
- Resort: Palisades Tahoe ("Boha"), 15 trails, 31 buildings, 86 small props, 6 lifts.
- Other mods were disabled during the tests (standalone check).
- The lab tools back up the saves folder at the start of each session and restore it afterwards.

Every result below was observed in the running game, from the mod's log, its status reports and screenshots. Results from the final build (game-thread loop) are dated 2026-11-22.

## Passed

| Test | Result |
|---|---|
| Resort load, moderate (default) | 329 dressed trees and 2 gingerbread houses in 49 groups, about 30 s after load |
| Light | 53 trees, 0 houses, 23 groups |
| Festive | 593 trees and 7 houses in 59 groups, 80 s. Built twice, no errors |
| Wonderland | 593 trees and 7 houses, 106 s (same as festive on Boha: both reach the 600 cap) |
| Density changes in a running game | moderate → festive → wonderland → festive → moderate; unchanged groups kept, the rest rebuilt or removed |
| Off | all 49 groups removed, 0 decorations |
| Hide / show | 49 groups hidden and shown |
| Clear / enable | everything removed and the mod paused, then rebuilt from the cache (16.6 s) |
| Cache | regenerate reuses all 49 groups (0.1 s); a forced recompute writes a byte-identical cache file |
| Menu round trip | back to the main menu and load the resort again: 49 groups, 50 tagged actors (49 groups plus the material holder), so no leftovers or duplicates |
| Art table detection | identified in 7 ms: 52 of 60 measured trees agree |
| Look | lights sit on the branches of the game's own trees, by day and at night (screenshots in `docs/screenshots/`) |
| Placement | no tree trunk on a trail; houses outside the skiable area and clear of lifts, buildings and props (rejection counts in the log) |
| Saves | saves folder unchanged after every lab session (file list, sizes and dates compared) |
| Performance | idle: 0.1 ms per tick. While placing and building: 1.6–7.3 ms average per tick, worst tick 54–80 ms (one per few seconds during a build) |
| Syntax | all 13 scripts load (luacheck) |

## Crashes during development (all fixed or avoided)

The game crashed seven times during development. The game's crash reporter (Sentry) was running, so these reports probably reached the developer.

1. **27k-vertex group (2026-11-21 21:00).** One group was created in a single tick. Fixed: sections are capped at 3,000 vertices and created over several ticks.
2. **Four lab probes (21:45, 21:49, 21:53, 21:56).** These were research calls, not the mod: FindAllOf over instanced mesh components, `GetSectionFromStaticMesh` on tree meshes, and property helpers used on the wrong property type. The mod never makes these calls (see RESEARCH.md).
3. **Festive builds (22:11 and 22:32).** The most likely cause is Lua running on UE4SS's async thread at the same time as the game thread: before the crashes the log showed Lua values turning into functions. The crash dumps have no symbols, so this could not be proven directly. The loop now runs only on the game thread (`LoopInGameThreadWithDelay`), and the full test set above then passed with no errors and no crash.

## Not tested

- Resorts other than Palisades Tahoe, and other biomes (their species, e.g. birch and larch, are not dressed).
- Long play sessions (the longest test session was about 25 minutes).
- Building, removing and editing trails, lifts and buildings by hand during play. Automatic updates were exercised through density changes and rebuilds, which use the same code path.
- The key bindings (Ctrl+Alt+F/G/J): the same actions were tested through commands.
- Multiplayer with Ski-E-O Together.
- Other hardware and graphics settings.
