-- PLAN3 phase 1: opening without a synchronous collection ("Collecting… n %" in the subheader until a boosted pass
-- completes), one meaning of each station status on the Overview tile, the Stations chip and the chip's rows (B2), the
-- Trains tab losing a train mid-pass, and the parsed station name in the snapshot.

local D, pi = lab.D, lab.pi

local function caption_key(c)
	return type(c) == "table" and c[1] or c
end

lab.suite("35_foundation", {
	-- Opening with no snapshot renders at once and collects over the next manager updates.
	function(ctx)
		ctx.planner = settings.global["cybersyn-enable-planner"].value
		lab.dev("set_setting", "cybersyn-enable-planner", false)
		remote.call(D, "close", pi)
		lab.check("closing the only window drops the snapshot", lab.dev("summary").tick == nil)
		lab.big_screen(pi)
		remote.call(D, "open", pi, true)
		local status = remote.call(D, "status", pi)
		lab.check("open does not collect synchronously", status.snapshot_tick == nil, status)
		-- PLAN3 §4.1/§4.3 (phase 3): the progress moved from the title bar to the tab's subheader.
		lab.check("subheader says Collecting", caption_key(status.subheader) == "cybersyn-gui.collecting-progress", status)
		lab.check("progress starts at 0 %", status.collecting == 0 and status.subheader[2] == "0", status)
		lab.check("title bar shows no collecting progress", caption_key(status.caption) ~= "cybersyn-gui.collecting-progress", status)
		remote.call(D, "select_tab", pi, "overview")
		local ov = remote.call(D, "dump", pi, "overview")
		lab.check("overview station tiles read – before the first pass", ov.rendered_tiles.failing.headline == "–"
			and ov.rendered_tiles.unserved.headline == "–", ov.rendered_tiles)
		local l = ov.lists.unserved
		lab.check("overview table says Collecting before the first pass, with no rows",
			#l.rendered == 0 and caption_key(l.empty) == "cybersyn-gui.stations-collecting", l.empty)
		remote.call(D, "select_tab", pi, "stations")
		local d = remote.call(D, "dump", pi, "stations")
		lab.check("stations tab shows the collecting placeholder", d.total == 0 and d.warning == true, d)
		local updates = 0
		while remote.call(D, "status", pi).snapshot_tick == nil and updates < 20 do
			remote.call(D, "tick", 1)
			updates = updates + 1
		end
		lab.info("first pass completed after " .. updates .. " manager update(s)")
		lab.check("first pass completes within 3 updates", updates >= 1 and updates <= 3, updates)
		status = remote.call(D, "status", pi)
		lab.check("subheader progress gone, title bar back to Updated", status.subheader == nil
			and caption_key(status.caption) == "cybersyn-gui.updated-ago" and status.collecting == nil, status)
		lab.wait(1)
	end,
	function(ctx)
		-- The first Stations build after a boosted pass spreads over the next renders (classify, sort, rows; phase 4 split
		-- the classification from the sort); the dump's own query takes the step the second tick left.
		remote.call(D, "tick", 2)
		local d = remote.call(D, "dump", pi, "stations")
		lab.check("stations tab shows every station after the pass", d.total == lab.dev("summary").station_count and d.total > 0, d.total)
		remote.call(D, "select_tab", pi, "overview")
		local tiles = remote.call(D, "dump", pi, "overview").tiles
		lab.check("overview has station figures right after the pass", tiles.failing ~= nil, tiles)
	end,

	-- A first pass that takes several updates: the Stations tab shows no rows and no counts from part of the stations,
	-- then every station on the update that completes it.
	function(ctx)
		remote.call(D, "close", pi)
		remote.call(D, "open", pi, true)
		remote.call(D, "select_tab", pi, "stations")
		local seen, ok, done, last = {}, true, false, nil
		for _ = 1, 20 do
			done = remote.call(D, "step", pi, 4)
			last = remote.call(D, "dump", pi, "stations")
			seen[#seen + 1] = last.total .. "/" .. tostring(last.counts.all)
			if done then break end
			if last.total ~= 0 or last.counts.all ~= nil or not last.warning then ok = false end
		end
		lab.check("stations: the first pass took several steps", #seen >= 5 and done, seen)
		lab.check("stations during the first pass: collecting placeholder, no rows, no counts", ok, seen)
		lab.check("stations on the step that completes it: rows == chip count == stations",
			last.total == last.counts.all and last.total == lab.dev("summary").station_count, seen)
		lab.dev("collect")
	end,

	-- The update that completes a boosted first pass leaves the first Stations build (classify, sort, every row) to the
	-- next update, so the two never add up in one tick on a large base.
	function(ctx)
		-- No manager tick of the game's own between the steps: each update here is a dev tick.
		ctx.ups = settings.global["cybersyn-manager-updates-per-second"].value
		lab.dev("set_setting", "cybersyn-manager-updates-per-second", 0)
		remote.call(D, "close", pi)
		remote.call(D, "select_tab", pi, "stations")
		remote.call(D, "open", pi, true)
		local updates, d = 0, nil
		while remote.call(D, "status", pi).snapshot_tick == nil and updates < 20 do
			remote.call(D, "tick", 1)
			updates = updates + 1
		end
		d = remote.call(D, "dump", pi, "stations")
		lab.check("stations: the completing update still shows the collecting placeholder", d.total == 0 and d.warning == true,
			{ updates = updates, total = d.total })
		ctx.defer_tick = game.tick
		lab.wait(1)
	end,
	function(ctx)
		lab.check("stations: deferred build runs in a later tick", game.tick > ctx.defer_tick, game.tick)
		remote.call(D, "tick", 1)
		local d = remote.call(D, "dump", pi, "stations")
		-- dump runs the query again, so only the rendered state shows what this update drew.
		lab.check("stations: the next update classifies but still shows the placeholder", d.warning == true and d.visible == false,
			{ warning = d.warning, visible = d.visible })
		ctx.defer_tick = game.tick
		lab.wait(1)
	end,
	function(ctx)
		remote.call(D, "tick", 1)
		local d = remote.call(D, "dump", pi, "stations")
		lab.check("stations: the update after that shows every station", d.total == lab.dev("summary").station_count and d.total > 0
			and not d.warning and d.visible and #d.ids == d.total, { total = d.total, rendered = #d.ids })
		lab.dev("set_setting", "cybersyn-manager-updates-per-second", ctx.ups)
	end,

	-- Paused, closed and reopened: the window still collects once and shows that data, then stays frozen.
	function(ctx)
		remote.call(D, "set_paused", pi, true)
		remote.call(D, "close", pi)
		remote.call(D, "select_tab", pi, "overview")
		remote.call(D, "open", pi, true)
		local status = remote.call(D, "status", pi)
		lab.check("paused reopen: subheader says Collecting", caption_key(status.subheader) == "cybersyn-gui.collecting-progress", status)
		local updates = 0
		while remote.call(D, "status", pi).snapshot_tick == nil and updates < 20 do
			remote.call(D, "tick", 1)
			updates = updates + 1
		end
		lab.check("paused reopen: the first pass completes", updates >= 1 and updates <= 3, updates)
		remote.call(D, "tick", 1)
		local tiles = remote.call(D, "dump", pi, "overview").rendered_tiles
		lab.check("paused reopen: overview tiles show data", tiles.failing.headline ~= "–" and tiles.fleet.headline ~= "–", tiles)
		status = remote.call(D, "status", pi)
		lab.check("paused reopen: subheader progress gone, title bar says Paused", status.subheader == nil
			and status.title_visible and caption_key(status.caption) ~= "cybersyn-gui.collecting-progress", status)
		local before = lab.dev("summary").tick
		remote.call(D, "tick", 3)
		lab.check("paused reopen: no further collection once data is shown", lab.dev("summary").tick == before, before)
		lab.wait(1)
	end,
	function(ctx)
		remote.call(D, "select_tab", pi, "stations")
		remote.call(D, "set_paused", pi, false)
		remote.call(D, "tick", 1)
		local d = remote.call(D, "dump", pi, "stations")
		lab.check("paused reopen: unpaused, stations rows show", d.total == lab.dev("summary").station_count, d.total)
	end,

	-- B2: Saturated has one meaning (deliveries at a finite limit). A station at its limit is saturated; one with a
	-- delivery but limit 0 is disabled, which the old Overview tile still counted as saturated.
	function(ctx)
		local stations = lab.read("stations")
		local busy = {}
		for id, st in pairs(stations) do
			if (st.deliveries_total or 0) > 0 then busy[#busy + 1] = id end
		end
		table.sort(busy)
		ctx.limits = {}
		lab.check("the world has stations with deliveries", #busy >= 2, #busy)
		for i = 1, math.min(#busy, 2) do
			local id = busy[i]
			local st = stations[id]
			local limit = i == 1 and st.deliveries_total or 0
			ctx.limits[id] = { stop = st.entity_stop, storage = st.trains_limit, entity = st.entity_stop.trains_limit }
			st.entity_stop.trains_limit = limit
			remote.call("cybersyn", "write_global", limit, "stations", id, "trains_limit")
		end
		lab.dev("collect")
		lab.set_status_filter(pi, nil)
		remote.call(D, "clear_filters", pi)
		remote.call(D, "select_tab", pi, "stations")
		local chips = remote.call(D, "dump", pi, "stations").counts
		lab.set_status_filter(pi, "saturated")
		local rows = remote.call(D, "dump", pi, "stations")
		lab.set_status_filter(pi, nil)
		remote.call(D, "select_tab", pi, "overview")
		-- PLAN3 §4.7 (phase 3): the Overview has no Saturated line any more; its Stations failing tile counts no power and
		-- disabled from the same st.status the chips read.
		local tile = remote.call(D, "dump", pi, "overview").tiles.failing
		lab.check("saturated chip == its rows", chips.saturated == rows.total, { chip = chips.saturated, rows = rows.total })
		lab.check("saturated: the station at its limit counts", chips.saturated >= 1, chips.saturated)
		lab.check("saturated: limit 0 with a delivery is disabled", chips.disabled >= 1, chips.disabled)
		lab.check("failing tile no power / disabled == chips", tile.no_power == chips.no_power and tile.disabled == chips.disabled,
			{ tile = { tile.no_power, tile.disabled }, chip = { chips.no_power, chips.disabled } })

		-- Mid-pass: the disabled station gets its limit back. Once the pass has refilled its record (pass not yet
		-- complete), the chip drops it at once; the tile must drop it in the same update.
		local id = busy[2]
		local l = ctx.limits[id]
		l.stop.trains_limit = l.entity
		remote.call("cybersyn", "write_global", l.storage, "stations", id, "trains_limit")
		ctx.limits[id] = nil
		local mid = false
		for _ = 1, 8 do
			remote.call(D, "tick", 1)
			local live = lab.read("manager")
			local rec = live.snapshot.stations[id]
			if rec and rec.status ~= "disabled" then
				mid = live.snapshot_build ~= nil
				break
			end
		end
		lab.check("disabled: the record changed before its pass completed", mid)
		remote.call(D, "select_tab", pi, "stations")
		chips = remote.call(D, "dump", pi, "stations").counts
		remote.call(D, "select_tab", pi, "overview")
		local ov = remote.call(D, "dump", pi, "overview")
		lab.check("disabled mid-pass: failing tile == Stations chip", ov.tiles.failing.disabled == chips.disabled,
			{ tile = ov.tiles.failing.disabled, chip = chips.disabled })
	end,

	-- A train that leaves the fleet mid-pass leaves the Trains tab in the same update. The Fleet headroom tile reads the
	-- planner's available-train counters (PLAN3 §4.4), so its "now" is the worst network's counter.
	function(ctx)
		remote.call(D, "clear_filters", pi)
		lab.dev("collect")
		local function trains_total()
			remote.call(D, "select_tab", pi, "trains")
			return remote.call(D, "dump", pi, "trains").total
		end
		remote.call(D, "select_tab", pi, "overview")
		local fleet = remote.call(D, "dump", pi, "overview").tiles.fleet
		local counts = lab.dev("diag_stats", 60).available_count
		lab.check("fleet headroom now == the worst network's available counter", fleet.worst ~= nil
			and fleet.now == (counts[fleet.worst] or 0), { fleet = fleet, counts = counts })
		local trains = trains_total()
		local id, train
		for tid, t in pairs(lab.read("trains")) do
			if not id or tid < id then id, train = tid, t end
		end
		-- Without a valid entity the collector drops the train from the snapshot; the planner is off, so nothing else
		-- reads it before the entity is put back.
		remote.call("cybersyn", "write_global", nil, "trains", id, "entity")
		for _ = 1, 3 do remote.call(D, "tick", 1) end
		local trains2 = trains_total()
		remote.call("cybersyn", "write_global", train.entity, "trains", id, "entity")
		lab.check("a train leaving mid-pass leaves the Trains tab", trains2 == trains - 1, { before = trains, after = trains2 })
		lab.dev("collect")
		lab.check("the train is back", trains_total() == trains2 + 1)
	end,

	-- The parser over the save's real names, and the snapshot carrying the result.
	function(ctx)
		local parts = remote.call(D, "parse_name", "[item=iron-plate,quality=rare] Iron [virtual-signal=signal-A]")
		lab.check("parse_name: lead, text, tail", parts.text == "Iron" and parts.lead[1] == "item/iron-plate"
			and parts.lead_quality[1] == "rare" and parts.tail[1] == "virtual-signal/signal-A" and not parts.tail_quality, parts)
		local ok = true
		for id, st in pairs(lab.read("stations")) do
			local name = st.entity_stop.backer_name
			local p = remote.call(D, "parse_name", name)
			if p.text ~= name then ok = false end
		end
		lab.check("plain station names parse to their text", ok)
	end,

	function(ctx)
		for id, l in pairs(ctx.limits or {}) do
			l.stop.trains_limit = l.entity
			remote.call("cybersyn", "write_global", l.storage, "stations", id, "trains_limit")
		end
		lab.dev("collect")
		remote.call(D, "close", pi)
		lab.check("planner restored", lab.dev("set_setting", "cybersyn-enable-planner", ctx.planner) == ctx.planner)
	end,
})
