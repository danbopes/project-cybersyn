-- PLAN3 §4.7 (phase 4): the pure rules of the Stations, Trains and Inventory tabs (scripts/gui/tab-logic.lua).

local H = require("harness")

local function logic()
	return H.load("scripts.gui.tab-logic")
end

local function id(x) return x end

test("single_value: one distinct value hides the column, nil counts as a value", function()
	local l = logic()
	assert_eq({ l.single_value({ 1, 1, 1 }, id) }, { true, 1 })
	assert_eq({ l.single_value({ 1, 2, 1 }, id) }, { false, nil })
	local all_nil = { { v = nil }, { v = nil } }
	assert_true((l.single_value(all_nil, function(r) return r.v end)), "all nil is uniform")
	local mixed = { { v = nil }, { v = 3 } }
	assert_false((l.single_value(mixed, function(r) return r.v end)), "nil and a value differ")
	assert_true((l.single_value({}, id)), "an empty page hides nothing visible")
end)

test("allocate: the flexible column takes the rest, hidden columns take nothing", function()
	local l = logic()
	local cols = { { "id", 60 }, { "status", 0 }, { "net", 100 }, { "ship", 200, min = 96 } }
	local w = l.allocate(cols, nil, 800, "status", 200)
	assert_eq(w, { id = 60, net = 100, ship = 200, status = 440 })
	w = l.allocate(cols, { net = true }, 800, "status", 200)
	assert_eq(w, { id = 60, ship = 200, status = 540 })
end)

test("allocate: shrinkable columns give width to the flexible one down to their minimum", function()
	local l = logic()
	local cols = { { "id", 60 }, { "status", 0 }, { "ship", 200, min = 96 } }
	assert_eq(l.allocate(cols, nil, 400, "status", 200), { id = 60, ship = 140, status = 200 })
	assert_eq(l.allocate(cols, nil, 300, "status", 200), { id = 60, ship = 96, status = 144 })
end)

test("table_width: the detail pane and its gap come off the content width", function()
	local l = logic()
	assert_eq(l.table_width(1392, false), 1392)
	assert_eq(l.table_width(1392, true), 1392 - 336)
	assert_eq(l.PANE_WIDTH + l.PANE_GAP, 336)
end)

test("train_widths: closed, the table takes the content width; narrow windows drop columns, never the status", function()
	local l = logic()
	for _, cw in ipairs({ 862, 912, 1104, 1392, 2000 }) do
		local w = l.train_widths(cw, {}, false)
		assert_eq(w.cw, cw)
		if cw >= 1104 then assert_eq(next(w.dropped), nil, "nothing dropped at " .. cw) end
		assert_true(w.dropped.shipment == nil and w.shipment ~= nil and w.shipment % 32 == 0,
			"shipment kept in whole slots at " .. cw)
		assert_true(l.train_columns_total(w) <= cw, "columns fit at " .. cw)
		-- Phase 7: the closed table drops columns (pane order) rather than squeeze the status below its minimum.
		assert_true(w.train_status >= l.TRAIN_STATUS_MIN, "status keeps its minimum at " .. cw)
		assert_true(w.group_name >= 120 and w.group_bypass and w.group_marker == l.GROUP_MARKER, "group row at " .. cw)
		-- Round 4: the Problems marker takes room from the compositions on the narrowest windows.
		assert_eq(w.group_comps, cw >= 1000, "group compositions at " .. cw)
	end
	local w = l.train_widths(912, {}, false)
	assert_true(w.dropped.last_refuel == true, "the first column to go is Last refuel")
	-- Unchanged from before the pane: 1392 gives Shipment its six slots.
	assert_eq(l.train_widths(1392, {}, false).shipment, 192)
end)

