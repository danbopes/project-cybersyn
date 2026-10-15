-- PLAN3 phase 1: opening without a synchronous collection ("Collecting… n %" until a boosted pass completes), one
-- meaning of Saturated on the Overview tile, the Stations chip and the chip's rows (B2), one fleet total on the
-- Overview and the Trains tab, and the parsed station name in the snapshot.

local D, pi = lab.D, lab.pi

local function caption_key(status)
	local c = status.caption
	return type(c) == "table" and c[1] or c
end

lab.suite("35_foundation", {
	-- Opening with no snapshot renders at once and collects over the next manager updates.
	function(ctx)
		ctx.planner = settings.global["cybersyn-enable-planner"].value
		lab.dev("set_setting", "cybersyn-enable-planner", false)
		remote.call(D, "close", pi)
		lab.check("closing the only window drops the snapshot", lab.dev("summary").tick == nil)
		remote.call(D, "open", pi, true)
		local status = remote.call(D, "status", pi)
		lab.check("open does not collect synchronously", status.snapshot_tick == nil, status)
		lab.check("subheader says Collecting", caption_key(status) == "cybersyn-gui.collecting-progress", status.caption)
		lab.check("progress starts at 0 %", status.collecting == 0 and status.caption[2] == "0", status)
		remote.call(D, "select_tab", pi, "overview")
		local ov = remote.call(D, "dump", pi, "overview")
		local placeholder = true
		for _, tile in ipairs({ "stations", "fleet", "depots", "demand" }) do
			if ov.rendered_tiles[tile].headline ~= "–" then placeholder = false end
		end
		lab.check("overview tiles read – before the first pass", placeholder, ov.rendered_tiles)
		local lists_ok = true
		for _, name in ipairs({ "starved", "waiting", "transit", "slowest", "saturated" }) do
			local l = ov.lists[name]
			local key = type(l.empty) == "table" and l.empty[1]
			if #l.keys ~= 0 or (key ~= "cybersyn-gui.stations-collecting" and key ~= "cybersyn-gui.overview-empty-" .. name .. "-disabled") then
				lists_ok = false
			end
		end
		lab.check("overview lists say Collecting before the first pass, with no rows", lists_ok, ov.lists)
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
		lab.check("subheader back to Updated", caption_key(status) == "cybersyn-gui.updated-ago" and status.collecting == nil, status)
		d = remote.call(D, "dump", pi, "stations")
		lab.check("stations tab shows every station after the pass", d.total == lab.dev("summary").station_count and d.total > 0, d.total)
		remote.call(D, "select_tab", pi, "overview")
		local tiles = remote.call(D, "dump", pi, "overview").tiles
		lab.check("overview counts every station right after the pass", tiles.stations.total == d.total, tiles.stations.total)
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

	-- Paused, closed and reopened: the window still collects once and shows that data, then stays frozen.
	function(ctx)
		remote.call(D, "set_paused", pi, true)
		remote.call(D, "close", pi)
		remote.call(D, "select_tab", pi, "overview")
		remote.call(D, "open", pi, true)
		local status = remote.call(D, "status", pi)
		lab.check("paused reopen: caption says Collecting", caption_key(status) == "cybersyn-gui.collecting-progress", status.caption)
		local updates = 0
		while remote.call(D, "status", pi).snapshot_tick == nil and updates < 20 do
			remote.call(D, "tick", 1)
			updates = updates + 1
		end
		lab.check("paused reopen: the first pass completes", updates >= 1 and updates <= 3, updates)
		remote.call(D, "tick", 1)
		local tiles = remote.call(D, "dump", pi, "overview").rendered_tiles
		lab.check("paused reopen: overview tiles show data", tiles.stations.headline ~= "–" and tiles.fleet.headline ~= "–", tiles)
		status = remote.call(D, "status", pi)
		lab.check("paused reopen: caption back to Paused", caption_key(status) ~= "cybersyn-gui.collecting-progress", status.caption)
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
		local tile = remote.call(D, "dump", pi, "overview").tiles.stations.saturated
		lab.check("saturated: Overview tile == Stations chip == chip rows", tile == chips.saturated and chips.saturated == rows.total,
			{ tile = tile, chip = chips.saturated, rows = rows.total })
		lab.check("saturated: the station at its limit counts", chips.saturated >= 1, chips.saturated)
		lab.check("saturated: limit 0 with a delivery is disabled", chips.disabled >= 1, chips.disabled)
		local st_tile = remote.call(D, "dump", pi, "overview").tiles.stations
		lab.check("stations tile lines == chips (no power, warming up, starved)", st_tile.faulty == chips.no_power
			and st_tile.warming_up == chips.warming_up and st_tile.starved == chips.starved,
			{ tile = { st_tile.faulty, st_tile.warming_up, st_tile.starved }, chip = { chips.no_power, chips.warming_up, chips.starved } })

		-- Mid-pass: the station at its limit gets room again. Once the pass has refilled its record (pass not yet
		-- complete), the chip drops it at once; the tile and its rows must drop it in the same update.
		local id = busy[1]
		local l = ctx.limits[id]
		l.stop.trains_limit = l.entity
		remote.call("cybersyn", "write_global", l.storage, "stations", id, "trains_limit")
		ctx.limits[id] = nil
		local mid = false
		for _ = 1, 8 do
			remote.call(D, "tick", 1)
			local live = lab.read("manager")
			local rec = live.snapshot.stations[id]
			if rec and rec.status ~= "saturated" then
				mid = live.snapshot_build ~= nil
				break
			end
		end
		lab.check("saturated: the record changed before its pass completed", mid)
		remote.call(D, "select_tab", pi, "stations")
		chips = remote.call(D, "dump", pi, "stations").counts
		remote.call(D, "select_tab", pi, "overview")
		local ov = remote.call(D, "dump", pi, "overview")
		lab.check("saturated mid-pass: Overview tile == Stations chip", ov.tiles.stations.saturated == chips.saturated,
			{ tile = ov.tiles.stations.saturated, chip = chips.saturated })
	end,

	-- One number per fact: the Fleet tile and the Trains tab count the same trains. On pY 123 they once showed 551 and
	-- 552: the collector refreshes the trains at the start of a pass, while the Overview's figures were rebuilt only
	-- after the pass completed. A train that leaves the fleet mid-pass reproduces it.
	function(ctx)
		remote.call(D, "clear_filters", pi)
		lab.dev("collect")
		local function totals()
			remote.call(D, "select_tab", pi, "trains")
			local trains = remote.call(D, "dump", pi, "trains").total
			remote.call(D, "select_tab", pi, "overview")
			return remote.call(D, "dump", pi, "overview").tiles.fleet.total, trains
		end
		local fleet, trains = totals()
		lab.check("fleet tile total == Trains tab total (no filter)", fleet == trains and trains > 0, { fleet = fleet, trains = trains })
		local id, train
		for tid, t in pairs(lab.read("trains")) do
			if not id or tid < id then id, train = tid, t end
		end
		-- Without a valid entity the collector drops the train from the snapshot; the planner is off, so nothing else
		-- reads it before the entity is put back.
		remote.call("cybersyn", "write_global", nil, "trains", id, "entity")
		for _ = 1, 3 do remote.call(D, "tick", 1) end
		local fleet2, trains2 = totals()
		remote.call("cybersyn", "write_global", train.entity, "trains", id, "entity")
		lab.check("a train leaving mid-pass leaves the Trains tab", trains2 == trains - 1, { before = trains, after = trains2 })
		lab.check("fleet tile total == Trains tab total mid-pass", fleet2 == trains2, { fleet = fleet2, trains = trains2 })
		lab.dev("collect")
		fleet, trains = totals()
		lab.check("the train is back in both", fleet == trains and trains == trains2 + 1, { fleet = fleet, trains = trains })
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
