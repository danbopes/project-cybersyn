-- PLAN3 §4.3: the window size from the screen (scripts/gui/sizing.lua) and the search normaliser (util).

local H = require("harness")

local function sizing()
	return H.load("scripts.gui.sizing")
end

local SCREENS = {
	{ "4K at 1.5", 3840, 2160, 1.5 },
	{ "1080p at 1.0", 1920, 1080, 1.0 },
	{ "1080p at 1.25", 1920, 1080, 1.25 },
	{ "4K at 2.0", 3840, 2160, 2.0 },
}

test("compute: width is 75 % of the logical screen, at most 1,440", function()
	local s = sizing()
	assert_eq(s.compute(3840, 2160, 1.5).width, 1440)
	assert_eq(s.compute(1920, 1080, 1.0).width, 1440)
	assert_eq(s.compute(1920, 1080, 1.25).width, 1152)
	assert_eq(s.compute(3840, 2160, 2.0).width, 1440)
	assert_eq(s.compute(1920, 1080, 1.25).content_width, 1152 - s.OUTER_WIDTH)
end)

test("compute: the window is chrome plus whole Overview rows and as tall as fits in 85 % of the screen", function()
	local s = sizing()
	for _, screen in ipairs(SCREENS) do
		local l = s.compute(screen[2], screen[3], screen[4])
		local limit = math.floor(0.85 * math.floor(screen[3] / screen[4]))
		local rows = l.rows_by_tab.overview_tab
		assert_eq(l.content_height, s.TAB_CHROME.overview_tab + rows * s.ROW_HEIGHT.overview_tab, screen[1])
		assert_true(l.window_height <= limit, screen[1] .. " fits")
		assert_true(l.window_height + s.ROW_HEIGHT.overview_tab > limit, screen[1] .. " one more row would not")
	end
end)

test("compute: the reference screen of the wireframe (4K at 1.5) gets 27 Overview rows", function()
	local s = sizing()
	local l = s.compute(3840, 2160, 1.5)
	assert_eq(l.screen_width, 2560)
	assert_eq(l.screen_height, 1440)
	assert_eq(l.rows_by_tab.overview_tab, math.floor((1224 - s.OUTER_HEIGHT - s.TAB_CHROME.overview_tab) / 32))
end)

test("compute: every other tab fits whole rows of its own height into the Overview's content height", function()
	local s = sizing()
	for _, screen in ipairs(SCREENS) do
		local l = s.compute(screen[2], screen[3], screen[4])
		for tab, h in pairs(s.ROW_HEIGHT) do
			local rows = l.rows_by_tab[tab]
			assert_true(s.TAB_CHROME[tab] + rows * h <= l.content_height, screen[1] .. " " .. tab)
			assert_true(s.TAB_CHROME[tab] + (rows + 1) * h > l.content_height, screen[1] .. " " .. tab .. " is maximal")
		end
	end
end)

test("compute: the filter row and the banner take rows away, never push past 85 %", function()
	local s = sizing()
	local plain = s.compute(3840, 2160, 1.5)
	local both = s.compute(3840, 2160, 1.5, true, true)
	assert_true(both.rows_by_tab.overview_tab < plain.rows_by_tab.overview_tab)
	assert_true(both.window_height <= 1224)
	assert_eq(both.window_height, s.OUTER_HEIGHT + s.FILTER_ROW_HEIGHT + s.BANNER_HEIGHT + both.content_height)
end)

test("compute: a tiny screen still gets the minimum rows, and a zero scale reads as 1", function()
	local s = sizing()
	local l = s.compute(800, 400, 1)
	assert_eq(l.rows_by_tab.overview_tab, s.MIN_ROWS)
	assert_eq(l.width, s.MIN_WIDTH)
	assert_eq(s.compute(1920, 1080, 0).width, 1440)
end)

