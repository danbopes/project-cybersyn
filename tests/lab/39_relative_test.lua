-- Phase 5 relative panels (PLAN3 §4.9): the stop and train panels beside the vanilla windows, driven through the
-- dev API (relative_open emulates on_gui_opened: player.opened cannot be set for the offline lab player).
--
-- Subjects: the save's provider, requester and both-stop; a stop without a Cybersyn combinator (hidden); a Cybersyn
-- train and a train Cybersyn does not know (hidden); and the R_LAYOUT scenario of cases.lua on row k = 60, whose
-- requester's allow list no train matches. Checks: role, network and mask, status and the occupancy pair against
-- Cybersyn's own tables and the stop entity; the Effective config numbers (threshold in stacks, largest eligible
-- capacity, mask match and eligible counts) against a train-by-train count of read_global("trains"), with and
-- without a snapshot; the manager tick closing a panel whose vanilla window is gone; the allow-list line; the Setup section against lint_bits; the unserved chip and the last
-- events against the diagnostics; the paused banner; dump twice identical with no section rebuilt; Open in manager.

local DEV = "cybersyn-manager-dev"
local SPEED = 50
local K = 60
local PI = 1

local function dev(fn, ...)
	return remote.call(DEV, fn, ...)
end

local function read(...)
	return (remote.call("cybersyn", "read_global", ...))
end

local rx = {}
lab.relative = rx

