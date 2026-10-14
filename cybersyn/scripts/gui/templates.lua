local constants = require("constants")

local templates = {}

--- Creates a frame action button, automatically accounting for inverted sprites.
--- @param name string?
--- @param sprite string?
--- @param tooltip LocalisedString?
--- @param handler GuiElemHandler?
--- @param tags Tags?
function templates.frame_action_button(name, sprite, tooltip, handler, tags)
	return {
		type = "sprite-button",
		name = name,
		style = "frame_action_button",
		sprite = sprite .. "",
		hovered_sprite = sprite .. "",
		clicked_sprite = sprite .. "",
		mouse_button_filter = { "left" },
		tooltip = tooltip,
		handler = handler,
		tags = tags,
	}
end

--- Creates a column header with a sort toggle.
--- @param widths table
--- @param tab string
--- @param column string
--- @param selected boolean
--- @param tooltip LocalisedString
--- @param state boolean?
--- @param handler GuiElemHandler?
function templates.sort_checkbox(widths, tab, column, selected, tooltip, state, handler)
	if state == nil then
		state = false
	end
	return {
		type = "checkbox",
		style = selected and "ltnm_selected_sort_checkbox" or "ltnm_sort_checkbox",
		style_mods = { width = widths and widths[tab][column] or nil, horizontally_stretchable = not widths },
		caption = { "cybersyn-gui." .. string.gsub(column, "_", "-") },
		tooltip = tooltip,
		state = state,
		ref = { tab, "toolbar", column .. "_checkbox" },
		handler = handler and { [defines.events.on_gui_checked_state_changed] = handler } or nil,
		tags = { tab = tab, column = column, width = widths and widths[tab][column] or nil, default_state = false },
	}
end

function templates.status_indicator(width, center)
	return {
		type = "flow",
		style = "flib_indicator_flow",
		style_mods = { horizontal_align = center and "center" or nil, width = width },
		{ type = "sprite", style = "flib_indicator" },
		{ type = "label" },
	}
end

--- Pager row `[«] [‹] "1–50 of 1,921" [›] [»]` for a tab. Element names are `<tab>_pager`, `<tab>_pager_first`,
--- `_prev`, `_label`, `_next`, `_last`; util.paginate keeps them current. Shift+‹/› moves 10 pages.
--- @param tab string canonical tab name, e.g. "stations_tab"
--- @param handler GuiElemHandler click handler, normally util.handle.pager_click
function templates.pager(tab, handler)
	local function button(action, caption)
		return {
			type = "button",
			name = tab .. "_pager_" .. action,
			style = "tool_button",
			caption = caption,
			tooltip = { "cybersyn-gui.pager-" .. action },
			enabled = false,
			tags = { pager_tab = tab, pager_action = action },
			handler = { [defines.events.on_gui_click] = handler },
		}
	end
	return {
		type = "flow",
		name = tab .. "_pager",
		direction = "horizontal",
		style_mods = { vertical_align = "center", horizontal_spacing = 4 },
		button("first", "«"),
		button("prev", "‹"),
		{
			type = "label",
			name = tab .. "_pager_label",
			style = "bold_label",
			style_mods = { minimal_width = 140, horizontal_align = "center" },
			caption = { "cybersyn-gui.pager-empty" },
		},
		button("next", "›"),
		button("last", "»"),
	}
end

return templates
