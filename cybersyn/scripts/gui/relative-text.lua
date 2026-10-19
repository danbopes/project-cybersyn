-- The pure parts of the relative panels (PLAN3 §4.9): role and threshold arithmetic, the fleet counts of the
-- Effective config section, schedule and event rows. Every function takes plain values and returns plain values or
-- LocalisedStrings, so the host unit tests cover them without the engine.

local format = require("__flib__.format")
local logic = require("scripts.gui.tab-logic")

local band = bit32.band
local bor = bit32.bor

local text = {}

text.NO_VALUE = "–"
-- Train limits read back as uint max when unset.
text.UNLIMITED = 2100000000
-- Ages and durations shown in the panel are rounded down to this many ticks, so a panel left open is rebuilt at most
-- once per step instead of every update.
text.AGE_STEP = 600

--- "Provider · Requester", "Provider", "Requester" (or none), with " · stack thresholds" in stack mode.
--- @param is_p boolean
--- @param is_r boolean
--- @param is_stack boolean
--- @return LocalisedString
function text.role(is_p, is_r, is_stack)
	local key
	if is_p and is_r then
		key = "cybersyn-gui.relative-role-both"
	elseif is_p then
		key = "cybersyn-gui.relative-role-provider"
	elseif is_r then
		key = "cybersyn-gui.relative-role-requester"
	else
		key = "cybersyn-gui.relative-role-none"
	end
	if is_stack then return { "", { key }, " · ", { "cybersyn-gui.relative-stack-mode" } } end
	return { key }
end

--- Whole stacks a threshold in items occupies: the slots a train needs to carry it.
--- @param threshold number items
--- @param stack_size number?
--- @return int
function text.stacks(threshold, stack_size)
	if not stack_size or stack_size <= 0 then return 0 end
	return math.ceil(threshold / stack_size)
end

--- The threshold the dispatcher holds a request against: a provider's own item threshold replaces the requester's
--- when it is lower (central-planning.lua, the effective_threshold of tick_dispatch).
--- @param threshold number
--- @param override number?
--- @return number
--- @return boolean overridden
function text.effective_threshold(threshold, override)
	if override and override < threshold then return override, true end
	return threshold, false
end

--- The train-side mask of a Cybersyn train on one network, nil when the train is not on it.
--- @param train {network_name: string?, network_mask: int|{[string]: int}?}
--- @param network string
--- @return int?
function text.train_mask(train, network)
	local name = train.network_name
	if name == NETWORK_EACH then
		local m = train.network_mask
		return type(m) == "table" and m[network] or nil
	elseif name == network then
		local m = train.network_mask
		return type(m) == "number" and m or 0
	end
	return nil
end

--- @class RelativeFleetCount per network of a stop: what its mask matches and what the fleet offers
--- @field mask int the stop's mask on the network
--- @field trains int Cybersyn trains on the network whose mask shares a bit with the stop's
--- @field depots int distinct depots among those trains
--- @field depot_set {[uint]: true}
--- @field capability {[uint]: {count: int, item_capacity: int, fluid_capacity: int, mask_or: int}} per layout, every
---   train on the network (the shape of snapshot.fleet.capability[network])
--- @field matched {[uint]: {count: int, item_capacity: int, fluid_capacity: int}} per layout, only the trains whose
---   own mask shares a bit with the stop's: a layout's OR-ed mask cannot tell which of its trains match

--- @param mask int
--- @return RelativeFleetCount
function text.new_fleet_count(mask)
	return { mask = mask, trains = 0, depots = 0, depot_set = {}, capability = {}, matched = {} }
end

