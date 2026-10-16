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
	assert_eq(l.table_width(1392, true), 1392 - 332)
	assert_eq(l.PANE_WIDTH + l.PANE_GAP, 332)
end)

test("shrink_first: the moved column gives up its width before the others", function()
	local l = logic()
	local cols = { { "id", 60 }, { "status", 0 }, { "net", 100, min = 60 }, { "ship", 192, min = 96 } }
	local moved = l.shrink_first(cols, "ship")
	assert_eq(moved[1][1], "ship")
	assert_eq(#moved, 4)
	assert_eq(cols[1][1], "id", "the input keeps its order")
	-- 100 px short: list order takes 40 from net first; shrink_first takes 96 from ship and only the last 4 from net.
	assert_eq(l.allocate(cols, nil, 552, "status", 300), { id = 60, net = 60, ship = 132, status = 300 })
	assert_eq(l.allocate(moved, nil, 552, "status", 300), { id = 60, net = 96, ship = 96, status = 300 })
	assert_eq(l.allocate(moved, nil, 652, "status", 300), { id = 60, net = 100, ship = 192, status = 300 })
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
