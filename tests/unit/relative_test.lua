-- The pure builders of the relative panels (scripts/gui/relative-text.lua) and the bounded backward scan they read
-- the log with (diag.last_for_step).

local H = require("harness")

local function rt()
	return H.load("scripts.gui.relative-text")
end

local function collector()
	return require("scripts.gui.collector")
end


test("role: provider, requester, both, none; stack mode appended", function()
	local t = rt()
	assert_eq(t.role(true, true, false), { "cybersyn-gui.relative-role-both" })
	assert_eq(t.role(true, false, false), { "cybersyn-gui.relative-role-provider" })
	assert_eq(t.role(false, true, false), { "cybersyn-gui.relative-role-requester" })
	assert_eq(t.role(false, false, false), { "cybersyn-gui.relative-role-none" })
	assert_eq(t.role(false, true, true),
		{ "", { "cybersyn-gui.relative-role-requester" }, " · ", { "cybersyn-gui.relative-stack-mode" } })
end)

test("stacks: whole stacks a threshold fills, rounded up; no stack size reads 0", function()
	local t = rt()
	assert_eq(t.stacks(2000, 100), 20)
	assert_eq(t.stacks(2001, 100), 21)
	assert_eq(t.stacks(2000, 5), 400)
	assert_eq(t.stacks(1, 200), 1)
	assert_eq(t.stacks(0, 50), 0)
	assert_eq(t.stacks(100, nil), 0)
end)

test("effective_threshold: a lower provider threshold replaces the requester's, a higher one does not", function()
	local t = rt()
	local v, o = t.effective_threshold(5000, 2000)
	assert_eq(v, 2000)
	assert_true(o)
	v, o = t.effective_threshold(5000, 8000)
	assert_eq(v, 5000)
	assert_false(o)
	v, o = t.effective_threshold(5000, nil)
	assert_eq(v, 5000)
	assert_false(o)
end)

test("train_mask: one network, NETWORK_EACH by name, other networks nil", function()
	local t = rt()
	assert_eq(t.train_mask({ network_name = "signal-A", network_mask = 3 }, "signal-A"), 3)
	assert_nil(t.train_mask({ network_name = "signal-A", network_mask = 3 }, "signal-B"))
	assert_eq(t.train_mask({ network_name = NETWORK_EACH, network_mask = { ["signal-B"] = 4 } }, "signal-B"), 4)
	assert_nil(t.train_mask({ network_name = NETWORK_EACH, network_mask = { ["signal-B"] = 4 } }, "signal-A"))
	assert_nil(t.train_mask({ network_name = nil }, "signal-A"))
end)

test("count_train: mask matches and distinct depots; capability per layout over every train on the network", function()
	local t = rt()
	local counts = { ["signal-A"] = t.new_fleet_count(1), ["signal-B"] = t.new_fleet_count(2) }
	local trains = {
		{ network_name = "signal-A", network_mask = 1, depot_id = 10, layout_id = 1, item_slot_capacity = 40, fluid_capacity = 0 },
		{ network_name = "signal-A", network_mask = 3, depot_id = 10, layout_id = 2, item_slot_capacity = 80, fluid_capacity = 0 },
		{ network_name = "signal-A", network_mask = 2, depot_id = 11, layout_id = 1, item_slot_capacity = 40, fluid_capacity = 0 },
		{ network_name = NETWORK_EACH, network_mask = { ["signal-B"] = 6 }, depot_id = 12, layout_id = 3, item_slot_capacity = 0, fluid_capacity = 50000 },
		{ network_name = "signal-C", network_mask = 1, depot_id = 13, layout_id = 1, item_slot_capacity = 40 },
	}
	for _, tr in ipairs(trains) do t.count_train(counts, tr) end
	local a, b = counts["signal-A"], counts["signal-B"]
	assert_eq(a.trains, 2, "trains sharing bit 1")
	assert_eq(a.depots, 1, "both in depot 10")
	assert_eq(a.capability[1], { count = 2, item_capacity = 40, fluid_capacity = 0, mask_or = 3 })
	assert_eq(a.capability[2], { count = 1, item_capacity = 80, fluid_capacity = 0, mask_or = 3 })
	assert_eq(b.trains, 1)
	assert_eq(b.depots, 1)
	assert_eq(b.capability[3].fluid_capacity, 50000)
	assert_eq(a.matched[1], { count = 1, item_capacity = 40, fluid_capacity = 0 }, "layout 1: only the mask-1 train")
	assert_eq(a.matched[2], { count = 1, item_capacity = 80, fluid_capacity = 0 })
end)

