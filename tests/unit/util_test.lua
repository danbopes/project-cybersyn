-- Characterization tests for scripts/gui/util.lua.

local H = require("harness")

local function util()
	return H.load("scripts.gui.util")
end

-- ------------------------------------------------------------------ sprites

test("valid_sprite: the path when drawable, else the fallback, and each path asked once", function()
	local u = util()
	assert_eq(u.valid_sprite("item/iron-ore", "utility/questionmark"), "item/iron-ore")
	assert_eq(u.valid_sprite("item/no-such-thing", "utility/questionmark"), "utility/questionmark")
	assert_eq(u.valid_sprite("item/no-such-thing"), nil)
	assert_eq(u.valid_sprite(nil, "utility/warning_icon"), "utility/warning_icon")
	local real, calls = helpers.is_valid_sprite_path, 0
	helpers.is_valid_sprite_path = function(path) calls = calls + 1 return real(path) end
	u.valid_sprite("fluid/water")
	u.valid_sprite("fluid/water")
	helpers.is_valid_sprite_path = real
	assert_eq(calls, 1)
end)

-- ------------------------------------------------------------------ durations

test("format_duration: below a second, nil and negative read 0s", function()
	local u = util()
	assert_eq(u.format_duration(nil), "0s")
	assert_eq(u.format_duration(-100), "0s")
	assert_eq(u.format_duration(0), "0s")
	assert_eq(u.format_duration(59), "0s")
end)

test("format_duration: seconds, minutes, hours with unpadded fields", function()
	local u = util()
	assert_eq(u.format_duration(60), "1s")
	assert_eq(u.format_duration(90), "1s")
	assert_eq(u.format_duration(3599), "59s")
	assert_eq(u.format_duration(3600), "1m 0s")
	assert_eq(u.format_duration(185 * 60), "3m 5s")
	assert_eq(u.format_duration(3662 * 60), "1h 1m 2s")
	assert_eq(u.format_duration(3600 * 60), "1h 0m 0s")
	-- No day unit: hours keep counting.
	assert_eq(u.format_duration(90000 * 60), "25h 0m 0s")
end)

test("short_duration: two units at most, second unit zero-padded", function()
	local u = util()
	assert_eq(u.short_duration(nil), "0s")
	assert_eq(u.short_duration(-5), "0s")
	assert_eq(u.short_duration(119.9), "1s")
	assert_eq(u.short_duration(42 * 60), "42s")
	assert_eq(u.short_duration(59 * 60), "59s")
	assert_eq(u.short_duration(60 * 60), "1m 00s")
	assert_eq(u.short_duration(185 * 60), "3m 05s")
	assert_eq(u.short_duration(3599 * 60), "59m 59s")
	assert_eq(u.short_duration(3600 * 60), "1h 00m")
	assert_eq(u.short_duration(3900 * 60), "1h 05m")
	assert_eq(u.short_duration(3959 * 60), "1h 05m")
	assert_eq(u.short_duration(86340 * 60), "23h 59m")
	assert_eq(u.short_duration(86400 * 60), "1d 00h")
	assert_eq(u.short_duration(183600 * 60), "2d 03h")
	assert_eq(u.short_duration(1000 * 86400 * 60), "1000d 00h")
end)

-- ------------------------------------------------------------------ search and filters

test("search_terms: lowercase whitespace-split words, nil when empty", function()
	local u = util()
	assert_nil(u.search_terms(nil))
	assert_nil(u.search_terms(""))
	assert_nil(u.search_terms("  \t "))
	assert_eq(u.search_terms("Iron  Ore\tMINE"), { "iron", "ore", "mine" })
	assert_eq(u.search_terms(" a.b (c) "), { "a.b", "(c)" })
end)

test("set_search_query: empty string clears, whitespace-only keeps the query but no terms", function()
	local u = util()
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
	local u = util()
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
	local u = util()
	local pd = { search_query = "A b" }
	local f = u.get_filters(pd)
	assert_eq(f.terms, { "a", "b" })
	assert_same(pd.search_terms, f.terms)
end)

test("filters_active: each field and ignore_item", function()
	local u = util()
	assert_false(u.filters_active({ mask = -1 }))
	assert_true(u.filters_active({ mask = -1, item = "coal" }))
	assert_false(u.filters_active({ mask = -1, item = "coal" }, true))
	assert_true(u.filters_active({ mask = 0 }))
	assert_true(u.filters_active({ mask = -1, terms = { "a" } }))
	assert_true(u.filters_active({ mask = -1, network = "signal-A" }))
	assert_true(u.filters_active({ mask = -1, surface = 1 }))
end)

test("network_passes: no network filter and mask -1 passes everything", function()
	local u = util()
	local f = { mask = -1 }
	assert_true(u.network_passes(nil, nil, f))
	assert_true(u.network_passes("signal-A", 0, f))
	assert_true(u.network_passes(NETWORK_EACH, {}, f))
end)

test("network_passes: named network", function()
	local u = util()
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
	local u = util()
	local mask = { ["signal-A"] = 2, ["signal-B"] = 4 }
	assert_true(u.network_passes(NETWORK_EACH, mask, { network = "signal-A", mask = -1 }))
	assert_false(u.network_passes(NETWORK_EACH, mask, { network = "signal-C", mask = -1 }))
	assert_false(u.network_passes(NETWORK_EACH, mask, { network = "signal-A", mask = 1 }))
	assert_true(u.network_passes(NETWORK_EACH, mask, { network = "signal-A", mask = 3 }))
	assert_false(u.network_passes(NETWORK_EACH, 2, { network = "signal-A", mask = -1 }))
end)

