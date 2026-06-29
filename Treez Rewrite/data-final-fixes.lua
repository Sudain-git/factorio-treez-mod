local tree_seed_item = data.raw.item["tree-seed"]
if not tree_seed_item then return end

local original_entity = tree_seed_item.place_result
if not original_entity then return end

data:extend({ {
  type         = "item",
  name         = "tree-entity-ref",
  hidden       = true,
  icon         = tree_seed_item.icon      or "__core__/graphics/empty.png",
  icon_size    = tree_seed_item.icon_size or 64,
  place_result = original_entity,
  stack_size   = 1,
  subgroup     = "seeds",
} })

local tree_proto = data.raw.plant[original_entity] or data.raw.tree[original_entity]
if tree_proto then
  local site = data.raw["simple-entity-with-owner"]["tree-seed-site"]
  if tree_proto.collision_mask        then site.collision_mask        = tree_proto.collision_mask        end
  if tree_proto.tile_buildability_rules then site.tile_buildability_rules = tree_proto.tile_buildability_rules end
  if tree_proto.collision_box         then site.collision_box         = tree_proto.collision_box         end
end

tree_seed_item.place_result = "tree-seed-site"