--- A fleet count of one network from {mask, layout_id, items, fluid} trains against the stop's mask.
local function fleet(t, stop_mask, trains)
	local counts = { ["signal-A"] = t.new_fleet_count(stop_mask) }
	for _, x in ipairs(trains) do
		t.count_train(counts, { network_name = "signal-A", network_mask = x[1], depot_id = 1, layout_id = x[2],
			item_slot_capacity = x[3], fluid_capacity = x[4] or 0 })
	end
	return counts["signal-A"]
end

test("eligible: trains counted one by one, never a layout's whole count by its OR-ed mask", function()
	local t = rt()
	-- One layout, four trains with masks 1, 2, 4, 8; the stop's mask is 1.
	local c = fleet(t, 1, { { 1, 7, 40 }, { 2, 7, 40 }, { 4, 7, 40 }, { 8, 7, 40 } })
	assert_eq(c.trains, 1)
	assert_eq(c.capability[7].count, 4)
	local n, items = t.eligible(c, true, {})
	assert_eq(n, 1, "matches the per-train count")
	assert_eq(items, 40)
	-- The largest capacity comes from a matching train only.
	c = fleet(t, 1, { { 1, 3, 20 }, { 2, 3, 80 } })
	n, items = t.eligible(c, true, {})
	assert_eq({ n, items }, { 1, 20 }, "the 80-stack train shares no bit")
	-- Accepted layouts filter the matched trains.
	c = fleet(t, 3, { { 1, 1, 40 }, { 2, 2, 80 }, { 1, 2, 60 } })
	n, items = t.eligible(c, false, { [1] = true })
	assert_eq({ n, items }, { 1, 40 })
	n, items = t.eligible(c, false, { [2] = true })
	assert_eq({ n, items }, { 2, 80 })
	assert_eq({ t.eligible(nil, true, {}) }, { 0, 0, 0 })
end)

test("allow_list: accepted layouts, eligible trains and the layouts no train has", function()
	local t = rt()
	local c = fleet(t, 1, { { 1, 1, 40 }, { 1, 1, 40 }, { 2, 2, 40 }, { 2, 2, 40 }, { 3, 2, 40 } })
	local n, trains, missing = t.allow_list({ [1] = true, [5] = true, [4] = true }, false, c)
	assert_eq(n, 3)
	assert_eq(trains, 2)
	assert_eq(missing, { 4, 5 })
	n, trains, missing = t.allow_list({ [2] = true }, false, c)
	assert_eq(trains, 1, "only layout 2's mask-3 train shares bit 1")
	assert_eq(missing, {})
	n, trains = t.allow_list({}, true, c)
	assert_false(n)
	assert_eq(trains, 3)
	n, trains, missing = t.allow_list({ [1] = true }, false, nil)
	assert_eq(n, 1)
	assert_eq(trains, 0)
	assert_eq(missing, { 1 })
end)

test("schedule_row: the active record marked, stations, rail waypoints, temporary and interrupt records", function()
	local t = rt()
	assert_eq(t.schedule_row(1, { station = "Depot" }, 2), { caption = { "", "    ", "1", ". ", "Depot" }, active = false })
	assert_eq(t.schedule_row(2, { station = "P", temporary = true }, 2), {
		caption = { "", "▶ ", "2", ". ", "P", " ", { "cybersyn-gui.relative-schedule-temporary" } }, active = true })
	assert_eq(t.schedule_row(3, { rail = true, temporary = true }, 2).caption[5], { "cybersyn-gui.relative-schedule-rail" })
	assert_eq(t.schedule_row(4, { station = "X", temporary = true, created_by_interrupt = true }, 1).caption[7],
		{ "cybersyn-gui.relative-schedule-interrupt" })
end)

