-- Problems tab (PLAN3 §4.7, §4.12, §4.13): every finding of the setup lint's last pass and of the last world scan,
-- read only, grouped by check in whole 32 px rows, with an acknowledge button per (subject, check). Visible only
-- while the lint job has a result. The Stations Setup chip, the Overview's misconfigured line and this tab count the
-- same pass (lint commits its masks and findings together).

local gui = require("__flib__.gui")
local format = require("__flib__.format")

local util = require("scripts.gui.util")
local collector = require("scripts.gui.collector")
local dev = require("scripts.gui.dev")
local diag = require("scripts.diag")
local lint = require("scripts.lint")
local pm = require("scripts.gui.problems-model")
local templates = require("scripts.gui.templates")

--- @class PlayerData
--- @field problems_filter {sev: {[int]: boolean}, acked: boolean?}? severities shown and the acknowledged toggle
--- @field problems_widths {subject: int, fix: int}? stretching column widths for the current layout
--- @field problems_model {sig: string, built: int, m: ProblemsModel}? the grouped findings of the current pass
--- @field problems_badge int? errors on the tab's badge

local problems_tab = {}

local TAB = "problems_tab"
local ROWS = "problems_rows"
local HOUR = 216000
local DAY = 24 * HOUR
-- Logical px (PLAN3 §4.7); subject and fix share what the window leaves.
local W = { dot = 20, chip = 160, detail = 300, ack = 28 }
local ROW_PADDING = 4 + 10
local SPACING = 8
local FRAME_BORDER = 4
local CELLS = 6
-- The subject takes this share of the stretching width, the fix line the rest.
local SUBJECT_SHARE = 0.42
local NAME_ICONS = 3
local ICON_ROW = 3 * 22
local SEVERITIES = { DIAG_SEV_ERROR, DIAG_SEV_WARNING, DIAG_SEV_INFO }

--- @param player_data PlayerData
--- @return {sev: {[int]: boolean}, acked: boolean?}
local function filter_of(player_data)
	local f = player_data.problems_filter
	if not f then
		f = { sev = {} }
		player_data.problems_filter = f
	end
	return f
end

--- @return LintState?
local function lint_state()
	local manager = storage.manager
	return manager and manager.lint
end

--- True once the setup lint finished a pass or a world scan finished: the tab shows only then.
--- @return boolean
function problems_tab.has_result()
	local s = lint_state()
	return s ~= nil and (s.tick ~= nil or s.world ~= nil)
end

--- The grouped findings of the current pass and world scan, rebuilt only when either, or an acknowledgement, changed.
--- @param player_data PlayerData
--- @return ProblemsModel
--- @return int built counts the rebuilds, for the render sig
function problems_tab.model(player_data)
	local s = lint.state()
	local world = s.world
	local sig = s.pass .. ":" .. tostring(world and world.tick) .. ":" .. (s.ack_version or 0)
	local cache = player_data.problems_model
	local now = game.tick
	if cache and cache.sig == sig and not (cache.m.next_expiry and cache.m.next_expiry <= now) then
		return cache.m, cache.built
	end
	local lists = { s.findings }
	if world then lists[2] = world.findings end
	local m = pm.build(lists, lint.subject_key, function(key, check) return diag.is_acked("lint", key, check) end)
	-- A counter, not the tick: two rebuilds in one tick (two clicks) must still re-render.
	local built = (cache and cache.built or 0) + 1
	player_data.problems_model = { sig = sig, built = built, m = m }
	return m, built
end

-- ---------------------------------------------------------------- creation and layout

local function header_cell(caption, width, name)
	return {
		type = "label",
		name = name,
		style = "cybersyn_unserved_header",
		style_mods = { width = width },
		caption = caption,
	}
end

