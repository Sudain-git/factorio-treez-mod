# Treez Rewrite — Feature Inventory

Mark each item: [x] = include in rewrite | [ ] = exclude / separate mod | [?] = undecided

---

## 0. Mod Structure

- [x] Barebones mod structure so the mod will load without error
- [x] Individual file/control for tree seed logic
- [x] individual file/control for tree queue logic
- [ ] individual file/control for nitrate logic
- [ ] individual file for dynamic rain intrigrations/logic
- [ ] individual file for winter is coming intigration/logic
- [x] individual files for each graphic

## 1. Tree Seed Item & Planting Entity

- [x] `tree-seed` item (base-game fallback when Space Age is absent)
- [x] `tree-seed` recipe (unlocked by Tree Growth research)
- [x] `tree-seed-site` proxy entity — the placeable marker robots fulfil
- [?] `treez-seed-waiting` marker entity — shows queued seeds on the map
- [?] `tree-entity-ref` hidden item — communicates the base tree name from data stage to control stage
- [x] Seed placement rejection on hard tiles (concrete, stone, etc.)
- [x] Seed placement rejection on natural resource patches (ore, oil, etc.)
- [x] Seed placement rejection on Space Exploration scaffold tiles/surfaces
- [x] Seed placement rejection when a player ghost is already on the tile
- [?] Blueprint normalisation — rewrites `treez-seed-waiting` entries to `tree-seed-site` when blueprinting

---

## 2. Tree Growth System

- [x] `data-final-fixes.lua` — generates 200 hidden growth-stage prototypes per tree species
- [x] Growth stage sprite scaling (sqrt curve, 5% floor)
- [x] Growth stage collision box scaling (20%→100% of base tree)
- [ ] Backward-compat alias stages (`treez-growth-stage-N`) for old save files
- [?] `process_growing_trees()` — advances saplings through stages every 10 ticks
- [?] Growth queue — parks seeds when the active-tree cap is full
- [x] `try_dequeue_tree()` — pulls seeds from the queue when a slot opens
- [?] `prune_growth_queue_for_surface()` — cleans up stale queue entries with no marker
- [x] Stale-entry guard in `try_dequeue_tree` — detects seeds removed without a mined event
- [x] Deconstruction-flag preservation — marked trees stay marked as they grow through stages
- [x] Ghost conflict guard during growth — respects player-placed ghosts at a seed's tile
- [?] Growth speed presets: Instant / Fast (~1 min) / Smooth (~10 min)
- [?] Growth stage variability (±% of base tick interval)
- [?] Day-only growth toggle
- [?] Pollution-delay on growth — higher chunk pollution → longer time between stages
- [?] "Trees enrich soil during pollution delay" sub-option (upgrades tile under tree on skipped tick)
- [?] Max simultaneously growing trees cap (set by research)
- [?] `recalculate_growth_cap()` — derives cap from actual research state, never drifts

---

## 3. Species Selection (Biome Awareness)

- [x] `pick_species_at()` — samples nearby trees, picks species weighted by count and biome nativity
- [x] Biome weight: native species (per `tile_buildability_rules`) get ×3 vs non-native ×1
- [x] Fallback to tile's native species list when no nearby trees exist (cleared land)
- [?] Dead/dry tree re-roll — sparse-looking species re-rolled once to reduce frequency
- [x] Alien Biomes species support — builds `native_species` map from AB tile rules
- [x] Vanilla-only fallback to `tree-01` when no biome data is available

---

## 4. Tree Seeder Area Tool

- [x] `tree-seeder` selection-tool item
- [x] `tree-seeder` shortcut button (toolbar)
- [x] `tree-seeder` custom-input (keybind)
- [x] Tree Seeder density GUI (slider, 10%–100%)
- [x] `on_player_selected_area` handler — places seed-site ghosts at chosen density
- [x] Hard tile / SE-blocked tile filtering in seeder area sweep
- [?] `treez-tree-seeder` technology (prereq: Sapling Growth 6 + logistic science)
- [?] Seeder shortcut availability sync on load and research completion

---

## 5. Tree Growth Research Chain

- [?] `treez-tree-growth` technology — triggered by mining a tree (fires research)
- [?] `on_player_mined_entity` tree counter — counts any tree species toward the threshold
- [?] Sapling Growth technology levels 1–6 (each doubles the active-tree cap)
- [?] Tech prerequisite re-assertion in `data-final-fixes.lua` (guards against SE overwriting prereqs)

