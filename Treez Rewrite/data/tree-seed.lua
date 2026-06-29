local _seed      = data.raw.item["tree-seed"]
local _icon      = _seed and _seed.icon      or "__core__/graphics/empty.png"
local _icon_size = _seed and _seed.icon_size or 64

if not data.raw["item-subgroup"]["seeds"] then
  data:extend({ {
    type  = "item-subgroup",
    name  = "seeds",
    group = "production",
    order = "z",
  } })
end

data:extend({ {
  type                = "simple-entity-with-owner",
  name                = "tree-seed-site",
  flags               = { "placeable-neutral", "player-creation" },
  icon                = _icon,
  icon_size           = _icon_size,
  items_to_place_this = { { count = 1, item = "tree-seed" } },
  max_health          = 10,
  minable             = { mining_time = 0.1, result = "tree-seed" },
  collision_box       = { { -0.1, -0.1 }, { 0.1, 0.1 } },
  selection_box       = { { -0.5, -0.5 }, { 0.5, 0.5 } },
  picture = {
    filename = _icon,
    width    = _icon_size,
    height   = _icon_size,
    priority = "extra-high",
    scale    = 0.5,
  },
} })
