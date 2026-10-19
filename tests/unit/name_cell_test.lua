-- Stop-name helpers shared by the Log, Overview and Stations tabs (scripts/gui/name-cell.lua).

local H = require("harness")

local function nc()
	return H.load("scripts.gui.name-cell")
end

local function stop(name, valid)
	return { valid = valid ~= false, backer_name = name }
end

test("station_view: snapshot first, then depot and refueler stops; gone stops are nil and cached as such", function()
	local n = nc()
	storage.stations = {}
	storage.depots = { [2] = { entity_stop = stop("[item=iron-plate] Depot") } }
	storage.refuelers = { [3] = { entity_stop = stop("Fuel", false) } }
	local parts = { text = "Snap" }
	local stations = { [1] = { name = "Snap full", name_parts = parts } }
	local v, st = n.station_view(1, stations)
	assert_eq(v, { name = "Snap full", text = "Snap", parts = parts, kind = "station" })
	assert_eq(st, stations[1])
	local cache = {}
	local d = n.station_view(2, stations, cache)
	assert_eq(d.kind, "depot")
	assert_eq(d.text, "Depot")
	assert_eq(cache[2], d)
	assert_eq(n.station_view(3, stations, cache), nil)
	assert_eq(cache[3], false)
	assert_eq(n.station_view(0, stations), nil)
	assert_eq(n.station_view(nil, stations), nil)
end)

test("station_tooltip: bold name, the optional line, the link footer", function()
	local n = nc()
	local util = require("scripts.gui.util")
	assert_eq(n.station_tooltip(nil), "")
	assert_eq(n.station_tooltip({ name = "A" }, "x"),
		{ "", "[font=default-semibold]", "A", "[/font]", "\n", "x", "\n", util.LINK_FOOTER })
	assert_eq(n.station_tooltip({ name = "A" }), { "", "[font=default-semibold]", "A", "[/font]", "\n", util.LINK_FOOTER })
end)
