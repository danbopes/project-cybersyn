-- Captions and the four-line chip tooltip of the Overview's Unserved table (scripts/gui/unserved-text.lua).

local H = require("harness")

local function text()
	return H.load("scripts.gui.unserved-text")
end

local function dur(ticks) return tostring(math.floor(ticks / 60)) .. "s" end

test("chip_style: red, orange, grey by severity; unknown reads grey", function()
	local t = text()
	assert_eq(t.chip_style(REASON_NO_PROVIDER), "cybersyn_chip_red")
	assert_eq(t.chip_style(REASON_P_BELOW_THRESHOLD), "cybersyn_chip_orange")
	assert_eq(t.chip_style(REASON_P_RESERVED), "cybersyn_chip_orange")
	assert_eq(t.chip_style(REASON_R_DISABLED), "cybersyn_chip_grey")
	assert_eq(t.chip_style(99), "cybersyn_chip_grey")
end)

test("chip_caption: the chip key per reason, Provider held for P_RESERVED", function()
	local t = text()
	assert_eq(t.chip_caption(REASON_P_RESERVED), { "cybersyn-diag.chip-p-reserved" })
	assert_eq(t.chip_caption(REASON_NO_TRAINS_ON_NETWORK), { "cybersyn-diag.chip-no-trains-on-network" })
	assert_eq(t.chip_caption(99), { "cybersyn-gui.unserved-unknown-reason" })
end)

test("stock_caption: stock / needed, train counts for the train-side reasons", function()
	local t = text()
	assert_eq(t.stock_caption(REASON_P_BELOW_THRESHOLD, 1200, 2000), "1.2k / 2.0k")
	assert_eq(t.stock_caption(REASON_P_RESERVED, 400, 400), "400 / 400")
	-- CAPACITY carries needed / largest; the column shows what the train carries against what is needed.
	assert_eq(t.stock_caption(REASON_CAPACITY, 4000, 3200), "3.2k / 4.0k")
	assert_eq(t.stock_caption(REASON_R_AT_LIMIT, 4, 4), { "cybersyn-gui.unserved-stock-trains", "4", "4" })
	assert_eq(t.stock_caption(REASON_NO_TRAINS_ON_NETWORK, 0, 12), { "cybersyn-gui.unserved-stock-no-trains" })
	assert_eq(t.stock_caption(REASON_TRAIN_FILTERED, 212, 0), { "cybersyn-gui.unserved-stock-filtered", "212" })
	assert_eq(t.stock_caption(REASON_NO_PROVIDER, 0, 0), "–")
	assert_eq(t.stock_caption(REASON_R_LAYOUT, nil, nil), "–")
end)

test("wait_caption: ≥ only for entries older than the diagnostics state", function()
	local t = text()
	assert_eq(t.wait_caption(600, false), "10s")
	assert_eq(t.wait_caption(600, true), "≥10s")
end)

test("why: a and b as numbers, masks raw, surfaces by name, the train split", function()
	local t = text()
	assert_eq(t.why(REASON_P_BELOW_THRESHOLD, 1200, 2000, "[virtual-signal=signal-A]"),
		{ "cybersyn-diag.why-p-below-threshold", "1,200", "2,000", "[virtual-signal=signal-A]", "0", "0", "0" })
	assert_eq(t.why(REASON_CAPACITY, 4000, 3200, "N")[2], "4,000")
	assert_eq(t.why(REASON_MASK_MISMATCH, 1024, 2048, "N"), { "cybersyn-diag.why-mask-mismatch", "1024", "2048", "N", "0", "0", "0" })
	local names = { [1] = "nauvis", [3] = "cyb-bench" }
	assert_eq(t.why(REASON_NO_SURFACE_ROUTE, 3, 1, "N", nil, function(i) return names[i] end),
		{ "cybersyn-diag.why-no-surface-route", "cyb-bench", "nauvis", "N", "0", "0", "0" })
	local rej = { 0, 0, 0, 0, 0, 140, 72, 0 }
	assert_eq(t.why(REASON_TRAIN_FILTERED, 212, 0, "A", rej),
		{ "cybersyn-diag.why-train-filtered", "212", "0", "A", "140", "72", "0" })
end)

