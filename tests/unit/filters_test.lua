-- The manager filters in scripts/gui/utils/filters.lua: search terms, the filter set and its predicates.

local H = require("harness")

local function filters()
	return H.load("scripts.gui.utils.filters")
end

-- ------------------------------------------------------------------ search and filters

test("search_terms: lowercase whitespace-split words, nil when empty", function()
	local u = filters()
	assert_nil(u.search_terms(nil))
	assert_nil(u.search_terms(""))
	assert_nil(u.search_terms("  \t "))
	assert_eq(u.search_terms("Iron  Ore\tMINE"), { "iron", "ore", "mine" })
	assert_eq(u.search_terms(" a.b (c) "), { "a.b", "(c)" })
end)

test("set_search_query: empty string clears, whitespace-only keeps the query but no terms", function()
	local u = filters()
	local pd = { search_query = "x", search_terms = { "x" } }
	u.set_search_query(pd, "")
	assert_nil(pd.search_query)
	assert_nil(pd.search_terms)
	u.set_search_query(pd, "Foo Bar")
	assert_eq(pd.search_query, "Foo Bar")
	assert_eq(pd.search_terms, { "foo", "bar" })
	u.set_search_query(pd, "   ")
	assert_eq(pd.search_query, "   ")
	assert_nil(pd.search_terms)
	u.set_search_query(pd, nil)
	assert_nil(pd.search_query)
end)

test("get_filters: defaults and mapping from player_data", function()
	local u = filters()
	assert_eq(u.get_filters({}), { mask = -1 })
	local pd = {
		search_item = "iron-plate",
		search_network_name = "signal-A",
		search_network_mask = 5,
		search_surface_idx = 2,
		search_terms = { "a" },
	}
	assert_eq(u.get_filters(pd), { terms = { "a" }, item = "iron-plate", network = "signal-A", mask = 5, surface = 2 })
end)

test("get_filters: derives and caches terms from a query saved without them", function()
	local u = filters()
	local pd = { search_query = "A b" }
	local f = u.get_filters(pd)
	assert_eq(f.terms, { "a", "b" })
	assert_same(pd.search_terms, f.terms)
end)

test("filters_active: each field and ignore_item", function()
	local u = filters()
	assert_false(u.filters_active({ mask = -1 }))
	assert_true(u.filters_active({ mask = -1, item = "coal" }))
	assert_false(u.filters_active({ mask = -1, item = "coal" }, true))
	assert_true(u.filters_active({ mask = 0 }))
	assert_true(u.filters_active({ mask = -1, terms = { "a" } }))
	assert_true(u.filters_active({ mask = -1, network = "signal-A" }))
	assert_true(u.filters_active({ mask = -1, surface = 1 }))
end)

test("network_passes: no network filter and mask -1 passes everything", function()
	local u = filters()
	local f = { mask = -1 }
	assert_true(u.network_passes(nil, nil, f))
	assert_true(u.network_passes("signal-A", 0, f))
	assert_true(u.network_passes(NETWORK_EACH, {}, f))
end)

test("network_passes: named network", function()
	local u = filters()
	local f = { network = "signal-A", mask = -1 }
	assert_true(u.network_passes("signal-A", 1, f))
	assert_false(u.network_passes("signal-B", 1, f))
	-- A station on the network with mask 0 shares no bit with -1.
	assert_false(u.network_passes("signal-A", 0, f))
	assert_false(u.network_passes("signal-A", { ["signal-A"] = 1 }, f))
	assert_false(u.network_passes(nil, 1, f))
	local f6 = { network = "signal-A", mask = 6 }
	assert_true(u.network_passes("signal-A", 2, f6))
	assert_false(u.network_passes("signal-A", 1, f6))
end)

test("network_passes: each-network stations use their per-network mask", function()
	local u = filters()
	local mask = { ["signal-A"] = 2, ["signal-B"] = 4 }
	assert_true(u.network_passes(NETWORK_EACH, mask, { network = "signal-A", mask = -1 }))
	assert_false(u.network_passes(NETWORK_EACH, mask, { network = "signal-C", mask = -1 }))
	assert_false(u.network_passes(NETWORK_EACH, mask, { network = "signal-A", mask = 1 }))
	assert_true(u.network_passes(NETWORK_EACH, mask, { network = "signal-A", mask = 3 }))
	assert_false(u.network_passes(NETWORK_EACH, 2, { network = "signal-A", mask = -1 }))
end)

