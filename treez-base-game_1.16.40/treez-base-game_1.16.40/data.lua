-- data.lua

-- Safe item-subgroup: "seeds" exists in Space Age; define as fallback.
if not data.raw["item-subgroup"]["seeds"] then
  data:extend({ {
    group = "production",
    name  = "seeds",
    order = "z",
    type  = "item-subgroup",
  } })
end

-- tree-seed item: provided by Space Age; create a base-game fallback if absent.
-- fuel_category and fuel_value are set here for the base-game fallback, and are
-- also re-applied unconditionally in data-final-fixes.lua so the fields are
-- present whether the item comes from this fallback or from Space Age's definition.
if not data.raw.item["tree-seed"] then
  data:extend({ {
    type          = "item",
    name          = "tree-seed",
    icon          = "__treez-base-game__/graphics/icons/tree-seed-sprite.png",
    icon_size     = 32,
    subgroup      = "seeds",
    order         = "a[tree-seed]",
    stack_size    = 50,
    place_result  = "tree-01",
    fuel_category = "chemical",
    fuel_value    = "200kJ",   -- 1/10th of wood (2 MJ); also set in data-final-fixes.lua
  } })
end

-- tree-seed recipe: guarded separately from the item because some mods (e.g.
-- Space Age) provide the item without providing a crafting recipe.  Treez
-- always needs a recipe named "tree-seed" to exist so that the treez-tree-growth
-- technology can unlock it.  If another mod already provides the recipe, we
-- leave it alone.
if not data.raw.recipe["tree-seed"] then
  data:extend({ {
    type            = "recipe",
    name            = "tree-seed",
    enabled         = false,  -- locked; unlocked by treez-tree-growth technology
    energy_required = 1,
    ingredients     = { { type = "item", name = "wood", amount = 1 } },
    results         = { { type = "item", name = "tree-seed", amount = 4 } },
  } })
end

-- _icons: used for entity icons on tree-seed-site, treez-seed-waiting,
-- tree-seeder shortcut, and tree-seeder selection-tool.
--
-- We intentionally use our own sprite rather than inheriting from the
-- active tree-seed item (base-game fallback or Space Age).  Space Age's
-- tree-seed.png is 120×64 (non-square), but its item definition implies a
-- 120×120 crop via icon_size.  Factorio validates sprite rectangles at load
-- time, so copying that icon_size would produce:
--   "sprite rectangle (0×0, 120×120) outside actual size (0×0, 120×64)"
-- Our own 32×32 sprite is always valid regardless of which mods are active.
local _icons = { { icon = "__treez-base-game__/graphics/icons/tree-seed-sprite.png", icon_size = 32 } }

-- Tech-tree icon: always the high-res photo acorns regardless of which
-- tree-seed item is active (base-game fallback or Space Age).
local _tech_icons = { {
  icon      = "__treez-base-game__/graphics/icons/seed-research.png",
  icon_size = 256,
} }

-- tree-seed-site proxy entity
data:extend({ {
  type                = "simple-entity-with-owner",
  name                = "tree-seed-site",
  flags               = { "placeable-neutral", "player-creation" },
  icons               = _icons,
  items_to_place_this = { { count = 1, item = "tree-seed" } },
  max_health          = 10,
  minable             = { mining_time = 0.1, result = "tree-seed" },
  picture = {
    filename = "__treez-base-game__/graphics/icons/tree-seed-sprite.png",
    width    = 32,
    height   = 32,
    priority = "extra-high",
    scale    = 1.0,
  },
  collision_box = { { -0.1, -0.1 }, { 0.1, 0.1 } },
  selection_box = { { -0.5, -0.5 }, { 0.5, 0.5 } },
} })

-- Waiting-seed visual marker.
-- Placed at a queued position so players can see where seeds are waiting to
-- begin growing.  Destroyed automatically when the seed starts its first
-- growth stage.  Selectable and minable (returns tree-seed).
-- "player-creation" is required for the deconstruction planner to select it.
-- "not-blueprintable" prevents blueprint capture.  The on_player_setup_blueprint
-- handler in control.lua also rewrites any stray waiting-seed blueprint entries
-- to tree-seed-site as a belt-and-suspenders guard.
data:extend({ {
  type               = "simple-entity-with-owner",
  name               = "treez-seed-waiting",
  selectable_in_game = true,
  flags     = {
    "placeable-neutral",
    "player-creation",
    "not-on-map",
    "not-repairable",
    "not-upgradable",
    "not-blueprintable",
  },
  icons               = _icons,
  max_health          = 10,
  minable             = { mining_time = 0.5, result = "tree-seed" },
  items_to_place_this = { { count = 1, item = "tree-seed" } },
  collision_box = { { -0.05, -0.05 }, { 0.05, 0.05 } },
  selection_box = { { -0.3,  -0.3  }, { 0.3,  0.3  } },
  picture = {
    filename     = "__treez-base-game__/graphics/icons/tree-seed-sprite.png",
    width        = 32,
    height       = 32,
    priority     = "extra-high",
    render_layer = "higher-object",
    scale        = 0.6,
  },
} })

