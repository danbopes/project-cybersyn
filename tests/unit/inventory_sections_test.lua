-- Round 7 (BRIEF-SECONDARY S4): the Inventory tab counts a station's items on the section that advertises them, so a
-- secondary inventory's items land under its own network ID and the network filter keeps only the sections on it.

local H = require("harness")
local SF = require("section_fixtures")

local function aggregate()
	local collector = require("scripts.gui.collector")
	SF.stub_collector(collector)
	return H.load("scripts.gui.inventory")._aggregate
end

local function snapshot(list)
	local stations = {}
	for _, st in ipairs(list) do stations[st.id] = st end
	return { stations = stations }
end

local function filters(network, mask)
	return { network = network, mask = mask or -1 }
end

local function count(bucket, hash)
	return bucket[hash] and bucket[hash].count or nil
end

test("inventory sections: the naphthalene plant's liquid fuel counts on A3, not on the station combinator's A1", function()
	local agg = aggregate()
	local snap = snapshot({ SF.naphtha(100) })
	local inv = agg(snap, filters())
	assert_eq(count(inv.provided, SF.NAPHTHA_OIL), 199134)
	assert_eq(count(inv.provided, SF.LIQUID_FUEL), 99134)
	assert_eq(inv.provided[SF.LIQUID_FUEL].stations, 1)
	-- Inventory 2's ignored -866 is never a request.
	assert_nil(inv.requested[SF.LIQUID_FUEL])
	-- Bit 2 is only in Inventory 1's A3.
	inv = agg(snap, filters("signal-A", 2))
	assert_eq(count(inv.provided, SF.LIQUID_FUEL), 99134)
	assert_nil(inv.provided[SF.NAPHTHA_OIL])
	-- Bit 3 is only Inventory 2's A4, which advertises nothing.
	inv = agg(snap, filters("signal-A", 4))
	assert_nil(inv.provided[SF.LIQUID_FUEL])
	assert_nil(inv.provided[SF.NAPHTHA_OIL])
	-- Another network: nothing.
	inv = agg(snap, filters("signal-B"))
	assert_nil(next(inv.provided))
end)

test("inventory sections: provided on A1 and requested on A2, each counts under its own network ID", function()
	local agg = aggregate()
	local st = SF.coal_both(200)
	st.wait = { [SF.COAL] = 50 }
	local snap = snapshot({ st })
	local inv, _, has_wait = agg(snap, filters())
	assert_eq(count(inv.provided, SF.COAL), 5000)
	assert_eq(count(inv.requested, SF.COAL), -2000)
	assert_eq(inv.requested[SF.COAL].earliest_wait_start, 50)
	assert_true(has_wait)
	inv = agg(snap, filters(nil, 2))
	assert_nil(inv.provided[SF.COAL])
	assert_eq(count(inv.requested, SF.COAL), -2000)
	-- Nothing provides coal on the request's network now, so all of it is short.
	assert_eq(inv.deficit[SF.COAL], 2000)
	inv = agg(snap, filters("signal-A", 1))
	assert_eq(count(inv.provided, SF.COAL), 5000)
	assert_nil(inv.requested[SF.COAL])
end)

test("inventory sections: sections of the same sources count their stock once; deliveries once per station", function()
	local agg = aggregate()
	local st = SF.coal_both(200)
	-- The station combinator's coal on A1 again on B1 (an each-network station), plus an incoming train.
	local dup = { key = "signal-B:1", network_name = "signal-B", mask = 1, sources = st.sections[1].sources,
		provided = st.sections[1].provided, requested = {}, ignored = {} }
	table.insert(st.sections, dup)
	st.deliveries = { [SF.COAL] = 300 }
	local inv = agg(snapshot({ st }), filters())
	assert_eq(count(inv.provided, SF.COAL), 5000)
	assert_eq(inv.provided[SF.COAL].stations, 1)
	assert_eq(count(inv.in_transit, SF.COAL), 300)
	inv = agg(snapshot({ st }), filters("signal-B"))
	assert_eq(count(inv.provided, SF.COAL), 5000)
	assert_nil(inv.requested[SF.COAL])
end)

test("inventory sections: a plain station with a sections table is counted as before", function()
	local agg = aggregate()
	local plain = SF.plain(7, "Plain", 1, { [SF.COAL] = 40 }, { [SF.COAL .. "x"] = { count = -5, threshold = 1, active = true } })
	local inv = agg(snapshot({ plain }), filters("signal-A", 1))
	assert_eq(count(inv.provided, SF.COAL), 40)
	assert_eq(count(inv.requested, SF.COAL .. "x"), -5)
	inv = agg(snapshot({ plain }), filters("signal-A", 2))
	assert_nil(next(inv.provided))
end)
