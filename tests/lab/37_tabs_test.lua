-- PLAN3 phase 4: the Stations, Trains and Inventory tabs. Every chip shows exactly the rows its count promises, with
-- and without a surface filter; Setup / Unserved / Failing count the same records as the Overview; the Trains hidden
-- columns, time-in-state order, the Not refuelled chip against refuel_tick and the per-user hours, the depot groups
-- against snapshot.depots_by_name; the Inventory's per-grid sorts (deficit from an oracle), Dim unrequested against
-- an oracle from the station records, "Delivered · last hour" against stats.aggregate; link cells are tag buttons.
-- Expected values come from the snapshot or Cybersyn's storage, never from the tab's own counts alone.

local D, pi = lab.D, lab.pi
local DS, DT, DI = "cybersyn-manager-dev-stations", "cybersyn-manager-dev-trains", "cybersyn-manager-dev-inventory"
local STATION_CHIPS = { "no_power", "disabled", "warming_up", "starved", "setup", "saturated", "idle", "ok", "unserved", "problems",
	"stuck", "failing" }
local TRAIN_CHIPS = { "parked", "to_p", "loading", "to_r", "unloading", "returning", "refuel", "interrupt",
	"not_refuelled", "in_group", "trouble", "problems" }
local HANDLER = "__cybersyn_handler"
local HOUR = 216000

local function key_of(c)
	return type(c) == "table" and c[1] or c
end

local function snapshot()
	return lab.read("manager").snapshot
end

local function stations_dump()
	remote.call(D, "select_tab", pi, "stations")
	return remote.call(D, "dump", pi, "stations")
end

local function trains_dump()
	remote.call(D, "select_tab", pi, "trains")
	return remote.call(D, "dump", pi, "trains")
end

