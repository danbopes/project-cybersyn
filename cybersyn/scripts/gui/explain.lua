-- "Explain" for one Unserved row (PLAN3 §11.8, B3): what the dispatcher recorded for a (requester, item) key, the
-- requester's setup findings and the recent confirmed reason changes and who it lost to. It reads storage.diag and
-- the lint result only: it never evaluates eligibility itself (the lint engine and the reason codes stay the only two
-- models).
-- Mounted as a screen frame beside the manager window, so the Overview's whole-row sizing never changes.

local gui = require("__flib__.gui")

local util = require("scripts.gui.util")
local utext = require("scripts.gui.unserved-text")
local diag = require("scripts.diag")
local lint = require("scripts.lint")
local pm = require("scripts.gui.problems-model")
local lint_text = require("scripts.gui.lint-text")
local dev = require("scripts.gui.dev")

--- @class PlayerData
--- @field explain {r_id: uint, hash: string, sig: string?}? the open Explain frame's key

local explain = {}
explain.handle = {}

local FRAME = "cybersyn_explain"
local WIDTH = 440
local INNER = WIDTH - 24
local CHANGES = 5

--- @param r_id uint
--- @param hash string
--- @return DiagEntry?
local function entry_of(r_id, hash)
	local d = storage.diag
	if not d then return nil end
	local ix = d.item_ix[hash]
	local by_item = ix and d.unserved[r_id]
	return by_item and by_item[ix] or nil
end

local function stop_name(id)
	local stop = util.stop_record(id)
	return stop and stop.backer_name or tostring(id)
end

local GREY = { 0.65, 0.65, 0.65 }

local function label(caption, grey)
	return {
		type = "label",
		caption = caption,
		style_mods = { single_line = false, maximal_width = INNER, font_color = grey and GREY or nil },
	}
end

local function heading(caption)
	return { type = "label", style = "caption_label", caption = caption }
end

--- A string that changes whenever anything shown changes (ages in 10 s steps).
local function sig_of(r_id, hash, e)
	local now = game.tick
	local lint_s = storage.manager.lint
	if not e then return table.concat({ "gone", lint_s and lint_s.pass or 0 }, "|") end
	return table.concat({ e.reason, e.a, e.b, e.n, #e.changes, e.changes[#e.changes] or 0, tostring(e.lost_to), e.lost_n,
		math.floor((now - e.first_tick) / utext.READ_STEP), lint_s and lint_s.pass or 0,
		storage.acks and storage.acks.lint_version or 0 }, "|")
end