-- ============================================================
-- Tree Seeder area tool
-- ============================================================

data:extend({ {
  action        = "lua",
  consuming     = "none",
  key_sequence  = "",
  name          = "tree-seeder",
  type          = "custom-input",
} })

data:extend({ {
  action                   = "lua",
  associated_control_input = "tree-seeder",
  icons                    = _icons,
  name                     = "tree-seeder",
  small_icons              = _icons,
  technology_to_unlock     = "treez-tree-seeder",
  type                     = "shortcut",
} })

data:extend({ {
  type        = "selection-tool",
  name        = "tree-seeder",
  flags       = { "only-in-cursor", "spawnable" },
  icons       = _icons,
  order       = "z[tree-seeder]",
  subgroup    = "seeds",
  stack_size  = 1,
  select = {
    border_color   = { r = 0.1, g = 0.8, b = 0.1 },
    color          = { r = 0.1, g = 0.8, b = 0.1, a = 0.5 },
    cursor_box_type = "copy",
    mode           = { "nothing" },
  },
  alt_select = {
    border_color   = { r = 0.8, g = 0.2, b = 0.1 },
    color          = { r = 0.8, g = 0.2, b = 0.1, a = 0.5 },
    cursor_box_type = "not-allowed",
    mode           = { "nothing" },
  },
} })

-- ============================================================
-- Tree Growth technology
-- Uses research_trigger so Factorio tracks progress natively:
-- cutting 10 base-game tree-01s completes it automatically.
-- For Alien Biomes installs, control.lua supplements this by
-- counting any tree species toward the same 10-tree threshold.
-- ============================================================
data:extend({ {
  type    = "technology",
  name    = "treez-tree-growth",
  icons   = _tech_icons,
  effects = {
    { type = "unlock-recipe", recipe = "tree-seed" },
  },
  research_trigger = {
    type   = "mine-entity",
    entity = "tree-01",
    count  = 1,   -- fires on first tree-01; control.lua handles all species via wood count
  },
} })

-- ============================================================
-- Tree Seeder technology
-- Prereq: Tree Growth.  Costs 100× automation + logistic packs.
-- Unlocks the Tree Seeder shortcut (area ghost-placement tool).
-- ============================================================
data:extend({ {
  type          = "technology",
  name          = "treez-tree-seeder",
  icons         = _tech_icons,
  prerequisites = { "treez-sapling-growth-6", "logistic-science-pack" },
  effects       = {},   -- shortcut unlock handled by technology_to_unlock on the shortcut
  unit          = {
    count       = 100,
    ingredients = {
      { "automation-science-pack", 1 },
      { "logistic-science-pack",   1 },
    },
    time = 30,
  },
} })


-- ============================================================
-- Sapling Growth technologies (levels 1–6)
-- Each level doubles the maximum number of simultaneously growing trees.
-- Chain: treez-tree-growth → level 1 → 2 → 3 → 4 → 5 → 6
-- Cost: escalating automation-science-pack per level (10/20/40/80/160/320).
-- Prerequisites and unit are re-asserted in data-final-fixes.lua after SE
-- post-processing so overhaul mods cannot relink or inject extra packs.
-- ============================================================
local _sapling_unit_1 = { count =  10, ingredients = { { "automation-science-pack", 1 } }, time = 30 }
local _sapling_unit_2 = { count =  20, ingredients = { { "automation-science-pack", 1 } }, time = 30 }
local _sapling_unit_3 = { count =  40, ingredients = { { "automation-science-pack", 1 } }, time = 30 }
local _sapling_unit_4 = { count =  80, ingredients = { { "automation-science-pack", 1 } }, time = 30 }
local _sapling_unit_5 = { count = 160, ingredients = { { "automation-science-pack", 1 } }, time = 30 }
local _sapling_unit_6 = { count = 320, ingredients = { { "automation-science-pack", 1 } }, time = 30 }

