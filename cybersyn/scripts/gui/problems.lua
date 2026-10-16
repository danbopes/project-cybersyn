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

--- True once the setup lint finished a pass or a world scan finished: the tab lists findings only then.
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
	-- diag counts every change to the lint acknowledgements, whoever or whatever made it (a click in any window, the
	-- cap, an expiry, a removed station).
	local acks = storage.acks
	local ack_version = acks and acks.lint_version or 0
	local wtick = world and world.tick or -1
	-- Removed stops and combinators leave the world scan's findings at once (not at the next scan).
	local pruned = lint.prune_world() or 0
	local cache = player_data.problems_model
	local now = game.tick
	-- Compared field by field: a steady render allocates nothing here.
	local removed = s.removed or 0
	if cache and cache.pass == s.pass and cache.wtick == wtick and cache.acks == ack_version and cache.pruned == pruned
		and cache.removed == removed and not (cache.m.next_expiry and cache.m.next_expiry <= now) then
		return cache.m, cache.built
	end
	local lists = { s.findings }
	if world then lists[2] = world.findings end
	local m = pm.build(lists, lint.subject_key, function(key, check) return diag.is_acked("lint", key, check) end)
	-- A counter, not the tick: two rebuilds in one tick (two clicks) must still re-render.
	local built = (cache and cache.built or 0) + 1
	player_data.problems_model = { pass = s.pass, wtick = wtick, acks = ack_version, pruned = pruned, removed = removed,
		built = built, m = m }
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
			sprite = "utility/refresh",
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
	-- The render sig holds the widths: the next render writes them into the bound slots.
	player_data.problems_widths = widths
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
--- @field tip LocalisedString the full name (rich text) for the tooltip
--- @field name string plain text for the sig
--- @field icons {sprite: string, quality: string?}[] lead icons
--- @field tail {sprite: string, quality: string?}[]? icons after the text ("Requestor for [item]")