local function find_station(pred)
	local ids = {}
	for id, st in pairs(read("stations")) do
		if pred(st) and id < 2000 then ids[#ids + 1] = id end
	end
	table.sort(ids)
	return ids[1]
end

--- Cybersyn trains on `net` whose mask shares a bit with `mask`, and their distinct depots.
local function oracle_matches(net, mask)
	local n, depots, nd = 0, {}, 0
	for _, t in pairs(read("trains")) do
		local m
		if t.network_name == "signal-each" then
			m = type(t.network_mask) == "table" and t.network_mask[net] or nil
		elseif t.network_name == net then
			m = type(t.network_mask) == "number" and t.network_mask or 0
		end
		if m and bit32.band(m, mask) ~= 0 then
			n = n + 1
			if t.depot_id and not depots[t.depot_id] then
				depots[t.depot_id] = true
				nd = nd + 1
			end
		end
	end
	return n, nd
end

--- Cybersyn trains on `net` the stop can be sent, train by train: own mask shares a bit with `mask` and a layout the
--- stop accepts; with the largest item capacity among them.
local function oracle_eligible(net, mask, station)
	local n, best = 0, 0
	for _, t in pairs(read("trains")) do
		local m
		if t.network_name == "signal-each" then
			m = type(t.network_mask) == "table" and t.network_mask[net] or nil
		elseif t.network_name == net then
			m = type(t.network_mask) == "number" and t.network_mask or 0
		end
		if m and bit32.band(m, mask) ~= 0 and
			(station.allows_all_trains or (station.accepted_layouts or {})[t.layout_id]) then
			n = n + 1
			if (t.item_slot_capacity or 0) > best then best = t.item_slot_capacity end
		end
	end
	return n, best
end

local function stop_checks(label, id, want_p, want_r)
	local d = dev("relative_open", PI, "stop", id)
	local st = read("stations", id)
	local m = d.model or {}
	lab.check(label .. ": panel open and its mount visible", d.open and d.open.kind == "stop" and d.open.id == id and
		d.mounts.stop and d.mounts.stop.visible == true and (d.mounts.train == nil or d.mounts.train.visible == false), d.open)
	lab.check(label .. ": anchored right of the train-stop window",
		d.mounts.stop and d.mounts.stop.anchor.gui == "train-stop-gui" and d.mounts.stop.anchor.type == "train-stop" and
		d.mounts.stop.anchor.position == defines.relative_gui_position.right, d.mounts.stop and d.mounts.stop.anchor)
	lab.check(label .. ": 300 px frame captioned Cybersyn", d.width == 300 and d.caption and
		d.caption[1] == "cybersyn-gui.relative-caption", { d.width, d.caption })
	lab.check(label .. ": role", m.is_p == want_p and m.is_r == want_r and m.is_p == (st.is_p == true) and
		m.is_r == (st.is_r == true), { m.is_p, m.is_r })
	lab.check(label .. ": network and mask as Cybersyn reads them", m.network_name == st.network_name and m.nets and
		m.nets[1] and m.nets[1].mask == st.network_mask, { m.nets, st.network_name, st.network_mask })
	lab.check(label .. ": occupancy pair = deliveries_total / trains_limit and the stop's trains_count",
		m.deliveries == st.deliveries_total and m.limit == st.entity_stop.trains_limit and
		m.trains_count == st.entity_stop.trains_count, { m.deliveries, m.limit, m.trains_count })
	return d
end

lab.suite("39_relative", {
	function()
		dev("close", PI)
		dev("drop_snapshot")
		rx.setting = settings.global["cybersyn-diagnostics"].value
		dev("set_setting", "cybersyn-diagnostics", "basic")
		rx.provider = find_station(function(st) return st.is_p and not st.is_r end)
		rx.requester = find_station(function(st) return st.is_r and not st.is_p end)
		rx.both = find_station(function(st) return st.is_r and st.is_p end)
		-- A network of its own, so 40_reason_codes' R_LAYOUT scenario starts from a clean signal-S.
		local network = cases.NETWORKS.R_LAYOUT
		cases.NETWORKS.R_LAYOUT = "signal-Y"
		local ok, case = pcall(cases.R_LAYOUT, { k = K })
		cases.NETWORKS.R_LAYOUT = network
		lab.check("R_LAYOUT scenario builds", ok, case)
		if not ok then return end
		rx.case = case
		-- A plain stop and a train Cybersyn does not know, on the scenario's row.
		local s = case.surface
		rx.plain = s.create_entity({ name = "train-stop", position = { 40, case.y - 1 }, direction = defines.direction.west,
			force = game.forces.player, raise_built = true })
		rx.plain.backer_name = "rc-relative-plain"
		case.entities[#case.entities + 1] = rx.plain
		local loco = s.create_entity({ name = "locomotive", position = { 20, case.y + 1 }, direction = defines.direction.east,
			force = game.forces.player })
		case.entities[#case.entities + 1] = loco
		rx.vanilla_train = loco.train
		lab.wait_until(function() return cases.trains_ready(case) end, 3600, SPEED)
	end,

	function()
		local case = rx.case
		lab.check("R_LAYOUT train parked", cases.trains_ready(case))
		case.stages[1].run(case)
		-- The first failing evaluation, the flap window and a few cycles for the entry and its event.
		lab.wait(2400, SPEED)
	end,

	function()
		-- No snapshot: the panel reads the stop live.
		local d = stop_checks("provider", rx.provider, true, false)
		lab.check("provider: read live while no manager window keeps a snapshot", d.model.source == "live", d.model.source)
		local st = read("stations", rx.provider)
		lab.check("provider: status from the ladder", d.model.status ~= nil, d.model.status)
		-- Phase 7: the live read and a manager pass put the same stop on the same rung of the one status ladder.
		dev("open", PI)
		dev("collect")
		local snap_status = read("manager", "snapshot", "stations", rx.provider, "status")
		dev("close", PI)
		lab.check("provider: the live status equals the snapshot's", snap_status ~= nil and d.model.status == snap_status,
			{ live = d.model.status, snapshot = snap_status })
		-- PLAN4 D13: the stop footer is Open in manager, comb1, comb2 (stations) and Pin; Test path and Rescan station
		-- are gone, so there is no action row.
		lab.check("provider: Open in manager, comb1 and Pin; no Test path, no action row", (function()
			local row = d.sections.buttons.content[1].children
			local names = {}
			for _, c in ipairs(row) do if c.name then names[c.name] = c end end
			return names.comb1 and names.comb1.enabled and names.pin and names.pin.enabled == true
				and names.open_manager ~= nil and names.test_path == nil and d.sections.buttons.content[2] == nil
		end)(), d.sections.buttons)
		stop_checks("requester", rx.requester, false, true)
		stop_checks("both", rx.both, true, true)
		local setup = serpent.line(dev("relative_dump", PI).sections.setup.content)
		if dev("lint_state").pass == 0 then
			lab.check("save station: no lint pass ran yet, Setup says so", setup:find("relative-setup-not-run", 1, true) ~= nil, setup)
		else
			lab.check("save station: Setup lists the stop's findings or says there are none",
				setup:find(#dev("lint_findings", rx.both) > 0 and "lint-fix-" or "relative-setup-none", 1, true) ~= nil, setup)
		end
		local plain = dev("relative_open", PI, "stop", rx.plain.unit_number)
		lab.check("plain stop without a combinator: no panel", plain.open == nil and plain.mounts.stop.visible == false, plain)

		-- Trains.
		local trains = read("trains")
		local tid
		for id in pairs(trains) do if not tid or id < tid then tid = id end end
		local t = dev("relative_open", PI, "train", tid)
		local tm = t.model or {}
		local entity = trains[tid].entity
		lab.check("Cybersyn train: panel open, stop panel hidden", t.open and t.open.kind == "train" and
			t.mounts.train.visible == true and t.mounts.stop.visible == false, t.mounts)
		-- PLAN5 D5-7: flush right of the docked pane at its top, as the stop panel docks to the train-stop window.
		local g = dev("train_panel_geometry", PI)
		local scale = g.scale
		local narrow_x = math.floor(452 * scale + 0.5)
		local wide_x = math.max(narrow_x, math.floor(28 * scale) + math.min(g.groups, g.row_count) * math.floor(71 * scale))
		lab.check("Cybersyn train: a screen frame flush right of the docked train pane, at its top",
			t.mounts.train.anchor == nil and not g.narrow and g.pane_right == wide_x
			and t.mounts.train.location.x == wide_x and t.mounts.train.location.y == math.floor(40 * scale + 0.5),
			{ g = g, mount = t.mounts.train, want = wide_x })
		lab.check("layout-dev: the ghost cursor selection's group tabs fit the narrow pane", g.groups >= 1
			and g.row_count == 6 and g.pane_right == narrow_x, g)
		-- Opened from the character: the game enters remote view in the same tick, the Fuel tab is disabled.
		remote.call("cybersyn", "write_global", game.tick, "manager", "players", PI, "remote_entered_tick")
		dev("relative_open", PI, "train", tid)
		g = dev("train_panel_geometry", PI)
		lab.check("opened in the tick remote view was entered from the character: the narrow pane", g.narrow
			and g.location.x == narrow_x, g)
		local before = dev("relative_dump", PI).refreshes
		dev("tick", 1)
		local after = dev("relative_dump", PI)
		lab.check("a train panel beside the narrow pane refreshes on the manager tick", after.open ~= nil
			and after.refreshes == before + 1 and after.mounts.train.visible == true, { before, after.refreshes })
		remote.call("cybersyn", "write_global", game.tick - 1, "manager", "players", PI, "remote_entered_tick")
		dev("relative_open", PI, "train", tid)
		g = dev("train_panel_geometry", PI)
		lab.check("opened while already in remote view: the pane with the Fuel tab", not g.narrow and g.location.x == wide_x, g)
		-- The lab's event order: the window opens, the controller change follows in the same tick.
		local player = game.get_player(PI)
		local was_remote = player.controller_type == defines.controllers.remote
		if not was_remote then player.set_controller({ type = defines.controllers.remote, position = player.position }) end
		dev("controller_changed", PI, defines.controllers.character)
		g = dev("train_panel_geometry", PI)
		lab.check("controller change from the character after the open, same tick: recorded and placed narrow",
			g.remote_entered_tick == game.tick and g.narrow and g.location.x == narrow_x, g)
		remote.call("cybersyn", "write_global", game.tick - 1, "manager", "players", PI, "remote_entered_tick")
		dev("controller_changed", PI, defines.controllers.remote)
		lab.check("a change from remote view records nothing",
			dev("train_panel_geometry", PI).remote_entered_tick == game.tick - 1)
		if not was_remote then player.exit_remote_view() end
		remote.call("cybersyn", "write_global", nil, "manager", "players", PI, "remote_entered_tick")
		-- A display change places and caps it again (still the narrow pane it was opened with).
		dev("set_layout", PI, 1920, 1080, 1.0)
		dev("relative_display_changed", PI)
		g = dev("train_panel_geometry", PI)
		lab.check("1080p at 1.0: placed at (452, 40), body capped to stay above the hotbar",
			g.location.x == 452 and g.location.y == 40 and g.body_cap == 1080 - 40 - 150 - 110, g)
		dev("set_setting_as", PI, "cybersyn-enable-planner", false)
		dev("relative_refresh_ms", PI, 1)
		local gp = dev("train_panel_geometry", PI)
		local bp = dev("relative_dump", PI).banner
		dev("set_setting_as", PI, "cybersyn-enable-planner", true)
		dev("relative_refresh_ms", PI, 1)
		local gr = dev("train_panel_geometry", PI)
		lab.check("1080p at 1.0 with the planner paused: the banner's 36 px come out of the body cap",
			bp ~= nil and gp.location.y == 40 and gp.body_cap == 1080 - 40 - 150 - 110 - 36, { banner = bp, g = gp })
		lab.check("planner resumed: the banner is gone and the body cap is back", gr.body_cap == 1080 - 40 - 150 - 110, gr)
		dev("set_layout", PI, 3840, 2160, 1.5)
		dev("relative_display_changed", PI)
		g = dev("train_panel_geometry", PI)
		lab.check("4K at 1.5: placed at (678, 60), body capped", g.location.x == 678 and g.location.y == 60
			and g.body_cap == 1440 - 300, g)
		lab.big_screen(PI)
		dev("relative_display_changed", PI)
		g = dev("train_panel_geometry", PI)
		lab.check("back on the big screen: placed and capped for it", g.location.y == math.floor(40 * g.scale + 0.5)
			and g.body_cap == math.floor(4320 / g.scale) - 300, g)
		t = dev("relative_dump", PI)
		lab.check("Cybersyn train: status, state, depot from Cybersyn and the train",
			tm.status == trains[tid].status and tm.state == entity.state and tm.depot_id == trains[tid].depot_id,
			{ tm.status, tm.state, tm.depot_id })
		local records = entity.get_schedule().get_records() or {}
		lab.check("Cybersyn train: schedule records and the active one", #tm.schedule == #records and
			tm.current == entity.get_schedule().current, { #tm.schedule, #records, tm.current })
		lab.check("Cybersyn train: Open in manager and no Locate in row 1, Path trace and Pin; Send home in the action row", (function()
			local names = {}
			for _, c in ipairs(t.sections.buttons.content[1].children) do if c.name then names[c.name] = c end end
			local actions = t.sections.buttons.content[2]
			local second = {}
			for _, c in ipairs(actions and actions.children or {}) do if c.name then second[c.name] = c end end
			local fail = actions and actions.children and actions.children[1]
			return names.locate == nil and second.locate == nil and names.open_manager ~= nil and second.path_trace and second.path_trace.enabled == true
				and second.pin ~= nil and fail ~= nil and fail.name == "fail_delivery"
		end)(), t.sections.buttons)
		local v = dev("relative_open", PI, "train", rx.vanilla_train.id)
		lab.check("train Cybersyn does not know: no panel", v.open == nil and v.mounts.train.visible == false, v)
		dev("relative_open", PI, "train", tid)
		local closed = dev("relative_close", PI)
		lab.check("closing the window hides the panel and clears the state", closed.open == nil and
			closed.mounts.train.visible == false and closed.mounts.stop.visible == false, closed)
		-- A window gone without on_gui_closed: the manager tick finds player.opened is not the subject and closes.
		dev("relative_open", PI, "train", tid)
		dev("relative_emulated", PI, false)
		dev("tick", 1)
		local gone = dev("relative_dump", PI)
		lab.check("no vanilla window open: the manager tick closes the train panel", gone.open == nil and
			gone.mounts.train.visible == false, gone)
		dev("relative_open", PI, "stop", rx.both)
		dev("relative_emulated", PI, false)
		dev("tick", 1)
		gone = dev("relative_dump", PI)
		lab.check("no vanilla window open: the manager tick closes the stop panel", gone.open == nil and
			gone.mounts.stop.visible == false, gone)
		rx.tid = tid

		-- The R_LAYOUT requester: unserved chip, events, the allow-list line (no snapshot: the fleet walk).
		local case = rx.case
		local r = case.r_station
		dev("relative_open", PI, "stop", r)
		if not (dev("relative_dump", PI).effective_open) then dev("relative_toggle_effective", PI) end
		-- The walk counts FLEET_CHUNK trains per refresh.
		for _ = 1, 10 do dev("relative_refresh_ms", PI, 1) end
		local d = dev("relative_dump", PI)
		local m = d.model
		local unserved = dev("diag_unserved", r)[case.item]
		lab.check("R_LAYOUT requester: unserved row with the dispatcher's reason", m.unserved and m.unserved[1] and
			m.unserved[1].reason == "R_LAYOUT" and unserved and unserved.reason == "R_LAYOUT", { m.unserved, unserved })
		lab.check("R_LAYOUT requester: the reason chip rendered",
			serpent.line(d.sections.unserved.content):find("chip-r-layout", 1, true) ~= nil)
		local last = dev("diag_last_for", "station", r, 10)
		lab.check("R_LAYOUT requester: last events = diag_last_for (bounded scan done)",
			d.cursor and d.cursor.done and d.cursor.rows == #last and #last > 0, { d.cursor, #last })
		local e = m.effective
		local station = read("stations", r)
		local net = e and e.nets[1]
		local n_trains, n_depots = oracle_matches(case.network, station.network_mask)
		lab.check("effective (walk): mask matches n trains · n depots = read_global trains",
			net and net.trains == n_trains and net.depots == n_depots and n_trains > 0, { net, n_trains, n_depots })
		local n_eligible = oracle_eligible(case.network, station.network_mask, station)
		lab.check("effective (walk): eligible trains = per-train oracle; capacity, allow-list and match lines agree",
			net and net.eligible == n_eligible and net.allow_trains == net.eligible and net.eligible <= net.trains,
			{ net, n_eligible })
		lab.check("effective: allow list accepts layouts but no train matches (red line)",
			net and net.accepted ~= false and net.allow_trains == 0 and
			serpent.line(d.sections.effective.content):find("relative-eff-allow\"", 1, true) ~= nil, net)
		local item = e and e.items[1]
		local stack = prototypes.item[case.item].stack_size
		lab.check("effective: threshold in stacks = ceil(threshold / stack size)", item and item.hash == case.item and
			item.need == math.ceil(item.effective / stack), item)

		-- With a snapshot: capability from the collector's fleet facts, the same match counts. The panel reads the
		-- snapshot only while a window keeps it current (PLAN5 D5-9: one kept after the close is not live).
		dev("open", PI)
		dev("collect")
		dev("lint_run")
		for _ = 1, 10 do dev("relative_refresh_ms", PI, 1) end
		d = dev("relative_dump", PI)
		m = d.model
		e = m.effective
		net = e.nets[1]
		lab.check("with a snapshot: the panel reads the snapshot record", m.source == "snapshot", m.source)
		local _, r_cap = oracle_eligible(case.network, station.network_mask, station)
		lab.check("effective (snapshot): largest eligible capacity = per-train oracle", net.item_capacity == r_cap,
			{ net.item_capacity, r_cap })
		lab.check("effective (snapshot): provider overrides known", e.overrides_known == true, e.overrides_known)
		lab.check("effective (snapshot): match counts unchanged", net.trains == n_trains and net.depots == n_depots, net)
		-- A save requester that accepts every layout: a capacity the fleet really has.
		dev("relative_open", PI, "stop", rx.requester)
		for _ = 1, 10 do dev("relative_refresh_ms", PI, 1) end
		local sd = dev("relative_dump", PI)
		local sst = read("stations", rx.requester)
		local snet = sd.model.effective and sd.model.effective.nets[1]
		local se, scap = oracle_eligible(sst.network_name, sst.network_mask, sst)
		local sn, snd = oracle_matches(sst.network_name, sst.network_mask)
		lab.check("effective (snapshot, save requester): largest eligible capacity and match counts", snet and scap > 0 and
			snet.item_capacity == scap and snet.trains == sn and snet.depots == snd and snet.eligible == se and
			snet.allow_trains == se, { snet, scap, sn, snd, se })
		lab.check("effective open: the slot rows stay", sd.sections.slots.visible == true)
		local sitem = sd.model.effective and sd.model.effective.items[1]
		local sstack = sitem and prototypes.item[sitem.hash] and prototypes.item[sitem.hash].stack_size
		lab.check("effective (save requester): stacks = ceil(threshold / stack size), spare = capacity - stacks",
			sitem and sstack and sitem.need == math.ceil(sitem.effective / sstack) and sitem.gap == scap - sitem.need, sitem)
		dev("relative_open", PI, "stop", r)
		local bits = dev("lint_bits", r)
		local names = {}
		for _, f in ipairs(m.findings) do names[#names + 1] = f.check end
		table.sort(names)
		local want = {}
		for _, f in ipairs(dev("lint_findings", r)) do want[#want + 1] = f.check end
		table.sort(want)
		lab.check("Setup section = lint_bits and lint_findings of the stop", m.lint_bits == bits.mask and
			serpent.line(names) == serpent.line(want) and #names > 0, { m.lint_bits, bits, names, want })
		lab.check("Setup section renders the layout finding and its fix line",
			serpent.line(d.sections.setup.content):find("lint-fix-layout", 1, true) ~= nil)

		-- Sig guard: two dumps at one tick are identical and the second refresh rebuilt nothing.
		local a = dev("relative_dump", PI)
		dev("relative_refresh_ms", PI, 1)
		local b = dev("relative_dump", PI)
		lab.check("dump twice: identical sections and model", serpent.line(a.sections) == serpent.line(b.sections) and
			serpent.line(a.model) == serpent.line(b.model))
		lab.check("refresh with nothing changed rebuilds no section", b.rebuilds == a.rebuilds, { a.rebuilds, b.rebuilds })
		lab.info({ "", "refresh requester, effective open: ", dev("relative_refresh_ms", PI, 50) })
		dev("relative_toggle_effective", PI)
		lab.info({ "", "refresh requester, effective closed: ", dev("relative_refresh_ms", PI, 50) })
		dev("close", PI)

		-- The dispatcher-paused banner.
		dev("set_setting_as", PI, "cybersyn-enable-planner", false)
		dev("relative_refresh_ms", PI, 1)
		local paused = dev("relative_dump", PI)
		dev("set_setting_as", PI, "cybersyn-enable-planner", true)
		dev("relative_refresh_ms", PI, 1)
		local resumed = dev("relative_dump", PI)
		lab.check("paused banner shown while the dispatcher is off, gone after", paused.banner ~= nil and
			resumed.banner == nil, { paused.banner, resumed.banner })

		-- Open in manager: Stations tab with the station chip on this stop (PLAN8 D8-7; it searched the name before).
		dev("relative_click", PI, "open_manager")
		local state = dev("state", PI)
		lab.check("Open in manager: Stations tab, station chip on the stop, no search", state.is_open and
			state.selected_tab == "stations_tab" and state.filters.station == r and state.filters.terms == nil, state)
		local keys = dev("dump", PI, "stations")
		lab.check("Open in manager: the stop is listed", serpent.line(keys):find(tostring(r), 1, true) ~= nil)
		dev("close", PI)
		dev("clear_filters", PI)
		dev("relative_open", PI, "train", rx.tid)
		dev("relative_click", PI, "open_manager")
		state = dev("state", PI)
		lab.check("Open in manager (train): Trains tab searching #id", state.is_open and state.selected_tab == "trains_tab" and
			state.filters.terms and state.filters.terms[1] == "#" .. rx.tid, state.filters)
		dev("close", PI)
		dev("clear_filters", PI)
		dev("relative_close", PI)

		-- The 10 s age step rewrites the unserved row's wait in place instead of rebuilding the section.
		dev("drop_snapshot")
		local u = dev("relative_open", PI, "stop", rx.case.r_station)
		rx.age = { rebuilt = (u.rebuilt or {}).unserved, wait = serpent.line(u.sections.unserved.content) }
		lab.wait(1300, SPEED)
	end,

	function()
		local u = dev("relative_dump", PI)
		local m = u.model or {}
		lab.check("age step: unserved wait rewritten in place, the section not rebuilt",
			u.open and m.unserved and m.unserved[1] and m.unserved[1].reason == "R_LAYOUT" and
			(u.rebuilt or {}).unserved == rx.age.rebuilt and serpent.line(u.sections.unserved.content) ~= rx.age.wait,
			{ u.rebuilt, rx.age.rebuilt })
		dev("relative_close", PI)
	end,

	-- PLAN5 D5-8: Open in manager shows the subject whatever was set before (Daniel: "These filters should clear and it
	-- should revert back to All"): the Trains and Stations chips, a network filter, the surface default of a closed
	-- window, a collapsed depot group and an open drill-down could each hide it.
	function()
		local T, S = "cybersyn-manager-dev-trains", "cybersyn-manager-dev-stations"
		local function toggled(d)
			for _, c in ipairs(d.chips or {}) do
				if c[2] then return c[1] end
			end
		end
		local function has(list, v)
			for _, x in ipairs(list or {}) do
				if x == v then return true end
			end
			return false
		end
		local function focus_train(id)
			dev("relative_open", PI, "train", id)
			dev("relative_click", PI, "open_manager")
			dev("relative_close", PI)
			dev("collect")
			dev("update", PI, 3)
			return dev("dump", PI, "trains"), dev("state", PI)
		end
		dev("close", PI)
		dev("clear_filters", PI)
		dev("open", PI)
		dev("select_tab", PI, "trains")
		dev("collect")
		remote.call(T, "set_chip", PI, "trouble")
		dev("update", PI, 2)
		local d = dev("dump", PI, "trains")
		local id
		for _, t in ipairs(d.all) do
			if not has(d.ids, t) and (not id or t < id) then id = t end
		end
		if not id then
			lab.skip("Open in manager clears the Trains chip", "every train is in trouble")
			remote.call(T, "set_chip", PI, "all")
			return
		end
		local want = serpent.line({ mask = -1, terms = { "#" .. id } })
		local got, st = focus_train(id)
		lab.check("Open in manager (window open, In trouble on): the train is listed, chip All, filters only #id",
			serpent.line(got.ids) == serpent.line({ id }) and toggled(got) == "all"
			and serpent.line(st.filters) == want, { ids = got.ids, chip = toggled(got), filters = st.filters, trouble = d.ids })

		-- Window closed with the chip and a network filter kept, the player on the stops' surface (D3 would filter by it).
		local p = game.get_player(PI)
		local home = { surface = p.surface, position = p.position }
		local bench = rx.case.surface
		p.teleport({ 0, 0 }, bench)
		remote.call(T, "set_chip", PI, "trouble")
		dev("set_filter", PI, { network = "signal-B" })
		dev("close", PI)
		got, st = focus_train(id)
		local h = dev("header", PI)
		lab.check("Open in manager (window closed, on the stops' surface): listed, chip All, no surface or network filter, " ..
			"filter row closed", st.is_open and serpent.line(got.ids) == serpent.line({ id }) and toggled(got) == "all"
			and serpent.line(st.filters) == want and h.filter_row == false, { ids = got.ids, filters = st.filters, h = h })
		dev("close", PI)
		dev("open", PI)
		st = dev("state", PI)
		lab.check("a plain open afterwards still starts on the player's surface (D3)", st.filters.surface == bench.index,
			st.filters)
		p.teleport(home.position, home.surface)
		dev("clear_filters", PI)

		-- Stations flag chips: Unserved, then Problems with the Misconfigured scope.
		for _, chip in ipairs({ "unserved", "problems" }) do
			dev("select_tab", PI, "stations")
			remote.call(S, "set_chip", PI, chip)
			local sd = dev("dump", PI, "stations")
			local sid
			for _, cand in ipairs({ rx.provider, rx.requester, rx.both }) do
				if cand and not has(sd.ids, cand) then sid = cand break end
			end
			if sid then
				dev("relative_open", PI, "stop", sid)
				dev("relative_click", PI, "open_manager")
				dev("relative_close", PI)
				dev("update", PI, 3)
				local after = dev("dump", PI, "stations")
				lab.check("Open in manager clears the Stations " .. chip .. " chip: the stop is listed, chip All",
					has(after.ids, sid) and toggled(after) == "all", { ids = after.ids, chip = toggled(after), sid = sid })
			else
				lab.skip("Open in manager clears the Stations " .. chip .. " chip", "every stop has the chip")
			end
		end

		-- Grouped by depot with every group collapsed: the train's group opens, the grouping stays.
		remote.call(T, "set_grouped", PI, true, nil)
		got = focus_train(id)
		lab.check("Open in manager (grouped, collapsed): the train row shows, still grouped", has(got.ids, id) and
			got.grouped == true and #got.groups >= 1, { ids = got.ids, groups = #got.groups, grouped = got.grouped })
		remote.call(T, "set_grouped", PI, false)

		-- An open drill-down with the query already "#id": it closes.
		local hash
		for _, row in ipairs(dev("diag_unserved_rows", 50)) do hash = hash or row.hash end
		hash = hash or "iron-plate"
		local od = dev("open_item", PI, hash)
		lab.check("drill-down opened over the Trains tab", od.open == true, od)
		focus_train(id)
		lab.check("Open in manager with the same query again closes the drill-down", dev("item_dump", PI).open == false)
		dev("clear_filters", PI)
		dev("close", PI)
	end,

	function()
		cases.destroy(rx.case)
		dev("drop_snapshot")
		dev("set_setting", "cybersyn-diagnostics", rx.setting)
		lab.wait(600, SPEED)
	end,

	function()
		lab.check("relative rows torn down", read("stations", rx.case.r_station) == nil)
	end,
})
