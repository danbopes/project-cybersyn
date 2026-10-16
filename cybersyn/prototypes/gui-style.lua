local constants = require("constants")

local data_util = require("__flib__.data-util")

local util = {}

for key, value in pairs(require("__core__.lualib.util")) do
	util[key] = value
end

util.paths = {
	nav_icons = "__cybersyn__/graphics/gui/frame-action-icons.png",
	shortcut_icons = "__cybersyn__/graphics/shortcut/ltn-manager-shortcut.png",
}

util.empty_checkmark = {
	filename = data_util.empty_image,
	priority = "very-low",
	width = 1,
	height = 1,
	frame_count = 1,
	scale = 8,
}

data:extend({
	data_util.build_sprite("ltnm_pin_black", { 0, 32 }, util.paths.nav_icons, 32),
	data_util.build_sprite("ltnm_pin_white", { 32, 32 }, util.paths.nav_icons, 32),
	data_util.build_sprite("ltnm_refresh_black", { 0, 0 }, util.paths.nav_icons, 32),
	data_util.build_sprite("ltnm_refresh_white", { 32, 0 }, util.paths.nav_icons, 32),
	-- utility/pause is dark grey, which vanishes on an unselected frame action button; the button style inverts a
	-- light sprite on hover by itself.
	data_util.build_sprite("cybersyn_pause_white", { 0, 0 }, "__cybersyn__/graphics/gui/pause-white.png", 32),
})




local styles = data.raw["gui-style"]["default"]

-- local depot_button_height = 89

-- BUTTON STYLES

-- smaller flib slot buttons
for _, color in ipairs({ "default", "red", "green", "blue", "orange" }) do
	styles["ltnm_small_slot_button_" .. color] = {
		type = "button_style",
		parent = "flib_slot_button_" .. color,
		size = 36,
	}
	styles["ltnm_selected_small_slot_button_" .. color] = {
		type = "button_style",
		parent = "flib_selected_slot_button_" .. color,
		size = 36,
	}
end

styles.ltnm_train_minimap_button = {
	type = "button_style",
	parent = "button",
	size = 60,
	default_graphical_set = {},
	hovered_graphical_set = {
		base = { position = { 81, 80 }, size = 1, opacity = 0.7 },
	},
	clicked_graphical_set = { position = { 70, 146 }, size = 1, opacity = 0.7 },
}

-- CHECKBOX STYLES

-- inactive is grey until hovered
-- checked = ascending, unchecked = descending
styles.ltnm_sort_checkbox = {
	type = "checkbox_style",
	font = "default-bold",
	-- font_color = bold_font_color,
	padding = 0,
	default_graphical_set = {
		filename = "__core__/graphics/arrows/table-header-sort-arrow-down-white.png",
		size = { 16, 16 },
		scale = 0.5,
	},
	hovered_graphical_set = {
		filename = "__core__/graphics/arrows/table-header-sort-arrow-down-hover.png",
		size = { 16, 16 },
		scale = 0.5,
	},
	clicked_graphical_set = {
		filename = "__core__/graphics/arrows/table-header-sort-arrow-down-white.png",
		size = { 16, 16 },
		scale = 0.5,
	},
	disabled_graphical_set = {
		filename = "__core__/graphics/arrows/table-header-sort-arrow-down-white.png",
		size = { 16, 16 },
		scale = 0.5,
	},
	selected_graphical_set = {
		filename = "__core__/graphics/arrows/table-header-sort-arrow-up-white.png",
		size = { 16, 16 },
		scale = 0.5,
	},
	selected_hovered_graphical_set = {
		filename = "__core__/graphics/arrows/table-header-sort-arrow-up-hover.png",
		size = { 16, 16 },
		scale = 0.5,
	},
	selected_clicked_graphical_set = {
		filename = "__core__/graphics/arrows/table-header-sort-arrow-up-white.png",
		size = { 16, 16 },
		scale = 0.5,
	},
	selected_disabled_graphical_set = {
		filename = "__core__/graphics/arrows/table-header-sort-arrow-up-white.png",
		size = { 16, 16 },
		scale = 0.5,
	},
	checkmark = util.empty_checkmark,
	disabled_checkmark = util.empty_checkmark,
	text_padding = 5,
}

