local _seed      = data.raw.item["tree-seed"]
local _icon      = _seed and _seed.icon      or "__core__/graphics/empty.png"
local _icon_size = _seed and _seed.icon_size or 64

data:extend({ {
  type         = "custom-input",
  name         = "tree-seeder",
  key_sequence = "",
  action       = "lua",
  consuming    = "none",
} })

data:extend({ {
  type                     = "shortcut",
  name                     = "tree-seeder",
  action                   = "lua",
  associated_control_input = "tree-seeder",
  icon                     = _icon,
  icon_size                = _icon_size,
  small_icon               = _icon,
  small_icon_size          = _icon_size,
} })

data:extend({ {
  type       = "selection-tool",
  name       = "tree-seeder",
  flags      = { "only-in-cursor", "spawnable" },
  icon       = _icon,
  icon_size  = _icon_size,
  order      = "z[tree-seeder]",
  subgroup   = "seeds",
  stack_size = 1,
  select = {
    border_color    = { r = 0.1, g = 0.8, b = 0.1 },
    color           = { r = 0.1, g = 0.8, b = 0.1, a = 0.5 },
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
