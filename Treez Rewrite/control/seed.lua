local ref_item   = prototypes.item["tree-entity-ref"]
local TREE_ENTITY = ref_item and ref_item.place_result and ref_item.place_result.name
if not TREE_ENTITY then
  log("[treez] ERROR: tree-entity-ref missing. Tree planting disabled.")
end

local SITE_NAME = "tree-seed-site"

local function handle_site(entity)
  if not entity.valid then return end
  local force    = entity.force
  local position = entity.position
  local surface  = entity.surface
  entity.destroy({ raise_destroy = false })

  if not TREE_ENTITY then return end
  if surface.platform ~= nil then return end
  if not surface.can_place_entity({ force = force, name = TREE_ENTITY, position = position }) then return end

  surface.create_entity({
    force       = force,
    name        = TREE_ENTITY,
    position    = position,
    raise_built = true,
  })
end

script.on_event(defines.events.on_robot_built_entity, function(event)
  handle_site(event.entity)
end, { { filter = "name", name = SITE_NAME } })

script.on_event(defines.events.on_built_entity, function(event)
  handle_site(event.entity)
end, { { filter = "name", name = SITE_NAME } })