-- selected is orange by default
styles.ltnm_selected_sort_checkbox = {
	type = "checkbox_style",
	parent = "ltnm_sort_checkbox",
	-- font_color = bold_font_color,
	default_graphical_set = {
		filename = "__core__/graphics/arrows/table-header-sort-arrow-down-active.png",
		size = { 16, 16 },
		scale = 0.5,
	},
	selected_graphical_set = {
		filename = "__core__/graphics/arrows/table-header-sort-arrow-up-active.png",
		size = { 16, 16 },
		scale = 0.5,
	},
}

-- FLOW STYLES

styles.ltnm_warning_flow = {
	type = "horizontal_flow_style",
	padding = 12,
	horizontal_align = "center",
	vertical_align = "center",
	vertical_spacing = 8,
	horizontally_stretchable = "on",
	vertically_stretchable = "on",
}

-- FRAME STYLES

-- The height comes from the player's screen at runtime (scripts/gui/sizing.lua).
styles.ltnm_main_content_frame = {
	type = "frame_style",
	parent = "deep_frame_in_shallow_frame",
}


styles.ltnm_small_slot_table_frame_light = {
	type = "frame_style",
	parent = "ltnm_table_inset_frame_light",
	minimal_height = 36,
	background_graphical_set = {
		base = {
			position = { 282, 17 },
			corner_size = 8,
			overall_tiling_horizontal_padding = 4,
			overall_tiling_horizontal_size = 28,
			overall_tiling_horizontal_spacing = 8,
			overall_tiling_vertical_padding = 4,
			overall_tiling_vertical_size = 28,
			overall_tiling_vertical_spacing = 8,
		},
	},
}

styles.ltnm_small_slot_table_frame_dark = {
	type = "frame_style",
	parent = "ltnm_table_inset_frame_dark",
	minimal_height = 36,
	background_graphical_set = {
		base = {
			position = { 282, 17 },
			corner_size = 8,
			overall_tiling_horizontal_padding = 4,
			overall_tiling_horizontal_size = 28,
			overall_tiling_horizontal_spacing = 8,
			overall_tiling_vertical_padding = 4,
			overall_tiling_vertical_size = 28,
			overall_tiling_vertical_spacing = 8,
		},
	},
}

styles.ltnm_table_inset_frame_light = {
	type = "frame_style",
	parent = "deep_frame_in_shallow_frame",
}

styles.ltnm_table_inset_frame_dark = {
	type = "frame_style",
	parent = "deep_frame_in_shallow_frame",
	graphical_set = {
		base = {
			position = { 51, 0 },
			corner_size = 8,
			center = { position = { 42, 8 }, size = { 1, 1 } },
			draw_type = "outer",
		},
		shadow = default_inner_shadow,
	},
}

styles.ltnm_table_row_frame_light = {
	type = "frame_style",
	--parent = "statistics_table_item_frame",
	--this is likely incorrect, unsure what the 2.0 equivalent is
	parent = "neutral_message_frame",
	top_padding = 8,
	bottom_padding = 8,
	left_padding = 8,
	right_padding = 8,
	minimal_height = 52,
	horizontal_flow_style = {
		type = "horizontal_flow_style",
		vertical_align = "center",
		horizontal_spacing = 10,
		horizontally_stretchable = "on",
	},
	graphical_set = {
		base = {
			center = { position = { 76, 8 }, size = { 1, 1 } },
			-- bottom = {position = {8, 40}, size = {1, 8}},
		},
	},
}

