-- Hand-built SnapshotStation records in the shape of the collector's inventory-row contract: every
-- source carries its own lists, priority and network, and st.rows holds one row per combinator in index order, as
-- collector.inventories returns them. Stubs of the collector's helpers sit here too.

local F = {}

F.NAPHTHA_OIL = "naphthalene-oil"
F.LIQUID_FUEL = "liquid-fuel"
F.COAL = "coal"

--- @param name string? network name
--- @param mask int?
local function source(kind, index, unit, priority, name, mask, provided, requested, ignored)
	return { kind = kind, index = index, unit = unit, ok = true, priority = priority or 0, network_mask = mask,
		network_name = name, mask = mask, provided = provided or {}, requested = requested or {}, ignored = ignored or {} }
end

function F.source_label(src)
	if src.kind == "station" then return { "cybersyn-gui.source-station" } end
	return { "cybersyn-gui.source-inventory", src.index }
end

--- st.rows from st.sources, as collector.inventories builds them.
local function rows(st)
	local out = {}
	for i, src in ipairs(st.sources) do
		out[i] = { key = st.id .. "@" .. src.unit, st = st, src = src, index = src.index, unit = src.unit, kind = src.kind,
			priority = src.priority, ok = src.ok, read = src.read ~= false, network_name = src.network_name,
			mask = src.mask, networks = src.networks, provided = src.provided, requested = src.requested,
			ignored = src.ignored, starved = src.starved, label = F.source_label(src) }
	end
	st.rows = out
	return st
end

local function base(t)
	t.deliveries = t.deliveries or {}
	t.thresholds = t.thresholds or {}
	t.control2 = t.control2 or {}
	t.wait = t.wait or {}
	t.ignored = t.ignored or {}
	t.status = t.status or "ok"
	t.trains_limit = t.trains_limit or 5
	t.deliveries_total = t.deliveries_total or 0
	t.surface_index = t.surface_index or 1
	t.name_lower = t.name_lower or string.lower(t.name or "")
	t.last_delivery_tick = t.last_delivery_tick or 0
	t.priority = t.priority or 0
	return t
end

--- A naphthalene plant: Provide only; the station combinator on A1 provides naphthalene oil, Inventory 1 on A3
--- liquid fuel, Inventory 2 on A4 holds -866 liquid fuel the switch keeps from being advertised.
function F.naphtha(id)
	local s = source("station", 0, 1001, 0, "signal-A", 1, { [F.NAPHTHA_OIL] = 199134 })
	local i1 = source("inventory", 1, 1002, 0, "signal-A", 3, { [F.LIQUID_FUEL] = 99134 })
	local i2 = source("inventory", 2, 1003, 0, "signal-A", 4, {}, {}, { [F.LIQUID_FUEL] = -866 })
	i1.read, i2.read = true, true
	local st = base({
		id = id,
		name = "Naphthalene plant",
		is_p = true,
		is_r = false,
		network_name = "signal-A",
		network_mask = 1,
		provided = { [F.NAPHTHA_OIL] = 199134, [F.LIQUID_FUEL] = 99134 },
		requested = {},
		ignored = { [F.LIQUID_FUEL] = -866 },
		secondary = true,
		secondary_count = 2,
	})
	st.sources = { s, i1, i2 }
	return rows(st)
end

--- Provides coal on A1 from the station combinator and requests it on A2 through Inventory 1.
function F.coal_both(id)
	local req = { count = -2000, threshold = 1000, active = true }
	local s = source("station", 0, 2001, 0, "signal-A", 1, { [F.COAL] = 5000 })
	local i1 = source("inventory", 1, 2002, 3, "signal-A", 2, {}, { [F.COAL] = req })
	i1.read = true
	local st = base({
		id = id,
		name = "Coal hub",
		is_p = true,
		is_r = true,
		network_name = "signal-A",
		network_mask = 1,
		provided = { [F.COAL] = 5000 },
		requested = { [F.COAL] = req },
		secondary = true,
		secondary_count = 1,
	})
	st.sources = { s, i1 }
	return rows(st)
end

--- A plain station: one row on the record's own provided / requested tables, as the contract
--- promises.
function F.plain(id, name, mask, provided, requested)
	local st = base({ id = id, name = name, network_name = "signal-A", network_mask = mask, provided = provided or {},
		requested = requested or {} })
	local s = source("station", 0, 9000 + id, 0, "signal-A", mask, st.provided, st.requested, st.ignored)
	st.sources = { s }
	return rows(st)
end

function F.mask_label(mask) return tostring(mask) end

--- Installs the helper stubs on a loaded collector table that does not have them yet.
function F.stub_collector(collector)
	for _, k in ipairs({ "mask_label", "source_label" }) do
		if collector[k] == nil then collector[k] = F[k] end
	end
end

return F
