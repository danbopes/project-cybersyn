-- A link cell for a stop name in a list row (PLAN3 §4.6, §4.7): up to three icons parsed from the front of the rich-text
-- name, the plain text as a link button, up to three icons from its end, each run with a "+n" when the name holds more.
-- Every part is a button tagged {kind, id} with util.handle.link_click, so a click anywhere on the name opens the stop.
-- The parts are direct children of one flow (no nested flows): a Trains page builds two of these per row.

local gui = require("__flib__.gui")
local util = require("scripts.gui.util")

local name_cell = {}

local ICON = 20
local ICON_GAP = 2
local OVERFLOW = 22

--- Width the icons of one side take, so the text button can take the rest.
--- @param parts RichNameParts?
--- @return int
local function icons_width(parts)
	local w = 0
	if not parts then return w end
	for _, side in ipairs({ "lead", "tail" }) do
		local list = parts[side]
		if list then w = w + #list * (ICON + ICON_GAP) end
		if parts[side .. "_overflow"] then w = w + OVERFLOW end
	end
	return w
end

--- @param out flib.GuiElemDef[]
--- @param parts RichNameParts?
--- @param side "lead"|"tail"
--- @param tags {kind: string, id: any}
--- @param tooltip LocalisedString
--- @param scope string
local function add_side(out, parts, side, tags, tooltip, scope)
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
				mouse_button_filter = { "left", "right" },
				handler = { [defines.events.on_gui_click] = util.handle.link_click },
			}, scope)
		end
	end
	local over = parts and parts[side .. "_overflow"]
	if over then
		out[#out + 1] = { type = "label", style = "cybersyn_overflow_label", caption = "+" .. over, tooltip = tooltip }
	end
end

--- @param parts RichNameParts?
--- @param name string
--- @return string
local function text_of(parts, name)
	local text = parts and parts.text
	if text == nil or text == "" then return name end
	return text
end

--- The children of a cell: lead icons, the text button, tail icons.
local function children(parts, name, tags, width, tooltip, scope)
	local out = {}
	add_side(out, parts, "lead", tags, tooltip, scope)
	out[#out + 1] = util.hoverable({
		type = "button",
		style = "cybersyn_link_button",
		style_mods = { maximal_width = math.max(width - icons_width(parts) - 4, 24) },
		caption = text_of(parts, name),
		tooltip = tooltip,
		tags = { kind = tags.kind, id = tags.id },
		mouse_button_filter = { "left", "right" },
		handler = { [defines.events.on_gui_click] = util.handle.link_click },
	}, scope)
	add_side(out, parts, "tail", tags, tooltip, scope)
	return out
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
	local def = {
		type = "flow",
		direction = "horizontal",
		style = "cybersyn_cell_flow",
		style_mods = shrink and { maximal_width = width, horizontal_spacing = ICON_GAP } or { width = width, horizontal_spacing = ICON_GAP },
		tags = { s = name .. "\1" .. tostring(tags.id) },
	}
	for i, child in ipairs(children(parts, name, tags, width, tooltip, scope)) do def[i] = child end
	return def
end

--- The text button of a cell.
--- @param cell LuaGuiElement
--- @return LuaGuiElement?
function name_cell.button(cell)
	for _, child in ipairs(cell.children) do
		if child.type == "button" then return child end
	end
	return nil
end

--- Rewrites a cell built by name_cell.def in place: rebuilt only when the name or the target changed, otherwise only
--- the tooltips are written.
--- @param cell LuaGuiElement
--- @param parts RichNameParts?
--- @param name string
--- @param tags {kind: string, id: any}
--- @param width int
--- @param tooltip LocalisedString
--- @param scope string
function name_cell.update(cell, parts, name, tags, width, tooltip, scope)
	local sig = name .. "\1" .. tostring(tags.id)
	if cell.tags.s ~= sig then
		cell.clear()
		for _, child in ipairs(children(parts, name, tags, width, tooltip, scope)) do gui.add(cell, child) end
		cell.tags = { s = sig }
		return
	end
	for _, child in ipairs(cell.children) do
		child.tooltip = tooltip
	end
end

return name_cell
