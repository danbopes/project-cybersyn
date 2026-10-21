-- Level-scope helpers for the in-game characterization suite, sent once per boot by run.sh before any test file.
-- Everything lives in the global `lab` because each RCON command is a separate chunk: locals die with the command,
-- globals of the level script survive until the server stops.
--
-- Output protocol (one line each, parsed by run.sh):
--   PASS <suite>: <check>            FAIL <suite>: <check>: <detail>
--   INFO <suite>: <text>             WAIT <tick>            DONE <suite>
--   SKIP <check> (<why>)             a check whose subject does not exist yet (counted apart from PASS/FAIL)
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
		-- Phase 4: Control signals moved to the relative panel; Trains gained state, time in state and last refuel;
		-- the Requested grid gained deficit.
		stations = { "name", "station_status", "network", "priority", "provided_requested", "deliveries", "wait", "last_delivery" },
		trains = { "train_id", "train_status", "network", "layout", "depot", "state", "time_in_state", "last_refuel",
			"shipment" },
		inventory = { "item_order", "amount", "stations", "wait", "deficit" },
	},
	DEFAULT_SORT = {
		stations = { "name", true },
		trains = { "train_id", true },
		inventory = { "item_order", true },
	},
	STATUSES = { "no_power", "disabled", "warming_up", "starved", "setup", "saturated", "idle", "ok" },
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

--- An emulated 8K screen at UI scale 1 for player `pi`: the window then fits more rows than this save has stations, so
--- every characterization list is one page, as before the window was sized from the screen (PLAN3 §4.3).
function lab.big_screen(pi)
	return remote.call(lab.D, "set_layout", pi or lab.pi, 7680, 4320, 1)
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
	lab.big_screen(pi)
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
			lists[name] = { keys = list.keys, order = list.order, total = list.total, acked_total = list.acked_total }
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
	lab.cur.wait_cond = nil
	game.speed = speed or 20
end

--- Like lab.wait, but the next step runs as soon as `cond()` is true (checked on every lab.resume), or after
--- `max_ticks` at the latest. The next step must check the condition itself: a timeout is not a failure here.
--- @param cond fun(): boolean
--- @param max_ticks integer
--- @param speed number?
function lab.wait_until(cond, max_ticks, speed)
	lab.cur.wait_until = game.tick + max_ticks
	lab.cur.wait_cond = cond
	game.speed = speed or 20
end

--- A check that cannot run yet. run.sh counts SKIP lines apart from PASS and FAIL.
--- @param name string
--- @param why string
function lab.skip(name, why)
	local suite = lab.cur and lab.cur.name or "lab"
	out("SKIP " .. suite .. ": " .. name .. " (" .. why .. ")")
end

function lab.resume()
	local s = lab.cur
	if not s then
		out("DONE none")
		return
	end
	if s.wait_until then
		local cond = s.wait_cond
		if game.tick < s.wait_until and not (cond and cond()) then
			out("WAIT " .. s.wait_until)
			return
		end
		s.wait_until = nil
		s.wait_cond = nil
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

-- ---------------------------------------------------------------- the setup lint's view (PLAN4 D7)
--
-- lab.problems_verify(label) is used by 37_tabs, 39_lint and 40_reason_codes: every finding of the last lint pass is
-- exactly once in the Stations Problems view (station subjects in their station's row, stops and combinators as
-- registry rows after the stations; depots, refuelers and trains render on the Trains tab and are checked for their
-- texts), each with its check's chip, fix line and detail numbers; it notes which checks it saw, so the last suite can
-- assert that every check produced a correct row somewhere in the run (lab.problems_coverage).

lab.problems_seen = lab.problems_seen or {}

local function lint_key_of(c)
	return type(c) == "table" and c[1] or c
end

local function lint_dash(name)
	return (string.gsub(name, "_", "-"))
end

--- "12,345" as flib's format.number writes it.
local function lint_number(v)
	local s = tostring(math.floor(math.abs(v)))
	local o = s:reverse():gsub("(%d%d%d)", "%1,"):reverse()
	if o:sub(1, 1) == "," then o = o:sub(2) end
	return (v < 0 and "-" or "") .. o
end