--- @param parts RichNameParts?
--- @param side "lead"|"tail"
--- @return {sprite: string, quality: string?}[]
local function side_icons(parts, side)
	local icons = {}
	local list = parts and parts[side]
	if list then
		local quality = parts[side .. "_quality"]
		for i = 1, math.min(#list, NAME_ICONS) do
			icons[i] = { sprite = list[i], quality = quality and quality[i] or nil }
		end
	end
	return icons
end

--- The name's icons before and after its text, and the text, as the Stations tab's name cell shows them.
--- @param name string
--- @param parts RichNameParts?
--- @return {sprite: string, quality: string?}[] lead
--- @return string text
--- @return {sprite: string, quality: string?}[] tail
local function name_icons(name, parts)
	local text = parts and parts.text
	if text == nil or text == "" then text = name end
	return side_icons(parts, "lead"), text, side_icons(parts, "tail")
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
		local text = { "cybersyn-gui.problems-train", tostring(id) }
		return { kind = train and "train" or nil, id = id, text = text, tip = text, name = "t" .. id,
			icons = { { sprite = "item/locomotive" } } }
	end
	if subject == LINT_SUBJECT_COMBINATOR then
		local e = f.entity
		if e and e.valid then
			local pos = e.position
			local text = { "cybersyn-gui.problems-combinator", tostring(math.floor(pos.x)), tostring(math.floor(pos.y)) }
			return { kind = "entity", id = id, name = "c" .. id, icons = { { sprite = "item/" .. COMBINATOR_NAME } },
				text = text, tip = text }
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
		local icons, text, tail = name_icons(st.name, st.name_parts)
		return { kind = kind, id = id, text = text, tip = st.name, name = st.name, icons = icons, tail = tail }
	end
	local stop
	if kind == "entity" then
		stop = f.entity
	else
		local record = (kind == "station" and storage.stations or kind == "depot" and storage.depots or storage.refuelers)[id]
		stop = record and record.entity_stop
	end
	if not (stop and stop.valid) then
		local gone = { "cybersyn-gui.problems-gone" }
		return { id = id, name = "-" .. id, icons = {}, text = gone, tip = gone }
	end
	local name = stop.backer_name
	local icons, text, tail = name_icons(name, parse_name(name))
	return { kind = kind, id = id, text = text, tip = name, name = name, icons = icons, tail = tail }
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

local ENV = { item = item_icon, network = network_icon, is_fluid = is_fluid, duration = util.short_duration }
problems_tab.ENV = ENV

-- Captions and tooltips that depend only on the check, the side of the station it predicts for and whether the
-- subject links anywhere: built once per Lua state. A pure function of its key, so a cache that differs between
-- states cannot desync anything.
local check_text = {}

--- @param check int
--- @param role "r"|"p"|nil nil when the subject is not a station
--- @return {key: string, caption: LocalisedString, chip: LocalisedString, fix: LocalisedString, tooltip: LocalisedString, linked: LocalisedString}
local function texts(check, role)
	local key = check .. (role or "-")
	local t = check_text[key]
	if t then return t end
	local code = role and lint.predicts(check, role) or nil
	local predicts = code and { "cybersyn-gui.problems-predicts", { "cybersyn-diag.chip-" .. REASON_KEYS[code] } }
		or { "cybersyn-gui.problems-predicts-none" }
	local tooltip = { "cybersyn-gui.problems-chip-tooltip", pm.caption(check), predicts, pm.fix(check),
		{ "cybersyn-diag.sev-" .. DIAG_SEV_NAMES[LINT_SEVERITY[check] or DIAG_SEV_WARNING] } }
	t = {
		key = key,
		caption = pm.caption(check),
		chip = pm.chip(check),
		fix = pm.fix(check),
		tooltip = tooltip,
		linked = { "", tooltip, "\n", util.LINK_FOOTER },
	}
	check_text[key] = t
	return t
end

--- The side of a station a finding predicts the dispatcher's reason for: the provider's when the finding is about
--- what the stop provides (an item on its way in) or the stop only provides.
--- @param f LintFinding
--- @param snapshot Snapshot
--- @return "r"|"p"|nil
local function role_of(f, snapshot)
	if f.subject ~= LINT_SUBJECT_STATION then return nil end
	if f.check == LINT_SAME_ITEM then return f.b == 1 and "p" or "r" end
	local st = snapshot.stations[f.id]
	if st and st.is_p and not st.is_r then return "p" end
	return "r"
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

-- ---------------------------------------------------------------- slots
--
-- The rows area is a pool of slot frames that are never destroyed: each holds the cells of a finding row and of a
-- group row and shows one set. A render binds the page's lines to slots by key (a line that moved swaps its slot into
-- place, a new line takes a slot whose line left the page) and writes only the cells whose content changed, so a page
-- flip or a filter change rewrites captions instead of creating elements. Slots beyond the page are hidden. While
-- another tab shows, the pool fills a few slots per render and then binds the page a few lines per render
-- (problems_tab.prewarm, problems_tab.prebind), so the tab's first show neither creates nor writes anything. What each
-- slot's cells show is cached in its storage record (the writes must be the same on every peer) and the slot's link
-- and acknowledge targets live there too: the cells' tags never change.

-- Child indices of a slot frame.
local C_DOT, C_CHIP, C_SUBJECT, C_DETAIL, C_FIX, C_ACK, C_GROUP, C_NOTE = 1, 2, 3, 4, 5, 6, 7, 8
local ROW_STYLE = { [true] = "cybersyn_problems_row_odd", [false] = "cybersyn_problems_row" }
local GROUP_STYLE = "cybersyn_problems_group_row"
-- Slots created per update while the pool is short of the page, then lines bound per update until the page is.
local PREWARM = 6
local PREBIND = 6
-- Slots created at most per render of the tab itself (a window rebuilt while the tab was selected).
local CREATE_PER_RENDER = 12

--- @class ProblemsSlot
--- @field key string? the line bound to it; nil while hidden
--- @field kind "r"|"g" which cell set shows
--- @field vis boolean
--- @field sig string? everything the bound line shows; equal = no writes
--- @field style string? frame style
--- @field dot string?
--- @field chip_style string?
--- @field chip string?
--- @field w string? the widths written
--- @field icons string?
--- @field n_icons int
--- @field link_style string?
--- @field subject string?
--- @field detail_style string?
--- @field detail string?
--- @field fix string?
--- @field ack string?
--- @field group string?
--- @field lk string? link kind of the bound finding
--- @field lid (uint|string)? link id
--- @field ak int? acknowledgement subject key
--- @field ck int? check

