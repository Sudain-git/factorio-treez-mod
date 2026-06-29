-- data-final-fixes.lua
-- Runs last in the data stage, after all mods have loaded.

local tree_seed_item = data.raw.item["tree-seed"]
if not tree_seed_item then return end

local original_entity = tree_seed_item.place_result
-- Validate: place_result must be an actual tree (or plant in Space Age).
-- If it was already overridden to "tree-seed-site" (e.g. by another mod's
-- data-final-fixes running first), or is nil, fall back to tree-01.
if not original_entity
   or (not data.raw.tree[original_entity]
       and not (data.raw.plant and data.raw.plant[original_entity])) then
  if data.raw.tree["tree-01"] then
    log(("[treez] place_result '%s' is not a tree entity; falling back to tree-01")
      :format(tostring(original_entity)))
    original_entity = "tree-01"
  else
    log("[treez] ERROR: cannot determine base tree entity; growth will be disabled.")
    original_entity = nil
  end
end

if original_entity then
  local ref_data = {
    hidden     = true,
    -- Use our own sprite rather than inheriting from the active tree-seed item.
    -- Space Age's tree-seed.png is 120x64 but its icon_size implies a 120x120
    -- crop; Factorio validates that rectangle even on hidden items and crashes.
    icon       = "__treez-base-game__/graphics/icons/tree-seed-sprite.png",
    icon_size  = 32,
    name       = "tree-entity-ref",
    order      = original_entity,
    stack_size = 1,
    subgroup   = "seeds",
    type       = "item",
  }
  if data.raw.plant and data.raw.plant[original_entity] then
    ref_data.place_result = original_entity
  end
  data:extend({ ref_data })

  local tree_proto = (data.raw.plant and data.raw.plant[original_entity])
                  or data.raw.tree[original_entity]
  if tree_proto then
    local site = data.raw["simple-entity-with-owner"]["tree-seed-site"]
    -- Copy collision box so seeds respect the same spacing as full trees.
    -- Do NOT copy collision_mask or tile_buildability_rules: the seed site must
    -- be placeable on any tile, including degraded terrain.  The tile
    -- compatibility for the actual tree is checked later in handle_site via
    -- can_place_entity for the growth-stage proto.
    if tree_proto.collision_box then
      site.collision_box = tree_proto.collision_box
    end
  end
end

tree_seed_item.place_result = "tree-seed-site"

