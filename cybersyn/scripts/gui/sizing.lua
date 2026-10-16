-- Manager window size from the player's screen (PLAN3 §4.3): the width is a share of the screen, and the height is a
-- fixed chrome plus whole rows, so no tab ever shows half a row. Pure arithmetic in logical pixels (physical pixels
-- divided by the UI scale); the GUI applies the result as style sizes, which the engine scales back up.

local sizing = {}

sizing.MAX_WIDTH = 1440
sizing.MIN_WIDTH = 960
sizing.WIDTH_SHARE = 0.75
sizing.HEIGHT_SHARE = 0.85
sizing.MIN_ROWS = 3

-- Everything outside a tab's content: frame border and title bar, the tab strip, the tab pane's padding. The
-- wireframe's 124 (titlebar 44, tabs 48, padding 12, bottom 20) measured 126 on screenshots: the window frame is 894 px
-- tall at UI scale 1.0 and 1,820 px at 1.5 (1,213 logical) with 17 and 27 Overview rows, shadow excluded.
sizing.OUTER_HEIGHT = 126
-- Frame border and the tab pane's side padding: the tab content is this much narrower than the window.
sizing.OUTER_WIDTH = 48
-- Optional strips: the filter row above the tabs, the dispatch-paused banner at the top of every tab.
sizing.FILTER_ROW_HEIGHT = 36
sizing.BANNER_HEIGHT = 36

-- Fixed part of each tab's content, rows excluded.
sizing.TAB_CHROME = {
	-- subheader 36, gap 12, tiles 108, gap 12, table caption 36, column header 20
	overview_tab = 224,
	-- subheader 36, column header 36, subfooter 36, frame borders
	stations_tab = 112,
	trains_tab = 112,
	-- subheader 36, gap 12, grid subheader 36, grid frame borders 8
	inventory_tab = 92,
	-- subheader 36, column header 20, subfooter 36, frame borders
	problems_tab = 96,
	-- subheader 36, gap 12, caption strip 36, frame borders 4
	log_tab = 88,
	-- The item drill-down (scripts/gui/item.lua) in place of a tab's content: subheader 36, then three tables of
	-- gap 12, caption strip 36, column header 20, frame borders 4; plus the 4 px border of the deep frame that hosts
	-- it on Stations and Trains.
	item_tab = 256,
}

-- Row height per tab (PLAN3 §4.3): every row of a list tab has a fixed height (Stations 32, Trains 36, including the
-- Trains depot group rows), so whole rows fit. Inventory counts slot rows.
sizing.ROW_HEIGHT = {
	overview_tab = 32,
	stations_tab = 32,
	trains_tab = 36,
	inventory_tab = 40,
	problems_tab = 32,
	log_tab = 28,
	-- Shared by the drill-down's three tables (item-model.split_rows).
	item_tab = 32,
}

--- @class ManagerLayout
--- @field width int window width
--- @field content_width int tab content width
--- @field content_height int tab content height without the banner
--- @field window_height int the whole window, every optional strip included
--- @field rows_by_tab {[string]: int}
--- @field screen_width int logical
--- @field screen_height int logical

--- @param res_w number display_resolution.width (physical px)
--- @param res_h number display_resolution.height
--- @param scale number display_scale
--- @param filter_row boolean? the filter row is shown
--- @param banner boolean? the dispatch-paused banner is shown
--- @return ManagerLayout
function sizing.compute(res_w, res_h, scale, filter_row, banner)
	if not scale or scale <= 0 then scale = 1 end
	local sw = math.floor(res_w / scale)
	local sh = math.floor(res_h / scale)
	local width = math.max(sizing.MIN_WIDTH, math.min(sizing.MAX_WIDTH, math.floor(sizing.WIDTH_SHARE * sw)))
	local extra = (filter_row and sizing.FILTER_ROW_HEIGHT or 0) + (banner and sizing.BANNER_HEIGHT or 0)
	local space = math.floor(sizing.HEIGHT_SHARE * sh) - sizing.OUTER_HEIGHT - extra
	local chrome = sizing.TAB_CHROME
	local heights = sizing.ROW_HEIGHT
	-- The Overview sets the content height; every other tab fits as many of its own rows into the same height, so
	-- switching tabs never resizes the window. On a small screen the height is raised until every tab gets its
	-- minimum rows (the drill-down's chrome is the tallest), even past the share of the screen.
	local need = 0
	for tab, h in pairs(heights) do
		need = math.max(need, chrome[tab] + sizing.MIN_ROWS * h)
	end
	local overview_rows = math.max(sizing.MIN_ROWS, math.floor((space - chrome.overview_tab) / heights.overview_tab),
		math.ceil((need - chrome.overview_tab) / heights.overview_tab))
	local content = chrome.overview_tab + overview_rows * heights.overview_tab
	local rows = {}
	for tab, h in pairs(heights) do
		rows[tab] = math.max(sizing.MIN_ROWS, math.floor((content - chrome[tab]) / h))
	end
	return {
		width = width,
		content_width = width - sizing.OUTER_WIDTH,
		content_height = content,
		window_height = sizing.OUTER_HEIGHT + extra + content,
		rows_by_tab = rows,
		screen_width = sw,
		screen_height = sh,
	}
end

--- Whether a stored window position (physical px, top left) keeps the title bar on a screen of this size.
--- @param location {x: number, y: number}?
--- @param res_w number
--- @param res_h number
--- @param width_px number window width in physical px
--- @return boolean
function sizing.location_visible(location, res_w, res_h, width_px)
	if not location then return false end
	local x, y = location.x or location[1], location.y or location[2]
	if not (x and y) then return false end
	-- At least a 100 px wide grip of the title bar must stay reachable.
	local grip = 100
	return x + width_px >= grip and x <= res_w - grip and y >= 0 and y <= res_h - 60
end

--- A stored position moved just enough that the whole window is on the screen (a larger UI scale makes the window
--- larger than when the position was stored); nil when the position is unusable.
--- @param location {x: number, y: number}?
--- @param res_w number
--- @param res_h number
--- @param width_px number
--- @param height_px number
--- @return {x: int, y: int}?
function sizing.fit_location(location, res_w, res_h, width_px, height_px)
	if not sizing.location_visible(location, res_w, res_h, width_px) then return nil end
	local x, y = location.x or location[1], location.y or location[2]
	x = math.max(0, math.min(x, res_w - width_px))
	y = math.max(0, math.min(y, res_h - height_px))
	return { x = math.floor(x), y = math.floor(y) }
end

return sizing
