-- Decisions the Stations, Trains and Inventory tabs make from plain values (PLAN3 §4.7): which columns a page hides,
-- which state chip a train shows, composition strings, deficits, chip membership, column widths. No game API here, so
-- every rule has a host unit test (tests/unit/tab_logic_test.lua).

local logic = {}

-- ---------------------------------------------------------------- columns

--- Whether every row gives the same value for a column; such a column is hidden and its value named in a header
--- tooltip instead. nil is a value like any other, so an all-nil column (electric fuel, never refuelled) is uniform.
--- @param rows any[]
--- @param key_fn fun(row: any): any
--- @return boolean uniform true for an empty list
--- @return any value the shared value when uniform
function logic.single_value(rows, key_fn)
	local n = #rows
	if n == 0 then return true, nil end
	local first = key_fn(rows[1])
	for i = 2, n do
		if key_fn(rows[i]) ~= first then return false, nil end
	end
	return true, first
end

--- Splits `available` px between fixed columns and one flexible column. Columns are {key, width, min?}; a hidden key
--- takes nothing. While the flexible column would fall below `flex_min`, the shrinkable columns (those with a `min`)
--- give up width in list order down to their minimum.
--- @param columns {[1]: string, [2]: int, min: int?}[]
--- @param hidden {[string]: true}?
--- @param available int px for all columns together, spacing excluded
--- @param flex string the flexible column's key
--- @param flex_min int
--- @return {[string]: int}
function logic.allocate(columns, hidden, available, flex, flex_min)
	hidden = hidden or {}
	local out, fixed = {}, 0
	for _, c in ipairs(columns) do
		local key = c[1]
		if key ~= flex and not hidden[key] then
			out[key] = c[2]
			fixed = fixed + c[2]
		end
	end
	local rest = available - fixed
	if rest < flex_min then
		for _, c in ipairs(columns) do
			local key = c[1]
			if c.min and out[key] and rest < flex_min then
				local give = math.min(out[key] - c.min, flex_min - rest)
				if give > 0 then
					out[key] = out[key] - give
					rest = rest + give
				end
			end
		end
	end
	out[flex] = math.max(rest, 0)
	return out
end

--- The Trains detail pane (PLAN3 §4.11) and the gap before it: the table is this much narrower while it shows.
-- The 300 px train panel inside 12 px insets (PLAN3 §8 rhythm).
logic.PANE_WIDTH = 324
logic.PANE_GAP = 12

-- The pane's fixed parts around its camera and the train panel's scroll body: the pane's subheader 36, the mount's
-- paddings 24, the panel's footer 40 and the frames' borders 8 (the panel's own subheader and paused banner are
-- hidden in the pane: the pane's subheader and the tab's banner say the same).
logic.PANE_FIXED = 36 + 24 + 40 + 8
logic.PANE_CAMERA_GAP = 12
logic.PANE_CAMERA_HEIGHT = 180
logic.PANE_CAMERA_MIN = 90
logic.PANE_BODY_MIN = 120

--- How the pane's height splits between the camera and the train panel's scroll body: the body keeps
--- PANE_BODY_MIN first, the camera shrinks to make room and is dropped below PANE_CAMERA_MIN.
--- @param height int the pane's height in logical px
--- @return int camera the camera's height, 0 = no camera
--- @return int body the scroll body's height cap, never negative
function logic.pane_split(height)
	local camera = math.min(logic.PANE_CAMERA_HEIGHT,
		height - logic.PANE_FIXED - logic.PANE_CAMERA_GAP - logic.PANE_BODY_MIN)
	if camera < logic.PANE_CAMERA_MIN then camera = 0 end
	local body = height - logic.PANE_FIXED - (camera > 0 and camera + logic.PANE_CAMERA_GAP or 0)
	return camera, math.max(body, 0)
end

--- The width the Trains table's columns share: the tab's content width, less the detail pane while it shows.
--- @param content_width int
--- @param pane boolean
--- @return int
function logic.table_width(content_width, pane)
	if pane then return content_width - logic.PANE_WIDTH - logic.PANE_GAP end
	return content_width
end

-- ---------------------------------------------------------------- Trains table widths

local TRAIN_SLOT = 32
-- Row padding and frame borders, and the gap between two shown columns.
local ROW_PADDING, COLUMN_GAP = 20, 8

