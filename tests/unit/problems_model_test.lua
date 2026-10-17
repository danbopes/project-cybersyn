-- The Problems tab's model (scripts/gui/problems-model.lua): grouping by check, acknowledged rows at the bottom of
-- their group, the split into pages of whole rows that each start with a group row, and the detail per check.

local H = require("harness")

local function pm()
	return H.load("scripts.gui.problems-model")
end

local function key_of(subject, id)
	return subject == LINT_SUBJECT_TRAIN and -id or id
end

local function finding(check, subject, id, a, b, extra)
	local f = { check = check, subject = subject, id = id, a = a or 0, b = b or 0 }
	for k, v in pairs(extra or {}) do f[k] = v end
	return f
end

local S, D, T = LINT_SUBJECT_STATION, LINT_SUBJECT_DEPOT, LINT_SUBJECT_TRAIN

--- Five capacity findings (error), two depot limits (warning), one never-refuelled (info), one registry finding.
local function lists()
	local setup = {
		finding(LINT_DEPOT_LIMIT, D, 50, -1),
		finding(LINT_CAPACITY, S, 12, 50, 40, { item = "iron-plate", network = "signal-A" }),
		finding(LINT_CAPACITY, S, 10, 50, 40, { item = "iron-plate", network = "signal-A" }),
		finding(LINT_NEVER_REFUELLED, T, 7, 300000, 0, { network = "signal-A" }),
		finding(LINT_CAPACITY, S, 11, 60, 40, { item = "copper-plate", network = "signal-A" }),
		finding(LINT_DEPOT_LIMIT, D, 40, 3),
		finding(LINT_CAPACITY, S, 13, 70, 40, { item = "iron-plate", network = "signal-A" }),
		finding(LINT_CAPACITY, S, 14, 80, 40, { item = "iron-plate", network = "signal-A" }),
		finding(LINT_TRAIN_MASK, S, 10, 1, 2, { network = "signal-A" }),
	}
	local world = { { check = LINT_DERELICT_COMB, subject = LINT_SUBJECT_COMBINATOR, id = 900, message = "derelict-combinator" } }
	return { setup, world }
end

local function no_acks() return nil end

test("build: groups by check, errors first, rows by subject then id; counts per severity", function()
	local m = pm().build(lists(), key_of, no_acks)
	local order = {}
	for i, g in ipairs(m.groups) do order[i] = LINT_NAMES[g.check] .. ":" .. #g.open end
	assert_eq(order, { "capacity:5", "train_mask:1", "depot_limit:2", "derelict_comb:1", "never_refuelled:1" })
	local ids = {}
	for i, row in ipairs(m.groups[1].open) do ids[i] = row.f.id end
	assert_eq(ids, { 10, 11, 12, 13, 14 })
	assert_eq(m.open, { [DIAG_SEV_ERROR] = 6, [DIAG_SEV_WARNING] = 3, [DIAG_SEV_INFO] = 1 })
	assert_eq({ m.total, m.acked, m.badge }, { 10, 0, 6 })
	-- Station 10 has two findings: one station for the Overview's misconfigured count.
	assert_eq(m.station_subjects, 5)
	assert_eq(m.groups[5].open[1].ack_key, -7)
	assert_eq(m.groups[1].open[1].key, LINT_CAPACITY .. ":" .. S .. ":10:iron-plate")
end)

