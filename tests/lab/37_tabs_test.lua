-- PLAN3 phase 4: the Stations, Trains and Inventory tabs. Every chip shows exactly the rows its count promises, with
-- and without a surface filter; Setup / Unserved / Failing count the same records as the Overview; the Trains hidden
-- columns, time-in-state order, the Not refuelled chip against refuel_tick and the per-user hours, the depot groups
-- against snapshot.depots_by_name; the Inventory's per-grid sorts (deficit from an oracle), Dim unrequested against
-- an oracle from the station records, "Delivered · last hour" against stats.aggregate; link cells are tag buttons.
-- Expected values come from the snapshot or Cybersyn's storage, never from the tab's own counts alone.

local D, pi = lab.D, lab.pi
local DS, DT, DI = "cybersyn-manager-dev-stations", "cybersyn-manager-dev-trains", "cybersyn-manager-dev-inventory"
local STATION_CHIPS = { "no_power", "disabled", "warming_up", "starved", "saturated", "idle", "ok", "unserved", "setup",
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
		if lab.STATUSES and counts[chip] and d.statuses and chip ~= "unserved" and chip ~= "setup" and chip ~= "stuck"
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
		lab.check("Setup chip == stations with st.lint ~= 0", counts.setup == lint and lint > 0, { chip = counts.setup, records = lint })
		lab.check("Unserved chip == stations with st.unserved.count > 0", counts.unserved == unserved, { chip = counts.unserved, records = unserved })
		lab.check("Failing chip == no power + disabled + throttling + setup records", counts.failing == failing, { chip = counts.failing, records = failing })
		remote.call(D, "select_tab", pi, "overview")
		local o = remote.call(D, "dump", pi, "overview")
		lab.check("Failing chip == the Overview's Stations failing tile (one number per fact)",
			o.tiles.failing and o.tiles.failing.headline == counts.failing, { tile = o.tiles.failing, chip = counts.failing })

		-- A rendered setup chip on exactly the rows with a lint finding.
		local d = stations_dump()
		local ok = true
		for i, id in ipairs(d.ids) do
			if d.setup[i] ~= ((snap.stations[id].lint or 0) ~= 0) then ok = false end
		end
		lab.check("the Status column's Setup chip shows on exactly the stations with a finding", ok)

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
		lab.check("collapsed groups list no trains", #d.ids == 0, d.ids)
		local pager = d.pager
		lab.check("the pager counts the group rows", key_of(pager) == "cybersyn-gui.pager-range" and pager[4] == tostring(#d.groups), pager)

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
