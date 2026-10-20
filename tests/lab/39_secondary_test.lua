-- Round 7 B1/B4: secondary inventory combinators. A station whose two inventory combinators were there before its
-- station combinator (the station-built path) registers them by unit number, so removing one unregisters it; a
-- request on an inventory combinator gets a wait start that survives the station combinator's own pass and clears
-- when the request stops.
--
-- Row k = 100 on cyb-bench with a network of its own, torn down at the end.

local K = 100
local NETWORK = "signal-8"
local MODE_STATION, MODE_INVENTORY = "/", "AND"
local ALLOW_ALL = 4
local THRESHOLD = "cybersyn-request-threshold"

local function read(...)
	return (remote.call("cybersyn", "read_global", ...))
end

local function keys(t)
	local out = {}
	for k in pairs(t or {}) do out[#out + 1] = k end
	table.sort(out)
	return out
end

--- A Cybersyn combinator beside `st.stop` at x offset `dx` (cases.station's comb sits at +1.5), optionally wired to
--- a constant combinator sending `signals`.
local function comb_at(case, st, dx, op, signals)
	local s, force = case.surface, game.forces.player
	local x, y = st.stop.position.x, st.stop.position.y
	local comb = s.create_entity({ name = "cybersyn-combinator", position = { x + dx, y - 2.5 },
		direction = defines.direction.north, force = force })
	case.entities[#case.entities + 1] = comb
	local ctl = comb.get_or_create_control_behavior()
	local params = ctl.parameters
	params.operation = op
	params.first_signal = { type = "virtual", name = NETWORK }
	params.second_constant = op == MODE_STATION and ALLOW_ALL or 0
	ctl.parameters = params
	script.raise_script_built({ entity = comb })
	if signals then
		local cc = s.create_entity({ name = "constant-combinator", position = { x + dx, y - 4.5 }, force = force })
		case.entities[#case.entities + 1] = cc
		cc.get_wire_connector(defines.wire_connector_id.circuit_red, true)
			.connect_to(comb.get_wire_connector(defines.wire_connector_id.combinator_input_red, true), false)
		cases.set_signals({ cc = cc }, signals)
	end
	return comb
end

local function wait_tick(id)
	local t = read("stations", id, "request_start_ticks")
	return t and t["iron-plate"]
end

local steps = {
	function(ctx)
		local case = cases.base("SECONDARY", { k = K }, { network = NETWORK, no_train = true })
		ctx.case = case
		-- cases.station builds the stop with its first inventory combinator (no station exists yet)
		local inv1 = cases.station(case, { name = "r7-secondary", x = cases.X_R[1], mode = MODE_INVENTORY })
		ctx.st, ctx.inv1 = inv1, inv1.comb
		ctx.inv2 = comb_at(case, inv1, 0.5, MODE_INVENTORY)
		lab.check("no station before its station combinator", read("stations", inv1.id) == nil)
		ctx.primary = comb_at(case, inv1, -0.5, MODE_STATION, { { THRESHOLD, 1000, "virtual" } })
		local combs = read("stations", inv1.id, "secondary_inv_combs")
		lab.check("the station-built path keys inventory combinators by unit number", lab.same_list(keys(combs),
			keys({ [ctx.inv1.unit_number] = 1, [ctx.inv2.unit_number] = 1 })), { got = keys(combs),
			want = { ctx.inv1.unit_number, ctx.inv2.unit_number } })

		ctx.inv2.destroy({ raise_destroy = true })
		combs = read("stations", inv1.id, "secondary_inv_combs")
		lab.check("a removed inventory combinator is unregistered", lab.same_list(keys(combs),
			{ ctx.inv1.unit_number }), keys(combs))

		cases.set_signals(inv1, { { "iron-plate", -2000 } })
		cases.finish(case)
		lab.wait_until(function() return wait_tick(inv1.id) ~= nil end, 1800)
	end,
	function(ctx)
		local id = ctx.st.id
		ctx.start = wait_tick(id)
		lab.check("a request on an inventory combinator gets a wait start", ctx.start ~= nil,
			read("stations", id, "request_start_ticks"))
		lab.check("the inventory combinator is polled as its own source",
			read("stations", id, "stops", ctx.inv1.unit_number) ~= nil)
		lab.wait(900)
	end,
	function(ctx)
		local id = ctx.st.id
		lab.check("the wait start holds across polls while only the inventory combinator requests",
			wait_tick(id) == ctx.start, { start = ctx.start, now = wait_tick(id) })
		cases.set_signals(ctx.st, {})
		lab.wait_until(function() return wait_tick(id) == nil end, 1800)
	end,
	function(ctx)
		lab.check("the wait clears once the inventory request stops", wait_tick(ctx.st.id) == nil,
			read("stations", ctx.st.id, "request_start_ticks"))
		ctx.case.cleanup()
		lab.check("the station is gone after teardown", read("stations", ctx.st.id) == nil)
	end,
}

lab.suite("secondary", steps)
