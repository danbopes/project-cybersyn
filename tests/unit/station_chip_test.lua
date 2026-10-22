-- PLAN8 D8-7 (the station chip: filter field, predicates, stop panel slot clicks) and D8-8 (the drill-down's
-- empty-text suffix).

local H = require("harness")

local function util() return H.load("scripts.gui.util") end

local function station(id, over)
	local st = {
		id = id,
		name_lower = "r",
		surface_index = 1,
		network_name = "signal-A",
		network_mask = 1,
		provided = { ["iron-ore"] = 100 },
		requested = {},
		deliveries = {},
	}
	for k, v in pairs(over or {}) do st[k] = v end
	return st
end

test("get_filters carries the chip as f.station; filters_active and filter_signature see it", function()
	local u = util()
	local f = u.get_filters({ search_station = 12 })
	assert_eq(f.station, 12)
	assert_true(u.filters_active({ mask = -1, station = 12 }))
	assert_true(u.filters_active({ mask = -1, station = 12 }, true))
	assert_true(u.filter_signature({ mask = -1 }) ~= u.filter_signature({ mask = -1, station = 12 }))
	assert_true(u.filter_signature({ mask = -1, station = 11 }) ~= u.filter_signature({ mask = -1, station = 12 }))
	assert_false(u.place_filters_active({ mask = -1, station = 12 }), "the chip is not a place filter")
end)

test("station_passes: only the chip's station, by id, whatever the name", function()
	local u = util()
	assert_true(u.station_passes(station(12), { mask = -1, station = 12 }))
	assert_false(u.station_passes(station(13), { mask = -1, station = 12 }))
	assert_true(u.station_passes(station(13), { mask = -1 }))
	-- The chip and the other filters AND together.
	assert_false(u.station_passes(station(12), { mask = -1, station = 12, surface = 2 }))
end)

test("train_passes: a train whose provider or requester is the chip's station", function()
	local u = util()
	storage.manager = { players = {}, snapshot = require("scripts.gui.collector").empty() }
	local function tr(p, r)
		return { surface_index = 1, network_name = "signal-A", network_mask = 1, manifest_hashes = {},
			p_station_id = p, r_station_id = r }
	end
	local f = { mask = -1, station = 12 }
	assert_true(u.train_passes(tr(12, 30), f))
	assert_true(u.train_passes(tr(30, 12), f))
	assert_false(u.train_passes(tr(30, 31), f))
	assert_false(u.train_passes(tr(nil, nil), f), "a parked train has no delivery station")
	assert_true(u.train_passes(tr(nil, nil), { mask = -1 }))
end)

test("overview_filters drops the chip (the Overview ignores it)", function()
	local u = util()
	local f = u.overview_filters({ search_station = 12, search_network_mask = -1 })
	assert_nil(f.station)
	assert_eq(u.get_filters({ search_station = 12 }).station, 12)
end)

test("empty_filter_suffix: '-filtered' with a place filter or the chip, '' otherwise", function()
	local u = util()
	assert_eq(u.empty_filter_suffix({ mask = -1 }), "")
	assert_eq(u.empty_filter_suffix({ mask = -1, terms = { "a" }, item = "coal" }), "")
	assert_eq(u.empty_filter_suffix({ mask = -1, station = 3 }), "-filtered")
	assert_eq(u.empty_filter_suffix({ mask = 2 }), "-filtered")
	assert_eq(u.empty_filter_suffix({ mask = -1, network = "signal-A" }), "-filtered")
	assert_eq(u.empty_filter_suffix({ mask = -1, surface = 1 }), "-filtered")
end)

test("D8-8 strings exist in en for every drill-down table", function()
	local en = H.read_cfg("en/manager.cfg")["cybersyn-gui"]
	for _, t in ipairs({ "providers", "requesters", "trains" }) do
		assert_true(en["item-empty-" .. t] ~= nil, t)
		assert_true(en["item-empty-" .. t .. "-filtered"] ~= nil, t .. " filtered")
	end
	for _, k in ipairs({ "station-chip", "station-chip-tooltip", "station-chip-ignored-tooltip" }) do
		assert_true(en[k] ~= nil, k)
	end
end)