--- The Trains table's columns in display order: {key, width, min = shrinkable down to}; the status takes the rest.
logic.TRAIN_WIDTHS = {
	{ "train_id", 52 },
	{ "train_status", 0 },
	{ "network", 96, min = 64 },
	{ "layout", 112, min = 80 },
	{ "depot", 150, min = 100 },
	{ "state", 128, min = 100 },
	{ "time_in_state", 72 },
	{ "last_refuel", 80 },
	{ "fuel", 52 },
	{ "shipment", 6 * TRAIN_SLOT, min = 3 * TRAIN_SLOT },
}
logic.TRAIN_STATUS_MIN = 260
--- While the detail pane shows, Shipment is dropped (the pane shows the cargo); with or without the pane, these go
--- one at a time while the status would stay under its minimum (a window narrower than about 1,100 px drops columns
--- even with the pane closed). Id, status and state always stay.
logic.TRAIN_PANE_DROP = { "last_refuel", "fuel", "layout", "network", "depot", "time_in_state" }

--- Column widths of the Trains table. The table is narrower by the detail pane while it shows; columns the pane
--- pushed out are reported in `dropped` and have no width, like the `hidden` ones. Shipment is cut to whole slots,
--- what that leaves goes to the status. The depot group rows keep their name at 120 px or more by dropping the
--- compositions note, then the Bypassed chip.
--- @param content_width int
--- @param hidden {[string]: true} columns hidden because every listed train shares their value
--- @param pane boolean
--- @return {[string]: int|boolean|table} w width per shown column, cw (table width), dropped, group_name, group_comps, group_bypass
function logic.train_widths(content_width, hidden, pane)
	local cw = logic.table_width(content_width, pane)
	local h, dropped = {}, {}
	for k in pairs(hidden) do h[k] = true end
	if pane then
		h.shipment = true
		dropped.shipment = true
	end
	local next_drop = 0
	local w
	while true do
		local shown = 0
		for _, c in ipairs(logic.TRAIN_WIDTHS) do
			if not h[c[1]] then shown = shown + 1 end
		end
		w = logic.allocate(logic.TRAIN_WIDTHS, h, cw - ROW_PADDING - (shown - 1) * COLUMN_GAP, "train_status",
			logic.TRAIN_STATUS_MIN)
		if w.train_status >= logic.TRAIN_STATUS_MIN then break end
		local key
		repeat
			next_drop = next_drop + 1
			key = logic.TRAIN_PANE_DROP[next_drop]
		until key == nil or not h[key]
		if not key then break end
		h[key] = true
		dropped[key] = true
	end
	local shipment = w.shipment
	if shipment then
		w.shipment = math.max(TRAIN_SLOT, math.floor(shipment / TRAIN_SLOT) * TRAIN_SLOT)
		w.train_status = w.train_status + math.max(shipment - w.shipment, 0)
	end
	w.cw = cw
	w.dropped = dropped
	-- Group row: toggle 28, Parked 110, Inbound 100, Trains 100, Bypassed chip 90, compositions 220, the name the rest.
	local name = cw - ROW_PADDING - 7 * COLUMN_GAP - 28 - 110 - 100 - 100 - 90 - 220
	w.group_comps, w.group_bypass = true, true
	if name < 120 then
		w.group_comps = false
		name = name + 220
	end
	if name < 120 then
		w.group_bypass = false
		name = name + 90
	end
	w.group_name = math.min(360, name)
	return w
end

--- The px the shown Trains columns take with their gaps and the row padding (logic.train_widths).
--- @param w table
--- @return int
function logic.train_columns_total(w)
	local total, shown = 0, 0
	for _, c in ipairs(logic.TRAIN_WIDTHS) do
		local v = w[c[1]]
		if v then
			total = total + v
			shown = shown + 1
		end
	end
	return total + math.max(shown - 1, 0) * COLUMN_GAP + ROW_PADDING
end

--- How many slots of a one-line slot strip show items when `n` items share `capacity` slots: when they do not all
--- fit, the last slot becomes the "+n" overflow count, so a row never wraps.
--- @param n int
--- @param capacity int
--- @return int shown
--- @return int overflow items not shown (0 when all fit)
function logic.fit_slots(n, capacity)
	if capacity < 1 then return 0, n end
	if n <= capacity then return n, 0 end
	local shown = capacity - 1
	return shown, n - shown
end

-- ---------------------------------------------------------------- trains

--- A signal wait shorter than this is ordinary traffic (diag.WAIT_SIGNAL_MIN, PLAN3 §4.4).
logic.WAIT_SIGNAL_MIN = 600

--- LuaTrain.state names that are a train's normal work and show no chip.
local QUIET = { on_the_path = true, wait_station = true, arrive_station = true }

local STATE_STYLE = {
	no_path = "red",
	path_lost = "red",
	no_schedule = "red",
	destination_full = "orange",
	manual_control = "orange",
	manual_control_stop = "orange",
	arrive_signal = "grey",
	wait_signal = "grey",
}

