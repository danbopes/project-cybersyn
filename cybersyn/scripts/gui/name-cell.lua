-- A link cell for a stop name in a list row (PLAN3 §4.6, §4.7): up to three icons parsed from the front of the rich-text
-- name, the plain text as a link button, up to three icons from its end, each run with a "+n" when the name holds more.
-- Every part is a button tagged {kind, id} with util.handle.link_click, so a click anywhere on the name opens the stop.

local gui = require("__flib__.gui")
local util = require("scripts.gui.util")

local name_cell = {}

local ICON = 20
local ICON_GAP = 2
local OVERFLOW = 22

--- @param parts RichNameParts?
--- @param side "lead"|"tail"
--- @return int icons
--- @return int? overflow
local function side_of(parts, side)
	local list = parts and parts[side]
	return list and #list or 0, parts and parts[side .. "_overflow"] or nil
end

--- Width the icons of one side take, so the text button can take the rest.
--- @param parts RichNameParts?
--- @return int
local function icons_width(parts)
	local w = 0
	for _, side in ipairs({ "lead", "tail" }) do
		local n, over = side_of(parts, side)
		if n > 0 then w = w + n * (ICON + ICON_GAP) end
		if over then w = w + OVERFLOW end
	end
	return w
end

--- @param parts RichNameParts?
--- @param side "lead"|"tail"
--- @param tags {kind: string, id: any}
--- @param tooltip LocalisedString
--- @param scope string
--- @return flib.GuiElemDef[]
local function side_children(parts, side, tags, tooltip, scope)
	local out = {}
	local list = parts and parts[side]
	if list then
		local quality = parts[side .. "_quality"]
		for i, sprite in ipairs(list) do
			out[#out + 1] = util.hoverable({
				type = "sprite-button",
				style = "cybersyn_name_icon",
				sprite = helpers.is_valid_sprite_path(sprite) and sprite or "utility/questionmark",
				quality = quality and quality[i] or nil,
				tooltip = tooltip,
				tags = { kind = tags.kind, id = tags.id },
				mouse_button_filter = { "left" },
				handler = { [defines.events.on_gui_click] = util.handle.link_click },
			}, scope)
		end
	end
	local over = parts and parts[side .. "_overflow"]
	if over then
		out[#out + 1] = { type = "label", style = "cybersyn_overflow_label", caption = "+" .. over, tooltip = tooltip }
	end
	return out
end

--- @param parts RichNameParts?
--- @param name string
--- @return string
local function text_of(parts, name)
	local text = parts and parts.text
	if text == nil or text == "" then return name end
	return text
end

--- @param parts RichNameParts? shared and read-only (scripts/gui/rich-name.lua)
--- @param name string the full rich-text name
--- @param tags {kind: string, id: any}
--- @param width int
--- @param tooltip LocalisedString
--- @param scope string hover scope of the list
--- @param shrink boolean? at most `width` wide instead of exactly, so what follows the name sits right after it
--- @return flib.GuiElemDef
function name_cell.def(parts, name, tags, width, tooltip, scope, shrink)
	local lead = { type = "flow", direction = "horizontal", style = "cybersyn_cell_flow", style_mods = { horizontal_spacing = ICON_GAP } }
	for i, def in ipairs(side_children(parts, "lead", tags, tooltip, scope)) do lead[i] = def end
	local tail = { type = "flow", direction = "horizontal", style = "cybersyn_cell_flow", style_mods = { horizontal_spacing = ICON_GAP } }
	for i, def in ipairs(side_children(parts, "tail", tags, tooltip, scope)) do tail[i] = def end
	return {
		type = "flow",
		direction = "horizontal",
		style = "cybersyn_cell_flow",
		style_mods = shrink and { maximal_width = width, horizontal_spacing = 2 } or { width = width, horizontal_spacing = 2 },
		tags = { s = name .. "\1" .. tostring(tags.id) },
		lead,
		util.hoverable({
			type = "button",
			style = "cybersyn_link_button",
			style_mods = { maximal_width = math.max(width - icons_width(parts) - 4, 24) },
			caption = text_of(parts, name),
			tooltip = tooltip,
			tags = { kind = tags.kind, id = tags.id },
			mouse_button_filter = { "left" },
			handler = { [defines.events.on_gui_click] = util.handle.link_click },
		}, scope),
		tail,
	}
end

--- Rewrites a cell built by name_cell.def in place: the icons only when the name or the target changed.
--- @param cell LuaGuiElement
--- @param parts RichNameParts?
--- @param name string
--- @param tags {kind: string, id: any}
--- @param width int
--- @param tooltip LocalisedString
--- @param scope string
function name_cell.update(cell, parts, name, tags, width, tooltip, scope)
	local c = cell.children
	local lead, button, tail = c[1], c[2], c[3]
	local sig = name .. "\1" .. tostring(tags.id)
	if cell.tags.s ~= sig then
		for _, pair in ipairs({ { lead, "lead" }, { tail, "tail" } }) do
			pair[1].clear()
			for _, def in ipairs(side_children(parts, pair[2], tags, tooltip, scope)) do gui.add(pair[1], def) end
		end
		button.caption = text_of(parts, name)
		button.style.maximal_width = math.max(width - icons_width(parts) - 4, 24)
		local t = button.tags
		t.kind, t.id = tags.kind, tags.id
		button.tags = t
		cell.tags = { s = sig }
	else
		for _, flow in ipairs({ lead, tail }) do
			for _, icon in ipairs(flow.children) do icon.tooltip = tooltip end
		end
	end
	button.tooltip = tooltip
end

return name_cell
