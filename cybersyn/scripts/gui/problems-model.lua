-- Texts of the setup lint's findings (PLAN3 §4.12; PLAN4 D7 folded the Problems tab into the Stations Problems
-- column): the order a station's findings are shown in, the sort rank of a station's lint mask, and the captions,
-- chips, fix lines and detail numbers of a finding. Pure: plain tables in, plain tables and LocalisedStrings out, so the
-- host unit tests cover it without the engine.

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

-- A check's place in the worst-first order: severity first, then the check index.
local RANK_STEP = 64

--- @param check int
--- @return int
function model.rank(check)
	return (LINT_SEVERITY[check] or DIAG_SEV_WARNING) * RANK_STEP + check
end

--- The rank of the worst check in a station's lint mask (the Problems column's sort key), nil when the mask is clean.
--- @param mask int?
--- @return int?
function model.mask_rank(mask)
	if not mask or mask == 0 then return nil end
	local best
	for check = 1, LINT_COUNT do
		if bit32.btest(mask, LINT_BIT[check]) then
			local r = model.rank(check)
			if not best or r < best then best = r end
		end
	end
	return best
end

--- @class ProblemEntry
--- @field f LintFinding
--- @field sev int DIAG_SEV_*
--- @field ack DiagAck? the acknowledgement while it holds

--- A station's findings in the order its cell shows them: not acknowledged first, then worst severity, check, what
--- the finding is about and the subject id, so the first entry is the one the cell spells out.
--- @param list LintFinding[]
--- @param is_acked fun(f: LintFinding): DiagAck?
--- @return ProblemEntry[]
function model.order(list, is_acked)
	local out = {}
	for i, f in ipairs(list) do
		out[i] = { f = f, sev = LINT_SEVERITY[f.check] or DIAG_SEV_WARNING, ack = is_acked(f) }
	end
	table.sort(out, function(a, b)
		local aa, ba = a.ack ~= nil, b.ack ~= nil
		if aa ~= ba then return ba end
		if a.sev ~= b.sev then return a.sev < b.sev end
		local fa, fb = a.f, b.f
		if fa.check ~= fb.check then return fa.check < fb.check end
		local ka, kb = tostring(fa.item or fa.message or ""), tostring(fb.item or fb.message or "")
		if ka ~= kb then return ka < kb end
		if fa.subject ~= fb.subject then return fa.subject < fb.subject end
		return fa.id < fb.id
	end)
	return out
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

--- The fix line: what to change, without the numbers (they are in the detail column).
--- @param check int
--- @return LocalisedString
function model.fix(check)
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
		if a == 0 then return { key .. "-zero", env.network(f.network) } end
		return { key, tostring(a), tostring(b), env.item(f.item) }
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
	return tostring(a) .. ":" .. tostring(f.b) .. ":" .. tostring(f.network) .. ":" .. tostring(f.item) .. ":" .. tostring(f.c)
end

return model
