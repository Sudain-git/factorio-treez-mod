# Treez Rewrite — Project Guide for Claude

This file is read automatically at the start of every conversation. It keeps context consistent across sessions so we don't re-derive decisions we've already made.

---

## What This Mod Is

**Treez (Rewrite)** is a Factorio 2.0 mod focused on tree planting and biome-aware tree growth. Players plant tree seeds by hand or via the Tree Seeder area tool; construction robots fulfill the ghosts; seeds grow through animated stages into full trees.

**This mod does NOT include:**
- Nitrate / Soil Crystal terrain restoration (that is a separate mod)
- Restorative Rains nitrate placement (separate mod)
- Sapling Soil Enrichment tile upgrading (separate mod)
- Winter Is Coming integration (separate mod, undecided)
- TerrainEvolution2 integration (undecided)

For feature-level decisions see `TODO.md`. Items marked `[x]` are in scope. Items marked `[ ]` are out of scope. Items marked `[?]` are undecided — ask before implementing them.

---

## Mod File Architecture

The mod is split into focused files. Do not collapse these back into a monolith.

```
treez-rewrite/
  info.json
  data.lua              -- requires the sub-files below
  data-final-fixes.lua  -- requires the sub-files below
  control.lua           -- requires the sub-files below
  settings.lua

  data/
    tree-seed.lua       -- tree-seed item, recipe, tree-seed-site entity, treez-seed-waiting entity
    tree-seeder.lua     -- Tree Seeder selection-tool, shortcut, custom-input, technologies
    technologies.lua    -- Tree Growth + Sapling Growth tech chain

  control/
    seed.lua            -- handle_site(), plant_seed_at(), placement rejection helpers
    queue.lua           -- growth queue, process_growing_trees(), try_dequeue_tree()
    species.lua         -- pick_species_at(), build_native_species_map()
    seeder.lua          -- Tree Seeder GUI, on_lua_shortcut, on_player_selected_area
    sweep.lua           -- run_seed_ghost_collision_sweep(), run_foreign_tree_ghost_sweep()
    compat.lua          -- is_se_blocked_*, AB helpers, Space Age guards
    commands.lua        -- /treez diagnostic command

  graphics/
    (one file per graphic asset)
```

`control.lua` is the entry point — it requires each control/ sub-file. Sub-files register their own events and expose functions via a returned table or upvalue sharing. Do not use globals to share state between files; pass data through `storage` (the persisted table) or through explicit `require` return values.

---

## Efficiency Principles

These come from a detailed review of the base-game mod. Do not repeat these mistakes.

### Cache everything that doesn't change tick-to-tick

- **Settings:** Read `settings.global["..."].value` once at module load into a local variable. Update it in `on_runtime_mod_setting_changed`. Never read `settings.global` inside a tick handler or event that fires frequently (e.g. `on_player_changed_position`).
- **Research state:** Never loop through `force.technologies[...]` inside a tick handler. Cache as a plain integer or boolean in `storage`, updated only in `on_research_finished`.

```lua
-- BAD: called every 10 ticks for every growing tree
local function get_soil_enrichment_level()
  for i = 1, 6 do ... force.technologies["..."] ... end
end

-- GOOD: cached integer, invalidated on research
-- storage.soil_enrichment_level updated in on_research_finished
```

### Batch engine calls

Every `surface.find_entities_filtered`, `surface.find_tiles_filtered`, `surface.get_tile`, `surface.get_pollution` is a C++/Lua boundary crossing. Minimize them.

- When processing multiple items in a radius, fetch the whole area once and build a Lua table, then iterate the table.
- When searching for multiple entity names, pass `name = { name1, name2, name3 }` in one call, not one call per name.
- When iterating a queue, do not call the engine inside the loop unless the entity is actually being processed.

### Keep queues sorted or skip-able

The base-game crystal queue was a flat array scanned linearly every 60 ticks even when nothing was due. The growth queue will have the same problem at scale.

