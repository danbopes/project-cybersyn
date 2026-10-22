-- PLAN8 D8-4: the red I. A station (requester, threshold 1,000) with two inventory combinators; the first asks for
-- 2,000 iron nobody provides. By the end of the first whole planner pass after the request its combinator shows OR
-- (the red I), the second inventory keeps its cyan I, and the station combinator shows the red S as it did before
-- round 8 (the station has a failed request) but never the I. A red I copied by blueprint is built as AND; one
-- copied onto the second inventory goes out there and leaves it registered. Then a provider offers the iron: the
-- train is dispatched, the inventory stops requesting (the delivery covers it) and the first whole pass after that
-- shows AND and clears the S bit. Last, a red I outlives neither the removal of its station combinator nor a rebuild.
--
-- Row k = 110 on cyb-bench with a network of its own (one train), torn down at the end.

local K = 110
local NETWORK = "signal-pink"
local MODE_STATION, MODE_INVENTORY = "/", "AND"
local PR_PROVIDE, PR_REQUEST, ALLOW_ALL = 1, 2, 4
local THRESHOLD = "cybersyn-request-threshold"

local function read(...)
	return (remote.call("cybersyn", "read_global", ...))
end

local function op(comb)
	return comb.valid and comb.get_or_create_control_behavior().parameters.operation or nil
end

