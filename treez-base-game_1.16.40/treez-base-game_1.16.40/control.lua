-- control.lua  (v1.15.61)

local DEFAULT_SEED_DENSITY    = 90
local DEFAULT_CRYSTAL_DENSITY = 100

local SEEDER_NAME       = "tree-seeder"
local SEEDER_GUI        = "tree-seeder-gui"
local SITE_NAME         = "tree-seed-site"

local PLACER_NAME       = "crystal-placer"
local PLACER_GUI        = "crystal-placer-gui"
local CRYSTAL_SITE_NAME             = "soil-crystal-site"
local CRYSTAL_COLORED_SITE_NAME     = "soil-crystal-colored-site"
local CRYSTAL_BLACK_SITE_NAME       = "soil-crystal-black-site"

-- All entity names this mod places — used wherever all crystal types must be
-- found or destroyed (trample scans, tile cleanup, etc.).
local CRYSTAL_NAMES = {
  CRYSTAL_SITE_NAME,
  CRYSTAL_COLORED_SITE_NAME,
  CRYSTAL_BLACK_SITE_NAME,
}

-- Event filter covering all entity names (on_entity_damaged, on_player_mined_entity).
local CRYSTAL_EVENT_FILTERS = {
  { filter = "name", name = CRYSTAL_SITE_NAME },
  { filter = "name", name = CRYSTAL_COLORED_SITE_NAME, mode = "or" },
  { filter = "name", name = CRYSTAL_BLACK_SITE_NAME,   mode = "or" },
}

local CRYSTAL_CHECK_INTERVAL = 60
local GROWTH_CHECK_INTERVAL  = 10
-- Pollution from queued pellets is emitted on its own, coarser cadence so the
-- (potentially large) queue is only walked once every POLLUTION_EMIT_INTERVAL
-- ticks instead of every CRYSTAL_CHECK_INTERVAL.  The per-pellet amount scales
-- with this interval, so total pollution per minute is unchanged.
local POLLUTION_EMIT_INTERVAL = 600

-- Waiting-seed marker entity name.
local SEED_WAITING_NAME = "treez-seed-waiting"

local AB_INSTALLED = script.active_mods["alien-biomes"] ~= nil

-- Tree Growth research: completed when a force has cut this many natural trees.
local TREE_GROWTH_TECH    = "treez-tree-growth"
local TREES_TO_RESEARCH   = 10

-- Weighted-random species pick from a list of tree entities.
-- Each valid species is counted; probability is proportional to that count.
-- e.g. 3 oak + 1 elm → 75% oak, 25% elm.  Returns nil if no valid species.
-- Builds a tile-name → {species-name = true} lookup so we know which tree
-- species are native to each tile type.  Called at init and config-change.
-- Uses tile_buildability_rules on each tree prototype, which is where AB
-- stores its tile-restriction data at runtime.  Degrades gracefully to an
-- empty map if the field is absent (all species then share equal weight).
local function build_native_species_map()
  storage.native_species = {}
  if not AB_INSTALLED then return end
  for name, proto in pairs(prototypes.entity) do
    if proto.type == "tree" then
      local rules = proto.tile_buildability_rules
      if rules then
        for _, rule in pairs(rules) do
          local tile = rule.target_tile
          local tile_name = tile and (type(tile) == "string" and tile or tile.name)
          if tile_name then
            storage.native_species[tile_name] = storage.native_species[tile_name] or {}
            storage.native_species[tile_name][name] = true
          end
        end
      end
    end
  end
end