data:extend({ {
  type          = "technology",
  name          = "treez-sapling-growth-1",
  icons         = { { icon = "__treez-base-game__/graphics/icons/sappling-research-1.png", icon_size = 128 } },
  prerequisites = { "treez-tree-growth", mods["aai-industry"] and "automation-science-pack" or "automation" },
  effects       = {},
  unit          = _sapling_unit_1,
} })

data:extend({ {
  type          = "technology",
  name          = "treez-sapling-growth-2",
  icons         = { { icon = "__treez-base-game__/graphics/icons/sappling-research-2.png", icon_size = 128 } },
  prerequisites = { "treez-sapling-growth-1" },
  effects       = {},
  unit          = _sapling_unit_2,
} })

data:extend({ {
  type          = "technology",
  name          = "treez-sapling-growth-3",
  icons         = { { icon = "__treez-base-game__/graphics/icons/sappling-research-3.png", icon_size = 128 } },
  prerequisites = { "treez-sapling-growth-2" },
  effects       = {},
  unit          = _sapling_unit_3,
} })

data:extend({ {
  type          = "technology",
  name          = "treez-sapling-growth-4",
  icons         = { { icon = "__treez-base-game__/graphics/icons/sappling-research-4.png", icon_size = 128 } },
  prerequisites = { "treez-sapling-growth-3" },
  effects       = {},
  unit          = _sapling_unit_4,
} })

data:extend({ {
  type          = "technology",
  name          = "treez-sapling-growth-5",
  icons         = { { icon = "__treez-base-game__/graphics/icons/sappling-research-5.png", icon_size = 128 } },
  prerequisites = { "treez-sapling-growth-4" },
  effects       = {},
  unit          = _sapling_unit_5,
} })

data:extend({ {
  type          = "technology",
  name          = "treez-sapling-growth-6",
  icons         = { { icon = "__treez-base-game__/graphics/icons/sappling-research-6.png", icon_size = 128 } },
  prerequisites = { "treez-sapling-growth-5" },
  effects       = {},
  unit          = _sapling_unit_6,
} })

-- ============================================================
-- Soil Crystal item + entity
-- ============================================================

local _crystal_icons = { {
  icon      = "__treez-base-game__/graphics/icons/soil-crystal.png",
  icon_size = 32,
} }

local _crystal_white_icons = { {
  icon      = "__treez-base-game__/graphics/icons/soil-crystal-rare-white.png",
  icon_size = 64,
} }

local _crystal_black_icons = { {
  icon      = "__treez-base-game__/graphics/icons/soil-crystal-rare-black.png",
  icon_size = 64,
} }

data:extend({ {
  type         = "item",
  name         = "soil-crystal",
  icons        = _crystal_white_icons,
  subgroup     = "seeds",
  order        = "b[soil-crystal]",
  stack_size   = 200,
  place_result = "soil-crystal-site",
} })

data:extend({ {
  type            = "recipe",
  name            = "soil-crystal",
  enabled         = false,
  energy_required = 2,
  category        = "chemistry",
  ingredients     = {
    { type = "item",  name = "wood",          amount = 6    },
    { type = "item",  name = "stone",         amount = 1    },
    { type = "fluid", name = "water",         amount = 100  },
    { type = "fluid", name = "sulfuric-acid", amount = 10   },
  },
  results = { { type = "item", name = "soil-crystal", amount = 5 } },
} })

-- ============================================================
-- Local Nitrate Pellets (black) — item, recipe, entity
-- Unlocked by treez-primitive-nitrates technology.
-- Hand-craftable (no assembler required). Fast and cheap.
-- Uses a dedicated black entity (soil-crystal-black-site) so the
-- firing logic can identify and restrict these pellets to a search
-- radius of 1, no catalyst spawning, no rain placement, and no
-- Enduring Nitrates re-queuing.
-- ============================================================
data:extend({ {
  type         = "item",
  name         = "soil-crystal-black",
  icons        = _crystal_black_icons,
  subgroup     = "seeds",
  order        = "b[soil-crystal-black]",
  stack_size   = 200,
  place_result = "soil-crystal-black-site",
} })

data:extend({ {
  type            = "recipe",
  name            = "soil-crystal-black",
  enabled         = false,
  energy_required = 0.5,
  category        = "crafting",
  ingredients     = {
    { type = "item", name = "wood",  amount = 2 },
    { type = "item", name = "stone", amount = 1 },
    { type = "item", name = "coal",  amount = 1 },
  },
  results = { { type = "item", name = "soil-crystal-black", amount = 1 } },
} })