test("network_passes: mask only, any network", function()
	local u = filters()
	local f = { mask = 4 }
	assert_true(u.network_passes(NETWORK_EACH, { ["signal-A"] = 1, ["signal-B"] = 4 }, f))
	assert_false(u.network_passes(NETWORK_EACH, { ["signal-A"] = 1 }, f))
	assert_true(u.network_passes("signal-A", 6, f))
	assert_false(u.network_passes("signal-A", 1, f))
	assert_false(u.network_passes("signal-A", nil, f))
end)

local function station(over)
	local st = {
		name_lower = "iron ore mine 1",
		surface_index = 1,
		network_name = "signal-A",
		network_mask = 1,
		provided = { ["iron-ore"] = 100 },
		requested = { ["coal"] = { count = -10, threshold = 5, active = true } },
		deliveries = { ["stone"] = 20 },
	}
	for k, v in pairs(over or {}) do st[k] = v end
	return st
end

test("station_passes: surface, plain-text AND terms, network, item", function()
	local u = filters()
	local st = station()
	assert_true(u.station_passes(st, { mask = -1 }))
	assert_false(u.station_passes(st, { mask = -1, surface = 2 }))
	assert_true(u.station_passes(st, { mask = -1, surface = 1 }))
	assert_true(u.station_passes(st, { mask = -1, terms = { "iron", "1" } }))
	assert_false(u.station_passes(st, { mask = -1, terms = { "iron", "copper" } }))
	-- Terms are plain substrings: "o.e" would match "ore" as a pattern.
	assert_false(u.station_passes(st, { mask = -1, terms = { "o.e" } }))
	assert_false(u.station_passes(st, { mask = -1, network = "signal-B" }))
	assert_true(u.station_passes(st, { mask = -1, item = "iron-ore" }))
	assert_true(u.station_passes(st, { mask = -1, item = "coal" }))
	assert_true(u.station_passes(st, { mask = -1, item = "stone" }))
	assert_false(u.station_passes(st, { mask = -1, item = "copper-ore" }))
	assert_true(u.station_passes(st, { mask = -1, item = "copper-ore" }, true))
end)