test("event_row: rounded age, kind, and the detail each kind needs", function()
	local t = rt()
	assert_eq(t.event_row({ tick = 0, kind = DIAG_KIND_UNSERVED_REASON, code = REASON_R_LAYOUT, a = 0, b = 0 }, 1250),
		{ "", "20s", "  ", { "cybersyn-diag.kind-unserved-reason" }, " · ", { "cybersyn-diag.chip-r-layout" } })
	assert_eq(t.event_row({ tick = 100, kind = DIAG_KIND_SERVED, code = REASON_R_LAYOUT, a = 60, b = 0 }, 100),
		{ "", "0s", "  ", { "cybersyn-diag.kind-served" } })
	assert_eq(t.event_detail({ kind = DIAG_KIND_SHORT_LOAD, code = 0, a = 2000, b = 1900 }),
		{ "cybersyn-gui.relative-event-cargo", "2,000", "1,900" })
	assert_eq(t.event_detail({ kind = DIAG_KIND_LINT, code = DIAG_LINT_APPEARED, a = LINT_LAYOUT, b = 5 }),
		{ "", { "cybersyn-diag.lint-layout" }, " (", { "cybersyn-diag.lint-appeared" }, ")" })
	assert_eq(t.event_detail({ kind = DIAG_KIND_STATION_LIMIT, code = 0, a = 2, b = 0 }),
		{ "cybersyn-gui.relative-event-limit", "2", "0" })
	assert_nil(t.event_detail({ kind = DIAG_KIND_ALERT, code = 1, a = 0, b = 0 }))
end)

test("s_colour, trains_pair, mask_text", function()
	local t = rt()
	assert_eq(t.s_colour(0), "cyan")
	assert_eq(t.s_colour(1), "green")
	assert_eq(t.s_colour(3), "green")
	assert_eq(t.s_colour(2), "red")
	assert_eq(t.s_colour(nil), "cyan")
	assert_eq(t.trains_pair(1, 2), "1 / 2")
	assert_eq(t.trains_pair(0, 4294967295), "0 / ∞")
	assert_eq(t.mask_text(5), "5 (101)")
	assert_eq(t.mask_text(0), "0 (0)")
	assert_eq(t.mask_text(-1), "-1")
	assert_eq(t.mask_text(65536), "65536")
end)

-- ---------------------------------------------------------------- diag.last_for_step

local diag = H.load("scripts.diag")

local function setup(mode)
	settings.global["cybersyn-diagnostics"] = { value = mode or "full" }
	storage.trains = storage.trains or {}
	storage.stations = storage.stations or {}
	return diag.apply()
end

local function seqs(rows)
	local out = {}
	for i, ev in ipairs(rows) do out[i] = ev.seq end
	return out
end

--- `n` events about `station` (basic and full rings alternating) among `filler` others each.
local function fill(d, station, n, filler)
	for _ = 1, n do
		for _ = 1, filler do diag.event(d, DIAG_KIND_ARRIVE_P, DIAG_SEV_INFO, 0, 0, 1, 999, 0, 0, 0, 0) end
		diag.event(d, DIAG_KIND_STATION_LIMIT, DIAG_SEV_INFO, 0, 0, 0, station, 0, 0, 1, 2)
		diag.event(d, DIAG_KIND_ARRIVE_R, DIAG_SEV_INFO, 0, 0, 2, station, 0, 0, 0, 0)
	end
end