--- An inventory combinator `dx` tiles west of the station combinator (in the stop's reach), wired to a constant
--- combinator of its own.
local function inventory(case, st, dx)
	local s, force = case.surface, game.forces.player
	local x, y = st.comb.position.x - dx, st.comb.position.y
	local comb = s.create_entity({ name = "cybersyn-combinator", position = { x, y },
		direction = defines.direction.north, force = force })
	case.entities[#case.entities + 1] = comb
	local ctl = comb.get_or_create_control_behavior()
	local params = ctl.parameters
	params.operation = MODE_INVENTORY
	params.first_signal = { type = "virtual", name = NETWORK }
	params.second_constant = 0
	ctl.parameters = params
	script.raise_script_built({ entity = comb })
	local cc = s.create_entity({ name = "constant-combinator", position = { x, y - 2 }, force = force })
	case.entities[#case.entities + 1] = cc
	cc.get_wire_connector(defines.wire_connector_id.circuit_red, true)
		.connect_to(comb.get_wire_connector(defines.wire_connector_id.combinator_input_red, true), false)
	local rec = { comb = comb, cc = cc, unit = comb.unit_number }
	cases.set_signals(rec, {})
	return rec
end

--- Planner passes are counted on Cybersyn's tick_init event (the start of every pass); `at[n]` snapshots the
--- displays when pass n starts, i.e. right after pass n - 1 finished.
local function watch(ctx)
	ctx.pass = 0
	ctx.at = {}
	script.on_event(remote.call("cybersyn", "get_on_tick_init"), function()
		ctx.pass = ctx.pass + 1
		ctx.at[ctx.pass] = { inv1 = op(ctx.inv1.comb), inv2 = op(ctx.inv2.comb), station = op(ctx.st.comb),
			display_state = read("stations", ctx.st.id, "display_state"),
			inv_failed = read("stations", ctx.st.id, "inv_failed") }
	end)
end

local function unwatch()
	script.on_event(remote.call("cybersyn", "get_on_tick_init"), nil)
end

local steps = {
	function(ctx)
		local case = cases.base("RED_I", { k = K }, { network = NETWORK })
		ctx.case = case
		ctx.st = cases.station(case, { name = "r8-red-i", x = cases.X_R[1], bits = PR_REQUEST + ALLOW_ALL,
			signals = { { THRESHOLD, 1000, "virtual" } } })
		ctx.inv1 = inventory(case, ctx.st, 1)
		ctx.inv2 = inventory(case, ctx.st, 2)
		ctx.p = cases.station(case, { name = "r8-red-i-p", x = cases.X_P[1], bits = PR_PROVIDE + ALLOW_ALL })
		cases.finish(case)
		watch(ctx)
		lab.wait_until(function() return cases.trains_ready(case) and ctx.pass >= 2 end, 3600)
	end,
	function(ctx)
		local combs = read("stations", ctx.st.id, "secondary_inv_combs") or {}
		lab.check("both inventory combinators are registered", combs[ctx.inv1.unit] ~= nil and combs[ctx.inv2.unit] ~= nil)
		lab.check("the train is parked", cases.trains_ready(ctx.case))
		lab.check("nothing is red before the request", op(ctx.inv1.comb) == MODE_INVENTORY and op(ctx.st.comb) == MODE_STATION,
			{ inv1 = op(ctx.inv1.comb), station = op(ctx.st.comb) })
		cases.set_signals(ctx.inv1, { { "iron-plate", -2000 } })
		ctx.c0 = ctx.pass
		lab.wait_until(function() return ctx.pass >= ctx.c0 + 2 end, 3600)
	end,
	function(ctx)
		-- Pass c0 may have polled the station before the request was set; pass c0 + 1 is the first whole one.
		local snap = ctx.at[ctx.c0 + 2] or {}
		lab.check("an unserved inventory request shows OR within one planner pass", snap.inv1 == "OR", snap)
		lab.check("the planner records the failure per inventory combinator",
			snap.inv_failed ~= nil and snap.inv_failed[ctx.inv1.unit] == true and snap.inv_failed[ctx.inv2.unit] == nil,
			snap.inv_failed)
		lab.check("the other inventory combinator stays AND", snap.inv2 == MODE_INVENTORY, snap.inv2)
		lab.check("the station combinator shows the red S as before, not the I", snap.station == "^"
			and bit32.band(snap.display_state or 0, 2) == 2, { op = snap.station, display_state = snap.display_state })
		lab.check("the stored params say AND", (read("to_comb_params", ctx.inv1.unit) or {}).operation == MODE_INVENTORY,
			read("to_comb_params", ctx.inv1.unit))

		-- Blueprint the red I and build the copy away from any stop.
		local s = ctx.case.surface
		local inv = game.create_inventory(1)
		inv.insert({ name = "blueprint" })
		local bp = inv[1]
		local pos = ctx.inv1.comb.position
		bp.create_blueprint({ surface = s, force = game.forces.player,
			area = { { pos.x - 0.4, pos.y - 0.9 }, { pos.x + 0.4, pos.y + 0.9 } } })
		local ents = bp.get_blueprint_entities() or {}
		lab.check("the blueprint holds the red I (OR)", #ents == 1 and serpent.line(ents):find('"OR"', 1, true) ~= nil,
			ents)
		local where = { pos.x - 30.5, pos.y }
		local built = bp.build_blueprint({ surface = s, force = game.forces.player, position = where,
			build_mode = defines.build_mode.forced, raise_built = true })
		inv.destroy()
		local ghost = built and built[1]
		if ghost then ctx.case.entities[#ctx.case.entities + 1] = ghost end
		lab.check("the blueprint's ghost is AND", ghost ~= nil and ghost.valid
			and ghost.get_or_create_control_behavior().parameters.operation == MODE_INVENTORY,
			ghost and ghost.valid and ghost.get_or_create_control_behavior().parameters.operation)
		local copy
		if ghost and ghost.valid then
			local _, revived = ghost.revive({ raise_revive = true })
			copy = revived
		end
		if copy then ctx.case.entities[#ctx.case.entities + 1] = copy end
		lab.check("the built copy is AND", copy ~= nil and op(copy) == MODE_INVENTORY, copy and op(copy))

		-- A red I copied onto the second inventory, then combinator_update without reset_display (the combinator
		-- window's path; copy_settings raises no on_entity_settings_pasted, whose handler passes reset_display and
		-- takes the same branch): it has not failed, so it goes out, and it stays registered (no rebuild).
		ctx.inv2.comb.copy_settings(ctx.inv1.comb)
		local pasted = op(ctx.inv2.comb)
		remote.call("cybersyn", "combinator_update", ctx.inv2.comb)
		local combs = read("stations", ctx.st.id, "secondary_inv_combs") or {}
		lab.check("a red I copied onto an inventory that has not failed shows AND after combinator_update", pasted == "OR"
			and op(ctx.inv2.comb) == MODE_INVENTORY, { pasted = pasted, now = op(ctx.inv2.comb) })
		lab.check("the pasted-onto inventory stays registered", combs[ctx.inv2.unit] ~= nil)
		lab.check("the failed inventory keeps its red I", op(ctx.inv1.comb) == "OR")

		-- Provide it.
		cases.set_signals(ctx.p, { { "iron-plate", 5000 } })
		lab.wait_until(function() return (read("stations", ctx.st.id, "deliveries_total") or 0) > 0 end, 3600)
	end,
	function(ctx)
		lab.check("the inventory request is dispatched", (read("stations", ctx.st.id, "deliveries_total") or 0) > 0)
		ctx.c1 = ctx.pass
		lab.wait_until(function() return ctx.pass >= ctx.c1 + 2 end, 3600)
	end,
	function(ctx)
		local snap = ctx.at[ctx.c1 + 2] or {}
		lab.check("served (the delivery covers the request): back to AND within one planner pass",
			snap.inv1 == MODE_INVENTORY and snap.inv_failed == nil, snap)
		lab.check("served: the station's S bit clears with it", bit32.band(snap.display_state or 0, 2) == 0, snap)
		-- Copper nobody provides lights the I again for the removal check.
		cases.set_signals(ctx.inv1, { { "copper-plate", -2000 } })
		ctx.c2 = ctx.pass
		lab.wait_until(function() return ctx.pass >= ctx.c2 + 2 end, 3600)
	end,
	function(ctx)
		lab.check("an unserved copper request lights the I again", op(ctx.inv1.comb) == "OR", op(ctx.inv1.comb))
		local comb = ctx.st.comb
		local pos, params = comb.position, comb.get_or_create_control_behavior().parameters
		comb.destroy({ raise_destroy = true })
		lab.check("removing the station combinator drops the station and puts out the I",
			read("stations", ctx.st.id) == nil and op(ctx.inv1.comb) == MODE_INVENTORY,
			{ station = read("stations", ctx.st.id) ~= nil, inv1 = op(ctx.inv1.comb) })

		-- A red I left over from an older build (before the removal reset it) is put out when the station is rebuilt.
		local ctl = ctx.inv1.comb.get_or_create_control_behavior()
		local p1 = ctl.parameters
		p1.operation = "OR"
		ctl.parameters = p1
		local again = ctx.case.surface.create_entity({ name = "cybersyn-combinator", position = pos,
			direction = defines.direction.north, force = game.forces.player })
		ctx.case.entities[#ctx.case.entities + 1] = again
		again.get_or_create_control_behavior().parameters = params
		script.raise_script_built({ entity = again })
		local combs = read("stations", ctx.st.id, "secondary_inv_combs") or {}
		lab.check("a rebuilt station adopts the inventory and shows its I cyan",
			combs[ctx.inv1.unit] ~= nil and op(ctx.inv1.comb) == MODE_INVENTORY,
			{ adopted = combs[ctx.inv1.unit] ~= nil, inv1 = op(ctx.inv1.comb) })
		unwatch()
		ctx.case.cleanup()
		lab.check("the station is gone after teardown", read("stations", ctx.st.id) == nil)
	end,
}

lab.suite("red_i", steps)
