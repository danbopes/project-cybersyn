-- PLAN3 phase 6b: the Problems tab. Hidden until the lint job has a result; one row per finding of the last lint pass
-- and the setup registry, grouped by check in whole rows with the right detail numbers and fix line; the badge and the
-- Overview's misconfigured line counting the same pass; filters, pages, acknowledge with expiry, and the registry's
-- rows with their entity links.
--
-- lab.problems_verify(label) is defined here for 39_lint and 40_reason_codes too: it checks every finding there is
-- against the tab's model and notes which checks it saw, so the last suite can assert that every check produced a
-- row somewhere in the run (lab.problems_coverage).

local D, pi = lab.D, lab.pi
local HOUR = 216000
local DAY = 24 * HOUR
local ROW_K = 45

local function dev(fn, ...)
	return remote.call(D, fn, ...)
end

local function key_of(c)
	return type(c) == "table" and c[1] or c
end

local function dash(name)
	return (string.gsub(name, "_", "-"))
end

--- "12,345" as flib's format.number writes it.
local function number(v)
	local s = tostring(math.floor(math.abs(v)))
	local out = s:reverse():gsub("(%d%d%d)", "%1,"):reverse()
	if out:sub(1, 1) == "," then out = out:sub(2) end
	return (v < 0 and "-" or "") .. out
end

-- The detail numbers each check shows: "n" formatted, "s" as a plain integer (masks), nil = none.
local NUMBERS = {
	capacity = { a = "n", b = "n" },
	layout = { a = "n", b = "n" },
	mask = { a = "s", b = "s" },
	occupancy = { a = "n", b = "n" },
	depot_limit = { a = "n" },
	priority = { a = "n" },
	depot_shared_name = { a = "n", b = "n" },
	refueler_mask = { a = "s", b = "s" },
	in_group = { a = "n" },
	missing_stop = { a = "n" },
	capacity_drift = { a = "n", b = "n" },
	train_mask = { a = "s", b = "s" },
	same_item = { a = "n" },
}

local WORLD = { derelict_comb = true, ghost_comb = true, no_comb = true, wrong_side = true, double_comb = true,
	name_overlap = true }

lab.problems_seen = lab.problems_seen or {}

