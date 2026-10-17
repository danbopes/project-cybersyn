-- The Problems tab's model (PLAN3 §4.7, §4.12, §4.13): the lint findings grouped by check, acknowledged ones sunk to
-- the bottom of their group, split into pages of whole rows where every page starts with a group row, and the
-- captions of a finding's cells. Pure: plain tables in, plain tables and LocalisedStrings out, so the host unit tests
-- cover it without the engine.

local format = require("__flib__.format")

local model = {}

model.CHIP_STYLE = {
	[DIAG_SEV_ERROR] = "cybersyn_chip_red",
	[DIAG_SEV_WARNING] = "cybersyn_chip_orange",
	[DIAG_SEV_INFO] = "cybersyn_chip_grey",
}
model.DOT = {
	[DIAG_SEV_ERROR] = "flib_indicator_red",
	[DIAG_SEV_WARNING] = "flib_indicator_orange",
	[DIAG_SEV_INFO] = "flib_indicator_cyan",
}
model.ACKED_DOT = "flib_indicator_white"

--- @class ProblemRow
--- @field f LintFinding
--- @field key string row identity: check, subject, id and what the finding is about
--- @field ack_key int lint.subject_key of the subject (storage.acks.lint)
--- @field check int
--- @field sev int DIAG_SEV_*
--- @field ack DiagAck? the acknowledgement while it holds

--- @class ProblemGroup
--- @field check int
--- @field sev int
--- @field open ProblemRow[]
--- @field acked ProblemRow[]