--- The subheader's right side, after the shared chip and progress note (templates.tab_header).
--- @return flib.GuiElemDef[]
function problems_tab.subheader_right()
	local defs = {
		{
			type = "sprite-button",
			name = "problems_scan_button",
			style = "tool_button",
			sprite = "utility/search",
			tooltip = { "cybersyn-gui.problems-scan-tooltip" },
			handler = { [defines.events.on_gui_click] = problems_tab.handle.problems_scan_click },
		},
		{ type = "label", name = "problems_scan_note", style = "cybersyn_subheader_note" },
		{ type = "empty-widget", style_mods = { width = 12 } },
	}
	for _, sev in ipairs(SEVERITIES) do
		defs[#defs + 1] = {
			type = "checkbox",
			name = "problems_sev_" .. sev,
			caption = { "cybersyn-gui.problems-sev-" .. DIAG_SEV_NAMES[sev], "0" },
			tooltip = { "cybersyn-gui.problems-sev-tooltip" },
			state = true,
			tags = { sev = sev },
			handler = { [defines.events.on_gui_checked_state_changed] = problems_tab.handle.problems_sev_changed },
		}
	end
	defs[#defs + 1] = { type = "empty-widget", style_mods = { width = 12 } }
	defs[#defs + 1] = {
		type = "checkbox",
		name = "problems_show_acked",
		caption = { "cybersyn-gui.problems-show-acked", "0" },
		tooltip = { "cybersyn-gui.problems-show-acked-tooltip" },
		state = false,
		handler = { [defines.events.on_gui_checked_state_changed] = problems_tab.handle.problems_show_acked },
	}
	return defs
end

function problems_tab.create()
	return {
		tab = {
			name = "manager_problems_tab",
			type = "tab",
			caption = { "cybersyn-gui.problems" },
			visible = false,
		},
		content = {
			name = "manager_problems_content_frame",
			type = "flow",
			direction = "vertical",
			style = "cybersyn_overview_content",
			{
				type = "frame",
				name = "problems_frame",
				direction = "vertical",
				style = "cybersyn_problems_frame",
				{
					type = "flow",
					name = "problems_header",
					direction = "horizontal",
					style = "cybersyn_problems_header",
					header_cell("", W.dot),
					header_cell({ "cybersyn-gui.problems-col-check" }, W.chip),
					header_cell({ "cybersyn-gui.problems-col-subject" }, nil, "problems_h_subject"),
					header_cell({ "cybersyn-gui.problems-col-detail" }, W.detail),
					header_cell({ "cybersyn-gui.problems-col-fix" }, nil, "problems_h_fix"),
					header_cell("", W.ack),
				},
				{
					type = "flow",
					name = ROWS,
					direction = "vertical",
					style_mods = { vertical_spacing = 0, horizontally_stretchable = true },
				},
				{
					type = "flow",
					name = "problems_empty_flow",
					direction = "horizontal",
					style = "cybersyn_overview_empty_flow",
					visible = false,
					{
						type = "label",
						name = "problems_empty",
						style = "cybersyn_overview_empty_label",
						caption = { "cybersyn-gui.problems-empty" },
					},
				},
				{
					type = "frame",
					name = "problems_subfooter",
					style = "cybersyn_problems_subfooter",
					{ type = "label", name = "problems_footer", style = "cybersyn_subheader_note" },
					{ type = "empty-widget", style = "flib_horizontal_pusher" },
					templates.pager(TAB, util.handle.pager_click),
				},
			},
		},
	}
end

--- Column widths and the rows area from the window layout (whole rows, no scroll pane).
--- @param player_data PlayerData
--- @param layout ManagerLayout
function problems_tab.apply_layout(player_data, layout)
	local refs = player_data.refs
	local rows = layout.rows_by_tab[TAB] or 3
	local fixed = W.dot + W.chip + W.detail + W.ack
	local stretch = layout.content_width - FRAME_BORDER - ROW_PADDING - (CELLS - 1) * SPACING - fixed
	local subject = math.floor(stretch * SUBJECT_SHARE)
	local widths = { subject = subject, fix = stretch - subject }
	local h_subject, h_fix = refs.problems_h_subject, refs.problems_h_fix
	if h_subject and h_subject.valid then h_subject.style.width = widths.subject end
	if h_fix and h_fix.valid then h_fix.style.width = widths.fix end
	local body = refs[ROWS]
	if body and body.valid then body.style.height = rows * 32 end
	local empty = refs.problems_empty_flow
	if empty and empty.valid then empty.style.height = rows * 32 end
	local old = player_data.problems_widths
	player_data.problems_widths = widths
	if not old or old.subject ~= widths.subject or old.fix ~= widths.fix then
		if body and body.valid then body.clear() end
		local state = util.gui_state(player_data, ROWS)
		state.keys, state.sigs, state.render_sig, state.contents = nil, nil, nil, nil
	end
end

-- ---------------------------------------------------------------- cells

-- Name parts of a stop the snapshot does not hold (depots, refuelers, unregistered stops): a pure function of the
-- name, so a cache that differs between Lua states cannot desync anything.
local parsed_cache = {}

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

--- @class ProblemsSubject
--- @field kind string? link kind for util.handle_link_click; nil when the subject is gone
--- @field id uint?
--- @field text LocalisedString
--- @field name string plain text for the sig
--- @field icons {sprite: string, quality: string?}[]

--- @param name string
--- @param parts RichNameParts?
--- @return {sprite: string, quality: string?}[]
--- @return string
local function name_icons(name, parts)
	local icons = {}
	local lead = parts and parts.lead
	if lead then
		for i = 1, math.min(#lead, NAME_ICONS) do
			icons[i] = { sprite = lead[i], quality = parts.lead_quality and parts.lead_quality[i] or nil }
		end
	end
	local text = parts and parts.text
	if text == nil or text == "" then text = name end
	return icons, text
end

local KIND_OF = {
	[LINT_SUBJECT_STATION] = "station",
	[LINT_SUBJECT_DEPOT] = "depot",
	[LINT_SUBJECT_REFUELER] = "refueler",
}

--- What a finding is about, as a link cell shows it.
--- @param f LintFinding
--- @param snapshot Snapshot
--- @return ProblemsSubject
local function subject_of(f, snapshot)
	local subject, id = f.subject, f.id
	if subject == LINT_SUBJECT_TRAIN then
		local train = storage.trains[id]
		return { kind = train and "train" or nil, id = id, text = { "cybersyn-gui.problems-train", tostring(id) },
			name = "t" .. id, icons = { { sprite = "item/locomotive" } } }
	end
	if subject == LINT_SUBJECT_COMBINATOR then
		local e = f.entity
		if e and e.valid then
			local pos = e.position
			return { kind = "entity", id = id, name = "c" .. id, icons = { { sprite = "item/" .. COMBINATOR_NAME } },
				text = { "cybersyn-gui.problems-combinator", tostring(math.floor(pos.x)), tostring(math.floor(pos.y)) } }
		end
		return { id = id, name = "c" .. id, icons = {}, text = { "cybersyn-gui.problems-gone" } }
	end
	local kind = KIND_OF[subject]
	if subject == LINT_SUBJECT_STOP then
		kind = storage.stations[id] and "station" or storage.depots[id] and "depot" or storage.refuelers[id] and "refueler"
			or "entity"
	end
	local st = kind == "station" and snapshot.stations[id] or nil
	if st then
		local icons, text = name_icons(st.name, st.name_parts)
		return { kind = kind, id = id, text = text, name = st.name, icons = icons }
	end
	local stop
	if kind == "entity" then
		stop = f.entity
	else
		local record = (kind == "station" and storage.stations or kind == "depot" and storage.depots or storage.refuelers)[id]
		stop = record and record.entity_stop
	end
	if not (stop and stop.valid) then
		return { id = id, name = "-" .. id, icons = {}, text = { "cybersyn-gui.problems-gone" } }
	end
	local name = stop.backer_name
	local icons, text = name_icons(name, parse_name(name))
	return { kind = kind, id = id, text = text, name = name, icons = icons }
end

--- @param hash string?
--- @return string
local function item_icon(hash)
	if not hash then return "" end
	local name, quality = unhash_signal(hash)
	local kind = prototypes.fluid[name] and "fluid" or "item"
	if quality and quality ~= "normal" then
		return "[" .. kind .. "=" .. name .. ",quality=" .. quality .. "]"
	end
	return "[" .. kind .. "=" .. name .. "]"
end

--- @param name string?
--- @return string
local function network_icon(name)
	if not name then return "?" end
	if prototypes.virtual_signal[name] then return "[virtual-signal=" .. name .. "]" end
	if prototypes.item[name] then return "[item=" .. name .. "]" end
	if prototypes.fluid[name] then return "[fluid=" .. name .. "]" end
	return name
end

--- @param hash string?
--- @return boolean
local function is_fluid(hash)
	if not hash then return false end
	local name = unhash_signal(hash)
	return prototypes.fluid[name] ~= nil
end

local ENV = { item = item_icon, network = network_icon, is_fluid = is_fluid, duration = util.format_duration }
problems_tab.ENV = ENV

-- Captions and tooltips that depend only on the check (and whether the subject is a station): built once per Lua
-- state. A pure function of its key, so a cache that differs between states cannot desync anything.
local check_text = {}

--- @param check int
--- @param station boolean
--- @return {caption: LocalisedString, chip: LocalisedString, fix: LocalisedString, tooltip: LocalisedString, linked: LocalisedString}
local function texts(check, station)
	local key = station and check or -check
	local t = check_text[key]
	if t then return t end
	local code = station and lint.predicts(check, "r") or nil
	local predicts = code and { "cybersyn-gui.problems-predicts", { "cybersyn-diag.chip-" .. REASON_KEYS[code] } }
		or { "cybersyn-gui.problems-predicts-none" }
	local tooltip = { "cybersyn-gui.problems-chip-tooltip", pm.caption(check), predicts, pm.fix(check),
		{ "cybersyn-diag.sev-" .. DIAG_SEV_NAMES[LINT_SEVERITY[check] or DIAG_SEV_WARNING] } }
	t = {
		caption = pm.caption(check),
		chip = pm.chip(check),
		fix = pm.fix(check),
		tooltip = tooltip,
		linked = { "", tooltip, "\n", util.LINK_FOOTER },
	}
	check_text[key] = t
	return t
end

--- @param row ProblemRow
--- @param now uint
--- @return LocalisedString
local function ack_tooltip(row, now)
	local a = row.ack
	if not a then return { "cybersyn-gui.problems-ack-tooltip" } end
	local who = a.player_index and game.get_player(a.player_index)
	local until_text = a.until_tick and util.format_duration(a.until_tick - now) or nil
	return { "cybersyn-gui.unserved-ack-tooltip-acked", who and who.name or "-",
		until_text and { "cybersyn-gui.unserved-ack-for", until_text } or { "cybersyn-gui.problems-ack-until-clear" } }
end

-- Row cells carry their handlers in the tags they are created with (flib's format, built once): flib's handler
-- field would read and rewrite every element's tags once more, which was most of the cost of building a page.
local HANDLER_TAG, LINK_HANDLERS, ACK_HANDLERS

--- Tags of an interactive cell: a link to `kind`/`id` (or the acknowledge button with `ack`), in the rows' hover hold.
--- @return Tags
local function cell_tags(kind, id, ack)
	if not HANDLER_TAG then
		local link = gui.format_handlers(util.with_hover({ [defines.events.on_gui_click] = util.handle.link_click }))
		HANDLER_TAG, LINK_HANDLERS = next(link)
		ACK_HANDLERS = gui.format_handlers(util.with_hover({
			[defines.events.on_gui_click] = problems_tab.handle.problems_ack_click }))[HANDLER_TAG]
	end
	local tags = ack or { kind = kind, id = id }
	tags.hover_scope = ROWS
	tags[HANDLER_TAG] = ack and ACK_HANDLERS or LINK_HANDLERS
	return tags
end

local valid_sprite = {}

--- @param sprite string
--- @return string
local function sprite_or_unknown(sprite)
	local ok = valid_sprite[sprite]
	if ok == nil then
		ok = helpers.is_valid_sprite_path(sprite)
		valid_sprite[sprite] = ok
	end
	return ok and sprite or "utility/questionmark"
end

--- The six cells of a finding row.
--- @param line ProblemsLine
--- @param ctx {snapshot: Snapshot, widths: {subject: int, fix: int}, now: uint}
--- @param subject ProblemsSubject
--- @return flib.GuiElemDef[]
local function finding_cells(line, ctx, subject)
	local row = line.row
	local f = row.f
	local acked = line.acked
	local kind, id = subject.kind, subject.id
	local t = texts(f.check, f.subject == LINT_SUBJECT_STATION)
	local detail = pm.detail(f, ENV)
	local subject_tip = kind and { "", "[font=default-semibold]", subject.text, "[/font]\n", util.LINK_FOOTER }
		or subject.text
	local icons = {
		type = "flow",
		direction = "horizontal",
		style = "cybersyn_unserved_icon_flow",
	}
	for i, icon in ipairs(subject.icons) do
		icons[i] = {
			type = "sprite-button",
			style = "cybersyn_name_icon",
			sprite = sprite_or_unknown(icon.sprite),
			quality = icon.quality,
			tooltip = subject_tip,
			raise_hover_events = true,
			tags = cell_tags(kind, id),
		}
	end
	return {
		{ type = "sprite", style = "cybersyn_problems_dot", sprite = acked and pm.ACKED_DOT or pm.DOT[row.sev] },
		{
			type = "button",
			style = acked and "cybersyn_chip_grey" or pm.CHIP_STYLE[row.sev],
			style_mods = { width = W.chip },
			caption = t.chip,
			tooltip = kind and t.linked or t.tooltip,
			raise_hover_events = true,
			tags = cell_tags(kind, id),
			mouse_button_filter = { "left" },
		},
		{
			type = "flow",
			direction = "horizontal",
			style = "cybersyn_unserved_cell_flow",
			style_mods = { width = ctx.widths.subject },
			icons,
			{
				type = "button",
				style = acked and "cybersyn_link_button_acked" or "cybersyn_link_button",
				style_mods = { maximal_width = ctx.widths.subject - ICON_ROW - 4 },
				caption = subject.text,
				enabled = kind ~= nil,
				tooltip = subject_tip,
				raise_hover_events = true,
				tags = cell_tags(kind, id),
				mouse_button_filter = { "left" },
			},
		},
		{
			type = "label",
			style = acked and "cybersyn_problems_detail_acked" or "cybersyn_problems_detail",
			style_mods = { width = W.detail },
			caption = detail,
			tooltip = detail,
			raise_hover_events = true,
			tags = cell_tags(kind, id),
		},
		{
			type = "label",
			style = "cybersyn_problems_fix",
			style_mods = { width = ctx.widths.fix },
			caption = t.fix,
			raise_hover_events = true,
			tags = cell_tags(kind, id),
		},
		{
			type = "sprite-button",
			style = "cybersyn_unserved_ack",
			sprite = "utility/check_mark",
			toggled = acked == true,
			tooltip = ack_tooltip(row, ctx.now),
			raise_hover_events = true,
			tags = cell_tags(nil, nil, { ack_key = row.ack_key, check = f.check }),
		},
	}
end

--- @param line ProblemsLine
--- @return LocalisedString
local function group_caption(line)
	local g = line.group
	local key = line.cont and "cybersyn-gui.problems-group-continued" or "cybersyn-gui.problems-group"
	return { key, pm.caption(g.check), format.number(line.shown) }
end

--- @param line ProblemsLine
--- @return LocalisedString
local function group_note(line)
	if (line.hidden_acked or 0) > 0 then
		return { "cybersyn-gui.problems-group-acked", format.number(line.hidden_acked) }
	end
	return ""
end

--- One sync_children entry per line of the page. A finding row's sig holds everything its cells show, so an
--- unchanged row costs nothing and a changed one is rebuilt in place.
--- @param lines ProblemsLine[]
--- @param ctx table
--- @return table[]
local function entries_of(lines, ctx)
	local entries = {}
	for i, line in ipairs(lines) do
		if line.kind == "group" then
			local g = line.group
			entries[i] = {
				key = "g" .. g.check .. (line.cont and "c" or ""),
				sig = line.shown .. ":" .. line.hidden_acked,
				build = function()
					return {
						type = "frame",
						style = "cybersyn_problems_group_row",
						direction = "horizontal",
						tags = { k = "g" .. g.check },
						{ type = "sprite", style = "cybersyn_problems_dot", sprite = pm.DOT[g.sev] },
						{ type = "label", style = "cybersyn_problems_group_caption", caption = group_caption(line) },
						{ type = "label", style = "cybersyn_subheader_note", caption = group_note(line) },
					}
				end,
				update = function(elem)
					local c = elem.children
					c[2].caption = group_caption(line)
					c[3].caption = group_note(line)
				end,
			}
		else
			local row = line.row
			local f = row.f
			local subject = subject_of(f, ctx.snapshot)
			local odd = i % 2 == 1
			local a = row.ack
			local style = odd and "cybersyn_problems_row_odd" or "cybersyn_problems_row"
			local content = table.concat({ line.acked and "a" or "", subject.name, tostring(subject.kind),
				pm.detail_sig(f), a and tostring(a.until_tick) or "", a and tostring(a.player_index) or "",
				a and a.until_tick and math.floor((a.until_tick - ctx.now) / 3600) or "" }, "|")
			local contents = ctx.contents
			entries[i] = {
				key = row.key,
				sig = (odd and "o" or "e") .. content,
				build = function()
					contents[row.key] = content
					local def = {
						type = "frame",
						style = style,
						direction = "horizontal",
						tags = { k = row.key },
					}
					for c, cell in ipairs(finding_cells(line, ctx, subject)) do def[c] = cell end
					return def
				end,
				-- A row that only moved needs its stripe; one whose content changed gets new cells.
				update = function(elem)
					if elem.style.name ~= style then elem.style = style end
					if contents[row.key] == content then return end
					contents[row.key] = content
					elem.clear()
					for _, cell in ipairs(finding_cells(line, ctx, subject)) do gui.add(elem, cell) end
				end,
			}
		end
	end
	return entries
end

-- ---------------------------------------------------------------- render

--- @param elem LuaGuiElement?
--- @param caption LocalisedString
local function set_caption(elem, caption)
	if elem and elem.valid then elem.caption = caption end
end

--- The scan note: progress while a world scan runs, then its age.
--- @param refs table
--- @param s LintState
local function render_scan(refs, s)
	local progress = lint.world_progress()
	local button = refs.problems_scan_button
	if button and button.valid and button.enabled ~= (progress == nil) then button.enabled = progress == nil end
	local note = refs.problems_scan_note
	if not (note and note.valid) then return end
	if progress then
		note.caption = { "cybersyn-gui.problems-scanning", tostring(math.floor(progress * 100)) }
	elseif s.world then
		note.caption = { "cybersyn-gui.problems-scanned-ago", util.format_duration(game.tick - s.world.tick) }
	else
		note.caption = { "cybersyn-gui.problems-never-scanned" }
	end
end

--- Severity and acknowledged toggles: their counts and states.
local function render_toggles(refs, m, filter)
	for _, sev in ipairs(SEVERITIES) do
		local box = refs["problems_sev_" .. sev]
		if box and box.valid then
			box.caption = { "cybersyn-gui.problems-sev-" .. DIAG_SEV_NAMES[sev], format.number(m.open[sev]) }
			local on = filter.sev[sev] ~= false
			if box.state ~= on then box.state = on end
		end
	end
	local acked = refs.problems_show_acked
	if acked and acked.valid then
		acked.caption = { "cybersyn-gui.problems-show-acked", format.number(m.acked) }
		local on = filter.acked == true
		if acked.state ~= on then acked.state = on end
	end
end

--- @param refs table
--- @param pg ProblemsPage
local function render_pager(refs, pg)
	local pager = refs[TAB .. "_pager"]
	if not (pager and pager.valid) then return end
	local multi = pg.pages > 1
	if pager.visible ~= multi then pager.visible = multi end
	if not multi then return end
	refs[TAB .. "_pager_label"].caption = { "cybersyn-gui.pager-range", format.number(pg.first), format.number(pg.last),
		format.number(pg.shown) }
	local back, forward = pg.page > 1, pg.page < pg.pages
	refs[TAB .. "_pager_first"].enabled = back
	refs[TAB .. "_pager_prev"].enabled = back
	refs[TAB .. "_pager_next"].enabled = forward
	refs[TAB .. "_pager_last"].enabled = forward
end

--- The current page of the player's view.
--- @param player_data PlayerData
--- @param m ProblemsModel
--- @return ProblemsPage
--- @return int rows
local function current_page(player_data, m)
	local layout = player_data.layout
	local rows = layout and layout.rows_by_tab[TAB] or 3
	rows = math.min(rows, util.page_size(player_data))
	player_data.page = player_data.page or {}
	local pg = pm.page(m, filter_of(player_data), rows, player_data.page[TAB])
	player_data.page[TAB] = pg.page
	return pg, rows
end

--- @param map_data MapData
--- @param player_data PlayerData
function problems_tab.build(map_data, player_data)
	local refs = player_data.refs
	local body = refs[ROWS]
	if not (body and body.valid) then return end
	local widths = player_data.problems_widths
	if not widths then return end
	local s = lint.state()
	render_scan(refs, s)
	local m, built = problems_tab.model(player_data)
	local filter = filter_of(player_data)
	local pg, rows = current_page(player_data, m)
	local now = game.tick
	local fsig = (filter.sev[1] == false and "e" or "") .. (filter.sev[2] == false and "w" or "") ..
		(filter.sev[3] == false and "i" or "") .. (filter.acked and "a" or "")
	local render_sig = table.concat({ built, fsig, rows, pg.page, widths.subject, widths.fix,
		m.acked > 0 and filter.acked and math.floor(now / 3600) or "" }, "|")
	local pass_age = s.tick and util.format_duration(now - s.tick) or "-"
	set_caption(refs.problems_footer, { "cybersyn-gui.problems-footer", format.number(m.total), format.number(m.acked),
		pass_age })
	local state = util.gui_state(player_data, ROWS)
	if state.render_sig == render_sig and not state.dirty then return end

	render_toggles(refs, m, filter)
	render_pager(refs, pg)
	local snapshot = collector.get()
	if not (state.keys and state.contents) then state.contents = {} end
	local ctx = { snapshot = snapshot, widths = widths, now = now, contents = state.contents }
	-- Movable: a finding that appears or clears moves the rows after it instead of rebuilding them.
	local result = util.sync_children(body, entries_of(pg.lines, ctx), state, util.hold_active(player_data, ROWS), true)
	if result == "rebuilt" then
		local keep = {}
		for _, key in ipairs(state.keys) do keep[key] = state.contents[key] end
		state.contents = keep
	end
	if result ~= "held" then state.render_sig = render_sig end

	local empty_flow = refs.problems_empty_flow
	local show_empty = #pg.lines == 0
	if empty_flow.visible ~= show_empty then empty_flow.visible = show_empty end
	if body.visible == show_empty then body.visible = not show_empty end
	if show_empty then
		set_caption(refs.problems_empty, m.total == 0 and { "cybersyn-gui.problems-empty" }
			or { "cybersyn-gui.problems-empty-filtered" })
	end
end

--- Tab visibility and badge, on every render whichever tab is selected (PLAN3 §4.6: errors not acknowledged).
--- @param player_data PlayerData
function problems_tab.refresh_tab(player_data)
	local tab = player_data.refs.manager_problems_tab
	if not (tab and tab.valid) then return end
	local has = problems_tab.has_result()
	if tab.visible ~= has then tab.visible = has end
	if not has then
		if player_data.selected_tab == TAB then util.select_tab(player_data, "overview_tab") end
		player_data.problems_badge = nil
		return
	end
	local m = problems_tab.model(player_data)
	local n = m.badge
	if player_data.problems_badge ~= n then
		player_data.problems_badge = n
		tab.badge_text = n > 0 and tostring(n) or ""
		tab.tooltip = n > 0 and { "cybersyn-gui.problems-badge-tooltip", tostring(n) } or ""
	end
end

-- ---------------------------------------------------------------- handlers

problems_tab.handle = {}

--- @param e {player_index: uint}
function problems_tab.wrapper(e, handler)
	local player = game.get_player(e.player_index)
	if not player then return end
	local player_data = storage.manager.players[e.player_index]
	if not player_data then return end
	handler(player, player_data, player_data.refs, e)
end

--- Display state only, so any player may acknowledge (PLAN3 §4.13). Bumping the version makes every open window
--- rebuild its model, not only this player's.
local function acks_changed()
	local s = lint.state()
	s.ack_version = (s.ack_version or 0) + 1
end

--- Acknowledge a finding: click = 24 h, shift = 1 h, control = until it clears; a click on an acknowledged one ends it.
--- @param e EventData.on_gui_click
function problems_tab.handle.problems_ack_click(player, player_data, refs, e)
	local tags = e.element.tags
	local key, check = tags.ack_key, tags.check
	if not (key and check) then return end
	if diag.is_acked("lint", key, check) then
		diag.unack("lint", key, check, player.index)
	else
		local until_tick
		if e.control then
			until_tick = nil
		elseif e.shift then
			until_tick = game.tick + HOUR
		else
			until_tick = game.tick + DAY
		end
		diag.ack("lint", key, check, player.index, until_tick)
	end
	acks_changed()
	util.rerender(player, player_data)
end

--- @param e EventData.on_gui_click
function problems_tab.handle.problems_scan_click(player, player_data, refs, e)
	if not lint.scan_world(player.index, true) then
		util.error_flying_text(player, { "cybersyn-gui.problems-scan-running" })
	end
	util.rerender(player, player_data)
end

--- @param e EventData.on_gui_checked_state_changed
function problems_tab.handle.problems_sev_changed(player, player_data, refs, e)
	local sev = e.element.tags.sev
	if not sev then return end
	filter_of(player_data).sev[sev] = e.element.state
	util.reset_page(player_data, TAB)
	util.rerender(player, player_data)
end

--- @param e EventData.on_gui_checked_state_changed
function problems_tab.handle.problems_show_acked(player, player_data, refs, e)
	filter_of(player_data).acked = e.element.state or nil
	util.reset_page(player_data, TAB)
	util.rerender(player, player_data)
end

gui.add_handlers(problems_tab.handle, problems_tab.wrapper)

-- ---------------------------------------------------------------- dev (PLAN3 §6)

--- Rendered rows (group and finding rows) for dev.rows.
--- @param player_data PlayerData
--- @return int
function problems_tab.rendered_rows(player_data)
	local body = player_data.refs[ROWS]
	if not (body and body.valid and body.visible) then return 0 end
	return #body.children
end

dev.register_rows(TAB, problems_tab.rendered_rows)

--- @param row ProblemRow
--- @param acked boolean
local function row_view(row, acked)
	local f = row.f
	return {
		key = row.key,
		ack_key = row.ack_key,
		check = LINT_NAMES[f.check],
		sev = DIAG_SEV_NAMES[row.sev],
		subject = LINT_SUBJECT_NAMES[f.subject],
		id = f.id,
		a = f.a,
		b = f.b,
		network = f.network,
		item = f.item,
		message = f.message,
		acked = acked,
		until_tick = row.ack and row.ack.until_tick or nil,
		caption = pm.caption(f.check),
		chip = pm.chip(f.check),
		detail = pm.detail(f, ENV),
		fix = pm.fix(f.check),
	}
end

--- What the tab shows for player `pi`: visibility and badge, counts, the current page's lines as the model has
--- them and the rows as rendered; with `all`, every finding of the model too.
local function dump(player_data, all)
	local refs = player_data.refs
	local tab = refs.manager_problems_tab
	local s = lint.state()
	local m = problems_tab.model(player_data)
	local filter = filter_of(player_data)
	local pg, rows = current_page(player_data, m)
	local lines = {}
	for i, line in ipairs(pg.lines) do
		if line.kind == "group" then
			lines[i] = { kind = "group", check = LINT_NAMES[line.group.check], cont = line.cont, shown = line.shown,
				hidden_acked = line.hidden_acked }
		else
			local v = row_view(line.row, line.acked)
			v.kind = "row"
			lines[i] = v
		end
	end
	local groups = {}
	for i, g in ipairs(m.groups) do
		groups[i] = { check = LINT_NAMES[g.check], sev = DIAG_SEV_NAMES[g.sev], open = #g.open, acked = #g.acked }
	end
	local rendered = {}
	local body = refs[ROWS]
	if body and body.valid and body.visible then
		for i, child in ipairs(body.children) do
			local c = child.children
			if child.style.name == "cybersyn_problems_group_row" then
				rendered[i] = { kind = "group", key = child.tags.k, caption = c[2].caption, note = c[3].caption }
			else
				local subject = c[3].children[2]
				rendered[i] = {
					kind = "row",
					key = child.tags.k,
					style = child.style.name,
					dot = c[1].sprite,
					chip = c[2].caption,
					chip_style = c[2].style.name,
					chip_tooltip = c[2].tooltip,
					subject = subject.caption,
					subject_kind = subject.tags.kind,
					subject_id = subject.tags.id,
					icons = #c[3].children[1].children,
					detail = c[4].caption,
					fix = c[5].caption,
					fix_style = c[5].style.name,
					acked = c[6].toggled,
					ack_tooltip = c[6].tooltip,
				}
			end
		end
	end
	local out = {
		visible = tab and tab.valid and tab.visible or false,
		badge = tab and tab.valid and tab.badge_text or nil,
		has_result = problems_tab.has_result(),
		pass = s.pass,
		lint_tick = s.tick,
		world_tick = s.world and s.world.tick or nil,
		scanning = lint.world_progress(),
		scan_note = refs.problems_scan_note and refs.problems_scan_note.caption or nil,
		scan_enabled = refs.problems_scan_button and refs.problems_scan_button.enabled,
		filter = { error = filter.sev[DIAG_SEV_ERROR] ~= false, warning = filter.sev[DIAG_SEV_WARNING] ~= false,
			info = filter.sev[DIAG_SEV_INFO] ~= false, acked = filter.acked == true },
		counts = { error = m.open[DIAG_SEV_ERROR], warning = m.open[DIAG_SEV_WARNING], info = m.open[DIAG_SEV_INFO],
			acked = m.acked, total = m.total, badge = m.badge },
		station_subjects = m.station_subjects,
		groups = groups,
		rows = rows,
		page = { page = pg.page, pages = pg.pages, first = pg.first, last = pg.last, shown = pg.shown },
		lines = lines,
		rendered = rendered,
		empty = refs.problems_empty_flow and refs.problems_empty_flow.visible and refs.problems_empty.caption or nil,
		footer = refs.problems_footer and refs.problems_footer.caption or nil,
	}
	if all then
		local list = {}
		for _, g in ipairs(m.groups) do
			for _, row in ipairs(g.open) do list[#list + 1] = row_view(row, false) end
			for _, row in ipairs(g.acked) do list[#list + 1] = row_view(row, true) end
		end
		out.all = list
	end
	return out
end

dev.register_dump(TAB, function(player_data) return dump(player_data, false) end)

--- @param pi uint
local function context(pi)
	local player = game.get_player(pi)
	if not player then error("no player " .. tostring(pi)) end
	local player_data = storage.manager.players[pi]
	if not player_data then error("no manager data for player " .. tostring(pi)) end
	return player, player_data
end

dev.add("problems_dump", function(pi, all)
	local _, player_data = context(pi)
	return dump(player_data, all)
end)

--- {sev = {error = bool, warning = bool, info = bool}, acked = bool}; a missing field keeps its value.
dev.add("problems_set_filter", function(pi, f)
	local player, player_data = context(pi)
	local filter = filter_of(player_data)
	if f.sev then
		for sev, name in ipairs(DIAG_SEV_NAMES) do
			if f.sev[name] ~= nil then filter.sev[sev] = f.sev[name] end
		end
	end
	if f.acked ~= nil then filter.acked = f.acked or nil end
	util.reset_page(player_data, TAB)
	util.rerender(player, player_data)
	return dump(player_data, false)
end)

--- The world scan for player `pi`, run to completion now (quiet: the tab shows the result).
dev.add("problems_scan", function(pi)
	local player, player_data = context(pi)
	lint.scan_world_now(pi, true)
	util.rerender(player, player_data)
	return dump(player_data, false)
end)

--- Acknowledges (subject key, check) as the tab's button would; `until_ticks` from now, nil = until it clears, false
--- = end the acknowledgement. `check` is a check name or index.
dev.add("problems_ack", function(pi, key, check, until_ticks)
	local player, player_data = context(pi)
	if type(check) == "string" then check = LINT_BY_NAME[check] end
	if not check then error("unknown lint check") end
	local ack
	if until_ticks == false then
		diag.unack("lint", key, check, pi)
	else
		ack = diag.ack("lint", key, check, pi, until_ticks and game.tick + until_ticks or nil)
	end
	acks_changed()
	util.rerender(player, player_data)
	return ack
end)

return problems_tab