-- Static cell tags in flib's handler format, built once (handlers are registered at load).
local LINK_TAGS, ACK_TAGS

local function cell_tags()
	if not LINK_TAGS then
		local link = gui.format_handlers(util.with_hover({
			[defines.events.on_gui_click] = problems_tab.handle.problems_link_click }))
		local tag, handlers = next(link)
		LINK_TAGS = { hover_scope = ROWS, [tag] = handlers }
		ACK_TAGS = { hover_scope = ROWS, [tag] = gui.format_handlers(util.with_hover({
			[defines.events.on_gui_click] = problems_tab.handle.problems_ack_click }))[tag] }
	end
	return LINK_TAGS, ACK_TAGS
end

--- @param widths {subject: int, fix: int}
--- @return string
local function widths_sig(widths)
	return widths.subject .. ":" .. widths.fix
end

--- A hidden slot frame with both cell sets, at `index` (appended when nil), striped and sized for that position and
--- the current widths so that binding a line to it in place writes only the line's own content.
--- @param body LuaGuiElement
--- @param index int? nil appends
--- @param pos int the position it will have
--- @param widths {subject: int, fix: int}?
--- @return LuaGuiElement
--- @return ProblemsSlot
local function create_slot(body, index, pos, widths)
	local link, ack = cell_tags()
	local odd = pos % 2 == 1
	local frame = body.add({ type = "frame", style = ROW_STYLE[odd], direction = "horizontal", visible = false,
		index = index })
	frame.add({ type = "sprite", style = "cybersyn_problems_dot" })
	local chip = frame.add({ type = "button", style = "cybersyn_chip_grey", raise_hover_events = true, tags = link,
		mouse_button_filter = { "left" } })
	chip.style.width = W.chip
	local subject = frame.add({ type = "flow", direction = "horizontal", style = "cybersyn_unserved_cell_flow" })
	if widths then subject.style.width = widths.subject end
	local icons = subject.add({ type = "flow", direction = "horizontal", style = "cybersyn_unserved_icon_flow" })
	for _ = 1, NAME_ICONS do
		icons.add({ type = "sprite-button", style = "cybersyn_name_icon", visible = false, raise_hover_events = true,
			tags = link })
	end
	local button = subject.add({ type = "button", style = "cybersyn_link_button", raise_hover_events = true, tags = link,
		mouse_button_filter = { "left" } })
	local tail = subject.add({ type = "flow", direction = "horizontal", style = "cybersyn_unserved_icon_flow" })
	for _ = 1, NAME_ICONS do
		tail.add({ type = "sprite-button", style = "cybersyn_name_icon", visible = false, raise_hover_events = true,
			tags = link })
	end
	frame.add({ type = "label", style = "cybersyn_problems_detail", raise_hover_events = true, tags = link })
	local fix = frame.add({ type = "label", style = "cybersyn_problems_fix", raise_hover_events = true, tags = link })
	if widths then
		button.style.maximal_width = widths.subject - 4
		fix.style.width = widths.fix
	end
	frame.add({ type = "sprite-button", style = "cybersyn_unserved_ack", sprite = "utility/check_mark",
		raise_hover_events = true, tags = ack })
	frame.add({ type = "label", style = "cybersyn_problems_group_caption", visible = false })
	frame.add({ type = "label", style = "cybersyn_subheader_note", visible = false })
	return frame, { kind = "r", vis = false, style = ROW_STYLE[odd], chip_style = "cybersyn_chip_grey",
		w = widths and widths_sig(widths),
		link_style = "cybersyn_link_button", detail_style = "cybersyn_problems_detail", n_icons = 0, iq = "",
		n_tail = 0, tq = "" }
end

--- The slot pool of the rows area, reset when the area was rebuilt (a new window).
--- @param player_data PlayerData
--- @param body LuaGuiElement
--- @return {slots: ProblemsSlot[], n: int, body: uint?, r: table?, dirty: true?, footer: string?}
local function pool_of(player_data, body)
	local state = util.gui_state(player_data, ROWS)
	if state.body ~= body.index or not state.slots then
		body.clear()
		state.body = body.index
		state.slots = {}
		state.n = 0
		state.r = nil
		state.footer = nil
		state.dirty = nil
	end
	return state
end

