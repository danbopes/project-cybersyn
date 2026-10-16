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
		assert_true(w.group_comps and w.group_bypass and w.group_name >= 120, "group row whole at " .. cw)
	end
	local w = l.train_widths(912, {}, false)
	assert_true(w.dropped.last_refuel == true, "the first column to go is Last refuel")
	-- Unchanged from before the pane: 1392 gives Shipment its six slots.
	assert_eq(l.train_widths(1392, {}, false).shipment, 192)
end)

test("train_widths: with the pane, Shipment goes and the columns fit down to the narrowest window", function()
	local l = logic()
	-- Content widths: 912 = the 960 px window floor (table 580), 1104 = 1080p/1.25 (772), 1231 = 1440p/1.5 (899),
	-- 1392 = 4K/1.5 and 1080p/1.0 (1060).
	for _, cw in ipairs({ 912, 1000, 1104, 1231, 1300, 1392, 2000 }) do
		for _, hidden in ipairs({ {}, { network = true, layout = true, depot = true }, { fuel = true, last_refuel = true } }) do
			local w = l.train_widths(cw, hidden, true)
			local at = cw .. " " .. tostring(next(hidden))
			assert_eq(w.cw, cw - 336, at)
			assert_eq(w.shipment, nil, "Shipment dropped at " .. at)
			assert_true(w.dropped.shipment, at)
			assert_true(l.train_columns_total(w) <= w.cw, "columns fit at " .. at .. ": " .. l.train_columns_total(w))
			assert_true(w.train_status >= l.TRAIN_STATUS_MIN, "status " .. w.train_status .. " at " .. at)
			assert_true(w.train_id ~= nil and w.state ~= nil, "id and state stay at " .. at)
			assert_true(w.group_name >= 120, "group name " .. w.group_name .. " at " .. at)
			for k in pairs(hidden) do assert_eq(w[k], nil, k .. " stays hidden at " .. at) end
		end
	end
	-- 4K/1.5: only Shipment goes; Network gives up a little width.
	local w = l.train_widths(1392, {}, true)
	assert_eq(w.network ~= nil and w.layout ~= nil and w.depot ~= nil and w.last_refuel ~= nil and w.fuel ~= nil, true)
	assert_eq(w.train_status, 260)
	-- The 960 px floor: refuel, fuel, layout, network and depot go too; id, status, state and time in state stay.
	w = l.train_widths(912, {}, true)
	local dropped = {}
	for k in pairs(w.dropped) do dropped[#dropped + 1] = k end
	table.sort(dropped)
	assert_eq(dropped, { "depot", "fuel", "last_refuel", "layout", "network", "shipment" })
	assert_eq(w.time_in_state, 72)
	-- 1080p/1.25 (table 772): Shipment, refuel, fuel and layout.
	dropped = {}
	for k in pairs(l.train_widths(1104, {}, true).dropped) do dropped[#dropped + 1] = k end
	table.sort(dropped)
	assert_eq(dropped, { "fuel", "last_refuel", "layout", "shipment" })
	-- The group row drops its compositions note, then the Bypassed chip, before its name gets under 120.
	assert_true(not w.group_comps and not w.group_bypass, "group at 912")
	w = l.train_widths(1104, {}, true)
	assert_true(not w.group_comps and w.group_bypass, "group at 1104")
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

test("state_chip: quiet states show none, trouble states are coloured, residue wins", function()
	local l = logic()
	assert_eq({ l.state_chip("on_the_path", 9999, false) }, { nil, nil })
	assert_eq({ l.state_chip("wait_station", 0, false) }, { nil, nil })
	assert_eq({ l.state_chip("arrive_station", 0, false) }, { nil, nil })
	assert_eq({ l.state_chip("no_path", 0, false) }, { "no_path", "red" })
	assert_eq({ l.state_chip("destination_full", 0, false) }, { "destination_full", "orange" })
	assert_eq({ l.state_chip("manual_control", 0, false) }, { "manual_control", "orange" })
	assert_eq({ l.state_chip("wait_signal", 599, false) }, { "wait_signal", "grey" })
	assert_eq({ l.state_chip("wait_signal", 600, false) }, { "wait_signal", "orange" })
	assert_eq({ l.state_chip("wait_station", 0, true) }, { "residue", "orange" })
	assert_eq({ l.state_chip(nil, 0, false) }, { nil, nil })
end)

test("in_trouble: every state with a red or orange chip, signal wait from 10 s", function()
	local l = logic()
	assert_true(l.in_trouble("path_lost", 0))
	assert_true(l.in_trouble("no_schedule", 0))
	assert_false(l.in_trouble(nil, 0))
	for _, state in ipairs({ "no_path", "path_lost", "no_schedule", "destination_full", "manual_control",
		"manual_control_stop", "arrive_signal", "wait_signal", "on_the_path", "wait_station" }) do
		for _, waited in ipairs({ 0, 599, 600 }) do
			local _, style = l.state_chip(state, waited, false)
			assert_eq(l.in_trouble(state, waited), style == "red" or style == "orange", state .. " " .. waited)
		end
	end
	assert_true(l.in_trouble("no_path", 0))
	assert_true(l.in_trouble("destination_full", 0))
	assert_true(l.in_trouble("manual_control", 0))
	assert_true(l.in_trouble("manual_control_stop", 0))
	assert_false(l.in_trouble("wait_signal", 599))
	assert_true(l.in_trouble("wait_signal", 600))
	assert_false(l.in_trouble("on_the_path", 1e6))
	assert_false(l.in_trouble("arrive_signal", 1e6))
end)

test("composition: locomotives as L, wagon runs in angle brackets", function()
	local l = logic()
	assert_eq(l.composition({ 0, 1, 1, 0 }), "L<CC>L")
	assert_eq(l.composition({ 0, 0, 1, 1, 1, 1 }), "LL<CCCC>")
	assert_eq(l.composition({ 0, 2, 1, 0, 1 }), "L<FC>L<C>")
	assert_eq(l.composition({ 0 }), "L")
	assert_eq(l.composition({}), "")
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

test("deficit: requested minus in transit minus unpromised stock, never below 0", function()
	local l = logic()
	assert_eq(l.deficit(-1000, 300, 200), 500)
	assert_eq(l.deficit(1000, 300, 200), 500, "a magnitude works too")
	assert_eq(l.deficit(-100, nil, 200), 0, "a surplus is no shortage")
	assert_eq(l.deficit(nil, 0, 50), 0)
	assert_eq(l.deficit(-10, nil, nil), 10)
	assert_eq(l.deficit(-1000, 400, -400), 600, "stock all promised (negative) counts as none")
end)

test("train chips: every caption key, full and compact, in every manager.cfg", function()
	local l = logic()
	local keys = {}
	for _, key in ipairs(l.TRAIN_CHIPS) do
		for _, compact in ipairs({ false, true }) do
			keys[#keys + 1] = l.train_chip_locale(key, compact):gsub("^cybersyn%-gui%.", "")
		end
		if key ~= "all" then keys[#keys + 1] = "trains-chip-" .. key:gsub("_", "-") .. "-tooltip" end
	end
	assert_eq(l.train_chip_locale("all", true), "cybersyn-gui.trains-chip-all")
	assert_eq(l.train_chip_locale("to_p", true), "cybersyn-gui.trains-chip-to-p-short")
	for _, loc in ipairs({ "en", "de", "es", "fr", "ko", "ru", "sv-SE" }) do
		local f = assert(io.open(H.mod_root .. "/locale/" .. loc .. "/manager.cfg", "r"))
		local text = f:read("*a")
		f:close()
		for _, k in ipairs(keys) do
			assert_true(text:find("\n" .. k .. "=", 1, true) ~= nil, loc .. " lacks " .. k)
		end
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
	-- A signal wait turns into trouble WAIT_SIGNAL_MIN after it began.
	assert_eq(l.chip_change_tick(1000, "wait_signal", 900, nil, 1, false), 900 + l.WAIT_SIGNAL_MIN)
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
