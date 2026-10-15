-- PLAN3 phase 1: opening without a synchronous collection ("Collecting… n %" until a boosted pass completes), one
-- meaning of Saturated on the Overview tile, the Stations chip and the chip's rows (B2), and the parsed station name in the
-- snapshot.

local D, pi = lab.D, lab.pi

local function caption_key(status)
	local c = status.caption
	return type(c) == "table" and c[1] or c
end

lab.suite("40_foundation", {
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
	end,

	-- The parser over the save's real names, and the snapshot carrying the result.
	function(ctx)
		local parts = remote.call(D, "parse_name", "[item=iron-plate,quality=rare] Iron [virtual-signal=signal-A]")
		lab.check("parse_name: lead, text, tail", parts.text == "Iron" and parts.lead[1].sprite == "item/iron-plate"
			and parts.lead[1].quality == "rare" and parts.tail[1].sprite == "virtual-signal/signal-A", parts)
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
