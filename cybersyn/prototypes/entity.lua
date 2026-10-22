--By Mami
combinator_entity = flib.copy_prototype(data.raw["arithmetic-combinator"]["arithmetic-combinator"], COMBINATOR_NAME)
combinator_entity.icon = "__cybersyn__/graphics/icons/cybernetic-combinator.png"
combinator_entity.radius_visualisation_specification = {
	sprite = {
		filename = "__cybersyn__/graphics/icons/area-of-effect.png",
		tint = { r = 1, g = 1, b = 0, a = .5 },
		height = 64,
		width = 64,
	},
	--offset = {0, .5},
	distance = 1.5,
}
combinator_entity.active_energy_usage = "10kW"
combinator_entity.fast_replaceable_group = COMBINATOR_NAME

if mods["nullius"] then
	combinator_entity.localised_name = { "entity-name.cybersyn-combinator" }
end

for _, dir in pairs({ "north", "east", "south", "west" }) do
	-- same sprites, just with some parts painted red
	combinator_entity.sprites[dir].layers[1].filename = "__cybersyn__/graphics/combinator/cybernetic-combinator.png"
end

local function create_combinator_display_direction(filename, x, y, shift)
	return {
		scale = 0.5,
		filename = filename,
		x = 30 * x,
		y = 22 * y,
		width = 30,
		height = 22,
		shift = shift,
		draw_as_glow = true,
	}
end
local function create_combinator_display(filename, x, y)
	return {
		north = create_combinator_display_direction(filename, x, y, util.by_pixel(0, -4.5)),
		east = create_combinator_display_direction(filename, x, y, util.by_pixel(0, -10.5)),
		south = create_combinator_display_direction(filename, x, y, util.by_pixel(0, -4.5)),
		west = create_combinator_display_direction(filename, x, y, util.by_pixel(0, -10.5)),
	}
end

-- cybernetic-displays.png: 30x22 cells addressed (column, row), the operation each one stands for in brackets.
--   (0,0) D depot [+]   (1,0) W wagon [-]   (2,0) S station [/]   (3,0) C control [%]
--   (0,1) red S, the station's request went unserved [^]   (1,1) green S, unused: the base game's green is drawn for [<<]
--   (2,1) R refueler [>>]   (3,1) I inventory [AND]
--   (0,2) red I, that inventory's own request went unserved [OR]: (3,1) recoloured the way (2,0) became (0,1)
-- The red I has a row of its own rather than (1,1), so upstream's green S art stays in the sheet for [<<].
local CYBERSYN_DISPLAYS = "__cybersyn__/graphics/combinator/cybernetic-displays.png"
local FACTORIO_DISPLAYS = "__base__/graphics/entity/combinator/combinator-displays.png"

combinator_entity.plus_symbol_sprites = create_combinator_display(CYBERSYN_DISPLAYS, 0, 0)
combinator_entity.minus_symbol_sprites = create_combinator_display(CYBERSYN_DISPLAYS, 1, 0)
combinator_entity.divide_symbol_sprites = create_combinator_display(CYBERSYN_DISPLAYS, 2, 0)
combinator_entity.modulo_symbol_sprites = create_combinator_display(CYBERSYN_DISPLAYS, 3, 0)
combinator_entity.power_symbol_sprites = create_combinator_display(CYBERSYN_DISPLAYS, 0, 1)
combinator_entity.left_shift_symbol_sprites = create_combinator_display(FACTORIO_DISPLAYS, 1, 1)  -- green '>'
combinator_entity.right_shift_symbol_sprites = create_combinator_display(CYBERSYN_DISPLAYS, 2, 1)
combinator_entity.and_symbol_sprites = create_combinator_display(CYBERSYN_DISPLAYS, 3, 1)
combinator_entity.or_symbol_sprites = create_combinator_display(CYBERSYN_DISPLAYS, 0, 2)
combinator_entity.multiply_symbol_sprites = combinator_entity.divide_symbol_sprites

combinator_out_entity = flib.copy_prototype(data.raw["constant-combinator"]["constant-combinator"], COMBINATOR_OUT_NAME) --[[@as data.ConstantCombinatorPrototype]]
combinator_out_entity.icon = nil
combinator_out_entity.icon_size = nil
combinator_out_entity.next_upgrade = nil
combinator_out_entity.minable = nil
combinator_out_entity.selection_box = nil
combinator_out_entity.collision_box = nil
combinator_out_entity.collision_mask = { layers = {} }
combinator_out_entity.circuit_wire_max_distance = 3
combinator_out_entity.flags = { "not-blueprintable", "not-deconstructable", "placeable-off-grid" }
combinator_out_entity.hidden_in_factoriopedia = true

local origin = { 0.0, 0.0 }
local invisible_sprite = { filename = "__cybersyn__/graphics/invisible.png", width = 1, height = 1 }
local wire_con1 = {
	red = origin,
	green = origin,
}
local wire_con0 = { wire = wire_con1, shadow = wire_con1 }
combinator_out_entity.sprites = invisible_sprite
combinator_out_entity.activity_led_sprites = invisible_sprite
combinator_out_entity.activity_led_light = {
	intensity = 0,
	size = 0,
}
combinator_out_entity.activity_led_light_offsets = { origin, origin, origin, origin }
combinator_out_entity.draw_circuit_wires = false
combinator_out_entity.circuit_wire_connection_points = {
	wire_con0,
	wire_con0,
	wire_con0,
	wire_con0,
}