---

## 6. Nitrate / Soil Crystal System  ← SEPARATE MOD

- [ ] `soil-crystal` (white) item + chemistry recipe
- [ ] `soil-crystal-black` (primitive/local) item + hand-craft recipe
- [ ] `soil-crystal-site` entity (white pellet)
- [ ] `soil-crystal-black-site` entity (primitive pellet)
- [ ] `soil-crystal-colored-site` entity (catalyst pellet, spawned programmatically)
- [ ] Crystal queue — `enqueue_crystal()`, `process_crystals()` every 60 ticks
- [ ] Night-only firing toggle
- [ ] Batch size limit per processing pass
- [ ] Overflow drain — raises batch size when queue exceeds threshold
- [ ] `crystal_min_fire` scan-skip guard
- [ ] `upgrade_tile()` — single tile upgrade step through vanilla/AB chain
- [ ] `smart_upgrade_tile()` — border-aware expanding-radius upgrade algorithm
- [ ] `TILE_RANK_CACHE` / `tile_rank()` — O(1) tile quality comparison
- [ ] `VANILLA_UPGRADE` chain table
- [ ] Alien Biomes upgrade/decay tile tables (`build_ab_tile_tables`)
- [ ] Vanilla random upgrade pools (`build_vanilla_random_pools`)
- [ ] Hard tile detection (`build_hard_tiles_set`, `is_hard_tile`)
- [ ] Crystal placement rejection on hard tiles and rail
- [ ] Trample mechanic — player/vehicle movement destroys nearby pellets
- [ ] Trample on entity damage (biter attacks destroy pellets)
- [ ] Trample on player manual mining (clears item buffer)
- [ ] Nitrate pollution emission (white pellets emit pollution while queued)
- [ ] Nitrate Catalyst (colored pellets) — `maybe_spawn_colored()`, chain-trigger logic
- [ ] Abundant Nitrate Catalyst technologies (levels 1–3, raise spawn chance)
- [ ] Nitrate Catalyst Reactions technologies (levels 1–3, scale chain reach + count)
- [ ] Enduring Nitrates technologies (levels 1–3, chance to re-queue instead of consume)
- [ ] White Pellet Refinement technologies (levels 1–5, reduce pollution emission)
- [ ] Primitive Nitrates technology (gates black pellet recipe)
- [ ] Soil Crystal technology (gates white pellet recipe + Crystal Placer shortcut)
- [ ] AB pollution decay pass — TerrainEvolution2 integration, degrades tiles near pollution
- [ ] Crystal Placer area tool (shortcut, GUI, area handler)
- [ ] Crystal ghost conflict resolution (`resolve_crystal_ghost_conflict`, `clear_crystal_ghosts_at`)
- [ ] `on_pre_build` crystal ghost sweep
- [ ] Tile-placement cleanup — destroys crystals under newly placed tiles
- [ ] Pellet Placer shortcut availability sync

---

## 7. Sapling Soil Enrichment

- [ ] `treez-soil-enrichment` technologies levels 1–6
- [ ] `try_growth_enrich_soil()` — distance-weighted random tile upgrade per stage advance
- [ ] `get_soil_enrichment_level()` — reads research state (currently uncached)
- [ ] Tech prerequisite re-assertion in `data-final-fixes.lua`

---

## 8. Dynamic Rain Integration  ← DEPENDS ON DYNAMIC-RAIN MOD

- [?] `treez-arboreal-aromatics` technology (space-science gate, enables rain seeding)
- [?] Cloud Seeding technologies levels 1–6 (scale seeds per cleaned chunk)
- [ ] `treez-restorative-rains` technology (space-science gate, enables rain nitrates)
- [?] `setup_rain_event_listener()` — registers DR's `on_rain_pollution_cleaned` event
- [?] `on_rain_pollution_cleaned` handler — credits + zero-crossing detection
- [?] `try_rain_seed_chunk()` — scatters seeds in pollution-cleared chunks
- [?] `get_rain_seed_count()` — reads research state (currently uncached)
- [?] `rain_seeding_tick()` — storm start/end bookkeeping (resets per-storm ledgers)
- [?] Rain growth boost — halves growth tick interval during active rainfall
- [ ] Restorative Rains credit system — accumulates credits per chunk cleaned
- [ ] `restorative_rains_tick()` — spends credits to place nitrate pellets during storms
- [ ] `try_place_rain_nitrate()` — placement guards for rain-dropped pellets
- [ ] Per-storm deduplication guard (each chunk seeded once per storm)
- [ ] Rain seed debug toggle — prints chunk/seed placement to all players
- [?] Tech prerequisite re-assertion in `data-final-fixes.lua`

