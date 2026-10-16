-- Pure rules of the phase-10 extras (PLAN3 §11, §4.14): no game API, so the host unit tests run them as they are.

local logic = {}

-- ---------------------------------------------------------------- path trace

--- Most line objects one trace may draw per render mode; the trace draws each segment twice (game and chart view),
--- so a player never holds more than 2 × this many objects (PLAN3 §11.1: ≤ 256).
logic.TRACE_SEGMENTS = 128
logic.TRACE_TICKS = 600

--- Whether b continues the straight line a→b→c: the turn at b is below about 1°. Rail centres of a straight run lie
--- exactly on one line; a curve or a diagonal change turns by at least 22.5° between neighbours.
--- @return boolean
local function collinear(ax, ay, bx, by, cx, cy)
	local ux, uy = bx - ax, by - ay
	local vx, vy = cx - bx, cy - by
	local dot = ux * vx + uy * vy
	if dot <= 0 then return false end
	local cross = ux * vy - uy * vx
	return cross * cross <= 0.0003 * (ux * ux + uy * uy) * (vx * vx + vy * vy)
end

--- Polyline vertices for a path of points: duplicates dropped, interior points of collinear runs dropped, then, if
--- still more than `max_segments` segments, exactly `max_segments` + 1 of them kept, evenly spread (the first and the
--- last always).
--- @param xs number[]
--- @param ys number[]
--- @param n int points to read from xs/ys
--- @param max_segments int?
--- @return number[] vx
--- @return number[] vy
--- @return int runs segments after the collinear merge, before any thinning
function logic.sample_runs(xs, ys, n, max_segments)
	max_segments = max_segments or logic.TRACE_SEGMENTS
	local px, py = {}, {}
	for i = 1, n do
		local x, y = xs[i], ys[i]
		local m = #px
		if m == 0 or px[m] ~= x or py[m] ~= y then
			px[m + 1], py[m + 1] = x, y
		end
	end
	local m = #px
	if m < 2 then return px, py, 0 end
	local vx, vy = { px[1] }, { py[1] }
	for i = 2, m - 1 do
		local k = #vx
		if not collinear(vx[k], vy[k], px[i], py[i], px[i + 1], py[i + 1]) then
			vx[k + 1], vy[k + 1] = px[i], py[i]
		end
	end
	vx[#vx + 1], vy[#vy + 1] = px[m], py[m]
	local runs = #vx - 1
	if runs <= max_segments then return vx, vy, runs end
	-- Evenly spread over the turning points, so the whole budget is used and no stretch loses all its corners.
	local tx, ty = {}, {}
	for k = 0, max_segments do
		local i = 1 + math.floor(k * runs / max_segments + 0.5)
		tx[k + 1], ty[k + 1] = vx[i], vy[i]
	end
	return tx, ty, runs
end

-- ---------------------------------------------------------------- confirm step

--- Ticks an armed action button waits for its second click (PLAN3 §4.14), counted on the manager tick.
logic.CONFIRM_TICKS = 180

--- @class ConfirmState
--- @field key string the action and its target, e.g. "fail:12"
--- @field tick uint when the first click armed it

--- A click on the button `key`: the first click arms it, a second click within CONFIRM_TICKS fires it. A click on
--- another button arms that one instead (one armed button per player). `shown` = the button still reads "Confirm?"
--- (its expiry has not been drawn yet): what the player saw is what the click does, so it fires.
--- @param cur ConfirmState?
--- @param key string
--- @param now uint
--- @param shown boolean? the clicked button shows the armed state
--- @return ConfirmState? next state
--- @return boolean fire
function logic.confirm_click(cur, key, now, shown)
	if cur and cur.key == key and (now - cur.tick < logic.CONFIRM_TICKS or shown) then return nil, true end
	return { key = key, tick = now }, false
end

--- @param cur ConfirmState?
--- @param key string
--- @param now uint
--- @return boolean
function logic.confirm_armed(cur, key, now)
	return cur ~= nil and cur.key == key and now - cur.tick < logic.CONFIRM_TICKS
end

--- @param cur ConfirmState?
--- @param now uint
--- @return boolean
function logic.confirm_expired(cur, now)
	return cur ~= nil and now - cur.tick >= logic.CONFIRM_TICKS
end

-- ---------------------------------------------------------------- chunked job

--- Trains one manager update of the Refresh allow-lists job handles (PLAN3 §4.14).
logic.JOB_CHUNK = 50

--- Stop visits one chunk may spend. A train whose layout no other train shares costs two walks over every station and
--- refueler in update_train_layout (the old layout dropped, the new one tested against every allow-list), so on a
--- large map a 50-train chunk of such trains would blow the update budget; other trains cost about nothing here.
logic.JOB_STOP_VISITS = 4096

--- The stop visits update_train_layout makes for one train.
--- @param singleton boolean no other train shares its layout
--- @param stops int stations + refuelers
--- @return int
function logic.job_cost(singleton, stops)
	return singleton and 2 * stops or 0
end

--- Whether a chunk that has handled `done` trains and spent `spent` stop visits may take one more train costing
--- `cost`. The first train of a chunk always runs, so the job advances whatever one train costs.
--- @param done int
--- @param spent int
--- @param cost int
--- @param chunk int? trains per chunk, default JOB_CHUNK
--- @param budget int? stop visits per chunk, default JOB_STOP_VISITS
--- @return boolean
function logic.job_continue(done, spent, cost, chunk, budget)
	if done == 0 then return true end
	if done >= (chunk or logic.JOB_CHUNK) then return false end
	return spent + cost <= (budget or logic.JOB_STOP_VISITS)
end

-- ---------------------------------------------------------------- HUD

--- The HUD's numbers from the live unserved entries per reason and the available trains per network. `headroom` is
--- the fewest available trains on any one network right now (shown as "free trains": the Overview's Fleet headroom
--- is a minimum over a period, a different number); a network in `networks` that never had an available train has no
--- counter and counts as 0. nil without any network.
--- @param counts {[int]: int} diag.counts_by_reason()
--- @param available {[string]: int} stats available_count
--- @param networks {[string]: true}? networks that have Cybersyn trains
--- @return {unserved: int, headroom: int?, network: string?, top_reason: int?, top_count: int}
function logic.hud_values(counts, available, networks)
	local total, top, top_n = 0, nil, 0
	for reason, n in pairs(counts) do
		total = total + n
		if n > top_n or (n == top_n and top and reason < top) then top, top_n = reason, n end
	end
	local headroom, network
	local function consider(name, n)
		if not headroom or n < headroom or (n == headroom and name < network) then headroom, network = n, name end
	end
	for name, n in pairs(available) do consider(name, n) end
	for name in pairs(networks or {}) do
		if available[name] == nil then consider(name, 0) end
	end
	return { unserved = total, headroom = headroom, network = network, top_reason = top, top_count = top_n }
end

-- ---------------------------------------------------------------- Test path

--- @class PathCandidate
--- @field id uint train id
--- @field available boolean parked or bypassing, ready for a delivery
--- @field fits boolean the stop's allow-list accepts the train's layout
--- @field capacity number item stacks plus fluid / 1000, only to rank

--- The train a Test path click asks the pathfinder for: a named train first, then the largest available train the
--- stop accepts, then any train the stop accepts, then any; ties go to the lowest id. This only picks a subject for
--- the pathfinder; it never decides eligibility (PLAN3 §11.8).
--- @param candidates PathCandidate[]
--- @param named uint? a train the caller named (the row's delivery)
--- @return uint?
function logic.pick_train(candidates, named)
	if named then
		for _, c in ipairs(candidates) do
			if c.id == named then return named end
		end
	end
	local best, best_rank
	for _, c in ipairs(candidates) do
		local rank = (c.fits and 2 or 0) + (c.available and 1 or 0)
		if not best or rank > best_rank or (rank == best_rank and (c.capacity > best.capacity
				or (c.capacity == best.capacity and c.id < best.id))) then
			best, best_rank = c, rank
		end
	end
	return best and best.id or nil
end

return logic