-- Seeds are combustible — 1/10th the fuel value of wood (wood = 2 MJ → 200 kJ).
-- Also set on the base-game fallback item in data.lua; re-applied here
-- unconditionally so the fields are present when Space Age provides the item
-- instead (Space Age's tree-seed definition does not include fuel fields).
tree_seed_item.fuel_category = "chemical"
tree_seed_item.fuel_value    = "200kJ"

-- ============================================================
-- Tree growth stage prototypes
--
-- For each plantable tree species (base game + Alien Biomes when installed)
-- this generates MAX_GROWTH_STAGES hidden entity prototypes named
-- "treez-{species}-stage-N".  Sprites use a sqrt scale curve (5% floor);
-- collision boxes scale linearly from 20% to 100% of the base tree's box.
--
-- For save-game compatibility, the pre-AB names "treez-growth-stage-N" are
-- also generated as aliases for the base tree so any trees already growing
-- in a world remain valid after the update.
-- ============================================================

local MAX_GROWTH_STAGES = 200   -- must match constant in control.lua

-- Recursively scale the 'scale' and 'shift' fields of every sprite-like
-- sub-table (identified by having a 'filename' or 'filenames' key).
local function scale_sprites(t, factor)
  if type(t) ~= "table" then return end
  if t.filename or t.filenames then
    t.scale = (t.scale or 1.0) * factor
    if t.shift then
      t.shift = { t.shift[1] * factor, t.shift[2] * factor }
    end
  end
  for _, v in pairs(t) do scale_sprites(v, factor) end
end

-- Generate MAX_GROWTH_STAGES hidden stage prototypes for one tree species.
-- stage_prefix: the leading portion of the entity name before "-stage-N"
--   e.g. "treez-tree-01" produces "treez-tree-01-stage-1" etc.
local function generate_stages(tree_proto, stage_prefix)
  local base_box = tree_proto.collision_box
  for i = 1, MAX_GROWTH_STAGES do
    local proto = table.deepcopy(tree_proto)
    local t     = i / MAX_GROWTH_STAGES

    local sprite_frac = math.max(0.05, math.sqrt(t))
                        * (MAX_GROWTH_STAGES / (MAX_GROWTH_STAGES + 1))

    proto.name         = stage_prefix .. "-stage-" .. i
    proto.autoplace    = nil
    proto.next_upgrade = nil
    proto.hidden       = true

    scale_sprites(proto, sprite_frac)

    local coll_frac = 0.2 + 0.8 * t
    if base_box then
      proto.collision_box = {
        { base_box[1][1] * coll_frac, base_box[1][2] * coll_frac },
        { base_box[2][1] * coll_frac, base_box[2][2] * coll_frac },
      }
    else
      proto.collision_box = {
        { -0.4 * coll_frac, -0.4 * coll_frac },
        {  0.4 * coll_frac,  0.4 * coll_frac },
      }
    end

    proto.minable = {
      mining_time = 0.5,
      result      = "wood",
      count       = math.max(1, math.floor(t * 4)),
    }

    data:extend({ proto })
  end
end

-- In Factorio 2.0 the `plant` prototype type is part of the base engine, so
-- data.raw.plant is always a table (possibly empty) and `not data.raw.plant`
-- is always false.  Gate on the mod itself instead.
if not mods["space-age"] then
  -- ── Base game tree ────────────────────────────────────────────────────────
  local base_tree = original_entity and data.raw.tree[original_entity]
  if base_tree then
    -- New-style names used by all new plantings: treez-{species}-stage-N
    generate_stages(base_tree, "treez-" .. original_entity)
    -- Backward-compat aliases for in-progress trees from pre-AB saves.
    -- Existing world entities named treez-growth-stage-N stay valid; they
    -- are replaced by new-style entities as each stage advances.
    generate_stages(base_tree, "treez-growth")
    log(("[treez] Created %d growth stages for base tree '%s' (+ compat aliases)")
      :format(MAX_GROWTH_STAGES, original_entity))
  else
    log(("[treez] WARNING: tree entity '%s' not found; growth stages skipped.")
      :format(tostring(original_entity)))
  end

  -- ── Alien Biomes trees ────────────────────────────────────────────────────
  if mods["alien-biomes"] then
    local ab_count = 0
    for name, tree_proto in pairs(data.raw.tree) do
      -- Include any tree that has autoplace set and is not the base tree.
      -- AB sets autoplace on all its species; vanilla trees AB has disabled
      -- (autoplace = nil) are intentionally skipped.
      if name ~= original_entity and tree_proto.autoplace then
        generate_stages(tree_proto, "treez-" .. name)
        ab_count = ab_count + 1
      end
    end
    log(("[treez] Created %d growth stages for %d Alien Biomes species (%d total)")
      :format(MAX_GROWTH_STAGES * ab_count, ab_count,
              MAX_GROWTH_STAGES * (ab_count + 2)))  -- +2: base + compat
  end
end

-- ============================================================
-- Technology prerequisite re-assertion
-- ============================================================
-- Space Exploration (and similar overhaul mods) may reorganise the tech tree
-- and reassign prerequisites during their own data stage. Because this mod
-- declares an optional dependency on SE, our data-final-fixes.lua runs after
-- SE's, so these assignments are the last word on prerequisites.

-- assert_tech(name, prerequisites, unit)
-- Reasserts both prerequisites and unit ingredients so overhaul mods (SE etc.)
-- cannot inject additional science packs or relink the chain.
local _standard_unit = { count = 100, ingredients = { { "automation-science-pack", 1 }, { "logistic-science-pack", 1 }, { "chemical-science-pack", 1 } }, time = 30 }

local function assert_tech(name, prerequisites, unit)
  local tech = data.raw.technology[name]
  if not tech then return end
  if prerequisites ~= nil then tech.prerequisites = prerequisites end
  if unit          ~= nil then tech.unit          = unit          end
  log(("[treez] tech asserted: '%s'"):format(name))
end

local _primitive_nitrates_unit = { count = 10, ingredients = { { "automation-science-pack", 1 }, { "logistic-science-pack", 1 } }, time = 30 }
assert_tech("treez-primitive-nitrates",            { "logistic-science-pack" },                              _primitive_nitrates_unit)
assert_tech("soil-crystal",                        { "treez-primitive-nitrates", "chemical-science-pack" },  _standard_unit)
assert_tech("soil-crystal-catalyst",               { "soil-crystal" },                                       _standard_unit)
assert_tech("soil-crystal-catalyst-abundant-1",    { "soil-crystal-catalyst" },                              _standard_unit)
assert_tech("soil-crystal-catalyst-abundant-2",    { "soil-crystal-catalyst-abundant-1" },                   _standard_unit)
assert_tech("soil-crystal-catalyst-abundant-3",    { "soil-crystal-catalyst-abundant-2" },                   _standard_unit)
assert_tech("soil-crystal-catalyst-reactions-1",   { "soil-crystal-catalyst" },                              _standard_unit)
assert_tech("soil-crystal-catalyst-reactions-2",   { "soil-crystal-catalyst-reactions-1" },                  _standard_unit)
assert_tech("soil-crystal-catalyst-reactions-3",   { "soil-crystal-catalyst-reactions-2" },                  _standard_unit)
assert_tech("soil-crystal-white-pollution-1",      { "soil-crystal" },                                       _standard_unit)
assert_tech("soil-crystal-white-pollution-2",      { "soil-crystal-white-pollution-1" },                     _standard_unit)
assert_tech("soil-crystal-white-pollution-3",      { "soil-crystal-white-pollution-2" },                     _standard_unit)
assert_tech("soil-crystal-white-pollution-4",      { "soil-crystal-white-pollution-3" },                     _standard_unit)
assert_tech("soil-crystal-white-pollution-5",      { "soil-crystal-white-pollution-4" },                     _standard_unit)

-- Sapling Growth chain — escalating automation-science-pack per level (10/20/40/80/160/320).
-- Re-asserted here so SE (and similar overhaul mods) cannot inject extra
-- science packs or relink the prerequisite chain.
-- The second prerequisite adapts to the mod environment:
--   AAI Industry installed → "automation-science-pack" (AAI's early science gate)
--   Vanilla / no AAI      → "automation" (standard first technology)
local _sapling_unit_1 = { count =  10, ingredients = { { "automation-science-pack", 1 } }, time = 30 }
local _sapling_unit_2 = { count =  20, ingredients = { { "automation-science-pack", 1 } }, time = 30 }
local _sapling_unit_3 = { count =  40, ingredients = { { "automation-science-pack", 1 } }, time = 30 }
local _sapling_unit_4 = { count =  80, ingredients = { { "automation-science-pack", 1 } }, time = 30 }
local _sapling_unit_5 = { count = 160, ingredients = { { "automation-science-pack", 1 } }, time = 30 }
local _sapling_unit_6 = { count = 320, ingredients = { { "automation-science-pack", 1 } }, time = 30 }
local _sapling_1_auto = mods["aai-industry"] and "automation-science-pack" or "automation"
assert_tech("treez-sapling-growth-1", { "treez-tree-growth", _sapling_1_auto }, _sapling_unit_1)
assert_tech("treez-sapling-growth-2", { "treez-sapling-growth-1" },             _sapling_unit_2)
assert_tech("treez-sapling-growth-3", { "treez-sapling-growth-2" },             _sapling_unit_3)
assert_tech("treez-sapling-growth-4", { "treez-sapling-growth-3" },             _sapling_unit_4)
assert_tech("treez-sapling-growth-5", { "treez-sapling-growth-4" },             _sapling_unit_5)
assert_tech("treez-sapling-growth-6", { "treez-sapling-growth-5" },             _sapling_unit_6)

-- Tree Seeder — re-asserted so overhaul mods cannot remove the logistic-science-pack
-- prerequisite or alter the research cost.
local _tree_seeder_unit = {
  count       = 100,
  ingredients = {
    { "automation-science-pack", 1 },
    { "logistic-science-pack",   1 },
  },
  time = 30,
}
assert_tech("treez-tree-seeder", { "treez-sapling-growth-6", "logistic-science-pack" }, _tree_seeder_unit)

-- Cloud Seeding / Arboreal Aromatics chain — re-asserted so overhaul mods
-- cannot inject extra packs or relink the prerequisite chain.
-- Only runs when Dynamic Rain is installed.
--
-- Space science gate for Arboreal Aromatics:
--   SE present → se-rocket-science-pack technology as both a prerequisite AND
--                ingredient (SE's post-rocket-silo gate; same name for tech and item).
--   SE absent  → space-science-pack as both a prerequisite tech AND an
--                ingredient, hard-gating this behind the rocket milestone.
if mods["dynamic-rain"] then
  local _cs_unit_1 = { count =  10, ingredients = { { "automation-science-pack", 1 } }, time = 60 }
  local _cs_unit_2 = { count =  20, ingredients = { { "automation-science-pack", 1 } }, time = 60 }
  local _cs_unit_3 = { count =  40, ingredients = { { "automation-science-pack", 1 } }, time = 60 }
  local _cs_unit_4 = { count =  80, ingredients = { { "automation-science-pack", 1 } }, time = 60 }
  local _cs_unit_5 = { count = 160, ingredients = { { "automation-science-pack", 1 } }, time = 60 }
  local _cs_unit_6 = { count = 320, ingredients = { { "automation-science-pack", 1 } }, time = 60 }

  local _aa_prereqs
  local _aa_space_pack
  if mods["space-exploration"] then
    _aa_prereqs    = { "soil-crystal", "treez-sapling-growth-1", "se-rocket-science-pack" }
    _aa_space_pack = "se-rocket-science-pack"
  else
    _aa_prereqs    = { "soil-crystal", "treez-sapling-growth-1", "space-science-pack" }
    _aa_space_pack = "space-science-pack"
  end
  local _aa_unit = {
    count       = 150,
    ingredients = {
      { "automation-science-pack", 1 },
      { "logistic-science-pack",   1 },
      { "chemical-science-pack",   1 },
      { _aa_space_pack,            1 },
    },
    time = 60,
  }
  assert_tech("treez-arboreal-aromatics",  _aa_prereqs, _aa_unit)
  assert_tech("treez-cloudseeding-1", { "treez-sapling-growth-1", "treez-arboreal-aromatics" },   _cs_unit_1)
  assert_tech("treez-cloudseeding-2", { "treez-cloudseeding-1", "treez-sapling-growth-2" },      _cs_unit_2)
  assert_tech("treez-cloudseeding-3", { "treez-cloudseeding-2", "treez-sapling-growth-3" },      _cs_unit_3)
  assert_tech("treez-cloudseeding-4", { "treez-cloudseeding-3", "treez-sapling-growth-4" },      _cs_unit_4)
  assert_tech("treez-cloudseeding-5", { "treez-cloudseeding-4", "treez-sapling-growth-5" },      _cs_unit_5)
  assert_tech("treez-cloudseeding-6", { "treez-cloudseeding-5", "treez-sapling-growth-6" },      _cs_unit_6)
end

-- Sapling Soil Enrichment chain — re-asserted so overhaul mods cannot inject
-- extra science packs or relink the prerequisite chain.
-- Cost mirrors sapling growth (10/20/40/80/160/320) with automation, logistic,
-- and chemical science packs at 60 s each.
local _se_unit_1 = { count =  10, ingredients = { { "automation-science-pack", 1 }, { "logistic-science-pack", 1 }, { "chemical-science-pack", 1 } }, time = 60 }
local _se_unit_2 = { count =  20, ingredients = { { "automation-science-pack", 1 }, { "logistic-science-pack", 1 }, { "chemical-science-pack", 1 } }, time = 60 }
local _se_unit_3 = { count =  40, ingredients = { { "automation-science-pack", 1 }, { "logistic-science-pack", 1 }, { "chemical-science-pack", 1 } }, time = 60 }
local _se_unit_4 = { count =  80, ingredients = { { "automation-science-pack", 1 }, { "logistic-science-pack", 1 }, { "chemical-science-pack", 1 } }, time = 60 }
local _se_unit_5 = { count = 160, ingredients = { { "automation-science-pack", 1 }, { "logistic-science-pack", 1 }, { "chemical-science-pack", 1 } }, time = 60 }
local _se_unit_6 = { count = 320, ingredients = { { "automation-science-pack", 1 }, { "logistic-science-pack", 1 }, { "chemical-science-pack", 1 } }, time = 60 }
assert_tech("treez-soil-enrichment-1", { "soil-crystal",            "treez-sapling-growth-1" },                                              _se_unit_1)
assert_tech("treez-soil-enrichment-2", { "treez-soil-enrichment-1", "soil-crystal-white-pollution-1", "treez-sapling-growth-2" },            _se_unit_2)
assert_tech("treez-soil-enrichment-3", { "treez-soil-enrichment-2", "soil-crystal-white-pollution-2", "treez-sapling-growth-3" },            _se_unit_3)
assert_tech("treez-soil-enrichment-4", { "treez-soil-enrichment-3", "soil-crystal-white-pollution-3", "treez-sapling-growth-4" },            _se_unit_4)
assert_tech("treez-soil-enrichment-5", { "treez-soil-enrichment-4", "soil-crystal-white-pollution-4", "treez-sapling-growth-5" },            _se_unit_5)
assert_tech("treez-soil-enrichment-6", { "treez-soil-enrichment-5", "soil-crystal-white-pollution-5", "treez-sapling-growth-6" },            _se_unit_6)
-- Restorative Rains — re-asserted so overhaul mods cannot relink prereqs.
-- Only asserted when Dynamic Rain is installed (tech doesn't exist otherwise).
--
-- Space science gate:
--   SE present → se-rocket-science-pack technology as both a prerequisite AND
--                ingredient (SE's post-rocket-silo gate; same name for tech and item).
--   SE absent  → space-science-pack as both a prerequisite tech AND ingredient.
if mods["dynamic-rain"] then
  local _rr_prereqs
  local _rr_space_pack
  if mods["space-exploration"] then
    _rr_prereqs    = { "soil-crystal", "treez-sapling-growth-1", "se-rocket-science-pack" }
    _rr_space_pack = "se-rocket-science-pack"
  else
    _rr_prereqs    = { "soil-crystal", "treez-sapling-growth-1", "space-science-pack" }
    _rr_space_pack = "space-science-pack"
  end
  local _rr_unit = {
    count       = 150,
    ingredients = {
      { "automation-science-pack", 1 },
      { "logistic-science-pack",   1 },
      { "chemical-science-pack",   1 },
      { _rr_space_pack,            1 },
    },
    time = 60,
  }
  assert_tech("treez-restorative-rains", _rr_prereqs, _rr_unit)
end

-- Enduring Nitrates chain — re-asserted so overhaul mods cannot relink prereqs.
-- Costs match catalyst research: 100 auto + logistic + chemical at 30 s.
local _en_unit = { count = 100, ingredients = { { "automation-science-pack", 1 }, { "logistic-science-pack", 1 }, { "chemical-science-pack", 1 } }, time = 30 }
assert_tech("treez-enduring-nitrates-1", { "soil-crystal-catalyst-abundant-1", "soil-crystal-catalyst-reactions-1" }, _en_unit)
assert_tech("treez-enduring-nitrates-2", { "treez-enduring-nitrates-1", "soil-crystal-catalyst-abundant-2", "soil-crystal-catalyst-reactions-2" }, _en_unit)
assert_tech("treez-enduring-nitrates-3", { "treez-enduring-nitrates-2", "soil-crystal-catalyst-abundant-3", "soil-crystal-catalyst-reactions-3" }, _en_unit)