-- Determines which tree species to plant at the given position.
--
-- Samples trees within 10 tiles and applies two weight factors:
--   Count weight — proportional to how many trees of each species are nearby.
--   Biome weight — native species (per tile_buildability_rules) get ×3;
--                  non-native / invasive species get ×1.
--
-- When no trees are found within 10 tiles (cleared land), falls back to the
-- tile's native species list directly rather than always returning tree-01.
-- This ensures reforesting cleared AB land still picks a biome-appropriate
-- species.  Only returns TREE_ENTITY on vanilla/unmapped tiles where
-- native_set is empty.
--
-- Sparse/dead-looking trees (names containing "dead" or starting with "dry")
-- are re-rolled once to reduce their selection frequency without eliminating
-- them from biomes where they genuinely dominate.
local function pick_species_at(surface, position)
  if not AB_INSTALLED then return TREE_ENTITY end

  local tile_name  = surface.get_tile(position).name
  local native_set = (storage.native_species or {})[tile_name] or {}

  local entities = surface.find_entities_filtered{
    type = "tree", position = position, radius = 10, limit = 60,
  }

  local counts = {}
  local total  = 0
  for _, tree in pairs(entities) do
    local name = tree.name
    if not name:find("^treez%-") then
      if prototypes.entity["treez-" .. name .. "-stage-1"] then
        local w = native_set[name] and 3 or 1
        counts[name] = (counts[name] or 0) + w
        total = total + w
      end
    end
  end

  -- No nearby reference trees: use the tile's native species list directly so
  -- cleared AB land still gets a biome-appropriate species, not tree-01.
  if total == 0 then
    local native_list = {}
    for name in pairs(native_set) do
      if prototypes.entity["treez-" .. name .. "-stage-1"] then
        native_list[#native_list + 1] = name
      end
    end
    if #native_list > 0 then
      return native_list[math.random(#native_list)]
    end
    return TREE_ENTITY  -- vanilla / unmapped tile; no biome data available
  end

  -- One weighted random draw from the counts table.
  local function one_pick()
    local roll = math.random() * total
    local acc  = 0
    for name, count in pairs(counts) do
      acc = acc + count
      if roll < acc then return name end
    end
    for name in pairs(counts) do return name end
  end

  local result = one_pick()

  -- Re-roll once for sparse/dead-looking trees.  Catches all five vanilla
  -- dead trees that AB re-enables:
  --   dead-grey-trunk, dead-dry-hairy-tree, dead-tree-desert  ("dead")
  --   dry-hairy-tree, dry-tree                                ("^dry")
  -- Accept the second result even if it is also sparse — avoids infinite
  -- loops and preserves correct behaviour in all-dead biomes.
  if result and (result:find("dead") or result:find("^dry")) then
    result = one_pick()
  end

  return result or TREE_ENTITY
end

-- Destroys any waiting-seed marker entities at or within a hair of the given
-- position.  Called whenever a growth-stage or final tree entity is placed so
-- that stale markers are always cleaned up regardless of how they got there —
-- this decouples marker lifetime from queue-entry lifetime entirely.
local function cleanup_marker_at(surface, position)
  local nearby = surface.find_entities_filtered{
    name     = SEED_WAITING_NAME,
    position = position,
    radius   = 0.2,
  }
  for _, m in pairs(nearby) do
    if m.valid then m.destroy({ raise_destroy = false }) end
  end
end

-- Removes the growth-queue entry whose position matches the given coordinates.
-- Called when a waiting-seed marker is mined or deconstructed so the queued
-- growth attempt is cancelled along with the visual marker.
local function remove_from_growth_queue(surface, position)
  for i = #storage.growth_queue, 1, -1 do
    local e = storage.growth_queue[i]
    if e.surface_index == surface.index
      and math.abs(e.position.x - position.x) < 0.5
      and math.abs(e.position.y - position.y) < 0.5 then
      table.remove(storage.growth_queue, i)
      return
    end
  end
end

-- Must match MAX_GROWTH_STAGES in data-final-fixes.lua.
local MAX_GROWTH_STAGES = 200

local HARD_TILE_THRESHOLD = 1.3

local TREE_GROWTH_ENABLED = not script.active_mods["space-age"]
local DYNAMIC_RAIN_ACTIVE = script.active_mods["dynamic-rain"] ~= nil

-- ── Growth speed presets ──────────────────────────────────────────────────────
local GROWTH_PRESETS = {
  instant = { stages = 0,   ticks = 0,   bypass = true  },
  fast    = { stages = 200, ticks = 18,   bypass = false },
  smooth  = { stages = 200, ticks = 180,  bypass = false },
}

local VARIABILITY_MAP = { ["0"] = 0.0, ["25"] = 0.25, ["50"] = 0.50, ["75"] = 0.75, ["100"] = 1.0 }

local crystal_delay_nights    = settings.global["treez-crystal-delay-nights"].value
local crystal_variance_nights = settings.global["treez-crystal-variance-nights"].value
local crystal_batch_size = settings.global["treez-crystal-batch-size"].value
local crystal_night_only = settings.global["treez-crystal-night-only"].value
local crystal_overflow_threshold = settings.global["treez-crystal-overflow-threshold"].value
local crystal_overflow_percent   = settings.global["treez-crystal-overflow-percent"].value

local crystal_colored_chance          = settings.global["treez-crystal-colored-chance"].value
local crystal_trample                 = settings.global["treez-fertilizer-trample"].value
local crystal_trample_player_radius   = settings.global["treez-trample-player-radius"].value

-- Returns the quality level (0–4) of an entity. Guards against base-game
-- (no Space Age) where entity.quality may be nil.
local function quality_level(entity)
  return (entity.quality and entity.quality.level) or 0
end
local randomize_upgrades         = settings.global["treez-randomize-upgrades"].value
local foreign_tree_sweep_enabled = settings.global["treez-foreign-tree-sweep"].value
local crystal_pollution_rate     = settings.global["treez-crystal-pollution-rate"].value

local tree_growth_max_active       = TREE_GROWTH_ENABLED and settings.global["treez-tree-growth-max-active"].value  or 500
local tree_growth_day_only         = TREE_GROWTH_ENABLED and settings.global["treez-tree-growth-day-only"].value    or true
local tree_growth_pollution_delay  = TREE_GROWTH_ENABLED and settings.global["treez-tree-growth-pollution-delay"].value or false
local tree_growth_enrich_soil      = TREE_GROWTH_ENABLED and settings.global["treez-tree-growth-enrich-soil"].value    or false
local tree_growth_variability = TREE_GROWTH_ENABLED
  and (VARIABILITY_MAP[settings.global["treez-tree-growth-variability"].value] or 0.0)
  or  0.0
local tree_rain_growth_boost = DYNAMIC_RAIN_ACTIVE and settings.global["treez-rain-growth-boost"].value or false
local rain_seed_enabled      = DYNAMIC_RAIN_ACTIVE and settings.global["treez-rain-seed-enabled"].value   or false
local rain_seed_debug        = DYNAMIC_RAIN_ACTIVE and settings.global["treez-rain-seed-debug"].value     or false
-- Set to true when dynamic-rain exposes on_chunk_pollution_cleared and we
-- successfully register a handler.  When true, rain_seeding_tick skips all
-- chunk polling — the native event drives everything instead.
local dr_native_event_active = false

local tree_growth_stages = 200
local tree_growth_ticks  = 18
local tree_growth_bypass = false

local function apply_growth_preset(speed)
  local preset = GROWTH_PRESETS[speed] or GROWTH_PRESETS.fast
  tree_growth_stages = preset.stages
  tree_growth_ticks  = preset.ticks
  tree_growth_bypass = preset.bypass
end

if TREE_GROWTH_ENABLED then
  apply_growth_preset(settings.global["treez-tree-growth-speed"].value)
end

local ref_item    = prototypes.item["tree-entity-ref"]
local TREE_ENTITY = ref_item and ref_item.order ~= "" and ref_item.order
if not TREE_ENTITY then
  -- Fallback: tree-entity-ref missing or empty (data-stage issue).
  -- Try to find a suitable base tree directly.
  if prototypes.entity["tree-01"] then
    TREE_ENTITY = "tree-01"
    log("[treez] WARNING: tree-entity-ref missing; falling back to tree-01.")
  else
    log("[treez] ERROR: tree-entity-ref missing and tree-01 not found. Tree growth disabled.")
  end
end

-- ============================================================
-- Vanilla tile upgrade table
-- ============================================================
local VANILLA_UPGRADE = {
  ["nuclear-ground"] = "sand-1",
  ["sand-1"]         = "red-desert-3",
  ["sand-2"]         = "red-desert-3",
  ["sand-3"]         = "red-desert-3",
  ["red-desert-3"]   = "red-desert-2",
  ["red-desert-2"]   = "red-desert-1",
  ["red-desert-1"]   = "red-desert-0",
  ["red-desert-0"]   = "dry-dirt",
  ["dry-dirt"]       = "dirt-7",
  ["dirt-7"]         = "grass-4",
  ["dirt-6"]         = "dirt-7",
  ["dirt-5"]         = "dirt-6",
  ["dirt-4"]         = "dirt-5",
  ["dirt-3"]         = "dirt-4",
  ["dirt-2"]         = "dirt-3",
  ["dirt-1"]         = "dirt-2",
  ["grass-4"]        = "grass-3",
  ["grass-3"]        = "grass-2",
  ["grass-2"]        = "grass-1",
  ["landfill"]       = "dry-dirt",
}

-- ============================================================
-- Tile rank cache — built once from VANILLA_UPGRADE at module load,
-- then extended with AB data whenever build_ab_tile_tables() runs.
-- tile_rank() does a single O(1) lookup into this table instead of
-- rebuilding it from scratch on every call (which was O(chain) per call,
-- called hundreds of times per process_crystals tick).
-- ============================================================
local TILE_RANK_CACHE = {}
do
  -- Seed vanilla ranks: walk the upgrade chain from the lowest tile.
  -- Tiles not in the chain default to 0 (treated as lowest quality).
  local r = 0
  local n = "nuclear-ground"
  while n do
    TILE_RANK_CACHE[n] = r
    r = r + 1
    n = VANILLA_UPGRADE[n]
  end
end

-- Called at the end of build_ab_tile_tables() to fold AB ranks into the
-- cache.  Must be called after storage.ab_upgrade_within is populated.
local function rebuild_tile_rank_cache()
  -- Reset to vanilla baseline first.
  local r = 0
  local n = "nuclear-ground"
  while n do
    TILE_RANK_CACHE[n] = r
    r = r + 1
    n = VANILLA_UPGRADE[n]
  end
  -- Walk ab_upgrade_within chains to assign relative ranks.  Because the
  -- AB chain can be multi-step (sand-1 → dirt-1 → dirt-2 … → grass-1),
  -- we do multiple passes until no new ranks are assigned.
  if storage and storage.ab_upgrade_within then
    local changed = true
    while changed do
      changed = false
      for from, to in pairs(storage.ab_upgrade_within) do
        local from_r = TILE_RANK_CACHE[from] or 0
        local to_r   = TILE_RANK_CACHE[to]
        -- A tile's rank should be at least one above any of its predecessors.
        if to_r == nil or to_r <= from_r then
          TILE_RANK_CACHE[to] = from_r + 1
          changed = true
        end
        -- Ensure the "from" tile has at least a base rank.
        if not TILE_RANK_CACHE[from] then
          TILE_RANK_CACHE[from] = 0
          changed = true
        end
      end
    end
  end
end

-- ============================================================
-- Feature 2: Space Exploration scaffold / asteroid blocking
-- ============================================================
local SE_BLOCKED_TILES = {
  ["se-space-platform-scaffold"]   = true,
  ["se-space-platform-plating"]    = true,
  ["se-space-platform-scaffold-2"] = true,
  ["se-spaceship-floor"]           = true,
  ["se-spaceship-floor-1"]         = true,
  ["se-spaceship-floor-2"]         = true,
  ["se-spaceship-floor-3"]         = true,
  ["se-spaceship-wall"]            = true,
}

local function is_se_blocked_tile(tile_name)
  if not script.active_mods["space-exploration"] then return false end
  return SE_BLOCKED_TILES[tile_name] == true
end

local function is_se_blocked_surface(surface)
  if not script.active_mods["space-exploration"] then return false end
  local n = surface.name
  return n:find("^se%-") ~= nil and
         (n:find("asteroid") ~= nil or n:match("^se%-%d+$") ~= nil)
end

local function is_se_blocked(surface, position)
  if is_se_blocked_surface(surface) then return true end
  return position ~= nil and is_se_blocked_tile(surface.get_tile(position).name)
end

local function reject_if_se_blocked(entity, item_name, player, robot)
  if not entity.valid then return false end
  if not is_se_blocked(entity.surface, entity.position) then return false end
  local pos = entity.position
  entity.destroy({ raise_destroy = false })
  if player then
    player.insert({ name = item_name, count = 1 })
    player.create_local_flying_text({ text = { "treez.blocked-scaffolding" }, position = pos })
  elseif robot then
    local inv = robot.get_inventory(defines.inventory.robot_cargo)
    if inv then inv.insert({ name = item_name, count = 1 }) end
  end
  return true
end

-- Returns true and refunds the item if the entity was placed on top of a
-- natural resource entity (ore, oil, stone, uranium, etc.).
-- Seeds planted on resource patches would obscure deposits and block mining.
local function reject_if_on_resource(entity, item_name, player, robot)
  if not entity.valid then return false end
  local resources = entity.surface.find_entities_filtered{
    position = entity.position,
    radius   = 0.5,
    type     = "resource",
  }
  if not resources[1] then return false end
  local pos = entity.position
  entity.destroy({ raise_destroy = false })
  if player then
    player.insert({ name = item_name, count = 1 })
    player.create_local_flying_text({ text = { "treez.blocked-resource" }, position = pos })
  elseif robot then
    local inv = robot.get_inventory(defines.inventory.robot_cargo)
    if inv then inv.insert({ name = item_name, count = 1 }) end
  end
  return true
end

-- ============================================================
-- Alien Biomes tile utilities
-- ============================================================

local function parse_ab_tile(name)
  local color, num
  color, num = name:match("^vegetation%-(%a+)%-grass%-(%d+)$")
  if color then return "vegetation", color, "grass", tonumber(num) end
  color, num = name:match("^mineral%-(%a+)%-dirt%-(%d+)$")
  if color then return "mineral", color, "dirt", tonumber(num) end
  color, num = name:match("^mineral%-(%a+)%-sand%-(%d+)$")
  if color then return "mineral", color, "sand", tonumber(num) end
  num = name:match("^frozen%-snow%-(%d+)$")
  if num then return "frozen", nil, "snow", tonumber(num) end
  color, num = name:match("^volcanic%-(%a+)%-heat%-(%d+)$")
  if color then return "volcanic", color, "heat", tonumber(num) end
  return nil
end

local COLOR_SAMPLE_RADIUS = 6
local function dominant_color_near(surface, position, target_group, default_color)
  local tilelist = storage.ab_tilelists_by_group
    and storage.ab_tilelists_by_group[target_group]
  if not tilelist or #tilelist == 0 then return default_color end
  local nearby = surface.find_tiles_filtered{
    position = position, radius = COLOR_SAMPLE_RADIUS, name = tilelist,
  }
  local counts = {}
  for _, tile in pairs(nearby) do
    local _, c = parse_ab_tile(tile.name)
    if c then counts[c] = (counts[c] or 0) + 1 end
  end
  local best_color, best_count = default_color, 0
  for color, count in pairs(counts) do
    if count > best_count then best_count = count; best_color = color end
  end
  return best_color
end

local function build_ab_tile_tables()
  storage.ab_upgrade_within     = {}
  storage.ab_decay_within       = {}
  storage.ab_decay_tilelist     = {}
  storage.ab_tilelists_by_group = { vegetation = {}, mineral = {} }
  storage.ab_random_pools       = {}
  if not script.active_mods["alien-biomes"] then return end
  local function tile_ok(n) return n ~= nil and prototypes.tile[n] ~= nil end
  local upgrade_count, decay_count = 0, 0
  for name, _ in pairs(prototypes.tile) do
    local g, c, b, n = parse_ab_tile(name)
    if g then
      if g == "vegetation" then
        table.insert(storage.ab_tilelists_by_group.vegetation, name)
      elseif g == "mineral" then
        table.insert(storage.ab_tilelists_by_group.mineral, name)
      end
      local up
      if g == "vegetation" and b == "grass" and n > 1 then
        up = ("vegetation-%s-grass-%d"):format(c, n - 1)
      elseif g == "mineral" and b == "sand" then
        up = n > 1 and ("mineral-%s-sand-%d"):format(c, n - 1) or ("mineral-%s-dirt-1"):format(c)
      elseif g == "mineral" and b == "dirt" and n < 6 then
        up = ("mineral-%s-dirt-%d"):format(c, n + 1)
      end
      if tile_ok(up) then storage.ab_upgrade_within[name] = up; upgrade_count = upgrade_count + 1 end
      local down
      if g == "mineral" and b == "dirt" then
        down = ("mineral-%s-sand-1"):format(c)
      elseif g == "mineral" and b == "sand" then
        down = "nuclear-ground"
      end
      if tile_ok(down) then storage.ab_decay_within[name] = down; decay_count = decay_count + 1 end
      if g == "vegetation" or g == "mineral" then
        table.insert(storage.ab_decay_tilelist, name)
      end
    end
  end
  log(("[treez] AB tables built: %d upgrades, %d decays, %d decay-eligible tiles")
    :format(upgrade_count, decay_count, #storage.ab_decay_tilelist))

  -- ── Feature 3: AB random pools ────────────────────────────────────────────
  local groups = {}
  for name, _ in pairs(prototypes.tile) do
    local g, c, b, n = parse_ab_tile(name)
    if g and (g == "mineral" or g == "vegetation") then
      local key = g .. "|" .. (c or "") .. "|" .. b
      if not groups[key] then
        groups[key] = { g = g, c = c or "", b = b, members = {} }
      end
      table.insert(groups[key].members, { name = name, n = n })
    end
  end

  for _, grp in pairs(groups) do
    local cross_name = nil
    if grp.g == "mineral" and grp.b == "sand" then
      cross_name = ("mineral-%s-dirt-1"):format(grp.c)
    elseif grp.g == "mineral" and grp.b == "dirt" then
      cross_name = ("vegetation-%s-grass-4"):format(grp.c)
    end
    local cross_ok = cross_name and prototypes.tile[cross_name] ~= nil

    local min_n = math.huge
    for _, m in ipairs(grp.members) do
      if m.n < min_n then min_n = m.n end
    end

    for _, member in ipairs(grp.members) do
      local pool = {}
      for _, sibling in ipairs(grp.members) do
        if prototypes.tile[sibling.name] then
          table.insert(pool, sibling.name)
        end
      end
      if cross_ok and member.n == min_n then
        table.insert(pool, cross_name)
      end
      if #pool > 0 then
        storage.ab_random_pools[member.name] = pool
      end
    end
  end
  local pool_count = 0
  for _ in pairs(storage.ab_random_pools) do pool_count = pool_count + 1 end
  log(("[treez] AB random pools built for %d tile types"):format(pool_count))
  -- Rebuild the rank cache now that ab_upgrade_within is populated.
  rebuild_tile_rank_cache()
end

-- ── Feature 3: Vanilla random pools ──────────────────────────────────────────
local function tile_number(name)
  return tonumber(name:match("%-(%d+)$")) or 0
end

local function build_vanilla_random_pools()
  storage.vanilla_random_pools = {}

  local categories = {
    { tiles = {"sand-1","sand-2","sand-3"},
      cross = "red-desert-3" },
    { tiles = {"red-desert-3","red-desert-2","red-desert-1","red-desert-0"},
      cross = "dry-dirt" },
    { tiles = {"dry-dirt"},
      cross = "dirt-7" },
    { tiles = {"dirt-1","dirt-2","dirt-3","dirt-4","dirt-5","dirt-6","dirt-7"},
      cross = "grass-4" },
    { tiles = {"grass-4","grass-3","grass-2","grass-1"},
      cross = nil },
    { tiles = {"landfill"},
      cross = "dry-dirt" },
  }

  for _, cat in ipairs(categories) do
    local existing = {}
    for _, name in ipairs(cat.tiles) do
      if prototypes.tile[name] then table.insert(existing, name) end
    end
    local cross_tile = (cat.cross and prototypes.tile[cat.cross]) and cat.cross or nil

    local min_n = math.huge
    for _, name in ipairs(existing) do
      local n = tile_number(name)
      if n < min_n then min_n = n end
    end

    for _, name in ipairs(existing) do
      local pool = {}
      for _, sibling in ipairs(existing) do
        table.insert(pool, sibling)
      end
      if cross_tile and tile_number(name) == min_n then
        table.insert(pool, cross_tile)
      end
      if #pool > 0 then
        storage.vanilla_random_pools[name] = pool
      end
    end
  end
  local pool_count = 0
  for _ in pairs(storage.vanilla_random_pools) do pool_count = pool_count + 1 end
  log(("[treez] Vanilla random pools built for %d tile types"):format(pool_count))
end

-- ============================================================
-- Hard tile detection
-- ============================================================

local function build_hard_tiles_set()
  storage.hard_tiles = {}
  local count = 0
  for name, tile in pairs(prototypes.tile) do
    if (tile.walking_speed_modifier or 1.0) >= HARD_TILE_THRESHOLD then
      storage.hard_tiles[name] = true; count = count + 1
    end
  end
  log(("[treez] Hard tile set: %d tiles (threshold %.1f)"):format(count, HARD_TILE_THRESHOLD))
end

local function is_hard_tile(tile_name)
  return storage.hard_tiles ~= nil and storage.hard_tiles[tile_name] == true
end

-- ============================================================
-- Day/night detection
-- ============================================================
local function is_night(surface)
  local t, e, m = surface.daytime, surface.evening, surface.morning
  if e <= m then return t >= e and t <= m
  else           return t >= e or  t <= m end
end

-- ============================================================
-- Crystal queue
-- ============================================================
-- Each entry: { entity, fire_at, rare }
-- rare = true  → soil-crystal-rare-site; uses rare pollution/spike settings.
-- rare = false → soil-crystal-site; uses normal pollution rate.

-- Returns the number of ticks until the surface's next evening threshold,
-- so a rare crystal that fires during daytime can defer to the same or next night.
local function ticks_until_next_night(surface)
  local t   = surface.daytime   -- 0..1, wraps continuously
  local e   = surface.evening   -- daytime value at which night begins
  local frac = e - t
  if frac <= 0 then frac = frac + 1 end
  return math.max(1, math.floor(frac * surface.ticks_per_day))
end

-- Lower bound on every queued pellet's fire_at.  process_crystals uses it to skip
-- the whole queue scan while nothing is due.  Only decreased here; recomputed from
-- the queue on config-change.  A stale-low value is safe (we just don't skip), so
-- no upkeep is required when entries are removed.
local function note_crystal_fire_at(fire_at)
  local cur = storage.crystal_min_fire
  if not cur or fire_at < cur then storage.crystal_min_fire = fire_at end
end

local function enqueue_crystal(entity, is_colored)
  -- Derive night length from the surface so mods that adjust the day/night
  -- cycle are automatically respected.
  local ticks_per_night = math.floor(entity.surface.ticks_per_day / 2)
  -- Clamp variance so delay − variance ≥ 1 night.
  local eff_variance = math.min(crystal_variance_nights, crystal_delay_nights - 1)
  local nights = crystal_delay_nights
  if eff_variance > 0 then
    nights = nights + math.random(-eff_variance, eff_variance)
  end
  local delay = nights * ticks_per_night
  local fire_at = game.tick + delay
  storage.crystal_queue[#storage.crystal_queue + 1] = {
    entity       = entity,
    fire_at      = fire_at,
    rare         = false,
    colored      = is_colored or false,
  }
  note_crystal_fire_at(fire_at)
end

local function enqueue_existing_crystals(surface)
  local queued = {}
  for _, entry in ipairs(storage.crystal_queue) do
    if entry.entity.valid then queued[entry.entity.unit_number] = true end
  end
  local added = 0
  -- Normal crystals
  for _, entity in ipairs(surface.find_entities_filtered{ name = CRYSTAL_SITE_NAME }) do
    if not queued[entity.unit_number] then
      storage.crystal_queue[#storage.crystal_queue + 1] = {
        entity = entity, fire_at = game.tick + 1, rare = false,
      }
      note_crystal_fire_at(game.tick + 1)
      added = added + 1
    end
  end
  if added > 0 then
    log(("[treez] Enqueued %d pre-existing crystals after config change."):format(added))
  end
end

-- ============================================================
-- Colored pellet helper
-- ============================================================
-- Spawns a colored pellet (Nitrate Catalyst) in place of a normal one.
-- Requires Nitrate Catalyst research to be active; before that, no colored
-- pellets appear. After research: 1-in-N chance (default 10%).

local function maybe_spawn_colored(entity, force)
  if not storage.colored_unlocked then return false end
  if crystal_colored_chance <= 0 then return false end
  local bonus = storage.colored_bonus_count or 0
  if math.random(crystal_colored_chance) > (1 + bonus) then return false end
  local pos     = entity.position
  local surface = entity.surface
  entity.destroy({ raise_destroy = false })
  local colored = surface.create_entity({
    name     = CRYSTAL_COLORED_SITE_NAME,
    position = pos,
    force    = force,
  })
  if colored then
    -- enqueue_crystal(entity, is_colored). The colored pellet must be flagged
    -- colored so the Nitrate Catalyst path runs at fire time, the pellet stays
    -- pollution-neutral, and it is excluded from the Enduring Nitrates re-queue.
    enqueue_crystal(colored, true)
  end
  return true
end

-- ============================================================
-- Rare crystal helper
-- ============================================================
-- Rare pellets spawn silently; no player notification on creation.

-- ============================================================
-- Tile upgrade  (Feature 3: randomise mode)
-- ============================================================
-- NOTE: Randomise upgrade paths has not yet been tested. Verify tile group
-- selection, no-op draw behaviour, and tier-skip logic before shipping.

local function get_random_upgrade_target(name)
  if storage.ab_random_pools then
    local pool = storage.ab_random_pools[name]
    if pool and #pool > 0 then return pool[math.random(#pool)] end
  end
  if storage.vanilla_random_pools then
    local pool = storage.vanilla_random_pools[name]
    if pool and #pool > 0 then return pool[math.random(#pool)] end
  end
  return nil
end

local function upgrade_tile(surface, position)
  local tile = surface.get_tile(position)
  local name = tile.name
  local target

  if randomize_upgrades then
    target = get_random_upgrade_target(name)
    if target and prototypes.tile[target] then
      surface.set_tiles({{ name = target, position = tile.position }}, nil, true)
      return true
    end
  end

  if storage.ab_upgrade_within then
    target = storage.ab_upgrade_within[name]
    if target and prototypes.tile[target] then
      surface.set_tiles({{ name = target, position = tile.position }}, nil, true)
      return true
    end
  end
  if script.active_mods["alien-biomes"] then
    local g, c, b, n = parse_ab_tile(name)
    if g == "mineral" and b == "dirt" and n == 6 then
      local veg_color = dominant_color_near(surface, tile.position, "vegetation", "green")
      target = ("vegetation-%s-grass-4"):format(veg_color)
      if prototypes.tile[target] then
        surface.set_tiles({{ name = target, position = tile.position }}, nil, true)
        return true
      end
    elseif name == "nuclear-ground" then
      local min_color = dominant_color_near(surface, tile.position, "mineral", "tan")
      target = ("mineral-%s-sand-1"):format(min_color)
      if prototypes.tile[target] then
        surface.set_tiles({{ name = target, position = tile.position }}, nil, true)
        return true
      end
    end
  end

  target = VANILLA_UPGRADE[name]
  if target and prototypes.tile[target] then
    surface.set_tiles({{ name = target, position = tile.position }}, nil, true)
    return true
  end
  return false
end

-- ============================================================
-- Smart tile upgrade — border-aware, expanding-radius algorithm
-- ============================================================
-- Used by normal white pellets and colored (catalyst) pellets.
-- Primitive (black) pellets use the same logic but with max_radius = 1.
--
-- Algorithm:
--   For r = 1 to max_radius:
--     1. Collect all tiles within radius r of the pellet position.
--     2. Find the minimum upgrade level present among those tiles.
--     3. Among tiles at that minimum level, find "border" tiles: those
--        with at least one orthogonal neighbour strictly above min level.
--        For each border tile count how many of its 4 neighbours are higher
--        (higher_count) and record the highest single neighbour (max_neighbour).
--     4. If any border tiles exist, pick the one with the most higher
--        neighbours (filling concave pockets first). Break ties by highest
--        single neighbour, then randomly.  Upgrade that tile and return.
--     5. If no border tiles exist at this radius (all same level), expand r.
--   If all radii exhausted with no border found, upgrade the tile under
--   the pellet itself (fallback).
--
-- tile_rank(name): maps a tile name to its upgrade rank so we can compare
-- tile quality without hard-coding the full chain.
-- Uses the module-level TILE_RANK_CACHE built once at startup (and rebuilt
-- after AB tables load), so this is now an O(1) table lookup.
local function tile_rank(name)
  return TILE_RANK_CACHE[name] or 0
end

-- Returns true if upgrade_tile would do anything to this tile name.
local function tile_is_upgradeable(name)
  if VANILLA_UPGRADE[name] then return true end
  if storage.ab_upgrade_within and storage.ab_upgrade_within[name] then return true end
  if script.active_mods["alien-biomes"] then
    local g, c, b, n2 = parse_ab_tile(name)
    if g == "mineral" and b == "dirt" and n2 == 6 then return true end
    if name == "nuclear-ground" then return true end
  end
  return false
end

local DIRS_4 = { {1,0}, {-1,0}, {0,1}, {0,-1} }

local function smart_upgrade_tile(surface, position, max_radius)
  local px, py = math.floor(position.x), math.floor(position.y)

  -- Bulk-fetch all tiles in the max_radius bounding box once, then build a
  -- position-keyed rank map.  This replaces hundreds of individual get_tile
  -- calls (one per candidate + one per neighbour check) with a single engine
  -- call, which is the dominant cost at radius 8 with a normal batch size.
  -- We fetch the max_radius box upfront so the map can be reused across all
  -- radius iterations without additional engine calls.  Neighbour tiles at
  -- the very edge (one beyond max_radius) are fetched separately only if
  -- needed (see the fallback below), keeping the common fast-path cheap.
  local tile_rank_at  -- position key → rank; populated lazily on first r
  local function get_rank_at(x, y)
    local key = x * 65536 + y   -- compact integer key, valid for typical map coords
    local v = tile_rank_at[key]
    if v == nil then
      -- Tile was outside the bulk area (edge neighbour); fetch individually.
      v = tile_rank(surface.get_tile({ x = x, y = y }).name)
      tile_rank_at[key] = v
    end
    return v
  end

  -- Build the bulk map for the full radius on first use.
  local bulk_built = false
  local function ensure_bulk()
    if bulk_built then return end
    bulk_built = true
    tile_rank_at = {}
    -- fetch_area covers candidates for all radii plus their orthogonal
    -- neighbours (which can be 1 tile outside max_radius).
    local pad = max_radius + 1
    local area = {
      { px - pad, py - pad },
      { px + pad + 1, py + pad + 1 },
    }
    local tiles = surface.find_tiles_filtered{ area = area }
    for _, t in ipairs(tiles) do
      local tx, ty = math.floor(t.position.x), math.floor(t.position.y)
      tile_rank_at[tx * 65536 + ty] = tile_rank(t.name)
    end
  end

  for r = 1, max_radius do
    ensure_bulk()

    -- Collect candidate tiles within radius r from the pre-built rank map.
    local candidates = {}
    for dy = -r, r do
      for dx = -r, r do
        if dx*dx + dy*dy <= r*r then
          local tx, ty = px + dx, py + dy
          local rk = get_rank_at(tx, ty)
          -- We need the tile name only for tile_is_upgradeable; reconstruct
          -- it only for the candidates that pass the min_rank filter below.
          candidates[#candidates + 1] = { x = tx, y = ty, rank = rk }
        end
      end
    end

    -- Find minimum rank in this radius.
    local min_rank = math.huge
    for _, c in ipairs(candidates) do
      if c.rank < min_rank then min_rank = c.rank end
    end

    if min_rank < math.huge then
      -- Among minimum-rank tiles, find border tiles (orthogonal neighbour
      -- with strictly higher rank) and score them.
      local border = {}
      for _, c in ipairs(candidates) do
        if c.rank == min_rank then
          -- Defer the get_tile name lookup to only tiles at min_rank.
          local tname = surface.get_tile({ x = c.x, y = c.y }).name
          if tile_is_upgradeable(tname) then
            local higher_count  = 0
            local max_neighbour = -1
            for _, d in ipairs(DIRS_4) do
              local nrank = get_rank_at(c.x + d[1], c.y + d[2])
              if nrank > min_rank then
                higher_count  = higher_count + 1
                if nrank > max_neighbour then max_neighbour = nrank end
              end
            end
            if higher_count > 0 then
              border[#border + 1] = {
                x             = c.x,
                y             = c.y,
                higher_count  = higher_count,
                max_neighbour = max_neighbour,
              }
            end
          end
        end
      end

      if #border > 0 then
        -- Sort: most higher neighbours first, then highest single neighbour.
        -- No random in the comparator — that violates Lua's strict weak ordering
        -- requirement and causes "invalid order function" errors.
        table.sort(border, function(a, b)
          if a.higher_count ~= b.higher_count then
            return a.higher_count > b.higher_count
          end
          return a.max_neighbour > b.max_neighbour
        end)

        -- Gather all top-score ties and pick one at random for organic feel.
        local best_hc = border[1].higher_count
        local best_mn = border[1].max_neighbour
        local tied    = {}
        for _, b in ipairs(border) do
          if b.higher_count == best_hc and b.max_neighbour == best_mn then
            tied[#tied + 1] = b
          end
        end
        local pick = tied[math.random(#tied)]
        return upgrade_tile(surface, { x = pick.x + 0.5, y = pick.y + 0.5 })
      end
    end
    -- No border found at this radius — expand to next.
  end

  -- Fallback: no border found within max_radius — upgrade tile under pellet.
  return upgrade_tile(surface, position)
end

-- ============================================================
-- ============================================================
-- Crystal processor
-- ============================================================

-- force_fire: when true, skips the batch limit and the night-only setting.
-- Used by the /treez force_nitrate command.
local function process_crystals(force_fire)
  local surface = game.surfaces[1]
  local night    = is_night(surface)
  -- Night-only and it's daytime: no pellet can fire this call, so skip the whole
  -- queue scan entirely.  (The in-loop night-only skip below remains as a guard.)
  if not force_fire and crystal_night_only and not night then return end
  local now      = game.tick
  -- Nothing queued: clear the due-bound and bail.
  if #storage.crystal_queue == 0 then storage.crystal_min_fire = nil return end
  -- Nothing is due yet: crystal_min_fire is a lower bound on every queued
  -- fire_at, so if now hasn't reached it no pellet can fire — skip the scan.
  if not force_fire and storage.crystal_min_fire and now < storage.crystal_min_fire then return end
  local processed, i = 0, 1
  -- Effective per-call fire cap.  Normally the fixed batch size, but when the
  -- queue exceeds the overflow threshold we raise it so that roughly
  -- crystal_overflow_percent% of the queue drains over one night's worth of
  -- firing opportunities.  It tapers automatically because qsize is re-read each
  -- call, so a storm backlog clears in a few nights instead of dozens.  The
  -- fixed batch size is always a floor.  force_fire (console command) fires all.
  local effective_batch = crystal_batch_size
  local qsize = #storage.crystal_queue
  if not force_fire and crystal_overflow_threshold > 0 and qsize > crystal_overflow_threshold then
    local night_fraction = surface.morning - surface.evening
    if night_fraction <= 0 then night_fraction = night_fraction + 1 end
    local batches_per_night = math.max(1,
      math.floor(night_fraction * surface.ticks_per_day / CRYSTAL_CHECK_INTERVAL))
    local night_budget = math.ceil(qsize * crystal_overflow_percent / 100)
    effective_batch = math.max(crystal_batch_size, math.ceil(night_budget / batches_per_night))
  end
  -- Per-call unit_number -> entry index for the catalyst chain trigger, built
  -- lazily the first time a catalyst fires this call and reused by the rest, so
  -- the chain no longer rescans the whole queue for every catalyst.
  local unit_to_entry
  while i <= #storage.crystal_queue and (force_fire or processed < effective_batch) do
    local entry = storage.crystal_queue[i]
    if force_fire or entry.fire_at <= now then
      if not force_fire and crystal_night_only and not night then
        i = i + 1
        goto continue
      end
      local last = #storage.crystal_queue
      storage.crystal_queue[i]    = storage.crystal_queue[last]
      storage.crystal_queue[last] = nil
      if entry.entity.valid then
        local pos        = entry.entity.position
        local ql         = quality_level(entry.entity)
        local is_black   = entry.entity.name == CRYSTAL_BLACK_SITE_NAME
        local nitrate_radius = storage.nitrate_upgrade_radius or 8

        if is_black then
          -- Primitive (black) pellets: border-aware upgrade, radius 1 only.
          smart_upgrade_tile(surface, pos, 1)
        else
          -- Normal white and colored pellets: border-aware upgrade, full radius.
          smart_upgrade_tile(surface, pos, nitrate_radius)
        end

        if entry.colored then
          -- Extra improvement attempts per quality level (direct upgrade_tile,
          -- not border-search — these are bonus strikes from the catalyst).
          for _ = 1, ql do upgrade_tile(surface, pos) end
          -- Adjacent tile improvement if that research is unlocked;
          -- one adjacent tile per quality level.
          if storage.colored_adjacent_unlocked then
            local offsets = { {1,0}, {-1,0}, {0,1}, {0,-1} }
            for k = 1, ql do
              local off = offsets[((k - 1) % 4) + 1]
              upgrade_tile(surface, { x = pos.x + off[1], y = pos.y + off[2] })
            end
          end
          -- Chain trigger: advance the nearest queued non-rare WHITE pellets.
          -- Nitrate Catalyst Reactions scales BOTH the reach and the number
          -- triggered, together, from storage.catalyst_chain_count (1 with no
          -- Reactions research, then 2/3/4 at levels 1/2/3): radius 1 / 1 pellet
          -- at level 0, up to radius 4 / 4 pellets at level 3.
          --
          -- Rather than scanning the whole queue for every catalyst (O(queue) per
          -- catalyst), we ask the engine's spatial index for pellet entities near
          -- this catalyst and map them back to queue entries through a per-call
          -- index (built once, on first use, and shared by every catalyst this
          -- call).  Distance is Euclidean on tile centres; the compare is inclusive
          -- so radius 1 catches orthogonally-adjacent pellets.
          local chain   = storage.catalyst_chain_count or 1
          local radius2 = chain * chain
          if not unit_to_entry then
            unit_to_entry = {}
            for _, qe in ipairs(storage.crystal_queue) do
              -- White, non-rare pellets only — colored pellets are never chain
              -- targets, and rare pellets manage their own timing.
              if not qe.rare and not qe.colored and qe.entity.valid then
                unit_to_entry[qe.entity.unit_number] = qe
              end
            end
          end
          -- Box padded by 0.5 so pellets sitting exactly `chain` tiles away are
          -- still returned; the d2 test below is the precise circular cut.
          -- Only WHITE pellets are valid chain targets: a catalyst triggers
          -- nearby white nitrate and never chains other colored pellets.
          local pad    = chain + 0.5
          local nearby = surface.find_entities_filtered{
            area = { { pos.x - pad, pos.y - pad }, { pos.x + pad, pos.y + pad } },
            name = CRYSTAL_SITE_NAME,
          }
          local candidates = {}
          for _, ne in ipairs(nearby) do
            local qe = unit_to_entry[ne.unit_number]
            if qe then
              local dx = ne.position.x - pos.x
              local dy = ne.position.y - pos.y
              local d2 = dx * dx + dy * dy
              -- d2 > 0 skips the catalyst's own entity (still valid here; it is
              -- destroyed after this block) in case it is still in the index.
              if d2 > 0 and d2 <= radius2 then
                candidates[#candidates + 1] = { entry = qe, d2 = d2 }
              end
            end
          end
          table.sort(candidates, function(a, b) return a.d2 < b.d2 end)
          for k = 1, math.min(chain, #candidates) do
            candidates[k].entry.fire_at = game.tick
          end
        end
        -- Enduring Nitrates: normal (non-colored, non-black) pellets have a
        -- 10%-per-level chance (up to 30%) of surviving and re-queuing for
        -- the next night instead of being destroyed.
        -- Black (primitive) pellets are excluded — they always consume themselves.
        local survived = false
        if entry.entity.valid and not entry.colored and not is_black then
          local en_level = 0
          local pforce = game.forces["player"]
          if pforce then
            for lvl = 1, 3 do
              local tech = pforce.technologies["treez-enduring-nitrates-" .. lvl]
              if tech and tech.researched then en_level = en_level + 1 end
            end
          end
          if en_level > 0 and math.random(100) <= (en_level * 10) then
            -- Re-enqueue for the next night; preserve entity in place.
            local en_fire = now + ticks_until_next_night(surface)
            storage.crystal_queue[#storage.crystal_queue + 1] = {
              entity  = entry.entity,
              fire_at = en_fire,
              rare    = false,
              colored = false,
            }
            note_crystal_fire_at(en_fire)
            survived = true
          end
        end
        if not survived then
          entry.entity.destroy({ raise_destroy = false })
        end
      end
      processed = processed + 1
    else
      i = i + 1
    end
    ::continue::
  end
end

-- ============================================================
-- AB pollution decay pass (System 5)
-- ============================================================

local function apply_ab_decay(surface, tile, chance)
  if math.random(1, 99) >= chance then return end
  local name, target = tile.name, nil
  if storage.ab_decay_within then
    target = storage.ab_decay_within[name]
    if target and prototypes.tile[target] then
      surface.set_tiles({{ name = target, position = tile.position }}, nil, true)
      return
    end
  end
  local g, c = parse_ab_tile(name)
  if g == "vegetation" then
    local min_color = dominant_color_near(surface, tile.position, "mineral", "tan")
    target = ("mineral-%s-dirt-6"):format(min_color)
    if prototypes.tile[target] then
      surface.set_tiles({{ name = target, position = tile.position }}, nil, true)
    end
  end
end

local function run_ab_decay_pass()
  if not script.active_mods["TerrainEvolution2"] then return end
  if not script.active_mods["alien-biomes"] then return end
  if not storage.ab_decay_tilelist or #storage.ab_decay_tilelist == 0 then return end
  local surface = game.surfaces[1]
  local minimal_pollution = settings.global["minimal_pollution"].value
  local chunk     = surface.get_random_chunk()
  local pollution = surface.get_pollution({ chunk.x * 32, chunk.y * 32 })
  if pollution <= minimal_pollution then return end
  local chance = math.min(99, math.floor(pollution / (minimal_pollution / 25)))
  local pos = {
    chunk.x * 32 + math.random(-32, 32),
    chunk.y * 32 + math.random(-32, 32),
  }
  local tiles = surface.find_tiles_filtered{
    position = pos, radius = 16, name = storage.ab_decay_tilelist, limit = 8,
  }
  for _, tile in pairs(tiles) do apply_ab_decay(surface, tile, chance) end
end

-- ============================================================
-- System 6: Tree growth
-- ============================================================

local function growth_proto_name(stage, species)
  local idx = math.ceil(stage * MAX_GROWTH_STAGES / tree_growth_stages)
  idx = math.max(1, math.min(MAX_GROWTH_STAGES, idx))
  return "treez-" .. (species or TREE_ENTITY) .. "-stage-" .. idx
end

local function is_raining_on_surface(surface)
  if not DYNAMIC_RAIN_ACTIVE then return false end
  if not (remote.interfaces["dynamic-rain"] and remote.interfaces["dynamic-rain"]["is_raining"]) then return false end
  return remote.call("dynamic-rain", "is_raining", surface.index) == true
end

local function random_growth_delay()
  if tree_growth_variability == 0 or tree_growth_ticks == 0 then
    return tree_growth_ticks
  end
  local spread = math.max(1, math.floor(tree_growth_ticks * tree_growth_variability))
  return math.max(1, tree_growth_ticks + math.random(-spread, spread))
end

-- Returns the growth delay for a tree on the given surface, halved when rain
-- growth boost is enabled and dynamic-rain reports active rainfall.
local function growth_delay_for(surface)
  local delay = random_growth_delay()
  if tree_rain_growth_boost and is_raining_on_surface(surface) then
    delay = math.max(1, math.floor(delay / 2))
  end
  return delay
end

local function try_dequeue_tree()
  if #storage.growth_queue == 0 then return end
  if storage.growing_tree_count >= tree_growth_max_active then return end

  -- Swap-remove: draw a random entry, then overwrite its slot with the last
  -- entry and drop the tail.  Order is irrelevant here (the draw is random), so
  -- this avoids table.remove's O(n) shift of every element after idx — which
  -- matters when the waiting backlog is large.  Correct even when idx == n: the
  -- self-copy is a harmless no-op and `queued` already holds the drawn entry.
  local n      = #storage.growth_queue
  local idx    = math.random(n)
  local queued = storage.growth_queue[idx]
  storage.growth_queue[idx] = storage.growth_queue[n]
  storage.growth_queue[n]   = nil
  local surface = game.surfaces[queued.surface_index]
  local force   = surface and game.forces[queued.force_name]
  if not surface or not force then
    -- Surface or force gone — clean up any marker and discard.
    if surface then cleanup_marker_at(surface, queued.position) end
    return
  end

  local pos     = queued.position
  local species = queued.species or TREE_ENTITY

  -- Stale-entry guard. The treez-seed-waiting marker is the queued seed's
  -- physical presence: every growth_queue entry is created alongside one and the
  -- marker is only removed by mining (which also drops the entry via
  -- remove_from_growth_queue) or by try_dequeue_tree itself. So if no marker is
  -- present here, the seed was removed by something that did not raise a mined
  -- event (e.g. a blueprint mod deleting it through a script destroy). The entry
  -- is stale — discard it instead of growing a phantom tree. The entry was
  -- already swap-removed from the queue above, so returning drops it.
  if not surface.find_entities_filtered{
       name = SEED_WAITING_NAME, position = pos, radius = 0.2 }[1] then
    return
  end

  if tree_growth_bypass then
    cleanup_marker_at(surface, pos)
    if surface.can_place_entity({ force = force, name = species, position = pos }) then
      surface.create_entity({ force = force, name = species, position = pos, raise_built = true })
    end
    return
  end

  local plant_name = growth_proto_name(1, species)

  -- ── Remove the marker FIRST ───────────────────────────────────────────────
  -- The treez-seed-waiting marker occupies the same tile and shares the
  -- object-layer collision mask with the stage-1 growth entity.  If it is
  -- still present when can_place_entity / create_entity runs, the check fails
  -- because the marker's own collision box blocks the placement.  Remove it
  -- here; if placement then still fails (tile incompatible, another entity in
  -- the way) we restore the marker so the seed stays visible and minable.
  cleanup_marker_at(surface, pos)

  -- Respect pre-placed ghosts: a ghost may have been placed at this position
  -- after the seed was queued.  The marker was just removed so only genuine
  -- foreign ghosts remain here.  Restore the marker and requeue so the seed
  -- keeps waiting rather than clobbering a player-designated build site.
  -- Footprint-based ghost check (see try_place_rain_nitrate): position+radius
  -- only matches ghosts centred within the radius, so a multi-tile ghost covering
  -- this tile but centred elsewhere would be missed and the real plant created
  -- below would build over it and delete it.  Search the whole tile instead.
  local gtx, gty = math.floor(pos.x), math.floor(pos.y)
  if surface.find_entities_filtered{ area = { { gtx, gty }, { gtx + 1, gty + 1 } }, type = "entity-ghost" }[1] then
    surface.create_entity({
      force = force, name = SEED_WAITING_NAME,
      position = pos, raise_built = false,
    })
    storage.growth_queue[#storage.growth_queue + 1] = queued
    return
  end

  local new_entity = surface.create_entity({
    force = force, name = plant_name, position = pos, raise_built = false,
  })

  if new_entity then
    -- ── Successful placement ────────────────────────────────────────────────
    storage.growing_trees[#storage.growing_trees + 1] = {
      entity  = new_entity,
      stage   = 1,
      fire_at = game.tick + growth_delay_for(surface),
      species = species,
    }
    storage.growing_tree_count = storage.growing_tree_count + 1
  else
    -- ── Placement failed ────────────────────────────────────────────────────
    -- Restore the marker so the player can still see and mine the queued seed.
    -- Requeue at the back so other positions get a chance next cycle.
    -- No retry limit: seeds are never silently discarded; they wait until
    -- either the position clears or the player manually mines the marker.
    surface.create_entity({
      force = force, name = SEED_WAITING_NAME,
      position = pos, raise_built = false,
    })
    storage.growth_queue[#storage.growth_queue + 1] = queued
  end
end

-- ── Rail entity types ─────────────────────────────────────────────────────────
-- Used by is_on_rail and try_place_rain_nitrate.  Defined here so both
-- functions can reference it without a forward-reference issue.
local RAIL_ENTITY_TYPES = {
  "straight-rail", "curved-rail", "half-diagonal-rail",
  "rail-signal", "rail-chain-signal", "train-stop",
}

-- ── Sapling Soil Enrichment helpers ──────────────────────────────────────────
-- Defined here (before process_growing_trees) so they are in scope at the
-- call site inside that function.

-- Returns the number of Sapling Soil Enrichment levels researched (0–6).
-- Level N gives an N% cumulative chance of upgrading a tile once per
-- intermediate growth stage advance.
local function get_soil_enrichment_level()
  local force = game.forces["player"]
  if not force then return 0 end
  local count = 0
  for i = 1, 6 do
    local tech = force.technologies["treez-soil-enrichment-" .. i]
    if tech and tech.researched then count = count + 1 end
  end
  return count
end

-- Called on each intermediate growth stage advance.
-- Rolls a 1%-per-level chance (cumulative up to 6%).  On success, picks a
-- tile to upgrade using distance-weighted random selection (Strategy 4):
--   • All tiles within Euclidean radius `level` are candidates.
--   • Each tile's selection weight = 1 / max(0.5, d)²  where d is its
--     Euclidean distance from the sapling centre.  The centre tile (d=0)
--     uses d=0.5 to give it weight 4, making it the strongest attractor
--     without making it a certainty.
--   • One tile is drawn from the weighted pool; if upgrade_tile returns
--     false (already at max) that tile is removed and a new draw is made.
--     This repeats until a tile upgrades or the pool is exhausted.
--   • Produces a smooth gaussian-ish gradient with no ring structure —
--     individual trees get organic circular halos, dense forests diffuse
--     upgrades inward following tree density rather than geometry.
-- surface, pos — the surface and world position of the advancing sapling.
local function try_growth_enrich_soil(surface, pos)
  local level = get_soil_enrichment_level()
  if level == 0 then return end   -- no research; nothing to do
  -- Each level contributes 1%; math.random(100) returns 1–100.
  if math.random(100) > level then return end   -- roll failed

  local ox = math.floor(pos.x)   -- tile origin (integer tile coord)
  local oy = math.floor(pos.y)
  local radius = level            -- Euclidean radius = research level in tiles

  -- Build weighted candidate pool.
  -- Weight = 1 / max(0.5, euclidean_distance)^2
  local pool        = {}
  local total_weight = 0.0

  for dy = -radius, radius do
    for dx = -radius, radius do
      local d2 = dx * dx + dy * dy
      if d2 <= radius * radius then   -- Euclidean circle cutoff
        local d   = math.sqrt(d2)
        local w   = 1.0 / math.max(0.5, d) ^ 2
        total_weight = total_weight + w
        pool[#pool + 1] = { dx = dx, dy = dy, w = w }
      end
    end
  end

  -- Weighted random draw without replacement until a tile upgrades or pool empty.
  while #pool > 0 and total_weight > 0 do
    local r   = math.random() * total_weight
    local acc = 0.0
    local idx = #pool   -- fallback to last if floating-point doesn't land
    for j = 1, #pool do
      acc = acc + pool[j].w
      if acc >= r then idx = j; break end
    end

    local entry  = pool[idx]
    local target = { x = ox + entry.dx + 0.5, y = oy + entry.dy + 0.5 }

    if upgrade_tile(surface, target) then return end   -- success — done

    -- Remove exhausted tile from pool and retry.
    total_weight = total_weight - entry.w
    pool[idx] = pool[#pool]
    pool[#pool] = nil
  end
  -- Pool exhausted — all tiles in radius fully upgraded, silently discard.
end

local function process_growing_trees()
  if not TREE_GROWTH_ENABLED then return end
  if storage.growing_tree_count == 0 and #storage.growth_queue == 0 then return end
  if tree_growth_day_only and is_night(game.surfaces[1]) then return end

  local now = game.tick
  local i   = 1

  while i <= #storage.growing_trees do
    local entry = storage.growing_trees[i]

    if not entry.entity.valid then
      local last = #storage.growing_trees
      storage.growing_trees[i]    = storage.growing_trees[last]
      storage.growing_trees[last] = nil
      storage.growing_tree_count  = storage.growing_tree_count - 1
      try_dequeue_tree()

    elseif entry.fire_at <= now then
      -- ── Pollution delay check ─────────────────────────────────────────────
      -- When "Tree growth delayed by pollution" is enabled, each tick where a
      -- tree is due to advance has a chance to be skipped equal to the chunk's
      -- current pollution value (clamped to 100%).
      --
      -- On a skip, the retry delay is scaled directly by the pollution level:
      --   retry = floor(pollution) × GROWTH_CHECK_INTERVAL ticks
      -- This means a chunk with 8 pollution retries after 80 ticks, while a
      -- chunk with 50 pollution retries after 500 ticks.  Trees in different
      -- pollution zones therefore grow at naturally different rates, producing
      -- location-based variability without any random spread within the delay
      -- itself.  A minimum of one full check-interval is enforced so a skip
      -- never reschedules for the very same tick.
      --
      -- When "Trees in growth enrich soil" is also enabled, a skipped tick
      -- carries the same percentage chance of upgrading the tile under the
      -- tree — representing the roots conditioning the soil despite the
      -- pollution blocking visible above-ground progress.
      if tree_growth_pollution_delay then
        local pos_check = entry.entity.position
        local surface_check = entry.entity.surface
        local pollution = surface_check.get_pollution(pos_check)
        -- Clamp to 100 so a very high-pollution chunk can stall a tree at
        -- most completely (100% skip chance) but never permanently (the tree
        -- always gets another attempt once the delay expires).
        local skip_chance = math.min(100, pollution)
        if skip_chance > 0 and math.random() * 100 <= skip_chance then
          -- Optionally enrich the soil on a skipped tick.
          if tree_growth_enrich_soil then
            if math.random() * 100 <= skip_chance then
              upgrade_tile(surface_check, pos_check)
            end
          end
          -- Retry delay scales with pollution: heavier pollution → longer wait.
          -- floor(pollution) × check-interval, minimum one interval.
          local pollution_ticks = math.max(GROWTH_CHECK_INTERVAL,
            math.floor(pollution) * GROWTH_CHECK_INTERVAL)
          entry.fire_at = now + pollution_ticks
          i = i + 1
          goto continue_growth
        end
      end
      -- ── Normal growth advance ─────────────────────────────────────────────
      local pos     = entry.entity.position
      local surface = entry.entity.surface
      local force   = entry.entity.force
      local species = entry.species or TREE_ENTITY
      -- Preserve deconstruction flag so a marked tree stays marked as it grows.
      local was_marked_for_deconstruction = entry.entity.to_be_deconstructed()
      entry.entity.destroy({ raise_destroy = false })

      local last = #storage.growing_trees
      storage.growing_trees[i]    = storage.growing_trees[last]
      storage.growing_trees[last] = nil

      if entry.stage >= tree_growth_stages then
        if species and prototypes.entity[species] then
          surface.create_entity({
            force = force, name = species, position = pos, raise_built = true,
          })
        elseif TREE_ENTITY then
          surface.create_entity({
            force = force, name = TREE_ENTITY, position = pos, raise_built = true,
          })
        end
        -- Guarantee no stale acorn marker remains once the full tree is placed.
        cleanup_marker_at(surface, pos)
        storage.growing_tree_count = storage.growing_tree_count - 1
        try_dequeue_tree()
      else
        local next_stage = entry.stage + 1
        -- Sapling Soil Enrichment: roll once per stage advance (stages 1–199).
        -- Fires before the entity swap so the tile is still accessible underfoot.
        try_growth_enrich_soil(surface, pos)
        local new_entity = surface.create_entity({
          force = force, name = growth_proto_name(next_stage, species),
          position = pos, raise_built = false,
        })
        if new_entity then
          if was_marked_for_deconstruction then
            new_entity.order_deconstruction(force)
          end
          storage.growing_trees[#storage.growing_trees + 1] = {
            entity  = new_entity,
            stage   = next_stage,
            fire_at = now + growth_delay_for(surface),
            species = species,
          }
        else
          if species and prototypes.entity[species] then
            surface.create_entity({
              force = force, name = species, position = pos, raise_built = true,
            })
          elseif TREE_ENTITY then
            surface.create_entity({
              force = force, name = TREE_ENTITY, position = pos, raise_built = true,
            })
          end
          cleanup_marker_at(surface, pos)
          storage.growing_tree_count = storage.growing_tree_count - 1
          try_dequeue_tree()
        end
      end
    else
      i = i + 1
    end
    ::continue_growth::
  end
  -- Catch-up pass: fill any slots opened by completed trees or a cap increase.
  -- Capped to available slots so a batch of failures doesn't spin the entire
  -- queue in one tick.  Failed placements restore their marker and requeue;
  -- seeds are never silently discarded.
  local available = math.max(0, tree_growth_max_active - storage.growing_tree_count)
  local attempts  = math.min(available, #storage.growth_queue)
  for _ = 1, attempts do
    if storage.growing_tree_count >= tree_growth_max_active then break end
    if #storage.growth_queue == 0 then break end
    try_dequeue_tree()
  end
end



-- ============================================================
-- Feature 4: Crystal pollution emission
-- ============================================================
-- Normal pellets  emit  crystal_pollution_rate / min (reduced by white_pollution_reduction research).
-- Colored pellets are pollution-neutral — no emission or absorption.
-- Runs on POLLUTION_EMIT_INTERVAL ticks (its own coarser cadence).
local function emit_crystal_pollution(surface)
  if #storage.crystal_queue == 0 then return end
  local base_pollution_rate = math.max(0, crystal_pollution_rate - (storage.white_pollution_reduction or 0))
  local normal_emit = base_pollution_rate * POLLUTION_EMIT_INTERVAL / 3600.0
  for _, entry in ipairs(storage.crystal_queue) do
    if entry.entity.valid then
      local ql = quality_level(entry.entity)
      if entry.colored then
        -- Colored (Nitrate Catalyst): pollution-neutral — no emission or absorption.
      else
        -- Normal (white): emission decreases by 10% per quality level.
        local amount = normal_emit * math.max(0, 1 - 0.1 * ql)
        if amount > 0 then
          surface.pollute(entry.entity.position, amount)
        end
      end
    end
  end
end

-- ============================================================
-- System 7: Dynamic Rain seed drop
-- ============================================================
-- When dynamic-rain removes all pollution from a chunk during a storm,
-- Treez scatters 1–6 seeds into that chunk (count scales with Sapling
-- Growth research).  Every seed attempt respects the same placement
-- rules as the normal on_built_entity → handle_site path.
--
-- Design notes:
--   • Dynamic Rain has no event for "chunk hit zero pollution".
--     We detect the transition by snapshotting polluted chunks when
--     rain starts, then polling only that smaller set every
--     CRYSTAL_CHECK_INTERVAL ticks.
--   • plant_seed_at mirrors handle_site logic without requiring an
--     entity to be created first.  Keep both in sync when editing
--     placement rules.
--   • get_pollution uses the chunk-centre point (x*32+16, y*32+16),
--     the same point Dynamic Rain itself polls.
--   • Pollution equality check is == 0 (exact), matching design spec.
--     Dynamic Rain removal is min(current, cap), so the result is
--     current - current = 0.0 in IEEE 754 when cap >= remaining
--     pollution.  If a chunk never triggers, try <= 0 instead.

-- Attempts to plant a single tree seed at the given position.
-- Applies all the same guards as on_built_entity → handle_site.
-- Returns true if the seed was placed or queued, false if rejected.
-- NOTE: Keep in sync with handle_site() when editing placement logic.
local function plant_seed_at(surface, position, force)
  if not TREE_ENTITY then return false end
  if surface.platform ~= nil then return false end

  local tile_name = surface.get_tile(position).name
  if is_hard_tile(tile_name)        then return false end
  if is_se_blocked_surface(surface) then return false end
  if is_se_blocked_tile(tile_name)  then return false end

  -- Do not plant on ore patches.  Seeds on top of ore would obscure the deposit
  -- and prevent efficient mining, so any tile with a resource entity underneath
  -- is treated as occupied.
  if surface.find_entities_filtered{ position = position, radius = 0.5, type = "resource" }[1] then
    return false
  end

  -- Do not plant where a nitrate pellet already exists — seeds and crystals
  -- must not overlap so neither mechanic obscures or interferes with the other.
  if surface.find_entities_filtered{ position = position, radius = 0.5, name = CRYSTAL_NAMES }[1] then
    return false
  end

  -- Respect pre-placed ghosts: the player has explicitly designated this tile
  -- for something else, so rain seeding must not clobber it.
  -- (can_place_entity uses entity collision layers and ignores the ghost layer,
  -- so this check must be done explicitly.)
  -- Footprint-based: search the whole tile, not a centre-based radius, so a
  -- multi-tile ghost covering this tile but centred elsewhere is still caught
  -- (otherwise the real tree/plant created below would build over and delete it).
  local gtx, gty = math.floor(position.x), math.floor(position.y)
  if surface.find_entities_filtered{ area = { { gtx, gty }, { gtx + 1, gty + 1 } }, type = "entity-ghost" }[1] then
    return false
  end

  -- Do not plant on top of already-built entities (buildings, walls, etc.).
  -- can_place_entity uses SITE_NAME whose collision box is intentionally tiny
  -- (0.2x0.2) so seeds can be placed near trees; that same tiny box means a
  -- large building whose footprint covers the tile but whose centre is elsewhere
  -- can pass the check.  A broader radius search catches those cases.
  -- Excludes: resources (caught above), ghosts (caught above), trees/plants,
  -- and our own seed/marker entities.
  local blocking = surface.find_entities_filtered{
    position = position,
    radius   = 0.5,
    type     = { "character", "combat-robot", "car", "spider-vehicle",
                 "locomotive", "cargo-wagon", "fluid-wagon", "artillery-wagon",
                 "artillery-turret", "turret", "ammo-turret", "electric-turret",
                 "fluid-turret", "container", "logistic-container",
                 "infinity-container", "assembling-machine", "furnace",
                 "electric-pole", "wall", "gate", "roboport", "lab",
                 "radar", "pump", "offshore-pump", "mining-drill",
                 "solar-panel", "accumulator", "reactor", "heat-pipe",
                 "generator", "boiler", "inserter", "transport-belt",
                 "underground-belt", "splitter", "pipe", "pipe-to-ground",
                 "storage-tank", "beacon", "lamp", "power-switch",
                 "programmable-speaker", "land-mine", "simple-entity-with-owner",
                 "simple-entity-with-force" },
  }
  for _, ent in ipairs(blocking) do
    local n = ent.name
    -- Allow our own seed/marker entities -- they are handled elsewhere.
    if n ~= SITE_NAME and n ~= SEED_WAITING_NAME then
      return false
    end
  end

  -- Use the seed-site collision box as a placement proxy.
  if not surface.can_place_entity({ force = force, name = SITE_NAME, position = position }) then
    return false
  end

  local species = pick_species_at(surface, position)
  if not species or species == "" then species = TREE_ENTITY end
  if not species or species == "" then return false end

  if not TREE_GROWTH_ENABLED or tree_growth_bypass then
    if surface.can_place_entity({ force = force, name = species, position = position }) then
      surface.create_entity({ force = force, name = species, position = position, raise_built = true })
      return true
    end
    return false
  end

  local plant_name = growth_proto_name(1, species)

  if storage.growing_tree_count < tree_growth_max_active then
    if surface.can_place_entity({ force = force, name = plant_name, position = position }) then
      local new_entity = surface.create_entity({
        force = force, name = plant_name, position = position, raise_built = false,
      })
      if new_entity then
        storage.growing_trees[#storage.growing_trees + 1] = {
          entity  = new_entity,
          stage   = 1,
          fire_at = game.tick + growth_delay_for(surface),
          species = species,
        }
        storage.growing_tree_count = storage.growing_tree_count + 1
        return true
      end
    end
    -- can_place_entity false, or create_entity returned nil → fall through to queue.
  end

  -- Cap reached or stage-1 blocked: queue the seed.
  surface.create_entity({
    force = force, name = SEED_WAITING_NAME,
    position = position, raise_built = false,
  })
  storage.growth_queue[#storage.growth_queue + 1] = {
    surface_index = surface.index,
    position      = { x = position.x, y = position.y },
    force_name    = force.name,
    species       = species,
  }
  return true   -- queued counts as "placed"
end

-- Returns the number of seeds to scatter in a rain-cleaned chunk.
-- Requires Arboreal Aromatics to be researched; returns 0 if not.
-- Base count is 1 (from Arboreal Aromatics alone).
-- Each 2 levels of Cloud Seeding add 1 more seed:
--   CS 0 → 1, CS 1 → 1, CS 2 → 2, CS 3 → 2, CS 4 → 3, CS 5 → 3, CS 6 → 4
-- Formula: floor(cloud_levels / 2) + 1
local function get_rain_seed_count()
  local force = game.forces["player"]
  if not force then return 0 end
  local aa_tech = force.technologies["treez-arboreal-aromatics"]
  if not (aa_tech and aa_tech.researched) then return 0 end
  local cloud_levels = 0
  for i = 1, 6 do
    local tech = force.technologies["treez-cloudseeding-" .. i]
    if tech and tech.researched then cloud_levels = cloud_levels + 1 end
  end
  return math.floor(cloud_levels / 2) + 1
end

-- Max random placement attempts per desired seed (avoids infinite loops
-- on heavily-obstructed chunks while still filling reasonable terrain).
local RAIN_SEED_ATTEMPTS_PER_SEED = 10

-- Scatter seeds into a chunk whose pollution just hit zero.
-- Places up to seed_count seeds in random valid positions within the chunk.
-- Any seeds that don't fit (no valid tile found in the attempt budget) are
-- silently dropped — they are not queued or retried.
-- Sends debug notifications to connected players when rain_seed_debug is on.
local function try_rain_seed_chunk(surface, chunk_x, chunk_y, force)
  local seed_count = get_rain_seed_count()
  if seed_count == 0 then return end   -- Arboreal Aromatics not yet researched

  local placed           = 0
  local placed_positions = {}

  local max_attempts = seed_count * RAIN_SEED_ATTEMPTS_PER_SEED
  for _ = 1, max_attempts do
    if placed >= seed_count then break end
    -- Pick a random tile centre within the 32×32 chunk.
    local tx  = chunk_x * 32 + math.random(0, 31)
    local ty  = chunk_y * 32 + math.random(0, 31)
    local pos = { x = tx + 0.5, y = ty + 0.5 }
    if plant_seed_at(surface, pos, force) then
      placed = placed + 1
      placed_positions[placed] = { x = pos.x, y = pos.y }
    end
  end

  if rain_seed_debug then
    local cx = chunk_x * 32 + 16
    local cy = chunk_y * 32 + 16
    -- Reveal the chunk on the minimap for the player force.
    force.chart(surface, {
      left_top     = { x = chunk_x * 32,      y = chunk_y * 32      },
      right_bottom = { x = chunk_x * 32 + 32, y = chunk_y * 32 + 32 },
    })
    local chunk_link = "[gps=" .. cx .. "," .. cy .. "]"
    for _, player in pairs(game.connected_players) do
      player.print({ "treez.rain-chunk-cleaned", chunk_link, placed, seed_count })
    end
    for i = 1, placed do
      local p = placed_positions[i]
      local seed_link = "[gps=" .. math.floor(p.x) .. "," .. math.floor(p.y) .. "]"
      for _, player in pairs(game.connected_players) do
        player.print({ "treez.rain-seed-placed", seed_link })
      end
    end
  end
end

-- ============================================================
-- System 7b: Dynamic Rain native event handler
-- ============================================================
-- DR 0.5.x exposes on_rain_pollution_cleaned (not on_chunk_pollution_cleared).
-- This fires every tick that rain removes any pollution, passing a table of
-- chunks cleaned that tick.  We use it for two purposes:
--   1. Cloud Seeding: detect when a chunk's pollution hits zero → scatter seeds.
--   2. Restorative Rains: accumulate credits (one per chunk-cleaning event) and
--      maintain a master list of chunks that had pollution removed this storm.
--
-- setup_rain_event_listener() registers on_rain_pollution_cleaned and returns
-- true on success.  The old polling path is kept in dead code but disabled.
-- Must be called from on_load, on_init, and on_configuration_changed.

-- Returns true if Restorative Rains is researched and the setting is enabled.
local function restorative_rains_active()
  if not DYNAMIC_RAIN_ACTIVE then return false end
  if not settings.global["treez-restorative-rains-enabled"].value then return false end
  local force = game.forces["player"]
  if not force then return false end
  local tech = force.technologies["treez-restorative-rains"]
  return tech ~= nil and tech.researched
end

-- Attempts to place one nitrate pellet at a random valid tile in the given chunk.
-- Returns true if a pellet was placed.
-- Placement guards (mirrors player placement):
--   • hard tile (concrete, stone, brick, etc.) → skip
--   • ore patch (resource entity) → skip
--   • ghost present → skip
--   • rail within 1.5 tiles → skip
--   • grass tile → skip (no nitrates on grass)
--   • can_place_entity false → skip
local RAIN_NITRATE_ATTEMPTS = 12   -- attempts per credit before giving up
local GRASS_TILES = {
  ["grass-1"] = true, ["grass-2"] = true,
  ["grass-3"] = true, ["grass-4"] = true,
}

local function try_place_rain_nitrate(surface, chunk_x, chunk_y, force)
  for _ = 1, RAIN_NITRATE_ATTEMPTS do
    local tx  = chunk_x * 32 + math.random(0, 31)
    local ty  = chunk_y * 32 + math.random(0, 31)
    local pos = { x = tx + 0.5, y = ty + 0.5 }
    -- Tile footprint occupied by this pellet, used for the ghost-overlap check.
    local tile_area = { { tx, ty }, { tx + 1, ty + 1 } }

    local tile_name = surface.get_tile(pos).name
    if not is_hard_tile(tile_name)
    and not GRASS_TILES[tile_name]
    and not is_se_blocked_tile(tile_name)
    and not surface.find_entities_filtered{ position = pos, radius = 0.5, type = "resource"     }[1]
    -- Ghost guard uses an AREA (this tile), NOT position+radius. position+radius
    -- only matches ghosts whose CENTRE is within the radius, so a multi-tile
    -- building ghost covering this tile but centred elsewhere slips through.
    -- create_entity then places a real pellet that "builds over" the overlapping
    -- ghost and the engine deletes it. We reject if ANY ghost footprint touches this tile.
    and not surface.find_entities_filtered{ area = tile_area, type = "entity-ghost" }[1]
    and not surface.find_entities_filtered{ position = pos, radius = 0.5, name = CRYSTAL_NAMES  }[1]
    and not surface.find_entities_filtered{ position = pos, radius = 0.5, name = { SITE_NAME, SEED_WAITING_NAME } }[1]
    and not surface.find_entities_filtered{ position = pos, radius = 1.5, type = RAIL_ENTITY_TYPES }[1]
    and surface.can_place_entity({ name = CRYSTAL_SITE_NAME, position = pos, force = force })
    then
      local entity = surface.create_entity({
        name     = CRYSTAL_SITE_NAME,
        position = pos,
        force    = force,
        raise_built = true,
      })
      if entity and entity.valid then
        enqueue_crystal(entity, false)
        return true
      end
    end
  end
  return false
end

-- Called every RAIN_NITRATE_INTERVAL ticks while rain is active.
-- Spends accumulated credits to place nitrate pellets in the storm's
-- cleaned-chunk pool, then resets credits and the chunk list so the
-- next burst starts fresh.
local RAIN_NITRATE_INTERVAL = 1200   -- 20 seconds at 60 UPS

local function restorative_rains_tick()
  if not DYNAMIC_RAIN_ACTIVE then return end

  if not restorative_rains_active() then return end

  local surface = game.surfaces["nauvis"]
  if not (surface and surface.valid) then return end

  if not is_raining_on_surface(surface) then return end

  local credits = storage.dr_rain_credits or 0
  if credits == 0 then return end

  local chunks = storage.dr_rain_chunks
  if not chunks or next(chunks) == nil then return end

  -- Build a flat array of chunk keys so we can pick randomly.
  local chunk_keys = {}
  for k in pairs(chunks) do
    chunk_keys[#chunk_keys + 1] = k
  end
  if #chunk_keys == 0 then return end

  local force = game.forces["player"]
  if not force then return end

  -- Spend up to `credits` placements this burst.
  local placed = 0
  for _ = 1, credits do
    local key = chunk_keys[math.random(#chunk_keys)]
    local cd  = chunks[key]
    if cd then
      if try_place_rain_nitrate(surface, cd.x, cd.y, force) then
        placed = placed + 1
      end
    end
  end

  if rain_seed_debug and placed > 0 then
    for _, player in pairs(game.connected_players) do
      player.print(("[treez] Restorative Rains: spent %d credit(s), placed %d nitrate(s)."):format(
        credits, placed))
    end
  end

  -- Reset ledger for the next burst window.
  storage.dr_rain_credits = 0
  storage.dr_rain_chunks  = {}
end

-- Called by on_rain_pollution_cleaned for each event DR fires.
-- Accumulates one credit per cleaned chunk entry and records each chunk.
-- Also handles Cloud Seeding (zero-crossing detection for seed scatter).
local function on_rain_pollution_cleaned(event)
  local surface = game.surfaces[event.surface_index]
  if not (surface and surface.valid) then return end

  local force = game.forces["player"]
  if not force then return end

  local chunks_data = event.chunks
  if not chunks_data then return end

  -- Ensure per-storm storage is initialised.
  local seeded      = storage.dr_seeded_this_storm or {}
  local rain_chunks = storage.dr_rain_chunks        or {}
  local credits     = storage.dr_rain_credits        or 0

  for _, cd in ipairs(chunks_data) do
    local cx  = cd.chunk_position.x
    local cy  = cd.chunk_position.y
    local key = cx .. ":" .. cy

    -- ── Restorative Rains: credit + chunk tracking ──────────────────
    -- Two credits per chunk so thunderstorms place twice as many nitrates.
    credits = credits + 2
    if not rain_chunks[key] then
      rain_chunks[key] = { x = cx, y = cy }
    end

    -- ── Cloud Seeding: scatter seeds when pollution hits zero ────────
    if rain_seed_enabled and cd.pollution_after == 0 and not seeded[key] then
      seeded[key] = true
      try_rain_seed_chunk(surface, cx, cy, force)
    end
  end

  storage.dr_seeded_this_storm = seeded
  storage.dr_rain_chunks       = rain_chunks
  storage.dr_rain_credits      = credits
end

-- Registers the on_rain_pollution_cleaned handler from Dynamic Rain.
-- Returns true when successfully registered, false otherwise.
-- Must be called from on_load, on_init, and on_configuration_changed.
local function setup_rain_event_listener()
  if not DYNAMIC_RAIN_ACTIVE then return false end
  if not (remote.interfaces["dynamic-rain"]
      and remote.interfaces["dynamic-rain"]["get_events"]) then
    log("[treez] Dynamic Rain detected but get_events not available.")
    return false
  end

  local ok, dr_events = pcall(remote.call, "dynamic-rain", "get_events")
  if not ok or type(dr_events) ~= "table" then
    log("[treez] Dynamic Rain get_events call failed.")
    return false
  end

  local event_id = dr_events.on_rain_pollution_cleaned
  if not event_id then
    log("[treez] Dynamic Rain get_events returned no on_rain_pollution_cleaned — rain integration disabled.")
    return false
  end

  script.on_event(event_id, on_rain_pollution_cleaned)
  log("[treez] Dynamic Rain on_rain_pollution_cleaned registered (id="
    .. tostring(event_id) .. ").")
  return true
end

-- Called from the CRYSTAL_CHECK_INTERVAL nth-tick handler.
-- Handles storm start/end bookkeeping only — event-driven detection replaces
-- the old polling path, which is retained here as dead code for reference.
local function rain_seeding_tick()
  if not DYNAMIC_RAIN_ACTIVE then return end

  local surface = game.surfaces["nauvis"]
  if not (surface and surface.valid) then return end

  local is_rain  = is_raining_on_surface(surface)
  local was_rain = storage.dr_rain_was_active or false

  -- Storm just started: reset all per-storm ledgers.
  if is_rain and not was_rain then
    storage.dr_seeded_this_storm = {}
    storage.dr_rain_chunks       = {}
    storage.dr_rain_credits      = 0
    if rain_seed_debug then
      for _, player in pairs(game.connected_players) do
        player.print("[treez] 🌧 Rain started — event-driven tracking active.")
      end
    end
  end

  -- Storm just ended: flush any remaining credits immediately so pellets
  -- placed at end-of-storm still fire the coming night.
  if not is_rain and was_rain then
    restorative_rains_tick()   -- spend whatever credits remain
    storage.dr_rain_chunks  = {}
    storage.dr_rain_credits = 0
  end

  storage.dr_rain_was_active = is_rain

  -- ── OLD POLLING PATH (disabled — kept for reference) ──────────────
  -- The polling path detected chunk pollution hitting zero by snapshotting
  -- at storm start and checking each interval.  It is superseded by the
  -- on_rain_pollution_cleaned event which carries pollution_before/after
  -- directly, making zero-crossing trivially detectable without polling.
  -- Removing this code entirely would be safe; it is retained commented
  -- in case a future DR version drops the event and we need to revert.
  --[[
  if not dr_native_event_active then
    -- (old polling code omitted)
  end
  --]]
end

-- ============================================================
-- Seed-ghost collision sweep (foreign-tree adaptation)
-- ============================================================
-- Some mods place real trees programmatically without checking for an existing
-- tree-seed ghost. When a tree lands on the tile a tree-seed-site ghost is
-- waiting on, construction robots can never fulfil the ghost (the tile is
-- occupied) and keep retrying. Once per day/night cycle, at dusk, we scan the
-- surface's tree-seed-site ghosts and cancel any that have become
-- unfulfillable because a foreign tree/plant now blocks the tile. The planting
-- is intentionally lost.
--
-- We require BOTH that a tree/plant overlaps the ghost's tile AND that the
-- seed-site can no longer be placed there, so a tree merely near a still-
-- buildable ghost is left untouched, and ghosts blocked by non-tree causes
-- (water, player buildings) are not swept up by this foreign-tree handler.
local function run_seed_ghost_collision_sweep(surface)
  if not (surface and surface.valid) then return end
  local ghosts = surface.find_entities_filtered{
    type       = "entity-ghost",
    ghost_name = SITE_NAME,
  }
  if #ghosts == 0 then return end
  local cancelled = 0
  for _, ghost in ipairs(ghosts) do
    if ghost.valid then
      local pos = ghost.position
      local gtx, gty = math.floor(pos.x), math.floor(pos.y)
      -- Footprint search over the ghost's own tile (mirrors the placement
      -- guards). "plant" covers Space Age trees and simply matches nothing in
      -- base, so the array filter is safe with or without Space Age.
      local tree = surface.find_entities_filtered{
        area = { { gtx, gty }, { gtx + 1, gty + 1 } },
        type = { "tree", "plant" },
      }[1]
      if tree and not surface.can_place_entity({
        name = SITE_NAME, position = pos, force = ghost.force,
      }) then
        ghost.destroy({ raise_destroy = false })
        cancelled = cancelled + 1
      end
    end
  end
  if cancelled > 0 then
    log(("[treez] Seed-ghost sweep cancelled %d unfulfillable ghost(s) blocked by foreign trees."):format(cancelled))
  end
end

-- Foreign-tree ghost collision sweep
-- ============================================================
-- Some mods place full-grown trees programmatically without checking for
-- existing entity ghosts.  When that happens the ghost is never fulfilled
-- (the tile is occupied) and robots keep retrying indefinitely.  Once per
-- day/night cycle we scan ALL entity-ghosts on the surface and mark for
-- deconstruction any tree or plant whose footprint overlaps a ghost tile.
-- Treez's own growing stages (name matches "treez-*-stage-*") are excluded —
-- they are managed by the growth system and are not the source of the problem.
local function run_foreign_tree_ghost_sweep(surface)
  if not (surface and surface.valid) then return end

  local sname = surface.name

  -- Debug: always announce the sweep is running so the player can confirm
  -- it is firing even when nothing is found.
  for _, player in pairs(game.connected_players) do
    player.print(("[treez] Foreign-tree sweep running on surface: %s"):format(sname))
  end

  -- Collect all entity-ghosts (any type, any mod).
  local ghosts = surface.find_entities_filtered{ type = "entity-ghost" }
  if #ghosts == 0 then
    for _, player in pairs(game.connected_players) do
      player.print("[treez] Foreign-tree sweep: no ghosts found, nothing to do.")
    end
    return
  end

  for _, player in pairs(game.connected_players) do
    player.print(("[treez] Foreign-tree sweep: found %d ghost(s), scanning for blocking trees..."):format(#ghosts))
  end

  -- Helper: record every tile covered by a bounding box into a key set.
  -- Tiles are keyed as math.floor(x) * 65536 + math.floor(y).
  -- Rail ghosts (and other large entities) have their center on one tile but
  -- their bounding box spans several tiles, so keying only by center position
  -- misses trees that sit under the rail footprint but not at its center.
  local function mark_bb_tiles(bb, tbl)
    local x1 = math.floor(bb.left_top.x)
    local y1 = math.floor(bb.left_top.y)
    local x2 = math.floor(bb.right_bottom.x - 0.001)  -- avoid counting the edge tile when bb ends exactly on a grid line
    local y2 = math.floor(bb.right_bottom.y - 0.001)
    for ty = y1, y2 do
      for tx = x1, x2 do
        tbl[tx * 65536 + ty] = true
      end
    end
  end

  -- Build a set of every tile covered by any ghost's bounding box.
  local ghost_tiles = {}
  for _, ghost in ipairs(ghosts) do
    if ghost.valid then
      mark_bb_tiles(ghost.bounding_box, ghost_tiles)
    end
  end

  -- Find all trees/plants and check whether any tile of their bounding box
  -- overlaps a ghost-covered tile.
  local trees = surface.find_entities_filtered{ type = { "tree", "plant" } }
  local marked = 0
  for _, tree in ipairs(trees) do
    if tree.valid then
      -- Exclude treez's own growing stages — they are intentional occupants.
      local tname = tree.name
      if not tname:find("^treez%-") then
        if not tree.to_be_deconstructed() then
          -- Check every tile the tree covers, not just its center.
          local bb  = tree.bounding_box
          local x1  = math.floor(bb.left_top.x)
          local y1  = math.floor(bb.left_top.y)
          local x2  = math.floor(bb.right_bottom.x - 0.001)
          local y2  = math.floor(bb.right_bottom.y - 0.001)
          local hit = false
          for ty = y1, y2 do
            for tx = x1, x2 do
              if ghost_tiles[tx * 65536 + ty] then
                hit = true
                break
              end
            end
            if hit then break end
          end
          if hit then
            tree.order_deconstruction(game.forces["player"])
            marked = marked + 1
            local pos  = tree.position
            local link = "[gps=" .. math.floor(pos.x) .. "," .. math.floor(pos.y) .. "," .. sname .. "]"
            for _, player in pairs(game.connected_players) do
              player.print(("[treez] Marked for deconstruction: %s \"%s\" at %s"):format(link, tname, sname))
            end
          end
        end
      end
    end
  end

  if marked > 0 then
    for _, player in pairs(game.connected_players) do
      player.print(("[treez] Foreign-tree sweep complete: %d tree(s) marked for deconstruction."):format(marked))
    end
    log(("[treez] Foreign-tree ghost sweep marked %d tree(s) for deconstruction (blocking ghost tiles)."):format(marked))
  else
    for _, player in pairs(game.connected_players) do
      player.print("[treez] Foreign-tree sweep complete: no blocking trees found.")
    end
  end
end

-- Prunes stale waiting-seed entries from the growth queue for one surface. Every
-- queued seed is created alongside a treez-seed-waiting marker; if the marker is
-- gone the seed was removed by something that did not raise a mined event (e.g. a
-- blueprint mod's script destroy), so the entry would otherwise linger and later
-- be grown into a phantom tree. try_dequeue_tree guards against this at grow time
-- as well; this prune clears parked phantoms that are never drawn (e.g. while the
-- active-tree cap is full). The queue is rebuilt once, in O(n), and only swapped
-- in when something was actually removed.
local function prune_growth_queue_for_surface(surface)
  if not (surface and surface.valid) then return end
  local idx     = surface.index
  local kept    = {}
  local removed = 0
  for _, e in ipairs(storage.growth_queue) do
    if e.surface_index ~= idx then
      kept[#kept + 1] = e
    elseif surface.find_entities_filtered{
             name = SEED_WAITING_NAME, position = e.position, radius = 0.2 }[1] then
      kept[#kept + 1] = e
    else
      removed = removed + 1
    end
  end
  if removed > 0 then
    storage.growth_queue = kept
    log(("[treez] Growth-queue prune dropped %d stale waiting-seed(s) with no marker."):format(removed))
  end
end

-- Runs the seed-ghost sweep once per day/night cycle on every surface, at each
-- surface's own day->night transition (dusk). Surfaces have independent cycles,
-- so each one's previous night sample is tracked separately in
-- storage.seed_sweep_night_by_surface, keyed by surface index; each surface
-- therefore fires exactly once per cycle regardless of differing day lengths.
-- Space platforms are skipped (seed sites are rejected there and no trees grow
-- on them). Iterating by index dedupes naturally if a surface is visited twice
-- in one pass. A nil default is fine: the first dusk after load on a surface
-- triggers one sweep there.
local function seed_ghost_sweep_tick()
  local flags = storage.seed_sweep_night_by_surface
  if type(flags) ~= "table" then
    flags = {}
    storage.seed_sweep_night_by_surface = flags
  end
  for _, surface in pairs(game.surfaces) do
    if surface.valid and surface.platform == nil then
      local idx   = surface.index
      local night = is_night(surface)
      if night and not flags[idx] then
        run_seed_ghost_collision_sweep(surface)
        if foreign_tree_sweep_enabled then
          run_foreign_tree_ghost_sweep(surface)
        end
        prune_growth_queue_for_surface(surface)
      end
      flags[idx] = night
    end
  end
end

-- ============================================================
-- Tick handlers
-- ============================================================

script.on_nth_tick(CRYSTAL_CHECK_INTERVAL, function()
  process_crystals()
  run_ab_decay_pass()
  rain_seeding_tick()
  seed_ghost_sweep_tick()
end)

-- Pellet pollution is emitted on a coarser cadence so the (possibly large) queue
-- is only walked once per POLLUTION_EMIT_INTERVAL ticks instead of every 60.  The
-- per-pellet amount scales with the interval, so total pollution/min is unchanged.
script.on_nth_tick(POLLUTION_EMIT_INTERVAL, function()
  emit_crystal_pollution(game.surfaces[1])
end)

-- Restorative Rains: spend accumulated credits every 20 seconds during rain.
-- Separate from the crystal processing tick so it can run at its own cadence.
script.on_nth_tick(RAIN_NITRATE_INTERVAL, function()
  restorative_rains_tick()
end)

if TREE_GROWTH_ENABLED then
  script.on_nth_tick(GROWTH_CHECK_INTERVAL, function()
    process_growing_trees()
  end)
end

-- ============================================================
-- Growth cap calculation
-- ============================================================
-- Formula: sapling_part + cloud_part = total simultaneous-tree cap
--   sapling_part : starts at 2, doubles per Sapling Growth level  (2→4→8→…→128)
--   cloud_part   : starts at 0, then 4/8/16/32/64/128 per Cloud Seeding level
--                  always 0 when Dynamic Rain is not installed
--                  Note: Cloud Seeding also boosts rain seeds per chunk (requires
--                  Arboreal Aromatics): floor(levels/2)+1  →  1/1/2/2/3/3/4 seeds.
-- Authoritative source of truth — called from on_research_finished,
-- on_init, and on_configuration_changed so the cap never drifts.

-- Syncs the Pellet Placer shortcut availability from actual research state.
-- Called from on_init and on_configuration_changed so saves that load with
-- soil-crystal already researched show the shortcut correctly.
-- technology_to_unlock handles brand-new games; this covers the rest.
local function sync_placer_shortcut()
  local force = game.forces["player"]
  if not force then return end
  local researched = force.technologies["soil-crystal"]
    and force.technologies["soil-crystal"].researched
  for _, player in pairs(force.players) do
    player.set_shortcut_available("crystal-placer", researched == true)
  end
end

-- Syncs the Tree Seeder shortcut availability from actual research state.
-- Mirrors sync_placer_shortcut: technology_to_unlock handles new games but
-- does not retroactively grey-out the shortcut on existing saves.  This
-- function ensures the shortcut is unavailable until treez-tree-seeder is
-- researched, on every load and on research completion.
local function sync_seeder_shortcut()
  local force = game.forces["player"]
  if not force then return end
  local researched = force.technologies["treez-tree-seeder"]
    and force.technologies["treez-tree-seeder"].researched
  for _, player in pairs(force.players) do
    player.set_shortcut_available("tree-seeder", researched == true)
  end
end

local function recalculate_growth_cap()
  local force = game.forces["player"]

  -- Sapling Growth: 2^(levels+2), starting at 4 with no research.
  -- 0=4, 1=8, 2=16, 3=32, 4=64, 5=128, 6=256
  local sapling_count = 0
  if force then
    for i = 1, 6 do
      local tech = force.technologies["treez-sapling-growth-" .. i]
      if tech and tech.researched then sapling_count = sapling_count + 1 end
    end
  end
  local sapling_cap = 2 ^ (sapling_count + 2)

  -- Cloud Seeding: 0 if DR absent or no levels researched,
  -- otherwise 2^(levels+1) → 4, 8, 16, 32, 64, 128
  local cloud_cap = 0
  if DYNAMIC_RAIN_ACTIVE and force then
    local cloud_count = 0
    for i = 1, 6 do
      local tech = force.technologies["treez-cloudseeding-" .. i]
      if tech and tech.researched then cloud_count = cloud_count + 1 end
    end
    if cloud_count > 0 then
      cloud_cap = 2 ^ (cloud_count + 1)
    end
  end

  local cap = sapling_cap + cloud_cap
  tree_growth_max_active = cap
  storage.growth_cap     = cap   -- persisted so on_load can restore without re-reading research
  settings.global["treez-tree-growth-max-active"].value = cap
  log(("[treez] recalculate_growth_cap: sapling=%d cloud=%d total=%d"):format(
    sapling_cap, cloud_cap, cap))
end

-- ============================================================
-- Research handlers
-- ============================================================

script.on_event(defines.events.on_research_finished, function(event)
  local name = event.research.name
  if name == "soil-crystal" then
    -- Explicitly enable the Pellet Placer shortcut for all players on this force.
    -- technology_to_unlock handles new games; this covers existing saves and
    -- mid-session research completion.
    for _, player in pairs(event.research.force.players) do
      player.set_shortcut_available("crystal-placer", true)
    end
  elseif name == "soil-crystal-colored-probability" then
    storage.colored_bonus_count = (storage.colored_bonus_count or 0) + 1
  elseif name == "soil-crystal-colored-adjacent" then
    storage.colored_adjacent_unlocked = true
  elseif name == "soil-crystal-catalyst" then
    storage.colored_unlocked = true
  elseif name == "soil-crystal-catalyst-abundant-1"
      or name == "soil-crystal-catalyst-abundant-2" then
    storage.colored_bonus_count = (storage.colored_bonus_count or 0) + 1
  elseif name == "soil-crystal-catalyst-reactions-1" then
    storage.catalyst_chain_count = 2
  elseif name == "soil-crystal-catalyst-reactions-2" then
    storage.catalyst_chain_count = 3
  elseif name == "soil-crystal-catalyst-reactions-3" then
    storage.catalyst_chain_count = 4
  elseif name == "soil-crystal-catalyst-abundant-3" then
    storage.colored_bonus_count = (storage.colored_bonus_count or 0) + 1
  elseif name == "soil-crystal-white-pollution-1"
      or name == "soil-crystal-white-pollution-2"
      or name == "soil-crystal-white-pollution-3"
      or name == "soil-crystal-white-pollution-4"
      or name == "soil-crystal-white-pollution-5" then
    -- Each level reduces white pellet emission by 1 pollution/min.
    storage.white_pollution_reduction = (storage.white_pollution_reduction or 0) + 1
  elseif name == "treez-tree-seeder" then
    -- Enable the Tree Seeder shortcut for all players on this force.
    -- technology_to_unlock handles new games; this covers existing saves and
    -- mid-session research completion.
    for _, player in pairs(event.research.force.players) do
      player.set_shortcut_available("tree-seeder", true)
    end
  elseif name == "treez-sapling-growth-1"
      or name == "treez-sapling-growth-2"
      or name == "treez-sapling-growth-3"
      or name == "treez-sapling-growth-4"
      or name == "treez-sapling-growth-5"
      or name == "treez-sapling-growth-6"
      or name == "treez-cloudseeding-1"
      or name == "treez-cloudseeding-2"
      or name == "treez-cloudseeding-3"
      or name == "treez-cloudseeding-4"
      or name == "treez-cloudseeding-5"
      or name == "treez-cloudseeding-6" then
    -- Derive the new cap from actual research state rather than incrementally
    -- doubling, so on_research_finished always converges to the correct value.
    recalculate_growth_cap()
    log(("[treez] Research '%s' completed: max active trees now %d"):format(
      name, tree_growth_max_active))
  end
end)

script.on_event(defines.events.on_runtime_mod_setting_changed, function(event)
  local s = event.setting
  if     s == "treez-crystal-delay-nights"           then crystal_delay_nights           = settings.global[s].value
  elseif s == "treez-crystal-variance-nights"        then crystal_variance_nights        = settings.global[s].value
  elseif s == "treez-crystal-batch-size"             then crystal_batch_size             = settings.global[s].value
  elseif s == "treez-crystal-night-only"             then crystal_night_only             = settings.global[s].value
  elseif s == "treez-crystal-overflow-threshold"     then crystal_overflow_threshold     = settings.global[s].value
  elseif s == "treez-crystal-overflow-percent"       then crystal_overflow_percent       = settings.global[s].value
  elseif s == "treez-tree-growth-speed"              then apply_growth_preset(settings.global[s].value)
  elseif s == "treez-tree-growth-variability"        then
    tree_growth_variability = VARIABILITY_MAP[settings.global[s].value] or 0.0
  elseif s == "treez-tree-growth-max-active"         then tree_growth_max_active         = settings.global[s].value
  elseif s == "treez-tree-growth-day-only"           then tree_growth_day_only           = settings.global[s].value
  elseif s == "treez-tree-growth-pollution-delay"    then tree_growth_pollution_delay    = settings.global[s].value
  elseif s == "treez-tree-growth-enrich-soil"        then tree_growth_enrich_soil        = settings.global[s].value
  elseif s == "treez-fertilizer-trample"             then crystal_trample                = settings.global[s].value
  elseif s == "treez-trample-player-radius"          then crystal_trample_player_radius  = settings.global[s].value
  elseif s == "treez-randomize-upgrades"             then randomize_upgrades             = settings.global[s].value
  elseif s == "treez-foreign-tree-sweep"             then foreign_tree_sweep_enabled     = settings.global[s].value
  elseif s == "treez-crystal-colored-chance"         then crystal_colored_chance         = settings.global[s].value
  elseif s == "treez-crystal-pollution-rate"          then crystal_pollution_rate           = settings.global[s].value
  elseif s == "treez-rain-growth-boost" and DYNAMIC_RAIN_ACTIVE then
    tree_rain_growth_boost = settings.global[s].value
  elseif s == "treez-rain-seed-enabled" and DYNAMIC_RAIN_ACTIVE then
    rain_seed_enabled = settings.global[s].value
  elseif s == "treez-rain-seed-debug" and DYNAMIC_RAIN_ACTIVE then
    rain_seed_debug = settings.global[s].value
  end
end)

-- ============================================================
-- System 3: Placement rejection on hard tiles and rail
-- ============================================================

local function is_on_rail(entity)
  local nearby = entity.surface.find_entities_filtered{
    type     = RAIL_ENTITY_TYPES,
    position = entity.position,
    radius   = 1.5,
  }
  return #nearby > 0
end

local function reject_crystal_if_hard_tile(entity, player, robot)
  if not entity.valid then return false end
  if is_on_rail(entity) then
    local pos = entity.position
    entity.destroy({ raise_destroy = false })
    if player then
      player.insert({ name = "soil-crystal", count = 1 })
      player.create_local_flying_text({ text = { "treez.crystal-blocked-hard-tile" }, position = pos })
    elseif robot then
      local inv = robot.get_inventory(defines.inventory.robot_cargo)
      if inv then inv.insert({ name = "soil-crystal", count = 1 }) end
    end
    return true
  end
  if not is_hard_tile(entity.surface.get_tile(entity.position).name) then return false end
  local pos = entity.position
  entity.destroy({ raise_destroy = false })
  if player then
    player.insert({ name = "soil-crystal", count = 1 })
    player.create_local_flying_text({ text = { "treez.crystal-blocked-hard-tile" }, position = pos })
  elseif robot then
    local inv = robot.get_inventory(defines.inventory.robot_cargo)
    if inv then inv.insert({ name = "soil-crystal", count = 1 }) end
  end
  return true
end

-- ============================================================
-- System 1: Seed-site swap
-- ============================================================

local function handle_site(entity)
  if not entity.valid then return end
  local force    = entity.force
  local position = entity.position
  local surface  = entity.surface

  -- Debug counters (shown by /treez, reset with /treez reset)
  storage.dbg = storage.dbg or {}
  storage.dbg.calls = (storage.dbg.calls or 0) + 1

  if not TREE_ENTITY then
    storage.dbg.no_entity = (storage.dbg.no_entity or 0) + 1
    entity.destroy({ raise_destroy = false })
    return
  end
  if surface.platform ~= nil then
    storage.dbg.platform = (storage.dbg.platform or 0) + 1
    entity.destroy({ raise_destroy = false })
    return
  end

  -- Destroy the seed site FIRST so its collision box does not interfere with
  -- the can_place_entity check for the growth-stage proto.
  entity.destroy({ raise_destroy = false })

  -- Determine the biome-appropriate species for this tile.
  -- Guard against nil/false returns (e.g. TREE_ENTITY not set, no trees in range).
  local species = pick_species_at(surface, position)
  if not species or species == "" then species = TREE_ENTITY end
  if not species or species == "" then
    storage.dbg.no_species = (storage.dbg.no_species or 0) + 1
    return
  end

  -- Respect pre-placed ghosts: the player has explicitly designated this tile
  -- for something else, so seed planting must not clobber it.
  -- (can_place_entity uses entity collision layers and ignores the ghost layer,
  -- so this check must be done explicitly.  The seed entity itself was already
  -- destroyed above, so only genuine foreign ghosts remain here.)
  -- Footprint-based: search the whole tile, not a centre-based radius, so a
  -- multi-tile ghost covering this tile but centred elsewhere is still caught
  -- (otherwise the real tree/plant created below would build over and delete it).
  local gtx, gty = math.floor(position.x), math.floor(position.y)
  if surface.find_entities_filtered{ area = { { gtx, gty }, { gtx + 1, gty + 1 } }, type = "entity-ghost" }[1] then
    return
  end

  if not TREE_GROWTH_ENABLED or tree_growth_bypass then
    if surface.can_place_entity({ force = force, name = species, position = position }) then
      surface.create_entity({ force = force, name = species, position = position, raise_built = true })
    end
    storage.dbg.bypass = (storage.dbg.bypass or 0) + 1
    return
  end

  local plant_name = growth_proto_name(1, species)

  if storage.growing_tree_count < tree_growth_max_active then
    local new_entity = surface.can_place_entity({ force = force, name = plant_name, position = position })
      and surface.create_entity({ force = force, name = plant_name, position = position, raise_built = true })
    if new_entity then
      storage.growing_trees[#storage.growing_trees + 1] = {
        entity  = new_entity,
        stage   = 1,
        fire_at = game.tick + growth_delay_for(surface),
        species = species,
      }
      storage.growing_tree_count = storage.growing_tree_count + 1
      storage.dbg.grew = (storage.dbg.grew or 0) + 1
      return
    end
    storage.dbg.stage1_fail = (storage.dbg.stage1_fail or 0) + 1
    -- Stage-1 placement blocked — fall through to waiting queue.
  else
    storage.dbg.cap_reached = (storage.dbg.cap_reached or 0) + 1
  end

  -- Cap reached, or stage-1 blocked: park this seed and retry when space opens.
  surface.create_entity({
    force = force, name = SEED_WAITING_NAME,
    position = position, raise_built = false,
  })
  storage.growth_queue[#storage.growth_queue + 1] = {
    surface_index = surface.index,
    position      = { x = position.x, y = position.y },
    force_name    = force.name,
    species       = species,
  }
  storage.dbg.queued = (storage.dbg.queued or 0) + 1
end

-- ============================================================
-- ============================================================
-- System 4: Ghost conflict resolution helpers
-- (defined here so they are in scope for the combined on_built_entity handler)
-- ============================================================

local function is_crystal_entity_name(name)
  for _, n in ipairs(CRYSTAL_NAMES) do
    if n == name then return true end
  end
  return false
end

local function clear_crystal_ghosts_at(surface, pos)
  local ghosts = surface.find_entities_filtered{
    type     = "entity-ghost",
    position = pos,
    radius   = 0.6,
  }
  for _, g in ipairs(ghosts) do
    if g.valid and is_crystal_entity_name(g.ghost_name) then
      g.destroy({ raise_destroy = false })
    end
  end
end

local function resolve_crystal_ghost_conflict(event)
  local entity = event.entity
  if not (entity and entity.valid) then return end
  if not is_crystal_entity_name(entity.ghost_name) then return end

  local ghosts = entity.surface.find_entities_filtered{
    type     = "entity-ghost",
    position = entity.position,
    radius   = 0.6,
  }
  for _, g in ipairs(ghosts) do
    if g.valid and g ~= entity then
      entity.destroy({ raise_destroy = false })
      return
    end
  end
end

-- ============================================================
-- Combined on_built_entity  (single registration — multiple calls replace
-- each other in Factorio, so everything must live in one handler)
-- ============================================================
script.on_event(defines.events.on_built_entity, function(event)
  local entity = event.entity
  if not (entity and entity.valid) then return end

  -- Debug counters
  storage.dbg = storage.dbg or {}
  storage.dbg.last_built  = entity.name
  storage.dbg.total_built = (storage.dbg.total_built or 0) + 1

  local name   = entity.name
  local player = game.players[event.player_index]

  -- Ghost conflict resolution for crystal ghosts; also block seed ghosts on resources.
  if entity.type == "entity-ghost" then
    -- Prevent blueprint seed ghosts from being placed on natural resource patches.
    -- Destroy the ghost and refund the item so robots never try to fulfill it.
    if entity.ghost_name == SITE_NAME then
      if entity.surface.find_entities_filtered{
          position = entity.position, radius = 0.5, type = "resource" }[1] then
        local pos = entity.position
        entity.destroy({ raise_destroy = false })
        if player then
          player.insert({ name = "tree-seed", count = 1 })
          player.create_local_flying_text({ text = { "treez.blocked-resource" }, position = pos })
        end
        return
      end
    end
    resolve_crystal_ghost_conflict(event)
    return
  end

  -- Tree seed site
  if name == SITE_NAME then
    if reject_if_se_blocked(entity, "tree-seed", player, nil) then
      storage.dbg.se_blocked = (storage.dbg.se_blocked or 0) + 1
      return
    end
    if reject_if_on_resource(entity, "tree-seed", player, nil) then return end
    storage.dbg.on_built_fired = (storage.dbg.on_built_fired or 0) + 1
    handle_site(entity)
    return
  end

  -- Crystal site
  if name == CRYSTAL_SITE_NAME then
    if reject_if_se_blocked(entity, "soil-crystal", player, nil) then return end
    local rejected = reject_crystal_if_hard_tile(entity, player, nil)
    if not rejected and entity.valid then
      local force = (player and player.force) or entity.force
      if not maybe_spawn_colored(entity, force) then
        enqueue_crystal(entity, false)
      end
    end
    return
  end

  -- Primitive (black) crystal site — enqueue directly, no catalyst spawn.
  if name == CRYSTAL_BLACK_SITE_NAME then
    if reject_if_se_blocked(entity, "soil-crystal-black", player, nil) then return end
    local rejected = reject_crystal_if_hard_tile(entity, player, nil)
    if not rejected and entity.valid then
      enqueue_crystal(entity, false)
    end
  end
end)

-- ============================================================
-- Combined on_robot_built_entity  (same reason — single registration)
-- ============================================================
script.on_event(defines.events.on_robot_built_entity, function(event)
  local entity = event.entity
  if not (entity and entity.valid) then return end

  local name = entity.name

  -- Ghost conflict resolution for crystal ghosts
  if entity.type == "entity-ghost" then
    resolve_crystal_ghost_conflict(event)
    return
  end

  -- Tree seed site
  if name == SITE_NAME then
    if reject_if_se_blocked(entity, "tree-seed", nil, event.robot) then return end
    if reject_if_on_resource(entity, "tree-seed", nil, event.robot) then return end
    handle_site(entity)
    return
  end

  -- Crystal site
  if name == CRYSTAL_SITE_NAME then
    if reject_if_se_blocked(entity, "soil-crystal", nil, event.robot) then return end
    local rejected = reject_crystal_if_hard_tile(entity, nil, event.robot)
    if not rejected and entity.valid then
      if not maybe_spawn_colored(entity, event.robot.force) then
        enqueue_crystal(entity, false)
      end
    end
    return
  end

  -- Primitive (black) crystal site — enqueue directly, no catalyst spawn.
  if name == CRYSTAL_BLACK_SITE_NAME then
    if reject_if_se_blocked(entity, "soil-crystal-black", nil, event.robot) then return end
    local rejected = reject_crystal_if_hard_tile(entity, nil, event.robot)
    if not rejected and entity.valid then
      enqueue_crystal(entity, false)
    end
  end
end)

-- ============================================================
-- System 8: Script-raised build / revive compatibility
-- ============================================================
-- Some mods place entities by reviving ghosts via entity.revive() and then
-- raising script_raised_revive, rather than triggering on_built_entity.
-- Blueprint Shotgun is a known example: it revives blueprint ghosts in-flight
-- and calls script.raise_script_revive{entity=entity}.
-- Other mods may call script.raise_built{entity=entity} instead.
-- Neither path fires on_built_entity or on_robot_built_entity, so without
-- this handler those entities would sit on the map unprocessed.
--
-- No player or robot is available here; reject_if_se_blocked /
-- reject_crystal_if_hard_tile handle nil gracefully (they destroy the entity
-- without attempting an item return, which is acceptable since the calling
-- mod already consumed the item before the revive).

local function handle_script_placed_entity(entity)
  if not (entity and entity.valid) then return end
  local name = entity.name

  if name == SITE_NAME then
    if reject_if_se_blocked(entity, "tree-seed", nil, nil) then return end
    if reject_if_on_resource(entity, "tree-seed", nil, nil) then return end
    handle_site(entity)
    return
  end

  if name == CRYSTAL_SITE_NAME then
    if reject_if_se_blocked(entity, "soil-crystal", nil, nil) then return end
    local rejected = reject_crystal_if_hard_tile(entity, nil, nil)
    if not rejected and entity.valid then
      if not maybe_spawn_colored(entity, entity.force) then
        enqueue_crystal(entity, false)
      end
    end
    return
  end

  -- Primitive (black) crystal site — enqueue directly, no catalyst spawn.
  if name == CRYSTAL_BLACK_SITE_NAME then
    if reject_if_se_blocked(entity, "soil-crystal-black", nil, nil) then return end
    local rejected = reject_crystal_if_hard_tile(entity, nil, nil)
    if not rejected and entity.valid then
      enqueue_crystal(entity, false)
    end
  end
end

-- Filter covering all entity names treez cares about for placement.
local SCRIPT_PLACED_FILTER = {
  { filter = "name", name = SITE_NAME },
  { filter = "name", name = CRYSTAL_SITE_NAME,       mode = "or" },
  { filter = "name", name = CRYSTAL_BLACK_SITE_NAME, mode = "or" },
}

-- script_raised_revive: fired by mods that revive ghosts via entity.revive()
-- (e.g. Blueprint Shotgun, some construction mods).
script.on_event(defines.events.script_raised_revive, function(event)
  handle_script_placed_entity(event.entity)
end, SCRIPT_PLACED_FILTER)

-- script_raised_built: fired by mods that create entities via surface.create_entity
-- and explicitly raise the event (e.g. some automation or blueprint mods).
script.on_event(defines.events.script_raised_built, function(event)
  handle_script_placed_entity(event.entity)
end, SCRIPT_PLACED_FILTER)

-- ============================================================
-- System 3: Tile-placement cleanup
-- ============================================================

local function destroy_crystals_under_tiles(surface, tiles)
  for _, tile_data in pairs(tiles) do
    local area = {
      left_top     = { tile_data.position.x,     tile_data.position.y     },
      right_bottom = { tile_data.position.x + 1, tile_data.position.y + 1 },
    }
    local crystals = surface.find_entities_filtered{ name = CRYSTAL_NAMES, area = area }
    for _, crystal in pairs(crystals) do
      if crystal.valid then crystal.destroy({ raise_destroy = false }) end
    end
  end
end

script.on_event(defines.events.on_player_built_tile, function(event)
  destroy_crystals_under_tiles(game.surfaces[event.surface_index], event.tiles)
end)

script.on_event(defines.events.on_robot_built_tile, function(event)
  destroy_crystals_under_tiles(game.surfaces[event.surface_index], event.tiles)
end)

-- ============================================================
-- System 4: Ghost conflict resolution — on_pre_build
-- ============================================================
-- on_pre_build fires before the player's placement; sweeps crystal ghosts
-- off the target tile so the incoming entity lands cleanly.
-- The ghost conflict functions (is_crystal_entity_name, clear_crystal_ghosts_at,
-- resolve_crystal_ghost_conflict) are defined before the combined on_built_entity
-- handler above so they are in scope there.
script.on_event(defines.events.on_pre_build, function(event)
  local player = game.players[event.player_index]
  if not (player and player.valid) then return end

  -- Skip if the player is placing a soil-crystal entity themselves.
  local cg = player.cursor_ghost
  if cg and is_crystal_entity_name(cg.name) then return end
  local cs = player.cursor_stack
  if cs and cs.valid_for_read then
    local pr = cs.prototype and cs.prototype.place_result
    if pr and is_crystal_entity_name(pr.name) then return end
  end

  clear_crystal_ghosts_at(player.surface, event.position)

  -- tree-seed-site must keep "player-creation" so it stays blueprintable, but
  -- that flag makes force-build block on it with "entity in the way" instead of
  -- marking it for deconstruction.  We compensate here: on any shift-build
  -- (force or super-force) we find seed-sites near the target position and mark
  -- them for deconstruction ourselves so the build proceeds normally.
  if event.shift_build then
    local sites = player.surface.find_entities_filtered{
      position = event.position,
      radius   = 1.0,
      name     = SITE_NAME,
    }
    for _, site in ipairs(sites) do
      if site.valid then
        site.order_deconstruction(player.force, player)
      end
    end
  end
end)





local VEHICLE_TRAMPLE_RADIUS = {
  car        = 1.5,
  tank       = 2.0,
  spidertron = 3.0,
}
local DEFAULT_VEHICLE_RADIUS = 1.5

-- A) Player on foot / player in vehicle
-- Robustness notes:
--   • crystal_trample is re-read from settings each call to avoid stale cache.
--   • CRYSTAL_NAMES is iterated one name at a time; passing a name table to
--     find_entities_filtered behaves inconsistently across Factorio 2.x builds.
--   • area box is used instead of position+radius; both should work but area
--     is simpler for the engine to resolve against small collision boxes.
local function trample_at(surface, pos, radius)
  local box = {
    { pos.x - radius, pos.y - radius },
    { pos.x + radius, pos.y + radius },
  }
  for _, crystal_name in ipairs(CRYSTAL_NAMES) do
    local found = surface.find_entities_filtered{ name = crystal_name, area = box }
    for _, crystal in pairs(found) do
      if crystal.valid then
        crystal.destroy({ raise_destroy = false })
      end
    end
  end
end

script.on_event(defines.events.on_player_changed_position, function(event)
  if not settings.global["treez-fertilizer-trample"].value then return end
  local player = game.players[event.player_index]
  if not (player and player.valid) then return end
  if not player.character then return end

  local vehicle = player.vehicle
  if vehicle and vehicle.valid then
    trample_at(vehicle.surface, vehicle.position,
               VEHICLE_TRAMPLE_RADIUS[vehicle.name] or DEFAULT_VEHICLE_RADIUS)
  else
    trample_at(player.surface, player.position, crystal_trample_player_radius)
  end
end)

-- B) Biter / any damage source
script.on_event(defines.events.on_entity_damaged, function(event)
  if not crystal_trample then return end
  local entity = event.entity
  if entity.valid then
    entity.destroy({ raise_destroy = false })
  end
end, CRYSTAL_EVENT_FILTERS)

-- ============================================================
-- Waiting-seed: mining / deconstruction
-- ============================================================
-- When a player or robot mines a treez-seed-waiting marker, cancel the
-- matching growth-queue entry.  The seed item is returned automatically
-- by the minable.result field on the entity prototype.
local _waiting_filter = { { filter = "name", name = SEED_WAITING_NAME } }

-- C) Player manually mining — unified handler.
--
-- Bug fix (v1.15.47): Factorio's script.on_event replaces any prior handler
-- for the same event on each call.  The original code registered three
-- separate on_player_mined_entity handlers (crystal trample pickup
-- prevention, tree research tracker, waiting-seed queue cleanup) so only
-- the last one (waiting-seed) was ever active.  The research tracker never
-- fired, meaning the first technology could never unlock by mining trees.
-- This also broke Alien Biomes support, where tree-01 may not exist and the
-- Lua tracker is the only unlock path.
--
-- All three cases are now handled in a single registration.  Event filters
-- are checked manually inside the handler instead of being passed to
-- on_event, which was the root cause of the silent overwrites.
local TREES_TO_RESEARCH = 1

script.on_event(defines.events.on_player_mined_entity, function(event)
  local entity = event.entity
  local name   = entity.name

  -- Case 1: Crystal trample — clear the item buffer so the player cannot
  -- pick up a crystal they walked over / deliberately mined while trample
  -- mode is active.
  if name == CRYSTAL_SITE_NAME
  or name == CRYSTAL_COLORED_SITE_NAME
  or name == CRYSTAL_BLACK_SITE_NAME then
    if crystal_trample and event.buffer then event.buffer.clear() end
    return
  end

  -- Case 2: Waiting-seed marker — cancel the queued growth entry.
  if name == SEED_WAITING_NAME then
    remove_from_growth_queue(entity.surface, entity.position)
    return
  end

  -- Case 3: Natural tree — advance the tree-growth research counter.
  -- Works for vanilla trees and Alien Biomes trees alike; treez-managed
  -- growth-stage entities (prefixed "treez-") are excluded.
  if entity.type == "tree" and not name:find("^treez%-") then
    local player = game.players[event.player_index]
    if not (player and player.valid) then return end
    local force = player.force
    local tech  = force.technologies[TREE_GROWTH_TECH]
    if not tech or tech.researched then return end

    local key = force.index
    storage.wood_collected[key] = (storage.wood_collected[key] or 0) + 1

    if storage.wood_collected[key] >= TREES_TO_RESEARCH then
      tech.researched = true
      for _, p in pairs(force.players) do
        p.print({ "treez.tree-growth-researched" })
      end
    end
  end
end)

script.on_event(defines.events.on_robot_mined_entity, function(event)
  remove_from_growth_queue(event.entity.surface, event.entity.position)
end, _waiting_filter)

-- ============================================================
-- Waiting-seed: blueprint normalisation
-- ============================================================
-- Blueprinting a treez-seed-waiting entity would produce a ghost that
-- robots cannot fulfil correctly (the entity is created internally, not
-- via a player-placeable item).  Swap any such entries for tree-seed-site
-- so that placing the blueprint runs the normal seeding flow.
script.on_event(defines.events.on_player_setup_blueprint, function(event)
  local player = game.players[event.player_index]
  if not (player and player.valid) then return end
  local bp = player.blueprint_to_setup
  if not (bp and bp.valid_for_read) then return end
  local entities = bp.get_blueprint_entities()
  if not entities then return end
  local changed = false
  for _, ent in ipairs(entities) do
    if ent.name == SEED_WAITING_NAME then
      ent.name  = SITE_NAME
      changed   = true
    end
  end
  if changed then bp.set_blueprint_entities(entities) end
end)

script.on_init(function()
  storage.tree               = {}
  storage.crystal_queue           = {}
  storage.colored_bonus_count       = 0
  storage.colored_adjacent_unlocked   = false
  storage.white_pollution_reduction   = 0
  storage.colored_unlocked            = false
  storage.catalyst_chain_count        = 1
  storage.growing_trees      = {}
  storage.growing_tree_count = 0
  storage.growth_queue       = {}
  storage.trees_cut          = {}   -- kept for migration; superseded by wood_collected
  storage.wood_collected     = {}
  storage.native_species     = {}
  storage.dr_rain_was_active   = false   -- System 7: Dynamic Rain integration
  storage.dr_seeded_this_storm = {}      -- System 7: chunks seeded in the current storm
  storage.dr_rain_chunks       = {}      -- System 7: chunks cleaned any amount this storm
  storage.dr_rain_credits      = 0       -- System 7: Restorative Rains credit accumulator
  storage.growth_cap           = 1       -- authoritative computed cap (set properly by recalculate_growth_cap below)
  -- New games start with a cap of 1 (no research done yet).
  -- recalculate_growth_cap reads actual research state, so it safely
  -- returns 1 here and stays in sync on any future load.
  recalculate_growth_cap()
  sync_placer_shortcut()
  sync_seeder_shortcut()
  build_native_species_map()   -- flagged chunks for future expansion mechanic
  build_hard_tiles_set()
  build_ab_tile_tables()
  build_vanilla_random_pools()
  dr_native_event_active = setup_rain_event_listener()
end)

-- Re-register the dynamic-rain native event handler on every game load.
-- script.on_event registrations are not persisted; they must be re-established
-- each time the engine loads a save.  on_init handles the very first load;
-- on_load handles all subsequent loads.
script.on_load(function()
  -- Restore the computed growth cap from storage.  This is authoritative over
  -- the setting value read at module load (line above), which can be stale when
  -- the player loads a save on the same mod version without triggering
  -- on_configuration_changed.
  if storage.growth_cap then
    tree_growth_max_active = storage.growth_cap
  end
  dr_native_event_active = setup_rain_event_listener()
end)

script.on_configuration_changed(function()
  if not storage.tree               then storage.tree               = {} end
  if not storage.crystal_queue           then storage.crystal_queue           = {} end
  if not storage.colored_bonus_count    then storage.colored_bonus_count    = 0 end
  if storage.colored_adjacent_unlocked == nil then storage.colored_adjacent_unlocked = false end
  if not storage.white_pollution_reduction   then storage.white_pollution_reduction   = 0 end
  if storage.colored_unlocked == nil         then storage.colored_unlocked            = false end
  if not storage.catalyst_chain_count        then storage.catalyst_chain_count        = 1 end
  if not storage.growing_trees      then storage.growing_trees      = {} end
  if not storage.growth_queue       then storage.growth_queue       = {} end
  if not storage.growing_tree_count then storage.growing_tree_count = #storage.growing_trees end
  -- Migrate queue entries from before 1.13.0 (no rare field), and (re)compute the
  -- due-bound from the loaded queue so the scan-skip guard is valid after load.
  storage.crystal_min_fire = nil
  for _, entry in ipairs(storage.crystal_queue) do
    if entry.rare == nil then entry.rare = false end
    if entry.fire_at and (not storage.crystal_min_fire or entry.fire_at < storage.crystal_min_fire) then
      storage.crystal_min_fire = entry.fire_at
    end
  end
  -- Migrate growth queue entries: strip obsolete fields from old saves.
  for _, entry in ipairs(storage.growth_queue) do
    entry.retries = nil   -- removed in 1.15.31; seeds no longer have a retry cap
    entry.marker  = nil   -- removed in 1.15.7; markers tracked spatially
    if entry.species == nil then entry.species = TREE_ENTITY end
  end
  -- Migrate growing tree entries: add species field for AB support.
  for _, entry in ipairs(storage.growing_trees) do
    if entry.species == nil then entry.species = TREE_ENTITY end
  end
  if not storage.trees_cut      then storage.trees_cut      = {} end
  if not storage.wood_collected then storage.wood_collected = {} end
  if not storage.native_species then storage.native_species = {} end
  -- System 7 (Dynamic Rain integration) storage — added in 1.15.57.
  if storage.dr_rain_was_active == nil then storage.dr_rain_was_active   = false end
  if not storage.dr_seeded_this_storm  then storage.dr_seeded_this_storm = {} end
  -- System 7 Restorative Rains ledger — added in 1.15.90.
  if not storage.dr_rain_chunks        then storage.dr_rain_chunks       = {} end
  if storage.dr_rain_credits == nil    then storage.dr_rain_credits      = 0  end
  -- growth_cap cache — added in 1.15.72.  recalculate_growth_cap() below will
  -- set the correct value; this guard just ensures the field exists for on_load.
  if not storage.growth_cap then storage.growth_cap = 1 end
  -- 1.15.77: Nitrate delay default reduced from 3 nights to 2 nights.
  -- Runtime-global settings keep their saved value, so we migrate existing saves
  -- that are still on the old default of 3.  User-customised values are left alone.
  if settings.global["treez-crystal-delay-nights"].value == 3 then
    settings.global["treez-crystal-delay-nights"].value = 2
    crystal_delay_nights = 2
  end
  -- Migrate counts from old trees_cut → wood_collected (1 tree ≈ 1 wood for migration).
  for k, v in pairs(storage.trees_cut) do
    storage.wood_collected[k] = (storage.wood_collected[k] or 0) + v
  end
  storage.trees_cut = {}
  -- Recalculate the max-active cap from actual research state.
  -- The stored setting can drift (e.g. saved at 64 from a previous session,
  -- or carried over from an older mod version), so we always derive the
  -- correct value by counting completed Sapling Growth levels.
  recalculate_growth_cap()
  sync_placer_shortcut()
  sync_seeder_shortcut()
  build_native_species_map()
  build_hard_tiles_set()
  build_ab_tile_tables()
  build_vanilla_random_pools()
  enqueue_existing_crystals(game.surfaces[1])
  dr_native_event_active = setup_rain_event_listener()
end)

-- ============================================================
-- Storage helpers
-- ============================================================

local function get_player_data(player_index)
  if not storage.tree then storage.tree = {} end
  if not storage.tree[player_index] then
    storage.tree[player_index] = {
      seed_density    = DEFAULT_SEED_DENSITY,
      crystal_density = DEFAULT_CRYSTAL_DENSITY,
    }
  end
  local pd = storage.tree[player_index]
  if pd.density and not pd.seed_density then pd.seed_density = pd.density end
  if not pd.seed_density    then pd.seed_density    = DEFAULT_SEED_DENSITY    end
  if not pd.crystal_density then pd.crystal_density = DEFAULT_CRYSTAL_DENSITY end
  return pd
end

-- ============================================================
-- Shared GUI helpers
-- ============================================================

local function close_gui(player, gui_name)
  local frame = player.gui.screen[gui_name]
  if frame then frame.destroy() end
end

local function build_density_gui(player, gui_name, title_key, slider_name, density)
  local frame = player.gui.screen.add({
    type = "frame", name = gui_name, caption = { title_key }, direction = "vertical",
  })
  player.opened = frame
  local row = frame.add({ type = "flow", name = "density-row", direction = "horizontal" })
  row.style.vertical_align     = "center"
  row.style.horizontal_spacing = 8
  row.add({ type = "label", caption = { "tree-gui.density-label" } })
  row.add({
    type = "slider", name = slider_name,
    minimum_value = 10, maximum_value = 100,
    value = density, value_step = 5, discrete_slider = true,
  })
  row.add({ type = "label", name = "density-label", caption = density .. "%" })
end

-- ============================================================
-- Shortcut / GUI / area-selection handlers
-- ============================================================

script.on_event(defines.events.on_lua_shortcut, function(event)
  local player = game.players[event.player_index]
  if event.prototype_name == SEEDER_NAME then
    -- Safety guard: shortcut should be locked by technology_to_unlock, but
    -- keybinds can still fire.  Silently ignore if tech isn't researched.
    local player = game.players[event.player_index]
    if not (player.force.technologies["treez-tree-seeder"] or {}).researched then return end
    if player.gui.screen[SEEDER_GUI] then close_gui(player, SEEDER_GUI)
    else
      local pd = get_player_data(event.player_index)
      build_density_gui(player, SEEDER_GUI, "tree-gui.seeder-title", "tree-density-slider", pd.seed_density)
      player.cursor_stack.set_stack({ count = 1, name = SEEDER_NAME })
    end
  elseif event.prototype_name == PLACER_NAME then
    if player.gui.screen[PLACER_GUI] then close_gui(player, PLACER_GUI)
    else
      local pd = get_player_data(event.player_index)
      build_density_gui(player, PLACER_GUI, "tree-gui.placer-title", "crystal-density-slider", pd.crystal_density)
      player.cursor_stack.set_stack({ count = 1, name = PLACER_NAME })
    end
  end
end)

script.on_event(defines.events.on_gui_value_changed, function(event)
  local name        = event.element.name
  local player_data = get_player_data(event.player_index)
  if name == "tree-density-slider" then
    player_data.seed_density = math.floor(event.element.slider_value)
    local frame = game.players[event.player_index].gui.screen[SEEDER_GUI]
    if frame then frame["density-row"]["density-label"].caption = player_data.seed_density .. "%" end
  elseif name == "crystal-density-slider" then
    player_data.crystal_density = math.floor(event.element.slider_value)
    local frame = game.players[event.player_index].gui.screen[PLACER_GUI]
    if frame then frame["density-row"]["density-label"].caption = player_data.crystal_density .. "%" end
  end
end)

script.on_event(defines.events.on_gui_closed, function(event)
  if not event.element then return end
  if event.element.name == SEEDER_GUI or event.element.name == PLACER_GUI then
    event.element.destroy()
  end
end)

script.on_event(defines.events.on_player_selected_area, function(event)
  local player  = game.players[event.player_index]
  local surface = player.surface
  local force   = player.force
  local area    = event.area
  local x1 = math.floor(area.left_top.x)
  local y1 = math.floor(area.left_top.y)
  local x2 = math.floor(area.right_bottom.x) - 1
  local y2 = math.floor(area.right_bottom.y) - 1

  local surface_blocked = is_se_blocked_surface(surface)

  if event.item == SEEDER_NAME then
    local density = get_player_data(event.player_index).seed_density / 100
    for tx = x1, x2 do
      for ty = y1, y2 do
        if math.random() < density then
          local pos = { x = tx + 0.5, y = ty + 0.5 }
          local tile_name = surface.get_tile(pos).name
          if not is_hard_tile(tile_name)
             and not surface_blocked
             and not is_se_blocked_tile(tile_name)
             and surface.can_place_entity({ force = force, name = SITE_NAME, position = pos }) then
            surface.create_entity({
              force = force, player = player, inner_name = SITE_NAME,
              name = "entity-ghost", position = pos, raise_built = false,
            })
          end
        end
      end
    end
  elseif event.item == PLACER_NAME then
    local density = get_player_data(event.player_index).crystal_density / 100
    for tx = x1, x2 do
      for ty = y1, y2 do
        if math.random() < density then
          local pos = { x = tx + 0.5, y = ty + 0.5 }
          local tile_name = surface.get_tile(pos).name
          -- can_place_entity ignores the ghost layer, so check explicitly to
          -- avoid placing a nitrate ghost on top of an existing ghost.
          if not is_hard_tile(tile_name)
             and not surface_blocked
             and not is_se_blocked_tile(tile_name)
             and not surface.find_entities_filtered{ position = pos, radius = 0.5, type = "entity-ghost" }[1]
             and surface.can_place_entity({ force = force, name = CRYSTAL_SITE_NAME, position = pos }) then
            surface.create_entity({
              force = force, player = player, inner_name = CRYSTAL_SITE_NAME,
              name = "entity-ghost", position = pos, raise_built = false,
            })
          end
        end
      end
    end
  end
end)

-- ============================================================
-- /treez  —  diagnostic console command
-- ============================================================
-- Prints a snapshot of the tree-growth and nitrate-crystal queues so the
-- player can confirm seeds are being processed and crystals are firing.
commands.add_command("treez", "Show treez mod diagnostics. '/treez reset' clears counters. '/treez fix-sites' converts stranded tree-planting-site entities into waiting seeds. '/treez force_nitrate' immediately fires all queued nitrate pellets. '/treez test_rain' simulates a dynamic-rain chunk-cleared event on the player's current chunk. '/treez test_wic' verifies Winter Is Coming compatibility by reporting WIC season state and performing a test tile upgrade.", function(event)
  local player = event.player_index and game.players[event.player_index]
  local function say(msg)
    if player then player.print(msg) else log(msg) end
  end

  if event.parameter == "reset" then
    storage.dbg = {}
    say("[treez] handle_site counters reset.")
    return
  end

  -- ── fix-sites: convert stranded tree-seed-site entities into queued seeds ──
  -- These accumulate when mods place seeds via script revive without treez
  -- having the script_raised_revive handler (fixed in 1.15.73).
  if event.parameter == "fix-sites" then
    local processed = 0
    local skipped   = 0
    for _, surf in pairs(game.surfaces) do
      local sites = surf.find_entities_filtered{ name = SITE_NAME }
      for _, entity in pairs(sites) do
        if entity.valid then
          -- Route through System 8 (handle_script_placed_entity → handle_site).
          -- script_raised_built fires synchronously so the entity is processed
          -- and destroyed before the next iteration.
          script.raise_script_built({ entity = entity })
          processed = processed + 1
        else
          skipped = skipped + 1
        end
      end
    end
    say(("[treez] fix-sites complete: %d site(s) processed, %d skipped (already invalid)."):format(
      processed, skipped))
    return
  end

  -- ── test_rain: simulate on_rain_chunk_cleared on the player's current chunk ──
  -- Lets you verify that the dynamic-rain handler and seed-placement logic are
  -- working without waiting for actual rain.  Resets the per-storm seeded guard
  -- for the player's chunk so repeated calls are not suppressed.
  -- Only available when DYNAMIC_RAIN_ACTIVE is true; reports clearly if DR is
  -- absent so the path is still inspectable without the mod installed.
  if event.parameter == "test_rain" then
    if not player then
      say("[treez] test_rain: must be run by a player, not from the console.")
      return
    end
    say("[treez] test_rain: DYNAMIC_RAIN_ACTIVE=" .. tostring(DYNAMIC_RAIN_ACTIVE)
      .. "  rain_seed_enabled=" .. tostring(rain_seed_enabled)
      .. "  dr_native_event_active=" .. tostring(dr_native_event_active))
    if not DYNAMIC_RAIN_ACTIVE then
      say("[treez] Dynamic Rain is NOT installed — rain handler is dormant.")
      say("[treez] Install dynamic-rain and reload to exercise this path.")
      return
    end
    if not rain_seed_enabled then
      say("[treez] rain_seed_enabled is false — enable treez-rain-seed-enabled in settings to proceed.")
      return
    end
    local force_check = game.forces["player"]
    local aa_tech = force_check and force_check.technologies["treez-arboreal-aromatics"]
    if not (aa_tech and aa_tech.researched) then
      say("[treez] Atmospheric Arbory not yet researched — rain seeding is dormant. Research it to enable seed scatter.")
      return
    end
    local surface = player.surface
    local pos     = player.position
    local cx      = math.floor(pos.x / 32)
    local cy      = math.floor(pos.y / 32)
    local key     = cx .. ":" .. cy
    -- Clear the per-storm guard for this chunk so the test is not suppressed.
    storage.dr_seeded_this_storm = storage.dr_seeded_this_storm or {}
    storage.dr_seeded_this_storm[key] = nil
    say(("[treez] Simulating rain chunk-cleared for chunk (%d, %d)  [centre gps=%d,%d]"):format(
      cx, cy, cx * 32 + 16, cy * 32 + 16))
    local force = game.forces["player"]
    -- Temporarily force rain_seed_debug so the handler prints its own trace.
    local old_debug = rain_seed_debug
    rain_seed_debug = true
    try_rain_seed_chunk(surface, cx, cy, force)
    rain_seed_debug = old_debug
    say("[treez] test_rain: simulation complete.")
    return
  end

  -- ── test_wic: verify Winter Is Coming compatibility ───────────────────────
  -- Winter Is Coming (WIC) has no remote interface and fires no custom events.
  -- Our compatibility relies entirely on set_tiles calls with raise_event=true,
  -- which causes Factorio to fire script_raised_set_tiles so WIC can update its
  -- warm-tile snapshot.  This command:
  --   1. Reports WIC installation status and current season state.
  --   2. Reads WIC's front status directly from storage.wic (shared namespace).
  --   3. Calls upgrade_tile at the player's position and reports the before/after
  --      tile name, confirming that treez's tile-change path is exercised.
  --      WIC's snapshot update is automatic (via script_raised_set_tiles) and
  --      cannot be directly read without WIC's internal chunk_snapshot module,
  --      but a successful tile change confirms the event is raised.
  if event.parameter == "test_wic" then
    if not player then
      say("[treez] test_wic: must be run by a player, not from the console.")
      return
    end
    local wic_installed = script.active_mods["winter-is-coming"] ~= nil
    say("[treez] WIC installed: " .. tostring(wic_installed))

    -- Read WIC's season state from shared storage (no remote interface exists).
    local wic_state = storage.wic
    if wic_installed and wic_state then
      local status = wic_state.front_status or "nil"
      local warned = tostring(wic_state.warned_one_hour_before_winter or false)
      say(("[treez] WIC front_status=%s  warned_one_hour_before_winter=%s"):format(
        tostring(status), warned))
      say("[treez] WIC season: "
        .. (status == "freezing" or status == "freezing-done"   and "WINTER (freeze active or complete)"
         or status == "unfreezing" or status == "unfreezing-done" and "SUMMER (thaw active or complete)"
         or "UNKNOWN (status=" .. tostring(status) .. ")"))
    elseif wic_installed then
      say("[treez] WIC installed but storage.wic not yet initialised (start a game first).")
    else
      say("[treez] WIC not installed — compatibility path is dormant but set_tiles raise_event=true is always active.")
    end

    -- Attempt a tile upgrade at the player's position to confirm the code path.
    local surface  = player.surface
    local pos      = player.position
    local before   = surface.get_tile(pos).name
    local upgraded = upgrade_tile(surface, pos)
    local after    = surface.get_tile(pos).name
    say(("[treez] upgrade_tile test at [gps=%d,%d]: tile '%s' → '%s'  (upgraded=%s)"):format(
      math.floor(pos.x), math.floor(pos.y), before, after, tostring(upgraded)))
    if upgraded then
      say("[treez] ✓ Tile changed — script_raised_set_tiles was fired; WIC will have updated its snapshot if installed.")
    else
      say("[treez] ✗ No tile upgrade at this position (tile may not be in the upgrade table, or already at max).")
      say("[treez]   Move to a dirt/grass tile and retry, or check that AB upgrade tables are built.")
    end
    return
  end

  -- ── force_nitrate: immediately fire all queued pellets ───────────────────
  if event.parameter == "force_nitrate" then
    local cq    = storage.crystal_queue or {}
    local total = #cq
    if total == 0 then
      say("[treez] No pellets currently queued — place some soil-crystal pellets first.")
      return
    end
    local n_normal, n_colored = 0, 0
    for _, entry in ipairs(cq) do
      if entry.colored then n_colored = n_colored + 1
      else                  n_normal  = n_normal  + 1
      end
    end
    process_crystals(true)
    local remaining = #(storage.crystal_queue or {})
    say(("[treez] Force-fired %d pellet(s)  (normal: %d  colored: %d).  %d remaining."):format(
      total - remaining, n_normal, n_colored, remaining))
    return
  end

  -- ── Tree growth ───────────────────────────────────────────────────────────
  local growing   = storage.growing_tree_count or 0
  local queued    = #(storage.growth_queue or {})
  local cap       = tree_growth_max_active
  local bypass    = tree_growth_bypass

  say("=== treez diagnostics ===")

  -- ── handle_site call breakdown ────────────────────────────────────────────
  local dbg = storage.dbg or {}
  say(("[handle_site] calls:%d  grew:%d  queued:%d  stage1_fail:%d  cap_reached:%d  bypass:%d  no_species:%d"):format(
    dbg.calls or 0, dbg.grew or 0, dbg.queued or 0,
    dbg.stage1_fail or 0, dbg.cap_reached or 0,
    dbg.bypass or 0, dbg.no_species or 0))
  say(("[on_built] total_built:%d  filter_matched:%d  se_blocked:%d  last_built:'%s'"):format(
    dbg.total_built or 0, dbg.on_built_fired or 0, dbg.se_blocked or 0,
    tostring(dbg.last_built)))

  -- ── TREE_ENTITY / prototype health ───────────────────────────────────────
  local ref_item_ok = prototypes.item["tree-entity-ref"] ~= nil
  say(("[Config] TREE_ENTITY: %s  tree-entity-ref item exists: %s"):format(
    tostring(TREE_ENTITY), tostring(ref_item_ok)))

  local stage1_name = TREE_ENTITY and growth_proto_name(1, TREE_ENTITY) or "N/A"
  local stage1_ok   = stage1_name ~= "N/A" and prototypes.entity[stage1_name] ~= nil
  say(("[Config] stage-1 proto: %s  exists: %s"):format(
    tostring(stage1_name), tostring(stage1_ok)))
  say(("[Trees] enabled: %s  bypass(instant): %s"):format(
    tostring(TREE_GROWTH_ENABLED), tostring(bypass)))
  say(("[Trees] actively growing: %d / %d (cap)"):format(growing, cap))
  say(("[Trees] waiting in queue: %d"):format(queued))

  -- Seed ghosts placed but not yet built by robots
  local seed_ghosts = 0
  for _, surf in pairs(game.surfaces) do
    for _, g in ipairs(surf.find_entities_filtered{ type = "entity-ghost" }) do
      if g.ghost_name == SITE_NAME then seed_ghosts = seed_ghosts + 1 end
    end
  end
  say(("[Trees] seed ghosts waiting for robots: %d"):format(seed_ghosts))

  -- Day/night state (growth pauses during day when day-only is on)
  local surf1  = game.surfaces[1]
  local is_day = surf1 and not is_night(surf1)
  say(("[Trees] day-only: %s  currently: %s"):format(
    tostring(tree_growth_day_only),
    is_day and "DAY — growth paused" or "night — growth active"))

  -- Stage breakdown condensed into quarters
  local quarters = {0, 0, 0, 0}
  local total_stages = tree_growth_stages > 0 and tree_growth_stages or 1
  for _, entry in ipairs(storage.growing_trees or {}) do
    local s = entry.stage or 1
    local q = math.min(4, math.ceil(s / total_stages * 4))
    quarters[q] = quarters[q] + 1
  end
  if growing > 0 then
    say(("[Trees] stage breakdown: Q1(seedling):%d  Q2(sapling):%d  Q3(young):%d  Q4(maturing):%d"):format(
      quarters[1], quarters[2], quarters[3], quarters[4]))
  end

  -- How soon will the next tree advance?
  local now      = game.tick
  local earliest = math.huge
  for _, entry in ipairs(storage.growing_trees or {}) do
    if entry.fire_at and entry.fire_at < earliest then
      earliest = entry.fire_at
    end
  end
  if earliest < math.huge then
    local ticks_left = math.max(0, earliest - now)
    say(("[Trees] next growth tick in: %d ticks (%.1f s)"):format(
      ticks_left, ticks_left / 60.0))
  end

  -- ── Nitrate crystals ─────────────────────────────────────────────────────
  local cq         = storage.crystal_queue or {}
  local total_crys = #cq
  local normal_c, colored_c = 0, 0
  for _, entry in ipairs(cq) do
    if entry.colored then colored_c = colored_c + 1
    else                   normal_c = normal_c + 1
    end
  end
  say(("[Nitrate] crystals in fire-queue: %d  (normal %d, colored %d)"):format(
    total_crys, normal_c, colored_c))

  -- Count placed crystals and ghosts across all surfaces
  local placed_normal, placed_colored = 0, 0
  local ghosts_normal, ghosts_colored = 0, 0
  for _, surf in pairs(game.surfaces) do
    placed_normal  = placed_normal  + #surf.find_entities_filtered{ name = CRYSTAL_SITE_NAME }
    placed_colored = placed_colored + #surf.find_entities_filtered{ name = CRYSTAL_COLORED_SITE_NAME }
    for _, g in ipairs(surf.find_entities_filtered{ type = "entity-ghost" }) do
      if     g.ghost_name == CRYSTAL_SITE_NAME         then ghosts_normal  = ghosts_normal  + 1
      elseif g.ghost_name == CRYSTAL_COLORED_SITE_NAME then ghosts_colored = ghosts_colored + 1
      end
    end
  end
  local placed_total = placed_normal + placed_colored
  local ghosts_total = ghosts_normal + ghosts_colored
  say(("[Nitrate] placed: %d total  (normal %d, colored %d)"):format(
    placed_total, placed_normal, placed_colored))
  say(("[Nitrate] ghosts waiting to build: %d  (normal %d, colored %d)"):format(
    ghosts_total, ghosts_normal, ghosts_colored))

  -- How soon will the next crystal fire?
  local earliest_c = math.huge
  for _, entry in ipairs(cq) do
    if entry.fire_at and entry.fire_at < earliest_c then
      earliest_c = entry.fire_at
    end
  end
  if earliest_c < math.huge then
    local ticks_left = math.max(0, earliest_c - now)
    say(("[Nitrate] next crystal fires in: %d ticks (%.1f s)"):format(
      ticks_left, ticks_left / 60.0))
  end

  -- ── Settings snapshot ─────────────────────────────────────────────────────
  say(("[Settings] growth speed: %s  day-only: %s  pollution-delay: %s"):format(
    settings.global["treez-tree-growth-speed"].value,
    tostring(tree_growth_day_only),
    tostring(tree_growth_pollution_delay)))
  say("=========================")
end)