data:extend({ {
  type                = "simple-entity-with-owner",
  name                = "soil-crystal-site",
  flags               = { "placeable-neutral", "player-creation" },
  icons               = _crystal_icons,
  items_to_place_this = { { count = 1, item = "soil-crystal" } },
  max_health          = 10,
  minable             = { mining_time = 0.1, result = "soil-crystal" },
  picture = {
    filename = "__treez-base-game__/graphics/icons/soil-crystal-rare-white.png",
    width    = 64,
    height   = 64,
    scale    = 0.5,
    priority = "extra-high",
  },
  collision_box = { { -0.1, -0.1 }, { 0.1, 0.1 } },
  selection_box = { { -0.4, -0.4 }, { 0.4, 0.4 } },
} })

-- ============================================================
-- Primitive Nitrate Pellet entity (black)
-- ============================================================
-- Placed by the player using the soil-crystal-black item.
-- Identified in control.lua by name so the firing logic can apply
-- radius-1 border search, skip catalyst spawning, skip rain placement,
-- and skip Enduring Nitrates re-queuing.
data:extend({ {
  type                = "simple-entity-with-owner",
  name                = "soil-crystal-black-site",
  flags               = { "placeable-neutral", "player-creation" },
  icons               = _crystal_black_icons,
  items_to_place_this = { { count = 1, item = "soil-crystal-black" } },
  max_health          = 10,
  minable             = { mining_time = 0.1, result = "soil-crystal-black" },
  picture = {
    filename = "__treez-base-game__/graphics/icons/soil-crystal-rare-black.png",
    width    = 64,
    height   = 64,
    scale    = 0.5,
    priority = "extra-high",
  },
  collision_box = { { -0.1, -0.1 }, { 0.1, 0.1 } },
  selection_box = { { -0.4, -0.4 }, { 0.4, 0.4 } },
} })

-- ============================================================
-- Colored Nitrate Pellet entity
-- ============================================================
-- Spawned programmatically (1-in-N on placement). Absorbs pollution while
-- queued. Fires identically to a normal pellet. Uses the coloured polkadot art.
data:extend({ {
  type                = "simple-entity-with-owner",
  name                = "soil-crystal-colored-site",
  flags               = { "placeable-neutral" },
  icons               = { {
    icon      = "__treez-base-game__/graphics/icons/soil-crystal-rare.png",
    icon_size = 64,
  } },
  max_health          = 10,
  -- A minable.result gives the entity a paired item, which is what construction
  -- robots need to deconstruct it (an entity that is minable but yields nothing
  -- is unreliable for bot deconstruction). Returning the white "soil-crystal"
  -- item also satisfies the design intent that a mined colored pellet hands back
  -- a regular white pellet. Player hand-mining while trample mode is on still
  -- yields nothing — the on_player_mined_entity trample handler clears the buffer.
  minable             = { mining_time = 0.1, result = "soil-crystal" },
  picture = {
    filename = "__treez-base-game__/graphics/icons/soil-crystal-rare.png",
    width    = 64,
    height   = 64,
    scale    = 0.5,
    priority = "extra-high",
  },
  collision_box = { { -0.1, -0.1 }, { 0.1, 0.1 } },
  selection_box = { { -0.5, -0.5 }, { 0.5, 0.5 } },
} })

-- ============================================================
-- Crystal Placer recipe (locked; unlocked by soil-crystal technology)
-- ============================================================
data:extend({ {
  type        = "recipe",
  name        = "crystal-placer",
  enabled     = false,
  ingredients = {},
  results     = { { type = "item", name = "crystal-placer", amount = 1 } },
} })

-- ============================================================
-- Crystal Placer area tool
-- Works like the Tree Seeder but places soil-crystal-site ghosts.
-- Robots fulfil the ghosts using soil-crystal items from the network.
-- ============================================================

data:extend({ {
  action       = "lua",
  consuming    = "none",
  key_sequence = "",
  name         = "crystal-placer",
  type         = "custom-input",
} })

data:extend({ {
  action                   = "lua",
  associated_control_input = "crystal-placer",
  icons                    = _crystal_white_icons,
  name                     = "crystal-placer",
  small_icons              = _crystal_white_icons,
  technology_to_unlock     = "soil-crystal",
  type                     = "shortcut",
} })

