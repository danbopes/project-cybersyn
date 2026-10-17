-- Trains tab styles of PLAN4 D11: the state icon slot, the composition icons and the marker labels that replaced the
-- chips with nothing to click.

local styles = data.raw["gui-style"]["default"]

-- The State column: the state's icon on a slot coloured like the old chip (red, orange, grey).
for _, color in ipairs({ "red", "orange", "grey" }) do
	styles["cybersyn_state_slot_" .. color] = {
		type = "button_style",
		parent = "flib_slot_button_" .. color,
		size = 28,
		padding = 2,
	}
end

-- One carriage-class icon of a composition, its run length as the badge; no slot behind it.
styles.cybersyn_composition_icon = {
	type = "button_style",
	parent = "transparent_slot",
	size = 28,
	padding = 0,
}

-- Coloured words that say what a chip used to say, on cells with nothing to click (no hover, no click sound).
local function marker(color)
	return {
		type = "label_style",
		parent = "label",
		font = "default-semibold",
		font_color = color,
	}
end
styles.cybersyn_marker_red = marker({ 1, 0.45, 0.4 })
styles.cybersyn_marker_orange = marker({ 1, 0.72, 0.3 })
styles.cybersyn_marker_grey = marker({ 0.8, 0.8, 0.8 })
styles.cybersyn_marker_acked = marker({ 0.5, 0.5, 0.5 })
