# Festive Slopes: research notes

Game: Ski-E-O! Ski Resort Tycoon, Steam app 4493130, build CL8231 (Unreal Engine 5.8). Loader: UE4SS 4.0.0, Lua.
Every API below was called from the mod in the running game unless it is marked otherwise. Dates are lab dates.

## Engine and loader facts (verified)

- **Mod location.** UE4SS loads Lua mods from `<game>\mods\<Name>\` when `enabled.txt` is present. Scripts live in `Scripts\` and `main.lua` is the entry point.
- **No coroutines.** UE4SS game calls (and `print`) do not work inside Lua coroutines: "lua state ... has no instance inside lua_instances". All long work is therefore an explicit step machine run from `LoopInGameThreadWithDelay(50)`, with a 4 ms budget per tick.
- **Never run Lua on two threads.** The first loop was `LoopAsync(50)` → `ExecuteInGameThread`, a common UE4SS pattern. It runs the async callback's Lua on UE4SS's own thread while the game thread runs the mod's tick, on the same Lua state.
  - With the long ticks of festive and wonderland builds, this corrupted the Lua state: numbers turned into functions ("attempt to perform arithmetic on a function value", "attempt to compare function with number", "Ref was not function").
  - It also crashed the game inside UE4SS.dll twice (22:11 and 22:32, at different addresses).
  - `LoopInGameThreadWithDelay`, which the game's own bundled mod menu uses, runs everything on the game thread.
- **Module cache.** UE4SS keeps its own `require` cache, so clearing `package.loaded` does not reload a module. The lab hot reload uses `dofile`.
- **Runtime meshes.** A spawned `StaticMeshActor` is used only as a holder.
  - `actor:AddComponentByClass(class, false, FTransform, false)` adds a `/Script/ProceduralMeshComponent.ProceduralMeshComponent`.
  - `CreateMeshSection(i, verts, tris, normals, uvs, {}, {}, false)` accepts plain Lua tables.
  - `SetMaterial(i, mat)` and `SetCastShadow(false)` work on the component.
  - Triangle winding: the front face is the clockwise order (as seen against the normal), so the mod's builder swaps vertices (`WIND = -1`). With the other order, every face rendered black or from the back.
- **Glow.** `CreateDynamicMaterialInstance(i, /Game/Materials/M_Prop_Unlit, FName("None"))` creates a dynamic material. `SetVectorParameterValue` is then called for several candidate colour parameter names. The coloured glow shows in game, but which parameter name the material actually uses was not isolated.
- **Materials.** These are game material instances under `/Game/Materials/Basic/` (e.g. `MI_Prop_Amber_Snowless`, `MI_Prop_White`) and `/Game/Materials/Metals/MI_Prop_Gold_Snowless`.
  - The non-Snowless MI_Prop materials turn white below the game's snow depth, so low decorations (gift boxes, house walls) use Snowless variants.
- **Earlier designs, dropped.** Version 0.1 development first built its own procedural cone trees, then placed the game's tree meshes (`SM_Spruce_10m` and others) through a spawned `InstancedStaticMeshComponent`. Both added trees to the map. After user feedback, both were removed in favour of dressing existing trees (next section).
- **Crash, now avoided.** One group of 27k vertices / 18 sections, all created in one tick, crashed inside UE4SS (access violation in UE4SS.dll; the dump has only UE4SS frames).
  - This happened right after a lab hot reload, so the exact trigger is not proven.
  - Since then, sections are capped at 3,000 vertices and created a few per tick. Groups cover 150 m of trail.
  - Since then, four crashes came from lab probes (listed below) and two from the threading problem above. The 27k-vertex crash may have had the same threading cause.

## The game's trees (verified)

Design decision, from user feedback on 2026-11-21: the mod adds **no** trees and dresses the game's own instead.

- **Where trees live.** Trees are entries in `ObstacleDataManager.Obstacles` (about 1.39 million on Boha), drawn by the game's own renderer.
- **Reading full tree data.** `GetObstaclesInRadius(center, radius)` returns `FObstacleData { Type, Transform, ClearingCost, InstanceIndex, ArtHandle }`.
  - The query is a sphere, so the centre must be near the ground.
  - `QueryObstaclesNearPosition` returns positions only.
  - In the Yeti Mayhem notes, `GetObstaclesInRadius` "returned empty" because the query centre was not at ground height.
- **Tree height.** `GetMaxTreeCanopyTopZNearSegment(start, end, halfWidth, out)` returns the canopy top. Height ÷ instance scale came out at the art's nominal 10.0 / 15.0 / 19.9 m.
- **Species data.** Species are `TreeSpeciesDataAsset`s (14 loaded), each with `Art: TArray<FTreeArtVariant { SizeClass, Condition, Mesh, CanopyMesh, ... }>`. The biome (`ObstacleDataManager.CachedBiomeSettings`, e.g. `DA_BiomeSettings_Tahoe`) lists its `SpeciesRoster`: Spruce, Fir, Pine, Aspen and WhitebarkPine.
- **ArtHandle** indexes a native art table that is not reflected.
  - Measured on Boha, its blocks match the species assets sorted by name, each species' variants in order, with Sclerophyll absent. Within a species, handles step by 3 per size class (healthy / dying / dead).
  - The mod does not hard-code this. It builds every candidate table (all species, or one left out) and scores each against measured tree heights.
  - Ties are broken by the biome roster: Pine and Sclerophyll have identical size layouts, so leaving out either one matched the heights equally well.
  - Result on Boha: 52 of 60 measured trees agree, using the table without Sclerophyll.
- **Mesh size.** `UStaticMesh:GetBounds()` gives the height and widest radius of each tree mesh. Lights sit at 0.84 × the cone through those bounds, which put them on the branch tips in screenshots.
- **Tree shapes (0.1.2).** The light spiral assumes a cone. The whitebark pine's own meshes (`sm_tree_whitebarkpine_10m`, `_15m`) have a spreading, gnarled crown, and lights floated around them (user screenshots, 2026-11-22). Its 20 m size uses the conical `SM_Pine_20m` mesh. The mod skips trees by mesh path (`T.SKIP_MESH`), not by species. Dressed trees on Boha at moderate: spruce 665, fir 336, pine 84, whitebark pine on the pine mesh 16.
- **Forest growth.** `ObstacleDataManager.Obstacles` grows by itself as the game's forest spreads. 0.1.1 used its count in the resort fingerprint and re-planned every 30 s for nothing. Only `ClearedZones` (trees the player cleared) is used now.

## Snow depth (verified, 0.1.2)

User report: gingerbread houses were half buried. The game's snow sits up to a few metres on top of the terrain, and none of the height functions include it. At the same points, `TerrainUtils:GetHeightAtLocation`, `SnapToTerrain`, `SnapToBaseTerrain` and `SkiResortFunctionLibrary:GetGroundHeightAtLocation` all returned the same bare-ground value.

- **Where the snow is.** `SnowSimulationSubsystem` holds render targets only: `CoarseMipRT`, `CoarseMipReadbackFp16RT`, `PackedDensityRT`, `SnowEnvironmentRT`, `BuildingCanopyMaskRT` and others. Its only functions are `HandleMonthChanged` and `GetGridResolution`. `FSnowCellData` is not stored in any reflected property.
- **Reading it.** `KismetRenderingLibrary:ReadRenderTargetRawUV(world, CoarseMipReadbackFp16RT, u, v, false)` returns the cell's raw values.
  - The grid is 1162 × 1162 cells (`GetGridResolution`) of 800 cm (`DA_SnowTileSettings.SnowCoarseCellSizeCm`), which is 9,296 m. That matches the `Landscape` actor's bounds (centre 0, 0; half extent 4,648 m). U runs along X and V along Y.
  - R and G are depths in cm. Beside the forest near the houses: R 198–254, G 36–49. Under the game's own buildings, which clear their snow: R 8–27. With U and V swapped, the building readings were not low, which confirmed the axis order.
  - The mod uses R + G as the depth. In screenshots, houses lifted by that amount (less 15 cm) sit on the snow surface with the door fully visible.
- **Cost.** About 1 ms per read, because it waits for the render thread. The mod reads each 8 m cell once per build, spread over ticks within the frame budget. While idle, it re-reads one decoration group's cell every 2 s.
- **Block reads do not work.** Through UE4SS, `ReadRenderTargetRawUVArea` returned a single value, so it is not used.
- **Still open.** The coarse 8 m grid can differ from the rendered snow surface on slopes and at trail edges.

**Calls that crashed the game in the lab** (UE4SS crash dumps at 21:45, 21:49, 21:53 and 21:56). Never use these:

- `FindAllOf("InstancedStaticMeshComponent")` / `"HierarchicalInstancedStaticMeshComponent"`, then reading their properties (crashed twice, even when filtered by world and skipping default objects).
- `KismetProceduralMeshLibrary.GetSectionFromStaticMesh` on a tree mesh (the meshes have no CPU access).
- UE4SS property helpers on the wrong property type, for example `GetPropertyClass()` on an object property or `GetStruct()` on a non-struct property. `pcall` does not catch these access violations.

## Resort data used for placement (verified)

| What | API |
|---|---|
| Trails | `TrailMapSubsystem` trail pieces (quadratic Bézier centre lines with half widths, plus bowl outlines), chained by the mod into continuous lines |
| Skiable area | `TrailMapSubsystem:IsPositionInCorridor(pos, -1)` and `GetDistanceToCorridor(pos, -1)` (negative inside). Checked per resort against geometry: 8/8 agreement on Boha |
| Terrain | `TerrainUtils:GetHeightAtLocation`, `GetSlopeAngleAtLocation` |
| Natural trees / rocks | `ObstacleDataManager:QueryObstaclesNearPosition(pos, radius)` |
| Buildings and props | `PlaceableRegistrySubsystem.Buildings` with `GetActorBounds`; small props are told apart by class name |
| Lifts | `PlaceableRegistrySubsystem.Lifts`: `Waypoints` (terminals and angle stations, cable line) and `TowerMeshComponents` |
| Resort identity | `GameSessionSubsystem.PendingLoadSave.PlaythroughId` (seed), else resort name, else map |

**Props among the buildings.** On Boha, 86 of the 117 registered "buildings" were small props:

- 44 `BP_TowerLight` along trails
- 12 benches
- 8 picnic tables
- 13 terrain-park rails, boxes and kickers
- lamp posts, heaters and ski racks

Treated as buildings, with a 22 m clearance, they blocked most trail edges. They now get a short fixed clearance (4 m plus their size).

**Open ground is scarce.** Along Boha's trail edges, only about 7% of points (328 of 4,530 samples) are both flatter than 18° and free of tree canopies within 9.5 m. Gingerbread houses therefore take the nearest valid spot anywhere along their trail's edge (a shared grid of candidate spots 15 m apart, at three depths), and they are placed before trees are dressed. Even so, Boha gets only 2 houses at the default density: 2,257 candidate spots were rejected for trees and 1,156 for steep ground.

## Not done / not verified

- **Custom imported assets** (.uasset / .pak with our own meshes and textures). This needs a UE 5.8 editor project cooked for this game; it was not attempted. All decoration geometry is generated at runtime from code and uses the game's own materials.
- **Time of day.** No working day/night setter was found in CL8231 (`SetDayNightPhase` and related calls had no effect). Night and dusk screenshots come from the game's own clock running on.
- **Walkways painted by players** that are not stored as saved walkway runs are not known to the mod. Only saved walkway runs are avoided.
- **Multiplayer** (Ski-E-O Together) was not tested. Decorations are local and cosmetic, so each player builds their own from the same seed.
