-- settings.lua
-- Tree settings sort first (a–d); pellet/crystal settings follow (e–q).

-- ── Tree growth ───────────────────────────────────────────────────────────────
data:extend({ {
  type           = "string-setting",
  name           = "treez-tree-growth-speed",
  setting_type   = "runtime-global",
  default_value  = "smooth",
  allowed_values = { "instant", "fast", "smooth" },
  order          = "a",
} })

data:extend({ {
  type           = "string-setting",
  name           = "treez-tree-growth-variability",
  setting_type   = "runtime-global",
  default_value  = "100",
  allowed_values = { "0", "25", "50", "75", "100" },
  hidden         = true,
  order          = "b",
} })

data:extend({ {
  type          = "int-setting",
  name          = "treez-tree-growth-max-active",
  setting_type  = "runtime-global",
  default_value = 1,
  hidden        = true,
} })

data:extend({ {
  type          = "bool-setting",
  name          = "treez-tree-growth-day-only",
  setting_type  = "runtime-global",
  default_value = true,
  order         = "d",
} })

data:extend({ {
  type          = "bool-setting",
  name          = "treez-tree-growth-pollution-delay",
  setting_type  = "runtime-global",
  default_value = true,
  order         = "d1",
} })

data:extend({ {
  type          = "bool-setting",
  name          = "treez-tree-growth-enrich-soil",
  setting_type  = "runtime-global",
  default_value = true,
  hidden        = true,
  order         = "d2",
} })

-- ── Pellet timing ─────────────────────────────────────────────────────────────
-- Delay is expressed in nights. Night length is read from the surface so mods
-- that adjust the day/night cycle are respected.
-- Variance is applied symmetrically (±nights), clamped so delay − variance ≥ 1.
data:extend({ {
  type          = "int-setting",
  name          = "treez-crystal-delay-nights",
  setting_type  = "runtime-global",
  default_value = 2,
  minimum_value = 1,
  order         = "e",
} })

data:extend({ {
  type          = "int-setting",
  name          = "treez-crystal-variance-nights",
  setting_type  = "runtime-global",
  default_value = 1,
  minimum_value = 0,
  hidden        = true,
  order         = "f",
} })

data:extend({ {
  type          = "int-setting",
  name          = "treez-crystal-batch-size",
  setting_type  = "runtime-global",
  default_value = 10,
  minimum_value = 1,
  order         = "g",
} })

data:extend({ {
  type          = "bool-setting",
  name          = "treez-crystal-night-only",
  setting_type  = "runtime-global",
  default_value = true,
  order         = "h",
} })

-- ── Overflow drain ────────────────────────────────────────────────────────────
-- When the pellet queue grows past the threshold (e.g. after a big rainstorm),
-- the processor switches from the fixed batch size to draining a percentage of
-- the queue per night so large backlogs clear in a few nights instead of dozens.
data:extend({ {
  type          = "int-setting",
  name          = "treez-crystal-overflow-threshold",
  setting_type  = "runtime-global",
  default_value = 2000,
  minimum_value = 0,
  order         = "i",
} })

data:extend({ {
  type          = "int-setting",
  name          = "treez-crystal-overflow-percent",
  setting_type  = "runtime-global",
  default_value = 40,
  minimum_value = 1,
  maximum_value = 100,
  order         = "j",
} })

-- ── Normal pellet pollution ───────────────────────────────────────────────────
data:extend({ {
  type          = "double-setting",
  name          = "treez-crystal-pollution-rate",
  setting_type  = "runtime-global",
  default_value = 5.0,
  minimum_value = 0,
  hidden        = true,
  order         = "i",
} })

-- ── Trample ───────────────────────────────────────────────────────────────────
data:extend({ {
  type          = "bool-setting",
  name          = "treez-fertilizer-trample",
  setting_type  = "runtime-global",
  default_value = true,
  order         = "j",
} })

-- Hidden: radius tuned to 0.9; expose again if further tuning is needed.
data:extend({ {
  type          = "double-setting",
  name          = "treez-trample-player-radius",
  setting_type  = "runtime-global",
  default_value = 0.9,
  minimum_value = 0.1,
  hidden        = true,
  order         = "j1",
} })

-- ── Upgrade paths ─────────────────────────────────────────────────────────────
data:extend({ {
  type          = "bool-setting",
  name          = "treez-randomize-upgrades",
  setting_type  = "runtime-global",
  default_value = false,
  order         = "k",
} })

-- ── Ghost collision sweeps ─────────────────────────────────────────────────────
data:extend({ {
  type          = "bool-setting",
  name          = "treez-foreign-tree-sweep",
  setting_type  = "runtime-global",
  default_value = true,
  order         = "k1",
} })

-- ── Colored pellet mechanics ──────────────────────────────────────────────────
data:extend({ {
  type          = "int-setting",
  name          = "treez-crystal-colored-chance",
  setting_type  = "runtime-global",
  default_value = 10,
  minimum_value = 1,
  hidden        = true,
  order         = "l",
} })

-- ── Dynamic Rain integration ───────────────────────────────────────────────
-- Only registered when dynamic-rain is installed; invisible otherwise.
if mods["dynamic-rain"] then
  data:extend({ {
    type          = "bool-setting",
    name          = "treez-rain-growth-boost",
    setting_type  = "runtime-global",
    default_value = true,
    order         = "r",
  } })

  -- Rain seed drop: scatter seeds in chunks whose pollution rain just cleared.
  data:extend({ {
    type          = "bool-setting",
    name          = "treez-rain-seed-enabled",
    setting_type  = "runtime-global",
    default_value = true,
    order         = "s",
  } })

  -- Debug toggle: log chunk-cleaned events and seed placement; reveal chunk on map.
  data:extend({ {
    type          = "bool-setting",
    name          = "treez-rain-seed-debug",
    setting_type  = "runtime-global",
    default_value = false,
    order         = "s1",
  } })

  -- Restorative Rains: allow disabling nitrate placement during rain even after
  -- the technology has been researched.  Useful if the player decides the
  -- mechanic doesn't fit their playthrough without restarting the map.
  data:extend({ {
    type          = "bool-setting",
    name          = "treez-restorative-rains-enabled",
    setting_type  = "runtime-global",
    default_value = true,
    order         = "t",
  } })
end