-- The k-format the detail cells write amounts in (scripts/lib.lua format_signal_count): "2.0k", "10k", "400".
local function lint_count(v)
	local abs = math.abs(v)
	local function si(divisor, symbol)
		if math.abs(math.floor(v / divisor)) >= 10 then return string.format("%.0f%s", math.floor(v / divisor), symbol) end
		return string.format("%.1f%s", math.floor(v / (divisor / 10)) / 10, symbol)
	end
	if abs >= 1e9 then return si(1e9, "G") end
	if abs >= 1e6 then return si(1e6, "M") end
	if abs >= 1e3 then return si(1e3, "k") end
	return tostring(v)
end

-- The detail numbers each check shows: "n" formatted, "s" as a plain integer (masks), nil = none.
local LINT_NUMBERS = {
	capacity = { a = "n", b = "n" },
	layout = { a = "n", b = "n" },
	mask = { a = "s", b = "s" },
	occupancy = { a = "n", b = "n" },
	depot_limit = { a = "n" },
	priority = { a = "n" },
	depot_shared_name = { a = "n", b = "n" },
	refueler_mask = { a = "s", b = "s" },
	in_group = { a = "n" },
	missing_stop = { a = "n" },
	capacity_drift = { a = "n", b = "n" },
	train_mask = { a = "s", b = "s" },
	same_item = { a = "n" },
}