test("set_station_filter: a known id sets the chip, opens the row, resets pages; unknown or nil clears", function()
	local u = util()
	storage.stations = { [12] = {} }
	local pd = { page = { stations_tab = 3 } }
	u.set_station_filter(pd, 12)
	assert_eq(pd.search_station, 12)
	assert_true(pd.filter_row_open)
	assert_eq(pd.page, {})
	u.set_station_filter(pd, 99)
	assert_nil(pd.search_station)
	pd.search_station = 12
	u.set_station_filter(pd, nil)
	assert_nil(pd.search_station)
end)

test("valid_station_filter drops a removed station", function()
	local u = util()
	storage.stations = { [12] = {} }
	local pd = { search_station = 12 }
	assert_eq(u.valid_station_filter(pd), 12)
	storage.stations[12] = nil
	assert_nil(u.valid_station_filter(pd))
	assert_nil(pd.search_station)
end)

-- ---------------------------------------------------------------- stop panel slot clicks

local function click_setup(open)
	local u = util()
	-- Defined by scripts/main.lua's remote interface, which the host tests do not load.
	interface_raise_item_selected = function() end
	storage.stations = { [12] = {} }
	local calls = {}
	u.set_item_view({
		open = function(_, _, hash) calls[#calls + 1] = "drill:" .. hash end,
		close = function() calls[#calls + 1] = "close-drill" end,
	})
	u.set_window_fns({
		open = function(_, pd) calls[#calls + 1] = "open-window"; pd.is_manager_open = true end,
		close = function(_, pd) calls[#calls + 1] = "close-window"; pd.is_manager_open = false end,
	})
	u.set_rerender(function() end)
	local pd = { is_manager_open = open, selected_tab = "overview_tab", refs = {} }
	return u, pd, calls, { index = 1 }
end

local function slot_click(u, player, pd, tags, mods)
	tags.kind = "item"
	tags.id = tags.id or "iron-plate"
	mods = mods or {}
	u.handle_link_click(player, pd, { element = { tags = tags }, button = mods.right and defines.mouse_button_type.right
		or defines.mouse_button_type.left, shift = mods.shift })
end

test("an Advertised/Unserved slot sets the chip and the item's drill-down, as today", function()
	local u, pd, calls, player = click_setup(false)
	slot_click(u, player, pd, { station = 12 })
	assert_eq(pd.search_station, 12)
	assert_eq(calls, { "drill:iron-plate" })
end)

test("an in-flight slot sets item + chip and lands on Trains, opening the window when closed", function()
	local u, pd, calls, player = click_setup(false)
	slot_click(u, player, pd, { station = 12, flight = true })
	assert_eq(pd.search_station, 12)
	assert_eq(pd.search_item, "iron-plate")
	assert_eq(pd.selected_tab, "trains_tab")
	assert_eq(calls, { "close-drill", "open-window" })
end)

test("a slot without a station leaves the chip alone; right-click clears only the item", function()
	local u, pd, calls, player = click_setup(true)
	pd.search_station = 12
	pd.search_item = "coal"
	slot_click(u, player, pd, {}, { right = true })
	assert_nil(pd.search_item)
	assert_eq(pd.search_station, 12)
	slot_click(u, player, pd, {})
	assert_eq(pd.search_station, 12)
	assert_eq(calls, { "drill:iron-plate" })
end)

-- ---------------------------------------------------------------- Log

test("log-model compile: the chip's station filters the station column, and ANDs with a subject", function()
	storage.stations = {}
	local model = H.load("scripts.gui.log-model")
	local f = model.default_filter()
	local r = { kind = { DIAG_KIND_STATION_LIMIT, DIAG_KIND_STATION_LIMIT }, station = { 12, 13 }, station2 = { 0, 0 },
		train = { 0, 0 }, item = { 0, 0 }, code = { 0, 0 } }
	local plain = model.compile(f, 100)
	local chip = model.compile(f, 100, nil, 12)
	assert_true(chip.any)
	assert_true(plain.sig ~= chip.sig)
	assert_true(model.match(r, 1, chip))
	assert_false(model.match(r, 2, chip))
	assert_true(model.match(r, 2, plain))
	f.subject = { kind = "station", id = 13 }
	assert_false(model.match(r, 2, model.compile(f, 100, nil, 12)), "two different stations match nothing")
	assert_true(model.match(r, 1, model.compile({ sev = f.sev, window = f.window, subject = { kind = "station", id = 12 } },
		100, nil, 12)))
end)