test("row_passes / station_passes: each row its own network and items, deliveries on row 0, the station chip", function()
	local u = filters()
	local st = station({ id = 9, network_mask = 1, requested = {} })
	st.provided = { ["iron-ore"] = 100 }
	st.sources = {
		{ kind = "station", index = 0, unit = 90, ok = true, priority = 0, network_name = "signal-A", mask = 1,
			provided = { ["iron-ore"] = 60 }, requested = {}, ignored = {} },
		{ kind = "inventory", index = 1, unit = 91, ok = true, priority = 2, network_name = "signal-A", mask = 4,
			provided = { ["iron-ore"] = 40 }, requested = { coal = { count = -10, threshold = 1, active = true } }, ignored = {} },
	}
	local rows = require("inventory_fixtures").rows(st).rows
	assert_eq(#rows, 2)
	local r0, r1 = rows[1], rows[2]
	assert_true(u.row_passes(r0, { mask = -1 }))
	assert_true(u.row_passes(r0, { mask = 1, network = "signal-A" }))
	assert_false(u.row_passes(r1, { mask = 1, network = "signal-A" }))
	assert_true(u.row_passes(r1, { mask = 4 }))
	assert_true(u.station_passes(st, { mask = 4 }), "any row")
	assert_false(u.station_passes(st, { mask = 8 }))
	-- Items: each row its own lists; the station's deliveries (stone) count on its first row only.
	assert_false(u.row_passes(r0, { mask = -1, item = "coal" }))
	assert_true(u.row_passes(r1, { mask = -1, item = "coal" }))
	assert_true(u.row_passes(r0, { mask = -1, item = "stone" }))
	assert_false(u.row_passes(r1, { mask = -1, item = "stone" }))
	assert_true(u.row_passes(r1, { mask = -1, item = "stone" }, true))
	assert_true(u.station_passes(st, { mask = -1, item = "coal" }))
	assert_false(u.station_passes(st, { mask = 1, item = "coal" }), "coal is requested on bit 3 only")
	-- Station-wide fields hold for every row.
	assert_false(u.row_passes(r1, { mask = -1, surface = 2 }))
	assert_false(u.row_passes(r1, { mask = -1, terms = { "copper" } }))
	assert_true(u.row_passes(r1, { mask = -1, station = 9 }))
	assert_false(u.row_passes(r1, { mask = -1, station = 10 }))
	assert_false(u.station_passes(st, { mask = -1, station = 10 }))
	-- An unread inventory (no mask) passes only without a network filter.
	r1.mask = nil
	assert_true(u.row_passes(r1, { mask = -1 }))
	assert_false(u.row_passes(r1, { mask = 4 }))
end)

test("get_filters / filter_signature: the station chip field", function()
	local u = filters()
	assert_nil(u.get_filters({}).station)
	assert_eq(u.get_filters({ search_station = 12 }).station, 12)
	local a = u.filter_signature({ mask = -1 })
	assert_true(a ~= u.filter_signature({ mask = -1, station = 12 }))
end)

local function with_snapshot_stations(stations)
	local snapshot = require("scripts.gui.collector").empty()
	snapshot.stations = stations
	storage.manager = { players = {}, snapshot = snapshot, collect_log = { epoch = 1, base = 0, ids = {} } }
end

test("train_terms_pass: depot, provider and requester names; every term must hit one", function()
	local u = filters()
	with_snapshot_stations({ [1] = { name_lower = "iron mine" }, [2] = { name_lower = "smelter in" } })
	local tr = { depot_name = "Depot North", p_station_id = 1, r_station_id = 2 }
	assert_true(u.train_terms_pass(tr, { "depot" }))
	assert_true(u.train_terms_pass(tr, { "north", "mine" }))
	assert_true(u.train_terms_pass(tr, { "smelter" }))
	assert_false(u.train_terms_pass(tr, { "copper" }))
	assert_false(u.train_terms_pass(tr, { "mine", "copper" }))
	assert_true(u.train_terms_pass(tr, {}))
	assert_false(u.train_terms_pass({ depot_name = "", p_station_id = 9 }, { "x" }))
end)

test("train_passes: surface, network, manifest item, terms", function()
	local u = filters()
	with_snapshot_stations({ [1] = { name_lower = "iron mine" } })
	local tr = {
		surface_index = 1,
		network_name = "signal-A",
		network_mask = 1,
		manifest_hashes = { ["iron-plate"] = 50 },
		depot_name = "Depot",
		p_station_id = 1,
	}
	assert_true(u.train_passes(tr, { mask = -1 }))
	assert_false(u.train_passes(tr, { mask = -1, surface = 2 }))
	assert_false(u.train_passes(tr, { mask = -1, network = "signal-B" }))
	assert_true(u.train_passes(tr, { mask = -1, item = "iron-plate" }))
	assert_false(u.train_passes(tr, { mask = -1, item = "coal" }))
	assert_true(u.train_passes(tr, { mask = -1, item = "coal" }, true))
	assert_true(u.train_passes(tr, { mask = -1, terms = { "mine" } }))
	assert_false(u.train_passes(tr, { mask = -1, terms = { "smelter" } }))
end)

test("set_item_filter: validates the hash, updates the chooser, resets every page", function()
	local u = filters()
	local chooser = H.element({ type = "choose-elem-button" })
	local pd = { page = { stations_tab = 3 }, refs = { manager_item_filter = chooser } }
	u.set_item_filter(pd, "iron-plate|rare")
	assert_eq(pd.search_item, "iron-plate|rare")
	assert_eq(chooser.elem_value, { type = "item", name = "iron-plate", quality = "rare" })
	assert_eq(pd.page, {})
	pd.page.trains_tab = 2
	u.set_item_filter(pd, "bogus")
	assert_nil(pd.search_item)
	assert_nil(chooser.elem_value)
	assert_eq(pd.page, {})
	u.set_item_filter({}, "coal")
end)