test("train_widths: with the pane, Shipment goes first but only when the status needs the room", function()
	local l = logic()
	-- Content widths: 912 = the 960 px window floor (table 576), 1104 = 1080p/1.25 (768), 1231 = 1440p/1.5 (895),
	-- 1392 = 4K/1.5 and 1080p/1.0 (1056).
	for _, cw in ipairs({ 912, 1000, 1104, 1231, 1300, 1392, 2000 }) do
		for _, hidden in ipairs({ {}, { network = true, layout = true, depot = true }, { fuel = true, last_refuel = true } }) do
			local w = l.train_widths(cw, hidden, true)
			local at = cw .. " " .. tostring(next(hidden))
			assert_eq(w.cw, cw - 336, at)
			assert_true(l.train_columns_total(w) <= w.cw, "columns fit at " .. at .. ": " .. l.train_columns_total(w))
			assert_true(w.train_status >= l.TRAIN_STATUS_MIN, "status " .. w.train_status .. " at " .. at)
			assert_true(w.train_id ~= nil and w.state ~= nil, "id and state stay at " .. at)
			assert_true(w.group_name >= 120, "group name " .. w.group_name .. " at " .. at)
			for k in pairs(hidden) do assert_eq(w[k], nil, k .. " stays hidden at " .. at) end
			-- Shipment is the first to go: nothing else is dropped while it shows.
			if w.shipment then assert_eq(next(w.dropped), nil, "only after Shipment at " .. at) end
		end
	end
	-- D15 item 15: a wide window keeps Shipment beside the pane instead of a status 700 px wide.
	local w = l.train_widths(2000, {}, true)
	assert_eq(w.shipment, 192)
	-- 4K/1.5: Shipment stays with four slots, the shrinkable columns give up their room first.
	w = l.train_widths(1392, {}, true)
	assert_eq(w.shipment, 128)
	assert_eq(w.network ~= nil and w.layout ~= nil and w.depot ~= nil and w.last_refuel ~= nil and w.fuel ~= nil, true)
	-- 1300: Shipment goes, nothing else.
	assert_eq(l.train_widths(1300, {}, true).dropped, { shipment = true })
	-- The 960 px floor: refuel, fuel, layout, network and depot go too; id, status, state and time in state stay.
	w = l.train_widths(912, {}, true)
	local dropped = {}
	for k in pairs(w.dropped) do dropped[#dropped + 1] = k end
	table.sort(dropped)
	assert_eq(dropped, { "depot", "fuel", "last_refuel", "layout", "network", "shipment" })
	assert_eq(w.time_in_state, 72)
	-- 1080p/1.25 (table 768): Shipment, refuel and fuel.
	dropped = {}
	for k in pairs(l.train_widths(1104, {}, true).dropped) do dropped[#dropped + 1] = k end
	table.sort(dropped)
	assert_eq(dropped, { "fuel", "last_refuel", "shipment" })
	-- The group row drops its compositions, then the Bypassed chip, then the marker's caption, before its name gets
	-- under 120.
	assert_true(not w.group_comps and not w.group_bypass and w.group_marker == l.GROUP_MARKER_ICON, "group at 912")
	w = l.train_widths(1104, {}, true)
	assert_true(not w.group_comps and w.group_bypass and w.group_marker == l.GROUP_MARKER, "group at 1104")
end)

test("pane_split: the body keeps its minimum, the camera shrinks and then goes", function()
	local l = logic()
	-- 4K/1.5: 27 rows.
	assert_eq({ l.pane_split(36 + 27 * 36) }, { 180, 1008 - 108 - 192 })
	-- 1080p/1.5 without strips: 10 rows.
	assert_eq({ l.pane_split(36 + 10 * 36) }, { 156, 120 })
	-- 1080p/2.0: 5 rows, and the 3-row floor.
	assert_eq({ l.pane_split(216) }, { 0, 108 })
	assert_eq({ l.pane_split(144) }, { 0, 36 })
	for h = 144, 1100, 4 do
		local camera, body = l.pane_split(h)
		local used = l.PANE_FIXED + (camera > 0 and camera + l.PANE_CAMERA_GAP or 0) + body
		assert_true(used <= h and body >= 0, "height " .. h)
		assert_true(camera == 0 or (camera >= l.PANE_CAMERA_MIN and camera <= 180), "camera at " .. h)
		assert_true(camera == 0 or body >= l.PANE_BODY_MIN, "body at " .. h)
	end
end)

test("fit_slots: one line, the last slot turns into the overflow count", function()
	local l = logic()
	assert_eq({ l.fit_slots(5, 12) }, { 5, 0 })
	assert_eq({ l.fit_slots(12, 12) }, { 12, 0 })
	assert_eq({ l.fit_slots(13, 12) }, { 11, 2 })
	assert_eq({ l.fit_slots(40, 6) }, { 5, 35 })
	assert_eq({ l.fit_slots(3, 0) }, { 0, 3 })
end)

local ALL_STATES = { "on_the_path", "path_lost", "no_schedule", "no_path", "arrive_signal", "wait_signal",
	"arrive_station", "wait_station", "manual_control_stop", "manual_control", "destination_full" }

test("state_chip: one wording, icon and colour; quiet states uncoloured, a long signal orange, residue wins", function()
	local l = logic()
	local function style(state, since, now, status) return l.state_chip(state, since, now, status).style end
	assert_nil(style("on_the_path", 0, 9999))
	assert_nil(style("wait_station", 0, 0))
	assert_nil(style("arrive_station", 0, 0))
	assert_eq(style("no_path", 0, 0), "red")
	assert_eq(style("path_lost", 0, 0), "red")
	assert_eq(style("no_schedule", 0, 0), "red")
	assert_eq(style("destination_full", 0, 0), "orange")
	assert_eq(style("manual_control", 0, 0), "orange")
	assert_eq(style("manual_control_stop", 0, 0), "orange")
	-- PLAN4 D11: a signal approach counts like a signal wait (was: arrive_signal always grey).
	for _, s in ipairs({ "wait_signal", "arrive_signal" }) do
		assert_eq(style(s, 1, 600), "grey", s .. " 599")
		assert_eq(style(s, 0, 600), "orange", s .. " 600")
		assert_eq(style(s, nil, nil), "grey", s .. " no age")
	end
	local residue = l.state_chip("wait_station", 0, 0, "residue")
	assert_eq({ residue.key, residue.style, residue.sprite }, { "residue", "orange", "fluid/cybersyn-nonempty-train" })
	assert_eq(l.state_chip("no_path", 0, 0, "residue").key, "residue", "residue wins over any state")
	local refuel = l.state_chip("wait_station", 0, 0, "refuel")
	assert_eq({ refuel.key, refuel.style, refuel.sprite }, { "refuel", "grey", "virtual-signal/signal-fuel" })
	assert_eq(l.state_chip("no_path", 0, 0, "refuel").key, "no_path", "refuel only replaces a quiet state")
	local none = l.state_chip(nil, nil, nil)
	assert_eq({ none.key, none.style }, { "unknown", nil })
	-- Caption and tooltip: the [cybersyn-diag] train-state-* set, the age after a middle dot.
	local c = l.state_chip("wait_signal", 1000, 1000 + 384 * 60)
	assert_eq(c.caption, { "cybersyn-diag.train-state-wait-signal" })
	assert_eq(c.tooltip, { "", { "cybersyn-diag.train-state-wait-signal" }, " · ", "6m 24s" })
	assert_eq(l.state_chip("manual_control_stop").tooltip, { "cybersyn-diag.train-state-manual-control-stop" })
end)

test("state sprites: every defines.train_state, residue and refuel map to a sprite; the map is the D11 one", function()
	local l = logic()
	local n = 0
	for name in pairs(defines.train_state) do
		n = n + 1
		local c = l.state_chip(name, 0, 0)
		assert_eq(c.key, name)
		assert_true(l.STATE_SPRITE[name] ~= nil and c.sprite == l.STATE_SPRITE[name], name .. " has a sprite")
	end
	assert_eq(n, #ALL_STATES, "the harness knows every engine state")
	for _, name in ipairs(ALL_STATES) do assert_true(l.STATE_SPRITE[name] ~= nil, name) end
	assert_eq(l.STATE_SPRITE.no_path, "utility/no_path_icon")
	assert_eq(l.STATE_SPRITE.path_lost, "fluid/cybersyn-lost-train")
	assert_eq(l.STATE_SPRITE.destination_full, "utility/destination_full_icon")
	assert_eq(l.STATE_SPRITE.arrive_signal, "item/rail-signal")
	assert_eq(l.STATE_SPRITE.wait_signal, "item/rail-signal")
	assert_eq(l.STATE_SPRITE.manual_control, "utility/hand")
	assert_eq(l.STATE_SPRITE.no_schedule, "utility/rail_path_not_possible")
	assert_eq(l.STATE_SPRITE.residue, "fluid/cybersyn-nonempty-train")
	assert_eq(l.STATE_SPRITE.refuel, "virtual-signal/signal-fuel")
	for _, b in ipairs(l.STATE_BUCKETS) do
		local c = l.bucket_chip(b)
		assert_eq(c.sprite, l.STATE_SPRITE[b] or "utility/questionmark", b .. " bucket sprite")
		assert_eq(c.caption, { "cybersyn-diag.train-state-" .. b:gsub("_", "-") }, b .. " bucket words are train-state-*")
	end
end)

test("state locale: one train-state-* set in every manager.cfg; the trains-state-*, relative-state-* and trains-group-state-* sets are gone", function()
	local l = logic()
	local keys = {}
	for _, name in ipairs(ALL_STATES) do keys[#keys + 1] = "train-state-" .. name:gsub("_", "-") end
	for _, k in ipairs({ "residue", "refuel", "unknown" }) do keys[#keys + 1] = "train-state-" .. k end
	for _, loc in ipairs({ "en", "de", "es", "fr", "ko", "ru", "sv-SE" }) do
		local f = assert(io.open(H.mod_root .. "/locale/" .. loc .. "/manager.cfg", "r"))
		local text = f:read("*a")
		f:close()
		for _, k in ipairs(keys) do
			assert_true(text:find("\n" .. k .. "=", 1, true) ~= nil, loc .. " lacks " .. k)
		end
		assert_nil(text:find("\ntrains%-state%-"), loc .. " still has trains-state-*")
		assert_nil(text:find("\nrelative%-state%-"), loc .. " still has relative-state-*")
		assert_nil(text:find("\ntrains%-group%-state%-"), loc .. " still has trains-group-state-*")
	end
end)

test("state_bucket: every state in exactly one bucket of the group tooltip", function()
	local l = logic()
	local known = {}
	for _, b in ipairs(l.STATE_BUCKETS) do known[b] = true end
	for _, name in ipairs(ALL_STATES) do assert_true(known[l.state_bucket(name)], name) end
	assert_eq(l.state_bucket("wait_signal"), "wait_signal")
	assert_eq(l.state_bucket("manual_control_stop"), "manual_control_stop")
	assert_eq(l.state_bucket("some_future_state"), "unknown")
	assert_eq(l.state_bucket(nil), "unknown")
end)

test("state_sort_key: red, orange, signals, quiet, none; fixed while a wait ages", function()
	local l = logic()
	local order = { "no_path", "manual_control", "wait_signal", "on_the_path" }
	for i = 1, #order - 1 do
		assert_true(l.state_sort_key(order[i]) < l.state_sort_key(order[i + 1]), order[i])
	end
	assert_true(l.state_sort_key("wait_station") < l.state_sort_key(nil))
end)

test("short_duration: the same two-unit captions as util.short_duration", function()
	local l = logic()
	assert_eq(l.short_duration(0), "0s")
	assert_eq(l.short_duration(42 * 60), "42s")
	assert_eq(l.short_duration(185 * 60), "3m 05s")
	assert_eq(l.short_duration(3900 * 60), "1h 05m")
	assert_eq(l.short_duration(183600 * 60), "2d 03h")
end)

test("in_trouble: every state with a red or orange icon, a signal from 10 s", function()
	local l = logic()
	assert_true(l.in_trouble("path_lost", 0))
	assert_true(l.in_trouble("no_schedule", 0))
	assert_false(l.in_trouble(nil, 0))
	for _, state in ipairs(ALL_STATES) do
		for _, waited in ipairs({ 0, 599, 600 }) do
			local style = l.state_chip(state, 0, waited).style
			assert_eq(l.in_trouble(state, waited), style == "red" or style == "orange", state .. " " .. waited)
		end
	end
	assert_false(l.in_trouble("wait_signal", 599))
	assert_true(l.in_trouble("wait_signal", 600))
	assert_true(l.in_trouble("arrive_signal", 600), "PLAN4 D11: a long approach is trouble too")
	assert_false(l.in_trouble("on_the_path", 1e6))
end)

test("composition: locomotives as L, wagon runs in angle brackets", function()
	local l = logic()
	assert_eq(l.composition({ 0, 1, 1, 0 }), "L<CC>L")
	assert_eq(l.composition({ 0, 0, 1, 1, 1, 1 }), "LL<CCCC>")
	assert_eq(l.composition({ 0, 2, 1, 0, 1 }), "L<FC>L<C>")
	assert_eq(l.composition({ 0 }), "L")
	assert_eq(l.composition({}), "")
end)

test("composition_runs: one run per class, artillery and unknown classes as locomotives", function()
	local l = logic()
	assert_eq(l.composition_runs({ 0, 1, 1 }), { { class = 0, n = 1 }, { class = 1, n = 2 } })
	assert_eq(l.composition_runs({ 0, 1, 1, 0 }), { { class = 0, n = 1 }, { class = 1, n = 2 }, { class = 0, n = 1 } })
	assert_eq(l.composition_runs({ 0, 0, 2, 2, 2, 2 }), { { class = 0, n = 2 }, { class = 2, n = 4 } })
	assert_eq(l.composition_runs({ 0, 7 }), { { class = 0, n = 2 } })
	assert_eq(l.composition_runs({}), {})
	assert_eq(l.composition_icons({ 0, 1, 2 }), "[item=locomotive][item=cargo-wagon][item=fluid-wagon]")
	for class = 0, 2 do assert_true(l.CLASS_SPRITE[class] ~= nil) end
end)

test("fit_compositions: up to max as icon runs, the rest as +n, at least one", function()
	local l = logic()
	-- pY 123's "Depot": three two-run compositions (×272, ×226, ×37) in the 220 px slot: two shown, +1.
	local py = { { runs = 2, n = 272 }, { runs = 2, n = 226 }, { runs = 2, n = 37 } }
	assert_eq({ l.fit_compositions(py, l.GROUP_COMPS, 2) }, { 2, 1 })
	assert_eq({ l.fit_compositions({ { runs = 2, n = 5 } }, l.GROUP_COMPS, 2) }, { 1, 0 })
	assert_eq({ l.fit_compositions({ { runs = 9, n = 5 }, { runs = 2, n = 1 } }, l.GROUP_COMPS, 2) }, { 1, 1 },
		"one long composition takes the slot")
	assert_eq({ l.fit_compositions({}, l.GROUP_COMPS, 2) }, { 0, 0 })
	assert_eq({ l.fit_compositions(py, 80, 2) }, { 1, 2 }, "one at least")
end)

test("age, not_refuelled and age_caption", function()
	local l = logic()
	assert_eq(l.age(1000, nil), nil)
	assert_eq(l.age(1000, 400), 600)
	assert_eq(l.age(1000, 1200), 0)
	assert_true(l.not_refuelled(1000, nil, 1))
	assert_false(l.not_refuelled(216000, 1, 1))
	assert_true(l.not_refuelled(216002, 1, 1))
	assert_false(l.not_refuelled(216002, 1, 2))
	assert_true(l.not_refuelled(54001, 0, 0.25))
	-- Never refuelled: the grace runs from refuel_from, as in the collector's not_refuelled_count and the lint.
	assert_false(l.not_refuelled(216000, nil, 1, 1), "inside its grace")
	assert_true(l.not_refuelled(216002, nil, 1, 1), "past its grace")
	assert_false(l.not_refuelled(300000, nil, 1, 100000), "a train registered late gets its own hour")
	assert_true(l.not_refuelled(300000, 1, 1, 299999), "a refuel tick wins over refuel_from")
	local fmt = function(t) return t .. "t" end
	assert_eq({ l.age_caption(1000, nil, fmt) }, { nil, nil })
	assert_eq({ l.age_caption(1000, 100, fmt) }, { "900t", 900 })
end)

test("fuel_percent: averaged over burner locomotives, nil when electric", function()
	local l = logic()
	assert_eq(l.fuel_percent({}), nil)
	assert_eq(l.fuel_percent({ { energy = 50, capacity = 100 } }), 50)
	assert_eq(l.fuel_percent({ { energy = 100, capacity = 100 }, { energy = 0, capacity = 100 } }), 50)
	assert_eq(l.fuel_percent({ { energy = 0, capacity = 0 } }), 0)
	assert_eq(l.fuel_percent({ { energy = 150, capacity = 100 } }), 100)
end)

test("group_rows: a group row per name, members only under expanded groups", function()
	local l = logic()
	local rows = l.group_rows({ "A", "B" }, { A = { 1, 2 }, B = { 3 } }, { B = true })
	assert_eq(rows, { { group = "A" }, { group = "B" }, { group = "B", train = 3 } })
	assert_eq(#l.group_rows({ "A" }, { A = { 1, 2 } }, { A = true }), 3)
end)

test("station_flags: chips a station belongs to; failing = no power + disabled + throttling + setup", function()
	local l = logic()
	assert_eq(l.station_flags({ status = "ok" }), 0)
	assert_eq(l.station_flags({ status = "ok", unserved = { count = 2 } }), l.FLAG_UNSERVED)
	assert_eq(l.station_flags({ status = "ok", unserved = { count = 0 } }), 0)
	assert_eq(l.station_flags({ status = "no_power", lint = 4 }), l.FLAG_NO_POWER + l.FLAG_SETUP)
	assert_eq(l.station_flags({ status = "disabled", throttling = true }), l.FLAG_DISABLED + l.FLAG_THROTTLING)
	for _, f in ipairs({ l.FLAG_NO_POWER, l.FLAG_DISABLED, l.FLAG_THROTTLING, l.FLAG_SETUP }) do
		assert_true(bit32.btest(l.FAILING, f))
	end
	assert_false(bit32.btest(l.FAILING, l.FLAG_UNSERVED))
	assert_false(bit32.btest(l.FAILING, l.FLAG_STUCK))
end)

test("stuck_stations: provider and requester of trains with a stuck alert", function()
	local l = logic()
	local trains = { [1] = { p_station_id = 10, r_station_id = 11 }, [2] = { p_station_id = 12 }, [3] = {} }
	local alerts = { { train_id = 1, kind = 1 }, { train_id = 2, kind = 2 }, { train_id = 3, kind = 1 }, { train_id = 9, kind = 1 } }
	assert_eq(l.stuck_stations(alerts, trains, 1), { [10] = true, [11] = true })
end)

test("chip_mode: names when they fit, else compact", function()
	local l = logic()
	assert_eq(l.chip_mode(1000, 900), "full")
	assert_eq(l.chip_mode(800, 900), "compact")
end)

test("chip_lines: all with names when they fit, else zero counts hidden (All and the toggled one kept), then wrap", function()
	local l = logic()
	local chips = {
		{ key = "all", width = 60, count = 6, keep = true },
		{ key = "a", width = 100, count = 0 },
		{ key = "b", width = 100, count = 3 },
		{ key = "c", width = 100, count = 0, keep = true },
		{ key = "d", width = 100, count = 2 },
	}
	local hidden, lines = l.chip_lines(chips, 500)
	assert_eq(hidden, {})
	assert_eq(lines, { { "all", "a", "b", "c", "d" } })
	hidden, lines = l.chip_lines(chips, 400)
	assert_eq(hidden, { a = true })
	assert_eq(lines, { { "all", "b", "c", "d" } })
	hidden, lines = l.chip_lines(chips, 300)
	assert_eq(hidden, { a = true })
	assert_eq(lines, { { "all", "b", "c" }, { "d" } }, "what still does not fit wraps; nothing is shortened")
end)

test("deficit: requested minus in transit minus unpromised stock, never below 0", function()
	local l = logic()
	assert_eq(l.deficit(-1000, 300, 200), 500)
	assert_eq(l.deficit(1000, 300, 200), 500, "a magnitude works too")
	assert_eq(l.deficit(-100, nil, 200), 0, "a surplus is no shortage")
	assert_eq(l.deficit(nil, 0, 50), 0)
	assert_eq(l.deficit(-10, nil, nil), 10)
	assert_eq(l.deficit(-1000, 400, -400), 600, "stock all promised (negative) counts as none")
end)

test("train chips: every caption and tooltip key in every manager.cfg, no short captions left", function()
	local l = logic()
	local keys = {}
	for _, key in ipairs(l.TRAIN_CHIPS) do
		keys[#keys + 1] = l.train_chip_locale(key):gsub("^cybersyn%-gui%.", "")
		if key ~= "all" then keys[#keys + 1] = "trains-chip-" .. key:gsub("_", "-") .. "-tooltip" end
	end
	assert_eq(l.train_chip_locale("to_p"), "cybersyn-gui.trains-chip-to-p")
	assert_eq(l.train_chip_locale("to_p", true), "cybersyn-gui.trains-chip-to-p", "D15 item 13: never abbreviated")
	for _, loc in ipairs({ "en", "de", "es", "fr", "ko", "ru", "sv-SE" }) do
		local f = assert(io.open(H.mod_root .. "/locale/" .. loc .. "/manager.cfg", "r"))
		local text = f:read("*a")
		f:close()
		for _, k in ipairs(keys) do
			assert_true(text:find("\n" .. k .. "=", 1, true) ~= nil, loc .. " lacks " .. k)
		end
		assert_nil(text:find("\ntrains%-chip%-[%w%-]+%-short="), loc .. " still has a short chip caption")
	end
end)

test("detail pane: its locale keys in every manager.cfg, and no key the code uses is missing", function()
	local keys = { "trains-pane-caption", "trains-pane-close-tooltip", "trains-pane-camera-tooltip" }
	local f = assert(io.open(H.mod_root .. "/scripts/gui/trains.lua", "r"))
	local code = f:read("*a")
	f:close()
	for key in code:gmatch('"cybersyn%-gui%.(trains%-pane%-[%w%-]+)"') do
		local known = false
		for _, k in ipairs(keys) do known = known or k == key end
		assert_true(known, "trains.lua uses " .. key .. ", not in this list")
	end
	for _, loc in ipairs({ "en", "de", "es", "fr", "ko", "ru", "sv-SE" }) do
		f = assert(io.open(H.mod_root .. "/locale/" .. loc .. "/manager.cfg", "r"))
		local text = f:read("*a")
		f:close()
		for _, k in ipairs(keys) do
			assert_true(text:find("\n" .. k .. "=", 1, true) ~= nil, loc .. " lacks " .. k)
		end
	end
end)

test("hours_caption: the setting's value without rounding", function()
	local l = logic()
	assert_eq(l.hours_caption(1), "1")
	assert_eq(l.hours_caption(0.25), "0.25")
	assert_eq(l.hours_caption(2.75), "2.75")
	assert_eq(l.hours_caption(12.5), "12.5")
	assert_eq(l.hours_caption(24), "24")
end)

test("unrequested: provide keys without a request key on the same network", function()
	local l = logic()
	local p = { ["A:iron"] = 1, ["B:iron"] = 1, ["A:coal"] = 1, ["B:copper|rare"] = 1 }
	local r = { ["A:iron"] = true, ["B:coal"] = true }
	assert_eq(l.unrequested(p, r), { coal = true, ["copper|rare"] = true })
	assert_eq(l.unrequested(p, r, "B"), { iron = true, ["copper|rare"] = true })
	assert_eq(l.unrequested(p, r, "A"), { coal = true })
	assert_eq(l.unrequested({}, r), {})
end)

test("chip_change_tick: the first tick at which time alone changes a train's In trouble or Not refuelled chip", function()
	local l = logic()
	-- A signal wait or approach turns into trouble WAIT_SIGNAL_MIN after it began.
	assert_eq(l.chip_change_tick(1000, "wait_signal", 900, nil, 1, false), 900 + l.WAIT_SIGNAL_MIN)
	assert_eq(l.chip_change_tick(1000, "arrive_signal", 900, nil, 1, false), 900 + l.WAIT_SIGNAL_MIN)
	assert_nil(l.chip_change_tick(2000, "wait_signal", 900, nil, 1, false), "already in trouble")
	assert_nil(l.chip_change_tick(1000, "on_the_path", 900, nil, 1, false))
	-- Not refuelled: the tick after `hours` have passed since the last refuel, only where a refueler exists.
	assert_eq(l.chip_change_tick(1000, "on_the_path", 900, 500, 1, true), 500 + 216000 + 1)
	assert_nil(l.chip_change_tick(1000, "on_the_path", 900, 500, 1, false))
	assert_eq(l.chip_change_tick(1000, "wait_signal", 900, 500, 1, true), 900 + l.WAIT_SIGNAL_MIN, "the earlier one")
	-- Consistent with not_refuelled: false at the tick before, true at the tick returned.
	local at = l.chip_change_tick(1000, nil, nil, 500, 0.25, true)
	assert_false(l.not_refuelled(at - 1, 500, 0.25, nil))
	assert_true(l.not_refuelled(at, 500, 0.25, nil))
end)

test("duration axis: gridlines on whole durations that format exactly, at most five above 0", function()
	local l = logic()
	assert_eq(l.duration_label(0), "0s")
	assert_eq(l.duration_label(30), "30s")
	assert_eq(l.duration_label(60), "1m")
	assert_eq(l.duration_label(90), "1m 30s")
	assert_eq(l.duration_label(5400), "1h 30m")
	assert_eq(l.duration_label(7200), "2h")
	local function labels(max)
		local out = {}
		for i, t in ipairs(l.duration_ticks(max)) do out[i] = t.label end
		return out
	end
	-- The checkpoint's chart: 98 s of bars, an axis top of 108 s; the library labelled 73 s "1m" and 98 s "2m".
	assert_eq(labels(108), { "0s", "30s", "1m", "1m 30s" })
	assert_eq(labels(132), { "0s", "30s", "1m", "1m 30s", "2m" })
	assert_eq(labels(11), { "0s", "5s", "10s" })
	assert_eq(labels(4000), { "0s", "15m", "30m", "45m", "1h" })
	for _, max in ipairs({ 0.5, 1, 7, 59, 61, 100, 599, 601, 3599, 3601, 40000, 200000 }) do
		local ticks = l.duration_ticks(max)
		assert_true(#ticks >= 1 and #ticks - 1 <= l.DURATION_LINES, "lines at " .. max .. ": " .. #ticks)
		local step = ticks[2] and ticks[2].value or 0
		for i, t in ipairs(ticks) do
			assert_true(t.value <= max, "no line above the top at " .. max)
			assert_eq(t.value, (i - 1) * step, "evenly spaced at " .. max)
			-- Exact: the label parses back to the value.
			local h, m, s = 0, 0, 0
			for n, u in string.gmatch(t.label, "(%d+)([hms])") do
				if u == "h" then h = tonumber(n) elseif u == "m" then m = tonumber(n) else s = tonumber(n) end
			end
			assert_eq(h * 3600 + m * 60 + s, t.value, "label " .. t.label .. " at " .. max)
		end
	end
end)

test("train_widths: the group row's stats run beside a name of at most GROUP_NAME_MAX", function()
	local l = logic()
	for _, cw in ipairs({ 1000, 1104, 1392, 2000 }) do
		local w = l.train_widths(cw, {}, false)
		assert_true(w.group_name <= l.GROUP_NAME_MAX and w.group_name >= 120, "name " .. w.group_name .. " at " .. cw)
		local used = 20 + 6 * 8 + 28 + w.group_name + l.GROUP_MARKER + l.GROUP_STATS + l.GROUP_BYPASS + l.GROUP_COMPS
		assert_true(used <= cw, "group row fits at " .. cw .. ": " .. used)
	end
end)

test("unserved_split: Show acknowledged takes up to half a full page at the bottom (D5-5)", function()
	local l = logic()
	assert_eq({ l.unserved_split(19, 33, 5, false) }, { 19, 0 })
	assert_eq({ l.unserved_split(19, 3, 5, nil) }, { 3, 0 })
	assert_eq({ l.unserved_split(19, 33, 1, true) }, { 18, 1 })
	assert_eq({ l.unserved_split(19, 33, 12, true) }, { 10, 9 })
	assert_eq({ l.unserved_split(19, 33, 0, true) }, { 19, 0 })
	assert_eq({ l.unserved_split(19, 3, 30, true) }, { 3, 16 })
	assert_eq({ l.unserved_split(1, 5, 2, true) }, { 0, 1 })
	assert_eq({ l.unserved_split(0, 5, 2, true) }, { 0, 0 })
	assert_eq({ l.unserved_split(17, 59, 3, true) }, { 14, 3 })
end)

test("statuses: every status has a colour, and the locale key uses dashes", function()
	local l = logic()
	for _, s in ipairs(l.STATUSES) do assert_true(l.STATUS_COLOR[s] ~= nil, s .. " has a colour") end
	assert_eq(l.status_key("no_power"), "cybersyn-gui.station-status-no-power")
end)