--- @param elem LuaGuiElement
--- @param c ProblemsSlot
--- @param kind "r"|"g"
local function show_set(elem, c, kind, ch)
	if c.kind == kind then return end
	local row = kind == "r"
	for i = C_CHIP, C_ACK do ch[i].visible = row end
	ch[C_GROUP].visible = not row
	ch[C_NOTE].visible = not row
	c.kind = kind
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

--- @param elem LuaGuiElement
--- @param c ProblemsSlot
--- @param line ProblemsLine
--- @param key string
local function bind_group(elem, c, line, key)
	local g = line.group
	local sig = key .. "|" .. line.shown .. "|" .. (line.hidden_acked or 0)
	if c.sig == sig then return end
	c.sig = sig
	local ch = elem.children
	show_set(elem, c, "g", ch)
	if c.style ~= GROUP_STYLE then
		elem.style = GROUP_STYLE
		c.style = GROUP_STYLE
	end
	local dot = pm.DOT[g.sev]
	if c.dot ~= dot then
		ch[C_DOT].sprite = dot
		c.dot = dot
	end
	ch[C_GROUP].caption = group_caption(line)
	ch[C_NOTE].caption = group_note(line)
	c.lk, c.lid, c.ak, c.ck = nil, nil, nil, nil
end

local NO_ICONS = {}
local ICON_STEP = 22