styles.ltnm_table_row_frame_dark = {
	type = "frame_style",
	parent = "ltnm_table_row_frame_light",
	-- graphical_set = {
	--   base = {bottom = {position = {8, 40}, size = {1, 8}}},
	-- },
	graphical_set = {},
}

styles.ltnm_table_toolbar_frame = {
	type = "frame_style",
	parent = "subheader_frame",
	left_padding = 9,
	right_padding = 7 + 12,          -- For scrollbar
	horizontally_stretchable = "on", -- FIXME: This causes the GUI to jump when the scrollbar appears
	horizontal_flow_style = {
		type = "horizontal_flow_style",
		horizontal_spacing = 10,
		vertical_align = "center",
	},
}


-- LABEL STYLES

--I am unsure what this was supposed to be in 1.1
local default_orange_color = {
	r = 255,
	g = 128,
	b = 0,
}

styles.ltnm_label_signal_count_inventory = {
	type = "label_style",
	parent = "count_label",
	size = 36,
	width = 36,
	horizontal_align = "right",
	vertical_align = "bottom",
	right_padding = 2,
	parent_hovered_font_color = { 1, 1, 1 },
}

styles.ltnm_label_signal_count = {
	type = "label_style",
	parent = "ltnm_label_signal_count_inventory",
	bottom_padding = 3,
	right_padding = 4,
}

styles.ltnm_label_train_count_inventory = {
	type = "label_style",
	parent = "count_label",
	size = 36,
	width = 36,
	horizontal_align = "right",
	vertical_align = "top",
	right_padding = 3,
	top_padding = -4,
	parent_hovered_font_color = { 1, 1, 1 },
}

styles.ltnm_label_train_count = {
	type = "label_style",
	parent = "ltnm_label_train_count_inventory",
	right_padding = 6,
	top_padding = -5,
}

local hovered_label_color = {
	r = 0.5 * (1 + default_orange_color.r),
	g = 0.5 * (1 + default_orange_color.g),
	b = 0.5 * (1 + default_orange_color.b),
}

styles.ltnm_clickable_semibold_label = {
	type = "label_style",
	parent = "ltnm_semibold_label",
	hovered_font_color = hovered_label_color,
	disabled_font_color = hovered_label_color,
}

styles.ltnm_minimap_label = {
	type = "label_style",
	font = "default-game",
	font_color = default_font_color,
	size = 60,
	vertical_align = "bottom",
	horizontal_align = "right",
	right_padding = 4,
}

styles.ltnm_semibold_label = {
	type = "label_style",
	font = "default-semibold",
}

styles.ltnm_column_label = {
	type = "label_style",
	font = "default-bold",
	left_padding = 8,
}

-- MINIMAP STYLES

-- Smallest size at which the locomotive's surroundings stay readable; it roughly doubles the rows visible without
-- scrolling.
styles.ltnm_train_minimap = {
	type = "minimap_style",
	size = 60,
}

-- 67 px rows (60 minimap + 7 padding) divide the 670 px Trains scroll pane into exactly ten rows, so the last
-- visible row is never cut in half by the footer.
styles.ltnm_train_row_frame_light = {
	type = "frame_style",
	parent = "ltnm_table_row_frame_light",
	top_padding = 4,
	bottom_padding = 3,
}

styles.ltnm_train_row_frame_dark = {
	type = "frame_style",
	parent = "ltnm_table_row_frame_dark",
	top_padding = 4,
	bottom_padding = 3,
}

styles.ltnm_subfooter_frame = {
	type = "frame_style",
	parent = "subheader_frame",
	left_padding = 8,
	right_padding = 8,
	horizontally_stretchable = "on",
	horizontal_flow_style = {
		type = "horizontal_flow_style",
		horizontal_spacing = 12,
		vertical_align = "center",
	},
}

styles.ltnm_squashable_semibold_label = {
	type = "label_style",
	parent = "ltnm_semibold_label",
	horizontally_squashable = "on",
}

-- CHART OVERLAY BUTTON STYLE