---

## 9. Foreign Tree & Ghost Sweep

- [X] `run_seed_ghost_collision_sweep()` — cancels unfulfillable seed ghosts blocked by foreign trees
- [X] `run_foreign_tree_ghost_sweep()` — marks foreign trees that block any ghost for deconstruction
- [X] `seed_ghost_sweep_tick()` — triggers sweeps once per day/night cycle at dusk, per surface
- [X] `foreign_tree_sweep_enabled` setting toggle

---

## 10. Script-Raised Build Compatibility

- [x] `script_raised_revive` handler — processes seeds/crystals placed by mods via `entity.revive()`
- [x] `script_raised_built` handler — processes seeds/crystals placed by mods via `create_entity` + raise
- [?] `/treez fix-sites` command — manually routes stranded `tree-seed-site` entities through the placement pipeline

---

## 11. Mod Compatibility

- [X] Alien Biomes — species map, tile upgrade/decay tables, dominant color sampling
- [X] Space Exploration — blocked tile/surface detection, item refund on rejection
- [X] Space Age — `plant` prototype support, `TREE_GROWTH_ENABLED` flag (growth disabled under SA)
- [?] TerrainEvolution2 — AB pollution decay pass hook
- [?] Winter Is Coming — `set_tiles` called with `raise_event=true` so WIC updates its tile snapshot
- [X] AAI Industry — adjusted tech prerequisite for Sapling Growth 1
- [X] `is_se_blocked_tile` / `is_se_blocked_surface` helpers

---

## 12. Settings (Runtime Global)

- [?] Tree growth speed (instant / fast / smooth)
- [?] Tree growth variability (0 / 25 / 50 / 75 / 100%)
- [?] Tree growth max active (hidden; managed by research)
- [?] Tree growth day-only toggle
- [?] Tree growth pollution delay toggle
- [?] Growing trees enrich soil toggle (hidden)
- [ ] Pellet delay (nights)
- [ ] Pellet delay variance (hidden)
- [ ] Pellet batch size
- [ ] Pellets night-only toggle
- [ ] Pellet overflow threshold
- [ ] Pellet overflow drain percent
- [ ] Pellet pollution rate (hidden)
- [ ] Pellet trample toggle
- [ ] Player trample radius (hidden)
- [ ] Randomise pellet upgrade paths toggle
- [?] Foreign tree sweep toggle
- [ ] Colored pellet chance 1-in-N (hidden)
- [?] Rain growth boost toggle (Dynamic Rain only)
- [?] Rain seed enabled toggle (Dynamic Rain only)
- [?] Rain seed debug toggle (Dynamic Rain only)
- [?] Restorative Rains enabled toggle (Dynamic Rain only)

---

## 13. Diagnostics & Debug

- [x] `/treez` — prints queue snapshots, handle_site counters, config state
- [x] `/treez reset` — clears debug counters
- [?] `/treez fix-sites` — converts stranded tree-seed-site entities
- [ ] `/treez force_nitrate` — immediately fires all queued pellets
- [?] `/treez test_rain` — simulates a rain chunk-cleared event at player position
- [?] `/treez test_wic` — verifies Winter Is Coming tile-change compatibility
- [?] `storage.dbg` counters — tracks handle_site call breakdown and on_built counts

---

## 14. Art

- [X] - Review individual art graphics for seeds
- [?] - Review individual art graphics for nitrates
- [x] - Review mapping between art graphics and how they are used

---
## Known Issues / Dead Code to Not Port

- `TREES_TO_RESEARCH = 10` at module level is shadowed by local `= 1` inside the handler — only the value `1` is ever used
- `soil-crystal-colored-probability` and `soil-crystal-colored-adjacent` research handlers exist but the technologies are not defined — those handlers never fire
- `storage.colored_adjacent_unlocked` is always `false`; the adjacent-tile improvement block in process_crystals can never execute
- The `rare` pellet field on queue entries is always `false`; the rare pellet mechanic was removed but scaffolding remains
- `dr_native_event_active` is set but its only consumer (the old polling block) is commented out
- `run_foreign_tree_ghost_sweep` prints to all players every day cycle even when nothing is found
