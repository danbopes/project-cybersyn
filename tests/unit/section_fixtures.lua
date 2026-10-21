-- Hand-built SnapshotStation records in the shape of the collector's sections contract (BRIEF-SECONDARY.md), for the
-- views' unit tests while the collector's own builder lives elsewhere. Stubs of the collector's helpers sit here too.

local F = {}

F.NAPHTHA_OIL = "naphthalene-oil"
F.LIQUID_FUEL = "liquid-fuel"
F.COAL = "coal"

local function source(kind, index, unit, priority)
	return { kind = kind, index = index, unit = unit, ok = true, priority = priority or 0 }
end

local function section(name, mask, sources, provided, requested, ignored)
	return { key = name .. ":" .. mask, network_name = name, mask = mask, sources = sources, provided = provided or {},
		requested = requested or {}, ignored = ignored or {} }
end

local function base(t)
	t.deliveries = t.deliveries or {}
	t.thresholds = t.thresholds or {}
	t.control2 = t.control2 or {}
	t.wait = t.wait or {}
	t.status = t.status or "ok"
	t.trains_limit = t.trains_limit or 5
	t.deliveries_total = t.deliveries_total or 0
	t.surface_index = t.surface_index or 1
	t.name_lower = t.name_lower or string.lower(t.name or "")
	t.last_delivery_tick = t.last_delivery_tick or 0
	t.priority = t.priority or 0
	return t
end

--- pY 126's naphthalene plant: Provide only; the station combinator on A1 provides naphthalene oil, Inventory 1 on A3
--- liquid fuel, Inventory 2 on A4 holds -866 liquid fuel the switch keeps from being advertised.
function F.naphtha(id)
	local s = source("station", 0, 1001)
	local i1 = source("inventory", 1, 1002)
	local i2 = source("inventory", 2, 1003)
	local st = base({
		id = id,
		name = "Naphthalene plant",
		is_p = true,
		is_r = false,
		network_name = "signal-A",
		network_mask = 1,
		provided = { [F.NAPHTHA_OIL] = 199134, [F.LIQUID_FUEL] = 99134 },
		requested = {},
	})
	st.sources = { s, i1, i2 }
	st.sections = {
		section("signal-A", 1, { s }, { [F.NAPHTHA_OIL] = 199134 }),
		section("signal-A", 3, { i1 }, { [F.LIQUID_FUEL] = 99134 }),
		section("signal-A", 4, { i2 }, {}, {}, { [F.LIQUID_FUEL] = -866 }),
	}
	st.mask_union = { ["signal-A"] = 7 }
	return st
end

--- Provides coal on A1 from the station combinator and requests it on A2 through Inventory 1.
function F.coal_both(id)
	local s = source("station", 0, 2001)
	local i1 = source("inventory", 1, 2002, 3)
	local req = { count = -2000, threshold = 1000, active = true }
	local st = base({
		id = id,
		name = "Coal hub",
		is_p = true,
		is_r = true,
		network_name = "signal-A",
		network_mask = 1,
		provided = { [F.COAL] = 5000 },
		requested = { [F.COAL] = req },
	})
	st.sources = { s, i1 }
	st.sections = {
		section("signal-A", 1, { s }, { [F.COAL] = 5000 }),
		section("signal-A", 2, { i1 }, {}, { [F.COAL] = req }),
	}
	st.mask_union = { ["signal-A"] = 3 }
	return st
end

--- A plain station with one section that shares its provided / requested tables, as the contract promises.
function F.plain(id, name, mask, provided, requested)
	local st = base({ id = id, name = name, network_name = "signal-A", network_mask = mask, provided = provided or {},
		requested = requested or {} })
	local s = source("station", 0, 9000 + id)
	st.sources = { s }
	st.sections = { { key = "signal-A:" .. mask, network_name = "signal-A", mask = mask, sources = { s },
		provided = st.provided, requested = st.requested, ignored = {} } }
	st.mask_union = { ["signal-A"] = mask }
	return st
end

--- collector.station_has_sections as the contract defines it.
function F.has_sections(st)
	if #st.sections > 1 then return true end
	for _, src in ipairs(st.sources) do
		if src.kind == "inventory" then return true end
	end
	return false
end

function F.mask_label(mask) return tostring(mask) end

function F.mask_bits_label(mask)
	local bits = {}
	for b = 1, 32 do
		if bit32.btest(mask, bit32.lshift(1, b - 1)) then bits[#bits + 1] = tostring(b) end
	end
	if #bits < 2 then return nil end
	return "bits " .. table.concat(bits, "+")
end

function F.source_label(src)
	if src.kind == "station" then return { "cybersyn-gui.source-station" } end
	return { "cybersyn-gui.source-inventory", tostring(src.index) }
end

--- Installs the helper stubs on a loaded collector table that does not have them yet.
function F.stub_collector(collector)
	for _, k in ipairs({ "has_sections", "mask_label", "mask_bits_label", "source_label" }) do
		local name = k == "has_sections" and "station_has_sections" or k
		if collector[name] == nil then collector[name] = F[k] end
	end
end

return F