--- The body's children for one key.
local function body_defs(r_id, hash, e)
	local now = game.tick
	local out = {}
	local sprite, quality = util.item_sprite_and_tooltip(hash)
	if not e then
		out[#out + 1] = label({ "cybersyn-gui.explain-gone" }, true)
	else
		local d = storage.diag
		local wait = now - e.first_tick
		local inherited = e.first_tick < diag.inherit_threshold(d)
		local station = storage.stations[r_id]
		local network = util.network_text(station and station.network_name)
		out[#out + 1] = heading({ "cybersyn-gui.explain-recorded" })
		out[#out + 1] = {
			type = "flow",
			direction = "horizontal",
			style_mods = { vertical_align = "center", horizontal_spacing = 8 },
			{ type = "button", style = utext.chip_style(e.reason), caption = utext.chip_caption(e.reason),
				ignored_by_interaction = true },
			label(utext.stock_caption(e.reason, e.a, e.b), true),
		}
		out[#out + 1] = label({ "cybersyn-gui.unserved-why", utext.why(e.reason, e.a, e.b, network, e.rej, util.surface_name) })
		out[#out + 1] = label({ "cybersyn-gui.unserved-fix", utext.fix(e.reason, network) }, true)
		out[#out + 1] = label({ inherited and "cybersyn-gui.unserved-since-load" or "cybersyn-gui.unserved-since",
			util.format_duration(wait), tostring(e.n or 0) }, true)
		if e.p_station_id and e.reason ~= REASON_NO_PROVIDER then
			out[#out + 1] = label({ "cybersyn-gui.explain-provider", stop_name(e.p_station_id) }, true)
		end

		out[#out + 1] = heading({ "cybersyn-gui.explain-history" })
		local changes, reasons = e.changes, e.change_reasons
		if #changes == 0 then
			out[#out + 1] = label({ "cybersyn-gui.explain-history-none" }, true)
		end
		for k = #changes, math.max(1, #changes - CHANGES + 1), -1 do
			out[#out + 1] = label({ "cybersyn-gui.explain-change", util.format_duration(now - changes[k]),
				utext.chip_caption(reasons[k] or e.reason) })
		end
		if e.lost_to and e.lost_n > 0 then
			out[#out + 1] = label({ "cybersyn-diag.lost-priority", stop_name(e.lost_to), tostring(e.lost_n) })
		end
	end

	out[#out + 1] = heading({ "cybersyn-gui.relative-setup" })
	local findings = {}
	for _, f in ipairs(lint.findings()) do
		if f.id == r_id and f.subject ~= LINT_SUBJECT_TRAIN then findings[#findings + 1] = f end
	end
	local lint_s = storage.manager.lint
	if #findings == 0 then
		out[#out + 1] = label({ (lint_s and lint_s.pass or 0) == 0 and "cybersyn-gui.relative-setup-not-run"
			or "cybersyn-gui.relative-setup-none" }, true)
	end
	for _, f in ipairs(findings) do
		out[#out + 1] = label({ "", "• ", { "cybersyn-diag.lint-" .. LINT_KEYS[f.check] } })
		out[#out + 1] = label(pm.detail(f, lint_text.ENV), true)
		out[#out + 1] = label(pm.fix(f.check, f), true)
	end

	return out, sprite, quality
end

--- Places the frame right of the manager window, or left when the right side has no room.
local function place(player, pd, frame)
	local window = pd.refs and pd.refs.manager_window
	local scale = player.display_scale
	if not (window and window.valid and window.visible) then
		frame.force_auto_center()
		return
	end
	local loc = window.location
	local layout = pd.layout
	local width_px = math.floor((layout and layout.width or 1440) * scale)
	local own = math.floor((WIDTH + 24) * scale)
	local x = loc.x + width_px + math.floor(8 * scale)
	if x + own > player.display_resolution.width then x = math.max(0, loc.x - own - math.floor(8 * scale)) end
	frame.location = { x = x, y = loc.y }
end

--- Builds or refreshes the frame for pd.explain.
--- @param player LuaPlayer
--- @param pd PlayerData
--- @param force boolean? rebuild even when nothing changed
function explain.render(player, pd, force)
	local ex = pd.explain
	if not ex then return end
	local frame = player.gui.screen[FRAME]
	if not (frame and frame.valid) then return end
	local e = entry_of(ex.r_id, ex.hash)
	local sig = sig_of(ex.r_id, ex.hash, e)
	if not force and ex.sig == sig then return end
	ex.sig = sig
	local body = frame.body
	body.clear()
	local defs, sprite, quality = body_defs(ex.r_id, ex.hash, e)
	for _, def in ipairs(defs) do gui.add(body, def) end
	local title = frame.titlebar.title
	local caption = { "cybersyn-gui.explain-title", sprite and ("[img=" .. sprite .. "]") or "", stop_name(ex.r_id) }
	title.caption = caption
	title.tooltip = caption
end

--- Opens Explain for one Unserved key (the row's Why chip), or closes it when it already shows that key.
--- @param player LuaPlayer
--- @param pd PlayerData
--- @param r_id uint
--- @param hash string
function explain.open(player, pd, r_id, hash)
	local cur = pd.explain
	local frame = player.gui.screen[FRAME]
	if cur and cur.r_id == r_id and cur.hash == hash and frame and frame.valid then
		explain.close(player, pd)
		return
	end
	if frame and frame.valid then frame.destroy() end
	local _, f = gui.add(player.gui.screen, {
		type = "frame",
		name = FRAME,
		direction = "vertical",
		style_mods = { width = WIDTH },
		{
			type = "flow",
			name = "titlebar",
			style = "flib_titlebar_flow",
			-- Requester names carry many icons: the title squashes (full caption in its tooltip) so the X always stays in
			-- the frame, and the whole bar drags because the handle can be squashed to nothing.
			{
				type = "label",
				name = "title",
				style = "frame_title",
				style_mods = { horizontally_squashable = true },
			},
			{ type = "empty-widget", name = "drag", style = "flib_titlebar_drag_handle", ignored_by_interaction = true },
			{
				type = "sprite-button",
				name = "close",
				style = "frame_action_button",
				sprite = "utility/close",
				tooltip = { "gui.close-instruction" },
				handler = { [defines.events.on_gui_click] = explain.handle.explain_close },
			},
		},
		{
			type = "frame",
			name = "body",
			style = "inside_shallow_frame_with_padding",
			direction = "vertical",
			style_mods = { horizontally_stretchable = true },
		},
	})
	f.titlebar.drag_target = f
	f.titlebar.title.drag_target = f
	pd.explain = { r_id = r_id, hash = hash }
	place(player, pd, f)
	explain.render(player, pd, true)
	-- An overlay of the window: Escape closes it first (manager.top_overlay).
	util.overlay_opened(player, pd)
end

--- @param player LuaPlayer?
--- @param pd PlayerData
function explain.close(player, pd)
	local was = pd.explain ~= nil
	pd.explain = nil
	if not player then return end
	local frame = player.gui.screen[FRAME]
	if frame and frame.valid then frame.destroy() end
	if was then util.overlay_closed(player, pd) end
end

--- Manager tick: refresh the open frames; close a frame whose window was closed.
--- @param manager_data Manager
function explain.tick(manager_data)
	for i, pd in pairs(manager_data.players) do
		if pd.explain then
			local player = game.get_player(i)
			if not (player and pd.is_manager_open) then
				explain.close(player, pd)
			else
				explain.render(player, pd)
			end
		end
	end
end

function explain.handle.explain_close(player, pd)
	explain.close(player, pd)
end

explain.wrapper = util.wrapper_pd

gui.add_handlers(explain.handle, explain.wrapper, "cybersyn_explain")

-- ---------------------------------------------------------------- dev interface

local function view(elem, out)
	if elem.type == "label" or elem.type == "button" then out[#out + 1] = elem.caption end
	for _, c in ipairs(elem.children) do view(c, out) end
	return out
end

dev.extend({
	explain_open = function(pi, r_id, hash)
		local player = game.get_player(pi)
		local pd = storage.manager.players[pi]
		explain.open(player, pd, r_id, hash)
		return pd.explain ~= nil
	end,
	explain_dump = function(pi)
		local player = game.get_player(pi)
		local pd = storage.manager.players[pi]
		local frame = player.gui.screen[FRAME]
		if not (frame and frame.valid) then return { open = false } end
		local bar = frame.titlebar
		local close = bar.close
		return { open = true, key = pd.explain, title = bar.title.caption, lines = view(frame.body, {}),
			location = frame.location,
			close = { exists = close ~= nil and close.valid, style = close and close.style.name, sprite = close and close.sprite },
			title_squashable = bar.title.style.horizontally_squashable, title_tooltip = bar.title.tooltip,
			drag = bar.drag_target and bar.drag_target.name, title_drag = bar.title.drag_target and bar.title.drag_target.name }
	end,
	explain_click_close = function(pi)
		local frame = game.get_player(pi).gui.screen[FRAME]
		local btn = frame and frame.valid and frame.titlebar.close
		if not btn then return false end
		return gui.dispatch({ name = defines.events.on_gui_click, element = btn, player_index = pi, tick = game.tick,
			button = defines.mouse_button_type.left, shift = false, control = false, alt = false })
	end,
	explain_close = function(pi)
		local player = game.get_player(pi)
		explain.close(player, storage.manager.players[pi])
	end,
})

return explain
