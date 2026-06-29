local DEFAULT_DENSITY = 90
local GUI_NAME        = "tree-seeder-gui"
local SEEDER_NAME     = "tree-seeder"
local SITE_NAME       = "tree-seed-site"

local function get_player_data(player_index)
  if not storage.tree then storage.tree = {} end
  if not storage.tree[player_index] then
    storage.tree[player_index] = { density = DEFAULT_DENSITY }
  end
  return storage.tree[player_index]
end

local function close_gui(player)
  local frame = player.gui.screen[GUI_NAME]
  if frame then frame.destroy() end
end

local function open_gui(player)
  local pd    = get_player_data(player.index)
  local frame = player.gui.screen.add({
    type      = "frame",
    name      = GUI_NAME,
    caption   = { "tree-gui.title" },
    direction = "vertical",
  })
  player.opened = frame
  local row = frame.add({ type = "flow", name = "tree-density-row", direction = "horizontal" })
  row.style.vertical_align     = "center"
  row.style.horizontal_spacing = 8
  row.add({ type = "label", caption = { "tree-gui.density-label" } })
  row.add({
    type            = "slider",
    name            = "tree-density-slider",
    minimum_value   = 10,
    maximum_value   = 100,
    value           = pd.density,
    value_step      = 5,
    discrete_slider = true,
  })
  row.add({ type = "label", name = "tree-density-label", caption = pd.density .. "%" })
end

script.on_event(defines.events.on_lua_shortcut, function(event)
  if event.prototype_name ~= SEEDER_NAME then return end
  local player = game.players[event.player_index]
  if player.gui.screen[GUI_NAME] then
    close_gui(player)
  else
    open_gui(player)
    player.cursor_stack.set_stack({ count = 1, name = SEEDER_NAME })
  end
end)

script.on_event(defines.events.on_gui_value_changed, function(event)
  if event.element.name ~= "tree-density-slider" then return end
  local player = game.players[event.player_index]
  local pd     = get_player_data(event.player_index)
  pd.density   = math.floor(event.element.slider_value)
  local frame  = player.gui.screen[GUI_NAME]
  if frame then
    frame["tree-density-row"]["tree-density-label"].caption = pd.density .. "%"
  end
end)

script.on_event(defines.events.on_gui_closed, function(event)
  if event.element and event.element.name == GUI_NAME then
    event.element.destroy()
  end
end)

script.on_event(defines.events.on_player_selected_area, function(event)
  if event.item ~= SEEDER_NAME then return end
  local player  = game.players[event.player_index]
  local pd      = get_player_data(event.player_index)
  local density = pd.density / 100
  local surface = player.surface
  local force   = player.force
  local area    = event.area
  local x1 = math.floor(area.left_top.x)
  local y1 = math.floor(area.left_top.y)
  local x2 = math.floor(area.right_bottom.x) - 1
  local y2 = math.floor(area.right_bottom.y) - 1
  for tx = x1, x2 do
    for ty = y1, y2 do
      if math.random() < density then
        local pos = { x = tx + 0.5, y = ty + 0.5 }
        if surface.can_place_entity({ force = force, name = SITE_NAME, position = pos }) then
          surface.create_entity({
            force       = force,
            inner_name  = SITE_NAME,
            name        = "entity-ghost",
            position    = pos,
            raise_built = false,
          })
        end
      end
    end
  end
end)