data:extend({ {
  type       = "selection-tool",
  name       = "crystal-placer",
  flags      = { "only-in-cursor", "spawnable" },
  icons      = _crystal_white_icons,
  order      = "z[crystal-placer]",
  subgroup   = "seeds",
  stack_size = 1,
  select = {
    border_color    = { r = 0.35, g = 0.80, b = 1.00 },
    color           = { r = 0.35, g = 0.80, b = 1.00, a = 0.30 },
    cursor_box_type = "copy",
    mode            = { "nothing" },
  },
  alt_select = {
    border_color    = { r = 0.8, g = 0.2, b = 0.1 },
    color           = { r = 0.8, g = 0.2, b = 0.1, a = 0.5 },
    cursor_box_type = "not-allowed",
    mode            = { "nothing" },
  },
} })

-- ============================================================
-- White pellet pollution reduction (5 explicit levels)
-- Each level reduces white pellet emission by 1 pollution/min
-- (default 5/min → 0/min at max level).
-- Defined as separate technologies so each prerequisite chain is
-- explicit and cannot be reassigned by overhaul mods like SE.
-- ============================================================
local _white_pollution_unit = {
    count       = 100,
    ingredients = {
      { "automation-science-pack", 1 },
      { "logistic-science-pack",   1 },
      { "chemical-science-pack",   1 },
    },
    time = 30,
  }

data:extend({ {
  type          = "technology",
  name          = "soil-crystal-white-pollution-1",
  icons         = _crystal_white_icons,
  prerequisites = { "soil-crystal" },
  unit          = _white_pollution_unit,
  effects       = {},
} })

data:extend({ {
  type          = "technology",
  name          = "soil-crystal-white-pollution-2",
  icons         = _crystal_white_icons,
  prerequisites = { "soil-crystal-white-pollution-1" },
  unit          = _white_pollution_unit,
  effects       = {},
} })

data:extend({ {
  type          = "technology",
  name          = "soil-crystal-white-pollution-3",
  icons         = _crystal_white_icons,
  prerequisites = { "soil-crystal-white-pollution-2" },
  unit          = _white_pollution_unit,
  effects       = {},
} })

data:extend({ {
  type          = "technology",
  name          = "soil-crystal-white-pollution-4",
  icons         = _crystal_white_icons,
  prerequisites = { "soil-crystal-white-pollution-3" },
  unit          = _white_pollution_unit,
  effects       = {},
} })

data:extend({ {
  type          = "technology",
  name          = "soil-crystal-white-pollution-5",
  icons         = _crystal_white_icons,
  prerequisites = { "soil-crystal-white-pollution-4" },
  unit          = _white_pollution_unit,
  effects       = {},
} })

-- ============================================================
-- Nitrate Catalyst technology
-- ============================================================
-- Unlocks colored pellets (Nitrate Catalysts). Before this research
-- no colored pellets will spawn. After research, 10% of placed pellets
-- become colored. Colored pellets are pollution-neutral and chain-trigger
-- a nearby pellet when they fire.
data:extend({ {
  type          = "technology",
  name          = "soil-crystal-catalyst",
  icons         = { { icon = "__treez-base-game__/graphics/icons/soil-crystal-rare.png", icon_size = 64 } },
  prerequisites = { "soil-crystal" },
  unit          = {
    count       = 100,
    ingredients = {
      { "automation-science-pack", 1 },
      { "logistic-science-pack",   1 },
      { "chemical-science-pack",   1 },
    },
    time = 30,
  },
  effects = {},
} })

-- ============================================================
-- Abundant Nitrate Catalyst (2 levels)
-- Each level increases the colored-pellet spawn probability.
-- Locale key: soil-crystal-catalyst-abundant (Factorio appends the level number)
-- ============================================================
local _catalyst_unit = {
    count       = 100,
    ingredients = {
      { "automation-science-pack", 1 },
      { "logistic-science-pack",   1 },
      { "chemical-science-pack",   1 },
    },
    time = 30,
  }

data:extend({ {
  type          = "technology",
  name          = "soil-crystal-catalyst-abundant-1",
  icons         = { { icon = "__treez-base-game__/graphics/icons/soil-crystal-rare.png", icon_size = 64 } },
  prerequisites = { "soil-crystal-catalyst" },
  unit          = _catalyst_unit,
  effects       = {},
} })

data:extend({ {
  type          = "technology",
  name          = "soil-crystal-catalyst-abundant-2",
  icons         = { { icon = "__treez-base-game__/graphics/icons/soil-crystal-rare.png", icon_size = 64 } },
  prerequisites = { "soil-crystal-catalyst-abundant-1" },
  unit          = _catalyst_unit,
  effects       = {},
} })