--- The chip a train row shows in its State column, or nil.
--- @param state string? LuaTrain.state as its defines.train_state name
--- @param waited number ticks in that state
--- @param residue boolean parked at its depot with cargo aboard
--- @return string? key chip name: the state name or "residue"
--- @return string? style suffix of a cybersyn_chip_* style
function logic.state_chip(state, waited, residue)
	if residue then return "residue", "orange" end
	if not state or QUIET[state] then return nil, nil end
	if state == "wait_signal" and (waited or 0) >= logic.WAIT_SIGNAL_MIN then return state, "orange" end
	return state, STATE_STYLE[state] or "grey"
end

--- The Trains tab's In trouble chip: every state whose chip is red or orange (no path, path lost, no schedule,
--- destination full, manual control, a signal wait of at least WAIT_SIGNAL_MIN), so a red row is always counted.
--- @param state string?
--- @param waited number
--- @return boolean
function logic.in_trouble(state, waited)
	if not state or QUIET[state] then return false end
	local _, style = logic.state_chip(state, waited, false)
	return style == "red" or style == "orange"
end

--- Composition string of a Cybersyn layout (0 = locomotive or any other carriage, 1 = cargo wagon, 2 = fluid wagon):
--- L for a locomotive, C and F for wagons, each run of wagons in angle brackets, so a 1-2-1 train reads "L<CC>L".
--- @param layout int[]
--- @return string
function logic.composition(layout)
	local out, n, open = {}, 0, false
	for i = 1, #layout do
		local c = layout[i]
		if c == 1 or c == 2 then
			if not open then
				n = n + 1
				out[n] = "<"
				open = true
			end
			n = n + 1
			out[n] = c == 1 and "C" or "F"
		else
			if open then
				n = n + 1
				out[n] = ">"
				open = false
			end
			n = n + 1
			out[n] = "L"
		end
	end
	if open then out[n + 1] = ">" end
	return table.concat(out)
end

--- Ticks since `tick`, nil when there is none (never refuelled, no state change recorded).
--- @param now number
--- @param tick number?
--- @return number?
function logic.age(now, tick)
	if not tick then return nil end
	local d = now - tick
	return d > 0 and d or 0
end

--- Whether a train counts for the Not refuelled > N h chip: not seen at a refueler for longer than the per-user
--- hours. A train never seen at one gets the same time from `refuel_from` (lint.refuel_from: since Cybersyn first
--- saw it, or since refuels are tracked), the grace the collector's not_refuelled_count and the lint give it.
--- @param now number
--- @param refuel_tick number?
--- @param hours number
--- @param refuel_from number?
--- @return boolean
function logic.not_refuelled(now, refuel_tick, hours, refuel_from)
	local since = refuel_tick or refuel_from
	if not since then return true end
	return now - since > hours * 216000
end

--- The next tick at which the passing of time alone changes a train's time-dependent chips (In trouble by a long
--- signal wait, Not refuelled), or nil when nothing will: the chip counts stay valid until the earliest such tick.
--- @param now number
--- @param state string? LuaTrain.state as its defines.train_state name
--- @param state_since number?
--- @param refuel_since number? refuel_tick, else the train's refuel grace start (refuel_from); nil = never refuelled
--- @param hours number
--- @param has_refueler boolean
--- @return number?
function logic.chip_change_tick(now, state, state_since, refuel_since, hours, has_refueler)
	local t
	if state == "wait_signal" and state_since then
		local at = state_since + logic.WAIT_SIGNAL_MIN
		if at > now then t = at end
	end
	if has_refueler and refuel_since then
		local at = math.floor(refuel_since + hours * 216000) + 1
		if at > now and (not t or at < t) then t = at end
	end
	return t
end

--- A duration caption with "never" for no tick: the Last refuel and Last delivery cells.
--- @param now number
--- @param tick number?
--- @param fmt fun(ticks: number): string
--- @return string|nil caption nil = never
--- @return number? age
function logic.age_caption(now, tick, fmt)
	local age = logic.age(now, tick)
	if not age then return nil, nil end
	return fmt(age), age
end

--- Fuel of a train as a percentage of what its burners hold when full, averaged over the locomotives that burn
--- fuel; nil when none does (electric).
--- @param locos {energy: number, capacity: number}[]
--- @return int?
function logic.fuel_percent(locos)
	local sum, n = 0, 0
	for _, l in ipairs(locos) do
		n = n + 1
		if l.capacity > 0 then sum = sum + math.min(l.energy / l.capacity, 1) end
	end
	if n == 0 then return nil end
	return math.floor(100 * sum / n + 0.5)
end