--- @class ProblemsModel
--- @field groups ProblemGroup[] errors first, then by check
--- @field open {[int]: int} findings not acknowledged, per severity
--- @field acked int
--- @field total int
--- @field badge int errors not acknowledged
--- @field next_expiry uint? the earliest until_tick among the acknowledgements shown
--- @field station_subjects int distinct stations with a setup finding (the Overview's misconfigured count)

--- @param f LintFinding
--- @return string
function model.row_key(f)
	return f.check .. ":" .. f.subject .. ":" .. f.id .. ":" .. (f.item or f.message or "")
end

--- @param a ProblemRow
--- @param b ProblemRow
local function row_before(a, b)
	local fa, fb = a.f, b.f
	if fa.subject ~= fb.subject then return fa.subject < fb.subject end
	if fa.id ~= fb.id then return fa.id < fb.id end
	return a.key < b.key
end

--- Groups the findings of every list by check.
--- @param lists LintFinding[][] the setup pass's findings, then the world scan's
--- @param subject_key fun(subject: int, id: uint): int lint.subject_key
--- @param is_acked fun(key: int, check: int): DiagAck?
--- @return ProblemsModel
function model.build(lists, subject_key, is_acked)
	local by_check = {}
	local groups = {}
	local open = { [DIAG_SEV_ERROR] = 0, [DIAG_SEV_WARNING] = 0, [DIAG_SEV_INFO] = 0 }
	local acked, total = 0, 0
	local next_expiry
	local stations = {}
	local station_subjects = 0
	for _, list in ipairs(lists) do
		for _, f in ipairs(list) do
			local check = f.check
			local sev = LINT_SEVERITY[check] or DIAG_SEV_WARNING
			local g = by_check[check]
			if not g then
				g = { check = check, sev = sev, open = {}, acked = {} }
				by_check[check] = g
				groups[#groups + 1] = g
			end
			local ack_key = subject_key(f.subject, f.id)
			local ack = is_acked(ack_key, check)
			local row = { f = f, key = model.row_key(f), ack_key = ack_key, check = check, sev = sev, ack = ack }
			total = total + 1
			if ack then
				g.acked[#g.acked + 1] = row
				acked = acked + 1
				local until_tick = ack.until_tick
				if until_tick and (not next_expiry or until_tick < next_expiry) then next_expiry = until_tick end
			else
				g.open[#g.open + 1] = row
				open[sev] = open[sev] + 1
			end
			if f.subject == LINT_SUBJECT_STATION and not stations[f.id] then
				stations[f.id] = true
				station_subjects = station_subjects + 1
			end
		end
	end
	table.sort(groups, function(a, b)
		if a.sev ~= b.sev then return a.sev < b.sev end
		return a.check < b.check
	end)
	for _, g in ipairs(groups) do
		table.sort(g.open, row_before)
		table.sort(g.acked, row_before)
	end
	return {
		groups = groups,
		open = open,
		acked = acked,
		total = total,
		badge = open[DIAG_SEV_ERROR],
		next_expiry = next_expiry,
		station_subjects = station_subjects,
	}
end

--- @class ProblemsFilter
--- @field sev {[int]: boolean} severities shown (missing = shown)
--- @field acked boolean? acknowledged findings shown (greyed, below the others of their group)

--- @class ProblemsLine
--- @field kind "group"|"row"
--- @field group ProblemGroup
--- @field cont boolean? a group row that continues its group from the previous page
--- @field shown int? group rows: findings of the group the filter shows
--- @field hidden_acked int? group rows: acknowledged findings of the group the filter hides
--- @field row ProblemRow?
--- @field acked boolean? finding rows

--- @class ProblemsPage
--- @field lines ProblemsLine[]
--- @field page int
--- @field pages int
--- @field first int index of the page's first finding among those shown (0 when none)
--- @field last int
--- @field shown int findings the filter shows

--- @param g ProblemGroup
--- @param filter ProblemsFilter
--- @return int open
--- @return int acked shown
local function visible(g, filter)
	if filter.sev and filter.sev[g.sev] == false then return 0, 0 end
	return #g.open, filter.acked and #g.acked or 0
end

--- Splits the shown findings into pages of `rows` whole rows. Every page starts with a group row (repeated, marked
--- continued, when a group runs over a page break) and a group row is never the last row of a page, so the row
--- arithmetic of the window holds on every page.
--- @param m ProblemsModel
--- @param filter ProblemsFilter
--- @param rows int
--- @param page int? 1-based; clamped
--- @return ProblemsPage
function model.page(m, filter, rows, page)
	rows = math.max(rows or 2, 2)
	-- One pass over the groups' sizes places every page break; only the wanted page's lines are built.
	local breaks = {}
	local p, used, findings = 1, 0, 0
	local starts = { { group = 1, i = 1, before = 0 } }
	local groups = m.groups
	for gi, g in ipairs(groups) do
		local n_open, n_acked = visible(g, filter)
		local n = n_open + n_acked
		local i = 1
		while i <= n do
			if used + 2 > rows then
				p = p + 1
				used = 0
				starts[p] = { group = gi, i = i, before = findings }
			end
			used = used + 1
			local take = math.min(rows - used, n - i + 1)
			used = used + take
			findings = findings + take
			i = i + take
		end
	end
	local pages = p
	page = math.min(math.max(page or 1, 1), pages)
	local start = starts[page]
	local stop = starts[page + 1]
	local lines = {}
	local count = 0
	local gi, i = start.group, start.i
	while gi <= #groups and #lines < rows do
		if stop and gi == stop.group and i >= stop.i then break end
		local g = groups[gi]
		local n_open, n_acked = visible(g, filter)
		local n = n_open + n_acked
		if i <= n then
			lines[#lines + 1] = { kind = "group", group = g, cont = i > 1, shown = n,
				hidden_acked = filter.acked and 0 or #g.acked }
			while i <= n and #lines < rows do
				if stop and gi == stop.group and i >= stop.i then break end
				local acked = i > n_open
				local row = acked and g.acked[i - n_open] or g.open[i]
				lines[#lines + 1] = { kind = "row", group = g, row = row, acked = acked }
				count = count + 1
				i = i + 1
			end
		end
		if i > n then
			gi, i = gi + 1, 1
		end
	end
	return {
		lines = lines,
		page = page,
		pages = pages,
		first = count > 0 and start.before + 1 or 0,
		last = start.before + count,
		shown = findings,
	}
end

-- ---------------------------------------------------------------- captions

--- @param check int
--- @return LocalisedString
function model.caption(check)
	return { "cybersyn-diag.lint-" .. (LINT_KEYS[check] or "unknown") }
end

--- The chip's short caption (the group row carries the full one).
--- @param check int
--- @return LocalisedString
function model.chip(check)
	return { "cybersyn-diag.lint-chip-" .. (LINT_KEYS[check] or "unknown") }
end

--- The fix line: what to change, without the numbers (they are in the detail column). A finding that names its own
--- fix (a phantom delivery's counter leak) gets that one.
--- @param check int
--- @param f LintFinding?
--- @return LocalisedString
function model.fix(check, f)
	if f and f.fix then return { "cybersyn-diag.lint-fix-" .. f.fix } end
	return { "cybersyn-diag.lint-fix-" .. (LINT_KEYS[check] or "unknown") }
end

--- @class ProblemsEnv
--- @field item fun(hash: string?): string rich-text icon of an item or fluid hash ("" when none)
--- @field network fun(name: string?): string rich-text icon of a network signal
--- @field is_fluid fun(hash: string?): boolean
--- @field duration fun(ticks: number): string

local HOUR_TICKS = 216000

local function n(v)
	return format.number(v or 0)
end

--- The numbers behind a finding, for the detail column ("[item] needs 50 stacks · largest train 40").
--- @param f LintFinding
--- @param env ProblemsEnv
--- @return LocalisedString
function model.detail(f, env)
	local check, a, b = f.check, f.a or 0, f.b or 0
	local key = "cybersyn-diag.lint-detail-" .. (LINT_KEYS[check] or "unknown")
	if check == LINT_CAPACITY then
		if env.is_fluid(f.item) then
			return { key .. "-fluid", env.item(f.item), n(a), n(b) }
		end
		-- The threshold as typed, then the stacks the trains are measured in.
		if f.c then return { key .. "-threshold", env.item(f.item), n(f.c), n(a), n(b) } end
		return { key, env.item(f.item), n(a), n(b) }
	elseif check == LINT_LAYOUT then
		if f.item then return { key .. "-item", env.item(f.item), n(a), n(b), env.network(f.network) } end
		return { key, n(a), n(b), env.network(f.network) }
	elseif check == LINT_MASK then
		return { key .. "-zero", env.network(f.network) }
	elseif check == LINT_PHANTOM then
		if f.train then return { key .. "-train", tostring(f.train), { "cybersyn-diag.lint-train-status-" .. (f.status or 0) }, n(a) } end
		return { key .. "-leak", n(a - b) }
	elseif check == LINT_OCCUPANCY and f.train then
		return { key .. "-train", tostring(f.train), n(b), n(a) }
	elseif check == LINT_NO_PROVIDER then
		return { key, env.item(f.item), env.network(f.network) }
	elseif check == LINT_SAME_ITEM then
		if a == 0 then return { key .. "-static", env.item(f.item) } end
		return { key .. (b == 1 and "-in" or "-out"), env.item(f.item), n(a) }
	elseif check == LINT_DEPOT_LIMIT then
		if a < 0 then return { key .. "-none" } end
		return { key, n(a) }
	elseif check == LINT_REFUELER_MASK or check == LINT_TRAIN_MASK then
		return { key, tostring(a), tostring(b), env.network(f.network) }
	elseif check == LINT_NEVER_REFUELLED then
		-- Whole hours: the tracked time grows on every pass, and the row must not change with it.
		return { key, env.network(f.network), env.duration(a - a % HOUR_TICKS) }
	elseif check == LINT_NO_TRAIN then
		return { key, env.network(f.network) }
	elseif f.message then
		return { "cybersyn-gui.problems-world-" .. f.message }
	end
	-- limit_zero, occupancy, phantom, depot_shared_name, in_group, missing_stop, capacity_drift: two counts.
	return { key, n(a), n(b) }
end

--- A signature of model.detail's inputs, for the row sig.
--- @param f LintFinding
--- @return string
function model.detail_sig(f)
	local a = f.a
	if f.check == LINT_NEVER_REFUELLED and a then a = math.floor(a / HOUR_TICKS) end
	return tostring(a) .. ":" .. tostring(f.b) .. ":" .. tostring(f.network) .. ":" .. tostring(f.item) .. ":" .. tostring(f.c) ..
		":" .. tostring(f.train) .. ":" .. tostring(f.status)
end

return model