-- ============================================================
-- Nitrate Catalyst Reactions (3 levels; reactions-3 defined in the extensions
-- block below). Each level scales both the chain reach and the trigger count
-- together via storage.catalyst_chain_count: L1 -> radius 2 / 2 pellets,
-- L2 -> radius 3 / 3, L3 -> radius 4 / 4. With no levels it is radius 1 / 1.
-- Locale key: soil-crystal-catalyst-reactions
-- ============================================================
data:extend({ {
  type          = "technology",
  name          = "soil-crystal-catalyst-reactions-1",
  icons         = { { icon = "__treez-base-game__/graphics/icons/soil-crystal-rare.png", icon_size = 64 } },
  prerequisites = { "soil-crystal-catalyst" },
  unit          = _catalyst_unit,
  effects       = {},
} })

data:extend({ {
  type          = "technology",
  name          = "soil-crystal-catalyst-reactions-2",
  icons         = { { icon = "__treez-base-game__/graphics/icons/soil-crystal-rare.png", icon_size = 64 } },
  prerequisites = { "soil-crystal-catalyst-reactions-1" },
  unit          = _catalyst_unit,
  effects       = {},
} })

-- ============================================================
-- Abundant Nitrate Catalyst 3 and Reactions 3 extensions
-- ============================================================
data:extend({ {
  type          = "technology",
  name          = "soil-crystal-catalyst-abundant-3",
  icons         = { { icon = "__treez-base-game__/graphics/icons/soil-crystal-rare.png", icon_size = 64 } },
  prerequisites = { "soil-crystal-catalyst-abundant-2" },
  unit          = _catalyst_unit,
  effects       = {},
} })

data:extend({ {
  type          = "technology",
  name          = "soil-crystal-catalyst-reactions-3",
  icons         = { { icon = "__treez-base-game__/graphics/icons/soil-crystal-rare.png", icon_size = 64 } },
  prerequisites = { "soil-crystal-catalyst-reactions-2" },
  unit          = _catalyst_unit,
  effects       = {},
} })

-- ============================================================
-- Primitive Nitrates technology
-- Early-game gate for crude nitrate pellet crafting.
-- Requires only automation + logistic science packs (no chemical).
-- Unlocks soil-crystal-black recipe (hand-craftable, fast, cheap).
-- The main soil-crystal technology (chemical plant recipe) requires
-- this as a prerequisite, enforcing natural progression.
-- ============================================================
data:extend({ {
  type          = "technology",
  name          = "treez-primitive-nitrates",
  icons         = _crystal_black_icons,
  prerequisites = { "logistic-science-pack" },
  unit          = {
    count       = 10,
    ingredients = {
      { "automation-science-pack", 1 },
      { "logistic-science-pack",   1 },
    },
    time = 30,
  },
  effects = {
    { type = "unlock-recipe", recipe = "soil-crystal-black" },
  },
} })

-- ============================================================
-- Soil Crystal technology
-- ============================================================
data:extend({ {
  type          = "technology",
  name          = "soil-crystal",
  icons         = _crystal_white_icons,
  prerequisites = { "treez-primitive-nitrates", "chemical-science-pack" },
  unit          = {
    count       = 100,
    ingredients = {
      { "automation-science-pack", 1 },
      { "logistic-science-pack",   1 },
      { "chemical-science-pack",   1 },
    },
    time = 30,
  },
  effects = {
    { type = "unlock-recipe", recipe = "soil-crystal" },
  },
} })

-- ============================================================
-- Cloud Seeding technologies (levels 1–6)
-- Only registered when Dynamic Rain is installed.
-- Each level allows one additional tree seed to be scattered in
-- chunks where rain has just washed away all pollution.
-- Chain: treez-sapling-growth-1 → cloudseeding-1 → 2 → 3 → 4 → 5 → 6
-- Each level also requires the matching sapling-growth level.
-- Cost mirrors sapling growth (10/20/40/80/160/320 automation packs),
-- but at 60 seconds per unit instead of 30.
-- Prerequisites and units are re-asserted in data-final-fixes.lua so
-- overhaul mods cannot inject extra packs or relink the chain.
-- ============================================================
if mods["dynamic-rain"] then
  local _cs_prereqs = {
    { "treez-sapling-growth-1", "treez-arboreal-aromatics" },
    { "treez-cloudseeding-1", "treez-sapling-growth-2" },
    { "treez-cloudseeding-2", "treez-sapling-growth-3" },
    { "treez-cloudseeding-3", "treez-sapling-growth-4" },
    { "treez-cloudseeding-4", "treez-sapling-growth-5" },
    { "treez-cloudseeding-5", "treez-sapling-growth-6" },
  }
  local _cs_counts = { 10, 20, 40, 80, 160, 320 }

  for i = 1, 6 do
    data:extend({ {
      type          = "technology",
      name          = "treez-cloudseeding-" .. i,
      icons         = { {
        icon      = "__treez-base-game__/graphics/icons/cloudseeding-" .. i .. ".png",
        icon_size = 128,
      } },
      prerequisites = _cs_prereqs[i],
      effects       = {},
      unit          = {
        count       = _cs_counts[i],
        ingredients = {
          { "automation-science-pack", 1 },
        },
        time = 60,
      },
    } })
  end