--- @return string? why the row's detail is wrong
local function detail_wrong(row)
	local detail = row.detail
	local text = serpent.line(detail, { comment = false })
	if WORLD[row.check] then
		if key_of(detail) == "cybersyn-gui.problems-world-" .. tostring(row.message) then return nil end
		return "world key"
	end
	local key = key_of(detail)
	if string.sub(key, 1, #("cybersyn-diag.lint-detail-" .. dash(row.check))) ~= "cybersyn-diag.lint-detail-" .. dash(row.check) then
		return "key " .. key
	end
	-- PLAN4 D10: a counter leak shows the deliveries no train serves, a bound train its id and the counted ones.
	if row.check == "phantom" then
		local leak = key_of(detail) == "cybersyn-diag.lint-detail-phantom-leak"
		local s = leak and number(row.a - row.b) or number(row.a)
		if not string.find(text, '"' .. s .. '"', 1, true) then return "phantom " .. s .. " not in " .. text end
		if row.train and not string.find(text, '"' .. row.train .. '"', 1, true) then return "phantom train" end
	end
	if row.check == "occupancy" and row.train and not string.find(text, '"' .. row.train .. '"', 1, true) then
		return "occupancy train"
	end
	local want = NUMBERS[row.check] or {}
	for _, field in ipairs({ "a", "b" }) do
		local how, v = want[field], row[field]
		local skip = (row.check == "mask" and row.a == 0) or (row.check == "depot_limit" and row.a < 0)
			or (row.check == "same_item" and row.a == 0)
		if how and v and not skip then
			local s = how == "n" and number(v) or tostring(v)
			if not string.find(text, '"' .. s .. '"', 1, true) then return field .. " " .. s .. " not in " .. text end
		end
	end
	if row.item and row.check ~= "layout" then
		local name = string.match(row.item, "^[^|]+")
		if not string.find(text, name, 1, true) then return "item " .. row.item end
	end
	if row.network and (row.check == "layout" or row.check == "no_provider" or row.check == "refueler_mask"
		or row.check == "train_mask" or row.check == "no_train" or row.check == "never_refuelled") then
		if not string.find(text, row.network, 1, true) then return "network " .. row.network end
	end
	return nil
end

--- Every finding of the last lint pass and the setup registry is exactly one row of the tab's model, with its check's
--- caption, chip and fix line and the finding's numbers in the detail. With `collect` (inside a tick handler, where
--- nothing can be printed) the results are appended to it as {name, ok, detail} for the caller to check later.
function lab.problems_verify(label, collect)
	local check = collect and function(name, ok, detail) collect[#collect + 1] = { name, ok and true or false, detail } end
		or lab.check
	local d = dev("problems_dump", pi, true)
	local want = {}
	local n = 0
	local function id_of(f)
		return f.check .. "|" .. f.subject .. "|" .. f.id .. "|" .. tostring(f.item or f.message or "")
	end
	for _, f in ipairs(dev("lint_findings")) do
		want[id_of(f)] = (want[id_of(f)] or 0) + 1
		n = n + 1
	end
	local rows, wrong = {}, {}
	for _, row in ipairs(d.all) do
		rows[id_of(row)] = (rows[id_of(row)] or 0) + 1
		local why = detail_wrong(row)
		if why then wrong[#wrong + 1] = row.check .. " " .. row.id .. ": " .. why end
		if key_of(row.fix) ~= "cybersyn-diag.lint-fix-" .. dash(row.check) then wrong[#wrong + 1] = row.check .. " fix" end
		if key_of(row.chip) ~= "cybersyn-diag.lint-chip-" .. dash(row.check) then wrong[#wrong + 1] = row.check .. " chip" end
		if not why then lab.problems_seen[row.check] = true end
	end
	local missing = {}
	for id, c in pairs(want) do
		if rows[id] ~= c then missing[#missing + 1] = id end
	end
	check(label .. ": one model row per finding (lint pass and registry)", #d.all == n and #missing == 0,
		{ rows = #d.all, findings = n, missing = missing })
	check(label .. ": every row has its check's chip, fix line and detail numbers", #wrong == 0, wrong)
	return d
end

--- Every check has produced a correct row somewhere in the run (called by the last suite).
function lab.problems_coverage()
	local missing = {}
	for _, name in ipairs({ "capacity", "layout", "mask", "no_provider", "limit_zero", "same_item", "occupancy",
		"phantom", "depot_limit", "depot_shared_name", "refueler_mask", "never_refuelled", "in_group", "missing_stop",
		"capacity_drift", "derelict_comb", "ghost_comb", "no_comb", "wrong_side", "double_comb", "priority",
		"name_overlap", "train_mask", "no_train" }) do
		if not lab.problems_seen[name] then missing[#missing + 1] = name end
	end
	lab.check("Problems tab: every one of the 24 checks produced a correct row in this run", #missing == 0, missing)
end

local function problems()
	remote.call(D, "select_tab", pi, "problems")
	remote.call(D, "update", pi, 1)
	return dev("problems_dump", pi)
end

local function stations_with_lint()
	local n = 0
	for _, st in pairs(lab.read("manager").snapshot.stations) do
		if (st.lint or 0) ~= 0 then n = n + 1 end
	end
	return n
end

--- The first finding row on the page.
local function first_row(d)
	for i, line in ipairs(d.lines) do
		if line.kind == "row" then return line, i end
	end
	return nil
end

local function comb_at(case, stop_entity, dx, dy, dir, mode, ghost)
	local s = case.surface
	local pos = { stop_entity.position.x + dx, stop_entity.position.y + dy }
	local e
	if ghost then
		e = s.create_entity({ name = "entity-ghost", inner_name = "cybersyn-combinator", position = pos,
			direction = defines.direction[dir], force = game.forces.player, raise_built = true })
	else
		e = s.create_entity({ name = "cybersyn-combinator", position = pos, direction = defines.direction[dir],
			force = game.forces.player })
		local ctl = e.get_or_create_control_behavior()
		local params = ctl.parameters
		params.operation = mode
		params.first_signal = { type = "virtual", name = case.network }
		ctl.parameters = params
		script.raise_script_built({ entity = e })
	end
	case.entities[#case.entities + 1] = e
	return e
end

local function bare_stop(case, x, name)
	local stop = case.surface.create_entity({ name = "train-stop", position = { x, case.y - 1 },
		direction = defines.direction.west, force = game.forces.player, raise_built = true })
	stop.backer_name = name
	case.entities[#case.entities + 1] = stop
	return stop
end

local pr = {}
lab.pr = pr

lab.suite("37_problems", {
	-- Shown even while the lint job has no result (a fresh save, or a manager never opened): the progress of the
	-- running pass instead of rows, no badge, and the selection stays (phase 7: a tab whose visibility flips while the
	-- window opens was drawn in the Overview's place for one frame).
	function()
		pr.planner = settings.global["cybersyn-enable-planner"].value
		lab.dev("set_setting", "cybersyn-enable-planner", false)
		remote.call(D, "open", pi)
		lab.big_screen(pi)
		dev("lint_run")
		local d = problems()
		lab.check("visible once a lint pass completed", d.visible == true and d.has_result == true, d.visible)
		remote.call("cybersyn", "write_global", nil, "manager", "lint")
		remote.call(D, "select_tab", pi, "problems")
		local st = dev("state", pi)
		d = dev("problems_dump", pi)
		lab.check("still shown without a lint result (a save whose manager never ran the lint job)", d.visible == true
			and d.has_result == false and d.badge == "", { visible = d.visible, badge = d.badge })
		lab.check("without a result the tab shows the pass progress, no rows",
			type(d.empty) == "table" and (d.empty[1] == "cybersyn-gui.problems-pending"
				or d.empty[1] == "cybersyn-gui.problems-pending-progress") and #d.rendered == 0, d.empty)
		lab.check("a selected Problems tab stays selected without a result", st.selected_tab == "problems_tab",
			st.selected_tab)
		-- Back: the next pass shows the tab again.
		dev("lint_run")
		d = problems()
		lab.check("shown again after the next pass, without errors", d.visible == true and d.pass == 1, d.pass)
	end,

	-- One number per fact, the badge, grouping, every finding's row, whole rows.
	function()
		local d = problems()
		lab.problems_verify("37 layout-dev")
		local snap_n = stations_with_lint()
		lab.check("station subjects in the tab == stations with st.lint ~= 0 == the Overview's misconfigured line",
			d.station_subjects == snap_n and snap_n > 0, { tab = d.station_subjects, st_lint = snap_n })
		local ov = dev("dump", pi, "overview")
		lab.check("the Overview's misconfigured line reads the same pass",
			ov.tiles.failing and ov.tiles.failing.misconfigured == d.station_subjects,
			{ tile = ov.tiles.failing and ov.tiles.failing.misconfigured, tab = d.station_subjects })
		remote.call(D, "select_tab", pi, "problems")
		local findings = dev("lint_findings")
		local errors = 0
		for _, f in ipairs(findings) do
			if f.check == "capacity" or f.check == "layout" or f.check == "mask" or f.check == "train_mask" or
				f.check == "no_train" or f.check == "no_provider" or f.check == "phantom" then
				errors = errors + 1
			end
		end
		lab.check("badge == findings at error severity, none acknowledged", d.badge == tostring(errors)
			and d.counts.badge == errors and d.counts.error == errors, { badge = d.badge, errors = errors })
		lab.check("tab total == the pass's findings", d.counts.total == #findings, { total = d.counts.total, n = #findings })
		local sev_rank = { error = 1, warning = 2, info = 3 }
		local ordered = true
		for i = 2, #d.groups do
			if sev_rank[d.groups[i].sev] < sev_rank[d.groups[i - 1].sev] then ordered = false end
		end
		lab.check("groups ordered errors first", ordered, d.groups)
		-- Whole rows on the one page this 8K screen gives: group row first, then its findings, as rendered.
		local same = #d.rendered == #d.lines
		for i, line in ipairs(d.lines) do
			local r = d.rendered[i]
			if not r or r.kind ~= line.kind then
				same = false
			elseif line.kind == "row" then
				if r.key ~= line.key or serpent.line(r.detail) ~= serpent.line(line.detail) or r.fix_style ~= "cybersyn_problems_fix"
					or serpent.line(r.fix) ~= serpent.line(line.fix) then
					same = false
				end
			end
		end
		lab.check("rendered rows == the model's page, in order (group rows, details, grey fix lines)", same,
			{ lines = #d.lines, rendered = #d.rendered })
		lab.check("the page starts with a group row", d.lines[1] and d.lines[1].kind == "group")
		local r = dev("rows", pi, "problems")
		lab.check("one page: rendered rows == model lines (groups + findings)", r.rendered == #d.lines
			and #d.lines == #d.groups + d.counts.total and d.page.pages == 1, { r = r, lines = #d.lines })
		local chip = d.rendered[2]
		lab.check("finding rows: red chip for an error, the check's chip caption, a link to the station",
			chip and chip.chip_style == "cybersyn_chip_red" and key_of(chip.chip) == "cybersyn-diag.lint-chip-capacity"
			and chip.subject_kind == "station" and chip.dot == "flib_indicator_red", chip)
		-- Dump twice with a render in between: nothing moves.
		local a = serpent.line(dev("problems_dump", pi), { comment = false })
		remote.call(D, "update", pi, 1)
		local b = serpent.line(dev("problems_dump", pi), { comment = false })
		lab.check("dump identical across a render (sig-guarded)", a == b)
		local t0 = game.create_profiler()
		remote.call(D, "update", pi, 5)
		t0.stop()
		lab.info({ "", "problems update x5 on layout-dev: ", t0 })
	end,

	-- Rows are a pool of slots: a page flip rebinds them instead of creating elements, a link cell resolves its target
	-- through its slot, and a never-refuelled row does not change while its tracked time grows within the hour.
	function()
		remote.call(D, "set_layout", pi, 3840, 2160, 1.5)
		local function pool()
			return lab.read("manager", "players", pi, "gui_state", "problems_rows")
		end
		-- From an empty pool while another tab shows: slots are created, then the page bound, a few per render.
		remote.call(D, "select_tab", pi, "overview")
		remote.call("cybersyn", "write_global", nil, "manager", "players", pi, "gui_state", "problems_rows")
		local steps, r = 0, nil
		repeat
			steps = steps + 1
			r = dev("problems_pool_step", pi)
		until r.done or steps >= 20
		local bound = serpent.line(pool().slots, { comment = false })
		local d = problems()
		lab.check("while another tab shows, the pool fills and binds the page a few slots per render; the first show writes nothing",
			r.done == true and steps > 2 and r.bound == #d.lines and serpent.line(pool().slots, { comment = false }) == bound,
			{ steps = steps, r = r, lines = #d.lines })
		local p0 = pool()
		lab.check("the slot pool covers the page before the tab is first shown", #p0.slots >= d.rows,
			{ slots = #p0.slots, rows = d.rows })
		local n0 = #p0.slots
		local flips_ok = d.page.pages > 1
		for _, page in ipairs({ 2, 1, 2, 1 }) do
			remote.call(D, "set_page", pi, "problems", page)
			local p = dev("problems_dump", pi)
			local same = #p.rendered == #p.lines
			for i, line in ipairs(p.lines) do
				local r = p.rendered[i]
				if not r or r.kind ~= line.kind or (line.kind == "row" and r.key ~= line.key) then same = false end
			end
			if not same or #pool().slots ~= n0 then flips_ok = false end
		end
		lab.check("page flips rebind the pooled slots: no slot created, rendered rows == the page", flips_ok,
			{ slots = #pool().slots, before = n0 })
		-- While the cursor rests on a row the slots keep their lines; the page follows once the hold ends.
		local keys1 = {}
		for i, r in ipairs(dev("problems_dump", pi).rendered) do keys1[i] = r.key end
		remote.call("cybersyn", "write_global", { tick = game.tick, scope = "problems_rows", index = 0 }, "manager",
			"players", pi, "hover")
		remote.call(D, "set_page", pi, "problems", 2)
		local held = dev("problems_dump", pi)
		local kept = #held.rendered == #keys1
		for i, r in ipairs(held.rendered) do
			if r.key ~= keys1[i] then kept = false end
		end
		remote.call("cybersyn", "write_global", nil, "manager", "players", pi, "hover")
		remote.call(D, "update", pi, 1)
		local released = dev("problems_dump", pi)
		local follows = #released.rendered == #released.lines
		for i, line in ipairs(released.lines) do
			if not released.rendered[i] or released.rendered[i].key ~= (line.key or released.rendered[i].key) then
				follows = false
			end
		end
		lab.check("hover hold: the rows stay while held, then show the new page", kept and follows
			and released.page.page == 2 and released.rendered[1].key ~= keys1[1],
			{ kept = kept, follows = follows, page = released.page.page })
		remote.call(D, "set_page", pi, "problems", 1)

		d = dev("problems_dump", pi)
		local row, index = first_row(d)
		local station = row and lab.read("stations", row.id)
		local res = dev("click", pi, "problems_rows", { index, 3, 2 }, { shift = true })
		local p = game.get_player(pi)
		local via_row = p.controller_type == defines.controllers.remote and p.position or nil
		if via_row then p.exit_remote_view() end
		-- The same station's link through its tags: the view lands on the same spot (offset clear of the window).
		dev("link_click", pi, "station", row and row.id or 0, { shift = true })
		local via_tags = p.controller_type == defines.controllers.remote and p.position or nil
		if via_tags then p.exit_remote_view() end
		lab.check("shift-click on a row's subject shows that row's station on the map", res == true and via_row ~= nil
			and via_tags ~= nil and via_row.x == via_tags.x and via_row.y == via_tags.y and station ~= nil,
			{ res = res, id = row and row.id, row = via_row, tags = via_tags })

		-- A never-refuelled finding on the page whose tracked time grows by half an hour between passes.
		lab.big_screen(pi)
		local s = lab.read("manager", "lint")
		local train_id = next(lab.read("trains"))
		-- LINT_NEVER_REFUELLED and LINT_SUBJECT_TRAIN (constants.lua; level scope cannot see them).
		local NEVER = 12
		local function inject(a, pass)
			local list = { { check = NEVER, subject = 4, id = train_id, a = a, b = 0, network = "signal-A" } }
			for k, f in ipairs(s.findings) do list[k + 1] = f end
			remote.call("cybersyn", "write_global", list, "manager", "lint", "findings")
			remote.call("cybersyn", "write_global", pass, "manager", "lint", "pass")
			remote.call(D, "update", pi, 1)
		end
		local function slot_of(key)
			for i, slot in ipairs(pool().slots) do
				if slot.key == key then return slot, i end
			end
		end
		inject(3 * HOUR + 60, s.pass + 1000)
		local key = NEVER .. ":4:" .. train_id .. ":"
		local before, i1 = slot_of(key)
		inject(3 * HOUR + HOUR / 2, s.pass + 1001)
		local after, i2 = slot_of(key)
		local shown = dev("problems_dump", pi).rendered[i2 or 0]
		lab.check("a never-refuelled row keeps its slot and content while the tracked time grows within the hour",
			before ~= nil and after ~= nil and i1 == i2 and before.sig == after.sig and shown
			and serpent.line(shown.detail):find("3h 00m", 1, true) ~= nil,
			{ before = before and before.sig, after = after and after.sig, detail = shown and shown.detail })

		-- A train's lint acknowledgement is written to the train column of its events (keyed by the negated id).
		local seq = dev("diag_state").seq
		dev("diag_ack", "lint", -train_id, NEVER, 600, pi)
		local ev
		for _, e in ipairs(dev("diag_events", seq, 1000)) do
			if e.seq > seq and e.kind == "acknowledged" then ev = e end
		end
		lab.check("a train's lint acknowledgement event names the train, not a station", ev ~= nil
			and ev.train == train_id and ev.station == 0, ev)
		dev("diag_unack", "lint", -train_id, NEVER, pi)
		dev("lint_run")

		-- Acknowledgements made or ended outside the tab (diag's own calls) reach the badge without a new pass.
		local d1 = problems()
		local r1 = first_row(d1)
		local badge = d1.counts.badge
		-- LINT_CAPACITY
		dev("diag_ack", "lint", r1.ack_key, 1, 600, pi)
		remote.call(D, "update", pi, 1)
		local d2 = dev("problems_dump", pi)
		dev("diag_unack", "lint", r1.ack_key, 1, pi)
		remote.call(D, "update", pi, 1)
		local d3 = dev("problems_dump", pi)
		lab.check("an acknowledgement made and ended outside the tab moves its badge without a new pass",
			r1.check == "capacity" and d2.pass == d1.pass and d2.counts.badge == badge - 1 and d3.counts.badge == badge,
			{ check = r1.check, badge = badge, acked = d2.counts.badge, ended = d3.counts.badge })
		remote.call(D, "update", pi, 1)
	end,

	-- Rows computed == rows rendered on the four screens of 36_window; pages split into whole rows.
	function()
		for _, screen in ipairs({ { "4K at 1.5", 3840, 2160, 1.5 }, { "1080p at 1.0", 1920, 1080, 1.0 },
			{ "1080p at 1.25", 1920, 1080, 1.25 }, { "4K at 2.0", 3840, 2160, 2.0 } }) do
			remote.call(D, "set_layout", pi, screen[2], screen[3], screen[4])
			local d = problems()
			local r = dev("rows", pi, "problems")
			local total = #d.groups + d.counts.total
			local ok = r.rendered == #d.lines and #d.lines <= r.computed and r.computed >= 3
				and (d.page.pages == 1 and #d.lines == total or #d.lines >= r.computed - 1)
			lab.check(screen[1] .. ": Problems rows rendered fill the rows computed (whole rows, no scroll pane)", ok,
				{ r = r, lines = #d.lines, pages = d.page.pages })
			if d.page.pages > 1 then
				local all_ok, seen = true, 0
				for page = 1, d.page.pages do
					remote.call(D, "set_page", pi, "problems", page)
					local p = problems()
					if #p.lines > r.computed or p.lines[1].kind ~= "group" or p.lines[#p.lines].kind ~= "row" then
						all_ok = false
					end
					for _, line in ipairs(p.lines) do
						if line.kind == "row" then seen = seen + 1 end
					end
				end
				lab.check(screen[1] .. ": every page starts with a group row, never ends with one, and the pages hold every finding",
					all_ok and seen == d.counts.total, { pages = d.page.pages, seen = seen, total = d.counts.total })
				remote.call(D, "set_page", pi, "problems", 1)
			end
		end
		lab.big_screen(pi)
	end,

	-- Severity filter, then acknowledge: moves to the bottom greyed, leaves the badge, expires.
	function()
		local d = dev("problems_set_filter", pi, { sev = { warning = false, info = false } })
		local only_errors = true
		for _, line in ipairs(d.lines) do
			if line.kind == "row" and line.sev ~= "error" then only_errors = false end
		end
		lab.check("severity filter: only errors shown, counts unchanged", only_errors and d.counts.warning > 0
			and d.filter.warning == false, d.counts)
		dev("problems_set_filter", pi, { sev = { warning = true, info = true } })
		d = problems()
		local row, index = first_row(d)
		pr.row = row
		local badge = d.counts.badge
		local res = dev("click", pi, "problems_rows", { index, 6 })
		lab.check("ack button dispatches", res == true, res)
		local stored = lab.read("acks").lint[row.ack_key]
		local a
		for _, v in pairs(stored or {}) do a = v end
		lab.check("a plain click acknowledges (subject, check) for 24 h", a ~= nil and a.until_tick == game.tick + DAY
			and a.player_index == pi, a)
		d = problems()
		local still = false
		for _, line in ipairs(d.lines) do
			if line.kind == "row" and line.key == row.key then still = true end
		end
		lab.check("the acknowledged row leaves the open rows and the badge", not still and d.counts.badge == badge - 1
			and d.badge == tostring(badge - 1) and d.counts.acked == 1, { badge = d.counts.badge, before = badge })
		local group = d.lines[1]
		lab.check("its group row counts the hidden acknowledged one", group.kind == "group" and group.hidden_acked == 1,
			group)
		d = dev("problems_set_filter", pi, { acked = true })
		local last
		for _, line in ipairs(d.lines) do
			if line.kind == "row" and line.check == row.check then last = line end
		end
		local rendered
		for _, r in ipairs(d.rendered) do
			if r.key == row.key then rendered = r end
		end
		lab.check("with Show acknowledged on: greyed at the bottom of its group", last and last.key == row.key
			and last.acked == true and rendered and rendered.chip_style == "cybersyn_chip_acked" and rendered.acked == true
			and rendered.dot == "flib_indicator_white", { last = last and last.key, rendered = rendered })
		pr.shot_state = true
		-- Expiry: an acknowledgement whose time runs out puts the row back without a new lint pass.
		dev("problems_ack", pi, row.ack_key, row.check, false)
		dev("problems_ack", pi, row.ack_key, row.check, 60)
		pr.expiry_row, pr.badge = row, badge
		d = problems()
		lab.check("a 60-tick acknowledgement holds at first", d.counts.badge == badge - 1, d.counts)
		lab.wait(90, 1)
	end,

	function()
		local row, badge = pr.expiry_row, pr.badge
		local d = problems()
		local still = false
		for _, line in ipairs(d.lines) do
			if line.kind == "row" and line.key == row.key and not line.acked then still = true end
		end
		lab.check("an expired acknowledgement puts the row back", still and d.counts.badge == badge, d.counts)
		-- Shift = 1 h, control = until the finding clears.
		local index, a
		row, index = first_row(d)
		dev("click", pi, "problems_rows", { index, 6 }, { shift = true })
		for _, v in pairs(lab.read("acks").lint[row.ack_key] or {}) do a = v end
		lab.check("shift-click acknowledges for 1 h", a and a.until_tick == game.tick + HOUR, a)
		-- Show acknowledged is still on: the row is now at the bottom of its group.
		d = problems()
		for i, line in ipairs(d.lines) do
			if line.key == row.key then index = i end
		end
		lab.check("the shift-acknowledged row is listed greyed", d.lines[index].acked == true, d.lines[index])
		dev("click", pi, "problems_rows", { index, 6 })
		lab.check("a click on an acknowledged row ends it", lab.read("acks").lint[row.ack_key] == nil)
		d = problems()
		row, index = first_row(d)
		dev("click", pi, "problems_rows", { index, 6 }, { control = true })
		local stored2 = lab.read("acks").lint[row.ack_key]
		a = nil
		for _, v in pairs(stored2 or {}) do a = v end
		lab.check("ctrl-click acknowledges until the finding clears", a ~= nil and a.until_tick == nil, a)
		-- The finding clears with the next pass: a depot limit set to 1.
		local depot
		for _, f in ipairs(dev("lint_findings")) do
			if f.check == "depot_limit" and not depot then depot = f.id end
		end
		pr.depot = depot
		dev("problems_ack", pi, depot, "depot_limit", nil)
		local stop = lab.read("depots", depot, "entity_stop")
		pr.depot_limit = stop.trains_limit
		stop.trains_limit = 1
		dev("lint_run")
		lab.check("an until-cleared acknowledgement ends when its finding clears",
			not dev("diag_is_acked", "lint", depot, 9), lab.read("acks").lint[depot])
		stop.trains_limit = pr.depot_limit
		dev("lint_run")
		dev("problems_ack", pi, row.ack_key, row.check, false)
		dev("problems_set_filter", pi, { acked = false })
	end,

	-- The setup registry (PLAN4 D8; the world scan and its button are gone): derelict, ghost and wrong-side
	-- combinators built on a row of their own are rows of the tab at once.
	function()
		local w = cases.base("PROBLEMS_W", { k = ROW_K }, { network = "signal-9", no_train = true })
		cases.finish(w)
		pr.w = w
		pr.derelict = comb_at(w, w.d1.stop, -200, -2.5, "north", "/")
		local ghost_stop = bare_stop(w, 160, "rc-PROBLEMS_W-ghost")
		pr.ghost_stop = ghost_stop
		comb_at(w, ghost_stop, 1.5, -2.5, "north", "/", true)
		local wrong_stop = bare_stop(w, 130, "rc-PROBLEMS_W-wrong")
		pr.wrong_stop = wrong_stop
		pr.wrong = comb_at(w, wrong_stop, 1.5, -2.5, "east", "/")
		remote.call(D, "update", pi, 1)
		local d = lab.problems_verify("37 registry")
		local found = {}
		for _, row in ipairs(d.all) do found[row.check .. ":" .. row.id] = row end
		lab.check("the registry lists the derelict combinator", found["derelict_comb:" .. pr.derelict.unit_number] ~= nil)
		lab.check("the registry lists the ghost at the unregistered stop", found["ghost_comb:" .. pr.ghost_stop.unit_number] ~= nil)
		lab.check("the registry lists the combinator facing away", found["wrong_side:" .. pr.wrong.unit_number] ~= nil)
		-- A registry finding's link opens the entity; shift shows it on the map.
		local link = dev("link_click", pi, "entity", pr.derelict.unit_number, { shift = true })
		lab.check("an unregistered combinator's link shows it on the map", link.markers ~= nil and #link.markers == 2
			and link.controller == defines.controllers.remote, link)
		local p = game.get_player(pi)
		if p.controller_type == defines.controllers.remote then p.exit_remote_view() end
		local ok, err = pcall(pr.w.cleanup)
		if not ok then lab.check("cleanup", false, err) end
		dev("lint_run")
		remote.call(D, "update", pi, 1)
		lab.dev("set_setting", "cybersyn-enable-planner", pr.planner)
		remote.call(D, "close", pi)
	end,
})
