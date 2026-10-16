-- Log tab (PLAN3 §4.7 Log): the diagnostics rings as a list of events, newest first, in whole 28 px rows. The rows,
-- counts, badge and Summary come from scripts/gui/log-model.lua; this file turns them into elements and handles the
-- subheader. Visible only while diagnostics are on (storage.diag exists).

local gui = require("__flib__.gui")
local format = require("__flib__.format")

local util = require("scripts.gui.util")
local collector = require("scripts.gui.collector")
local dev = require("scripts.gui.dev")
local diag = require("scripts.diag")
local model = require("scripts.gui.log-model")
local text = require("scripts.gui.unserved-text")

--- @class PlayerData
--- @field log_filter LogFilter?
--- @field log_rows LogRowsState?
--- @field log_counts LogCountsState?
--- @field log_badge LogBadgeState?
--- @field log_summary LogSummaryState? only while Summary is on
--- @field log_seen_seq uint? newest seq the player had the Log on screen for (the badge counts errors after it)
--- @field log_export {path: string, state: "running"|"done"|"off", rows: int?, chunks: int?, first_tick: uint?, last_tick: uint?}? the player's latest export
--- @field log_widths {station: int, message: int, rows: int}? cell widths for the current layout
--- @field log_caps {[string]: any}? signatures of the subheader and caption texts last written

local log_tab = {}

local TAB = "log_tab"
local ROWS = "log_rows"
local ROW_HEIGHT = 28
-- Logical px at the 1,392 px content width of a 1,440 px window; the message takes the rest.
local W = { age = 60, dot = 16, kind = 20, train = 56, station = 300, item = 28, count = 44, print = 28 }
local BASE_CONTENT_WIDTH = 1392
local CELLS = 9
local SPACING = 8
local ROW_PADDING = 4 + 8
local FRAME_BORDER = 4
local ICON = 20
local NAME_ICONS = 3
-- Rows examined per update (measured on a 2,030-station base, full ring of 16,384 rows): the rows' backward scan
-- stops early on a dense filter, the counts and the Summary visit every row of the window.
local ROWS_BUDGET = 2048
local COUNTS_BUDGET = 1024
local SUMMARY_BUDGET = 1024
local BADGE_BUDGET = model.BUDGET
local SEV_SPRITES = { "flib_indicator_red", "flib_indicator_orange", "flib_indicator_white" }
local SEV_KEYS = { "error", "warning", "info" }
local CYCLE_MINUTES = 10
local MINUTE = 3600

-- Kind sprites, checked against the loaded prototypes once (a pure function of them, so the same in every Lua state).
local KIND_SPRITE_CANDIDATES = {
	[DIAG_KIND_UNSERVED_REASON] = { "utility/clock" },
	[DIAG_KIND_SERVED] = { "utility/check_mark_green", "utility/check_mark" },
	[DIAG_KIND_FLAPPING] = { "utility/refresh" },
	[DIAG_KIND_DISPATCH_FAILED] = { "utility/danger_icon" },
	[DIAG_KIND_DELIVERY_FAILED] = { "utility/danger_icon" },
	[DIAG_KIND_ALERT] = { "utility/warning_icon" },
	[DIAG_KIND_STATION_POWER] = { "utility/electricity_icon", "item/substation" },
	[DIAG_KIND_STATION_LIMIT] = { "item/train-stop" },
	[DIAG_KIND_STATION_WARMUP_DONE] = { "item/train-stop" },
	[DIAG_KIND_STATION_DISABLED] = { "item/train-stop" },
	[DIAG_KIND_SHORT_LOAD] = { "item/cargo-wagon" },
	[DIAG_KIND_UNEXPECTED_CARGO] = { "item/cargo-wagon" },
	[DIAG_KIND_RESIDUAL_CARGO] = { "item/cargo-wagon" },
	[DIAG_KIND_SCHEDULE_EDITED] = { "utility/rename_icon", "item/locomotive" },
	[DIAG_KIND_LINT] = { "item/cybersyn-combinator", "item/decider-combinator" },
	[DIAG_KIND_ACKNOWLEDGED] = { "utility/check_mark_white", "utility/check_mark" },
	[DIAG_KIND_UNACKNOWLEDGED] = { "utility/check_mark_white", "utility/check_mark" },
	[DIAG_KIND_MANUAL_ACTION] = { "utility/hand", "utility/rename_icon" },
	[DIAG_KIND_DISPATCHED] = { "item/locomotive" },
	[DIAG_KIND_ARRIVE_P] = { "item/locomotive" },
	[DIAG_KIND_LEAVE_P] = { "item/locomotive" },
	[DIAG_KIND_ARRIVE_R] = { "item/locomotive" },
	[DIAG_KIND_LEAVE_R] = { "item/locomotive" },
	[DIAG_KIND_RETURNED] = { "item/locomotive" },
	[DIAG_KIND_TRAIN_STATE] = { "item/locomotive" },
}
local kind_sprites

--- @param kind int
--- @return string
local function kind_sprite(kind)
	if not kind_sprites then
		kind_sprites = {}
		for k, list in pairs(KIND_SPRITE_CANDIDATES) do
			for _, path in ipairs(list) do
				if helpers.is_valid_sprite_path(path) then
					kind_sprites[k] = path
					break
				end
			end
		end
	end
	return kind_sprites[kind] or "utility/questionmark"
end

-- ---------------------------------------------------------------- state

--- @param player_data PlayerData
--- @return LogFilter
local function get_filter(player_data)
	local f = player_data.log_filter
	if not f then
		f = model.default_filter()
		player_data.log_filter = f
	end
	return f
end
log_tab.get_filter = get_filter

--- The manager's item filter as diag's item index (-1: an item the log has never seen, so nothing matches).
--- @param player_data PlayerData
--- @param d DiagState
--- @return int?
local function item_filter(player_data, d)
	local hash = player_data.search_item
	if not hash then return nil end
	return d.item_ix[hash] or -1
end

--- @param player_data PlayerData
--- @param d DiagState
--- @return LogCompiled
local function compiled(player_data, d)
	return model.compile(get_filter(player_data), game.tick, item_filter(player_data, d))
end
log_tab.compiled = compiled

--- @param player_data PlayerData
--- @return int
local function row_limit(player_data)
	local layout = player_data.layout
	return layout and layout.rows_by_tab[TAB] or 10
end

--- @param player_data PlayerData
--- @return {[string]: any}
local function caps(player_data)
	local c = player_data.log_caps
	if not c then
		c = {}
		player_data.log_caps = c
	end
	return c
end

--- Writes caption (and tooltip) only when `sig` changed since the last write to that element.
local function set_caption(player_data, elem, sig, caption, tooltip)
	if not (elem and elem.valid) then return end
	local c = caps(player_data)
	local name = elem.name
	if c[name] == sig then return end
	c[name] = sig
	elem.caption = caption
	if tooltip ~= nil then elem.tooltip = tooltip end
end

-- ---------------------------------------------------------------- names

local parsed_cache = {}

--- A pure function of the name, so a cache that differs between Lua states cannot desync anything.
--- @param name string
--- @return RichNameParts
local function parse_name(name)
	local p = parsed_cache[name]
	if not p then
		p = util.parse_rich_name(name)
		parsed_cache[name] = p
	end
	return p
end

--- @class LogNameView
--- @field name string
--- @field text string
--- @field icons {sprite: string, quality: string?}[]
--- @field kind "station"|"depot"|"refueler"