end

-- ============================================================
-- Sapling Soil Enrichment technologies (levels 1–6)
-- Each level adds a 1% chance (cumulative up to 6%) of upgrading the
-- tile beneath a sapling once per intermediate growth stage advance.
-- On a successful roll, the tile directly under the sapling is upgraded
-- first; if already at maximum quality, a random tile within a radius
-- equal to the research level is upgraded instead.
--
-- Prerequisites:
--   Level 1: soil-crystal + treez-sapling-growth-1
--   Level N: treez-soil-enrichment-(N-1)
--            + soil-crystal-white-pollution-(N-1)
--            + treez-sapling-growth-N
--
-- Cost mirrors sapling growth (10/20/40/80/160/320) but requires
-- automation, logistic, and chemical science packs at 60 s each.
-- Prerequisites and units are re-asserted in data-final-fixes.lua.
-- ============================================================
local _se_unit_1 = { count =  10, ingredients = { { "automation-science-pack", 1 }, { "logistic-science-pack", 1 }, { "chemical-science-pack", 1 } }, time = 60 }
local _se_unit_2 = { count =  20, ingredients = { { "automation-science-pack", 1 }, { "logistic-science-pack", 1 }, { "chemical-science-pack", 1 } }, time = 60 }
local _se_unit_3 = { count =  40, ingredients = { { "automation-science-pack", 1 }, { "logistic-science-pack", 1 }, { "chemical-science-pack", 1 } }, time = 60 }
local _se_unit_4 = { count =  80, ingredients = { { "automation-science-pack", 1 }, { "logistic-science-pack", 1 }, { "chemical-science-pack", 1 } }, time = 60 }
local _se_unit_5 = { count = 160, ingredients = { { "automation-science-pack", 1 }, { "logistic-science-pack", 1 }, { "chemical-science-pack", 1 } }, time = 60 }
local _se_unit_6 = { count = 320, ingredients = { { "automation-science-pack", 1 }, { "logistic-science-pack", 1 }, { "chemical-science-pack", 1 } }, time = 60 }
local _se_units = { _se_unit_1, _se_unit_2, _se_unit_3, _se_unit_4, _se_unit_5, _se_unit_6 }

local _se_prereqs = {
  { "soil-crystal",             "treez-sapling-growth-1" },
  { "treez-soil-enrichment-1",  "soil-crystal-white-pollution-1", "treez-sapling-growth-2" },
  { "treez-soil-enrichment-2",  "soil-crystal-white-pollution-2", "treez-sapling-growth-3" },
  { "treez-soil-enrichment-3",  "soil-crystal-white-pollution-3", "treez-sapling-growth-4" },
  { "treez-soil-enrichment-4",  "soil-crystal-white-pollution-4", "treez-sapling-growth-5" },
  { "treez-soil-enrichment-5",  "soil-crystal-white-pollution-5", "treez-sapling-growth-6" },
}

for i = 1, 6 do
  data:extend({ {
    type          = "technology",
    name          = "treez-soil-enrichment-" .. i,
    icons         = { {
      icon      = "__treez-base-game__/graphics/icons/sappling-soil-enrichment-" .. i .. ".png",
      icon_size = 128,
    } },
    prerequisites = _se_prereqs[i],
    effects       = {},
    unit          = _se_units[i],
  } })
end

