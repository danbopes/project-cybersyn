-- Level-scope helpers for the in-game characterization suite, sent once per boot by run.sh before any test file.
-- Everything lives in the global `lab` because each RCON command is a separate chunk: locals die with the command,
-- globals of the level script survive until the server stops.
--
-- Output protocol (one line each, parsed by run.sh):
--   PASS <suite>: <check>            FAIL <suite>: <check>: <detail>
--   INFO <suite>: <text>             WAIT <tick>            DONE <suite>
-- A suite is a list of steps. A step that needs game time calls lab.wait(n) and returns; the server keeps running
-- and run.sh calls lab.resume() until the target tick is reached, so no RCON command ever blocks a tick.

lab = {
	D = "cybersyn-manager-dev",
	pi = 1,
	passed = 0,
	failed = 0,
	TABS = { "overview", "inventory", "stations", "trains" },
	GRIDS = { "provided", "in_transit", "requested" },
	SORTS = {
		stations = { "name", "station_status", "network", "provided_requested", "deliveries", "control_signals", "wait",
			"last_delivery" },
		trains = { "train_id", "train_status", "network", "layout", "depot", "shipment" },
		inventory = { "item_order", "amount", "stations", "wait" },
	},
	DEFAULT_SORT = {
		stations = { "name", true },
		trains = { "train_id", true },
		inventory = { "item_order", true },
	},
	STATUSES = { "no_power", "disabled", "warming_up", "starved", "saturated", "idle", "ok" },
	PERIODS = { 10, 60, 1440 },
}

local function out(line)
	rcon.print(line)
end

--- @param name string
--- @param cond any
--- @param detail any?
--- @return boolean
function lab.check(name, cond, detail)
	local suite = lab.cur and lab.cur.name or "lab"
	if cond then
		lab.passed = lab.passed + 1
		out("PASS " .. suite .. ": " .. name)
		return true
	end
	lab.failed = lab.failed + 1
	if type(detail) == "table" then detail = serpent.line(detail, { nocode = true, maxlevel = 4 }) end
	out("FAIL " .. suite .. ": " .. name .. (detail ~= nil and (": " .. tostring(detail)) or ""))
	return false
end

--- Strings print as-is; anything else (a LocalisedString with profilers) goes through rcon.print's translator.
function lab.info(text)
	local suite = lab.cur and lab.cur.name or "lab"
	if type(text) == "table" then
		rcon.print({ "", "INFO " .. suite .. ": ", text })
	else
		out("INFO " .. suite .. ": " .. tostring(text))
	end
end

function lab.dev(fn, ...)
	return remote.call(lab.D, fn, ...)
end

function lab.read(...)
	return remote.call("cybersyn", "read_global", ...)
end

--- Calls a dev function, turning an error into a FAIL line instead of aborting the step.
--- @return boolean ok
--- @return any result
function lab.try(name, fn, ...)
	local ok, res = pcall(remote.call, lab.D, fn, ...)
	if not ok then lab.check(name, false, res) end
	return ok, res
end

function lab.count(t)
	local n = 0
	for _ in pairs(t or {}) do n = n + 1 end
	return n
end

--- @param list any[]
--- @return {[any]: true}
function lab.set_of(list)
	local s = {}
	for _, v in pairs(list or {}) do s[v] = true end
	return s
end

--- @return boolean ok
--- @return any first element of `sub` missing from `super`
function lab.subset(sub, super)
	local s = lab.set_of(super)
	for _, v in pairs(sub or {}) do
		if not s[v] then return false, v end
	end
	return true
end