test("build: acknowledged findings sink to the bottom of their group and leave the badge", function()
	local acks = { [12] = { [LINT_CAPACITY] = { until_tick = 500 } }, [-7] = { [LINT_NEVER_REFUELLED] = { until_tick = 300 } } }
	local m = pm().build(lists(), key_of, function(key, check) return acks[key] and acks[key][check] end)
	local g = m.groups[1]
	assert_eq(#g.open, 4)
	assert_eq(#g.acked, 1)
	assert_eq(g.acked[1].f.id, 12)
	assert_eq({ m.badge, m.acked, m.open[DIAG_SEV_INFO] }, { 5, 2, 0 })
	assert_eq(m.next_expiry, 300)
end)

--- The page as strings: "G:check[:c]" for group rows, "check:id[:a]" for finding rows.
local function shape(pg)
	local out = {}
	for i, line in ipairs(pg.lines) do
		if line.kind == "group" then
			out[i] = "G:" .. LINT_NAMES[line.group.check] .. (line.cont and ":c" or "")
		else
			out[i] = LINT_NAMES[line.row.check] .. ":" .. line.row.f.id .. (line.acked and ":a" or "")
		end
	end
	return out
end

test("page: whole rows, every page starts with a group row, a group row never ends a page", function()
	local model = pm()
	local m = model.build(lists(), key_of, no_acks)
	local all = { sev = {} }
	-- 5 groups + 10 findings = 15 rows; at 6 rows a page: capacity 5 needs a continued header.
	local p1 = model.page(m, all, 6, 1)
	assert_eq(shape(p1), { "G:capacity", "capacity:10", "capacity:11", "capacity:12", "capacity:13", "capacity:14" })
	assert_eq({ p1.page, p1.pages, p1.first, p1.last, p1.shown }, { 1, 3, 1, 5, 10 })
	local p2 = model.page(m, all, 6, 2)
	-- train_mask (2 rows) and depot_limit (3 rows) fit; derelict would leave its group row last, so it moves on.
	assert_eq(shape(p2), { "G:train_mask", "train_mask:10", "G:depot_limit", "depot_limit:40", "depot_limit:50" })
	assert_eq({ p2.first, p2.last }, { 6, 8 })
	local p3 = model.page(m, all, 6, 3)
	assert_eq(shape(p3), { "G:derelict_comb", "derelict_comb:900", "G:never_refuelled", "never_refuelled:7" })
	assert_eq(p3.pages, 3)
	-- Out-of-range pages clamp.
	assert_eq(model.page(m, all, 6, 99).page, 3)
	assert_eq(model.page(m, all, 6, 0).page, 1)
	-- A group running over two page breaks repeats its row as continued.
	local p = model.page(m, all, 3, 2)
	assert_eq(shape(p), { "G:capacity:c", "capacity:12", "capacity:13" })
	for page = 1, p.pages do
		local lines = model.page(m, all, 3, page).lines
		assert_true(#lines <= 3)
		assert_eq(lines[1].kind, "group")
		assert_eq(lines[#lines].kind, "row")
	end
end)

test("page: severity and acknowledged filters; counts on the group row", function()
	local model = pm()
	local acks = { [12] = { [LINT_CAPACITY] = { until_tick = 500 } } }
	local m = model.build(lists(), key_of, function(key, check) return acks[key] and acks[key][check] end)
	local p = model.page(m, { sev = { [DIAG_SEV_WARNING] = false, [DIAG_SEV_INFO] = false } }, 20, 1)
	assert_eq(shape(p), { "G:capacity", "capacity:10", "capacity:11", "capacity:13", "capacity:14", "G:train_mask", "train_mask:10" })
	assert_eq({ p.lines[1].shown, p.lines[1].hidden_acked }, { 4, 1 })
	local shown = model.page(m, { sev = { [DIAG_SEV_WARNING] = false, [DIAG_SEV_INFO] = false }, acked = true }, 20, 1)
	assert_eq(shape(shown), { "G:capacity", "capacity:10", "capacity:11", "capacity:13", "capacity:14", "capacity:12:a",
		"G:train_mask", "train_mask:10" })
	assert_eq({ shown.lines[1].shown, shown.lines[1].hidden_acked }, { 5, 0 })
	-- Nothing to show: no lines, one page.
	local none = model.page(m, { sev = { false, false, false } }, 20, 1)
	assert_eq({ #none.lines, none.pages, none.first, none.last, none.shown }, { 0, 1, 0, 0, 0 })
	local empty = model.page(model.build({ {} }, key_of, no_acks), { sev = {} }, 20, 1)
	assert_eq({ #empty.lines, empty.pages }, { 0, 1 })
end)

local ENV = {
	item = function(hash) return hash and ("[item=" .. hash .. "]") or "" end,
	network = function(name) return "[virtual-signal=" .. tostring(name) .. "]" end,
	is_fluid = function(hash) return hash == "water" end,
	duration = function(ticks) return tostring(math.floor(ticks / 60)) .. "s" end,
}

test("detail sig: a never-refuelled row keeps its sig while the tracked time grows within the hour", function()
	local model = pm()
	local function sig(a) return model.detail_sig(finding(LINT_NEVER_REFUELLED, T, 7, a, 0, { network = "signal-A" })) end
	assert_eq(sig(216000 * 3 + 60), sig(216000 * 3 + 200000))
	assert_eq(sig(216000 * 3) ~= sig(216000 * 4), true)
	local function cap(a) return model.detail_sig(finding(LINT_CAPACITY, S, 1, a, 40, { item = "coal" })) end
	assert_eq(cap(50) ~= cap(51), true)
end)

test("detail: the numbers behind each check", function()
	local model = pm()
	local function d(check, a, b, extra) return model.detail(finding(check, S, 1, a, b, extra), ENV) end
	local K = "cybersyn-diag.lint-detail-"
	assert_eq(d(LINT_CAPACITY, 50, 40, { item = "iron-plate" }), { K .. "capacity", "[item=iron-plate]", "50", "40" })
	assert_eq(d(LINT_CAPACITY, 30000, 25000, { item = "water" }),
		{ K .. "capacity-fluid", "[item=water]", "30,000", "25,000" })
	assert_eq(d(LINT_CAPACITY, 50, 40, { item = "iron-plate", c = 5000 }),
		{ K .. "capacity-threshold", "[item=iron-plate]", "5,000", "50", "40" }, "the typed threshold first")
	assert_eq(d(LINT_LAYOUT, 1, 2, { network = "signal-A" }), { K .. "layout", "1", "2", "[virtual-signal=signal-A]" })
	assert_eq(d(LINT_LAYOUT, 1, 2, { network = "signal-A", item = "coal" }),
		{ K .. "layout-item", "[item=coal]", "1", "2", "[virtual-signal=signal-A]" }, "the capacity path names its item")
	assert_eq(d(LINT_MASK, 0, 6, { network = "signal-B" }), { K .. "mask-zero", "[virtual-signal=signal-B]" })
	assert_eq(d(LINT_NO_PROVIDER, 0, 0, { item = "coal", network = "signal-A" }),
		{ K .. "no-provider", "[item=coal]", "[virtual-signal=signal-A]" })
	assert_eq(d(LINT_LIMIT_ZERO, 0, 0), { K .. "limit-zero", "0", "0" })
	assert_eq(d(LINT_SAME_ITEM, 0, 0, { item = "coal" }), { K .. "same-item-static", "[item=coal]" })
	assert_eq(d(LINT_SAME_ITEM, 2000, 0, { item = "coal" }), { K .. "same-item-out", "[item=coal]", "2,000" })
	assert_eq(d(LINT_SAME_ITEM, 800, 1, { item = "coal" }), { K .. "same-item-in", "[item=coal]", "800" })
	assert_eq(d(LINT_OCCUPANCY, 0, 1), { K .. "occupancy", "0", "1" })
	assert_eq(d(LINT_OCCUPANCY, 0, 1, { train = 412 }), { K .. "occupancy-train", "412", "1", "0" },
		"the train the stop holds that Cybersyn did not send")
	assert_eq(d(LINT_PHANTOM, 3, 1, { fix = "phantom-leak" }), { K .. "phantom-leak", "2" },
		"a counter leak: the deliveries no train serves")
	assert_eq(d(LINT_PHANTOM, 0, 1, { train = 15, status = STATUS_P }),
		{ K .. "phantom-train", "15", { "cybersyn-diag.lint-train-status-2" }, "0" }, "a bound train the station does not count")
	assert_eq(d(LINT_PRIORITY, 49, 0), { K .. "priority", "49", "0" })
	assert_eq(d(LINT_DEPOT_LIMIT, -1, 0), { K .. "depot-limit-none" })
	assert_eq(d(LINT_DEPOT_LIMIT, 3, 0), { K .. "depot-limit", "3" })
	assert_eq(d(LINT_DEPOT_SHARED_NAME, 2, 2), { K .. "depot-shared-name", "2", "2" })
	assert_eq(d(LINT_REFUELER_MASK, 4, 1, { network = "signal-7" }),
		{ K .. "refueler-mask", "4", "1", "[virtual-signal=signal-7]" })
	assert_eq(d(LINT_NEVER_REFUELLED, 216060, 0, { network = "signal-7" }),
		{ K .. "never-refuelled", "[virtual-signal=signal-7]", "3600s" })
	assert_eq(d(LINT_IN_GROUP, 2, 0), { K .. "in-group", "2", "0" })
	assert_eq(d(LINT_MISSING_STOP, 2, 0), { K .. "missing-stop", "2", "0" })
	assert_eq(d(LINT_CAPACITY_DRIFT, 7, 40), { K .. "capacity-drift", "7", "40" })
	assert_eq(d(LINT_TRAIN_MASK, 1, 42, { network = "signal-B" }),
		{ K .. "train-mask", "1", "42", "[virtual-signal=signal-B]" })
	assert_eq(d(LINT_NO_TRAIN, 0, 0, { network = "signal-8" }), { K .. "no-train", "[virtual-signal=signal-8]" })
	assert_eq(model.detail({ check = LINT_DOUBLE_COMB, subject = LINT_SUBJECT_STOP, id = 5, message = "station-and-depot" },
		ENV), { "cybersyn-gui.problems-world-station-and-depot" })
end)

test("captions and fix lines: one locale key per check, the fix line without numbers", function()
	local model = pm()
	for check = 1, LINT_COUNT do
		assert_eq(model.caption(check), { "cybersyn-diag.lint-" .. LINT_KEYS[check] })
		assert_eq(model.fix(check), { "cybersyn-diag.lint-fix-" .. LINT_KEYS[check] })
		assert_eq(model.fix(check, { check = check }), { "cybersyn-diag.lint-fix-" .. LINT_KEYS[check] })
		assert_eq(model.chip(check), { "cybersyn-diag.lint-chip-" .. LINT_KEYS[check] })
		assert_not_nil(model.CHIP_STYLE[LINT_SEVERITY[check]])
		assert_not_nil(model.DOT[LINT_SEVERITY[check]])
	end
	assert_eq(model.fix(LINT_PHANTOM, { check = LINT_PHANTOM, fix = "phantom-leak" }),
		{ "cybersyn-diag.lint-fix-phantom-leak" }, "a counter leak names the recount")
end)

--- Every key the model and the tab use exists in the English locale, and every other locale carries it too.
test("locale: every lint caption, fix and detail key, and the tab's keys, in every manager.cfg", function()
	local function read(path)
		local f = assert(io.open(H.mod_root .. "/locale/" .. path, "r"))
		local text = f:read("*a")
		f:close()
		return text
	end
	local keys = {}
	for check = 1, LINT_COUNT do
		keys[#keys + 1] = "lint-" .. LINT_KEYS[check]
		keys[#keys + 1] = "lint-fix-" .. LINT_KEYS[check]
		keys[#keys + 1] = "lint-chip-" .. LINT_KEYS[check]
	end
	for _, k in ipairs({ "capacity", "capacity-fluid", "capacity-threshold", "layout", "layout-item", "mask-zero", "no-provider", "limit-zero",
		"same-item-static", "same-item-out", "same-item-in", "occupancy", "occupancy-train", "phantom", "phantom-train",
		"phantom-leak", "priority", "depot-limit", "depot-limit-none",
		"depot-shared-name", "refueler-mask", "never-refuelled", "in-group", "missing-stop", "capacity-drift",
		"train-mask", "no-train" }) do
		keys[#keys + 1] = "lint-detail-" .. k
	end
	for _, m in ipairs({ "double-station", "double-station-control", "double-depot", "double-refueler",
		"station-and-depot", "station-and-refueler", "depot-and-refueler", "non-default-priority",
		"name-overlap-with-depot", "derelict-combinator", "ghost-combinator", "stop-no-combinator",
		"wrong-side-combinator" }) do
		keys[#keys + 1] = "problems-world-" .. m
	end
	keys[#keys + 1] = "lint-fix-phantom-leak"
	for status = STATUS_D, STATUS_F do keys[#keys + 1] = "lint-train-status-" .. status end
	for _, k in ipairs({ "problems", "problems-sev-error", "problems-sev-warning",
		"problems-sev-info", "problems-sev-tooltip", "problems-show-acked", "problems-show-acked-tooltip",
		"problems-col-check", "problems-col-subject", "problems-col-detail", "problems-col-fix", "problems-group",
		"problems-group-continued", "problems-group-acked", "problems-empty", "problems-empty-filtered",
		"problems-train", "problems-combinator", "problems-gone", "problems-predicts", "problems-predicts-none",
		"problems-chip-tooltip", "problems-ack-tooltip", "problems-ack-until-clear", "problems-badge-tooltip",
		"problems-footer", "problems-pending", "problems-pending-progress" }) do
		keys[#keys + 1] = k
	end
	for _, loc in ipairs({ "en", "de", "es", "fr", "ko", "ru", "sv-SE" }) do
		local text = read(loc .. "/manager.cfg")
		for _, k in ipairs(keys) do
			assert_true(text:find("\n" .. k .. "=", 1, true) ~= nil, loc .. " lacks " .. k)
		end
		-- Fix lines carry no numbers: the detail column has them.
		for check = 1, LINT_COUNT do
			local line = text:match("\nlint%-fix%-" .. LINT_KEYS[check]:gsub("%-", "%%-") .. "=([^\n]*)")
			assert_true(line ~= nil and not line:find("__%d__"), loc .. " lint-fix-" .. LINT_KEYS[check])
		end
		assert_true(not text:match("\nlint%-fix%-phantom%-leak=([^\n]*)"):find("__%d__"), loc .. " lint-fix-phantom-leak")
		-- The world scan is gone (PLAN4 D8): its button's texts with it.
		assert_true(text:find("\nproblems-scan-tooltip=", 1, true) == nil, loc .. " still has problems-scan-tooltip")
	end
end)