test("network_passes: mask only, any network", function()
	local u = util()
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
	local u = util()
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
	local u = util()
	local collector = H.load("scripts.gui.collector")
	local st = station({ id = 9, network_mask = 1, requested = {} })
	st.provided = { ["iron-ore"] = 100 }
	st.sources = {
		{ kind = "station", index = 0, unit = 90, ok = true, priority = 0, network_name = "signal-A", mask = 1,
			provided = { ["iron-ore"] = 60 }, requested = {}, ignored = {} },
		{ kind = "inventory", index = 1, unit = 91, ok = true, priority = 2, network_name = "signal-A", mask = 4,
			provided = { ["iron-ore"] = 40 }, requested = { coal = { count = -10, threshold = 1, active = true } }, ignored = {} },
	}
	local rows = collector.inventories(st)
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
	local u = util()
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
	local u = util()
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
	local u = util()
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

-- ------------------------------------------------------------------ sorting

local function ids(rows)
	local out = {}
	for i, r in ipairs(rows) do out[i] = r.id end
	return out
end

test("sort_by: ascending and descending, nil keys last, ties by input position", function()
	local u = util()
	local function rows()
		return {
			{ k = 3, id = "a" }, { k = 1, id = "b" }, { k = 3, id = "c" }, { k = nil, id = "d" },
			{ k = 2, id = "e" }, { k = nil, id = "f" },
		}
	end
	local key = function(r) return r.k end
	local asc = rows()
	assert_same(u.sort_by(asc, key, true), asc)
	assert_eq(ids(asc), { "b", "e", "a", "c", "d", "f" })
	local desc = u.sort_by(rows(), key, false)
	assert_eq(ids(desc), { "a", "c", "e", "b", "d", "f" })
end)

test("sort_by: stable for many equal keys", function()
	local u = util()
	local rows = {}
	for i = 1, 60 do rows[i] = { k = i % 2, id = i } end
	u.sort_by(rows, function(r) return r.k end, true)
	local expected = {}
	for i = 2, 60, 2 do expected[#expected + 1] = i end
	for i = 1, 59, 2 do expected[#expected + 1] = i end
	assert_eq(ids(rows), expected)
end)

test("sort_by: tiebreak_fn ascending in both directions; string keys compare bytewise", function()
	local u = util()
	local function rows()
		return { { k = 1, id = "z" }, { k = 1, id = "m" }, { k = 0, id = "q" }, { k = 1, id = "a" } }
	end
	local key = function(r) return r.k end
	local tb = function(r) return r.id end
	assert_eq(ids(u.sort_by(rows(), key, true, tb)), { "q", "a", "m", "z" })
	assert_eq(ids(u.sort_by(rows(), key, false, tb)), { "a", "m", "z", "q" })
	local names = { { id = "b" }, { id = "a" }, { id = "C" } }
	assert_eq(ids(u.sort_by(names, function(r) return r.id end, true)), { "C", "a", "b" })
end)

test("get_sort: creates the default once; later defaults are ignored", function()
	local u = util()
	local pd = {}
	local c, a = u.get_sort(pd, "stations_tab", "name")
	assert_eq(c, "name")
	assert_true(a)
	assert_eq(pd.sort, { stations_tab = { column = "name", ascending = true } })
	c, a = u.get_sort(pd, "stations_tab", "wait")
	assert_eq(c, "name")
	assert_true(a)
end)

test("set_sort: same column toggles, new column ascending, explicit direction wins", function()
	local u = util()
	local pd = {}
	u.set_sort(pd, "stations_tab", "name")
	assert_eq(pd.sort.stations_tab, { column = "name", ascending = true })
	u.set_sort(pd, "stations_tab", "name")
	assert_eq(pd.sort.stations_tab, { column = "name", ascending = false })
	u.set_sort(pd, "stations_tab", "name")
	assert_eq(pd.sort.stations_tab, { column = "name", ascending = true })
	u.set_sort(pd, "stations_tab", "wait")
	assert_eq(pd.sort.stations_tab, { column = "wait", ascending = true })
	u.set_sort(pd, "stations_tab", "wait", true)
	assert_eq(pd.sort.stations_tab, { column = "wait", ascending = true })
	u.set_sort(pd, "stations_tab", "name", false)
	assert_eq(pd.sort.stations_tab, { column = "name", ascending = false })
	-- get_sort's implicit default counts as the active column, so the first click flips it.
	local pd2 = {}
	u.get_sort(pd2, "trains_tab", "id")
	u.set_sort(pd2, "trains_tab", "id")
	assert_eq(pd2.sort.trains_tab, { column = "id", ascending = false })
end)

test("set_sort: resets only that tab's page", function()
	local u = util()
	local pd = { page = { stations_tab = 3, trains_tab = 2 } }
	u.set_sort(pd, "stations_tab", "name")
	assert_eq(pd.page, { trains_tab = 2 })
	local pd2 = {}
	u.set_sort(pd2, "stations_tab", "name")
	assert_nil(pd2.page)
end)

-- ------------------------------------------------------------------ paging

test("page_size: the constant bound without a window layout", function()
	local u = util()
	assert_eq(u.page_size({ player_index = 2 }), 200)
	assert_eq(u.MAX_PAGE_SIZE, 200)
end)

test("page_size: a tab gets the window's rows, capped by the bound", function()
	local u = util()
	local pd = { layout = { rows_by_tab = { stations_tab = 18, trains_tab = 12, big_tab = 500 } } }
	assert_eq(u.page_size(pd, "stations_tab"), 18)
	assert_eq(u.page_size(pd, "trains_tab"), 12)
	assert_eq(u.page_size(pd, "big_tab"), 200)
	assert_eq(u.page_size(pd, "other_tab"), 200)
	assert_eq(u.page_size(pd), 200)
	assert_eq({ u.paginate({ layout = pd.layout }, "stations_tab", 40) }, { 1, 18, 1, 3 })
end)

test("paginate: slices, clamping and stored page", function()
	local u = util()
	local pd = { layout = { rows_by_tab = { t = 10 } } }
	assert_eq({ u.paginate(pd, "t", 0) }, { 1, 0, 1, 1 })
	assert_eq({ u.paginate(pd, "t", 25) }, { 1, 10, 1, 3 })
	pd.page.t = 3
	assert_eq({ u.paginate(pd, "t", 25) }, { 21, 25, 3, 3 })
	pd.page.t = 5
	assert_eq({ u.paginate(pd, "t", 25) }, { 21, 25, 3, 3 })
	assert_eq(pd.page.t, 3)
	pd.page.t = 0
	assert_eq({ u.paginate(pd, "t", 25) }, { 1, 10, 1, 3 })
	pd.page.t = -2
	assert_eq({ u.paginate(pd, "t", 30) }, { 1, 10, 1, 3 })
	pd.page.t = 3
	assert_eq({ u.paginate(pd, "t", 30) }, { 21, 30, 3, 3 })
	pd.page.t = math.huge
	assert_eq({ u.paginate(pd, "t", 10) }, { 1, 10, 1, 1 })
	-- Shrinking the list pulls the page back.
	pd.page.t = 3
	assert_eq({ u.paginate(pd, "t", 12) }, { 11, 12, 2, 2 })
	assert_eq(pd.page.t, 2)
end)

local function pager_refs(tab)
	local refs = { [tab .. "_pager_label"] = H.element({ type = "label" }) }
	for _, k in ipairs({ "first", "prev", "next", "last" }) do
		refs[tab .. "_pager_" .. k] = H.element({ type = "button" })
	end
	return refs
end

test("paginate: pager caption and button states", function()
	local u = util()
	local refs = pager_refs("t")
	local pd = { refs = refs, page = { t = 2 } }
	u.paginate(pd, "t", 2500, 1000)
	assert_eq(refs.t_pager_label.caption, { "cybersyn-gui.pager-range", "1,001", "2,000", "2,500" })
	assert_true(refs.t_pager_first.enabled)
	assert_true(refs.t_pager_prev.enabled)
	assert_true(refs.t_pager_next.enabled)
	assert_true(refs.t_pager_last.enabled)
	pd.page.t = 1
	u.paginate(pd, "t", 2500, 1000)
	assert_false(refs.t_pager_first.enabled)
	assert_false(refs.t_pager_prev.enabled)
	assert_true(refs.t_pager_next.enabled)
	u.paginate(pd, "t", 0, 1000)
	assert_eq(refs.t_pager_label.caption, { "cybersyn-gui.pager-empty" })
	assert_false(refs.t_pager_next.enabled)
	assert_false(refs.t_pager_last.enabled)
	refs.t_pager_label.valid = false
	refs.t_pager_next.enabled = "untouched"
	u.paginate(pd, "t", 2500, 1000)
	assert_eq(refs.t_pager_next.enabled, "untouched")
end)

test("reset_page and reset_pages", function()
	local u = util()
	local pd = {}
	u.reset_page(pd, "t")
	assert_nil(pd.page)
	pd.page = { t = 2, u = 3 }
	u.reset_page(pd, "t")
	assert_eq(pd.page, { u = 3 })
	u.reset_pages(pd)
	assert_eq(pd.page, {})
end)

-- ------------------------------------------------------------------ tabs, gui_state, hover

test("select_tab: finds the tab by element name and syncs selected_tab", function()
	local u = util()
	assert_false(u.select_tab({}, "stations_tab"))
	local pane = {
		valid = true,
		selected_tab_index = 1,
		tabs = { { tab = { name = "manager_overview_tab" } }, { tab = { name = "manager_stations_tab" } } },
	}
	local pd = { refs = { manager_tabbed_pane = pane }, selected_tab = "overview_tab" }
	assert_true(u.select_tab(pd, "stations_tab"))
	assert_eq(pane.selected_tab_index, 2)
	assert_eq(pd.selected_tab, "stations_tab")
	assert_false(u.select_tab(pd, "log_tab"))
	assert_eq(pane.selected_tab_index, 2)
	assert_eq(pd.selected_tab, "stations_tab")
	pane.valid = false
	assert_false(u.select_tab(pd, "overview_tab"))
end)

test("gui_state: created on demand and stable", function()
	local u = util()
	local pd = {}
	local s = u.gui_state(pd, "stations")
	assert_eq(s, {})
	assert_same(u.gui_state(pd, "stations"), s)
	assert_same(pd.gui_state.stations, s)
	assert_true(u.gui_state(pd, "trains") ~= s)
end)

test("hold_active: scope match within HOVER_HOLD_TICKS", function()
	local u = util()
	assert_eq(u.HOVER_HOLD_TICKS, 600)
	game.tick = 1000
	local pd = { hover = { tick = 500, scope = "rows", index = 3 } }
	assert_true(u.hold_active(pd, "rows"))
	assert_false(u.hold_active(pd, "other"))
	game.tick = 1099
	assert_true(u.hold_active(pd, "rows"))
	game.tick = 1100
	assert_false(u.hold_active(pd, "rows"))
	assert_false(u.hold_active({}, "rows"))
end)

test("with_hover/hoverable: function handler becomes on_gui_click", function()
	local u = util()
	local click = function() end
	local h = u.with_hover(click)
	assert_same(h[defines.events.on_gui_click], click)
	assert_same(h[defines.events.on_gui_hover], u.handle.hover_enter)
	assert_same(h[defines.events.on_gui_leave], u.handle.hover_leave)
	local def = u.hoverable({ type = "button", tags = { a = 1 } }, "rows")
	assert_true(def.raise_hover_events)
	assert_eq(def.tags, { a = 1, hover_scope = "rows" })
	assert_same(def.handler[defines.events.on_gui_hover], u.handle.hover_enter)
	assert_nil(def.handler[defines.events.on_gui_click])
end)

test("hover_enter/hover_leave/touch_hover keep one hover record per player", function()
	local u = util()
	game.tick = 70
	local parent = H.element({ name = "rows" })
	local elem = parent.add({ type = "button" })
	local pd = {}
	u.handle.hover_enter(nil, pd, nil, { element = elem })
	assert_eq(pd.hover, { tick = 70, scope = "rows", index = 1 })
	local other = parent.add({ type = "button" })
	u.handle.hover_leave(nil, pd, nil, { element = other })
	assert_not_nil(pd.hover)
	u.handle.hover_leave(nil, pd, nil, { element = elem })
	assert_nil(pd.hover)

	storage.manager = { players = { [1] = pd } }
	local tagged = parent.add({ type = "button", tags = { hover_scope = "rows" } })
	game.tick = 80
	u.touch_hover({ element = tagged, player_index = 1 })
	assert_eq(pd.hover, { tick = 80, scope = "rows", index = 3 })
	game.tick = 90
	u.touch_hover({ element = tagged, player_index = 1 })
	assert_eq(pd.hover.tick, 90)
	u.touch_hover({ element = elem, player_index = 1 })
	assert_eq(pd.hover.tick, 90)
end)

test("switch_opened: the guard holds only while the move runs, per player", function()
	local u = util()
	local inside, other
	u.switch_opened({ index = 1 }, function()
		inside = u.switching(1)
		other = u.switching(2)
	end)
	assert_true(inside)
	assert_false(other)
	assert_false(u.switching(1))
end)

-- ------------------------------------------------------------------ items and signals

test("item_rank: item_order plus quality fraction, unknown items last", function()
	local u = util()
	storage.manager = { item_order = { ["iron-plate"] = 5, ["copper-plate"] = 7 } }
	assert_eq(u.item_rank("iron-plate"), 5)
	assert_eq(u.item_rank("iron-plate|rare"), 5 + 3 / 32)
	assert_eq(u.item_rank("iron-plate|legendary"), 5 + 6 / 32)
	assert_eq(u.item_rank("iron-plate|normal"), 5 + 1 / 32)
	assert_eq(u.item_rank("iron-plate|gone"), 5 + 16 / 32)
	assert_eq(u.item_rank("unobtainium"), 1e9)
end)

test("item_rank: cached per Lua state, so a later item_order change is not seen", function()
	local u = util()
	storage.manager = { item_order = { ["iron-plate"] = 5 } }
	assert_eq(u.item_rank("iron-plate"), 5)
	storage.manager.item_order["iron-plate"] = 9
	assert_eq(u.item_rank("iron-plate"), 5)
	local u2 = util()
	assert_eq(u2.item_rank("iron-plate"), 9)
	storage.manager = nil
	assert_eq(util().item_rank("iron-plate"), 1e9)
end)

test("hashes_in_item_order: rank, then hash string", function()
	local u = util()
	storage.manager = { item_order = { ["iron-plate"] = 5, ["copper-plate"] = 7 } }
	local hashes = { ["copper-plate"] = 1, ["iron-plate"] = 1, ["iron-plate|rare"] = 1, zzz = 1, aaa = 1 }
	assert_eq(u.hashes_in_item_order(hashes), { "iron-plate", "iron-plate|rare", "copper-plate", "aaa", "zzz" })
	assert_eq(u.hashes_in_item_order({}), {})
end)

test("signal_hash_valid: prototype lookup and quality check", function()
	local u = util()
	assert_false(u.signal_hash_valid(nil))
	assert_false(u.signal_hash_valid(5))
	assert_true(u.signal_hash_valid("iron-plate"))
	assert_true(u.signal_hash_valid("water"))
	assert_true(u.signal_hash_valid("signal-A"))
	assert_true(u.signal_hash_valid("cybersyn-combinator"))
	assert_true(u.signal_hash_valid("iron-plate|rare"))
	assert_false(u.signal_hash_valid("iron-plate|bogus"))
	assert_false(u.signal_hash_valid("nonexistent"))
	assert_false(u.signal_hash_valid("nonexistent|rare"))
	-- A quality name is itself a valid signal.
	assert_true(u.signal_hash_valid("rare"))
end)

test("signalid_from_name / signalid_from_hash: type by prototype group", function()
	local u = util()
	assert_eq(u.signalid_from_name("iron-plate"), { type = "item", name = "iron-plate" })
	assert_eq(u.signalid_from_name("water", "rare"), { type = "fluid", name = "water", quality = "rare" })
	assert_eq(u.signalid_from_name("signal-A"), { type = "virtual", name = "signal-A" })
	assert_eq(u.signalid_from_name("cybersyn-combinator"), { type = "entity", name = "cybersyn-combinator" })
	-- Unknown names fall through to "quality" rather than failing.
	assert_eq(u.signalid_from_name("nonexistent"), { type = "quality", name = "nonexistent" })
	assert_eq(u.signalid_from_hash("iron-plate|rare"), { type = "item", name = "iron-plate", quality = "rare" })
	assert_eq(u.signalid_from_hash("crude-oil"), { type = "fluid", name = "crude-oil" })
end)

test("item_sprite_and_tooltip", function()
	local u = util()
	local sprite, quality, tooltip, signal = u.item_sprite_and_tooltip("iron-plate|rare")
	assert_eq(sprite, "item/iron-plate")
	assert_eq(quality, "rare")
	assert_eq(tooltip, { "", "[item=iron-plate,quality=rare]", " ", { "item-name.iron-plate" } })
	assert_eq(signal, { type = "item", name = "iron-plate", quality = "rare" })
	assert_eq(u.item_sprite_and_tooltip("water"), "fluid/water")
	assert_nil(u.item_sprite_and_tooltip("nonexistent"))
	assert_nil(u.item_sprite_and_tooltip("iron-plate|gone"))
end)

test("set_item_filter: validates the hash, updates the chooser, resets every page", function()
	local u = util()
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

-- ------------------------------------------------------------------ sync_children

local function entry(key, log, sig)
	return {
		key = key,
		sig = sig,
		build = function() return { type = "label", name = key, caption = key } end,
		update = function(elem, _, index)
			log[#log + 1] = key .. "@" .. index
			elem.updated_index = index
		end,
	}
end

local function child_names(parent)
	local out = {}
	for i, c in ipairs(parent.children) do out[i] = c.name end
	return out
end

local function entries_for(keys, log, sigs)
	local out = {}
	for i, k in ipairs(keys) do out[i] = entry(k, log, sigs and sigs[i]) end
	return out
end

test("sync_children: build, update in place, sig skip", function()
	local u = util()
	local parent = H.element({ name = "list" })
	local state, log = {}, {}
	assert_eq(u.sync_children(parent, entries_for({ "a", "b" }, log, { 1, 1 }), state), "rebuilt")
	assert_eq(child_names(parent), { "a", "b" })
	assert_eq(log, {})
	assert_eq(state.keys, { "a", "b" })
	assert_eq(state.sigs, { a = 1, b = 1 })
	assert_eq(u.sync_children(parent, entries_for({ "a", "b" }, log, { 1, 2 }), state), "updated")
	assert_eq(log, { "b@2" })
	assert_eq(state.sigs, { a = 1, b = 2 })
	assert_nil(state.dirty)
end)

test("sync_children: hold keeps structure and marks dirty", function()
	local u = util()
	local parent = H.element({ name = "list" })
	local state, log = {}, {}
	u.sync_children(parent, entries_for({ "a", "b", "c" }, log), state)
	assert_eq(u.sync_children(parent, entries_for({ "c", "a" }, log), state, true), "held")
	assert_eq(child_names(parent), { "a", "b", "c" })
	-- Survivors get the update with their new index.
	assert_eq(log, { "a@2", "c@1" })
	assert_true(state.dirty)
	assert_eq(state.keys, { "a", "b", "c" })
end)

test("sync_children: unheld change keeps the common prefix and rebuilds the rest", function()
	local u = util()
	local parent = H.element({ name = "list" })
	local state, log = {}, {}
	u.sync_children(parent, entries_for({ "a", "b", "c" }, log), state)
	H.gui_log = {}
	assert_eq(u.sync_children(parent, entries_for({ "a", "c", "d" }, log), state), "rebuilt")
	assert_eq(child_names(parent), { "a", "c", "d" })
	assert_eq(log, { "a@1" })
	assert_eq(H.count_ops("destroy"), 2)
	assert_eq(H.count_ops("add"), 2)
	H.gui_log = {}
	assert_eq(u.sync_children(parent, entries_for({ "x" }, log), state), "rebuilt")
	assert_eq(H.count_ops("clear"), 1)
	assert_eq(child_names(parent), { "x" })
end)

test("sync_children: movable swaps survivors instead of rebuilding", function()
	local u = util()
	local parent = H.element({ name = "list" })
	local state, log = {}, {}
	u.sync_children(parent, entries_for({ "a", "b", "c" }, log), state)
	H.gui_log = {}
	assert_eq(u.sync_children(parent, entries_for({ "c", "a", "b" }, log), state, false, true), "rebuilt")
	assert_eq(child_names(parent), { "c", "a", "b" })
	assert_eq(H.count_ops("add"), 0)
	assert_eq(H.count_ops("destroy"), 0)
	assert_eq(log, { "c@1", "a@2", "b@3" })
	H.gui_log = {}
	log = {}
	assert_eq(u.sync_children(parent, entries_for({ "c", "d" }, log), state, false, true), "rebuilt")
	assert_eq(child_names(parent), { "c", "d" })
	assert_eq(H.count_ops("add"), 1)
	assert_eq(H.count_ops("destroy"), 2)
	assert_eq(log, { "c@1" })
end)

test("sync_table_rows: header cells untouched, rows rebuilt from the first difference", function()
	local u = util()
	local tbl = H.element({ name = "tbl" })
	tbl.add({ name = "h1" })
	tbl.add({ name = "h2" })
	local function row(key, log)
		return {
			key = key,
			build = function() return { { type = "label", name = key .. "1" }, { type = "label", name = key .. "2" } } end,
			update = function(cells, _, index) log[#log + 1] = key .. "@" .. index .. ":" .. cells[1].name end,
		}
	end
	local state, log = {}, {}
	assert_eq(u.sync_table_rows(tbl, 2, 2, { row("a", log), row("b", log) }, state), "rebuilt")
	assert_eq(child_names(tbl), { "h1", "h2", "a1", "a2", "b1", "b2" })
	assert_eq(u.sync_table_rows(tbl, 2, 2, { row("a", log), row("b", log) }, state), "updated")
	assert_eq(log, { "a@1:a1", "b@2:b1" })
	log = {}
	assert_eq(u.sync_table_rows(tbl, 2, 2, { row("a", log), row("c", log) }, state), "rebuilt")
	assert_eq(child_names(tbl), { "h1", "h2", "a1", "a2", "c1", "c2" })
	assert_eq(log, { "a@1:a1" })
end)

test("module registers its handlers with flib under the cybersyn_util prefix", function()
	util()
	assert_not_nil(H.flib_gui.handlers["cybersyn_util:pager_click"])
	assert_not_nil(H.flib_gui.handlers["cybersyn_util:hover_enter"])
end)

-- ------------------------------------------------------------------ sync_children: moves, reuse, guards

test("sync_children: movable insertion updates shifted survivors although their sigs did not change", function()
	local u = util()
	local parent = H.element({ name = "list" })
	local state, log = {}, {}
	u.sync_children(parent, entries_for({ "a", "b", "c" }, log, { "s", "s", "s" }), state)
	H.gui_log = {}
	local result = u.sync_children(parent, entries_for({ "n", "a", "b", "c" }, log, { "s", "s", "s", "s" }), state, false, true)
	assert_eq(result, "rebuilt")
	assert_eq(child_names(parent), { "n", "a", "b", "c" })
	assert_eq(H.count_ops("add"), 1)
	assert_eq(H.count_ops("destroy"), 0)
	assert_eq(log, { "a@2", "b@3", "c@4" })
	assert_eq(parent.children[4].updated_index, 4)
	assert_eq(state.sigs, { n = "s", a = "s", b = "s", c = "s" })
	-- Same order again: every sig matches, nothing runs.
	log[#log + 1] = "|"
	assert_eq(u.sync_children(parent, entries_for({ "n", "a", "b", "c" }, log, { "s", "s", "s", "s" }), state, false, true), "updated")
	assert_eq(log, { "a@2", "b@3", "c@4", "|" })
end)

test("sync_children: movable hands a vanished key's child to a new key through reuse", function()
	local u = util()
	local parent = H.element({ name = "list" })
	local state, log = {}, {}
	u.sync_children(parent, entries_for({ "a", "b", "c" }, log), state)
	local b_elem = parent.children[2]
	local entries = entries_for({ "a", "x", "c" }, log)
	entries[2].reuse = function(elem, old_key)
		log[#log + 1] = "reuse " .. old_key .. "->x"
		elem.name = "x"
	end
	H.gui_log = {}
	assert_eq(u.sync_children(parent, entries, state, false, true), "rebuilt")
	assert_eq(H.count_ops("add"), 0)
	assert_eq(H.count_ops("destroy"), 0)
	assert_same(parent.children[2], b_elem)
	assert_eq(child_names(parent), { "a", "x", "c" })
	assert_eq(log, { "a@1", "reuse b->x", "x@2", "c@3" })
	assert_eq(state.keys, { "a", "x", "c" })
	-- A freed child elsewhere in the list is swapped into place before it is reused.
	entries = entries_for({ "z", "a", "c" }, log)
	entries[1].reuse = function(elem, old_key)
		log[#log + 1] = "reuse " .. old_key .. "->z"
		elem.name = "z"
	end
	H.gui_log = {}
	for i = #log, 1, -1 do log[i] = nil end
	assert_eq(u.sync_children(parent, entries, state, false, true), "rebuilt")
	assert_eq(child_names(parent), { "z", "a", "c" })
	assert_same(parent.children[1], b_elem)
	assert_eq(H.count_ops("add"), 0)
	assert_eq(H.count_ops("destroy"), 0)
	assert_eq(log, { "reuse x->z", "z@1", "a@2", "c@3" })
	-- An entry without reuse still gets a fresh child, and the vanished one is destroyed.
	H.gui_log = {}
	log = {}
	assert_eq(u.sync_children(parent, entries_for({ "a", "y", "c" }, log), state, false, true), "rebuilt")
	assert_eq(child_names(parent), { "a", "y", "c" })
	assert_eq(H.count_ops("add"), 1)
	assert_eq(H.count_ops("destroy"), 1)
	assert_false(b_elem.valid)
end)

test("sync_children: children changed behind its back force a full rebuild", function()
	local u = util()
	local parent = H.element({ name = "list" })
	local state, log = {}, {}
	u.sync_children(parent, entries_for({ "a", "b", "c" }, log, { 1, 1, 1 }), state)
	parent.children[2].destroy()
	H.gui_log = {}
	assert_eq(u.sync_children(parent, entries_for({ "a", "b", "c" }, log, { 1, 1, 1 }), state), "rebuilt")
	assert_eq(H.count_ops("clear"), 1)
	assert_eq(H.count_ops("add"), 3)
	assert_eq(child_names(parent), { "a", "b", "c" })
	assert_eq(log, {})
	assert_eq(state.sigs, { a = 1, b = 1, c = 1 })
	parent.children[3].destroy()
	assert_eq(u.sync_children(parent, entries_for({ "c", "a", "b" }, log), state, true), "rebuilt")
	assert_eq(child_names(parent), { "c", "a", "b" })
end)

test("sync_children options: a write budget defers updates and keeps their old sigs", function()
	local u = util()
	local parent = H.element({ name = "list" })
	local state, log = {}, {}
	u.sync_children(parent, entries_for({ "a", "b", "c" }, log, { 1, 1, 1 }), state)
	local opts = { budget = { n = 2 } }
	assert_eq(u.sync_children(parent, entries_for({ "a", "b", "c" }, log, { 2, 2, 2 }), state, false, opts), "updated")
	assert_eq(log, { "a@1", "b@2" })
	assert_true(opts.deferred)
	assert_eq(state.sigs, { a = 2, b = 2, c = 1 })
	opts = { budget = { n = 2 } }
	u.sync_children(parent, entries_for({ "a", "b", "c" }, log, { 2, 2, 2 }), state, false, opts)
	assert_eq(log, { "a@1", "b@2", "c@3" })
	assert_nil(opts.deferred)
end)

test("sync_children options: after sees every placed child, fresh when built or reused; gone sees destroyed keys", function()
	local u = util()
	local parent = H.element({ name = "list" })
	local state, seen, gone = {}, {}, {}
	local opts = {
		elems = true,
		build = function(e) return { type = "label", name = e.key } end,
		reuse = function(elem, _, e) elem.name = e.key end,
		after = function(elem, e, i, fresh) seen[#seen + 1] = e.key .. "@" .. i .. (fresh and "+" or "") .. elem.name end,
		gone = function(key) gone[#gone + 1] = key end,
	}
	local function plain(keys)
		local out = {}
		for i, k in ipairs(keys) do out[i] = { key = k } end
		return out
	end
	u.sync_children(parent, plain({ "a", "b" }), state, false, opts)
	assert_eq(seen, { "a@1+a", "b@2+b" })
	assert_eq(#state.elems, 2)
	seen = {}
	assert_eq(u.sync_children(parent, plain({ "a", "b" }), state, false, opts), "updated")
	assert_eq(seen, { "a@1a", "b@2b" })
	seen = {}
	H.gui_log = {}
	u.sync_children(parent, plain({ "x", "a" }), state, false, opts)
	assert_eq(child_names(parent), { "x", "a" })
	assert_eq(H.count_ops("add"), 0)
	assert_eq(seen, { "x@1+x", "a@2a" })
	u.sync_children(parent, plain({ "a" }), state, false, opts)
	assert_eq(gone, { "x" })
	assert_eq(state.keys, { "a" })
	assert_same(state.elems[1], parent.children[1])
end)

test("sync_children options: a build budget stops at the first build over it and drops the rest", function()
	local u = util()
	local parent = H.element({ name = "list" })
	local state, log = {}, {}
	u.sync_children(parent, entries_for({ "a", "b", "c", "d" }, log), state, false, { build_budget = 2 })
	assert_eq(child_names(parent), { "a", "b" })
	assert_eq(state.keys, { "a", "b" })
	u.sync_children(parent, entries_for({ "a", "b", "c", "d" }, log), state, false, { build_budget = 2 })
	assert_eq(child_names(parent), { "a", "b", "c", "d" })
	-- A new key at the top over the budget: everything below it waits, survivors included.
	u.sync_children(parent, entries_for({ "n", "a", "b", "c", "d" }, log), state, false, { build_budget = 0 })
	assert_eq(child_names(parent), {})
	assert_eq(state.keys, {})
end)

test("sync_children options: destroy_vanished never reuses, rebuild_mostly_new recreates a mostly new set", function()
	local u = util()
	local parent = H.element({ name = "list" })
	local state, log = {}, {}
	local opts = { destroy_vanished = true, rebuild_mostly_new = true, moved_keeps_sig = true }
	u.sync_children(parent, entries_for({ "a", "b", "c" }, log, { 1, 1, 1 }), state)
	local entries = entries_for({ "c", "x", "a" }, log, { 1, 1, 1 })
	entries[2].reuse = function() error("reused") end
	H.gui_log = {}
	assert_eq(u.sync_children(parent, entries, state, false, opts), "rebuilt")
	assert_eq(child_names(parent), { "c", "x", "a" })
	assert_eq(H.count_ops("destroy"), 1)
	assert_eq(H.count_ops("add"), 1)
	assert_eq(log, {}, "moved children keep their sigs")
	H.gui_log = {}
	assert_eq(u.sync_children(parent, entries_for({ "a", "p", "q" }, log, { 1, 1, 1 }), state, false, opts), "rebuilt")
	assert_eq(child_names(parent), { "a", "p", "q" })
	assert_eq(H.count_ops("clear"), 1)
	assert_eq(H.count_ops("add"), 3)
	assert_eq(state.sigs, { a = 1, p = 1, q = 1 })
end)

local function table_row(key, log)
	return {
		key = key,
		build = function() return { { type = "label", name = key .. "1" }, { type = "label", name = key .. "2" } } end,
		update = function(cells, _, index) log[#log + 1] = key .. "@" .. index .. ":" .. cells[1].name .. "," .. cells[2].name end,
	}
end

local function table_rows(keys, log)
	local out = {}
	for i, k in ipairs(keys) do out[i] = table_row(k, log) end
	return out
end

local function header_table()
	local tbl = H.element({ name = "tbl" })
	tbl.add({ name = "h1" })
	tbl.add({ name = "h2" })
	return tbl
end

test("sync_table_rows: hold keeps the rows, updates survivors from their old cells and marks dirty", function()
	local u = util()
	local tbl = header_table()
	local state, log = {}, {}
	u.sync_table_rows(tbl, 2, 2, table_rows({ "a", "b", "c" }, log), state)
	H.gui_log = {}
	assert_eq(u.sync_table_rows(tbl, 2, 2, table_rows({ "c", "a" }, log), state, true), "held")
	assert_true(state.dirty)
	assert_eq(state.keys, { "a", "b", "c" })
	assert_eq(child_names(tbl), { "h1", "h2", "a1", "a2", "b1", "b2", "c1", "c2" })
	assert_eq(#H.gui_log, 0)
	assert_eq(log, { "a@2:a1,a2", "c@1:c1,c2" })
	log = {}
	assert_eq(u.sync_table_rows(tbl, 2, 2, table_rows({ "c", "a" }, log), state), "rebuilt")
	assert_nil(state.dirty)
	assert_eq(child_names(tbl), { "h1", "h2", "c1", "c2", "a1", "a2" })
end)

test("sync_table_rows: cells changed behind its back force a rebuild below the header", function()
	local u = util()
	local tbl = header_table()
	local state, log = {}, {}
	u.sync_table_rows(tbl, 2, 2, table_rows({ "a", "b" }, log), state)
	tbl.children[4].destroy()
	assert_eq(u.sync_table_rows(tbl, 2, 2, table_rows({ "a", "b" }, log), state), "rebuilt")
	assert_eq(child_names(tbl), { "h1", "h2", "a1", "a2", "b1", "b2" })
	assert_eq(log, {})
end)

test("sync_table_rows: rows that can rebind are rewritten in place past the first difference, not rebuilt", function()
	local u = util()
	local tbl = header_table()
	local state, log = {}, {}
	local function rows(keys)
		local out = table_rows(keys, log)
		for _, e in ipairs(out) do
			e.rebind = function(cells, _, index) log[#log + 1] = "rebind " .. e.key .. "@" .. index .. ":" .. cells[1].name end
		end
		return out
	end
	u.sync_table_rows(tbl, 2, 2, rows({ "a", "b", "c" }), state)
	H.gui_log = {}
	log = {}
	-- "b" left: "c" takes b's elements, the last row's go.
	assert_eq(u.sync_table_rows(tbl, 2, 2, rows({ "a", "c" }), state), "rebuilt")
	assert_eq(log, { "a@1:a1,a2", "rebind c@2:b1" })
	assert_eq(child_names(tbl), { "h1", "h2", "a1", "a2", "b1", "b2" })
	assert_eq(H.count_ops("add"), 0)
	assert_eq(H.count_ops("destroy"), 2)
	assert_eq(state.keys, { "a", "c" })
	-- One more row than before: the new last one is built.
	H.gui_log = {}
	log = {}
	u.sync_table_rows(tbl, 2, 2, rows({ "a", "c", "d" }), state)
	assert_eq(H.count_ops("add"), 2)
	assert_eq(log, { "a@1:a1,a2", "c@2:b1,b2" })
end)

-- ------------------------------------------------------------------ pager, sort header

test("pager_click: steps, shift steps of 10, clamps at 1, last and first", function()
	local u = util()
	local calls = 0
	u.set_rerender(function() calls = calls + 1 end)
	local pd = {}
	local function click(action, shift, tab)
		u.handle.pager_click(nil, pd, nil, { element = { tags = { pager_tab = tab or "t", pager_action = action } }, shift = shift })
	end
	click("next")
	assert_eq(pd.page.t, 2)
	click("next", true)
	assert_eq(pd.page.t, 12)
	click("prev")
	assert_eq(pd.page.t, 11)
	click("prev", true)
	assert_eq(pd.page.t, 1)
	click("prev", true)
	assert_eq(pd.page.t, 1)
	click("last")
	assert_eq(pd.page.t, math.huge)
	click("first")
	assert_eq(pd.page.t, 1)
	assert_eq(calls, 7)
	u.handle.pager_click(nil, pd, nil, { element = { tags = {} } })
	assert_eq(calls, 7)
end)

test("sort_click: sorts the tagged tab by the tagged column, toggling on a repeat", function()
	local u = util()
	local calls = 0
	u.set_rerender(function() calls = calls + 1 end)
	local pd = {}
	local function click(tags) u.handle.sort_click(nil, pd, nil, { element = { tags = tags } }) end
	click({ sort_tab = "trains_tab", column = "name" })
	assert_eq(pd.sort.trains_tab, { column = "name", ascending = true })
	click({ sort_tab = "trains_tab", column = "name" })
	assert_eq(pd.sort.trains_tab, { column = "name", ascending = false })
	click({ column = "name" })
	assert_eq(calls, 2)
end)

test("sync_sort_header: active column selected with the stored direction, others at their default", function()
	local u = util()
	local cell = H.element({ name = "cell" })
	local name = cell.add({ type = "checkbox", style = "ltnm_sort_checkbox", state = false, tags = { column = "name", default_state = false } })
	local status = cell.add({ type = "checkbox", style = "ltnm_selected_sort_checkbox", state = false, tags = { column = "status", default_state = true } })
	local wait = cell.add({ type = "checkbox", style = "ltnm_sort_checkbox", state = true, tags = { column = "wait" } })
	local plain = cell.add({ type = "checkbox", style = "plain", state = true })
	local label = cell.add({ type = "label", style = "ltnm_sort_checkbox", tags = { column = "name" } })
	u.sync_sort_header(cell, "name", false)
	assert_eq(name.style, { name = "ltnm_selected_sort_checkbox" })
	assert_true(name.state)
	assert_eq(status.style, { name = "ltnm_sort_checkbox" })
	assert_true(status.state)
	-- No default_state: an inactive arrow keeps whatever it shows.
	assert_eq(wait.style, { name = "ltnm_sort_checkbox" })
	assert_true(wait.state)
	assert_eq(plain.style, { name = "plain" })
	assert_eq(label.style, { name = "ltnm_sort_checkbox" })
	u.sync_sort_header(cell, "name", true)
	assert_false(name.state)
	u.sync_sort_header(cell, "status", true)
	assert_eq(status.style, { name = "ltnm_selected_sort_checkbox" })
	assert_false(status.state)
	assert_eq(name.style, { name = "ltnm_sort_checkbox" })
	assert_false(name.state)
	cell.valid = false
	u.sync_sort_header(cell, "name", true)
	assert_eq(name.style.name, "ltnm_sort_checkbox")
	u.sync_sort_header(nil, "name", true)
end)

-- ------------------------------------------------------------------ slot tables

local function slot_summary(defs)
	local out = {}
	for i, d in ipairs(defs) do
		out[i] = (d.tags and d.tags.kind == "item" and d.tags.id or d.sprite) .. " " .. string.match(d.style, "_(%a+)$") .. " " .. d.children[1].caption
	end
	return out
end

local function slot_station()
	storage.manager = { item_order = { ["iron-plate"] = 1, coal = 2, stone = 3, ["copper-ore"] = 4, ["iron-ore"] = 5 } }
	game.tick = 4000
	return {
		provided = { ["iron-plate"] = 1500, coal = 5 },
		requested = {
			stone = { count = -60, active = true },
			["copper-ore|rare"] = { count = -10, active = false },
			["iron-ore"] = { count = -7, active = true },
		},
		wait = { stone = 400, ["copper-ore|rare"] = 100 },
		deliveries = { ["iron-ore"] = 400, coal = -50 },
		control = { ["cybersyn-priority"] = 3, ["signal-A"] = 1, ["bogus-signal"] = 5 },
		thresholds = { stone = 150 },
	}
end

test("slot_table_build_from_station: provided green, active requests red, below threshold orange, item order", function()
	local u = util()
	local defs = u.slot_table_build_from_station(slot_station())
	assert_eq(slot_summary(defs), {
		"iron-plate green 1.5k",
		"coal green 5",
		"stone red -60",
		"copper-ore|rare orange -10",
		"iron-ore red -7",
	})
	assert_eq(defs[3], {
		type = "sprite-button",
		sprite = "item/stone",
		elem_tooltip = { type = "item-with-quality", name = "stone", quality = "normal" },
		enabled = false,
		style = "ltnm_small_slot_button_red",
		tags = { kind = "item", id = "stone" },
		tooltip = {
			"",
			{ "", "[item=stone,quality=]", " ", { "item-name.stone" } },
			" ", { "cybersyn-gui.requested" },
			"\n[color=yellow]", { "cybersyn-gui.waiting-for", "1m 0s" }, "[/color]",
			"\n", { "cybersyn-gui.amount", "-60" },
		},
		children = {
			{ type = "label", style = "ltnm_label_signal_count", ignored_by_interaction = true, caption = "-60" },
		},
	})
	-- Below threshold: no wait line even with a tracked start.
	assert_eq(defs[4].quality, "rare")
	assert_eq(defs[4].tooltip, {
		"",
		{ "", "[item=copper-ore,quality=rare]", " ", { "item-name.copper-ore" } },
		" ", { "cybersyn-gui.requested-below-threshold" },
		"\n", { "cybersyn-gui.amount", "-10" },
	})
	assert_eq(defs[1].tooltip[6], { "cybersyn-gui.amount", "1,500" })
end)

test("slot_table_build_from_deliveries: incoming green, outgoing blue", function()
	local u = util()
	local defs = u.slot_table_build_from_deliveries(slot_station())
	assert_eq(slot_summary(defs), { "coal blue -50", "iron-ore green 400" })
	assert_eq(defs[1].tooltip[4], { "cybersyn-gui.outgoing" })
	assert_eq(defs[2].tooltip[4], { "cybersyn-gui.incoming" })
end)

test("slot builders: a look sets the slot and count styles and highlights its selected item", function()
	local u = util()
	local look = { prefix = "p_", selected_prefix = "s_", count = "c", selected = "coal" }
	local defs = u.slot_table_build_from_deliveries(slot_station(), look)
	assert_eq({ defs[1].style, defs[2].style, defs[2].children[1].style }, { "s_blue", "p_green", "c" })
	assert_eq(u.slot_table_build_from_station(slot_station(), look)[2].style, "s_green")
end)

test("slot_table_build_from_control_signals: sorted virtual signals with a sprite, then thresholds", function()
	local u = util()
	local defs = u.slot_table_build_from_control_signals(slot_station())
	assert_eq(slot_summary(defs), {
		"virtual-signal/cybersyn-priority default 3",
		"virtual-signal/signal-A default 1",
		"stone default 150",
	})
	assert_eq(defs[2].tooltip, {
		"", "[virtual-signal=signal-A] ", { "item-name.signal-A" }, "\n", { "cybersyn-gui.amount", "1" },
	})
	assert_nil(defs[2].tags)
	assert_eq(defs[3].tooltip, {
		"",
		{ "", "[item=stone,quality=]", " ", { "item-name.stone" } },
		"\n", { "cybersyn-gui.request-threshold", "150" },
	})
end)

test("natural_key: digit runs compare by value, leading zeros ignored", function()
	local util = H.load("scripts.gui.util")
	local names = { "stn-10", "stn-2", "stn-1", "stn-002", "stn", "a10b", "a9b", "x0" }
	table.sort(names, function(a, b)
		local ka, kb = util.natural_key(a), util.natural_key(b)
		if ka ~= kb then return ka < kb end
		return a < b
	end)
	assert_eq(names, { "a9b", "a10b", "stn", "stn-1", "stn-002", "stn-2", "stn-10", "x0" })
	assert_eq(util.natural_key("000"), util.natural_key("0"))
end)

test("ack_until_tick: a day, an hour with shift, until clear with control", function()
	local u = util()
	game.tick = 100
	assert_eq(u.ack_until_tick({}), 100 + 24 * 216000)
	assert_eq(u.ack_until_tick({ shift = true }), 100 + 216000)
	assert_nil(u.ack_until_tick({ control = true, shift = true }))
end)