--- A station, depot or refueler by its stop's unit number, from the snapshot when it holds the station.
--- @param id uint
--- @return LogNameView?
local function station_view(id)
	if not id or id == 0 then return nil end
	local st = collector.get().stations[id]
	local name, parts, kind
	if st then
		name, parts, kind = st.name, st.name_parts, "station"
	else
		local record = storage.stations[id]
		kind = "station"
		if not record then
			record = storage.depots[id]
			kind = "depot"
		end
		if not record then
			record = storage.refuelers[id]
			kind = "refueler"
		end
		local stop = record and record.entity_stop
		if not (stop and stop.valid) then return nil end
		name = stop.backer_name
		parts = parse_name(name)
	end
	local icons = {}
	local lead = parts and parts.lead
	if lead then
		for i = 1, math.min(#lead, NAME_ICONS) do
			icons[i] = { sprite = lead[i], quality = parts.lead_quality and parts.lead_quality[i] or nil }
		end
	end
	local label = parts and parts.text or name
	if label == nil or label == "" then label = name end
	return { name = name, text = label, icons = icons, kind = kind }
end
log_tab.station_view = station_view

--- @param index uint
--- @return string?
local function player_name(index)
	local p = index and index > 0 and game.get_player(index)
	return p and p.name or nil
end

--- @type LogTextContext
local TEXT_CTX = {
	player = player_name,
	duration = util.format_duration,
	stock = text.stock_caption,
	chip = text.chip_caption,
}

--- @param g LogGroup
--- @return LocalisedString
function log_tab.message(g)
	return model.message(g, TEXT_CTX)
end

-- ---------------------------------------------------------------- build

local function hoverable(def)
	return util.hoverable(def, ROWS)
end

--- Severity toggle: "[dot] 12", toggled while that severity is shown.
--- @param sev int
local function sev_button(sev)
	return {
		type = "button",
		name = "log_sev_" .. sev,
		style = "cybersyn_log_sev_button",
		caption = "[img=" .. SEV_SPRITES[sev] .. "] 0",
		toggled = true,
		tags = { sev = sev },
		handler = { [defines.events.on_gui_click] = log_tab.handle.log_sev_click },
	}
end

--- @return LocalisedString[]
local function kind_items()
	local items = {}
	for i, it in ipairs(model.KIND_ITEMS) do
		if it.group then
			items[i] = { "", "[font=default-semibold]", { "cybersyn-gui.log-group-" .. model.GROUPS[it.group].name }, "[/font]" }
		elseif it.kind then
			items[i] = { "", "   ", { "cybersyn-diag.kind-" .. DIAG_KIND_KEYS[it.kind] } }
		else
			items[i] = { "cybersyn-gui.log-all-kinds" }
		end
	end
	return items
end

--- The subheader's right side; manager.lua puts it after the shared chip and progress note.
--- @return flib.GuiElemDef[]
function log_tab.subheader_right()
	return {
		{ type = "label", name = "log_export_note", style = "cybersyn_subheader_note", visible = false },
		sev_button(DIAG_SEV_ERROR),
		sev_button(DIAG_SEV_WARNING),
		sev_button(DIAG_SEV_INFO),
		{
			type = "drop-down",
			name = "log_kind_dropdown",
			style = "cybersyn_log_kind_dropdown",
			items = kind_items(),
			selected_index = 1,
			tooltip = { "cybersyn-gui.log-kind-tooltip" },
			handler = { [defines.events.on_gui_selection_state_changed] = log_tab.handle.log_kind_changed },
		},
		{ type = "label", style = "subheader_caption_label", caption = { "cybersyn-gui.log-train-label" },
			tooltip = { "cybersyn-gui.log-train-tooltip" } },
		{
			type = "textfield",
			name = "log_train_field",
			style = "cybersyn_log_train_field",
			numeric = true,
			allow_decimal = false,
			allow_negative = false,
			clear_and_focus_on_right_click = true,
			lose_focus_on_confirm = true,
			tooltip = { "cybersyn-gui.log-train-tooltip" },
			handler = { [defines.events.on_gui_text_changed] = log_tab.handle.log_train_changed },
		},
		{
			type = "button",
			name = "log_subject_chip",
			style = "cybersyn_item_chip",
			visible = false,
			mouse_button_filter = { "left", "right" },
			tooltip = { "cybersyn-gui.log-subject-tooltip" },
			handler = { [defines.events.on_gui_click] = log_tab.handle.log_subject_clear },
		},
		{
			type = "drop-down",
			name = "log_window_dropdown",
			style = "cybersyn_log_window_dropdown",
			items = { { "cybersyn-gui.log-window-10" }, { "cybersyn-gui.log-window-60" }, { "cybersyn-gui.log-window-all" } },
			selected_index = model.DEFAULT_WINDOW,
			tooltip = { "cybersyn-gui.log-window-tooltip" },
			handler = { [defines.events.on_gui_selection_state_changed] = log_tab.handle.log_window_changed },
		},
		{
			type = "checkbox",
			name = "log_follow",
			caption = { "cybersyn-gui.log-follow" },
			tooltip = { "cybersyn-gui.log-follow-tooltip" },
			state = true,
			handler = { [defines.events.on_gui_checked_state_changed] = log_tab.handle.log_follow_changed },
		},
		{
			type = "checkbox",
			name = "log_summary_toggle",
			caption = { "cybersyn-gui.log-summary" },
			tooltip = { "cybersyn-gui.log-summary-tooltip" },
			state = false,
			handler = { [defines.events.on_gui_checked_state_changed] = log_tab.handle.log_summary_changed },
		},
		{
			type = "sprite-button",
			name = "log_export_button",
			style = "tool_button",
			sprite = "utility/export_slot",
			tooltip = { "cybersyn-gui.log-export-tooltip" },
			handler = { [defines.events.on_gui_click] = log_tab.handle.log_export_click },
		},
	}
end

--- One table of the Summary: a caption and up to SUMMARY_TOP rows of [dot] [subject] [count].
local function summary_table(name, caption)
	return {
		type = "frame",
		name = name .. "_frame",
		direction = "vertical",
		style = "cybersyn_log_summary_frame",
		{
			type = "frame",
			style = "cybersyn_unserved_caption_frame",
			{ type = "label", name = name .. "_caption", style = "subheader_caption_label", caption = caption },
		},
		{ type = "table", name = name, style = "cybersyn_log_summary_table", column_count = 3 },
	}
end

function log_tab.create()
	return {
		tab = {
			name = "manager_log_tab",
			type = "tab",
			caption = { "cybersyn-gui.log" },
		},
		content = {
			name = "manager_log_content_frame",
			type = "flow",
			direction = "vertical",
			style = "cybersyn_overview_content",
			{
				type = "frame",
				name = "log_frame",
				direction = "vertical",
				style = "cybersyn_unserved_frame",
				{
					type = "frame",
					direction = "horizontal",
					style = "cybersyn_unserved_caption_frame",
					{ type = "label", name = "log_header", style = "subheader_caption_label", caption = "" },
					{ type = "empty-widget", style = "flib_horizontal_pusher" },
					{ type = "label", name = "log_status", style = "cybersyn_subheader_note", caption = "" },
				},
				{
					type = "flow",
					name = "log_body",
					direction = "vertical",
					style_mods = { vertical_spacing = 0 },
					{ type = "table", name = ROWS, style = "cybersyn_log_rows_table", column_count = 1 },
					{
						type = "flow",
						name = "log_summary",
						direction = "horizontal",
						visible = false,
						style_mods = { horizontal_spacing = 12, padding = 8 },
						summary_table("log_summary_stations", { "cybersyn-gui.log-summary-stations" }),
						summary_table("log_summary_items", { "cybersyn-gui.log-summary-items" }),
					},
					{
						type = "flow",
						name = "log_empty_flow",
						direction = "horizontal",
						style = "cybersyn_overview_empty_flow",
						visible = false,
						{ type = "label", name = "log_empty", style = "cybersyn_overview_empty_label", caption = "" },
					},
				},
			},
		},
	}
end

--- Cell widths from the window layout and the rows area's height (whole rows).
--- @param player_data PlayerData
--- @param layout ManagerLayout
function log_tab.apply_layout(player_data, layout)
	local refs = player_data.refs
	local cw = layout.content_width
	local rows = layout.rows_by_tab[TAB]
	local station = math.floor(W.station * math.min(cw, BASE_CONTENT_WIDTH) / BASE_CONTENT_WIDTH)
	local fixed = W.age + W.dot + W.kind + W.train + station + W.item + W.count + W.print
	local message = cw - FRAME_BORDER - ROW_PADDING - (CELLS - 1) * SPACING - fixed
	local old = player_data.log_widths
	-- Two summary frames side by side with 12 between them, inside the body's 8 px padding.
	local summary = math.floor((cw - FRAME_BORDER - 16 - 12) / 2)
	player_data.log_widths = { station = station, message = message, rows = rows, summary = summary }
	for _, name in ipairs({ "log_summary_stations_frame", "log_summary_items_frame" }) do
		local frame = refs[name]
		if frame and frame.valid then frame.style.width = summary end
	end
	if player_data.log_caps then
		player_data.log_caps.log_summary_stations = nil
		player_data.log_caps.log_summary_items = nil
	end
	local body = refs.log_body
	if body and body.valid then body.style.height = rows * ROW_HEIGHT end
	local empty = refs.log_empty_flow
	if empty and empty.valid then empty.style.height = rows * ROW_HEIGHT end
	if not old or old.station ~= station or old.message ~= message then
		local parent = refs[ROWS]
		if parent and parent.valid then parent.clear() end
		local state = util.gui_state(player_data, ROWS)
		state.keys, state.sigs, state.memo = nil, nil, nil
	end
end

-- ---------------------------------------------------------------- rows

-- A pure function of the loaded prototypes, so the same in every Lua state.
local sprite_ok = {}

--- @param path string
--- @return string
local function valid_sprite(path)
	local ok = sprite_ok[path]
	if ok == nil then
		ok = helpers.is_valid_sprite_path(path)
		sprite_ok[path] = ok
	end
	return ok and path or "utility/questionmark"
end

--- Phase profilers while the dev interface measures a render (nil otherwise).
--- @type {counts: LuaProfiler, rows: LuaProfiler, render: LuaProfiler, rest: LuaProfiler, written: int}?
local prof


--- @param g LogGroup
--- @return string? hash
local function group_item(g)
	local d = storage.diag
	return g.item ~= 0 and d and d.item_hash[g.item] or nil
end

--- @param view LogNameView?
--- @param extra LocalisedString?
--- @return LocalisedString
local function station_tooltip(view, extra)
	if not view then return "" end
	local tooltip = { "", "[font=default-semibold]", view.name, "[/font]" }
	if extra then
		tooltip[#tooltip + 1] = "\n"
		tooltip[#tooltip + 1] = extra
	end
	tooltip[#tooltip + 1] = "\n"
	tooltip[#tooltip + 1] = { "cybersyn-gui.link-footer" }
	return tooltip
end

-- Station names and train validity are read again at most this often for a row whose event did not change.
local NAME_REFRESH = 600

--- Writes a row's cells, each only when what it shows changed since `m` (what the element shows now; empty for a
--- new row). A row whose event, count and numbers are unchanged is not looked at until the name refresh.
--- @param cells LuaGuiElement[]
--- @param g LogGroup
--- @param m table the row's memo, updated
--- @param now uint
local function write_cells(cells, g, m, now)
	m.seq, m.n_, m.a_, m.b_, m.epoch = g.seq, g.n, g.a, g.b, math.floor(now / NAME_REFRESH)
	if prof then prof.written = prof.written + 1 end
	local tsig = g.first_tick .. "|" .. g.tick .. "|" .. g.n
	if m.t ~= tsig then
		cells[1].tooltip = model.age_tooltip(g, util.format_duration)
		m.t = tsig
	end
	if m.sev ~= g.sev then
		cells[2].sprite = SEV_SPRITES[g.sev] or SEV_SPRITES[3]
		cells[2].tooltip = { "cybersyn-diag.sev-" .. (SEV_KEYS[g.sev] or "info") }
		m.sev = g.sev
	end
	if m.kind ~= g.kind then
		cells[3].sprite = kind_sprite(g.kind)
		cells[3].tooltip = { "cybersyn-diag.kind-" .. (DIAG_KIND_KEYS[g.kind] or "alert") }
		m.kind = g.kind
	end
	-- train
	local train_ok = g.train ~= 0 and storage.trains[g.train] ~= nil
	local trsig = g.train .. (train_ok and "t" or "")
	if m.tr ~= trsig then
		local train = cells[4]
		if g.train ~= 0 then
			train.caption = tostring(g.train)
			train.tooltip = { "", { "cybersyn-gui.log-train", tostring(g.train) }, "\n", { "cybersyn-gui.link-footer" } }
		else
			train.caption = ""
			train.tooltip = ""
		end
		local style = train_ok and "cybersyn_log_link" or "cybersyn_log_link_gone"
		if m.trs ~= style then
			train.style = style
			train.style.width = W.train
			m.trs = style
		end
		m.tr = trsig
	end
	-- station: the icons only when the name or the target changed
	local view = station_view(g.station)
	local ssig = g.station .. "|" .. (view and view.name or "")
	if m.st ~= ssig then
		local cell = cells[5]
		local icons, button = cell.children[1], cell.children[2]
		-- Three icon slots made with the row, shown as the name needs them: a row reused for another station
		-- creates no elements.
		local slots
		local mi = m.icons
		if not mi then
			mi = {}
			m.icons = mi
		end
		for i = 1, NAME_ICONS do
			local icon = view and view.icons[i]
			local sprite = icon and valid_sprite(icon.sprite) or false
			if mi[i] ~= sprite then
				slots = slots or icons.children
				local slot = slots[i]
				if sprite then slot.sprite = sprite end
				if (mi[i] or false) == false or sprite == false then slot.visible = sprite ~= false end
				mi[i] = sprite
			end
		end
		if view then
			button.caption = view.text
		elseif g.station ~= 0 then
			button.caption = { "cybersyn-gui.log-gone-station", tostring(g.station) }
		else
			button.caption = ""
		end
		if m.en ~= (view ~= nil) then
			button.enabled = view ~= nil
			m.en = view ~= nil
		end
		button.tooltip = station_tooltip(view, nil)
		m.st = ssig
	end
	-- item
	local hash = group_item(g)
	if m.item ~= (hash or "") then
		local item = cells[6]
		local sprite, quality = nil, nil
		if hash then sprite, quality = util.item_sprite_and_tooltip(hash) end
		-- An empty slot shows nothing and log_link_click ignores it (disabled, it would draw its frame).
		if sprite then
			item.sprite = sprite
			if m.q ~= (quality or "") then
				item.quality = quality
				m.q = quality or ""
			end
			item.elem_tooltip = util.elem_tooltip(hash)
		else
			item.sprite = nil
			item.elem_tooltip = nil
		end
		m.item = hash or ""
	end
	-- message, count
	local msig = g.kind .. "|" .. g.code .. "|" .. g.a .. "|" .. g.b .. "|" .. g.station2 .. "|" .. g.n
	if m.msg ~= msig then
		cells[7].caption = log_tab.message(g)
		-- The message's tooltip names the other station of the event (the provider, the other end of a delivery);
		-- the kind is the kind sprite's tooltip.
		local other = diag.STATION2_IS_STATION[g.kind] and g.station2 ~= 0 and station_view(g.station2) or nil
		local tip = other and { "cybersyn-gui.log-other-station", other.name } or ""
		if other or m.mt then cells[7].tooltip = tip end
		m.mt = other ~= nil
		m.msg = msig
	end
	if m.n ~= g.n then
		cells[8].caption = model.repeat_caption(g.n)
		m.n = g.n
	end
end

--- The cells of a row, empty; write_cells fills them.
--- @param widths {station: int, message: int}
--- @return flib.GuiElemDef[]
local function cell_defs(widths)
	-- Rows are reused for other events, so their link cells carry no target: the click finds it from the row.
	local link = { [defines.events.on_gui_click] = log_tab.handle.log_link_click }
	return {
		hoverable({ type = "label", style = "cybersyn_log_age", style_mods = { width = W.age } }),
		hoverable({ type = "sprite", style = "cybersyn_log_dot" }),
		hoverable({ type = "sprite", style = "cybersyn_log_kind" }),
		hoverable({
			type = "button",
			style = "cybersyn_log_link",
			style_mods = { width = W.train },
			mouse_button_filter = { "left", "right" },
			tags = { cell = "train" },
			handler = link,
		}),
		{
			type = "flow",
			direction = "horizontal",
			style = "cybersyn_log_cell_flow",
			style_mods = { width = widths.station },
			{
				type = "flow",
				direction = "horizontal",
				style = "cybersyn_log_icon_flow",
				{ type = "sprite", style = "cybersyn_log_icon", visible = false, ignored_by_interaction = true },
				{ type = "sprite", style = "cybersyn_log_icon", visible = false, ignored_by_interaction = true },
				{ type = "sprite", style = "cybersyn_log_icon", visible = false, ignored_by_interaction = true },
			},
			hoverable({
				type = "button",
				style = "cybersyn_log_link",
				style_mods = { maximal_width = widths.station - NAME_ICONS * ICON - 8 },
				mouse_button_filter = { "left", "right" },
				tags = { cell = "station" },
				handler = link,
			}),
		},
		hoverable({
			type = "sprite-button",
			style = "cybersyn_log_item",
			mouse_button_filter = { "left", "right" },
			tooltip = { "cybersyn-gui.item-click-hint" },
			tags = { cell = "item" },
			handler = link,
		}),
		hoverable({ type = "label", style = "cybersyn_log_message", style_mods = { width = widths.message } }),
		hoverable({ type = "label", style = "cybersyn_log_count", style_mods = { width = W.count } }),
		hoverable({
			type = "sprite-button",
			style = "cybersyn_log_print",
			sprite = "utility/center",
			tooltip = { "cybersyn-gui.log-print-tooltip" },
			handler = { [defines.events.on_gui_click] = log_tab.handle.log_print_click },
		}),
	}
end

-- One set of row callbacks for every row (util.sync_children passes the entry); the render's context is in upvalues
-- set by render_rows, so a render allocates no closures.
local r_memo, r_widths, r_now

--- @param entry {key: uint, g: LogGroup}
local function row_build(entry)
	r_memo[entry.key] = nil
	return hoverable({ type = "frame", direction = "horizontal", style = "cybersyn_log_row", children = cell_defs(r_widths) })
end

local function row_built(elem, entry)
	local m = {}
	local cells = elem.children
	write_cells(cells, entry.g, m, r_now)
	m.a = model.age_caption(r_now, entry.g, util.short_duration)
	cells[1].caption = m.a
	r_memo[entry.key] = m
end

-- The element keeps what it showed for the vanished key, so its memo moves with it.
local function row_reuse(elem, old_key, entry)
	r_memo[entry.key] = r_memo[old_key] or {}
	r_memo[old_key] = nil
end

local function row_update(elem, entry)
	local key, g, now = entry.key, entry.g, r_now
	local m = r_memo[key]
	if not m then
		m = {}
		r_memo[key] = m
	end
	local cells
	if m.seq ~= g.seq or m.n_ ~= g.n or m.a_ ~= g.a or m.b_ ~= g.b or m.epoch ~= math.floor(now / NAME_REFRESH) then
		cells = elem.children
		write_cells(cells, g, m, now)
	end
	local age = model.age_caption(now, g, util.short_duration)
	if m.a ~= age then
		cells = cells or elem.children
		cells[1].caption = age
		m.a = age
	end
end

--- Rows live in a one-column table whose odd-row background gives the tint, so a row that moves needs no restyle.
--- @param player_data PlayerData
--- @param groups LogGroup[]
local function render_rows(player_data, groups)
	local refs = player_data.refs
	local parent = refs[ROWS]
	local widths = player_data.log_widths
	if not (parent and parent.valid and widths) then return end
	local state = util.gui_state(player_data, ROWS)
	local memo = state.memo
	if not memo then
		memo = {}
		state.memo = memo
	end
	r_memo, r_widths, r_now = memo, widths, game.tick
	local entries = {}
	for i, g in ipairs(groups) do
		entries[i] = { key = g.first, g = g, build = row_build, built = row_built, reuse = row_reuse, update = row_update }
	end
	util.sync_children(parent, entries, state, util.hold_active(player_data, ROWS), true)
	local keep = {}
	for _, key in ipairs(state.keys or {}) do keep[key] = memo[key] end
	state.memo = keep
	r_memo, r_widths = nil, nil
end

-- ---------------------------------------------------------------- summary

--- @param player_data PlayerData
--- @param tbl LuaGuiElement
--- @param list table[]?
--- @param is_item boolean
local function render_summary_table(player_data, tbl, list, is_item)
	if not (tbl and tbl.valid) then return end
	local d = storage.diag
	local sig = { tostring(list ~= nil) }
	for _, e in ipairs(list or {}) do sig[#sig + 1] = (e.id or e.item) .. ":" .. e.n .. ":" .. e.sev end
	sig = table.concat(sig, ",")
	local c = caps(player_data)
	if c[tbl.name] == sig then return end
	c[tbl.name] = sig
	tbl.clear()
	local widths = player_data.log_widths
	-- frame width less the table padding, the dot, the count and the spacing between them
	local name_width = (widths and widths.summary or 600) - 14 - 16 - 60 - 2 * 8 - 8
	for _, e in ipairs(list or {}) do
		gui.add(tbl, { type = "sprite", style = "cybersyn_log_dot", sprite = SEV_SPRITES[e.sev],
			tooltip = { "cybersyn-diag.sev-" .. SEV_KEYS[e.sev] } })
		if is_item then
			local hash = d and d.item_hash[e.item]
			local sprite, quality, tooltip = nil, nil, nil
			if hash then sprite, quality, tooltip = util.item_sprite_and_tooltip(hash) end
			gui.add(tbl, {
				type = "flow",
				direction = "horizontal",
				style = "cybersyn_log_cell_flow",
				{
					type = "sprite-button",
					style = "cybersyn_log_item",
					sprite = sprite,
					quality = quality,
					elem_tooltip = hash and util.elem_tooltip(hash) or nil,
					tags = hash and { kind = "item", id = hash } or {},
					mouse_button_filter = { "left", "right" },
					handler = { [defines.events.on_gui_click] = util.handle.link_click },
				},
				{ type = "label", style = "cybersyn_log_message", style_mods = { width = name_width - 32 },
					caption = tooltip and tooltip[4] or hash or "?" },
			})
		else
			local view = station_view(e.id)
			gui.add(tbl, {
				type = "button",
				style = "cybersyn_log_link",
				style_mods = { width = name_width },
				caption = view and view.name or { "cybersyn-gui.log-gone-station", tostring(e.id) },
				enabled = view ~= nil,
				tooltip = station_tooltip(view, nil),
				tags = view and { kind = view.kind, id = e.id } or {},
				mouse_button_filter = { "left", "right" },
				handler = { [defines.events.on_gui_click] = util.handle.link_click },
			})
		end
		gui.add(tbl, { type = "label", style = "cybersyn_log_count", style_mods = { width = 60 }, caption = format.number(e.n),
			tooltip = { "cybersyn-gui.log-summary-count-tooltip", format.number(e.n) } })
	end
end

--- @param player_data PlayerData
--- @param ss LogSummaryState
--- @param done boolean
local function render_summary(player_data, ss, done)
	local refs = player_data.refs
	render_summary_table(player_data, refs.log_summary_stations, done and ss.top_stations or nil, false)
	render_summary_table(player_data, refs.log_summary_items, done and ss.top_items or nil, true)
end

-- ---------------------------------------------------------------- subheader and header line

--- Dispatches per planner cycle: deliveries dispatched per tick over the last CYCLE_MINUTES minute buckets, times the
--- last cycle's length (one cycle's own count jumps between 0 and a handful).
--- @return number? per_cycle
--- @return int ticks last cycle length
local function cycle_figures()
	local s = storage.stats
	local cycle = s and s.cycle
	local ticks = cycle and cycle.ticks_last or 0
	if not (s and s.minute and ticks > 0) then return nil, ticks end
	local now = game.tick
	local oldest = now - now % MINUTE - (CYCLE_MINUTES - 1) * MINUTE
	local first, dispatches = nil, 0
	for _, b in pairs(s.minute) do
		if b.start_tick and b.start_tick >= oldest and b.start_tick <= now then
			dispatches = dispatches + (b.dispatches or 0)
			if not first or b.start_tick < first then first = b.start_tick end
		end
	end
	if not first or now <= first then return cycle.dispatches_last, ticks end
	return dispatches / (now - first) * ticks, ticks
end

--- "covering the last 11 min · basic · planner cycle 43 ticks · 2.7 dispatches per cycle"; with full on, the full
--- events' own reach is named too (the full ring fills far faster than the basic one).
--- @param d DiagState
--- @return LocalisedString
--- @return string sig
local function header_line(d)
	local now = game.tick
	local rb, rf = model.rings(d)
	-- A ring that has not wrapped yet reaches back to when diagnostics started (nothing older was dropped).
	local start = d.loaded_tick
	if rb.count >= rb.size and rb.count > 0 then start = math.max(start, rb.tick[diag.ring_at(rb, 0)]) end
	local covering = util.short_duration(now - start)
	local mode, full_covering = { "cybersyn-gui.log-mode-basic" }, ""
	if rf then
		local full_start = rf.count > 0 and rf.tick[diag.ring_at(rf, 0)] or now
		full_covering = util.short_duration(now - full_start)
		mode = { "cybersyn-gui.log-mode-full", full_covering }
	end
	local per_cycle, ticks = cycle_figures()
	local per = per_cycle and string.format("%.1f", per_cycle) or "–"
	return { "cybersyn-gui.log-header", covering, mode, tostring(ticks), per },
		covering .. "|" .. full_covering .. "|" .. ticks .. "|" .. per
end

--- The export note in the subheader: "Exporting… n %", then where the file went.
--- @param player_data PlayerData
function log_tab.refresh_export_note(player_data)
	local refs = player_data.refs
	local note = refs and refs.log_export_note
	if not (note and note.valid) then return end
	local ex = player_data.log_export
	local job
	if ex and ex.state == "running" then
		local d = storage.diag
		for _, j in ipairs(d and d.export_jobs or {}) do
			if j.path == ex.path then job = j end
		end
	end
	local sig, caption, tooltip
	if job then
		local percent = math.floor(diag.export_progress(job) * 100)
		sig = "run" .. percent
		caption = { "cybersyn-gui.log-exporting", tostring(percent) }
		tooltip = { "cybersyn-gui.log-export-path", job.path }
	elseif ex and ex.state ~= "running" then
		sig = ex.state .. ex.path .. tostring(ex.rows)
		local key = ex.state == "off" and "cybersyn-gui.log-exported-off" or "cybersyn-gui.log-exported"
		caption = { key, format.number(ex.rows or 0), ex.path }
		tooltip = { "cybersyn-gui.log-export-path", ex.path }
	else
		sig = ""
	end
	local shown = sig ~= ""
	if note.visible ~= shown then note.visible = shown end
	if shown then set_caption(player_data, note, sig, caption, tooltip) end
end

--- @param player_data PlayerData
--- @param cs LogCountsState
--- @param building boolean
local function render_sev_buttons(player_data, cs, building)
	local refs = player_data.refs
	local f = get_filter(player_data)
	for sev = 1, 3 do
		local button = refs["log_sev_" .. sev]
		if button and button.valid then
			local n = cs.total[sev]
			local shown = f.sev[sev] == true
			local sig = n .. (building and "+" or "") .. (shown and "on" or "off")
			local c = caps(player_data)
			if c[button.name] ~= sig then
				c[button.name] = sig
				local count = format.number(n) .. (building and "+" or "")
				button.caption = "[img=" .. SEV_SPRITES[sev] .. "] " .. count
				button.toggled = shown
				button.tooltip = { "cybersyn-gui.log-sev-tooltip", { "cybersyn-diag.sev-" .. SEV_KEYS[sev] }, count }
			end
		end
	end
end

--- The subheader controls written back from the stored filter (on open, and after a dev or chip change).
--- @param player_data PlayerData
function log_tab.restore_widgets(player_data)
	local refs = player_data.refs
	local f = get_filter(player_data)
	local dropdown = refs.log_kind_dropdown
	if dropdown and dropdown.valid then
		local index = 1
		for i, it in ipairs(model.KIND_ITEMS) do
			if (f.group and it.group == f.group) or (f.kind and it.kind == f.kind) then index = i end
		end
		dropdown.selected_index = index
	end
	local field = refs.log_train_field
	if field and field.valid then
		local t = f.train and tostring(f.train) or ""
		if field.text ~= t then field.text = t end
	end
	local window = refs.log_window_dropdown
	if window and window.valid then window.selected_index = f.window or model.DEFAULT_WINDOW end
	if refs.log_follow and refs.log_follow.valid then refs.log_follow.state = f.follow ~= false end
	if refs.log_summary_toggle and refs.log_summary_toggle.valid then refs.log_summary_toggle.state = f.summary == true end
	local chip = refs.log_subject_chip
	if chip and chip.valid then
		local s = f.subject
		chip.visible = s ~= nil
		if s then
			local name
			if s.kind == "train" then
				name = { "cybersyn-gui.log-train", tostring(s.id) }
			else
				local view = station_view(s.id)
				name = view and view.name or tostring(s.id)
			end
			chip.caption = { "cybersyn-gui.log-subject-chip", name }
		end
	end
	local c = player_data.log_caps
	if c then
		for sev = 1, 3 do c["log_sev_" .. sev] = nil end
	end
end

-- ---------------------------------------------------------------- the tab

--- The tab exists in every window; it is shown while diagnostics are on. Every Lua state reads the same storage.diag,
--- so every peer writes the same `visible`.
--- @param player_data PlayerData
function log_tab.refresh_visibility(player_data)
	local refs = player_data.refs
	local tab = refs and refs.manager_log_tab
	if not (tab and tab.valid) then return end
	local on = storage.diag ~= nil
	if tab.visible ~= on then tab.visible = on end
	if not on then
		if tab.badge_text ~= "" then tab.badge_text = "" end
		player_data.log_badge = nil
		if player_data.selected_tab == TAB then util.select_tab(player_data, "overview_tab") end
	end
end

--- Unread errors as the tab's badge (PLAN3 §4.6).
--- @param player_data PlayerData
function log_tab.refresh_badge(player_data)
	local refs = player_data.refs
	local tab = refs and refs.manager_log_tab
	local d = storage.diag
	if not (tab and tab.valid and d) then return end
	local bs = player_data.log_badge
	if not bs then
		bs = {}
		player_data.log_badge = bs
	end
	local n = model.update_badge(bs, d, player_data.log_seen_seq, BADGE_BUDGET)
	local caption = n > 0 and format.number(n) or ""
	if tab.badge_text ~= caption then
		tab.badge_text = caption
		tab.tooltip = n > 0 and { "cybersyn-gui.log-badge-tooltip", format.number(n) } or ""
	end
end

--- @param player_data PlayerData
function log_tab.mark_seen(player_data)
	local d = storage.diag
	if not d then return end
	player_data.log_seen_seq = d.seq
end

--- @param map_data MapData
--- @param player_data PlayerData
local function prof_start(name)
	if prof then prof[name].restart() end
end

local function prof_stop(name)
	if prof then prof[name].stop() end
end

function log_tab.build(map_data, player_data)
	local refs = player_data.refs
	if not (refs.log_body and refs.log_body.valid) then return end
	local d = storage.diag
	if not d then return end
	local f = get_filter(player_data)
	local cf = compiled(player_data, d)
	local limit = row_limit(player_data)

	local cs = player_data.log_counts
	if not cs then
		cs = {}
		player_data.log_counts = cs
	end
	local rows_flow, summary_flow, empty_flow = refs[ROWS], refs.log_summary, refs.log_empty_flow
	local status_sig, status
	local empty_sig, empty_caption
	local rebuilt = false
	if f.summary then
		local ss = player_data.log_summary
		if not ss then
			ss = {}
			player_data.log_summary = ss
		end
		local done = model.update_summary(ss, d, cf, SUMMARY_BUDGET)
		if rows_flow.visible then rows_flow.visible = false end
		local any = done and (#ss.top_stations > 0 or #ss.top_items > 0)
		if summary_flow.visible ~= (any == true) then summary_flow.visible = any == true end
		render_summary(player_data, ss, done)
		if done then
			local age = util.short_duration(game.tick - ss.as_of_tick)
			status_sig = "sum" .. ss.scanned .. "|" .. age
			status = { "cybersyn-gui.log-summary-status", format.number(ss.scanned), age }
			if not any then empty_sig, empty_caption = "sum-empty", { "cybersyn-gui.log-empty" } end
		else
			status_sig, status = "summing", { "cybersyn-gui.log-summarising" }
			empty_sig, empty_caption = "summing", { "cybersyn-gui.log-summarising" }
		end
	else
		player_data.log_summary = nil
		local rs = player_data.log_rows
		if not rs then
			rs = { groups = {} }
			player_data.log_rows = rs
		end
		prof_start("rows")
		local old_sig = rs.sig
		model.update_rows(rs, d, cf, limit, f.follow ~= false, ROWS_BUDGET)
		rebuilt = rs.sig ~= old_sig
		prof_stop("rows")
		prof_start("render")
		if summary_flow.visible then summary_flow.visible = false end
		local any = #rs.groups > 0
		if rows_flow.visible ~= any then rows_flow.visible = any end
		-- With nothing to show the row elements stay (hidden), to be reused when rows come back.
		if any then render_rows(player_data, rs.groups) end
		prof_stop("render")
		if not any then
			if rs.below then
				empty_sig, empty_caption = "scanning", { "cybersyn-gui.log-scanning" }
			else
				empty_sig, empty_caption = "empty", { "cybersyn-gui.log-empty" }
			end
		end
		if f.follow == false and rs.anchor then
			local newer = d.seq - rs.anchor
			status_sig = "paused" .. newer
			status = { "cybersyn-gui.log-paused", format.number(newer) }
		else
			status_sig, status = "", ""
		end
	end
	-- A filter change rewrites every row; the counts' first scan waits for the next update.
	prof_start("counts")
	local building = model.update_counts(cs, d, cf, rebuilt and 0 or COUNTS_BUDGET)
	render_sev_buttons(player_data, cs, building)
	prof_stop("counts")

	prof_start("rest")
	local show_empty = empty_caption ~= nil
	if empty_flow.visible ~= show_empty then empty_flow.visible = show_empty end
	if show_empty then set_caption(player_data, refs.log_empty, empty_sig, empty_caption) end
	set_caption(player_data, refs.log_status, status_sig, status)

	local header, header_sig = header_line(d)
	set_caption(player_data, refs.log_header, header_sig, header, { "cybersyn-gui.log-header-tooltip" })
	log_tab.refresh_export_note(player_data)
	log_tab.mark_seen(player_data)
	prof_stop("rest")
end

--- Rows shown, for dev.rows.
--- @param player_data PlayerData
--- @return int
function log_tab.rendered_rows(player_data)
	local parent = player_data.refs[ROWS]
	if not (parent and parent.valid and parent.visible) then return 0 end
	return #parent.children
end

dev.register_rows(TAB, log_tab.rendered_rows)

-- ---------------------------------------------------------------- export, chat print, the subject chip

--- Ends of the export jobs, from diag (also when diagnostics are turned off with a job queued).
diag.set_export_listener(function(job, cause)
	local manager_data = storage.manager
	if not manager_data then return end
	-- By path, not player index: an export for a player who is not connected is written on the server (index 0).
	for _, player_data in pairs(manager_data.players) do
		local ex = player_data.log_export
		if ex and ex.path == job.path and ex.state == "running" then
			player_data.log_export = { path = job.path, state = cause == "off" and "off" or "done", rows = job.rows,
				chunks = job.chunks, first_tick = job.first_tick, last_tick = job.last_tick }
			log_tab.refresh_export_note(player_data)
		end
	end
end)

--- The fixed nth tick and the manager tick: one export chunk, then the note of whoever started that export.
function log_tab.export_tick()
	local job = diag.export_tick()
	if not job then return end
	local manager_data = storage.manager
	if not manager_data then return end
	for _, player_data in pairs(manager_data.players) do
		local ex = player_data.log_export
		if ex and ex.path == job.path and player_data.is_manager_open then log_tab.refresh_export_note(player_data) end
	end
end

--- Queues an export of what the Log's filter selects, written on the player's machine.
--- @param player LuaPlayer
--- @param player_data PlayerData
--- @return string? path
function log_tab.export(player, player_data)
	local d = storage.diag
	if not d then return nil end
	local path = diag.export(player.connected and player.index or 0, model.export_filter(compiled(player_data, d)))
	if path then
		player_data.log_export = { path = path, state = "running" }
		log_tab.refresh_export_note(player_data)
	end
	return path
end

--- A row's group by any seq it holds (the shown rows), else the ring row with that seq.
--- @param player_data PlayerData
--- @param seq uint
--- @return LogGroup?
local function find_group(player_data, seq)
	local rs = player_data.log_rows
	for _, g in ipairs(rs and rs.groups or {}) do
		if g.seq == seq or g.first == seq then return g end
	end
	local d = storage.diag
	if not d then return nil end
	for _, r in ipairs({ d.ring_basic, d.ring_full }) do
		local k = diag.first_after(r, seq - 1)
		if k < r.count then
			local i = diag.ring_at(r, k)
			if r.seq[i] == seq then return model.new_group(r, i) end
		end
	end
	return nil
end

--- The chat line for a row (PLAN3 §11.6): its age, kind, tags the chat makes clickable, and the message.
--- @param player LuaPlayer
--- @param g LogGroup
--- @return LocalisedString
function log_tab.chat_line(player, g)
	local train_unit
	local train = g.train ~= 0 and storage.trains[g.train]
	local entity = train and train.entity
	if entity and entity.valid then
		local front = entity.front_stock
		train_unit = front and front.unit_number or nil
	end
	local stop_unit, gps
	local view = station_view(g.station)
	if view then
		local record = storage.stations[g.station] or storage.depots[g.station] or storage.refuelers[g.station]
		local stop = record and record.entity_stop
		if stop and stop.valid then
			stop_unit = stop.unit_number
			gps = { x = stop.position.x, y = stop.position.y, surface = stop.surface.name }
		end
	elseif entity and entity.valid and entity.front_stock then
		local front = entity.front_stock
		gps = { x = front.position.x, y = front.position.y, surface = front.surface.name }
	end
	local tags = model.chat_tags(train_unit, stop_unit, gps, group_item(g))
	return { "cybersyn-gui.log-chat", util.format_duration(game.tick - g.tick),
		{ "cybersyn-diag.kind-" .. (DIAG_KIND_KEYS[g.kind] or "alert") }, tags, log_tab.message(g) }
end

--- @param player LuaPlayer
--- @param player_data PlayerData
--- @param seq uint
--- @return LocalisedString? printed
function log_tab.print_row(player, player_data, seq)
	local g = find_group(player_data, seq)
	if not g then return nil end
	local line = log_tab.chat_line(player, g)
	player.print(line)
	return line
end

--- Right-click on a train or station link anywhere in the manager: the Log shows only that train or stop.
--- @param player LuaPlayer
--- @param player_data PlayerData
--- @param kind string
--- @param id uint
function log_tab.set_subject(player, player_data, kind, id)
	local f = get_filter(player_data)
	local subject_kind = kind == "train" and "train" or "station"
	f.subject = { kind = subject_kind, id = id }
	f.summary = false
	log_tab.restore_widgets(player_data)
	local name
	if subject_kind == "train" then
		name = { "cybersyn-gui.log-train", tostring(id) }
	else
		local view = station_view(id)
		name = view and view.name or tostring(id)
	end
	if storage.diag then
		player.create_local_flying_text({ create_at_cursor = true, text = { "cybersyn-gui.log-subject-set", name } })
	end
end

util.set_log_subject(log_tab.set_subject)

-- ---------------------------------------------------------------- handlers

log_tab.handle = {}

--- @param e {player_index: uint}
function log_tab.wrapper(e, handler)
	local player = game.get_player(e.player_index)
	if not player then return end
	local player_data = storage.manager.players[e.player_index]
	if not player_data then return end
	handler(player, player_data, player_data.refs, e)
end

local function changed(player, player_data)
	util.rerender(player, player_data)
end

--- @param e EventData.on_gui_click
function log_tab.handle.log_sev_click(player, player_data, refs, e)
	local sev = e.element.tags.sev
	local f = get_filter(player_data)
	f.sev[sev] = not f.sev[sev]
	changed(player, player_data)
end

--- @param e EventData.on_gui_selection_state_changed
function log_tab.handle.log_kind_changed(player, player_data, refs, e)
	local it = model.KIND_ITEMS[e.element.selected_index] or {}
	local f = get_filter(player_data)
	f.group, f.kind = it.group, it.kind
	changed(player, player_data)
end

--- @param e EventData.on_gui_text_changed
function log_tab.handle.log_train_changed(player, player_data, refs, e)
	local f = get_filter(player_data)
	local id = tonumber(e.element.text)
	f.train = id and id > 0 and math.floor(id) or nil
	changed(player, player_data)
end

--- @param e EventData.on_gui_click
function log_tab.handle.log_subject_clear(player, player_data, refs, e)
	get_filter(player_data).subject = nil
	log_tab.restore_widgets(player_data)
	changed(player, player_data)
end

--- @param e EventData.on_gui_selection_state_changed
function log_tab.handle.log_window_changed(player, player_data, refs, e)
	get_filter(player_data).window = e.element.selected_index
	changed(player, player_data)
end

--- @param e EventData.on_gui_checked_state_changed
function log_tab.handle.log_follow_changed(player, player_data, refs, e)
	get_filter(player_data).follow = e.element.state
	changed(player, player_data)
end

--- @param e EventData.on_gui_checked_state_changed
function log_tab.handle.log_summary_changed(player, player_data, refs, e)
	local f = get_filter(player_data)
	f.summary = e.element.state
	-- Toggling it on again recomputes it.
	player_data.log_summary = nil
	changed(player, player_data)
end

--- @param e EventData.on_gui_click
function log_tab.handle.log_export_click(player, player_data, refs, e)
	log_tab.export(player, player_data)
end

--- @param e EventData.on_gui_click
--- The group a row element shows, from its position in the rows table.
--- @param player_data PlayerData
--- @param elem LuaGuiElement a row or anything inside one
--- @return LogGroup?
local function row_group(player_data, elem)
	local rows = player_data.refs[ROWS]
	while elem and elem.valid and elem.parent and elem.parent ~= rows do elem = elem.parent end
	if not (elem and elem.valid and elem.parent == rows) then return nil end
	local keys = util.gui_state(player_data, ROWS).keys
	local key = keys and keys[elem.get_index_in_parent()]
	local rs = player_data.log_rows
	for _, g in ipairs(rs and rs.groups or {}) do
		if g.first == key then return g end
	end
	return nil
end

--- The link target of a row's train, station or item cell: {kind, id} or nil.
--- @param g LogGroup
--- @param cell string
--- @return string? kind
--- @return any id
local function cell_target(g, cell)
	if cell == "train" then
		if g.train ~= 0 then return "train", g.train end
	elseif cell == "station" then
		local view = station_view(g.station)
		if view then return view.kind, g.station end
	elseif cell == "item" then
		local hash = group_item(g)
		if hash then return "item", hash end
	end
	return nil, nil
end

--- A train, station or item cell of a row: the shared link semantics (util.handle_link_click) on the row's target.
--- @param e EventData.on_gui_click
function log_tab.handle.log_link_click(player, player_data, refs, e)
	util.touch_hover(e)
	local g = row_group(player_data, e.element)
	if not g then return end
	local kind, id = cell_target(g, e.element.tags.cell)
	if not kind then return end
	util.handle_link_click(player, player_data, {
		element = { tags = { kind = kind, id = id } },
		button = e.button, shift = e.shift, control = e.control, alt = e.alt, player_index = e.player_index,
	})
end

--- @param e EventData.on_gui_click
function log_tab.handle.log_print_click(player, player_data, refs, e)
	util.touch_hover(e)
	local g = row_group(player_data, e.element)
	if g then log_tab.print_row(player, player_data, g.seq) end
end

log_tab.cell_target = cell_target

gui.add_handlers(log_tab.handle, log_tab.wrapper)

-- ---------------------------------------------------------------- dev interface

--- @param g LogGroup
local function group_view(g, d)
	return {
		seq = g.seq, first = g.first, n = g.n, tick = g.tick, first_tick = g.first_tick,
		kind = DIAG_KIND_NAMES[g.kind], sev = DIAG_SEV_NAMES[g.sev], code = g.code, train = g.train,
		station = g.station, station2 = g.station2, item = g.item ~= 0 and d.item_hash[g.item] or nil, a = g.a, b = g.b,
	}
end

dev.register_dump(TAB, function(player_data)
	local d = storage.diag
	local refs = player_data.refs
	local out = { diag = d ~= nil, tab_visible = refs.manager_log_tab.visible, badge = refs.manager_log_tab.badge_text }
	out.export_note = refs.log_export_note.visible and refs.log_export_note.caption or nil
	out.export = player_data.log_export
	if not d then return out end
	local f = get_filter(player_data)
	out.filter = f
	out.limit = row_limit(player_data)
	local rs = player_data.log_rows
	out.groups = {}
	for i, g in ipairs(rs and rs.groups or {}) do out.groups[i] = group_view(g, d) end
	out.complete = rs and rs.below == nil or false
	out.anchor = rs and rs.anchor
	local cs = player_data.log_counts
	out.counts = cs and cs.total
	out.counting = cs and cs.build ~= nil
	local ss = player_data.log_summary
	if ss then
		out.summary = { done = ss.below == nil, stations = ss.top_stations, scanned = ss.scanned, as_of = ss.as_of }
		out.summary.items = {}
		for i, e in ipairs(ss.top_items or {}) do
			out.summary.items[i] = { item = d.item_hash[e.item], n = e.n, sev = e.sev }
		end
	end
	local rows = {}
	local parent = refs[ROWS]
	-- What a row's link cells open, from the group shown at that position (rows are not held while dumping).
	local function target(i, cell)
		local g = rs and rs.groups[i]
		if not g then return {} end
		local k, id = cell_target(g, cell)
		return { kind = k, id = id }
	end
	local handler_tag = "__" .. script.mod_name .. "_handler"
	if parent and parent.valid and parent.visible then
		for i, row in ipairs(parent.children) do
			local c = row.children
			local station = c[5].children[2]
			rows[i] = {
				style = row.style.name,
				height = row.style.maximal_height,
				age = c[1].caption,
				age_tooltip = c[1].tooltip,
				age_style = c[1].style.name,
				dot = c[2].sprite,
				kind_sprite = c[3].sprite,
				train = c[4].caption,
				train_tags = target(i, "train"),
				station = station.caption,
				station_tags = target(i, "station"),
				station_handler = station.tags[handler_tag] ~= nil,
				item = target(i, "item").id,
				elem_tooltip = c[6].elem_tooltip,
				message = c[7].caption,
				count = c[8].caption,
			}
		end
	end
	out.rows = rows
	out.rows_style = parent and parent.valid and parent.style.name or nil
	out.keys = util.gui_state(player_data, ROWS).keys
	out.held = util.gui_state(player_data, ROWS).dirty == true
	out.header = refs.log_header.caption
	out.status = refs.log_status.caption
	out.empty = refs.log_empty_flow.visible and refs.log_empty.caption or nil
	out.sev_buttons = {}
	for sev = 1, 3 do
		local b = refs["log_sev_" .. sev]
		out.sev_buttons[sev] = { caption = b.caption, toggled = b.toggled }
	end
	out.subject_chip = refs.log_subject_chip.visible and refs.log_subject_chip.caption or nil
	out.seen = player_data.log_seen_seq
	out.summary_shown = refs.log_summary.visible
	return out
end)

dev.register_function("log_dump", function(pi)
	return dev.call("dump", pi, TAB)
end)

--- Keys present in `f` are applied (false clears): sev = {bool, bool, bool}, kind = kind name, group = group name,
--- train, subject = {kind, id}, window = 1..3, follow, summary. `quiet`: no render (so the next update is the one a
--- filter change costs).
dev.register_function("log_set_filter", function(pi, f, quiet)
	local player = game.get_player(pi)
	local player_data = storage.manager.players[pi]
	local filter = get_filter(player_data)
	f = f or {}
	if f.sev ~= nil then filter.sev = f.sev or { true, true, true } end
	if f.kind ~= nil then
		filter.group = nil
		filter.kind = nil
		for k, name in ipairs(DIAG_KIND_NAMES) do
			if name == f.kind then filter.kind = k end
		end
	end
	if f.group ~= nil then
		filter.kind = nil
		filter.group = nil
		for g, group in ipairs(model.GROUPS) do
			if group.name == f.group then filter.group = g end
		end
	end
	if f.train ~= nil then filter.train = f.train or nil end
	if f.subject ~= nil then filter.subject = f.subject or nil end
	if f.window ~= nil then filter.window = f.window or model.DEFAULT_WINDOW end
	if f.follow ~= nil then filter.follow = f.follow end
	if f.summary ~= nil then
		filter.summary = f.summary
		player_data.log_summary = nil
	end
	log_tab.restore_widgets(player_data)
	if player and player_data.is_manager_open and not quiet then util.rerender(player, player_data) end
	return filter
end)

--- An export with the Log's filter, written at once (the GUI's runs in chunks); returns the path and the rows written.
dev.register_function("log_export", function(pi)
	local player = game.get_player(pi)
	local player_data = storage.manager.players[pi]
	local d = storage.diag
	if not (player and d) then return nil end
	local path = diag.export(player.connected and pi or 0, model.export_filter(compiled(player_data, d)))
	local job = d.export_jobs[#d.export_jobs]
	while d.export_jobs[1] do diag.export_step() end
	return { path = path, rows = job and job.rows }
end)

--- Times every chunk of an unfiltered export written now (budget measurement); returns one LocalisedString per chunk.
dev.register_function("log_export_bench", function(pi)
	local d = storage.diag
	if not d then return nil end
	diag.export(0, nil)
	local job = d.export_jobs[#d.export_jobs]
	local out = {}
	while d.export_jobs[1] do
		local before = job.rows
		local p = game.create_profiler()
		diag.export_step()
		p.stop()
		out[#out + 1] = { "", #out + 1, ": ", job.rows - before, " rows ", p }
	end
	return out
end)

--- One Log render of player `pi` timed by phase: counts, the rows model, writing the rows, the rest; plus the rows
--- written.
dev.register_function("log_profile", function(pi)
	local player_data = storage.manager.players[pi]
	prof = { written = 0 }
	for _, k in ipairs({ "counts", "rows", "render", "rest" }) do prof[k] = game.create_profiler(true) end
	local total = game.create_profiler()
	log_tab.build(storage, player_data)
	total.stop()
	local p = prof
	prof = nil
	return { "", "total ", total, " | counts ", p.counts, " | rows ", p.rows, " | render ", p.render, " | rest ", p.rest,
		" | rows written ", p.written }
end)

--- Prints the row holding `seq` to player `pi` as the Print button does; returns the printed LocalisedString.
dev.register_function("log_print", function(pi, seq)
	local player = game.get_player(pi)
	local player_data = storage.manager.players[pi]
	return log_tab.print_row(player, player_data, seq)
end)

--- The Log's export filter and compiled filter, for oracles.
dev.register_function("log_filter_state", function(pi)
	local player_data = storage.manager.players[pi]
	local d = storage.diag
	if not d then return nil end
	local cf = compiled(player_data, d)
	local st2 = {}
	for kind in pairs(diag.STATION2_IS_STATION) do st2[DIAG_KIND_NAMES[kind]] = true end
	return { min_tick = cf.min_tick, export = model.export_filter(cf), limit = row_limit(player_data),
		station2_kinds = st2, item = player_data.search_item, now = game.tick }
end)

return log_tab