test("location_visible: off-screen positions are refused, in physical pixels", function()
	local s = sizing()
	assert_false(s.location_visible(nil, 3840, 2160, 2160))
	assert_true(s.location_visible({ x = 840, y = 171 }, 3840, 2160, 2160))
	assert_false(s.location_visible({ x = 3800, y = 171 }, 3840, 2160, 2160))
	assert_false(s.location_visible({ x = -2100, y = 171 }, 3840, 2160, 2160))
	assert_false(s.location_visible({ x = 100, y = -5 }, 3840, 2160, 2160))
	assert_false(s.location_visible({ x = 100, y = 2140 }, 3840, 2160, 2160))
	-- A position stored on a 4K screen is off a 1080p one.
	assert_false(s.location_visible({ x = 2500, y = 1500 }, 1920, 1080, 1440))
	assert_true(s.location_visible({ 10, 10 }, 1920, 1080, 1440))
end)

test("fit_location: a position kept after the window grew is moved back onto the screen", function()
	local s = sizing()
	-- Stored at UI scale 1.5 (2,160 px wide), restored at 2.0 (2,880 px wide).
	assert_eq(s.fit_location({ x = 840, y = 96 }, 3840, 2160, 2880, 1784), { x = 840, y = 96 })
	assert_eq(s.fit_location({ x = 1500, y = 96 }, 3840, 2160, 2880, 1784), { x = 960, y = 96 })
	assert_eq(s.fit_location({ x = 100, y = 900 }, 3840, 2160, 2160, 1820), { x = 100, y = 340 })
	assert_nil(s.fit_location({ x = 3800, y = 96 }, 3840, 2160, 2880, 1784))
	assert_nil(s.fit_location(nil, 3840, 2160, 2880, 1784))
end)

-- ------------------------------------------------------------------ search

local function util()
	return H.load("scripts.gui.util")
end

test("search_terms: lowercase, split on whitespace, nil for blank", function()
	local u = util()
	assert_eq(u.search_terms("  Iron  PLATE "), { "iron", "plate" })
	assert_nil(u.search_terms("   "))
	assert_nil(u.search_terms(nil))
end)

test("search_terms: the normaliser is helpers.multilingual_to_lower", function()
	local u = util()
	local seen
	helpers.multilingual_to_lower = function(s) seen = s; return string.lower(s) end
	assert_eq(u.search_terms("ÄB"), { string.lower("ÄB") })
	assert_eq(seen, "ÄB")
	helpers.multilingual_to_lower = string.lower
end)

test("search: [, %, - and . are plain characters, never patterns", function()
	local u = util()
	local function match(name, query)
		return u.terms_match(u.normalize(name), u.search_terms(query))
	end
	assert_true(match("[item=iron-plate] Iron 50%", "[item=iron"))
	assert_true(match("[item=iron-plate] Iron 50%", "50%"))
	assert_true(match("[item=iron-plate] Iron 50%", "%"))
	assert_true(match("Unload-A", "d-a"))
	assert_false(match("axb", "a.b"))
	assert_true(match("a.b", "a.b"))
	assert_false(match("Iron", "["))
	assert_true(match("[virtual-signal=signal-A] Depot", "[virtual-signal=signal-a]"))
	-- A lone "%" or "[" would raise "malformed pattern" if it ever reached string.find as a pattern.
	assert_true(pcall(match, "x", "%"))
	assert_true(pcall(match, "x", "[%"))
end)

test("station_passes: rich text and pattern characters in the query", function()
	local u = util()
	local st = { name_lower = "[item=coal] coal 100% (east)", surface_index = 1, network_name = "signal-A", network_mask = 1,
		provided = {}, requested = {}, deliveries = {} }
	local f = { terms = u.search_terms("[item=coal] 100% (east)"), mask = -1 }
	assert_true(u.station_passes(st, f))
	f.terms = u.search_terms("(west)")
	assert_false(u.station_passes(st, f))
end)