--- Rows of the Trains tab grouped by depot: one group row per name (sorted), followed by its trains when expanded.
--- Group rows count as rows for paging.
--- @param names string[] group names in display order
--- @param members {[string]: any[]} the trains of each group, in display order
--- @param expanded {[string]: true}?
--- @return {group: string, train: any?}[]
function logic.group_rows(names, members, expanded)
	local out = {}
	expanded = expanded or {}
	for _, name in ipairs(names) do
		out[#out + 1] = { group = name }
		if expanded[name] then
			for _, tr in ipairs(members[name] or {}) do
				out[#out + 1] = { group = name, train = tr }
			end
		end
	end
	return out
end

--- The Trains chips in subheader order; "all" clears the chip.
logic.TRAIN_CHIPS = { "all", "parked", "to_p", "loading", "to_r", "unloading", "returning", "refuel", "interrupt",
	"not_refuelled", "in_group", "trouble" }

--- The locale key of a Trains chip caption: compact captions use the -short key, except All, which is short already.
--- @param key string one of TRAIN_CHIPS
--- @param compact boolean
--- @return string
function logic.train_chip_locale(key, compact)
	local base = "cybersyn-gui.trains-chip-" .. string.gsub(key, "_", "-")
	if compact and key ~= "all" then return base .. "-short" end
	return base
end

--- The hours of the Not refuelled chip as the caption and the tooltip show them: "1", "0.25", "2.75", "12.5".
--- @param hours number
--- @return string
function logic.hours_caption(hours)
	local s = string.format("%.2f", hours)
	s = string.gsub(s, "0+$", "")
	return (string.gsub(s, "%.$", ""))
end

-- ---------------------------------------------------------------- stations

logic.FLAG_UNSERVED = 1
logic.FLAG_SETUP = 2
logic.FLAG_THROTTLING = 4
logic.FLAG_NO_POWER = 8
logic.FLAG_DISABLED = 16
logic.FLAG_STUCK = 32
--- Failing = no power + disabled + throttling + setup (PLAN3 §4.7; the Overview's Stations failing tile).
logic.FAILING = 8 + 16 + 4 + 2

--- Chip membership of a station record, without the stuck flag (that one comes from the trains).
--- @param st {status: string?, unserved: {count: int}?, lint: int?, throttling: boolean?}
--- @return int
function logic.station_flags(st)
	local f = 0
	local u = st.unserved
	if u and u.count > 0 then f = f + logic.FLAG_UNSERVED end
	if (st.lint or 0) ~= 0 then f = f + logic.FLAG_SETUP end
	if st.throttling then f = f + logic.FLAG_THROTTLING end
	if st.status == "no_power" then f = f + logic.FLAG_NO_POWER end
	if st.status == "disabled" then f = f + logic.FLAG_DISABLED end
	return f
end

--- Stations named by a train with a stuck alert as its provider or requester.
--- @param alerts {train_id: uint, kind: int}[]
--- @param trains {[uint]: {p_station_id: uint?, r_station_id: uint?}}
--- @param stuck_kind int
--- @return {[uint]: true}
function logic.stuck_stations(alerts, trains, stuck_kind)
	local out = {}
	for _, a in ipairs(alerts or {}) do
		if a.kind == stuck_kind then
			local tr = trains[a.train_id]
			if tr then
				if tr.p_station_id then out[tr.p_station_id] = true end
				if tr.r_station_id then out[tr.r_station_id] = true end
			end
		end
	end
	return out
end

--- Chip captions: names with counts when they all fit next to what else the subheader shows, else icon and count.
--- @param available int px left in the subheader
--- @param full int px the chips need with names
--- @return "full"|"compact"
function logic.chip_mode(available, full)
	return full <= available and "full" or "compact"
end

-- ---------------------------------------------------------------- inventory

--- What one network is still short of: requested − in transit − the providers' stock not yet promised to a delivery
--- (their signals plus their negative, outgoing deliveries). Stock already promised is in transit too, so it is
--- subtracted once. Never below 0: a surplus on one network covers nothing on another.
--- @param requested number? magnitude or the requested grid's negative count
--- @param in_transit number?
--- @param stock number? provider signals plus outgoing (negative) deliveries
--- @return number
function logic.deficit(requested, in_transit, stock)
	local short = math.abs(requested or 0) - (in_transit or 0) - math.max(stock or 0, 0)
	return short > 0 and short or 0
end

--- Provided items that no requester on the same network asks for: the provide keys ("network:hash") without a
--- matching request key, folded to item hashes. With `network`, only that network's keys count.
--- @param provide_keys {[string]: any}
--- @param request_keys {[string]: any}
--- @param network string?
--- @return {[string]: true}
function logic.unrequested(provide_keys, request_keys, network)
	local provided, matched = {}, {}
	local find, sub = string.find, string.sub
	for key in pairs(provide_keys) do
		local s = find(key, ":", 1, true)
		if s and (not network or sub(key, 1, s - 1) == network) then
			local hash = sub(key, s + 1)
			provided[hash] = true
			if request_keys[key] then matched[hash] = true end
		end
	end
	for hash in pairs(matched) do provided[hash] = nil end
	return provided
end

return logic
