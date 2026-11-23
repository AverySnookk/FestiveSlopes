# Changelog

All notable changes to Festive Slopes (AverySnookk Studios).

## 0.1.2 (2026-11-22)

### Changed
- **Many more dressed trees.** Every density level dresses roughly two to three times as many trees as before. On Palisades Tahoe, moderate went from 329 to about 1,100 trees, and festive and wonderland reach the new cap.
  - The default `max_decorations` is now 1500 (was 600). If you keep your old settings file, raise it there too.
  - The number of gingerbread houses per trail is about the same as before.

### Fixed
- **Gingerbread houses were half buried in snow.** The game piles snow up to a few metres deep on top of the ground, and the houses stood on the bare ground. Houses now stand on top of the snow, read from the game's own snow simulation. Every few minutes the mod checks the snow again and moves any house whose snow got deeper or melted. A frosted gingerbread base shows when the snow is lower than the house.
- **Gift boxes and the lowest lights were under the snow** on trees. They now stay above it.
- **Lights floated around some trees.** The game's whitebark pines have a spreading, gnarled crown, and the light spiral (made for cone-shaped trees) did not fit them. They are no longer dressed. Spruce, fir, pine and hemlock are.
- **The whole resort was re-planned every 30 seconds** on some saves, for nothing, because the game's forest grows by itself. Only trees you clear now count as a resort change.

### Performance
- Decoration groups are capped at 12 decorations, so the denser levels do not cause long frames. The worst frame while building is about 50–80 ms (as in 0.1.1).
- First visit to a resort: the first decorations appear after about 20 s (0.1.1: about 15 s, with a third as many trees). Later visits: about 5 s.

## 0.1.1 (2026-11-22)

### Fixed
- **Decorations took about a minute to appear** on the first visit to a resort, so it looked as if the mod did nothing. Now the trees near the camera light up within about 15 s (about 6 s on later visits, from the cache), and the whole resort is done in about 25 s.
  - The mod starts 5 s after the resort loads instead of 15 s.
  - The first build gets twice as much time per frame. Later background updates still use the small budget.
  - Decorations nearest the camera are built first.

## 0.1.0 (2026-11-21), first release

Tested on Ski-E-O! Ski Resort Tycoon build CL8231 with UE4SS 4.0.0.

### Added
- **Dressed trees.** The game's own trees get Christmas lights (multicolour or warm white), gold stars, ornaments and gift boxes. The mod adds no trees: it picks healthy evergreens (spruce, fir, pine, whitebark pine, hemlock) along trail edges and around buildings. Lights follow each tree's real height and canopy, so they rest on the branches.
- **Gingerbread houses** beside trails: icing trim, snowy candy roofs, gumdrops, candy canes, glowing windows, a chimney, and a candy fence and path.
- **Five density levels:** off, light, moderate (default), festive and wonderland. One trail always stays natural.
- **House placement rules.** Houses stay outside the game's skiable corridor and away from:
  - the forest
  - buildings, lift stations, lift towers and cable lines
  - small props (lights, benches, terrain-park features)
  - saved walkways
  - steep or uneven ground
- **Stable layouts:** seeded from the resort's playthrough id; `placement_seed` overrides it. Placements are cached per resort in `Cache/`.
- **Automatic updates** every 30 s when trails, buildings, lifts or trees (cleared or planted) change. Only the changed stretches are rebuilt.
- **Settings file** `Config/FestiveSlopes.ini`.
- **Keys:** Ctrl+Alt+F show/hide, Ctrl+Alt+G regenerate, Ctrl+Alt+J status.
- **Commands** through the UE4SS console (`festive <command>`) or `commands.txt`.
- **Cosmetic only:** no collision, nothing registered with the game, nothing written to save files. Leftover decorations are removed on map changes and after a mod restart.
