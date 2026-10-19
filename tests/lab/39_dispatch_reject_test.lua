-- PLAN5 D5-6: a train heading back to its depot (bypass) that is picked for a provider it cannot reach is rejected
-- by set_manifest_schedule's path pre-check. The Log row names the cause (no_path, info) with the item and the train
-- state, the schedule is left alone, the train is back in the pool after the 300-tick back-off, the row has a why/fix
-- tooltip, the unread-error badge does not move and the stop panel's Last events names the cause.
--
-- layout-dev's stops face west-bound traffic only, so a parked train has stops it cannot reach (which train is parked
-- depends on where the golden trace left them). The planner is frozen so nothing else picks the train while it is a
-- bypass train; it is put back at its depot after.

local D = "cybersyn-manager-dev"
local C = "cybersyn"
local PI = 1
local STATUS_D = 0
local STATUS_TO_D_BYPASS = 6
local NO_PATH_SKIP_TIME = 300

local function dev(fn, ...)
	return remote.call(D, fn, ...)
end

local function read(...)
	return (remote.call(C, "read_global", ...))
end

local function newest_seq()
	local seq = 0
	for _, ev in ipairs(dev("diag_events", 0, 100000)) do
		if ev.seq > seq then seq = ev.seq end
	end
	return seq
end

local function contains(ls, s)
	return serpent.line(ls):find(s, 1, true) ~= nil
end