--- @return string? why the entry's detail is wrong
local function lint_detail_wrong(row)
	local detail = row.detail
	local text = serpent.line(detail, { comment = false })
	if row.message then
		if lint_key_of(detail) == "cybersyn-gui.problems-world-" .. tostring(row.message) then return nil end
		return "world key"
	end
	local key = lint_key_of(detail)
	local want_key = "cybersyn-diag.lint-detail-" .. lint_dash(row.check)
	if string.sub(key, 1, #want_key) ~= want_key then return "key " .. key end
	-- PLAN4 D10: a counter leak shows the deliveries no train serves, a bound train its id and the counted ones.
	if row.check == "phantom" then
		local leak = key == "cybersyn-diag.lint-detail-phantom-leak"
		local v = leak and row.a - row.b or row.a
		local s, k = lint_number(v), lint_count(v)
		if not (string.find(text, '"' .. s .. '"', 1, true) or string.find(text, '"' .. k .. '"', 1, true)) then
			return "phantom " .. s .. " not in " .. text
		end
		if row.train and not string.find(text, '"' .. row.train .. '"', 1, true) then return "phantom train" end
	end
	if row.check == "occupancy" and row.train and not string.find(text, '"' .. row.train .. '"', 1, true) then
		return "occupancy train"
	end
	local want = LINT_NUMBERS[row.check] or {}
	for _, field in ipairs({ "a", "b" }) do
		local how, v = want[field], row[field]
		local skip = (row.check == "mask" and row.a == 0) or (row.check == "depot_limit" and row.a < 0)
			or (row.check == "same_item" and row.a == 0)
		if how and v and not skip then
			local s = how == "n" and lint_number(v) or tostring(v)
			local k = how == "n" and lint_count(v) or s
			if not (string.find(text, '"' .. s .. '"', 1, true) or string.find(text, '"' .. k .. '"', 1, true)) then
				return field .. " " .. s .. " (" .. k .. ") not in " .. text
			end
		end
	end
	if row.item and row.check ~= "layout" then
		local name = string.match(row.item, "^[^|]+")
		if not string.find(text, name, 1, true) then return "item " .. row.item end
	end
	if row.network and (row.check == "layout" or row.check == "no_provider" or row.check == "refueler_mask"
		or row.check == "train_mask" or row.check == "no_train" or row.check == "never_refuelled") then
		if not string.find(text, row.network, 1, true) then return "network " .. row.network end
	end
	return nil
end

local function lint_id_of(f)
	return f.check .. "|" .. f.subject .. "|" .. f.id .. "|" .. tostring(f.item or f.message or "")
end

--- Every finding of the last lint pass is exactly one entry of the Stations Problems view (stations and registry), or
--- for depots, refuelers and trains has correct texts. With `collect` (inside a tick handler, where nothing can be
--- printed) the results are appended to it as {name, ok, detail} for the caller to check later.
--- @return table the view (dev stations_lint_view)
function lab.problems_verify(label, collect)
	local check = collect and function(name, ok, detail) collect[#collect + 1] = { name, ok and true or false, detail } end
		or lab.check
	local v = remote.call(lab.D, "stations_lint_view")
	if not v.snapshot then
		-- With every window closed the snapshot is released; the view reopens on a collected one.
		remote.call(lab.D, "collect")
		v = remote.call(lab.D, "stations_lint_view")
	end
	local wrong, seen = {}, {}
	local function entry(e, where)
		local id = lint_id_of(e)
		seen[id] = (seen[id] or 0) + 1
		local why = lint_detail_wrong(e)
		if why then wrong[#wrong + 1] = where .. " " .. e.check .. " " .. e.id .. ": " .. why end
		-- A counter leak (more deliveries counted than trains bound) has its own fix line: Recount deliveries.
		local fix = (e.check == "phantom" and (e.a or 0) > (e.b or 0)) and "phantom-leak" or lint_dash(e.check)
		if lint_key_of(e.fix) ~= "cybersyn-diag.lint-fix-" .. fix then wrong[#wrong + 1] = e.check .. " fix" end
		if lint_key_of(e.chip) ~= "cybersyn-diag.lint-chip-" .. lint_dash(e.check) then wrong[#wrong + 1] = e.check .. " chip" end
		if not why then lab.problems_seen[e.check] = true end
	end
	local empty_rows = {}
	for _, row in ipairs(v.stations) do
		if #row.entries == 0 then empty_rows[#empty_rows + 1] = row.id end
		for _, e in ipairs(row.entries) do
			if e.subject ~= "station" or e.id ~= row.id then wrong[#wrong + 1] = "station row " .. row.id .. " holds " .. lint_id_of(e) end
			entry(e, "station")
		end
	end
	local registry_seen = {}
	for _, r in ipairs(v.registry) do
		entry(r.entry, "registry")
		registry_seen[lint_id_of(r.entry)] = (registry_seen[lint_id_of(r.entry)] or 0) + 1
	end
	for _, e in ipairs(v.others) do
		local why = lint_detail_wrong(e)
		if why then wrong[#wrong + 1] = e.subject .. " " .. e.check .. " " .. e.id .. ": " .. why
		else lab.problems_seen[e.check] = true end
	end
	-- Station findings: once each in the view.
	local want, missing, n = {}, {}, 0
	for _, f in ipairs(remote.call(lab.D, "lint_findings")) do
		if f.subject == "station" then
			want[lint_id_of(f)] = (want[lint_id_of(f)] or 0) + 1
			n = n + 1
		end
	end
	local in_view = 0
	for id, c in pairs(seen) do
		if string.find(id, "|station|", 1, true) then in_view = in_view + c end
	end
	for id, c in pairs(want) do
		if seen[id] ~= c then missing[#missing + 1] = id end
	end
	check(label .. ": every station finding is exactly once in the Stations Problems view", #missing == 0 and in_view == n
		and #empty_rows == 0, { findings = n, in_view = in_view, missing = missing, rows_without_finding = empty_rows })
	-- Stops and combinators: once each as a registry row.
	local raw, extra = {}, {}
	for _, e in ipairs(v.raw_registry) do raw[lint_id_of(e)] = (raw[lint_id_of(e)] or 0) + 1 end
	for id, c in pairs(raw) do
		if registry_seen[id] ~= c then extra[#extra + 1] = id end
	end
	for id in pairs(registry_seen) do
		if not raw[id] then extra[#extra + 1] = id end
	end
	check(label .. ": every stop and combinator finding is exactly once a registry row", #extra == 0,
		{ raw = #v.raw_registry, rows = #v.registry, differ = extra })
	check(label .. ": every finding has its check's chip, fix line and detail numbers", #wrong == 0, wrong)
	return v
end

--- Every check has produced a correct row somewhere in the run (called by the last suite).
function lab.problems_coverage()
	local missing = {}
	for _, name in ipairs({ "capacity", "layout", "mask", "no_provider", "limit_zero", "same_item", "occupancy",
		"phantom", "depot_limit", "depot_shared_name", "refueler_mask", "never_refuelled", "in_group", "missing_stop",
		"capacity_drift", "derelict_comb", "ghost_comb", "no_comb", "wrong_side", "double_comb", "priority",
		"name_overlap", "train_mask", "no_train" }) do
		if not lab.problems_seen[name] then missing[#missing + 1] = name end
	end
	lab.check("Problems view: every one of the 24 checks produced a correct row in this run", #missing == 0, missing)
end

out("INFO lab: lib loaded at tick " .. game.tick)