--- Every string and locale key of a LocalisedString, depth first, in reading order.
local function leaves(ls, out)
	out = out or {}
	if type(ls) ~= "table" then
		out[#out + 1] = ls
		return out
	end
	if ls[1] ~= "" then out[#out + 1] = { key = ls[1] } end
	for i = 2, #ls do leaves(ls[i], out) end
	return out
end

--- The "Trains by state" counts of a group row's hover box: {train-state key suffix = n}, and their sum.
local function tooltip_states(tip)
	local out, sum = {}, 0
	local l = leaves(tip)
	for i, v in ipairs(l) do
		if type(v) == "table" and v.key:find("^cybersyn%-diag%.train%-state%-") then
			local n = tonumber(((l[i + 1] or ""):gsub("[^%d]", "")))
			out[(v.key:gsub("^cybersyn%-diag%.train%-state%-", ""))] = n
			sum = sum + (n or 0)
		end
	end
	return out, sum
end

--- The train count of a group row's hover box head ("depot-0 · 6 trains").
local function tooltip_head(tip)
	for _, v in ipairs(leaves(tip)) do
		if type(v) == "table" and v.key == "cybersyn-gui.trains-group-head" then return v end
	end
end

--- Every chip toggled in turn shows as many rows as its count said before (big screen: one page).
--- @param label string
local function check_station_chips(label)
	remote.call(DS, "set_chip", pi, "all")
	local d0 = stations_dump()
	local counts = {}
	for k, v in pairs(d0.counts) do counts[k] = v end
	for k, v in pairs(d0.chip_counts) do counts[k] = v end
	for _, chip in ipairs(STATION_CHIPS) do
		remote.call(DS, "set_chip", pi, chip)
		local d = stations_dump()
		lab.check(label .. ": Stations chip " .. chip .. " count == rows shown", d.total == counts[chip] and #d.ids == d.total
			and (counts[chip] == 0 or d.chip == chip), { count = counts[chip], total = d.total, rows = #d.ids, chip = d.chip })
		if lab.STATUSES and counts[chip] and d.statuses and chip ~= "unserved" and chip ~= "problems" and chip ~= "stuck"
			and chip ~= "failing" then
			local same = true
			for _, s in ipairs(d.statuses) do
				if s ~= chip then same = false end
			end
			lab.check(label .. ": Stations chip " .. chip .. " rows all have that status", same, d.statuses)
		end
	end
	remote.call(DS, "set_chip", pi, "all")
	return counts
end

--- @param label string
local function check_train_chips(label)
	remote.call(DT, "set_chip", pi, "all")
	local d0 = trains_dump()
	for _, chip in ipairs(TRAIN_CHIPS) do
		remote.call(DT, "set_chip", pi, chip)
		local d = trains_dump()
		lab.check(label .. ": Trains chip " .. chip .. " count == rows shown", d.total == d0.counts[chip] and #d.ids == d.total,
			{ count = d0.counts[chip], total = d.total, rows = #d.ids })
	end
	remote.call(DT, "set_chip", pi, "all")
	return d0.counts
end

--- The value found under a LocalisedString key anywhere inside a tooltip, or nil.
local function find_key(ls, key)
	if type(ls) ~= "table" then return nil end
	if ls[1] == key then return ls end
	for i = 2, #ls do
		local found = find_key(ls[i], key)
		if found then return found end
	end
	return nil
end

lab.suite("37_tabs", {
	function(ctx)
		ctx.planner = settings.global["cybersyn-enable-planner"].value
		lab.dev("set_setting", "cybersyn-enable-planner", false)
		remote.call(D, "open", pi)
		remote.call(D, "clear_filters", pi)
		lab.set_status_filter(pi, nil)
		lab.big_screen(pi)
		-- The lint job runs only while a window is open; a whole pass now, then a collector pass copies its bits.
		lab.dev("lint_run")
		lab.dev("collect")
		for tab, def in pairs(lab.DEFAULT_SORT) do remote.call(D, "set_sort", pi, tab, def[1], def[2]) end

		-- Stations: every chip, then the counts against the records.
		local counts = check_station_chips("no filter")
		local snap = snapshot()
		local lint, unserved, failing = 0, 0, 0
		for _, st in pairs(snap.stations) do
			local f = false
			if (st.lint or 0) ~= 0 then
				lint = lint + 1
				f = true
			end
			if st.unserved and st.unserved.count > 0 then unserved = unserved + 1 end
			if st.status == "no_power" or st.status == "disabled" or st.throttling then f = true end
			if f then failing = failing + 1 end
		end
		lab.check("Problems chip == stations with st.lint ~= 0", counts.problems == lint and lint > 0, { chip = counts.problems, records = lint })
		lab.check("Unserved chip == stations with st.unserved.count > 0", counts.unserved == unserved, { chip = counts.unserved, records = unserved })
		lab.check("Failing chip == no power + disabled + throttling + problems records", counts.failing == failing, { chip = counts.failing, records = failing })
		remote.call(D, "select_tab", pi, "overview")
		local o = remote.call(D, "dump", pi, "overview")
		lab.check("Failing chip == the Overview's Stations failing tile (one number per fact)",
			o.tiles.failing and o.tiles.failing.headline == counts.failing, { tile = o.tiles.failing, chip = counts.failing })

		-- PLAN4 D15-5: an otherwise OK station with an error nobody acknowledged reads Setup (its own chip, not in
		-- OK); every other status stays. The stop panel's Status line says the same; an acknowledgement turns it back.
		do
			local em = o.lint_error_mask
			local sd = stations_dump()
			local recs = snapshot().stations
			local wrong, setup_id = {}, nil
			local n_setup = 0
			for i, id in ipairs(sd.ids) do
				local rec = recs[id]
				local want = rec.status or "ok"
				if want == "ok" and bit32.band(rec.lint or 0, em) ~= 0 then want = "setup" end
				if sd.statuses[i] ~= want then wrong[#wrong + 1] = { id = id, got = sd.statuses[i], want = want } end
				if want == "setup" then
					n_setup = n_setup + 1
					if not setup_id or id < setup_id then setup_id = id end
				end
			end
			lab.check("Status reads Setup for every OK station with an open error, and only for those", #wrong == 0
				and n_setup > 0, { wrong = wrong, setup = n_setup })
			local n_ok = 0
			for _, x in ipairs(sd.statuses) do
				if x == "ok" then n_ok = n_ok + 1 end
			end
			lab.check("Setup is its own chip and leaves OK", counts.setup == n_setup and counts.ok == n_ok,
				{ setup = counts.setup, want = n_setup, ok = counts.ok, rows = n_ok })
			if setup_id then
				local function head()
					return serpent.line(lab.dev("relative_open", pi, "stop", setup_id).sections.head.content, { comment = false })
				end
				local h = head()
				lab.check("stop panel: Status reads Setup", h:find("station-status-setup", 1, true) ~= nil, h)
				lab.check("stop panel head: Role, Network and Status are labels of their own (no colon) beside their values",
					h:find('{"cybersyn-gui.relative-role"}', 1, true) ~= nil and h:find('{"cybersyn-gui.relative-network"}', 1, true) ~= nil
					and h:find('{"cybersyn-gui.relative-status"}', 1, true) ~= nil, h)
				lab.dev("relative_close", pi)
				local acked = {}
				for check = 1, 32 do
					if bit32.band(recs[setup_id].lint, em, bit32.lshift(1, check - 1)) ~= 0 then
						lab.dev("diag_ack", "lint", setup_id, check, nil, pi)
						acked[#acked + 1] = check
					end
				end
				local function status_of(id)
					local x = stations_dump()
					for i, sid in ipairs(x.ids) do
						if sid == id then return x.statuses[i], x.counts end
					end
				end
				local after, c = status_of(setup_id)
				local h2 = head()
				lab.dev("relative_close", pi)
				lab.check("acknowledged: Status is OK again on Stations and the stop panel", after == "ok" and c.setup == n_setup - 1
					and h2:find("station-status-ok", 1, true) ~= nil, { status = after, counts = c, acked = acked })
				for _, check in ipairs(acked) do lab.dev("diag_unack", "lint", setup_id, check, pi) end
				after = status_of(setup_id)
				lab.check("unacknowledged: Setup again", after == "setup", after)
			end
		end

		-- PLAN4 D7 flipped round 3's row-level Setup chip: the Status column shows the status only (no dead button).
		local d = stations_dump()
		local list = d.status_children
		local ok = true
		for _, n in ipairs(list or {}) do
			if n ~= 2 then ok = false end
		end
		lab.check("the Status column holds the status dot and caption only (row Setup chip removed)", list ~= nil and #list > 0
			and ok, list)

		-- Stuck: a stuck alert on a train names its provider and requester.
		local train_id, train
		for id, tr in pairs(snap.trains) do
			if tr.p_station_id and (not train_id or id < train_id) then train_id, train = id, tr end
		end
		if train_id then
			remote.call("cybersyn", "write_global", { { train_id = train_id, kind = 1, since_tick = game.tick } }, "manager", "snapshot", "alerts")
			remote.call(DS, "set_chip", pi, "stuck")
			local sd = stations_dump()
			local want = { [train.p_station_id] = true }
			if train.r_station_id then want[train.r_station_id] = true end
			local same = lab.count(want) == #sd.ids
			for _, id in ipairs(sd.ids) do
				if not want[id] then same = false end
			end
			lab.check("Stuck train chip shows the provider and requester of a train with a stuck alert", same, { ids = sd.ids, want = want })
			remote.call(DS, "set_chip", pi, "all")
			lab.dev("collect")
		else
			lab.skip("Stuck train chip", "no train with a provider on this save")
		end

		-- Surface filters narrow every chip count.
		for _, name in ipairs({ "cyb-bench", "nauvis" }) do
			remote.call(D, "set_filter", pi, { surface = game.surfaces[name].index })
			check_station_chips("surface " .. name)
			check_train_chips("surface " .. name)
			remote.call(D, "clear_filters", pi)
		end
	end,

	-- PLAN4 D7: the Problems chip's view on Stations. Chip count == station rows (with and without a surface filter),
	-- every finding once (lab.problems_verify), the Problems column shows each row's worst finding with "+n", stops
	-- and combinators that are not a station follow as registry rows linked to their entity; acknowledging from the
	-- row; the stop panel's Setup section still renders.
	function(ctx)
		remote.call(D, "clear_filters", pi)
		lab.set_status_filter(pi, nil)
		lab.big_screen(pi)
		-- A combinator with no stop in reach: the registry reports it.
		local s = game.surfaces["cyb-bench"]
		local comb = s.create_entity({ name = "cybersyn-combinator", position = { 0.5, -60.5 }, force = game.forces.player })
		script.raise_script_built({ entity = comb })
		ctx.derelict = comb
		lab.dev("lint_run")
		lab.dev("collect")
		local v = lab.problems_verify("37_tabs Problems view")
		local derelict
		for _, r in ipairs(v.registry) do
			if r.entry.id == comb.unit_number then derelict = r end
		end
		lab.check("the derelict combinator is a registry row of the Problems view", derelict ~= nil and
			derelict.entry.check == "derelict_comb" and derelict.entity, v.registry)

		remote.call(DS, "set_chip", pi, "problems")
		local d = stations_dump()
		lab.check("Problems chip: count == station rows, the view sorts worst first, column 4 is Problems",
			d.chip == "problems" and d.total == d.chip_counts.problems and #d.ids == d.total and d.total > 0
			and d.column == "problems" and d.ascending == true and d.header[4] == "problems",
			{ chip = d.chip, total = d.total, count = d.chip_counts.problems, rows = #d.ids, column = d.column, header = d.header })
		local want = {}
		for _, row in ipairs(v.stations) do want[row.id] = row end
		local same = #d.ids == #v.stations
		for _, id in ipairs(d.ids) do
			if not want[id] then same = false end
		end
		lab.check("Problems chip: the rows are the stations with a finding", same, { rows = d.ids, view = #v.stations })
		local w = d.widths
		lab.check("Problems view: the Problems column stretches, Deliveries keeps two slots", w and w.problems_view
			and w.dl_slots == 2 and w.problems > w.name and w.problems > w.deliveries and w.name >= 160
			and w.cw - 72 + (w.hide_wait and 8 or 0) - w.name - w.station_status - w.network - w.problems - w.deliveries - w.wait
				- w.last_delivery == 0, w)
		local caps = d.chip_captions or {}
		lab.check("the Problems chip leads with the warning triangle, Setup with its yellow dot",
			type(caps.problems) == "table" and caps.problems[2] == "[img=utility/warning_icon] "
			and type(caps.setup) == "table" and caps.setup[2] == "[img=flib_indicator_yellow] ", caps)
		local sorted = true
		for i = 2, #d.keys do
			if d.keys[i] < d.keys[i - 1] then sorted = false end
		end
		lab.check("Problems view: worst severity then check, row by row", sorted, d.keys)
		local cells_ok, bad = true, {}
		for i, id in ipairs(d.ids) do
			local p, row = d.problems[i], want[id]
			local first = row and row.entries[1]
			local more = row and #row.entries > 1 and ("+" .. (#row.entries - 1)) or false
			if not (p and first and key_of(p.chip) == key_of(first.chip) and key_of(p.detail) == key_of(first.detail)
				and p.more == more and p.ack ~= nil and p.ack_tags.sid == id) then
				cells_ok = false
				bad[#bad + 1] = { id = id, cell = p, first = first and first.check, n = row and #row.entries }
			end
		end
		lab.check("Problems column: each row spells out its worst finding, '+n' for the rest, an acknowledge button",
			cells_ok, bad)
		lab.check("Problems view: the registry rows follow the stations, one per stop or combinator finding",
			d.registry_last and #d.registry == #v.registry and #d.registry > 0, { rows = d.registry, view = #v.registry })
		local reg
		for _, r in ipairs(d.registry) do
			if string.find(r.key, ":" .. comb.unit_number .. ":", 1, true) then reg = r end
		end
		lab.check("registry row: the combinator links to its entity and names its check", reg ~= nil and reg.link[1] == "entity"
			and reg.link[2] == comb.unit_number and reg.problems and key_of(reg.problems.chip) == "cybersyn-diag.lint-chip-derelict-comb",
			reg)
		local summary = d.summary
		if type(summary) == "table" and summary[1] == "" then summary = summary[2] end
		lab.check("Problems view: the subfooter counts the registry rows", key_of(summary) == "cybersyn-gui.stations-summary-registry",
			d.summary)

		-- PLAN4 D2/D7: the Overview's Misconfigured line and the view it jumps to agree on one number. The oracle is the
		-- findings themselves: a station with an error-severity finding nobody acknowledged counts, one whose errors are
		-- all acknowledged is "+n acked". Those stations lead the view, and the subfooter carries both numbers.
		local function misconfigured_oracle(surface)
			local view = remote.call(D, "stations_lint_view")
			local snap = snapshot()
			local open, acked = {}, 0
			for _, row in ipairs(view.stations) do
				local st = snap.stations[row.id]
				if st and (not surface or st.surface_index == surface) then
					local errors, open_errors = 0, 0
					for _, e in ipairs(row.entries) do
						if e.sev == 1 then
							errors = errors + 1
							if not e.acked then open_errors = open_errors + 1 end
						end
					end
					if open_errors > 0 then open[row.id] = true elseif errors > 0 then acked = acked + 1 end
				end
			end
			return open, acked
		end
		local function check_misconfigured(label, surface)
			local open, acked = misconfigured_oracle(surface)
			local m = stations_dump()
			local lead = 0
			while m.ids[lead + 1] and open[m.ids[lead + 1]] do lead = lead + 1 end
			local n = lab.count(open)
			lab.check("Misconfigured agrees with the Problems view (" .. label .. "): the leading rows are the stations "
				.. "with an open error, the subfooter says how many (+ acked)", m.chip == "problems" and lead == n
				and m.open_errors ~= nil and m.open_errors[1] == n and m.open_errors[2] == acked,
				{ lead = lead, oracle = n, acked = acked, subfooter = m.open_errors, ids = m.ids })
			return n, acked
		end
		local n_open = check_misconfigured("no filter")
		lab.check("layout-dev has a station with an open error to jump to", n_open > 0, n_open)
		-- The Overview's own number: after the filters phase it counts open errors (misconfigured_acked exists); before,
		-- it counted every station with a finding, as the chip does.
		local ov = remote.call(D, "dump", pi, "overview").tiles.failing
		remote.call(D, "select_tab", pi, "stations")
		if ov and ov.misconfigured_acked ~= nil then
			local _, acked0 = misconfigured_oracle()
			lab.check("the Overview's Misconfigured line == the open-error rows of its jump", ov.misconfigured == n_open
				and ov.misconfigured_acked == acked0, { overview = ov.misconfigured, acked = ov.misconfigured_acked,
				view = n_open, view_acked = acked0 })
		else
			lab.check("the Overview's Misconfigured line == the Problems chip", ov and ov.misconfigured == d.chip_counts.problems,
				{ overview = ov and ov.misconfigured, chip = d.chip_counts.problems })
		end

		-- With a surface filter: the chip counts that surface's stations and lists them; registry rows of other surfaces go.
		for _, name in ipairs({ "nauvis", "cyb-bench" }) do
			remote.call(D, "set_filter", pi, { surface = game.surfaces[name].index })
			local f = stations_dump()
			local on_surface = true
			local snap = snapshot()
			for _, id in ipairs(f.ids) do
				if snap.stations[id].surface_index ~= game.surfaces[name].index then on_surface = false end
			end
			lab.check("Problems chip with surface " .. name .. ": count == rows, all on that surface", f.chip == "problems"
				and f.total == (f.chip_counts.problems or 0) and #f.ids == f.total and on_surface,
				{ total = f.total, count = f.chip_counts.problems, rows = #f.ids })
			local has_derelict = false
			for _, r in ipairs(f.registry) do
				if string.find(r.key, ":" .. comb.unit_number .. ":", 1, true) then has_derelict = true end
			end
			lab.check("registry rows obey the surface filter (" .. name .. ")", has_derelict == (name == "cyb-bench"), f.registry)
			check_misconfigured("surface " .. name, game.surfaces[name].index)
		end
		remote.call(D, "set_filter", pi, { network = "signal-A" })
		lab.check("a network filter hides the registry rows (they belong to no network)", #stations_dump().registry == 0)
		-- Clearing the filters clears the Stations chips too (PLAN4 D4).
		remote.call(D, "clear_filters", pi)
		remote.call(DS, "set_chip", pi, "problems")

		-- Acknowledge every finding of the first row from its button, then end it with a second click.
		d = stations_dump()
		local first_id = d.ids[1]
		lab.dev("click", pi, "manager_stations_tab_scroll_pane", { 1, 4, 6 })
		local acks = lab.dev("diag_acks")
		local by = acks and acks.lint and acks.lint[first_id]
		local acked_all = by ~= nil and lab.count(by) == lab.count((function()
			local checks = {}
			for _, e in ipairs(want[first_id].entries) do checks[e.check] = true end
			return checks
		end)())
		local after = stations_dump()
		local pos
		for i, id in ipairs(after.ids) do if id == first_id then pos = i end end
		lab.check("acknowledge: the row's findings are acknowledged and its cell greys out", acked_all and pos ~= nil
			and after.problems[pos] and after.problems[pos].ack == true and after.problems[pos].chip_style == "cybersyn_chip_acked",
			{ pos = pos, cell = pos and after.problems[pos], acks = acks and acks.lint })
		-- The first row had an open error: it leaves the count for "+1 acked" and moves behind every open station.
		local open_after, acked_after = check_misconfigured("one station acknowledged")
		local open_station_after = 0
		for i, id in ipairs(after.ids) do
			if after.problems[i] and after.problems[i].ack == false then open_station_after = i end
		end
		lab.check("acknowledge: the station moves behind every open one", open_after == n_open - 1 and acked_after >= 1
			and pos ~= nil and pos > open_station_after, { pos = pos, last_open = open_station_after, open = open_after,
			before = n_open })
		lab.dev("click", pi, "manager_stations_tab_scroll_pane", { pos or 1, 4, 6 })
		after = stations_dump()
		lab.check("acknowledge: a second click ends them", after.problems[pos or 1] and after.problems[pos or 1].ack == false,
			after.problems[pos or 1])

		-- The stop panel's Setup section still renders the findings (its texts moved to lint-text.lua).
		lab.dev("relative_open", pi, "stop", first_id)
		local setup = serpent.line(lab.dev("relative_dump", pi).sections.setup.content)
		lab.check("stop panel: the Setup section still lists the stop's findings with their fix lines",
			setup:find("lint-fix-", 1, true) ~= nil and setup:find("lint-detail-", 1, true) ~= nil, setup)
		lab.dev("relative_close", pi)

		-- Leaving the view gives Provided / requested back and drops the Problems sort.
		remote.call(DS, "set_chip", pi, "all")
		d = stations_dump()
		lab.check("Problems chip off: Provided / requested is back, sorted by name", d.header[4] == "provided_requested"
			and d.column == "name" and #d.registry == 0, { header = d.header, column = d.column })
		-- The Overview's jump sets player_data.stations_chip = "problems" (p1); the tab reads it as the chip.
		remote.call("cybersyn", "write_global", "problems", "manager", "players", pi, "stations_chip")
		d = stations_dump()
		lab.check("stations_chip = 'problems' (the Overview's jump) opens the Problems view", d.chip == "problems"
			and d.column == "problems" and d.total == d.chip_counts.problems, { chip = d.chip, column = d.column })
		remote.call(DS, "set_chip", pi, "all")
		comb.destroy({ raise_destroy = true })
		lab.dev("lint_run")
	end,

	-- PLAN4 D15 items 8, 13, 14, 15: Last dispatch reads never before the first dispatch; names sort naturally; chips
	-- wrap rather than abbreviate on a narrow window; the Wait column hides when the page has no wait.
	function(ctx)
		remote.call(D, "clear_filters", pi)
		lab.set_status_filter(pi, nil)
		lab.big_screen(pi)
		remote.call(D, "set_sort", pi, "stations", "name", true)
		local d = stations_dump()
		local function natural(name)
			return (string.gsub(string.lower(name), "%d+", function(n)
				n = string.gsub(n, "^0+", "")
				if n == "" then n = "0" end
				return string.format("%02d", #n) .. n
			end))
		end
		local ordered, pairs_out = true, {}
		for i = 2, #d.names do
			local a, b = natural(tostring(d.names[i - 1])), natural(tostring(d.names[i]))
			if b < a then
				ordered = false
				pairs_out[#pairs_out + 1] = { d.names[i - 1], d.names[i] }
			end
		end
		local has_ten = false
		for _, n in ipairs(d.names) do if tostring(n):find("10", 1, true) then has_ten = true end end
		lab.check("Stations: names in natural order (stn-2 before stn-10)", ordered and has_ten, pairs_out)

		local dispatched = 0
		for i, id in ipairs(d.ids) do
			local station = remote.call("cybersyn", "read_global", "stations", id)
			if station and station.created_tick and station.last_delivery_tick ~= station.created_tick
				and key_of(d.last[i]) ~= "cybersyn-gui.never" then dispatched = dispatched + 1 end
		end
		lab.info("Stations: " .. dispatched .. " rows with a recorded dispatch show its age")

		local ok, case = pcall(function()
			local c = cases.base("P3FRESH", { k = 90 }, { network = "signal-9", no_train = true })
			c.fresh = cases.station(c, { name = "p3-fresh-station", x = cases.X_P[1], bits = 1 })
			return c
		end)
		lab.check("a fresh station builds", ok, case)
		if ok then
			lab.dev("collect")
			remote.call(D, "set_filter", pi, { query = "p3-fresh-station" })
			local f = stations_dump()
			lab.check("Last dispatch: a fresh station reads never", #f.ids == 1 and key_of(f.last[1]) == "cybersyn-gui.never",
				{ ids = f.ids, last = f.last })
			-- One station with no wait on the page: the Wait column hides and gives its width to the name.
			lab.check("Wait column hidden when the page has no wait", f.hidden[1] == "wait" and #f.hidden == 1, f.hidden)
			-- Unless it carries the sort: its header holds the sort arrow.
			remote.call(D, "set_sort", pi, "stations", "wait", false)
			f = stations_dump()
			lab.check("Wait column stays while the list sorts by it", #f.hidden == 0 and f.column == "wait", f.hidden)
			remote.call(D, "set_sort", pi, "stations", "name", true)
			remote.call(D, "clear_filters", pi)
			pcall(case.cleanup or function() cases.destroy(case) end)
			lab.dev("collect")
		end

		-- A narrow window with the search field open: the chips wrap onto a second line, none abbreviated, and the
		-- page gives up exactly one row for it. 1080p at 2.0 is the narrowest supported window (960 px); a stuck alert
		-- on a delivering train adds the Stuck train chip, more than fits beside the search field there.
		local snap = snapshot()
		local stuck_train
		for id, tr in pairs(snap.trains) do
			if tr.p_station_id and (not stuck_train or id < stuck_train) then stuck_train = id end
		end
		lab.dev("set_layout", pi, 1920, 1080, 2)
		remote.call(D, "select_tab", pi, "stations")
		-- Ctrl+F reaches an offline player's window only while it is pinned.
		lab.dev("click", pi, "manager_pin_button")
		lab.dev("search_input", pi)
		if stuck_train then
			remote.call("cybersyn", "write_global", { { train_id = stuck_train, kind = 1, since_tick = game.tick } }, "manager",
				"snapshot", "alerts")
		end
		remote.call(D, "update", pi, 1)
		d = stations_dump()
		local rows = lab.dev("rows", pi, "stations")
		local named = true
		for _, chip in ipairs(d.chips) do
			if chip[1] ~= "all" and chip[3] == false and chip[2] == false then named = false end
		end
		lab.check("narrow window: chips wrap onto a second line", d.chip_row == true and #d.wrapped > 0, { wrapped = d.wrapped, chips = d.chips })
		lab.check("narrow window: zero-count chips are hidden, the rest enabled", named, d.chips)
		lab.check("narrow window: the page gives up one row for the chip line and still fits whole rows",
			rows.rendered == rows.computed - 1 and #d.ids == rows.rendered, { rows = rows, ids = #d.ids })
		lab.dev("cancel_search", pi)
		lab.dev("click", pi, "manager_pin_button")
		lab.big_screen(pi)
		remote.call(D, "update", pi, 1)
		d = stations_dump()
		lab.check("wide window: one chip line again", d.chip_row == false and #d.wrapped == 0, d.wrapped)
	end,

	-- Trains: chips, hidden columns, time in state, depot groups.
	function(ctx)
		local counts = check_train_chips("no filter")
		local snap = snapshot()
		local n = 0
		for _ in pairs(snap.trains) do n = n + 1 end
		local d = trains_dump()
		lab.check("Trains: All lists every train", d.total == n and #d.ids == n, { total = d.total, trains = n })

		-- In trouble from the train states (every red or orange state chip) and Cybersyn's alerts.
		local trouble = 0
		local names = {}
		for name, v in pairs(defines.train_state) do names[v] = name end
		local alerted = {}
		for _, a in ipairs(snap.alerts or {}) do alerted[a.train_id] = true end
		for id, tr in pairs(snap.trains) do
			local s = names[tr.state]
			local waited = game.tick - (tr.state_since or game.tick)
			if alerted[id] or s == "no_path" or s == "path_lost" or s == "no_schedule" or s == "destination_full"
				or s == "manual_control" or s == "manual_control_stop" or (s == "wait_signal" and waited >= 600) then
				trouble = trouble + 1
			end
		end
		lab.check("In trouble chip == trains with a red/orange state or an alert", counts.trouble == trouble,
			{ chip = counts.trouble, oracle = trouble })

		-- Hidden columns: one distinct value over the listed trains.
		local function uniform(fn, list)
			local first, seen = nil, false
			for _, tr in pairs(list) do
				local v = fn(tr)
				if not seen then first, seen = v, true elseif v ~= first then return false end
			end
			return true
		end
		local function check_hidden(label, list)
			local dd = trains_dump()
			local hidden = lab.set_of(dd.hidden)
			local want = {
				network = uniform(function(tr)
					local m = tr.network_mask
					if type(m) == "table" then
						local parts = {}
						for k, v in pairs(m) do parts[#parts + 1] = k .. "=" .. v end
						table.sort(parts)
						m = table.concat(parts, ",")
					end
					return tostring(tr.network_name) .. "|" .. tostring(m)
				end, list),
				layout = uniform(function(tr) return tr.layout_id end, list),
				depot = uniform(function(tr) return tr.depot_name end, list),
			}
			local same = true
			for column, w in pairs(want) do
				if (hidden[column] == true) ~= w then same = false end
			end
			lab.check(label .. ": Network, Layout and Depot hidden exactly when one value", same, { hidden = dd.hidden, want = want })
			local tip_ok = true
			for column in pairs(want) do
				if hidden[column] and not find_key(dd.status_tooltip, "cybersyn-gui.trains-hidden-" .. column) then tip_ok = false end
			end
			lab.check(label .. ": the Status header tooltip names every hidden column's value", tip_ok, dd.status_tooltip)
			if hidden.network then
				local t = find_key(dd.status_tooltip, "cybersyn-gui.trains-hidden-network")
				local _, tr = next(list)
				local m = tr.network_mask
				local want_net = type(m) == "number" and (tr.network_name .. " · " .. m) or nil
				lab.check(label .. ": the hidden network names the signal and its mask", t and (want_net == nil or t[2] == want_net),
					{ tip = t, want = want_net })
			end
			if hidden.layout then
				local t = find_key(dd.status_tooltip, "cybersyn-gui.trains-hidden-layout")
				lab.check(label .. ": the hidden layout is a composition string", t and type(t[2]) == "string" and t[2]:find("^L") ~= nil, t)
			end
		end
		check_hidden("no filter", snap.trains)
		remote.call(D, "set_filter", pi, { network = "signal-A" })
		local a = {}
		for id, tr in pairs(snap.trains) do
			local m = tr.network_mask
			if tr.network_name == "signal-A" or (type(m) == "table" and m["signal-A"]) then a[id] = tr end
		end
		check_hidden("network signal-A", a)
		local da = trains_dump()
		lab.check("a network filter hides the Network column", lab.set_of(da.hidden).network == true, da.hidden)
		remote.call(D, "clear_filters", pi)

		-- Time in state: the first (ascending) sort puts the longest first.
		remote.call(D, "set_sort", pi, "trains", "time_in_state")
		local dt = trains_dump()
		local ok, why = lab.ordered(dt.keys, #dt.ids, true)
		lab.check("Time in state sorts by state_since ascending, i.e. the longest first", ok and dt.ascending == true
			and dt.column == "time_in_state", why or dt.keys)
		remote.call(D, "set_sort", pi, "trains", "train_id", true)

		-- Fuel: a percentage per row on the page, nil only for trains without a burner.
		local fuel_ok = true
		for _, id in ipairs(d.ids) do
			local f = d.fuel[id] or d.fuel[tostring(id)]
			if not (f == false or f == nil or (type(f) == "number" and f >= 0 and f <= 100)) then fuel_ok = false end
		end
		lab.check("fuel is a percentage per listed train", fuel_ok, d.fuel)
		lab.info(remote.call(DT, "fuel_profile", pi))
	end,

	-- Not refuelled > N h against refuel_tick, the network's refueler and the per-user setting.
	function(ctx)
		local trains = lab.read("trains")
		local on_a = {}
		for id, t in pairs(trains) do
			local m = t.network_mask
			if t.network_name == "signal-A" or (type(m) == "table" and m["signal-A"]) then on_a[#on_a + 1] = id end
		end
		table.sort(on_a)
		lab.check("signal-A has trains to test the refuel chip on", #on_a >= 2, on_a)
		if #on_a < 2 then return end
		local had = lab.read("to_refuelers")
		ctx.had_refueler = had and had["signal-A"] ~= nil
		if not ctx.had_refueler then remote.call("cybersyn", "write_global", {}, "to_refuelers", "signal-A") end
		ctx.refuelled = on_a[1]
		remote.call("cybersyn", "write_global", game.tick - HOUR / 2, "trains", on_a[1], "refuel_tick")
		lab.dev("collect")
		local function chip()
			return trains_dump().counts.not_refuelled
		end
		-- The collector's rule: a never-refuelled train is measured from its refuel_from (lint.refuel_from).
		local function oracle(hours)
			local n = 0
			local snap_trains = snapshot().trains
			for id, t in pairs(lab.read("trains")) do
				local m = t.network_mask
				local on = t.network_name == "signal-A" or (type(m) == "table" and m["signal-A"])
				if not on then
					for net in pairs(lab.read("to_refuelers") or {}) do
						if t.network_name == net then on = true end
					end
				end
				local since = t.refuel_tick or (snap_trains[id] and snap_trains[id].refuel_from)
				if on and (not since or game.tick - since > hours * HOUR) then n = n + 1 end
			end
			return n
		end
		lab.dev("set_player_setting", pi, "cybersyn-manager-refuel-hours", 1)
		local one = chip()
		lab.check("Not refuelled > 1 h == the collector's rule (refuel_tick, else refuel_from)", one == oracle(1),
			{ chip = one, oracle = oracle(1), trains = #on_a })
		remote.call(DT, "set_chip", pi, "not_refuelled")
		local listed = {}
		for _, id in ipairs(trains_dump().ids) do listed[id] = true end
		lab.check("the train refuelled 30 min ago is not listed at 1 h", not listed[on_a[1]], trains_dump().ids)
		remote.call(DT, "set_chip", pi, "all")

		-- A never-refuelled train still inside its grace (registered just now) does not count yet.
		local fresh = on_a[2]
		ctx.fresh, ctx.fresh_seen = fresh, lab.read("trains", fresh, "seen_tick")
		remote.call("cybersyn", "write_global", nil, "trains", fresh, "refuel_tick")
		remote.call("cybersyn", "write_global", game.tick, "trains", fresh, "seen_tick")
		lab.dev("collect")
		local graced = chip()
		remote.call(DT, "set_chip", pi, "not_refuelled")
		listed = {}
		for _, id in ipairs(trains_dump().ids) do listed[id] = true end
		remote.call(DT, "set_chip", pi, "all")
		lab.check("a never-refuelled train inside its grace is not counted (as not_refuelled_count)",
			graced == oracle(1) and not listed[fresh], { chip = graced, oracle = oracle(1), fresh = fresh })
		remote.call("cybersyn", "write_global", ctx.fresh_seen, "trains", fresh, "seen_tick")
		lab.dev("collect")
		lab.dev("set_player_setting", pi, "cybersyn-manager-refuel-hours", 0.25)
		local quarter = chip()
		lab.check("Not refuelled > 0.25 h counts that train too (the per-user setting)", quarter == oracle(0.25) and quarter >= 1
			and quarter >= one, { chip = quarter, oracle = oracle(0.25), one = one })
		remote.call(DT, "set_chip", pi, "not_refuelled")
		local d = trains_dump()
		lab.check("Not refuelled chip shows its count", d.total == quarter and #d.ids == quarter, { total = d.total, chip = quarter })
		remote.call(DT, "set_chip", pi, "all")
		lab.dev("set_player_setting", pi, "cybersyn-manager-refuel-hours", 1)
		remote.call("cybersyn", "write_global", nil, "trains", on_a[1], "refuel_tick")
		if not ctx.had_refueler then remote.call("cybersyn", "write_global", nil, "to_refuelers", "signal-A") end
		lab.dev("collect")
	end,

	-- Group by depot: one group row per depot name, the numbers from snapshot.depots_by_name.
	function(ctx)
		local by_name = lab.dev("depots_by_name")
		local names = {}
		for name in pairs(by_name) do names[#names + 1] = name end
		table.sort(names, function(a, b)
			if string.lower(a) ~= string.lower(b) then return string.lower(a) < string.lower(b) end
			return a < b
		end)
		remote.call(DT, "set_grouped", pi, true, nil)
		local d = trains_dump()
		local shown = {}
		for i, g in ipairs(d.groups) do shown[i] = g.name end
		local refuelers = next(lab.read("refuelers") or {}) ~= nil
		local want = {}
		for i, n in ipairs(names) do want[i] = n end
		lab.check("group rows: one per depot name, in name order (" .. #names .. ")", lab.same_list(shown, want)
			or (refuelers and lab.same_list({ table.unpack(shown, 1, #names) }, want)), { shown = shown, want = want })
		-- Parked, inbound and bound count the trains listed under the group (refuelling ones go to the refuelers),
		-- so they agree with the expanded members and the Parked chip; the limit is the depots' own.
		local oracle = {}
		for _, tr in pairs(snapshot().trains) do
			if tr.status ~= 7 and tr.status ~= 8 then
				local o = oracle[tr.depot_name] or { parked = 0, inbound = 0, bound = 0 }
				oracle[tr.depot_name] = o
				o.bound = o.bound + 1
				if tr.status == 0 then o.parked = o.parked + 1 end
				if tr.status == 5 or tr.status == 6 then o.inbound = o.inbound + 1 end
			end
		end
		local nums_ok, checked = true, 0
		for _, g in ipairs(d.groups) do
			local e = by_name[g.name]
			if e then
				local o = oracle[g.name] or { parked = 0, inbound = 0, bound = 0 }
				local parked, inbound, bound = g.captions[1], g.captions[2], g.captions[3]
				local limit = e.limit >= 2000000000 and "∞" or tostring(e.limit)
				if not (key_of(parked) == "cybersyn-gui.trains-group-parked" and parked[2] == tostring(o.parked) and parked[3] == limit
						and inbound[2] == tostring(o.inbound) and bound[2] == tostring(o.bound)) then
					nums_ok = false
				end
				checked = checked + 1
			end
		end
		lab.check("group rows: parked (residue included) / limit, inbound and trains from the listed trains (" .. checked .. ")",
			nums_ok and checked > 0, { groups = d.groups, oracle = oracle })
		local run_ok = true
		for _, g in ipairs(d.groups) do
			if by_name[g.name] and not (g.run and g.pusher) then run_ok = false end
		end
		lab.check("group rows: the stats are one run beside the name, the compositions pushed to the right end", run_ok, d.groups)
		lab.check("collapsed groups list no trains", #d.ids == 0, d.ids)
		local pager = d.pager
		lab.check("the pager counts the group rows and says rows; the summary beside it counts trains",
			key_of(pager) == "cybersyn-gui.pager-range-rows" and pager[4] == tostring(#d.groups)
			and type(d.summary) == "table" and d.summary[1] == "cybersyn-gui.trains-summary", { pager = pager, summary = d.summary })

		local first = names[1]
		remote.call(DT, "set_grouped", pi, true, { [first] = true })
		local e = trains_dump()
		local members = 0
		for _, tr in pairs(snapshot().trains) do
			if tr.depot_name == first and tr.status ~= 7 and tr.status ~= 8 then members = members + 1 end
		end
		lab.check("an expanded group lists its trains under it", #e.ids == members and members > 0, { ids = e.ids, members = members })
		local head
		for _, g in ipairs(e.groups) do
			if g.name == first then head = g end
		end
		lab.check("the expanded group's Trains number == the trains listed under it", head ~= nil
			and head.captions[3][2] == tostring(members), { head = head, members = members })
		lab.check("the pager counts group rows and the expanded trains", e.pager[4] == tostring(#e.groups + members), e.pager)
		lab.check("rows rendered == rows computed while grouped",
			remote.call(D, "rows", pi, "trains").rendered == math.min(#e.groups + members, remote.call(D, "rows", pi, "trains").computed))
		remote.call(DT, "set_grouped", pi, false, nil)
	end,

	-- PLAN4 D11 / D7: every state icon exists, composition icons follow the layout record, the group hover box counts
	-- the group's trains by state, the Problems chip counts the trains with findings, depot markers sit exactly on
	-- the depots with findings.
	function(ctx)
		local sprites = remote.call(DT, "sprites")
		local bad, states = {}, 0
		for _, s in ipairs(sprites) do
			if not s.valid then bad[#bad + 1] = s.kind .. " " .. s.name .. " " .. s.sprite end
			if s.kind == "state" then states = states + 1 end
		end
		local n_states = 0
		for _ in pairs(defines.train_state) do n_states = n_states + 1 end
		lab.check("every defines.train_state, residue and refuel map to a sprite that exists (" .. states .. ")",
			#bad == 0 and states == n_states + 2, bad)
		lab.check("every tooltip bucket, carriage class and chip icon is a valid sprite (" .. #sprites .. ")", #bad == 0, bad)

		-- One train gets a second layout for this step (no tick passes), so the Composition column shows.
		local trains = lab.read("trains")
		local ids = {}
		for id in pairs(trains) do ids[#ids + 1] = id end
		table.sort(ids)
		local odd, odd_layout = ids[1], trains[ids[1]].layout_id
		remote.call("cybersyn", "write_global", { 0, 1, 1, 0, 2 }, "layouts", 9901)
		remote.call("cybersyn", "write_global", 9901, "trains", odd, "layout_id")
		lab.dev("collect")
		remote.call(D, "update", pi, 3)
		local d = trains_dump()
		local snap = snapshot()
		local comp_ok, checked, wrong = true, 0, {}
		for i, id in ipairs(d.ids) do
			local tr = snap.trains[id]
			local want = remote.call(DT, "runs", tr.layout_id) or {}
			local got = d.layouts[i] or {}
			local same = #got == #want
			for k, r in ipairs(want) do
				local g = got[k]
				if not (type(g) == "table" and g[1] == r[1] and g[2] == r[2]) then same = false end
			end
			if not same then
				comp_ok = false
				wrong[#wrong + 1] = { id = id, got = got, want = want }
			end
			checked = checked + 1
		end
		lab.check("composition icons == the layout record's class runs for every train (" .. checked .. ")",
			comp_ok and checked == #ids and not lab.set_of(d.hidden).layout, wrong)
		local odd_row
		for i, id in ipairs(d.ids) do
			if id == odd then odd_row = d.layouts[i] end
		end
		lab.check("L C×2 L F: four runs, the badge only on the run of two", odd_row and #odd_row == 4 and odd_row[2][1] == "item/cargo-wagon"
			and odd_row[2][2] == 2 and odd_row[1][2] == 1, odd_row)

		-- State icons: a slot only for the coloured states, its tooltip "<state> · <age>" and the click footer.
		local icon_ok = true
		local names = {}
		for name, v in pairs(defines.train_state) do names[v] = name end
		for i, id in ipairs(d.ids) do
			local tr = snap.trains[id]
			local s = names[tr.state]
			local quiet = s == "on_the_path" or s == "wait_station" or s == "arrive_station"
			local residue = tr.status == 0 and next(tr.manifest_hashes or {}) ~= nil
			local refuel = tr.status == 8
			local st = d.states[i]
			if quiet and not residue and not refuel then
				if st ~= false then icon_ok = false end
			elseif not (st and st.type == "sprite-button" and st.style:find("^cybersyn_state_slot_")
					and key_of(leaves(st.tooltip)[1]) ~= nil) then
				icon_ok = false
			end
		end
		lab.check("state icons: a coloured slot exactly on the rows whose state is not quiet", icon_ok, d.states)

		-- Grouped: the hover box's states sum to the group's trains, its head names them.
		remote.call(DT, "set_grouped", pi, true, nil)
		local g = trains_dump()
		local sums_ok, groups = true, 0
		for _, row in ipairs(g.groups) do
			local bound = row.captions[3] and tonumber(row.captions[3][2])
			if row.name == "\1refuelers" then bound = row.captions[2] and tonumber(row.captions[2][2]) end
			local _, sum = tooltip_states(row.tooltip)
			local head = tooltip_head(row.tooltip)
			if not (bound and sum == bound and head) then sums_ok = false end
			groups = groups + 1
		end
		lab.check("group hover box: trains by state sum to the group's trains (" .. groups .. " groups)", sums_ok and groups > 0,
			g.groups)
		local comps_ok = true
		for _, row in ipairs(g.groups) do
			if row.comps then
				local icons = 0
				for _, c in ipairs(row.comps) do if type(c) == "table" then icons = icons + 1 end end
				if icons == 0 then comps_ok = false end
			end
		end
		lab.check("group rows draw their compositions as icon runs", comps_ok, g.groups)
		remote.call("cybersyn", "write_global", odd_layout, "trains", odd, "layout_id")
		remote.call("cybersyn", "write_global", nil, "layouts", 9901)
		lab.dev("collect")

		-- Findings: one train with a drifted capacity, one depot with a train limit of 2.
		local depots = lab.read("depots")
		local depot_id
		for id, dp in pairs(depots) do
			if not depot_id or id < depot_id then depot_id = id end
		end
		local stop = depots[depot_id].entity_stop
		local limit = stop.trains_limit
		-- The lint measures a train's capacity only while it is off a trip: a parked one.
		local drift
		for _, id in ipairs(ids) do
			if not drift and trains[id].status == 0 then drift = id end
		end
		local capacity = trains[drift].item_slot_capacity
		stop.trains_limit = 2
		remote.call("cybersyn", "write_global", 7, "trains", drift, "item_slot_capacity")
		lab.dev("lint_run")
		local findings = lab.dev("lint_findings")
		local train_ids, depot_ids, refueler = {}, {}, false
		for _, f in ipairs(findings) do
			if f.subject == "train" then train_ids[f.id] = true end
			if f.subject == "depot" then depot_ids[f.id] = true end
			if f.subject == "refueler" then refueler = true end
		end
		local n_train = 0
		for _ in pairs(train_ids) do n_train = n_train + 1 end
		remote.call(DT, "set_grouped", pi, false, nil)
		remote.call(DT, "set_chip", pi, "all")
		local f = trains_dump()
		lab.check("Problems chip == trains with a train finding (" .. n_train .. ")", f.counts.problems == n_train
			and train_ids[drift] == true, { chip = f.counts.problems, findings = train_ids, drift = drift })
		remote.call(DT, "set_chip", pi, "problems")
		local fp = trains_dump()
		lab.check("the Problems chip lists exactly those trains", #fp.ids == n_train and train_ids[fp.ids[1]] == true, fp.ids)
		remote.call(DT, "set_chip", pi, "all")
		remote.call(DT, "set_grouped", pi, true, nil)
		local by_name = lab.dev("depots_by_name")
		local want = {}
		for name, e in pairs(by_name) do
			for _, id in ipairs(e.ids) do
				if depot_ids[id] then want[name] = true end
			end
		end
		if refueler then want["\1refuelers"] = true end
		local gm = trains_dump()
		local marks_ok, marked = true, 0
		for _, row in ipairs(gm.groups) do
			local has = row.marker ~= nil
			if has ~= (want[row.name] == true) then marks_ok = false end
			if has then
				marked = marked + 1
				if not (row.marker.type == "label" and row.marker.style:find("^cybersyn_marker_")) then marks_ok = false end
			end
		end
		lab.check("a Problems marker (a label) on exactly the depot groups with findings (" .. marked .. ")",
			marks_ok and marked > 0, { groups = gm.groups, want = want })
		stop.trains_limit = limit
		remote.call("cybersyn", "write_global", capacity, "trains", drift, "item_slot_capacity")
		lab.dev("lint_run")
		remote.call(DT, "set_grouped", pi, false, nil)
		lab.dev("collect")
	end,

	-- A train changing state changes only a group row's hover box: written into the built row, no rebuild.
	function(ctx)
		remote.call(DT, "set_grouped", pi, true, nil)
		remote.call(D, "update", pi, 2)
		local before = trains_dump()
		local snap = snapshot()
		local target, group
		for id, tr in pairs(snap.trains) do
			if not target and tr.status == 0 and tr.depot_name then target, group = id, tr.depot_name end
		end
		local row0
		for _, r in ipairs(before.groups) do if r.name == group then row0 = r end end
		local states0 = row0 and tooltip_states(row0.tooltip) or {}
		remote.call("cybersyn", "write_global", defines.train_state.wait_signal, "manager", "snapshot", "trains", target, "state")
		remote.call("cybersyn", "write_global", nil, "manager", "players", pi, "trains_query")
		remote.call(D, "update", pi, 2)
		local after = trains_dump()
		local row1
		for _, r in ipairs(after.groups) do if r.name == group then row1 = r end end
		local states1, sum1 = {}, 0
		if row1 then states1, sum1 = tooltip_states(row1.tooltip) end
		local bound = row1 and row1.captions[3] and tonumber(row1.captions[3][2])
		lab.check("a state change moves the group hover box's count (" .. tostring(group) .. ")", row1 ~= nil
			and (states1["wait-signal"] or 0) == (states0["wait-signal"] or 0) + 1 and sum1 == bound, { before = states0, after = states1, bound = bound })
		lab.check("the group rows were updated in place, not rebuilt", after.last_result ~= "rebuilt", after.last_result)
		remote.call(DT, "set_grouped", pi, false, nil)
		lab.dev("collect")
	end,

	-- The panels' former chips are labels: the train state, the unserved reason, the lint finding in the stop head.
	function(ctx)
		local function find(view, name, out)
			out = out or {}
			if type(view) ~= "table" then return out end
			if view.name == name then out[#out + 1] = view end
			for _, c in ipairs(view.children or {}) do find(c, name, out) end
			return out
		end
		local function section_items(d, section, name)
			local s = d.sections and d.sections[section]
			local out = {}
			for _, c in ipairs(s and s.content or {}) do find(c, name, out) end
			return out
		end
		local trains = lab.read("trains")
		local tid = next(trains)
		local t = lab.dev("relative_open", pi, "train", tid)
		local chips = section_items(t, "head", "state_chip")
		lab.check("train panel: the state is a label, no handler, no chip style", #chips == 1 and chips[1].type == "label"
			and not chips[1].handler and not (chips[1].style or ""):find("chip"), chips)
		lab.dev("relative_close", pi)
		local diag = lab.read("diag")
		local station = diag and next(diag.unserved or {})
		if station then
			local p = lab.dev("relative_open", pi, "stop", station)
			local reason = section_items(p, "unserved", "chip")
			local ok = #reason > 0
			for _, c in ipairs(reason) do
				if c.type ~= "label" or c.handler or (c.style or ""):find("^cybersyn_chip_") then ok = false end
			end
			lab.check("stop panel: unserved reasons are labels, no handler, no chip style (" .. #reason .. ")", ok, reason)
			-- The head's lint finding (occupancy / phantom) is a marker label too: no chip-styled button anywhere in it.
			local function chip_buttons(view, out)
				if type(view) ~= "table" then return out end
				if view.type == "button" and (view.style or ""):find("^cybersyn_chip_") then out[#out + 1] = view end
				for _, c in ipairs(view.children or {}) do chip_buttons(c, out) end
				return out
			end
			local left = {}
			for _, sec in ipairs({ "head", "unserved" }) do
				for _, c in ipairs(p.sections[sec] and p.sections[sec].content or {}) do chip_buttons(c, left) end
			end
			lab.check("stop panel: no chip-styled button left in the head and the unserved rows", #left == 0, left)
			lab.dev("relative_close", pi)
		else
			lab.skip("stop panel reason labels", "no unserved request on this save at this tick")
		end
	end,

	-- Inventory: per-grid sorts, deficit, dim unrequested, delivered last hour.
	function(ctx)
		remote.call(D, "select_tab", pi, "inventory")
		remote.call(DI, "clear_grid_sorts", pi)
		local inv = snapshot().inventory_all
		local function dump() return remote.call(D, "dump", pi, "inventory") end

		remote.call(DI, "set_grid_sort", pi, "requested", "deficit")
		local d = dump()
		local r = d.requested
		local ok, why = lab.ordered(r.keys, #r.hashes, false)
		-- Per network: requested - incoming - (provider signals + outgoing deliveries), at least 0, summed. A station
		-- on several networks offers its stock on each and counts its requests on the first by name.
		local nets = {}
		local function bucket(n)
			local b = nets[n] or { r = {}, t = {}, s = {} }
			nets[n] = b
			return b
		end
		for _, st in pairs(snapshot().stations) do
			local list = { st.network_name or "" }
			if st.network_name == "signal-each" and type(st.network_mask) == "table" then
				list = {}
				for n in pairs(st.network_mask) do list[#list + 1] = n end
				table.sort(list)
			end
			local first = bucket(list[1])
			for _, n in ipairs(list) do
				local b = bucket(n)
				for hash, count in pairs(st.provided) do b.s[hash] = (b.s[hash] or 0) + count end
				for hash, count in pairs(st.deliveries) do
					if count < 0 then b.s[hash] = (b.s[hash] or 0) + count end
				end
			end
			for hash, req in pairs(st.requested) do
				if req.active then first.r[hash] = (first.r[hash] or 0) - req.count end
			end
			for hash, count in pairs(st.deliveries) do
				if count > 0 then first.t[hash] = (first.t[hash] or 0) + count end
			end
		end
		local want = {}
		for _, b in pairs(nets) do
			for hash, req in pairs(b.r) do
				local short = req - (b.t[hash] or 0) - math.max(b.s[hash] or 0, 0)
				if short > 0 then want[hash] = (want[hash] or 0) + short end
			end
		end
		local oracle_ok, tip_ok, short_items = true, true, 0
		for i, hash in ipairs(r.hashes) do
			local w = want[hash] or 0
			if r.keys[i] ~= w then oracle_ok = false end
			if w > 0 then short_items = short_items + 1 end
			local line = find_key(r.tooltips[i], "cybersyn-gui.inventory-deficit")
			if (line ~= nil) ~= (w > 0) then tip_ok = false end
		end
		lab.check("Requested by deficit: largest shortage first", ok and r.column == "deficit", why)
		lab.check("deficit per network from the station records, never below 0 (" .. short_items .. " short)", oracle_ok,
			{ keys = r.keys, hashes = r.hashes, want = want })
		lab.check("the 'Short by' line only on items that are short", tip_ok)
		lab.check("the other grids keep their own sort", d.provided.column == "item_order" and d.in_transit.column == "item_order")

		remote.call(DI, "set_grid_sort", pi, "provided", "amount")
		d = dump()
		ok, why = lab.ordered(d.provided.keys, #d.provided.hashes, false)
		lab.check("Provided by amount: largest first, Requested still by deficit", ok and d.provided.column == "amount"
			and d.requested.column == "deficit", why)
		remote.call(DI, "set_grid_sort", pi, "provided", "amount")
		d = dump()
		lab.check("the active sort button again goes back to item order", d.provided.column == "item_order", d.provided.column)
		remote.call(DI, "set_grid_sort", pi, "in_transit", "stations")
		d = dump()
		ok, why = lab.ordered(d.in_transit.keys, #d.in_transit.hashes, false)
		lab.check("In transit by stations: most first", ok and d.in_transit.column == "stations", why)
		remote.call(DI, "set_grid_sort", pi, "requested", "wait")
		d = dump()
		ok, why = lab.ordered(d.requested.keys, #d.requested.hashes, false)
		lab.check("Requested by wait: longest first (negated start ticks descending)", ok and d.requested.column == "wait", why)
		remote.call(DI, "clear_grid_sorts", pi)

		-- Dim unrequested against an oracle from the station records: an item a station provides on network N is dimmed
		-- when no station on N actively requests it. After the trace's stimulus every provided item may be requested
		-- somewhere, so one signal-A station is made to provide wood, which nobody requests, for this check.
		local wood_id
		for id, st in pairs(snapshot().stations) do
			if st.network_name == "signal-A" and not st.warming_up and (not wood_id or id < wood_id) then wood_id = id end
		end
		remote.call("cybersyn", "write_global", 7, "manager", "snapshot", "stations", wood_id, "provided", "wood")
		remote.call("cybersyn", "write_global", 1, "manager", "snapshot", "provider_masks", "signal-A:wood")
		remote.call("cybersyn", "write_global", nil, "manager", "players", pi, "inventory_cache")
		local provides, requests = {}, {}
		for _, st in pairs(snapshot().stations) do
			if st.network_name and not st.warming_up then
				local nets = {}
				if type(st.network_mask) == "table" then
					for n in pairs(st.network_mask) do nets[#nets + 1] = n end
				else
					nets[1] = st.network_name
				end
				for _, n in ipairs(nets) do
					for hash in pairs(st.provided) do provides[n .. ":" .. hash] = hash end
					for hash, req in pairs(st.requested) do
						if req.active then requests[n .. ":" .. hash] = true end
					end
				end
			end
		end
		local oracle, matched = {}, {}
		for key, hash in pairs(provides) do
			oracle[hash] = true
			if requests[key] then matched[hash] = true end
		end
		for hash in pairs(matched) do oracle[hash] = nil end
		local list = {}
		for hash in pairs(oracle) do list[#list + 1] = hash end
		table.sort(list)
		remote.call(DI, "set_dim", pi, true)
		d = dump()
		lab.check("Dim unrequested == provided items with no request on the same network (oracle from the records)",
			lab.same_list(d.unrequested, list) and lab.set_of(list).wood == true, { dim = d.unrequested, oracle = list })
		local styles_ok = true
		local dimmed = lab.set_of(list)
		for i, hash in ipairs(d.provided.hashes) do
			local grey = d.provided.styles[i]:find("grey") ~= nil
			if grey ~= (dimmed[hash] == true) then styles_ok = false end
		end
		lab.check("dimmed slots are exactly the unrequested ones", styles_ok, d.provided.styles)
		lab.info(remote.call(DI, "dim_profile"))
		remote.call(DI, "set_dim", pi, false)
		d = dump()
		local undimmed = true
		for _, style in ipairs(d.provided.styles) do
			if style:find("grey") then undimmed = false end
		end
		lab.check("Dim unrequested off: nothing grey", undimmed)
		lab.dev("collect")
		remote.call("cybersyn", "write_global", nil, "manager", "players", pi, "inventory_cache")
		d = dump()

		-- Delivered · last hour in every slot tooltip, from stats.aggregate.
		local delivered_ok, seen = true, 0
		for _, grid in ipairs(lab.GRIDS) do
			for i, hash in ipairs(d[grid].hashes) do
				local line = find_key(d[grid].tooltips[i], "cybersyn-gui.inventory-delivered-hour")
				if not line or line[2] ~= remote.call(DI, "delivered", hash) then delivered_ok = false end
				seen = seen + 1
			end
		end
		lab.check("'Delivered · last hour' in every slot tooltip matches stats.aggregate (" .. seen .. " slots)", delivered_ok and seen > 0)
	end,

	-- Two seconds later only the clock cells move: no row's dispatch part is written again (planner frozen, manager
	-- updates off while the clock runs, so the one render after the wait sees the whole change).
	function(ctx)
		remote.call(D, "select_tab", pi, "trains")
		remote.call(D, "update", pi, 2)
		ctx.updates = settings.global["cybersyn-manager-updates-per-second"].value
		lab.dev("set_setting", "cybersyn-manager-updates-per-second", 0)
		ctx.before = trains_dump()
		lab.wait(150)
	end,
	function(ctx)
		remote.call(D, "update", pi, 1)
		local after, before = trains_dump(), ctx.before
		lab.dev("set_setting", "cybersyn-manager-updates-per-second", ctx.updates)
		lab.check("a render 2.5 s later rewrites no row, only the time-in-state captions moved", after.last_rewrites == 0
			and after.last_result == "updated" and #after.in_state == #before.in_state and #after.in_state > 0
			and not lab.same_list(after.in_state, before.in_state), { before = before.in_state, after = after.in_state,
			rewrites = after.last_rewrites, result = after.last_result })
	end,

	-- Tile jumps land on the chip they promise, and link cells are tag buttons with the link handler.
	function(ctx)
		remote.call(D, "select_tab", pi, "overview")
		local o = remote.call(D, "dump", pi, "overview")
		lab.dev("click", pi, "overview_tile_failing")
		local d = remote.call(D, "dump", pi, "stations")
		lab.check("the Stations failing tile toggles the Failing chip and lists its stations", d.chip == "failing"
			and d.total == o.tiles.failing.headline, { chip = d.chip, total = d.total, tile = o.tiles.failing.headline })
		lab.dev("click", pi, "overview_tile_unserved")
		d = remote.call(D, "dump", pi, "stations")
		lab.check("the Unserved tile toggles the Unserved chip, longest wait first", d.chip == "unserved" and d.column == "wait"
			and d.ascending == false and d.total == d.chip_counts.unserved, { chip = d.chip, column = d.column })
		lab.set_status_filter(pi, nil)
		-- A toggled status chip must not survive a tile jump: one chip at a time.
		for _, tile in ipairs({ "failing", "unserved" }) do
			remote.call(DS, "set_chip", pi, "ok")
			remote.call(D, "select_tab", pi, "overview")
			lab.dev("click", pi, "overview_tile_" .. tile)
			d = remote.call(D, "dump", pi, "stations")
			lab.check("the " .. tile .. " tile clears a toggled status chip and lands on its own", d.chip == tile
				and d.total == d.chip_counts[tile], { chip = d.chip, total = d.total, counts = d.chip_counts })
		end
		lab.set_status_filter(pi, nil)
		lab.dev("click", pi, "overview_tile_fleet")
		local t = remote.call(D, "dump", pi, "trains")
		local worst = remote.call(D, "state", pi).filters.network
		local parked = 0
		for _, tr in pairs(snapshot().trains) do
			local m = tr.network_mask
			if tr.status == 0 and (tr.network_name == worst or (type(m) == "table" and m[worst])) then parked = parked + 1 end
		end
		lab.check("the Fleet tile toggles Parked with the worst network as filter", t.chip == "parked" and worst ~= nil
			and t.total == parked, { chip = t.chip, total = t.total, parked = parked, network = worst })
		remote.call(DT, "set_chip", pi, "all")
		remote.call(D, "clear_filters", pi)
		lab.dev("click", pi, "overview_tile_throughput")
		local inv = remote.call(D, "dump", pi, "inventory")
		lab.check("the Throughput tile sorts every grid by amount", inv.provided.column == "amount" and inv.requested.column == "amount")
		remote.call(D, "set_sort", pi, "inventory", "item_order", true)

		-- Link cells.
		local player = game.get_player(pi)
		local function find(e, name)
			if e.name == name then return e end
			for _, c in ipairs(e.children) do
				local r = find(c, name)
				if r then return r end
			end
		end
		remote.call(D, "select_tab", pi, "stations")
		remote.call(D, "update", pi, 1)
		local list = find(player.gui.screen, "manager_stations_tab_scroll_pane")
		local links_ok, n = true, 0
		local function button_index(cell)
			for i, child in ipairs(cell.children) do
				if child.type == "button" then return i end
			end
		end
		for _, row in ipairs(list.children) do
			local cell = row.children[1]
			local i = button_index(cell)
			local button = i and cell.children[i]
			n = n + 1
			if not (button and button.tags.kind == "station" and button.tags.id == row.tags.station_id and button.tags[HANDLER]) then
				links_ok = false
			end
			for _, icon in ipairs(cell.children) do
				if icon.type == "sprite-button" and not (icon.tags.kind == "station" and icon.tags.id == row.tags.station_id
						and icon.tags[HANDLER]) then
					links_ok = false
				end
			end
		end
		lab.check("every Stations name cell is a tag button {station, id} with the link handler (" .. n .. ")", links_ok and n > 0)
		-- A right click reaches the handler without opening anything (only items react to it).
		local res = lab.dev("click", pi, "manager_stations_tab_scroll_pane", { 1, 1, button_index(list.children[1].children[1]) },
			{ right = true })
		lab.check("a click on a Stations name cell reaches its handler", res == true, res)

		remote.call(D, "select_tab", pi, "trains")
		remote.call(D, "update", pi, 1)
		list = find(player.gui.screen, "manager_trains_tab_scroll_pane")
		links_ok, n = true, 0
		for _, row in ipairs(list.children) do
			if row.tags.train_id then
				n = n + 1
				local id_button = row.children[1]
				local depot = row.children[5].children[button_index(row.children[5])]
				local target = row.children[2].children[2]
				if not (id_button.tags.kind == "train" and id_button.tags.id == row.tags.train_id and id_button.tags[HANDLER]
						and depot.tags.kind == "depot" and depot.tags[HANDLER]) then
					links_ok = false
				end
				local tb = target.visible and target.children[button_index(target)]
				if target.visible and not (tb.tags.kind == "station" or tb.tags.kind == "refueler") then
					links_ok = false
				end
			end
		end
		lab.check("every Trains id, stop and depot cell is a tag button with the link handler (" .. n .. ")", links_ok and n > 0)

		-- Reopened: the Stations summary line comes back with the rows after the "Collecting…" placeholder.
		remote.call(D, "select_tab", pi, "trains")
		remote.call(D, "update", pi, 1)
		lab.check("the Trains query cache exists while open", lab.read("manager", "players", pi, "trains_query") ~= nil)

		remote.call(D, "select_tab", pi, "stations")
		remote.call(D, "close", pi)
		lab.check("closing drops the Trains query cache (it holds snapshot train records)",
			lab.read("manager", "players", pi, "trains_query") == nil)
		remote.call(D, "open", pi, true)
		remote.call(D, "select_tab", pi, "stations")
		local s
		for _ = 1, 12 do
			remote.call(D, "tick", 1)
			s = remote.call(D, "dump", pi, "stations")
			if s.total > 0 and s.visible then break end
		end
		remote.call(D, "tick", 1)
		s = remote.call(D, "dump", pi, "stations")
		lab.check("after a reopen the Stations summary line is back", key_of(s.summary) == "cybersyn-gui.stations-summary", s.summary)
		lab.set_status_filter(pi, nil)
		lab.dev("set_setting", "cybersyn-enable-planner", ctx.planner)
	end,
})