-- ============================================================
-- Restorative Rains technology (1 level)
-- Requires Dynamic Rain.  While it is raining, credits accumulate
-- for each chunk that has pollution removed.  Every 20 seconds those
-- credits are spent to place nitrate pellets in the cleaned chunks,
-- queued to fire the coming night.  Can be disabled at any time via
-- the "treez-restorative-rains-enabled" runtime-global setting.
-- Prerequisites: soil-crystal + treez-sapling-growth-1
-- Cost: 150 automation + logistic + chemical packs at 60 s.
-- ============================================================
if mods["dynamic-rain"] then
  -- When Space Exploration is installed, gate behind the se-rocket-science-pack
  -- technology (same name as the item; unlocked after rocket-silo) as both a
  -- prerequisite and an ingredient.  Without SE, use vanilla space-science-pack
  -- as both a technology prerequisite and a research ingredient.
  local _rr_prereqs
  local _rr_space_pack
  if mods["space-exploration"] then
    _rr_prereqs    = { "soil-crystal", "treez-sapling-growth-1", "se-rocket-science-pack" }
    _rr_space_pack = "se-rocket-science-pack"
  else
    _rr_prereqs    = { "soil-crystal", "treez-sapling-growth-1", "space-science-pack" }
    _rr_space_pack = "space-science-pack"
  end
  data:extend({ {
    type          = "technology",
    name          = "treez-restorative-rains",
    icons         = { {
      icon      = "__treez-base-game__/graphics/icons/restorative-rains.png",
      icon_size = 128,
    } },
    prerequisites = _rr_prereqs,
    effects       = {},
    unit          = {
      count       = 150,
      ingredients = {
        { "automation-science-pack", 1 },
        { "logistic-science-pack",   1 },
        { "chemical-science-pack",   1 },
        { _rr_space_pack,            1 },
      },
      time = 60,
    },
  } })
end

-- ============================================================
-- Arboreal Aromatics technology (1 level)
-- Requires Dynamic Rain.  Represents the study of volatile organic
-- compounds released by trees and their interaction with rain-borne
-- aerosols.  Does not grant direct effects; instead it gates
-- Cloud Seeding research, ensuring the player has explored the
-- rain-soil feedback loop before pursuing atmospheric seeding.
--
-- Space science gate:
--   SE present  → se-rocket-science-pack technology as a prerequisite AND
--                 ingredient (the SE tech that unlocks the pack, gated behind
--                 rocket-silo + speed-module + advanced-material-processing-2).
--   SE absent   → space-science-pack as both a tech prerequisite AND an
--                 ingredient, so the rocket milestone is a hard gate.
-- ============================================================
if mods["dynamic-rain"] then
  local _aa_prereqs
  local _aa_space_pack
  if mods["space-exploration"] then
    _aa_prereqs    = { "soil-crystal", "treez-sapling-growth-1", "se-rocket-science-pack" }
    _aa_space_pack = "se-rocket-science-pack"
  else
    _aa_prereqs    = { "soil-crystal", "treez-sapling-growth-1", "space-science-pack" }
    _aa_space_pack = "space-science-pack"
  end
  data:extend({ {
    type          = "technology",
    name          = "treez-arboreal-aromatics",
    icons         = { {
      icon      = "__treez-base-game__/graphics/icons/restorative-rains.png",
      icon_size = 128,
    } },
    prerequisites = _aa_prereqs,
    effects       = {},
    unit          = {
      count       = 150,
      ingredients = {
        { "automation-science-pack", 1 },
        { "logistic-science-pack",   1 },
        { "chemical-science-pack",   1 },
        { _aa_space_pack,            1 },
      },
      time = 60,
    },
  } })
end

-- ============================================================
-- Enduring Nitrates technologies (levels 1–3)
-- Each level adds a 10% cumulative chance (up to 30%) that a normal
-- nitrate pellet survives firing and is re-queued to fire again the
-- next night.  Does not apply to rare or colored pellets.
-- Gate: soil-crystal-catalyst-abundant-1 → level 1 → 2 → 3
-- Cost matches catalyst research: 100 auto + logistic + chemical at 30 s.
-- ============================================================
local _en_prereqs = {
  { "soil-crystal-catalyst-abundant-1", "soil-crystal-catalyst-reactions-1" },
  { "treez-enduring-nitrates-1", "soil-crystal-catalyst-abundant-2", "soil-crystal-catalyst-reactions-2" },
  { "treez-enduring-nitrates-2", "soil-crystal-catalyst-abundant-3", "soil-crystal-catalyst-reactions-3" },
}

for i = 1, 3 do
  data:extend({ {
    type          = "technology",
    name          = "treez-enduring-nitrates-" .. i,
    icons         = { {
      icon      = "__treez-base-game__/graphics/icons/enduring-nitrates.png",
      icon_size = 128,
    } },
    prerequisites = _en_prereqs[i],
    effects       = {},
    unit          = _catalyst_unit,   -- matches catalyst: 100 packs, 30 s
  } })
end