styles.cybersyn_chart_overlay_button = {
	type = "button_style",
	parent = "button",
	default_graphical_set = {},
	hovered_graphical_set = {},
	clicked_graphical_set = {},
	padding = 0,
	minimal_width = 1,
	minimal_height = 1,
}

-- SCROLL PANE STYLES

styles.ltnm_table_scroll_pane = {
	type = "scroll_pane_style",
	parent = "flib_naked_scroll_pane_no_padding",
	vertical_flow_style = {
		type = "vertical_flow_style",
		vertical_spacing = 0,
	},
}

styles.ltnm_slot_table_scroll_pane = {
	type = "scroll_pane_style",
	parent = "flib_naked_scroll_pane_no_padding",
	horizontally_squashable = "off",
	background_graphical_set = {
		base = {
			position = { 282, 17 },
			corner_size = 8,
			overall_tiling_horizontal_padding = 4,
			overall_tiling_horizontal_size = 32,
			overall_tiling_horizontal_spacing = 8,
			overall_tiling_vertical_padding = 4,
			overall_tiling_vertical_size = 32,
			overall_tiling_vertical_spacing = 8,
		},
	},
}

-- TABBED PANE STYLES

styles.ltnm_tabbed_pane = {
	type = "tabbed_pane_style",
	tab_content_frame = {
		type = "frame_style",
		parent = "tabbed_pane_frame",
		left_padding = 12,
		right_padding = 12,
		bottom_padding = 12,
	},
}


data:extend({
	-- custom inputs
	{
		type = "custom-input",
		name = "cybersyn-toggle-gui",
		key_sequence = "CONTROL + T",
		action = "lua",
	},
	{
		type = "shortcut",
		name = "cybersyn-toggle-gui",
		icon = "__cybersyn__/graphics/shortcut/manager-toolbar-white.png",
		icon_size = 32,
		small_icon = "__cybersyn__/graphics/shortcut/manager-toolbar-white.png",
		small_icon_size = 32,
		style = "green",
		toggleable = true,
		action = "lua",
		associated_control_input = "cybersyn-toggle-gui",
		technology_to_unlock = "cybersyn-train-network",
	},
})

-- WINDOW (PLAN3 §4.3)