local steps = {
	function(ctx)
		ctx.planner = settings.global["cybersyn-enable-planner"].value
		dev("set_setting", "cybersyn-enable-planner", false)
		local ids = {}
		for id, t in pairs(read("trains")) do
			if t.status == STATUS_D and t.is_available and t.entity.valid then ids[#ids + 1] = id end
		end
		table.sort(ids)
		--- Stops with rail on `surface`: one without rail or on another surface is not this path (the train would be
		--- sent and stuck).
		local function stops_on(surface)
			local out = {}
			for id, st in pairs(read("stations")) do
				local e = st.entity_stop
				if e.valid and e.connected_rail and e.surface_index == surface then out[#out + 1] = id end
			end
			table.sort(out)
			return out
		end
		local stations
		-- The first parked train and the first stop it has no route to at all; any other stop as the requester.
		for _, id in ipairs(ids) do
			local train = read("trains", id).entity
			stations = stops_on(train.front_stock.surface_index)
			for _, sid in ipairs(stations) do
				local path = game.train_manager.request_train_path({ type = "any-goal-accessible", train = train,
					goals = { { train_stop = read("stations", sid).entity_stop } },
					search_direction = "any-direction-with-locomotives", in_chain_signal_section = false })
				if not path.found_path then
					ctx.train, ctx.p = id, sid
					break
				end
			end
			if ctx.train then break end
		end
		for _, sid in ipairs(stations or {}) do
			if ctx.p and sid ~= ctx.p then
				ctx.r = sid
				break
			end
		end
		local t = ctx.train and read("trains", ctx.train)
		if not (t and ctx.r) then
			lab.skip("bypass train rejected", "no parked train with an unreachable stop on this save")
			ctx.skip = true
			return
		end
		ctx.depot = t.depot_id
		lab.info("train " .. ctx.train .. " (depot " .. ctx.depot .. "), requester " .. ctx.r .. ", unreachable provider " ..
			ctx.p)
		-- Viewing the Log first clears the badge, so a new error would show (a "99+" would hide it).
		dev("open", PI)
		dev("select_tab", PI, "log")
		dev("update", PI, 3)
		dev("select_tab", PI, "overview")
		-- The badge is refreshed by the manager tick, not by a render.
		dev("tick", 1)
		ctx.badge = dev("log_dump", PI).badge
		lab.info("badge before the rejection: '" .. ctx.badge .. "'")
		ctx.seq = newest_seq()
		ctx.records = t.entity.get_schedule().get_record_count()
		ctx.state = t.entity.state

		remote.call(C, "write_global", STATUS_TO_D_BYPASS, "trains", ctx.train, "status")
		remote.call(C, "write_global", nil, "depots", ctx.depot, "available_train_id")
		ctx.tick = game.tick
		remote.call(C, "create_delivery", ctx.r, ctx.p, ctx.train,
			{ { name = "iron-plate", type = "item", quality = "normal", count = 100 } })

		local after = read("trains", ctx.train)
		lab.check("rejected: schedule untouched, still heading to its depot, no manifest, out of the pool",
			after.entity.get_schedule().get_record_count() == ctx.records and after.status == STATUS_TO_D_BYPASS and
			after.manifest == nil and not after.is_available,
			{ records = after.entity.get_schedule().get_record_count(), before = ctx.records, status = after.status,
				avail = after.is_available })
		lab.check("back-off: skip_path_checks_until = tick + 300", after.skip_path_checks_until == ctx.tick + NO_PATH_SKIP_TIME,
			{ after.skip_path_checks_until, ctx.tick })

		local rows = {}
		for _, ev in ipairs(dev("diag_events", ctx.seq, 1000)) do
			if ev.seq > ctx.seq and ev.kind == "dispatch_failed" then rows[#rows + 1] = ev end
		end
		local ev = rows[1] or {}
		lab.check("one dispatch_failed row", #rows == 1, rows)
		lab.check("code no_path (no chain signals on layout-dev), severity info", ev.code_name == "no_path" and
			ev.sev == "info", ev)
		lab.check("requester, provider, train, item and a = train state + 1", ev.station == ctx.r and
			ev.station2 == ctx.p and ev.train == ctx.train and ev.item == "iron-plate" and ev.a == ctx.state + 1, ev)
		ctx.ev = ev

		-- The manager tick can commit a lint pass with error findings of its own: the badge must count exactly the
		-- unread errors other than this row.
		dev("tick", 1)
		local dump = dev("log_dump", PI)
		local others = 0
		for _, e in ipairs(dev("diag_events", dump.seen, 100000)) do
			if e.seq > dump.seen and e.sev == "error" and e.seq ~= ev.seq then others = others + 1 end
		end
		lab.check("the unread-error badge does not count the row", dump.badge == (others > 99 and "99+" or others > 0 and tostring(others) or ""),
			{ before = ctx.badge, after = dump.badge, other_errors = others })

		dev("select_tab", PI, "log")
		dev("update", PI, 3)
		local found
		for _, row in ipairs(dev("log_dump", PI).rows or {}) do
			if contains(row.message, "cybersyn-diag.dispatch-no-path") then
				found = row
				break
			end
		end
		lab.check("Log row: the no_path text", found ~= nil)
		lab.check("Log row: why/fix tooltip naming the cause and the state",
			found and contains(found.message_tooltip, "cybersyn-diag.dispatch-why-no-path") and
			contains(found.message_tooltip, "cybersyn-diag.dispatch-fix-no-path") and
			contains(found.message_tooltip, "cybersyn-diag.train-state-"), found and found.message_tooltip)
		lab.check("Log row: the item column shows the item", found and found.item == "iron-plate", found and found.item)
		dev("select_tab", PI, "overview")

		dev("relative_open", PI, "stop", ctx.r)
		for _ = 1, 3 do dev("relative_refresh_ms", PI, 1) end
		local rel = dev("relative_dump", PI)
		local events = rel.sections and rel.sections.events
		lab.check("stop panel Last events: the cause, not just Dispatch failed",
			events and events.visible and contains(events.content, "cybersyn-diag.dispatch-no-path"), events)
		dev("relative_close", PI)

		lab.wait_until(function() return read("trains", ctx.train, "is_available") == true end, 600)
	end,

	function(ctx)
		dev("set_setting", "cybersyn-enable-planner", ctx.planner)
		if ctx.skip then return end
		local t = read("trains", ctx.train)
		lab.check("available again within 600 ticks of the rejection", t.is_available == true and
			game.tick - ctx.tick <= 600, { avail = t.is_available, ticks = game.tick - ctx.tick })
		lab.info("re-added after " .. (game.tick - ctx.tick) .. " ticks")
		remote.call(C, "remove_available_train", ctx.train)
		remote.call(C, "add_available_train_to_depot", ctx.train, ctx.depot)
		t = read("trains", ctx.train)
		lab.check("restored: parked at its depot and available", t.status == STATUS_D and t.is_available == true and
			read("depots", ctx.depot, "available_train_id") == ctx.train)
		dev("close", PI)
	end,
}

lab.suite("39_dispatch_reject", steps)