--- Adds one Cybersyn train to a stop's per-network counts.
--- @param counts {[string]: RelativeFleetCount}
--- @param train {network_name: string?, network_mask: any, depot_id: uint?, layout_id: uint?, item_slot_capacity: int?, fluid_capacity: int?}
function text.count_train(counts, train)
	for network, c in pairs(counts) do
		local m = text.train_mask(train, network)
		if m then
			local layout_id = train.layout_id or 0
			local cap = c.capability[layout_id]
			if not cap then
				cap = { count = 0, item_capacity = 0, fluid_capacity = 0, mask_or = 0 }
				c.capability[layout_id] = cap
			end
			cap.count = cap.count + 1
			local items, fluid = train.item_slot_capacity or 0, train.fluid_capacity or 0
			if items > cap.item_capacity then cap.item_capacity = items end
			if fluid > cap.fluid_capacity then cap.fluid_capacity = fluid end
			cap.mask_or = bor(cap.mask_or, m)
			if band(m, c.mask) ~= 0 then
				c.trains = c.trains + 1
				local hit = c.matched[layout_id]
				if not hit then
					hit = { count = 0, item_capacity = 0, fluid_capacity = 0 }
					c.matched[layout_id] = hit
				end
				hit.count = hit.count + 1
				if items > hit.item_capacity then hit.item_capacity = items end
				if fluid > hit.fluid_capacity then hit.fluid_capacity = fluid end
				local depot = train.depot_id
				if depot and not c.depot_set[depot] then
					c.depot_set[depot] = true
					c.depots = c.depots + 1
				end
			end
		end
	end
end

--- "LCCL": one letter per carriage of a layout (0 locomotive, 1 cargo wagon, 2 fluid wagon).
--- @param layout int[]?
--- @return string
function text.layout_text(layout)
	if not layout then return "?" end
	local out = {}
	for i, v in ipairs(layout) do
		out[i] = v == 0 and "L" or v == 1 and "C" or v == 2 and "F" or "?"
	end
	return table.concat(out)
end

--- The trains a stop on one network can be sent: mask match (train by train) and a layout the stop accepts, with
--- the largest capacities among them. The one count the Effective config section shows wherever it says "trains match".
--- @param c RelativeFleetCount?
--- @param allows_all boolean
--- @param accepted {[uint]: true?}
--- @return int trains
--- @return int item_capacity
--- @return int fluid_capacity
function text.eligible(c, allows_all, accepted)
	local trains, items, fluid = 0, 0, 0
	if not c then return 0, 0, 0 end
	for layout_id, l in pairs(c.matched) do
		if allows_all or accepted[layout_id] then
			trains = trains + l.count
			if l.item_capacity > items then items = l.item_capacity end
			if l.fluid_capacity > fluid then fluid = l.fluid_capacity end
		end
	end
	return trains, items, fluid
end

