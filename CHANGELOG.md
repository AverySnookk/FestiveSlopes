# Changelog

All notable changes to Festive Slopes (AverySnookk Studios).

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