- The growth queue (seeds waiting to start growing) should support fast early-exit when the cap is full.
- The growing-trees list should be iterable in O(active count) with no wasted work.
- Consider a sorted or min-heap structure for any queue where entries have a `fire_at` time.

### Event filters everywhere

Every `script.on_event` registration that can take a filter table should have one. This reduces the number of Lua calls the engine makes per tick.

```lua
-- Always use filters on damage, mined, built events
script.on_event(defines.events.on_entity_damaged, handler, {
  { filter = "name", name = "tree-seed-site" },
})
```

### Single registration per event

Factorio silently replaces any prior handler when you call `script.on_event` for the same event twice. This was a real bug in the base-game. All logic for a given event must live in one handler — use internal if/elseif branching, not multiple registrations.

### Surface reference consistency

Always reference the main surface as `game.surfaces["nauvis"]`, not `game.surfaces[1]`. Store the result in a local variable if used more than once in a function.

---

## Entity Layer System

Every time we create, destroy, check, or interact with an entity, we must think through which layers are involved and what the engine does or does not handle automatically. This section is a reference for that reasoning.

---

### The Layers

Factorio entities exist across several independent layer systems simultaneously.

**Collision layers** — what the engine uses for placement and movement checks.
In Factorio 2.0 these are named (not bit flags):

| Layer name | What lives there |
|---|---|
| `object-layer` | Most buildings, trees, resources, our seed/crystal entities |
| `ghost-layer` | Entity ghosts only — invisible to `can_place_entity` |
| `player-layer` | Player character collision |
| `ground-tile` | The tile surface itself |
| `resource-layer` | Ore, oil, and other resource entities |
| `rail-layer` | Rails, signals, stops |
| `item-layer` | Items dropped on the ground |
| `transport-belt-layer` | Belts |
| `water-tile` | Water tiles (blocks most placement) |

An entity's `collision_mask` declares which layers it **occupies** and which it **blocks**. Two entities can coexist at the same position if their occupied layers do not conflict.