--- Writes one side's icon buttons of a subject cell; returns what they show now (count, qualities).
--- @param buttons LuaGuiElement[]
--- @param icons {sprite: string, quality: string?}[]
--- @param tip LocalisedString
--- @param shown int icons visible before
--- @param shown_q string qualities written before
--- @return int
--- @return string
local function bind_icons(buttons, icons, tip, shown, shown_q)
	local n = math.min(#icons, NAME_ICONS)
	local iq = ""
	for i = 1, n do
		local icon = icons[i]
		local b = buttons[i]
		b.sprite = sprite_or_unknown(icon.sprite)
		b.tooltip = tip
		iq = iq .. (icon.quality or "") .. ","
	end
	if iq ~= shown_q then
		for i = 1, n do buttons[i].quality = icons[i].quality end
	end
	for i = math.min(n, shown) + 1, math.max(n, shown) do buttons[i].visible = i <= n end
	return n, iq
end

--- @param elem LuaGuiElement
--- @param c ProblemsSlot
--- @param line ProblemsLine
--- @param key string
--- @param odd boolean
--- @param ctx {snapshot: Snapshot, widths: {subject: int, fix: int}, now: uint, wsig: string}
local function bind_row(elem, c, line, key, odd, ctx)
	local row = line.row
	local f = row.f
	local acked = line.acked == true
	local subject = subject_of(f, ctx.snapshot)
	local kind, id = subject.kind, subject.id
	local a = row.ack
	local ack_sig = a and (tostring(a.until_tick) .. ":" .. tostring(a.player_index) .. ":" ..
		(a.until_tick and math.floor((a.until_tick - ctx.now) / 3600) or "")) or ""
	local role = role_of(f, ctx.snapshot)
	local detail_sig = pm.detail_sig(f)
	local sig = table.concat({ key, odd and "o" or "e", acked and "a" or "", subject.name, tostring(kind), tostring(id),
		tostring(role), detail_sig, ack_sig, ctx.wsig }, "|")
	if c.sig == sig then return end
	c.sig = sig
	c.lk, c.lid, c.ak, c.ck = kind, id, row.ack_key, f.check

	local ch = elem.children
	show_set(elem, c, "r", ch)
	local style = ROW_STYLE[odd]
	if c.style ~= style then
		elem.style = style
		c.style = style
	end
	local dot = acked and pm.ACKED_DOT or pm.DOT[row.sev]
	if c.dot ~= dot then
		ch[C_DOT].sprite = dot
		c.dot = dot
	end

	local t = texts(f.check, role)
	local chip = ch[C_CHIP]
	local chip_style = acked and "cybersyn_chip_acked" or pm.CHIP_STYLE[row.sev]
	if c.chip_style ~= chip_style then
		chip.style = chip_style
		-- A style write drops the element's own width.
		chip.style.width = W.chip
		c.chip_style = chip_style
	end
	local chip_sig = t.key .. (kind and "l" or "")
	if c.chip ~= chip_sig then
		chip.caption = t.chip
		chip.tooltip = kind and t.linked or t.tooltip
		c.chip = chip_sig
	end

	local cell = ch[C_SUBJECT]
	local sub = cell.children
	local link = sub[2]
	local widths = ctx.widths
	local link_style = acked and "cybersyn_link_button_acked" or "cybersyn_link_button"
	local n_lead = math.min(#subject.icons, NAME_ICONS)
	local n_tail = subject.tail and math.min(#subject.tail, NAME_ICONS) or 0
	local relayout = c.w ~= ctx.wsig or c.n_icons ~= n_lead or c.n_tail ~= n_tail
	if c.link_style ~= link_style then
		link.style = link_style
		c.link_style = link_style
		relayout = true
	end
	if relayout then
		link.style.maximal_width = math.max(widths.subject - (n_lead + n_tail) * ICON_STEP - 4, 24)
	end
	if c.w ~= ctx.wsig then
		cell.style.width = widths.subject
		ch[C_FIX].style.width = widths.fix
		c.w = ctx.wsig
	end
	local subject_sig = subject.name .. "|" .. tostring(kind)
	if c.subject ~= subject_sig then
		local tip = kind and { "", "[font=default-semibold]", subject.tip, "[/font]\n", util.LINK_FOOTER } or subject.text
		link.caption = subject.text
		link.tooltip = tip
		if link.enabled ~= (kind ~= nil) then link.enabled = kind ~= nil end
		c.n_icons, c.iq = bind_icons(sub[1].children, subject.icons, tip, c.n_icons, c.iq)
		c.n_tail, c.tq = bind_icons(sub[3].children, subject.tail or NO_ICONS, tip, c.n_tail, c.tq)
		c.subject = subject_sig
	end

	local detail = ch[C_DETAIL]
	local detail_style = acked and "cybersyn_problems_detail_acked" or "cybersyn_problems_detail"
	if c.detail_style ~= detail_style then
		detail.style = detail_style
		c.detail_style = detail_style
	end
	if c.detail ~= detail_sig then
		local text = pm.detail(f, ENV)
		detail.caption = text
		detail.tooltip = text
		c.detail = detail_sig
	end
	if c.fix ~= t.key then
		local fix = ch[C_FIX]
		fix.caption = t.fix
		fix.tooltip = t.fix
		c.fix = t.key
	end
	local ack_full = (acked and "1" or "0") .. ack_sig
	if c.ack ~= ack_full then
		local button = ch[C_ACK]
		if button.toggled ~= acked then button.toggled = acked end
		button.tooltip = ack_tooltip(row, ctx.now)
		c.ack = ack_full
	end
end

--- @param line ProblemsLine
--- @return string
local function line_key(line)
	if line.kind == "group" then return "g" .. line.group.check .. (line.cont and "c" or "") end
	return line.row.key
end

--- @param elems LuaGuiElement[]
--- @param slots ProblemsSlot[]
--- @param line ProblemsLine
--- @param key string
--- @param i int
--- @param ctx table
local function bind(elems, slots, line, key, i, ctx)
	local elem, c = elems[i], slots[i]
	if line.kind == "group" then
		bind_group(elem, c, line, key)
	else
		bind_row(elem, c, line, key, i % 2 == 1, ctx)
	end
	if not c.vis then
		elem.visible = true
		c.vis = true
	end
end

--- Binds the page's lines to the pool's slots (see the section comment). While the hover hold is active, slots keep
--- their lines: only a line still on the page at its own slot is rewritten, and the caller retries.
--- @param body LuaGuiElement
--- @param lines ProblemsLine[]
--- @param ctx table
--- @param state table pool_of
--- @param hold boolean
--- @return "synced"|"held"
local function sync_slots(body, lines, ctx, state, hold)
	local slots = state.slots
	local elems = body.children
	local n = #lines
	local keys = {}
	for i = 1, n do keys[i] = line_key(lines[i]) end
	local cur_n = state.n
	if hold then
		local same = cur_n == n
		for i = 1, same and n or 0 do
			if slots[i].key ~= keys[i] then
				same = false
				break
			end
		end
		if not same then
			local index_of = {}
			for i = 1, n do index_of[keys[i]] = i end
			for j = 1, cur_n do
				local i = index_of[slots[j].key]
				if i then bind(elems, slots, lines[i], keys[i], j, ctx) end
			end
			return "held"
		end
	end

	local wanted, pos_of = {}, {}
	for i = 1, n do wanted[keys[i]] = true end
	for j = 1, cur_n do pos_of[slots[j].key] = j end
	for i = 1, n do
		local key = keys[i]
		if slots[i] == nil or slots[i].key ~= key then
			local j = pos_of[key]
			if not j then
				-- A slot at i or later whose line left the page (or none), the same kind first; slots before i are final.
				local kind = lines[i].kind == "group" and "g" or "r"
				local any
				for k = i, #slots do
					local s = slots[k]
					if not (s.key and wanted[s.key]) then
						if s.kind == kind then
							j = k
							break
						end
						any = any or k
					end
				end
				j = j or any
				if j and slots[j].key then pos_of[slots[j].key] = nil end
			end
			if j then
				if j ~= i then
					body.swap_children(i, j)
					slots[i], slots[j] = slots[j], slots[i]
					elems[i], elems[j] = elems[j], elems[i]
					local moved = slots[j].key
					if moved then pos_of[moved] = j end
				end
			else
				local elem, c = create_slot(body, i <= #elems and i or nil, i, ctx.widths)
				table.insert(elems, i, elem)
				table.insert(slots, i, c)
				for k = i + 1, #slots do
					local moved = slots[k].key
					if moved then pos_of[moved] = k end
				end
			end
			slots[i].key = key
			pos_of[key] = i
		end
		bind(elems, slots, lines[i], key, i, ctx)
	end
	for j = n + 1, #slots do
		local c = slots[j]
		if c.vis then
			elems[j].visible = false
			c.vis = false
		end
		c.key = nil
	end
	state.n = n
	return "synced"
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
local function render_scan(player_data, refs, s)
	local progress = lint.world_progress()
	local button = refs.problems_scan_button
	if button and button.valid and button.enabled ~= (progress == nil) then button.enabled = progress == nil end
	local note = refs.problems_scan_note
	if not (note and note.valid) then return end
	local sig, arg
	if progress then
		arg = tostring(math.floor(progress * 100))
		sig = "p" .. arg
	elseif s.world then
		arg = util.format_duration(game.tick - s.world.tick)
		sig = "w" .. arg
	else
		sig = "n"
	end
	if player_data.problems_scan_sig == sig then return end
	player_data.problems_scan_sig = sig
	if progress then
		note.caption = { "cybersyn-gui.problems-scanning", arg }
	elseif s.world then
		note.caption = { "cybersyn-gui.problems-scanned-ago", arg }
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

--- Before the first lint pass or world scan has finished: the progress of the running pass, rows and pager hidden.
--- @param player_data PlayerData
--- @param refs table
--- @param s LintState
local function render_pending(player_data, refs, s)
	local body, empty_flow = refs[ROWS], refs.problems_empty_flow
	if body.visible then body.visible = false end
	if not empty_flow.visible then empty_flow.visible = true end
	local pager = refs[TAB .. "_pager"]
	if pager and pager.valid and pager.visible then pager.visible = false end
	local job = s.job
	local caption
	if job then
		local n = #job.sids + #(job.dids or {}) + #(job.fids or {}) + (job.tids and #job.tids or 0)
		local done = (job.i or 0) + (job.ti or 0)
		caption = { "cybersyn-gui.problems-pending-progress", math.floor(100 * done / math.max(n, 1)) }
	else
		caption = { "cybersyn-gui.problems-pending" }
	end
	set_caption(refs.problems_empty, caption)
	set_caption(refs.problems_footer, "")
	-- The first result renders in full, whatever the pool showed before the result went away.
	pool_of(player_data, body).r = nil
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

--- @param map_data MapData?
--- @param player_data PlayerData
--- @param limit int? bind only the page's first `limit` lines (problems_tab.prebind); the render stays pending
function problems_tab.build(map_data, player_data, limit)
	local refs = player_data.refs
	local body = refs[ROWS]
	if not (body and body.valid) then return end
	local widths = player_data.problems_widths
	if not widths then return end
	local s = lint.state()
	render_scan(player_data, refs, s)
	if not problems_tab.has_result() then
		render_pending(player_data, refs, s)
		return
	end
	local m, built = problems_tab.model(player_data)
	local filter = filter_of(player_data)
	local now = game.tick
	local state = pool_of(player_data, body)
	local pass_age = s.tick and util.format_duration(now - s.tick) or "-"
	local footer_sig = m.total .. "|" .. m.acked .. "|" .. pass_age
	if state.footer ~= footer_sig then
		set_caption(refs.problems_footer, { "cybersyn-gui.problems-footer", format.number(m.total),
			format.number(m.acked), pass_age })
		state.footer = footer_sig
	end
	-- Everything the page and its rows depend on, compared before the page is split (which allocates).
	local fbits = (filter.sev[1] == false and 1 or 0) + (filter.sev[2] == false and 2 or 0)
		+ (filter.sev[3] == false and 4 or 0) + (filter.acked and 8 or 0)
	local layout = player_data.layout
	local want_rows = math.min(layout and layout.rows_by_tab[TAB] or 3, util.page_size(player_data))
	local hour = m.acked > 0 and filter.acked and math.floor(now / 3600) or -1
	local page_no = player_data.page and player_data.page[TAB]
	local r = state.r
	if r and not state.dirty and r.built == built and r.fbits == fbits and r.rows == want_rows and r.page == page_no
		and r.ws == widths.subject and r.wf == widths.fix and r.hour == hour then
		return
	end
	local pg, rows = current_page(player_data, m)

	render_toggles(refs, m, filter)
	render_pager(refs, pg)
	local ctx = { snapshot = collector.get(), widths = widths, now = now, wsig = widths_sig(widths) }
	local lines = pg.lines
	-- A window rebuilt while this tab is selected has no prewarmed pool: the page fills over a few renders rather
	-- than creating every slot in one.
	if #state.slots < #lines then limit = math.min(limit or #lines, #state.slots + CREATE_PER_RENDER) end
	if limit and limit < #lines then
		local part = {}
		for i = 1, limit do part[i] = lines[i] end
		lines = part
	end
	if sync_slots(body, lines, ctx, state, util.hold_active(player_data, ROWS)) == "held" or lines ~= pg.lines then
		state.dirty = true
	else
		state.dirty = nil
		state.r = { built = built, fbits = fbits, rows = rows, page = pg.page, ws = widths.subject, wf = widths.fix,
			hour = hour }
	end

	local empty_flow = refs.problems_empty_flow
	local show_empty = #pg.lines == 0
	if empty_flow.visible ~= show_empty then empty_flow.visible = show_empty end
	if body.visible == show_empty then body.visible = not show_empty end
	if show_empty then
		set_caption(refs.problems_empty, m.total == 0 and { "cybersyn-gui.problems-empty" }
			or { "cybersyn-gui.problems-empty-filtered" })
	end
end

--- The badge, on every render whichever tab is selected (PLAN3 §4.6: errors not acknowledged). The tab itself is
--- always shown: a tab whose `visible` flips while the window opens is drawn in the Overview's place for one frame
--- (the tab-strip transient of phases 4-10), so before the first lint result it shows the pass's progress instead.
--- @param player_data PlayerData
function problems_tab.refresh_tab(player_data)
	local tab = player_data.refs.manager_problems_tab
	if not (tab and tab.valid) then return end
	local created = problems_tab.prewarm(player_data)
	if not problems_tab.has_result() then
		if player_data.problems_badge ~= 0 then
			player_data.problems_badge = 0
			tab.badge_text = ""
			tab.tooltip = ""
		end
		return
	end
	if created == 0 and player_data.selected_tab ~= TAB then problems_tab.prebind(player_data) end
	local m = problems_tab.model(player_data)
	local n = m.badge
	if player_data.problems_badge ~= n then
		player_data.problems_badge = n
		tab.badge_text = n > 0 and tostring(n) or ""
		tab.tooltip = n > 0 and { "cybersyn-gui.problems-badge-tooltip", tostring(n) } or ""
	end
end

--- Fills the slot pool toward the page size, PREWARM slots per render whichever tab shows, so the tab's first render
--- binds slots instead of creating them.
--- @param player_data PlayerData
--- @return int created
function problems_tab.prewarm(player_data)
	local body = player_data.refs[ROWS]
	local layout = player_data.layout
	-- Not before the first snapshot: the boosted collection after an open has the updates to itself, and the lint
	-- job that gives this tab a result needs the snapshot anyway.
	if not (body and body.valid and layout and collector.get().tick) then return 0 end
	local rows = math.min(layout.rows_by_tab[TAB] or 3, util.page_size(player_data))
	local state = pool_of(player_data, body)
	local slots = state.slots
	local widths = player_data.problems_widths
	local n = math.max(math.min(rows - #slots, PREWARM), 0)
	for _ = 1, n do
		local _, c = create_slot(body, nil, #slots + 1, widths)
		slots[#slots + 1] = c
	end
	return n
end

--- Binds the current page to the pool PREBIND lines per render while another tab shows, once per pool: the tab's
--- first show then finds its page bound and writes nothing.
--- @param player_data PlayerData
function problems_tab.prebind(player_data)
	local body = player_data.refs[ROWS]
	local layout = player_data.layout
	if not (body and body.valid and layout) then return end
	local state = pool_of(player_data, body)
	if state.r then return end
	local rows = math.min(layout.rows_by_tab[TAB] or 3, util.page_size(player_data))
	if #state.slots < rows then return end
	problems_tab.build(nil, player_data, state.n + PREBIND)
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

--- The slot record of the row a cell belongs to.
--- @param player_data PlayerData
--- @param elem LuaGuiElement
--- @return ProblemsSlot?
local function slot_of(player_data, elem)
	local body = player_data.refs[ROWS]
	if not (body and body.valid) then return nil end
	local target = body.index
	while elem do
		local parent = elem.parent
		if not parent then return nil end
		if parent.index == target then
			local slots = util.gui_state(player_data, ROWS).slots
			return slots and slots[elem.get_index_in_parent()]
		end
		elem = parent
	end
	return nil
end

--- A link cell: the finding's subject (util.handle_link_click).
--- @param e EventData.on_gui_click
function problems_tab.handle.problems_link_click(player, player_data, refs, e)
	local c = slot_of(player_data, e.element)
	if not (c and c.key and c.lk) then return end
	util.handle_link_click(player, player_data, e, c.lk, c.lid)
end

--- Acknowledge a finding: click = 24 h, shift = 1 h, control = until it clears; a click on an acknowledged one ends it.
--- Display state only, so any player may acknowledge (PLAN3 §4.13).
--- @param e EventData.on_gui_click
function problems_tab.handle.problems_ack_click(player, player_data, refs, e)
	local c = slot_of(player_data, e.element)
	local key, check = c and c.ak, c and c.ck
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
	-- The click is the change the player asked for: the row leaves (or moves) now, not once the cursor leaves.
	player_data.hover = nil
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
	local n = 0
	for _, child in ipairs(body.children) do
		if child.visible then n = n + 1 end
	end
	return n
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
	local state = util.gui_state(player_data, ROWS)
	local slots = state.slots or {}
	if body and body.valid and body.visible then
		for i, child in ipairs(body.children) do
			local slot = slots[i]
			local c = child.children
			if not child.visible then
				break
			elseif slot.kind == "g" then
				rendered[i] = { kind = "group", key = slot.key, caption = c[C_GROUP].caption, note = c[C_NOTE].caption }
			else
				local subject = c[3].children[2]
				rendered[i] = {
					kind = "row",
					key = slot.key,
					style = child.style.name,
					dot = c[1].sprite,
					chip = c[2].caption,
					chip_style = c[2].style.name,
					chip_tooltip = c[2].tooltip,
					subject = subject.caption,
					subject_kind = slot.lk,
					subject_id = slot.lid,
					icons = slot.n_icons,
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

--- One render's pool work for player `pi` while another tab shows (prewarm, then prebind), for timing it alone.
dev.add("problems_pool_step", function(pi)
	local _, player_data = context(pi)
	if problems_tab.prewarm(player_data) == 0 and player_data.selected_tab ~= TAB and problems_tab.has_result() then
		problems_tab.prebind(player_data)
	end
	local state = util.gui_state(player_data, ROWS)
	return { slots = state.slots and #state.slots or 0, bound = state.n or 0, done = state.r ~= nil }
end)

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
	util.rerender(player, player_data)
	return ack
end)

return problems_tab