data:extend({
	data_util.build_sprite("cybersyn_filter_white", { 0, 0 }, "__cybersyn__/graphics/gui/filter-white.png", 32),
	{
		-- Ctrl+F (or whatever the player bound to the game's search) while the manager is open.
		type = "custom-input",
		name = "cybersyn-manager-search",
		key_sequence = "",
		linked_game_control = "focus-search",
		action = "lua",
	},
})

styles.cybersyn_tab_subheader = {
	type = "frame_style",
	parent = "subheader_frame",
	horizontally_stretchable = "on",
	left_padding = 8,
	right_padding = 8,
	horizontal_flow_style = {
		type = "horizontal_flow_style",
		horizontal_spacing = 8,
		vertical_align = "center",
	},
}

styles.cybersyn_filter_row = {
	type = "frame_style",
	parent = "cybersyn_tab_subheader",
	horizontal_flow_style = {
		type = "horizontal_flow_style",
		horizontal_spacing = 12,
		vertical_align = "center",
	},
}

-- The red of the negative subheader, without its negative margin.
styles.cybersyn_banner_frame = {
	type = "frame_style",
	parent = "cybersyn_tab_subheader",
	graphical_set = {
		base = {
			center = { position = { 411, 25 }, size = { 1, 1 } },
			bottom = { position = { 411, 26 }, size = { 1, 8 } },
		},
		shadow = bottom_shadow,
	},
}

styles.cybersyn_banner_label = {
	type = "label_style",
	parent = "bold_label",
	font_color = { 1, 1, 1 },
}

styles.cybersyn_subheader_note = {
	type = "label_style",
	font_color = { 0.7, 0.7, 0.7 },
	horizontally_squashable = "on",
}

styles.cybersyn_search_field = {
	type = "textbox_style",
	width = 200,
}

-- Item filter chip: "[icon] Filtered: Iron plate ×".
styles.cybersyn_item_chip_icon = {
	type = "button_style",
	parent = "flib_slot_button_orange",
	size = 28,
}

styles.cybersyn_item_chip = {
	type = "button_style",
	parent = "button",
	height = 28,
	minimal_width = 0,
	left_padding = 8,
	right_padding = 8,
	default_font_color = { 0, 0, 0 },
	default_graphical_set = {
		base = { position = { 0, 17 }, corner_size = 8, tint = { 1, 0.78, 0.45 } },
		shadow = default_dirt,
	},
	hovered_graphical_set = {
		base = { position = { 34, 17 }, corner_size = 8, tint = { 1, 0.78, 0.45 } },
		shadow = default_dirt,
		glow = default_glow(default_glow_color, 0.5),
	},
	clicked_graphical_set = {
		base = { position = { 51, 17 }, corner_size = 8, tint = { 1, 0.78, 0.45 } },
		shadow = default_dirt,
	},
}

-- Reason chips (PLAN3 §8): red = nothing changes on its own, orange = waiting on stock or capacity, grey = a setting.
local function chip(tint)
	local style = {
		type = "button_style",
		parent = "button",
		height = 28,
		minimal_width = 0,
		left_padding = 8,
		right_padding = 8,
		horizontally_squashable = "on",
		font = "default-semibold",
		default_font_color = { 0, 0, 0 },
		hovered_font_color = { 0, 0, 0 },
		clicked_font_color = { 0, 0, 0 },
	}
	if tint then
		style.default_graphical_set = {
			base = { position = { 0, 17 }, corner_size = 8, tint = tint },
			shadow = default_dirt,
		}
		style.hovered_graphical_set = {
			base = { position = { 34, 17 }, corner_size = 8, tint = tint },
			shadow = default_dirt,
			glow = default_glow(default_glow_color, 0.5),
		}
		style.clicked_graphical_set = {
			base = { position = { 51, 17 }, corner_size = 8, tint = tint },
			shadow = default_dirt,
		}
	end
	return style
end
styles.cybersyn_chip_red = chip({ 1, 0.5, 0.45 })
styles.cybersyn_chip_orange = chip({ 1, 0.78, 0.45 })
styles.cybersyn_chip_grey = chip(nil)

-- A link cell: text that opens what it names (scripts/gui/util.lua util.handle_link_click).
styles.cybersyn_link_button = {
	type = "button_style",
	parent = "transparent_button",
	font = "default-semibold",
	horizontal_align = "left",
	minimal_width = 0,
	height = 32,
	left_padding = 2,
	right_padding = 2,
	horizontally_squashable = "on",
	default_font_color = { 0.9, 0.9, 0.9 },
	hovered_font_color = { 1, 0.74, 0.4 },
	clicked_font_color = { 1, 0.74, 0.4 },
	disabled_font_color = { 0.5, 0.5, 0.5 },
	disabled_graphical_set = {},
}

styles.cybersyn_link_button_acked = {
	type = "button_style",
	parent = "cybersyn_link_button",
	default_font_color = { 0.5, 0.5, 0.5 },
}

styles.cybersyn_name_icon = {
	type = "button_style",
	parent = "transparent_slot",
	size = 20,
}

-- OVERVIEW TAB STYLES

styles.cybersyn_overview_content = {
	type = "vertical_flow_style",
	vertical_spacing = 0,
	horizontally_stretchable = "on",
}

styles.cybersyn_overview_tile_row = {
	type = "horizontal_flow_style",
	horizontal_spacing = 12,
	top_margin = 12,
	height = 108,
}

local shallow_base = {
	position = { 17, 0 },
	corner_size = 8,
	center = { position = { 76, 8 }, size = { 1, 1 } },
	draw_type = "outer",
}

-- A whole tile is one button (it jumps to the matching tab); it looks like a shallow frame and glows on hover.
styles.cybersyn_overview_tile = {
	type = "button_style",
	parent = "button",
	height = 108,
	padding = 0,
	minimal_width = 0,
	default_graphical_set = { base = shallow_base, shadow = default_inner_shadow },
	hovered_graphical_set = { base = shallow_base, shadow = default_inner_shadow, glow = default_glow(default_glow_color, 0.5) },
	clicked_graphical_set = { base = shallow_base, shadow = default_inner_shadow },
	disabled_graphical_set = { base = shallow_base, shadow = default_inner_shadow },
	clicked_vertical_offset = 0,
}

-- 4 + header 28 + four 18 px lines + 4 = the 108 px tile.
styles.cybersyn_overview_tile_body = {
	type = "vertical_flow_style",
	vertical_spacing = 0,
	top_padding = 4,
	bottom_padding = 4,
	left_padding = 10,
	right_padding = 10,
}

styles.cybersyn_overview_tile_header = {
	type = "horizontal_flow_style",
	vertical_align = "center",
	horizontal_spacing = 6,
	height = 28,
}

styles.cybersyn_overview_tile_icon = {
	type = "image_style",
	size = 24,
	stretch_image_to_widget_size = true,
}

styles.cybersyn_overview_tile_caption = {
	type = "label_style",
	parent = "caption_label",
	horizontally_squashable = "on",
}

styles.cybersyn_overview_big_number = {
	type = "label_style",
	font = "default-large-bold",
	font_color = { 255, 230, 192 },
}

styles.cybersyn_overview_line_flow = {
	type = "horizontal_flow_style",
	vertical_align = "center",
	horizontal_spacing = 8,
	height = 18,
}

styles.cybersyn_overview_line_label = {
	type = "label_style",
	font_color = { 0.85, 0.85, 0.85 },
	horizontally_squashable = "on",
}

styles.cybersyn_overview_line_value = {
	type = "label_style",
	font = "default-semibold",
	horizontal_align = "right",
	minimal_width = 40,
}

styles.cybersyn_overview_period_dropdown = {
	type = "dropdown_style",
	parent = "dropdown",
	width = 140,
}

styles.cybersyn_unserved_frame = {
	type = "frame_style",
	parent = "inside_deep_frame",
	top_margin = 12,
	horizontally_stretchable = "on",
	vertical_flow_style = {
		type = "vertical_flow_style",
		vertical_spacing = 0,
	},
}

styles.cybersyn_unserved_caption_frame = {
	type = "frame_style",
	parent = "subheader_frame",
	horizontally_stretchable = "on",
	left_padding = 8,
	right_padding = 8,
	horizontal_flow_style = {
		type = "horizontal_flow_style",
		horizontal_spacing = 8,
		vertical_align = "center",
	},
}

styles.cybersyn_unserved_count_button = {
	type = "button_style",
	parent = "cybersyn_link_button",
	height = 28,
	font = "default-bold",
}

styles.cybersyn_unserved_table = {
	type = "table_style",
	parent = "table",
	horizontal_spacing = 8,
	vertical_spacing = 0,
	left_padding = 4,
	right_padding = 10,
	odd_row_graphical_set = {
		filename = "__core__/graphics/gui-new.png",
		position = { 472, 25 },
		size = 1,
	},
}

styles.cybersyn_unserved_item = {
	type = "button_style",
	parent = "transparent_slot",
	size = 32,
}

styles.cybersyn_unserved_cell = {
	type = "label_style",
	height = 32,
	vertical_align = "center",
}

styles.cybersyn_unserved_cell_acked = {
	type = "label_style",
	parent = "cybersyn_unserved_cell",
	font_color = { 0.5, 0.5, 0.5 },
}

styles.cybersyn_unserved_value = {
	type = "label_style",
	parent = "cybersyn_unserved_cell",
	horizontal_align = "right",
}

styles.cybersyn_unserved_value_acked = {
	type = "label_style",
	parent = "cybersyn_unserved_value",
	font_color = { 0.5, 0.5, 0.5 },
}

styles.cybersyn_unserved_header = {
	type = "label_style",
	font = "default-small-semibold",
	font_color = { 0.6, 0.6, 0.6 },
	height = 20,
	vertical_align = "center",
	horizontally_squashable = "on",
}

styles.cybersyn_unserved_header_value = {
	type = "label_style",
	parent = "cybersyn_unserved_header",
	horizontal_align = "right",
}

styles.cybersyn_unserved_cell_flow = {
	type = "horizontal_flow_style",
	vertical_align = "center",
	horizontal_spacing = 4,
	height = 32,
}

styles.cybersyn_unserved_icon_flow = {
	type = "horizontal_flow_style",
	vertical_align = "center",
	horizontal_spacing = 2,
	width = 64,
}

styles.cybersyn_unserved_ack = {
	type = "button_style",
	parent = "tool_button",
	size = 28,
}

styles.cybersyn_overview_empty_flow = {
	type = "horizontal_flow_style",
	horizontal_align = "center",
	vertical_align = "center",
	horizontally_stretchable = "on",
}

styles.cybersyn_overview_empty_label = {
	type = "label_style",
	font_color = { 0.6, 0.6, 0.6 },
	single_line = false,
	horizontal_align = "center",
	vertical_align = "center",
	maximal_width = 600,
}

-- PROBLEMS TAB STYLES (PLAN3 §4.7): 32 px rows in a vertical flow, group rows in the subheader colour.

styles.cybersyn_problems_frame = {
	type = "frame_style",
	parent = "inside_deep_frame",
	horizontally_stretchable = "on",
	vertical_flow_style = {
		type = "vertical_flow_style",
		vertical_spacing = 0,
	},
}

styles.cybersyn_problems_header = {
	type = "horizontal_flow_style",
	horizontal_spacing = 8,
	left_padding = 4,
	right_padding = 10,
	height = 20,
	vertical_align = "center",
}

styles.cybersyn_problems_row = {
	type = "frame_style",
	parent = "frame",
	graphical_set = {},
	padding = 0,
	left_padding = 4,
	right_padding = 10,
	height = 32,
	horizontally_stretchable = "on",
	horizontal_flow_style = {
		type = "horizontal_flow_style",
		horizontal_spacing = 8,
		vertical_align = "center",
	},
}

styles.cybersyn_problems_row_odd = {
	type = "frame_style",
	parent = "cybersyn_problems_row",
	graphical_set = { base = { center = { position = { 472, 25 }, size = { 1, 1 } } } },
}

styles.cybersyn_problems_group_row = {
	type = "frame_style",
	parent = "cybersyn_problems_row",
	graphical_set = { base = { center = { position = { 256, 25 }, size = { 1, 1 } } } },
}

styles.cybersyn_problems_dot = {
	type = "image_style",
	size = 16,
	stretch_image_to_widget_size = true,
	left_margin = 2,
	right_margin = 2,
}

styles.cybersyn_problems_group_caption = {
	type = "label_style",
	parent = "caption_label",
	horizontally_squashable = "on",
}

-- The width lives in the style: the acknowledged variant swaps styles in place, which drops an element's own width.
styles.cybersyn_problems_detail = {
	type = "label_style",
	parent = "cybersyn_unserved_cell",
	width = 300,
	horizontally_squashable = "on",
}

styles.cybersyn_problems_detail_acked = {
	type = "label_style",
	parent = "cybersyn_problems_detail",
	font_color = { 0.5, 0.5, 0.5 },
}

styles.cybersyn_problems_fix = {
	type = "label_style",
	parent = "cybersyn_unserved_cell",
	font_color = { 0.6, 0.6, 0.6 },
	horizontally_squashable = "on",
}

styles.cybersyn_problems_subfooter = {
	type = "frame_style",
	parent = "subfooter_frame",
	horizontally_stretchable = "on",
	horizontal_flow_style = {
		type = "horizontal_flow_style",
		horizontal_spacing = 8,
		vertical_align = "center",
	},
}

-- LOG TAB STYLES (PLAN3 §4.7 Log: 28 px rows; the rows table below gives the alternate-row tint)

styles.cybersyn_log_row = {
	type = "frame_style",
	padding = 0,
	left_padding = 4,
	right_padding = 8,
	height = 28,
	horizontally_stretchable = "on",
	graphical_set = {},
	horizontal_flow_style = {
		type = "horizontal_flow_style",
		vertical_align = "center",
		horizontal_spacing = 8,
	},
}

styles.cybersyn_log_age = {
	type = "label_style",
	font_color = { 0.6, 0.6, 0.6 },
	horizontal_align = "right",
	height = 28,
	vertical_align = "center",
}

styles.cybersyn_log_dot = {
	type = "image_style",
	size = 16,
	stretch_image_to_widget_size = true,
}

styles.cybersyn_log_kind = {
	type = "image_style",
	size = 20,
	stretch_image_to_widget_size = true,
}

styles.cybersyn_log_link = {
	type = "button_style",
	parent = "cybersyn_link_button",
	height = 28,
}

styles.cybersyn_log_link_gone = {
	type = "button_style",
	parent = "cybersyn_log_link",
	default_font_color = { 0.5, 0.5, 0.5 },
}

styles.cybersyn_log_cell_flow = {
	type = "horizontal_flow_style",
	vertical_align = "center",
	horizontal_spacing = 4,
	height = 28,
}

styles.cybersyn_log_icon_flow = {
	type = "horizontal_flow_style",
	vertical_align = "center",
	horizontal_spacing = 0,
}

styles.cybersyn_log_icon = {
	type = "image_style",
	size = 20,
	stretch_image_to_widget_size = true,
}

styles.cybersyn_log_item = {
	type = "button_style",
	parent = "transparent_slot",
	size = 28,
}

styles.cybersyn_log_message = {
	type = "label_style",
	height = 28,
	vertical_align = "center",
	horizontally_squashable = "on",
}

styles.cybersyn_log_count = {
	type = "label_style",
	font = "default-semibold",
	horizontal_align = "right",
	height = 28,
	vertical_align = "center",
}

styles.cybersyn_log_print = {
	type = "button_style",
	parent = "tool_button",
	size = 24,
	padding = 2,
}

styles.cybersyn_log_sev_button = {
	type = "button_style",
	parent = "button",
	height = 28,
	minimal_width = 0,
	left_padding = 6,
	right_padding = 8,
}

styles.cybersyn_log_kind_dropdown = {
	type = "dropdown_style",
	parent = "dropdown",
	width = 190,
}

styles.cybersyn_log_window_dropdown = {
	type = "dropdown_style",
	parent = "dropdown",
	width = 160,
}

styles.cybersyn_log_train_field = {
	type = "textbox_style",
	width = 72,
}

styles.cybersyn_log_summary_frame = {
	type = "frame_style",
	parent = "deep_frame_in_shallow_frame",
	vertical_flow_style = {
		type = "vertical_flow_style",
		vertical_spacing = 0,
	},
}

styles.cybersyn_log_summary_table = {
	type = "table_style",
	parent = "cybersyn_unserved_table",
	column_alignments = {
		{ column = 3, alignment = "right" },
	},
}

styles.cybersyn_log_rows_table = {
	type = "table_style",
	parent = "table",
	horizontal_spacing = 0,
	vertical_spacing = 0,
	cell_padding = 0,
	horizontally_stretchable = "on",
	odd_row_graphical_set = {
		filename = "__core__/graphics/gui-new.png",
		position = { 472, 25 },
		size = 1,
	},
}