test("last_for_step: equals last_for once done, with at most the budget examined per call", function()
	game.tick = 10
	local d = setup("full")
	fill(d, 7, 6, 500)
	local want = seqs(diag.last_for("station", 7, 10))
	assert_eq(#want, 10)
	local c = diag.scan_cursor("station", 7, 10)
	local calls = 0
	repeat
		diag.last_for_step(c, 300)
		calls = calls + 1
		assert_true(c.examined <= 300, "examined " .. c.examined)
	until c.done or calls > 100
	assert_true(c.done)
	assert_eq(seqs(c.rows), want)
	assert_true(calls > 5, "the scan was spread over calls: " .. calls)
end)

test("last_for_step: rows written since the last call come first, without a rescan", function()
	game.tick = 10
	local d = setup("full")
	fill(d, 7, 12, 3)
	local c = diag.scan_cursor("station", 7, 10)
	diag.last_for_step(c)
	assert_true(c.done)
	fill(d, 7, 1, 20)
	diag.last_for_step(c)
	assert_eq(c.examined, 22, "only the new rows")
	assert_eq(seqs(c.rows), seqs(diag.last_for("station", 7, 10)))
end)

test("last_for_step: fewer matches than n is done at the end of the log; a new state starts over", function()
	game.tick = 10
	local d = setup("basic")
	fill(d, 7, 2, 5)
	local c = diag.scan_cursor("station", 7, 10)
	diag.last_for_step(c)
	assert_true(c.done)
	assert_eq(#c.rows, 2, "basic keeps only the limit rows")
	setup("off")
	assert_eq(diag.last_for_step(c), {})
	game.tick = 20
	d = setup("basic")
	fill(d, 7, 1, 0)
	assert_eq(#diag.last_for_step(c), 1)
end)

test("last_for_step: more new rows than the budget start over from the newest", function()
	game.tick = 10
	local d = setup("full")
	fill(d, 7, 3, 0)
	local c = diag.scan_cursor("station", 7, 10)
	diag.last_for_step(c)
	fill(d, 9, 2, 400)
	fill(d, 7, 1, 0)
	diag.last_for_step(c, 100)
	assert_eq(c.rows[1].seq, d.seq)
	repeat diag.last_for_step(c, 100) until c.done
	assert_eq(seqs(c.rows), seqs(diag.last_for("station", 7, 10)))
end)

-- ---------------------------------------------------------------- network sections (round 7)

-- Records in the collector's section contract (BRIEF-SECONDARY.md), built by hand.

local function fluid(name, order)
	prototypes.fluid[name] = prototypes.fluid[name]
		or { name = name, order = order, localised_name = { "fluid-name." .. name }, valid = true }
end

local function source(kind, index, priority)
	return { kind = kind, index = index, unit = 100 + index, ok = true, priority = priority or 0 }
end

--- [naphthalene-oil] Provider on pY 126: Provide only, the station combinator on A1, Inventory 1 on A3 (bits 1+2),
--- Inventory 2 on A4 whose -866 liquid fuel the switch keeps from being advertised.
local function naphthalene()
	fluid("naphthalene-oil", "z[a]")
	fluid("liquid-fuel", "z[b]")
	local s0, s1, s2 = source("station", 0), source("inventory", 1), source("inventory", 2)
	return {
		id = 7, name = "[fluid=naphthalene-oil] Provider", is_p = true, is_r = false, is_stack = false,
		network_name = "signal-A", network_mask = 1, comb_ok = true, priority = 0,
		provided = { ["naphthalene-oil"] = 199134, ["liquid-fuel"] = 99134 }, requested = {}, wait = {}, deliveries = {},
		sources = { s0, s1, s2 },
		mask_union = { ["signal-A"] = 7 },
		sections = {
			{ key = "signal-A:1", network_name = "signal-A", mask = 1, sources = { s0 },
				provided = { ["naphthalene-oil"] = 199134 }, requested = {}, ignored = {} },
			{ key = "signal-A:3", network_name = "signal-A", mask = 3, sources = { s1 },
				provided = { ["liquid-fuel"] = 99134 }, requested = {}, ignored = {} },
			{ key = "signal-A:4", network_name = "signal-A", mask = 4, sources = { s2 },
				provided = {}, requested = {}, ignored = { ["liquid-fuel"] = -866 } },
		},
	}
end

--- A plain requester: Request only, one section on A3, several requests below threshold, and a provide the switch
--- drops.
local function plain()
	local s0 = source("station", 0, 1)
	local requested = {
		["iron-plate"] = { count = -1900, threshold = 2000, active = false },
		["copper-plate"] = { count = -1600, threshold = 2000, active = false },
		["coal"] = { count = -2500, threshold = 2000, active = true },
	}
	local provided = {}
	return {
		id = 9, name = "Circuit Requestor", is_p = false, is_r = true, is_stack = false,
		network_name = "signal-A", network_mask = 3, comb_ok = true, priority = 1,
		provided = provided, requested = requested, wait = {}, deliveries = {},
		sources = { s0 },
		mask_union = { ["signal-A"] = 3 },
		sections = {
			{ key = "signal-A:3", network_name = "signal-A", mask = 3, sources = { s0 },
				provided = provided, requested = requested, ignored = { stone = 52 } },
		},
	}
end

test("sections: has_sections, masks caption, inventories and bits for the naphthalene provider and a plain stop", function()
	local t = rt()
	local n, p = naphthalene(), plain()
	assert_true(collector().station_has_sections(n))
	assert_false(collector().station_has_sections(p), "one section, no inventory")
	assert_eq({ t.masks_caption(t.sections_of(n)) }, { "signal-A", "1 · 3 · 4" })
	assert_eq({ t.masks_caption(t.sections_of(p)) }, { "signal-A", "3" })
	assert_eq(t.inventory_count(n), 2)
	assert_eq(t.inventory_count(p), 0)
		assert_eq(t.section_summary(n.sections[1]), { "cybersyn-gui.section-provides", "1" })
	assert_eq(t.section_summary(n.sections[3]), { "cybersyn-gui.section-nothing" })
	assert_eq(t.section_summary(p.sections[1]), { "cybersyn-gui.section-requests", "3" })
end)

test("sections: one label and one line of text per section, as the stop panel heads its blocks", function()
	local t = rt()
	local n = naphthalene()
	assert_eq(t.section_label(n.sections[2]), "[virtual-signal=signal-A]3")
	assert_eq(t.section_text(n.sections[2]),
		{ "", "[virtual-signal=signal-A]3", " (bits 1+2)", " · ", t.sources_caption(n.sections[2].sources) })
	assert_eq(t.section_text(n.sections[1])[3], "", "one bit, no bits label")
	local sig = t.section_sig(n.sections[2])
	n.sections[2].sources[1].priority = 9
	assert_true(t.section_sig(n.sections[2]) ~= sig, "a source's priority is in the text, so in the sig")
end)

test("sections: the switch's reason for what a section does not advertise", function()
	local t = rt()
	assert_eq(t.ignored_reason(naphthalene()), { "cybersyn-gui.section-provide-only" })
	assert_eq(t.ignored_reason(plain()), { "cybersyn-gui.section-request-only" })
	assert_eq(t.ignored_reason({ is_p = true, is_r = true }), { "cybersyn-gui.section-switch" })
end)

test("sections: sources caption with one priority, and with each source's own when they differ", function()
	local t = rt()
	local a, b = source("station", 0, 0), source("inventory", 1, 0)
	assert_eq(t.sources_caption({ a }), { "", collector().source_label(a), " · ", { "cybersyn-gui.section-priority", "0" } })
	assert_eq(t.sources_caption({ a, b }),
		{ "", collector().source_label(a), ", ", collector().source_label(b), " · ", { "cybersyn-gui.section-priority", "0" } })
	b.priority = 5
	assert_eq(t.sources_caption({ a, b }), { "", collector().source_label(a), " ", { "cybersyn-gui.section-source-priority", "0" },
		", ", collector().source_label(b), " ", { "cybersyn-gui.section-source-priority", "5" } })
end)

test("sections: a record without sections reads as one per network, NETWORK_EACH sorted", function()
	local t = rt()
	local st = { network_name = "signal-A", network_mask = 3, provided = { coal = 5 }, requested = {}, priority = 2 }
	local s = t.sections_of(st)
	assert_eq(#s, 1)
	assert_eq({ s[1].key, s[1].mask, s[1].sources[1].priority }, { "signal-A:3", 3, 2 })
	assert_true(s[1].provided == st.provided, "the station's own table")
	assert_false(collector().station_has_sections(st))
	s = t.sections_of({ network_name = NETWORK_EACH, network_mask = { ["signal-B"] = 2, ["signal-A"] = 1 },
		provided = {}, requested = {} })
	assert_eq({ s[1].key, s[2].key }, { "signal-A:1", "signal-B:2" })
	assert_eq(#t.sections_of({ provided = {}, requested = {} }), 0, "no network, nothing advertised")
end)

test("sections: starved per section, from section.starved or the station's network:hash keys on its own network", function()
	local t = rt()
	local p = plain()
	local sec = p.sections[1]
	assert_eq(t.section_starved(sec, { ["signal-A:coal"] = true, ["signal-A:iron-plate"] = true }), { coal = true },
		"below-threshold requests are never starved")
	assert_eq(t.section_starved(sec, { ["signal-B:coal"] = true }), {}, "another network's key")
	sec.starved = { ["iron-plate"] = true }
	assert_eq(t.section_starved(sec, { ["signal-A:coal"] = true }), { ["iron-plate"] = true }, "the collector's own set wins")
end)

test("sections_content: same values sign alike whatever the fill order; ignored and starved change it", function()
	local t = rt()
	local a, b = naphthalene(), naphthalene()
	b.sections[1].provided = {}
	b.sections[1].provided["naphthalene-oil"] = 199134
	assert_eq(t.sections_content(a), t.sections_content(b))
	b.sections[3].ignored["liquid-fuel"] = -900
	assert_true(t.sections_content(a) ~= t.sections_content(b), "ignored count")
	local p = plain()
	local base = t.sections_content(p)
	assert_eq(base, t.sections_content(p, { ["signal-A:coal"] = true }), "a record with sections keeps its own starved sets")
	p.sections[1].starved = { coal = true }
	assert_true(base ~= t.sections_content(p), "starved")
	p.sections[1].starved = nil
	local old = { network_name = "signal-A", network_mask = 1, provided = {}, requested = { coal = { count = -9, threshold = 1, active = true } } }
	assert_true(t.sections_content(old) ~= t.sections_content(old, { ["signal-A:coal"] = true }), "without sections, the station's keys")
	p.sections[1].sources[1].priority = 4
	assert_true(base ~= t.sections_content(p), "priority")
end)

-- ---------------------------------------------------------------- stop panel blocks

local function relative_mod()
	commands = commands or { add_command = function() end, remove_command = function() end, commands = {}, game_commands = {} }
	return H.load("scripts.gui.relative")
end

--- Captions of a def tree, depth first, LocalisedStrings flattened to their keys and plain parts.
local function captions(defs)
	local out = {}
	local function flat(ls)
		if type(ls) ~= "table" then return tostring(ls) end
		local parts = {}
		for i, v in ipairs(ls) do
			if not (i == 1 and v == "") then parts[#parts + 1] = flat(v) end
		end
		return table.concat(parts, "")
	end
	local function walk(d)
		if d.caption then out[#out + 1] = flat(d.caption) end
		if d.type == "sprite-button" then out[#out + 1] = "slot:" .. d.tags.id .. ":" .. string.gsub(d.style, "^ltnm_small_slot_button_", "") end
		for _, c in ipairs(d) do walk(c) end
		for _, c in ipairs(d.children or {}) do
			if d.type ~= "sprite-button" then walk(c) end
		end
	end
	for _, d in ipairs(defs) do walk(d) end
	return out
end

test("stop panel: the naphthalene provider gets one block per section, Inventory 2 with its unadvertised fuel", function()
	local r = relative_mod()
	local c = captions(r.slots_defs(naphthalene()))
	assert_eq(c[1], "cybersyn-gui.section-advertised")
	local text = table.concat(c, "\n")
	-- Section heads in order: A1, A3 with its bits, A4.
	local i1 = text:find("[virtual-signal=signal-A]1\n", 1, true)
	local i3 = text:find("[virtual-signal=signal-A]3\nbits 1+2\n", 1, true)
	local i4 = text:find("[virtual-signal=signal-A]4\n", 1, true)
	assert_true(i1 and i3 and i4 and i1 < i3 and i3 < i4, text)
	assert_true(text:find("slot:naphthalene-oil:green", i1, true) < i3, "naphthalene oil provided on A1")
	assert_true(text:find("slot:liquid-fuel:green", i3, true) < i4, "liquid fuel provided on A3")
	assert_nil(text:find("slot:liquid-fuel", i4, true), "never a slot on A4")
	local tail = text:sub(i4)
	assert_true(tail:find("cybersyn-gui.section-not-advertised [fluid=liquid-fuel", 1, true) and tail:find("]-866 (cybersyn-gui.section-provide-only)", 1, true) ~= nil, tail)
	local lines = 0
	for _, d in ipairs(r.slots_defs(naphthalene())) do
		if d.type == "line" then lines = lines + 1 end
	end
	assert_eq(lines, 2, "a separator between three blocks")
end)

test("stop panel: a plain requester is a single block with Provided, Requested, the threshold note and its dropped provide", function()
	local r = relative_mod()
	local c = captions(r.slots_defs(plain()))
	local text = table.concat(c, "\n")
	assert_eq(c[1], "cybersyn-gui.section-advertised")
	assert_true(text:find("[virtual-signal=signal-A]3\nbits 1+2\n", 1, true) ~= nil, text)
	assert_true(text:find("cybersyn-gui.section-provided\ncybersyn-gui.section-none\ncybersyn-gui.section-requested\n", 1, true) ~= nil, text)
	assert_true(text:find("slot:coal:red", 1, true) ~= nil)
	assert_true(text:find("slot:iron-plate:orange", 1, true) ~= nil)
	assert_true(text:find("slot:copper-plate:orange", 1, true) ~= nil)
	assert_true(text:find("cybersyn-gui.section-below-threshold", 1, true) ~= nil)
	assert_true(text:find("cybersyn-gui.section-not-advertised [item=stone", 1, true) and text:find("]52 (cybersyn-gui.section-request-only)", 1, true) ~= nil, text)
	for _, d in ipairs(r.slots_defs(plain())) do assert_true(d.type ~= "line", "one block, no separator") end
end)

test("stop panel: a starved request in a section says so in its tooltip", function()
	local r = relative_mod()
	local p = plain()
	p.sections[1].starved = { coal = true }
	local found = false
	local function walk(d)
		if d.type == "sprite-button" and d.tags.id == "coal" then
			found = serpent.line(d.tooltip):find("cybersyn-gui.section-starved", 1, true) ~= nil
		end
		for _, c in ipairs(d) do walk(c) end
	end
	for _, d in ipairs(r.slots_defs(p)) do walk(d) end
	assert_true(found)
end)

test("stop panel: the section blocks are rebuilt only when the record changed", function()
	local r = relative_mod()
	local body = H.element({ name = "body" })
	body.slots = body.add({ type = "flow", name = "slots" })
	local state = { sigs = {}, rebuilds = 0 }
	local st = naphthalene()
	st.read_tick = 10
	local m = { st = st, source = "snapshot" }
	r.render_slots(state, body, m)
	assert_eq(state.rebuilds, 1)
	assert_true(#body.slots.children > 0)
	r.render_slots(state, body, m)
	assert_eq(state.rebuilds, 1, "same pass, nothing rebuilt")
	st.read_tick = 20
	r.render_slots(state, body, m)
	assert_eq(state.rebuilds, 1, "refilled with the same values")
	st.sections[3].ignored["liquid-fuel"] = -900
	st.read_tick = 30
	r.render_slots(state, body, m)
	assert_eq(state.rebuilds, 2, "an unadvertised count moved")
	-- A live read with diagnostics on: the station-level starved set moves, the sectioned record's signature cache holds.
	m.source = "live"
	st.sig_key = -1
	state.starved = { ["signal-A:coal"] = true }
	r.render_slots(state, body, m)
	local cached = state.rsig.slots
	state.starved = { ["signal-A:stone"] = true }
	r.render_slots(state, body, m)
	assert_true(state.rsig.slots == cached, "the signature was not built again")
end)

test("stop panel: a working station combinator without input names its inventories as paused for that reason", function()
	local r = relative_mod()
	local t = rt()
	local n = naphthalene()
	n.comb_ok = true
	n.sources[3].read = false
	table.remove(n.sections, 3)
	assert_eq(#t.paused_inventories(n), 1)
	local text = table.concat(captions(r.slots_defs(n)), "\n")
	assert_true(text:find("cybersyn-gui.section-paused-no-signals", 1, true) ~= nil, text)
	n.comb_ok = false
	local off = table.concat(captions(r.slots_defs(n)), "\n")
	assert_true(off:find("cybersyn-gui.section-paused-no-signals", 1, true) == nil, off)
	assert_true(t.sections_content(n) ~= t.sections_content(naphthalene()))
end)

test("stop panel: inventories the collector could not read are named as paused", function()
	local r = relative_mod()
	local t = rt()
	local n = naphthalene()
	n.sources[3].ok = false
	table.remove(n.sections, 3)
	assert_eq(#t.paused_inventories(n), 1)
	local text = table.concat(captions(r.slots_defs(n)), "\n")
	assert_true(text:find("cybersyn-gui.section-paused", 1, true) ~= nil, text)
	assert_true(t.sections_content(n) ~= t.sections_content(naphthalene()))
end)
