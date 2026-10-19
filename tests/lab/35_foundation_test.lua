-- PLAN3 phase 1, reworked by PLAN5 D5-9: opening without a synchronous collection (placeholders until a boosted pass
-- that steps every tick completes; the "Collecting… n %" note only once a boost outlasts 30 ticks), the snapshot kept
-- two minutes after the last close (a reopen paints its rows at once and refreshes them quietly), one meaning of each
-- station status on the Overview tile, the Stations chip and the chip's rows (B2), the Trains tab losing a train
-- mid-pass, and the parsed station name in the snapshot.

local D, pi = lab.D, lab.pi

local function caption_key(c)
	return type(c) == "table" and c[1] or c
end

--- The tiles drawn from a complete pass (the Failing headline also waits for the first lint pass, so its first line).
local function tiles_have_data(tiles)
	return tiles.unserved.headline ~= "–" and tiles.failing.lines[1][2] ~= "–"
end

--- The per-tick handler's samples since `boost_samples("start")`, split into the completing step and the renders.
local function boost_log()
	local raw = remote.call(D, "boost_samples", "raw")
	local done, renders = nil, {}
	for _, e in ipairs(raw) do
		if e.kind == "step" and e.done then done = e.tick end
		if e.kind == "render" then renders[#renders + 1] = e end
	end
	return raw, done, renders
end

lab.suite("35_foundation", {
	-- The last close keeps the snapshot for the grace period; dev release frees it. A cold open then renders at once
	-- with placeholders and no note, and collects on the next ticks.
	function(ctx)
		ctx.planner = settings.global["cybersyn-enable-planner"].value
		lab.dev("set_setting", "cybersyn-enable-planner", false)
		remote.call(D, "open", pi)
		remote.call(D, "close", pi)
		local status = remote.call(D, "status", pi)
		lab.check("closing the only window keeps the snapshot", lab.dev("summary").tick ~= nil, status)
		lab.check("for KEEP_TICKS: release_at = now + 7200", status.release_at == game.tick + 7200, status.release_at)
		lab.check("a kept snapshot is not live", status.live == false, status)
		local released = lab.dev("release")
		lab.check("dev release frees it at once", released.snapshot_tick == nil and released.release_at == nil, released)
		ctx.mem_released = lab.dev("mem", true)
		lab.big_screen(pi)
		remote.call(D, "boost_samples", "start", pi)
		remote.call(D, "open", pi, true)
		ctx.open_tick = game.tick
		status = remote.call(D, "status", pi)
		lab.check("open does not collect synchronously", status.snapshot_tick == nil, status)
		lab.check("a cold boost starts at the open", status.boost == game.tick and status.quiet == nil, status)
		-- PLAN5 D5-9e: the note waits 30 boosted ticks; a pass on this save takes two.
		lab.check("no Collecting note at the open", status.subheader == nil and status.collecting == 0, status)
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
		remote.call(D, "select_tab", pi, "overview")
		lab.wait(5)
	end,
	function(ctx)
		remote.call(D, "boost_samples", "stop")
		local raw, done, renders = boost_log()
		local status = remote.call(D, "status", pi)
		lab.info("cold open at " .. ctx.open_tick .. ": " .. serpent.line(raw))
		lab.check("the pass completes within 3 ticks of the open (per-tick boost)", done ~= nil and done - ctx.open_tick <= 3,
			{ open = ctx.open_tick, done = done })
		lab.check("no step on the open's own tick (its first render ran there)", raw[1] and raw[1].tick > ctx.open_tick, raw[1])
		lab.check("no step and render share a tick", (function()
			local steps = {}
			for _, e in ipairs(raw) do if e.kind == "step" then steps[e.tick] = true end end
			for _, e in ipairs(renders) do if steps[e.tick] then return false end end
			return true
		end)(), raw)
		local first = renders[1]
		lab.check("the render after completion runs on the next tick and shows data", first and done
			and first.tick == done + 1 and first.data == true, first)
		local noted = false
		for _, e in ipairs(renders) do if e.note then noted = true end end
		lab.check("no Collecting note at any point of a short cold boost", not noted and status.subheader == nil, renders)
		lab.check("4 renders owed after completion, then the handler is idle", #renders == 4 and status.settle == nil
			and status.boost == nil, { renders = #renders, status = status })
		local tiles = remote.call(D, "dump", pi, "overview").rendered_tiles
		lab.check("overview tiles show data", tiles_have_data(tiles), tiles.failing)
		lab.check("subheader progress gone, title bar back to Updated (or hidden: renders are current)",
			status.subheader == nil and status.collecting == nil
			and (not status.title_visible or caption_key(status.caption) == "cybersyn-gui.updated-ago"), status)
	end,

	-- A cold boost that outlasts 30 ticks (a huge base, GC cycles) shows its progress.
	function(ctx)
		remote.call(D, "close", pi)
		lab.dev("release")
		remote.call(D, "open", pi, true)
		remote.call("cybersyn", "write_global", game.tick - 29, "manager", "collect_boost")
		remote.call(D, "update", pi, 1)
		lab.check("29 ticks into a cold boost: still no note", remote.call(D, "status", pi).subheader == nil)
		remote.call("cybersyn", "write_global", game.tick - 30, "manager", "collect_boost")
		remote.call(D, "tick", 1)
		local status = remote.call(D, "status", pi)
		lab.check("30 ticks into a cold boost: subheader says Collecting", caption_key(status.subheader)
			== "cybersyn-gui.collecting-progress" and status.subheader[2] == "0", status)
		lab.wait(5)
	end,
	function(ctx)
		local status = remote.call(D, "status", pi)
		lab.check("the long boost completes on the next ticks, its note goes with it", status.snapshot_tick ~= nil
			and status.subheader == nil and status.boost == nil, status)
	end,

	-- A first pass that takes several steps: the Stations tab shows no rows and no counts from part of the stations,
	-- then every station on the step that completes it.
	function(ctx)
		remote.call(D, "close", pi)
		lab.dev("release")
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

	-- The first Stations build after a boosted pass spreads over the settle renders on the ticks after it (classify,
	-- sort, rows), with no manager update in between: the per-tick handler alone collects and renders.
	function(ctx)
		ctx.ups = settings.global["cybersyn-manager-updates-per-second"].value
		lab.dev("set_setting", "cybersyn-manager-updates-per-second", 0)
		remote.call(D, "close", pi)
		lab.dev("release")
		remote.call(D, "select_tab", pi, "stations")
		remote.call(D, "boost_samples", "start", pi)
		remote.call(D, "open", pi, true)
		ctx.open_tick = game.tick
		lab.wait(8)
	end,
	function(ctx)
		remote.call(D, "boost_samples", "stop")
		local raw, done, renders = boost_log()
		local n = lab.dev("summary").station_count
		local by_offset = {}
		for _, e in ipairs(renders) do by_offset[#by_offset + 1] = (e.tick - (done or 0)) .. ":" .. tostring(e.rows) end
		lab.info("stations cold open, renders (ticks after completion:rows): " .. table.concat(by_offset, " "))
		lab.check("stations: the pass completes within 3 ticks", done ~= nil and done - ctx.open_tick <= 3,
			{ open = ctx.open_tick, done = done })
		lab.check("stations: +1 classifies and +2 sorts behind the placeholder, +3 renders every row", #renders == 4
			and renders[1].rows == 0 and renders[2].rows == 0 and renders[3].rows == n and renders[3].tick == done + 3,
			by_offset)
		local d = remote.call(D, "dump", pi, "stations")
		lab.check("stations: every station shows, no placeholder", d.total == n and n > 0 and not d.warning and d.visible
			and #d.ids == d.total, { total = d.total, rendered = #d.ids })
		lab.dev("set_setting", "cybersyn-manager-updates-per-second", ctx.ups)
	end,

	-- Reopened inside the grace period: the kept rows in the first paint, no note and no placeholders, refreshed by a
	-- quiet boost on the next ticks.
	function(ctx)
		remote.call(D, "select_tab", pi, "overview")
		remote.call(D, "close", pi)
		local kept = lab.dev("summary").tick
		-- Older than the 600 ticks after which an open refreshes it.
		remote.call("cybersyn", "write_global", game.tick - 700, "manager", "snapshot", "tick")
		ctx.kept_tick = game.tick - 700
		remote.call(D, "open", pi, true)
		local status = remote.call(D, "status", pi)
		lab.check("reopen inside the grace: the deadline goes", kept ~= nil and status.release_at == nil, status)
		lab.check("reopen inside the grace: a quiet boost, no note, no progress", status.quiet == true
			and status.boost == game.tick and status.subheader == nil and status.collecting == nil, status)
		local ov = remote.call(D, "dump", pi, "overview")
		lab.check("reopen inside the grace: tiles have data in the first paint", tiles_have_data(ov.rendered_tiles),
			ov.rendered_tiles.failing)
		lab.check("reopen inside the grace: unserved rows in the first paint", #ov.lists.unserved.rendered > 0,
			#ov.lists.unserved.rendered)
		remote.call(D, "close", pi)
		remote.call(D, "select_tab", pi, "stations")
		remote.call(D, "open", pi, true)
		local rows = remote.call(D, "rows", pi, "stations").rendered
		lab.check("reopen inside the grace: every Stations row in the first paint", rows == lab.dev("summary").station_count,
			rows)
		remote.call(D, "select_tab", pi, "overview")
		lab.wait(4)
	end,
	function(ctx)
		local status = remote.call(D, "status", pi)
		lab.check("the quiet boost refreshed the kept snapshot within 3 ticks", status.snapshot_tick ~= nil
			and status.snapshot_tick > ctx.kept_tick and status.quiet == nil and status.boost == nil, status)
	end,

	-- A stop panel with the manager closed and a kept snapshot reads the stop live.
	function(ctx)
		remote.call(D, "close", pi)
		local id
		for sid in pairs(lab.read("stations")) do
			if not id or sid < id then id = sid end
		end
		remote.call(D, "relative_open", pi, "stop", id)
		remote.call(D, "relative_refresh_ms", pi, 1)
		local m = remote.call(D, "relative_dump", pi).model
		lab.check("kept snapshot, manager closed: the stop panel reads the stop live", m.source == "live"
			and m.read_tick == game.tick and lab.dev("summary").tick ~= nil, { source = m.source, read_tick = m.read_tick })
		remote.call(D, "relative_close", pi)
	end,

	-- The kept snapshot goes at its deadline, and the heap with it.
	function(ctx)
		remote.call(D, "open", pi)
		remote.call(D, "select_tab", pi, "stations")
		lab.dev("set_keep_ticks", 60)
		remote.call(D, "close", pi)
		ctx.mem_kept = lab.dev("mem", true)
		lab.check("set_keep_ticks: the deadline follows it", remote.call(D, "status", pi).release_at == game.tick + 60)
		lab.check("the Stations query cache stays with the kept snapshot",
			lab.read("manager", "players", pi, "stations_query") ~= nil)
		remote.call(D, "select_tab", pi, "overview")
		lab.wait(61)
	end,
	function(ctx)
		local status = remote.call(D, "status", pi)
		local mem = lab.dev("mem", true)
		lab.info(string.format("heap released %.0f KB, kept %.0f KB, after the grace %.0f KB", ctx.mem_released,
			ctx.mem_kept, mem))
		lab.check("after the grace the snapshot is released, the Stations query cache with it", status.snapshot_tick == nil
			and status.release_at == nil and lab.read("manager", "players", pi, "stations_query") == nil, status)
		-- Other state (rings, lint) moves the heap by a few hundred KB on this save between the two measurements.
		lab.check("after the grace the heap is below the kept value and not above the released one (+5 %)",
			mem < ctx.mem_kept and mem <= 1.05 * ctx.mem_released, { released = ctx.mem_released, kept = ctx.mem_kept, now = mem })
		lab.check("set_keep_ticks(nil) restores KEEP_TICKS", lab.dev("set_keep_ticks", nil) == 7200)
		lab.dev("set_keep_ticks", 0)
		remote.call(D, "open", pi)
		remote.call(D, "close", pi)
		lab.check("a grace period of 0 releases at the close (the old behaviour)", lab.dev("summary").tick == nil
			and remote.call(D, "status", pi).release_at == nil)
		lab.dev("set_keep_ticks", nil)
	end,

	-- Paused, closed and reopened with a kept snapshot: the kept data shows and nothing collects.
	function(ctx)
		remote.call(D, "open", pi)
		remote.call(D, "set_paused", pi, true)
		remote.call(D, "close", pi)
		remote.call(D, "select_tab", pi, "overview")
		remote.call("cybersyn", "write_global", game.tick - 700, "manager", "snapshot", "tick")
		ctx.kept_tick = game.tick - 700
		remote.call(D, "open", pi, true)
		local tiles = remote.call(D, "dump", pi, "overview").rendered_tiles
		lab.check("paused reopen, kept: the kept data shows at once", tiles_have_data(tiles), tiles.failing)
		lab.wait(4)
	end,
	function(ctx)
		lab.check("paused reopen, kept: no collection", lab.dev("summary").tick == ctx.kept_tick, lab.dev("summary").tick)
		remote.call(D, "close", pi)
		lab.dev("release")
		remote.call(D, "open", pi, true)
		local status = remote.call(D, "status", pi)
		lab.check("paused reopen, cold: placeholders, a boost", status.snapshot_tick == nil and status.collecting == 0, status)
		lab.wait(5)
	end,

	-- Paused, closed and reopened cold: the window still collects once and shows that data, then stays frozen.
	function(ctx)
		local status = remote.call(D, "status", pi)
		lab.check("paused reopen: the first pass completes", status.snapshot_tick ~= nil and status.boost == nil, status)
		local tiles = remote.call(D, "dump", pi, "overview").rendered_tiles
		lab.check("paused reopen: overview tiles show data", tiles_have_data(tiles) and tiles.fleet.headline ~= "–", tiles)
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