--- The allow-list line: how many layouts the stop accepts, how many trains it can be sent (text.eligible), and the
--- accepted layouts no train on the network has at all.
--- @param accepted {[uint]: true?}
--- @param allows_all boolean
--- @param c RelativeFleetCount?
--- @return int|false layouts accepted, false = every layout
--- @return int trains eligible trains
--- @return uint[] missing accepted layout ids no train on the network has, ascending
function text.allow_list(accepted, allows_all, c)
	local trains = text.eligible(c, allows_all, accepted)
	if allows_all then return false, trains, {} end
	local capability = c and c.capability or {}
	local n, missing = 0, {}
	for layout_id in pairs(accepted) do
		n = n + 1
		if not capability[layout_id] then missing[#missing + 1] = layout_id end
	end
	table.sort(missing)
	return n, trains, missing
end

--- One line of the schedule list.
--- @param index int
--- @param record {station: string?, rail: any?, temporary: boolean?, created_by_interrupt: boolean?}
--- @param current int the active record's index
--- @return {caption: LocalisedString, active: boolean}
function text.schedule_row(index, record, current)
	local active = index == current
	local target
	if record.station then
		target = record.station
	elseif record.rail then
		target = { "cybersyn-gui.relative-schedule-rail" }
	else
		target = text.NO_VALUE
	end
	local caption = { "", active and "▶ " or "    ", tostring(index), ". ", target }
	if record.created_by_interrupt then
		caption[#caption + 1] = " "
		caption[#caption + 1] = { "cybersyn-gui.relative-schedule-interrupt" }
	elseif record.temporary then
		caption[#caption + 1] = " "
		caption[#caption + 1] = { "cybersyn-gui.relative-schedule-temporary" }
	end
	return { caption = caption, active = active }
end

--- An age rounded down to AGE_STEP ticks, for captions that must not change every update.
--- @param ticks number
--- @return number
function text.age_step(ticks)
	ticks = math.max(ticks or 0, 0)
	return ticks - ticks % text.AGE_STEP
end

--- The caption of one event row: "2m 10s  Unserved · Provider low". `detail` is what the kind needs after the dot
--- (the reason, the lint check, the planned and actual amounts), nil when the kind needs nothing.
--- @param ev {tick: uint, kind: int, code: int, a: int, b: int}
--- @param now uint
--- @return LocalisedString
function text.event_row(ev, now)
	local key = DIAG_KIND_KEYS[ev.kind]
	local kind = key and { "cybersyn-diag.kind-" .. key } or tostring(ev.kind)
	local caption = { "", logic.short_duration(text.age_step(now - ev.tick)), "  ", kind }
	local detail = text.event_detail(ev)
	if detail then
		caption[#caption + 1] = " · "
		caption[#caption + 1] = detail
	end
	return caption
end

--- @param ev {kind: int, code: int, a: int, b: int}
--- @return LocalisedString?
function text.event_detail(ev)
	local kind, code = ev.kind, ev.code
	if kind == DIAG_KIND_UNSERVED_REASON or kind == DIAG_KIND_FLAPPING then
		local key = REASON_KEYS[code]
		return key and { "cybersyn-diag.chip-" .. key } or nil
	elseif kind == DIAG_KIND_SHORT_LOAD or kind == DIAG_KIND_UNEXPECTED_CARGO or kind == DIAG_KIND_RESIDUAL_CARGO then
		return { "cybersyn-gui.relative-event-cargo", format.number(ev.a or 0), format.number(ev.b or 0) }
	elseif kind == DIAG_KIND_LINT then
		local check_key = LINT_KEYS[ev.a]
		local verb = code == DIAG_LINT_APPEARED and "cybersyn-diag.lint-appeared" or "cybersyn-diag.lint-cleared"
		if check_key then return { "", { "cybersyn-diag.lint-" .. check_key }, " (", { verb }, ")" } end
		return { verb }
	elseif kind == DIAG_KIND_STATION_LIMIT then
		return { "cybersyn-gui.relative-event-limit", tostring(ev.a or 0), tostring(ev.b or 0) }
	elseif kind == DIAG_KIND_DISPATCH_FAILED then
		local name = DIAG_DISPATCH_NAMES[code]
		return name and { "cybersyn-diag.dispatch-" .. string.gsub(name, "_", "-") } or nil
	end
	return nil
end

--- The combinator's "S" colour for a station's display_state (main.lua: 0 cyan, odd green, else red).
--- @param display_state int?
--- @return "cyan"|"green"|"red"
function text.s_colour(display_state)
	display_state = display_state or 0
	if display_state == 0 then return "cyan" end
	if display_state % 2 == 1 then return "green" end
	return "red"
end

--- "1 / 2" for deliveries against the train limit, "1 / ∞" without a limit.
--- @param deliveries int
--- @param limit int
--- @return string
function text.trains_pair(deliveries, limit)
	local l = (limit or 0) >= text.UNLIMITED and "∞" or tostring(limit or 0)
	return tostring(deliveries or 0) .. " / " .. l
end

--- The mask as a number, with its bits for a small positive mask: "5 (101)"; "-1" alone (every bit).
--- @param mask int
--- @return string
function text.mask_text(mask)
	mask = mask or 0
	if mask < 0 or mask >= 65536 then return tostring(mask) end
	local m = mask
	local bits = {}
	while m > 0 and #bits < 32 do
		bits[#bits + 1] = tostring(m % 2)
		m = math.floor(m / 2)
	end
	if #bits == 0 then bits[1] = "0" end
	local out = {}
	for i = #bits, 1, -1 do out[#out + 1] = bits[i] end
	return tostring(mask) .. " (" .. table.concat(out) .. ")"
end

return text
