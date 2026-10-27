-- The filter chips' captions fit the maximal_width the tabs give them, in every shipped locale (en's text where a
-- locale has no translation of its own), measured with the fonts Factorio renders button captions in at UI scale 1.0.
-- A chip that fails here would show clipped in game: widen it in its tab's CHIP_WIDTH or shorten the English source.

local H = require("harness")
local FONTS = require("fixtures.font_advances")

-- Measured in game at UI scale 1.0 (a chip button is its text plus the style's paddings plus this) and the size of an
-- [img=] icon in a 14 px caption. Both reproduce the Stations subheader to within 1 px; see SLACK.
local BUTTON_EXTRA = 8
local ICON = 20
-- The estimate came out 1 px short on four of seven chips in the calibration screenshot, never long.
local SLACK = 1

local function style_padding()
	local f = assert(io.open(H.mod_root .. "/prototypes/gui-style.lua", "r"))
	local src = f:read("*a")
	f:close()
	local block = assert(src:match("styles%.cybersyn_filter_chip = (%b{})"), "cybersyn_filter_chip style")
	-- Another font would need another advance table.
	assert(block:match('parent = "button"') and not block:match("font"), "the chip keeps the button style's font")
	return tonumber(block:match("left_padding = (%d+)")) + tonumber(block:match("right_padding = (%d+)"))
end

local function locales()
	local p = assert(io.popen('ls "' .. H.mod_root .. '/locale"'))
	local out = {}
	for name in p:lines() do out[#out + 1] = name end
	p:close()
	return out
end

-- Every cfg file of a locale on top of en's, as the engine falls back per key.
local function strings(loc)
	local function read(dir, into)
		local p = assert(io.popen('ls "' .. H.mod_root .. "/locale/" .. dir .. '"'))
		for file in p:lines() do
			if file:match("%.cfg$") then
				for section, keys in pairs(H.read_cfg(dir .. "/" .. file)) do
					for _, k in ipairs(keys.order) do into[section .. "." .. k] = keys[k] end
				end
			end
		end
		p:close()
		return into
	end
	local out = read("en", {})
	if loc ~= "en" then read(loc, out) end
	return out
end

local function localise(ls, dict)
	if type(ls) == "string" then return ls end
	local key = ls[1]
	local parts = {}
	for i = 2, #ls do parts[i - 1] = localise(ls[i], dict) end
	if key == "" then return table.concat(parts) end
	local text = assert(dict[key], "no locale text for " .. key)
	return (text:gsub("__(%d+)__", function(n) return assert(parts[tonumber(n)], key .. " parameter " .. n) end))
end

local function utf8_codepoints(s)
	local cps, i = {}, 1
	while i <= #s do
		local c = s:byte(i)
		local n = c < 0x80 and 1 or c < 0xE0 and 2 or c < 0xF0 and 3 or 4
		local cp = n == 1 and c or c % (2 ^ (7 - n))
		for j = 1, n - 1 do cp = cp * 64 + s:byte(i + j) % 64 end
		cps[#cps + 1] = cp
		i = i + n
	end
	return cps
end

local function text_width(text, advance)
	local icons = 0
	text = text:gsub("%[img=[^%]]+%]", function()
		icons = icons + 1
		return ""
	end)
	assert(not text:find("[%[%]]"), "unhandled rich text in " .. text)
	local w = icons * ICON
	for _, cp in ipairs(utf8_codepoints(text)) do
		w = w + assert(advance[cp], string.format("U+%04X is not in font_advances.lua: rerun gen_font_advances.py", cp))
	end
	return w
end

-- Counts with every digit count the code formats (format.number: "1,000" from four digits) and each digit, plus no
-- count at all, which the Stations chips show as a dash while the first pass runs.
local COUNTS = { false }
for digits = 1, 7 do
	for d = 0, 9 do
		if digits == 1 or d > 0 then COUNTS[#COUNTS + 1] = tonumber(string.rep(tostring(d), digits)) end
	end
end

local function check(tab, keys, caption)
	local padding = style_padding()
	local over, n = {}, 0
	for _, loc in ipairs(locales()) do
		local chain = assert(FONTS.chains[FONTS.locales[loc]], "no font chain for locale " .. loc .. ": rerun gen_font_advances.py")
		local dict = strings(loc)
		for _, key in ipairs(keys) do
			local worst
			for _, count in ipairs(COUNTS) do
				local c = count or nil
				local need = text_width(localise(caption(key, c), dict), chain.advance) + padding + BUTTON_EXTRA + SLACK
				local have = tab.chip_max_width(key, c or 0)
				n = n + 1
				if need > have and (not worst or need - have > worst.by) then
					worst = { by = need - have, need = need, have = have, count = c }
				end
			end
			if worst then
				over[#over + 1] = string.format("%s %s count %s: %d px > %d", loc, key, worst.count and tostring(worst.count) or "-",
					worst.need, worst.have)
			end
		end
	end
	assert_true(n > 100, "measured the captions")
	table.sort(over)
	assert_eq(over, {})
end

-- In game every chip icon names a real sprite; the harness has no sprite prototypes, and its helpers outlive a test.
local function with_tabs(fn)
	local valid = helpers.is_valid_sprite_path
	helpers.is_valid_sprite_path = function() return true end
	H.load("scripts.gui.util")
	local ok, err = pcall(fn, H.load("scripts.gui.stations"), H.load("scripts.gui.trains"))
	helpers.is_valid_sprite_path = valid
	H.load("scripts.gui.util")
	if not ok then error(err, 0) end
end

test("Stations chips: every shipped locale's caption fits the chip's maximal_width", function()
	with_tabs(function(stations_tab)
		local keys = { "all" }
		for _, s in ipairs(require("scripts.gui.tab-logic").STATUSES) do keys[#keys + 1] = s end
		for _, k in ipairs({ "unserved", "problems", "stuck", "failing" }) do keys[#keys + 1] = k end
		check(stations_tab, keys, stations_tab.chip_caption)
	end)
end)

test("Trains chips: every shipped locale's caption fits the chip's maximal_width", function()
	with_tabs(function(_, trains_tab)
		check(trains_tab, require("scripts.gui.tab-logic").TRAIN_CHIPS, function(key, count)
			return trains_tab.chip_caption(key, count or 0, REFUEL_GRACE_TICKS / 216000)
		end)
	end)
end)

test("font_advances.lua covers every shipped locale", function()
	for _, loc in ipairs(locales()) do
		assert_not_nil(FONTS.locales[loc], loc)
	end
end)