function lab.same_list(a, b)
	a, b = a or {}, b or {}
	local n = math.max(#a, #b)
	for i = 1, n do
		if a[i] ~= b[i] then return false, i end
	end
	return true
end

--- Checks that dumped sort keys are in display order. Keys missing (nil or false) must all come last in either
--- direction; present keys must be monotonic. The expected order comes from the values alone.
--- @param keys any[] may contain holes
--- @param n integer number of rows
--- @param ascending boolean
--- @return boolean ok
--- @return string? detail
function lab.ordered(keys, n, ascending)
	local seen_missing = false
	local prev
	for i = 1, n do
		local k = keys[i]
		if k == nil or k == false then
			seen_missing = true
		else
			if seen_missing then return false, "row " .. i .. " has a key after a missing one" end
			if prev ~= nil then
				if type(prev) ~= type(k) then return false, "mixed key types at row " .. i end
				if ascending and k < prev or (not ascending) and k > prev then
					return false, string.format("row %d: %s after %s (%s)", i, tostring(k), tostring(prev),
						ascending and "asc" or "desc")
				end
			end
			prev = k
		end
	end
	return true
end

--- Row identities of every tab, in display order, from the dumpers. Overview lists show their top rows only, so
--- `overview_total` carries each list's full length next to the shown keys.
--- @return table
function lab.tab_keys(pi)
	pi = pi or lab.pi
	local keys = {}
	for _, tab in ipairs(lab.TABS) do
		lab.dev("select_tab", pi, tab)
		local d = lab.dev("dump", pi, tab)
		if tab == "stations" or tab == "trains" then
			keys[tab] = d.ids
		elseif tab == "inventory" then
			keys[tab] = {}
			for _, g in ipairs(lab.GRIDS) do keys[tab][g] = d[g] and d[g].hashes or {} end
		else
			keys[tab] = {}
			keys.overview_total = {}
			for name, list in pairs(d.lists or {}) do
				keys[tab][name] = list.keys
				keys.overview_total[name] = list.total
			end
		end
	end
	return keys
end

--- The filter cases both the golden summary and 20_manager apply, as {label, filter}.
--- @param item string? an item hash to filter by
--- @return {[1]: string, [2]: table}[]
function lab.filter_cases(item)
	return {
		{ "query stn-1", { query = "stn-1" } },
		{ "item " .. tostring(item), { item = item } },
		{ "network signal-A", { network = "signal-A" } },
		{ "network signal-B", { network = "signal-B" } },
		{ "mask 2", { mask = 2 } },
		{ "surface cyb-bench", { surface = game.surfaces["cyb-bench"].index } },
		{ "surface nauvis", { surface = game.surfaces.nauvis.index } },
	}
end

--- Sets the stations tab's status chip (nil = all) through the tab's own dev interface.
--- @return string the active filter, "all" when none
function lab.set_status_filter(pi, status)
	return remote.call("cybersyn-manager-dev-stations", "set_status_filter", pi or lab.pi, status or false)
end

local function dir(asc) return asc and "asc" or "desc" end

--- Every value the manager derives that a refactor must keep, at one tick: rows under each filter and status chip,
--- every sort column in both directions (so tie order and key semantics are pinned, not only the default sort),
--- station statuses and chip counts, inventory amounts and station counts as raw numbers, and the Overview model
--- (tiles and lists) for every period. Leaves the player's filters, sorts, period and chip as they were by default.
--- The manager must be open.
--- @return table
function lab.golden(pi)
	pi = pi or lab.pi
	local D = lab.D
	local out = { filters = {}, sorts = {}, stations = {}, overview_model = {} }
	remote.call(D, "clear_filters", pi)
	lab.set_status_filter(pi, nil)
	for tab, def in pairs(lab.DEFAULT_SORT) do remote.call(D, "set_sort", pi, tab, def[1], def[2]) end

	remote.call(D, "select_tab", pi, "stations")
	local st = remote.call(D, "dump", pi, "stations")
	local status = {}
	for i, id in ipairs(st.ids) do status[tostring(id)] = st.statuses[i] or false end
	out.stations = { status = status, counts = st.counts, stripes_ok = st.stripes_ok, total = st.total }
	local chips = {}
	for _, s in ipairs(lab.STATUSES) do
		lab.set_status_filter(pi, s)
		chips[s] = remote.call(D, "dump", pi, "stations").ids
	end
	lab.set_status_filter(pi, nil)
	out.stations.chips = chips

	local first_item = lab.tab_keys(pi).inventory.provided[1]
	for _, case in ipairs(lab.filter_cases(first_item)) do
		remote.call(D, "clear_filters", pi)
		remote.call(D, "set_filter", pi, case[2])
		out.filters[case[1]] = lab.tab_keys(pi)
	end
	remote.call(D, "clear_filters", pi)

	for _, tab in ipairs({ "stations", "trains" }) do
		remote.call(D, "select_tab", pi, tab)
		local by_column = {}
		for _, column in ipairs(lab.SORTS[tab]) do
			by_column[column] = {}
			for _, asc in ipairs({ true, false }) do
				remote.call(D, "set_sort", pi, tab, column, asc)
				by_column[column][dir(asc)] = remote.call(D, "dump", pi, tab).ids
			end
		end
		out.sorts[tab] = by_column
	end
	remote.call(D, "select_tab", pi, "inventory")
	local inv = {}
	for _, column in ipairs(lab.SORTS.inventory) do
		inv[column] = {}
		for _, asc in ipairs({ true, false }) do
			remote.call(D, "set_sort", pi, "inventory", column, asc)
			local d = remote.call(D, "dump", pi, "inventory")
			local grids = {}
			for _, g in ipairs(lab.GRIDS) do
				-- Raw numbers, not captions: amounts and station counts survive a change of number formatting.
				grids[g] = { hashes = d[g].hashes, keys = d[g].keys, column = d[g].column, stale = d[g].stale }
			end
			inv[column][dir(asc)] = grids
		end
	end
	out.sorts.inventory = inv
	for tab, def in pairs(lab.DEFAULT_SORT) do remote.call(D, "set_sort", pi, tab, def[1], def[2]) end

	remote.call(D, "select_tab", pi, "overview")
	local period = remote.call(D, "dump", pi, "overview").period
	for _, minutes in ipairs(lab.PERIODS) do
		remote.call(D, "set_period", pi, minutes)
		local d = remote.call(D, "dump", pi, "overview")
		local lists = {}
		for name, list in pairs(d.lists) do
			lists[name] = { keys = list.keys, order = list.order, total = list.total }
		end
		out.overview_model[tostring(minutes)] = { tiles = d.tiles, lists = lists }
	end
	remote.call(D, "set_period", pi, period)
	return out
end

-- ---- suites ------------------------------------------------------------------

--- Starts a suite. `steps` run in order; each gets the shared context table.
--- @param name string
--- @param steps fun(ctx: table)[]
function lab.suite(name, steps)
	lab.cur = { name = name, steps = steps, i = 0, ctx = {} }
	lab.resume()
end

--- Asks for `ticks` of game time before the next step, at `speed` (default 20).
function lab.wait(ticks, speed)
	lab.cur.wait_until = game.tick + ticks
	game.speed = speed or 20
end

function lab.resume()
	local s = lab.cur
	if not s then
		out("DONE none")
		return
	end
	if s.wait_until then
		if game.tick < s.wait_until then
			out("WAIT " .. s.wait_until)
			return
		end
		s.wait_until = nil
		game.speed = 1
	end
	while s.i < #s.steps do
		s.i = s.i + 1
		local ok, err = xpcall(s.steps[s.i], debug.traceback, s.ctx)
		if not ok then lab.check("step " .. s.i .. " ran", false, err) end
		if s.wait_until then
			out("WAIT " .. s.wait_until)
			return
		end
	end
	game.speed = 1
	out("DONE " .. s.name)
	lab.cur = nil
end

out("INFO lab: lib loaded at tick " .. game.tick)