**Render layer** — purely visual ordering, independent of collision:
- `"object"` — most entities
- `"higher-object"` — renders above normal entities at the same position (seed-waiting marker uses this so it's visible on the ground)
- `"lower-object"`, `"floor"`, etc.

**Tile layer** — the ground itself. Separate from entities entirely. Modified by `surface.set_tiles()`. There is no tile ghost system — tile changes are immediate.

---

### The Critical Blind Spot: `can_place_entity` Does Not See Ghosts

`can_place_entity` checks collision against entities on the surface using their collision masks. Entity ghosts occupy `ghost-layer`, which normal building entities do not collide with. **A ghost at a position will not block `can_place_entity`.**

This means:
- You can `create_entity` on top of a ghost and the ghost is silently destroyed by the engine
- You must manually search for ghosts before placing if you want to respect them

```lua
-- ALWAYS check for ghosts explicitly before placing at a tile
local tx, ty = math.floor(pos.x), math.floor(pos.y)
if surface.find_entities_filtered{
  area = { {tx, ty}, {tx+1, ty+1} }, type = "entity-ghost"
}[1] then
  return  -- respect the player's intent
end
```

Use **area search** (tile bounding box), not **position + radius**. A radius search only matches entities whose **centre** is within the radius. A large multi-tile ghost centred two tiles away but covering this tile will pass a radius check and the real entity you place will silently destroy it.

---

### Area Search vs Radius Search — When to Use Each

| Use | Method | Catches |
|---|---|---|
| "Is there a ghost on this tile?" | `area = { {tx,ty}, {tx+1,ty+1} }` | Any ghost whose footprint overlaps |
| "Is there a resource at this point?" | `position = pos, radius = 0.5` | Fine — resources are point entities |
| "Is there anything blocking near here?" | area over the full footprint | Correct for multi-tile entities |
| Existence check (any result) | add `limit = 1` | Stops at first match — free speedup |

The rule: **use area when you care about footprint overlap; use radius when you care about proximity to a point.**

---

### Placement Method Comparison

Each placement method has a different event chain and different automatic side effects.

| Method | `on_built_entity` | `on_robot_built_entity` | `script_raised_built` | Removes ghost? | Items consumed? |
|---|---|---|---|---|---|
| Player hand-places item | ✓ | — | — | Yes (engine) | Yes (from inventory) |
| Robot fulfils ghost | — | ✓ | — | Yes (engine) | Yes (from robot cargo) |
| `create_entity` with `raise_built=true` | — | — | ✓ | **No** | **No** |
| `create_entity` with `raise_built=false` | — | — | — | **No** | **No** |
| `entity.revive()` with `raise_revive=true` | — | — | ✓ (revive) | Yes (it IS the ghost) | **No** |

Key implications:
- `create_entity` **never** automatically removes a ghost at the same position. If you place a real entity on top of a ghost via script, the engine destroys the ghost silently to resolve the collision — but only if their collision masks conflict. If they don't conflict, both coexist.
- Robots fulfilling ghosts always goes through `on_robot_built_entity`, never `on_built_entity`. These must be handled separately (or in a shared function called by both).
- Some mods revive ghosts via `entity.revive()` instead of using a robot. This fires neither `on_built_entity` nor `on_robot_built_entity`. Register a `script_raised_revive` handler for these cases.

---

### Destruction Method Comparison

| Method | `on_entity_destroyed` fires? | Items dropped? | Player notified? |
|---|---|---|---|
| `entity.destroy({ raise_destroy=false })` | **No** | **No** | **No** |
| `entity.destroy({ raise_destroy=true })` | Yes | **No** | No |
| Player mines entity | Yes (via `on_player_mined_entity`) | Yes → player inventory | Yes |
| Robot deconstructs | Yes (via `on_robot_mined_entity`) | Yes → logistics | No |

Use `raise_destroy = false` for all internal cleanup (removing growth-stage entities during advancement, removing markers). This is silent, fast, and does not cascade into other mods' handlers.

---

### Ghost Lifecycle — Full Chain

Understanding this prevents bugs in the robot-fulfillment path.

```
Player uses Tree Seeder area tool
  → create_entity({ name = "entity-ghost", inner_name = "tree-seed-site" })
  → on_built_entity fires (entity.type == "entity-ghost")

Robot picks up tree-seed item from logistics chest
  → Robot flies to ghost position
  → Engine removes ghost, places tree-seed-site
  → on_robot_built_entity fires (entity.name == "tree-seed-site")
  → handle_site() runs
    → tree-seed-site entity is destroyed (raise_destroy=false)
    → growth-stage-1 entity created (raise_built=false) OR waiting marker created
```

If we call `create_entity` ourselves (e.g. during `fix-sites` recovery), use `raise_built=true` so the `script_raised_built` handler routes it through `handle_site()` — the same path as a normal robot fulfillment.

---

### Blueprint & Deconstruction Chain

**Blueprint capture** (`on_player_setup_blueprint`):
- Entities with `"not-blueprintable"` flag are excluded automatically — growth stage entities must have this
- Entities with `"player-creation"` flag ARE captured — seed-sites are `player-creation` so they blueprint correctly
- `treez-seed-waiting` has `"not-blueprintable"` but we also handle `on_player_setup_blueprint` to rewrite any that slip through

**Deconstruction planner** (`on_marked_for_deconstruction`):
- Only targets entities with `"player-creation"` flag
- Growth stage entities should NOT have this flag (they are internal, not player-placed)
- Seed-waiting markers DO have `"player-creation"` so the player can deconstruct them to cancel a queued seed
- When a waiting marker is deconstructed, `on_robot_mined_entity` fires — we must cancel the matching growth queue entry there

**Force-build** (shift-click):
- `on_pre_build` fires with `event.shift_build = true`
- Player-creation entities in the way are NOT automatically removed — the engine blocks the placement
- We compensate in `on_pre_build` by manually marking seed-sites for deconstruction so the player's build proceeds

---

### Entity Flags That Matter for This Mod

| Flag | Effect | Used on |
|---|---|---|
| `"placeable-neutral"` | Can be placed by any force | All our entities |
| `"player-creation"` | Blueprintable, selectable by deconstruction planner | seed-site, seed-waiting |
| `"not-blueprintable"` | Excluded from blueprint capture | seed-waiting, growth stages |
| `"not-on-map"` | Hidden from the map overlay | seed-waiting |
| `"not-repairable"` | Repair packs don't work on it | seed-waiting |
| `"not-upgradable"` | Upgrade planner ignores it | seed-waiting |
| `"hidden"` | Entity exists but is not shown in menus/filters | growth stage entities |

---

### Checklist: Before Writing Any Entity Interaction

Ask these questions before writing code that places, removes, or checks entities:

1. **Which collision layers does this entity occupy?** Will `can_place_entity` see it?
2. **Could a ghost be at this position?** If yes, search by area, not radius.
3. **What placement method am I using?** Does it raise events? Does it remove ghosts?
4. **What destruction method am I using?** Do I want items dropped? Events raised?
5. **Does the order matter?** Destroy the old entity BEFORE checking `can_place_entity` for the replacement.
6. **Could a robot or script-revive path reach this code?** If yes, handle `on_robot_built_entity` and `script_raised_revive` as well as `on_built_entity`.
7. **Should this entity be blueprintable / deconstructable?** Set flags accordingly.
8. **Am I raising `set_tiles` with `raise_event = true`?** Required for WIC compatibility.

---

## Factorio 2.0 API Conventions

- `storage` is the persisted table (was `global` in Factorio 1.x). Always use `storage`.
- `prototypes` is the runtime prototype table (was `game.entity_prototypes` etc. in 1.x).
- `script.on_init` → new game only. `script.on_load` → every game load (re-register events, restore upvalues). `script.on_configuration_changed` → mod version change or mod list change (migrate storage).
- `data.raw` is only available in the data stage. Never reference it from `control.lua`.
- The `mods` table is available in the data stage. Use `script.active_mods` in the control stage.
- `plant` prototype type exists in Factorio 2.0 base engine. Gate Space Age features on `mods["space-age"]`, not on `data.raw.plant`.
- `raise_built = true` / `raise_destroy = false` on `create_entity` / `destroy` — be intentional. Raising events has performance cost and can trigger cascades.

---

## Code Style

- No comments explaining what the code does. Comments only for non-obvious WHY: hidden constraints, workarounds, subtle invariants.
- No docstrings or multi-line comment blocks.
- Local variables over repeated table lookups: `local surface = entity.surface` at the top of a function, not `entity.surface.X` repeated.
- Snake_case for variables and functions. SCREAMING_SNAKE for module-level constants that never change.
- Guard clauses at the top of functions (`if not x then return end`) rather than deeply nested if/else.
- Prefer explicit `return` over falling off the end of a function that has multiple exit paths.
- Do not add error handling for things that cannot happen. Trust Factorio's guarantees about valid entities in event handlers that have appropriate filters.

---

## Lua Safety Rules

These are Lua-specific bugs that have no compiler warning and fail silently or at runtime far from the source.

### Always use `local`
Variables without `local` are global by default. Globals persist across function calls and bleed between files. No exceptions — every variable gets `local`.

### `or` defaults break on `false`
`local x = y or default` returns `default` when `y` is `false`, not just when `y` is `nil`. For booleans and settings, use an explicit nil check:
```lua
-- WRONG: returns true even when the setting is legitimately false
local day_only = settings.global["treez-tree-growth-day-only"].value or true

-- CORRECT
local day_only = settings.global["treez-tree-growth-day-only"].value
if day_only == nil then day_only = true end
```

### Variable shadowing is silent
Lua does not warn when a local shadows an outer local. Use distinct names — never reuse a name from an outer scope for a different value. The base-game had a module-level constant silently dead for the entire mod's life because of this.

### `#` is undefined on tables with holes
`#t` only gives a reliable answer when the table is a contiguous sequence. Deleting from the middle with `t[i] = nil` creates a hole and makes `#t` undefined. Always use swap-remove:
```lua
t[i] = t[#t]
t[#t] = nil
```

### Never mutate a table while iterating it with `pairs`
Adding or removing keys during `pairs` may skip entries or visit them twice. Collect removals first, then remove. For arrays, iterate backwards with a numeric `for` loop.

### `table.sort` requires strict less-than, never less-than-or-equal
Using `<=` in a sort comparator violates Lua's strict weak ordering requirement and causes an "invalid order function" crash at runtime. Always use `<` only.

### Tables are references, not copies
`local b = a` where `a` is a table gives `b` a reference to the same table. Use `table.deepcopy(a)` when you need an independent copy. This is critical in `data-final-fixes.lua` when cloning tree prototypes for growth stages.

### Closures capture the variable, not the value
A closure defined inside a loop captures the loop variable itself. Shadow it with a local inside the loop body when you need to capture the current value.

### Empty table check: use `next()`, not `#`
`#t == 0` is unreliable for non-sequence tables. The correct general check is `next(t) == nil`.

### `pcall` around every `remote.call`
A remote interface from another mod may not exist or may error. A bare `remote.call` that fails crashes the entire mod:
```lua
local ok, result = pcall(remote.call, "dynamic-rain", "get_events")
if not ok then
  log("[treez] remote call failed: " .. tostring(result))
  return
end
```

### String patterns are not regex
Lua uses its own pattern syntax. Escape literal dots and special characters with `%`. The `-` quantifier is lazy (not greedy like `*`). `%d` = digit, `%a` = letter, `%s` = whitespace.

### String concatenation in loops is expensive
Each `..` allocates a new string. Use `table.concat(parts)` to build strings from arrays.

---

## Factorio-Specific Nuances

Rules and surprises specific to Factorio's modding environment.

### Data stage vs Control stage — hard boundary
| | Data stage | Control stage |
|---|---|---|
| Files | `data.lua`, `data-updates.lua`, `data-final-fixes.lua`, `settings.lua` | `control.lua` and required files |
| Mod list | `mods["name"]` | `script.active_mods["name"]` |
| Prototypes | `data.raw["type"]["name"]` | `prototypes.entity["name"]` etc. |
| Game object | not available | `game`, `storage`, `script`, `defines` |
| When it runs | once at startup, before any game loads | during gameplay |

Never reference `data.raw` from `control.lua`. Never reference `game` from `data.lua`.

### The three lifecycle hooks — get these right every time

```lua
script.on_init(function()
  -- NEW GAME ONLY. Initialize storage fields here.
  storage.growth_queue = {}
  storage.growing_tree_count = 0
end)

script.on_load(function()
  -- EVERY GAME LOAD (including new game, after on_init).
  -- Re-register dynamic event IDs (e.g. from remote interfaces).
  -- Do NOT read or write storage here — it hasn't been migrated yet.
  dr_native_event_active = setup_rain_event_listener()
end)

script.on_configuration_changed(function()
  -- MOD VERSION CHANGE or mod list change.
  -- Migrate storage fields here. Add missing fields, remove obsolete ones.
  if not storage.growth_queue then storage.growth_queue = {} end
end)
```

A common mistake: putting `storage` initialization in `on_load` instead of `on_init`. `on_load` runs before migration so stale data can corrupt new fields.

### Dynamic event IDs must be registered in BOTH `on_init` and `on_load`

Event IDs from other mods (via `remote.call`) are not persisted. If you register them only in `on_init`, they disappear after the first save/load cycle:
```lua
local function setup_rain_listener()
  -- call this from BOTH on_init and on_load
end
script.on_init(function() setup_rain_listener() end)
script.on_load(function() setup_rain_listener() end)
```

### `script.on_event` silently replaces prior handlers

Calling `script.on_event` for the same event ID twice makes the second call replace the first — no error, no warning. All logic for a given event must be in one handler with internal branching.

### `entity.valid` — check before every use

Entities can be invalidated between the moment an event fires and when your handler accesses them (another mod, or your own earlier code in the same handler, may have destroyed it). Always guard:
```lua
if not entity.valid then return end
```
This is especially important in growth-stage advancement where the entity is destroyed and replaced in the same tick.

### Destroy the occupant before placing a replacement

When swapping entities at the same position (e.g. seed marker → stage-1 growth entity), the old entity must be destroyed before `can_place_entity` or `create_entity` is called. The old entity's collision box blocks placement even though you're about to remove it. The base-game documented this explicitly — do not skip the destroy-first step.

### `can_place_entity` does not see the ghost layer

`surface.can_place_entity` checks collision layers but ignores entity ghosts. A ghost sitting on the target tile will pass this check, and then `create_entity` will silently destroy the ghost to place the real entity. Always explicitly search for ghosts before placing:
```lua
if surface.find_entities_filtered{
  area = { {tx, ty}, {tx+1, ty+1} }, type = "entity-ghost"
}[1] then return end
```
Use an `area` search (the tile's bounding box), not `position + radius` — a multi-tile ghost centred elsewhere but covering the tile will slip through a radius check.

### `storage` cannot hold functions or closures

Only serializable values go in `storage`: numbers, strings, booleans, tables of the above, and Factorio LuaObject references (entities, forces, surfaces, etc.). Functions and closures are silently dropped or cause errors. Never put a function in `storage`.

### `raise_built` and `raise_destroy` — be explicit and intentional

- `raise_built = true` on `create_entity` → fires `on_built_entity` and `script_raised_built` for all mods including your own. Use for entities the player or system "officially" places.
- `raise_built = false` → silent placement. Use for internal entities like growth-stage prototypes where you don't want to re-trigger your own `on_built_entity` handler.
- `raise_destroy = false` on `entity.destroy()` → silent removal. Almost always what you want for internal cleanup to avoid cascades.

### `surface.set_tiles` — always pass `raise_event = true`

The third argument controls whether `script_raised_set_tiles` fires. Winter Is Coming and similar mods watch this event to update their tile snapshots. If you omit it or pass `false`, those mods see a stale world:
```lua
surface.set_tiles({{ name = target, position = pos }}, nil, true)
--                                                          ^^^^
```

### `on_nth_tick` instead of `on_tick` with modulo

```lua
-- WRONG: on_tick fires every tick; the modulo is cheap but the Lua call isn't
script.on_event(defines.events.on_tick, function(e)
  if e.tick % 60 == 0 then process() end
end)

-- CORRECT: engine only calls Lua every 60th tick
script.on_nth_tick(60, function() process() end)
```

`on_nth_tick` registrations are not persisted — re-register them in `on_load`.

### `find_entities_filtered` with `limit = 1` for existence checks

When you only need to know if at least one entity exists (not how many), pass `limit = 1`. The engine stops searching after the first match:
```lua
-- WRONG: fetches every ghost on the surface
local ghosts = surface.find_entities_filtered{ type = "entity-ghost" }
if #ghosts > 0 then ...

-- CORRECT: stops at first match
if surface.find_entities_filtered{ type = "entity-ghost", limit = 1 }[1] then ...
```

### Quality level guard (Space Age)

`entity.quality` is nil in base game (no Space Age). Always guard:
```lua
local ql = (entity.quality and entity.quality.level) or 0
```

### Technology `effects` must be an explicit empty table, not omitted

Technologies that grant no engine-handled effects (their logic is in `on_research_finished`) still need `effects = {}`. Omitting the field entirely can cause errors in some mod environments:
```lua
data:extend({{ type = "technology", name = "treez-...", effects = {}, ... }})
```

### `table.deepcopy` before mutating any prototype

When generating growth-stage prototypes in `data-final-fixes.lua`, always deepcopy the source prototype before modifying it. Mutating `data.raw[type][name]` directly changes the prototype for every subsequent reader:
```lua
local proto = table.deepcopy(data.raw.tree["tree-01"])
-- now safe to modify proto.name, proto.collision_box, etc.
```

### Multiplayer: `math.random` is synchronized, GUIs are per-player

- `math.random` is seeded and synchronized across all clients automatically — do not seed it yourself.
- GUI elements on `player.gui.screen` are per-player and only visible to that player. Never assume one player's GUI state applies to another.
- Use `game.connected_players` (not `game.players`) when you need to print to online players only.

---

## Development Philosophy

### Small, provable iterations

Every implementation step should produce something testable before the next step begins. Do not wire up three systems at once and then debug why nothing works.

Concrete rules:
- The mod must load without error at every commit. A commit that crashes on load is not a valid stopping point.
- Before implementing a feature, state out loud what "done and verifiable" looks like. If we can't define it, we're not ready to start.
- Implement one function or one entity at a time. Verify it loads and behaves correctly. Then proceed.
- Data-stage first: define the item/entity/technology, confirm the game loads, then write the control-stage handler.
- Do not start the next layer until the current one is confirmed working.

What "verified" means at each layer:
- **Data stage:** game loads without error; entity/item appears in the game under the right conditions
- **Control stage:** event fires (add a `log()` call to confirm); storage fields are set correctly; `/treez` diagnostic shows expected state
- **Full feature:** the golden path works in-game; edge cases (robot path, script-revive path, SE-blocked surface) are tested one by one

### Debugging approach

- Use `log("[treez] ...")` to confirm code paths during development. Remove all debug `log()` calls before committing.
- Use `/treez` diagnostic command to inspect queue state, growing tree count, and counters without opening the save file.
- When something is broken, identify the layer first (data stage? control stage? wrong event? wrong entity name?) before changing code.
- If a bug is non-obvious, write it in `LESSONS.md` before fixing it. The fix is less valuable than the rule that prevents it recurring.

---

## Working Together Across Sessions

**At the start of every session:**
1. Read `LESSONS.md` — know what mistakes have already been made.
2. Read `TODO.md` — confirm what is in scope for today.
3. Check `## In Progress` at the bottom of this file — pick up any half-finished work.
4. If a feature is marked `[?]` in `TODO.md`, ask before implementing it.

**When implementing:**
- One feature or file at a time. Do not refactor adjacent code unless it directly blocks the task.
- Write the data-stage definition first, verify it loads, then write the control-stage handler.
- Run through the Entity Layer Checklist before writing any entity placement or destruction code.
- If there is a trade-off between efficiency and design, stop and ask rather than choosing silently.

**When a mistake is made:**
- Add an entry to `LESSONS.md` immediately, before fixing the code.
- If the lesson is general enough to always apply, also add it to the relevant section of this file.
- Then fix the code.

**When a session ends:**
- Commit everything that is in a working (loads without error) state.
- If something is left half-done, note it in `## In Progress` below.
- If a `log()` debugging call was added, remove it before committing.

---

## Reference: Base-Game Mod Location

The fully-working reference implementation lives at:
`../treez-base-game_1.16.40/treez-base-game_1.16.40/`

When in doubt about how something worked in the original, read that code. Do not copy-paste from it — rewrite with the efficiency principles above applied.

---

## In Progress

_(Add notes here when a session ends mid-task so the next session can pick up cleanly.)_

- Nothing in progress yet. Starting from scratch.