test("chip_tooltip: four lines, asked / why / fix / since, with the since-load wording when inherited", function()
	local t = text()
	local tip = t.chip_tooltip({
		item = "[item=coal] Coal", requested = 400, requester = "Req", reason = REASON_NO_PROVIDER, a = 0, b = 0,
		network = "A", wait = 7 * 3600 + 40 * 60, inherited = true, n = 41,
	}, dur)
	assert_eq(tip[2], { "cybersyn-gui.unserved-asked", "[item=coal] Coal", "400", "Req" })
	assert_eq(tip[3], "\n")
	assert_eq(tip[4], { "cybersyn-gui.unserved-why", { "cybersyn-diag.why-no-provider", "0", "0", "A", "0", "0", "0" } })
	assert_eq(tip[6], { "cybersyn-gui.unserved-fix", { "cybersyn-diag.fix-no-provider", "A" } })
	assert_eq(tip[8], { "cybersyn-gui.unserved-since-load", "460s", "41" })
	assert_eq(#tip, 8)
end)

test("chip_tooltip: no amount when the snapshot does not know it; read age appended", function()
	local t = text()
	local tip = t.chip_tooltip({
		item = "I", requester = "R", reason = REASON_P_RESERVED, a = 300, b = 400, wait = 120, inherited = false, n = 2,
		read_age = 1300,
	}, dur)
	assert_eq(tip[2], { "cybersyn-gui.unserved-asked-no-amount", "I", "R" })
	assert_eq(tip[4][2][1], "cybersyn-diag.why-p-reserved")
	assert_eq(tip[8], { "", { "cybersyn-gui.unserved-since", "2s", "2" }, " · ", { "cybersyn-gui.read-ago", "20s" } })
end)

test("read_ago and read_step: rounded down to 10 s so tooltips are not rebuilt every update", function()
	local t = text()
	assert_eq(t.read_ago(30, dur), { "cybersyn-gui.read-just-now" })
	assert_eq(t.read_ago(1199, dur), { "cybersyn-gui.read-ago", "10s" })
	assert_eq(t.read_step(599), 0)
	assert_eq(t.read_step(600), 1)
	assert_eq(t.read_step(nil), -1)
end)

--- Values of one section of a cfg file, by key.
local function cfg_section(path, section)
	local f = assert(io.open(path, "r"))
	local out, current = {}, nil
	for line in f:lines() do
		local head = line:match("^%[(.-)%]")
		if head then
			current = head
		elseif current == section then
			local k, v = line:match("^([^=;#]+)=(.*)$")
			if k then out[k] = v end
		end
	end
	f:close()
	return out
end

--- Highest __n__ a locale value refers to.
local function max_param(value)
	local n = 0
	for d in value:gmatch("__(%d+)__") do n = math.max(n, tonumber(d)) end
	return n
end

test("locale: every reason's chip, why and fix line gets every __n__ it names, in every manager.cfg", function()
	local t = text()
	for _, loc in ipairs({ "en", "de", "es", "fr", "ko", "ru", "sv-SE" }) do
		local cfg = cfg_section(H.mod_root .. "/locale/" .. loc .. "/manager.cfg", "cybersyn-diag")
		for code, key in pairs(REASON_KEYS) do
			local rendered = {
				t.chip_caption(code),
				t.why(code, 1, 2, "[virtual-signal=signal-A]"),
				t.fix(code, "[virtual-signal=signal-A]"),
			}
			for _, ls in ipairs(rendered) do
				local value = cfg[ls[1]:gsub("^cybersyn%-diag%.", "")]
				assert_true(value ~= nil, loc .. " lacks " .. ls[1])
				assert_true(max_param(value) <= #ls - 1,
					loc .. " " .. ls[1] .. " names __" .. max_param(value) .. "__ but gets " .. (#ls - 1) .. " parameters")
			end
		end
	end
	assert_eq(t.fix(REASON_NO_TRAINS_ON_NETWORK, "N"), { "cybersyn-diag.fix-no-trains-on-network", "N" })
	assert_eq(t.fix(REASON_NO_PROVIDER, nil), { "cybersyn-diag.fix-no-provider", "?" })
end)
