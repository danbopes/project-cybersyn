-- scripts/gui/rich-name.lua: the station-name parser behind util.parse_rich_name (PLAN3 §4.2).

local H = require("harness")

local function parse(name)
	return H.load("scripts.gui.rich-name").parse(name)
end

local function icon(sprite, quality)
	return { sprite = sprite, quality = quality }
end

local function parts(lead, text, tail, lead_overflow, tail_overflow)
	return { lead = lead or {}, text = text, tail = tail or {}, lead_overflow = lead_overflow or 0, tail_overflow = tail_overflow or 0 }
end

test("plain names: text only, trimmed", function()
	assert_eq(parse("Iron Mine"), parts({}, "Iron Mine"))
	assert_eq(parse("  Iron  Mine \t"), parts({}, "Iron  Mine"))
	assert_eq(parse(""), parts({}, ""))
	assert_eq(parse(nil), parts({}, ""))
end)

test("leading icons of every supported type, with quality", function()
	assert_eq(parse("[item=iron-plate] Iron"), parts({ icon("item/iron-plate") }, "Iron"))
	assert_eq(parse("[fluid=water][virtual-signal=signal-A] [entity=stone-furnace]Smelter"), parts({
		icon("fluid/water"), icon("virtual-signal/signal-A"), icon("entity/stone-furnace"),
	}, "Smelter"))
	assert_eq(parse("[item=iron-plate,quality=rare] Iron"), parts({ icon("item/iron-plate", "rare") }, "Iron"))
	assert_eq(parse("[item= iron-plate , quality = epic ] Iron"), parts({ icon("item/iron-plate", "epic") }, "Iron"))
end)

test("trailing icons and mixed names", function()
	assert_eq(parse("Iron drop [item=iron-plate]"), parts({}, "Iron drop", { icon("item/iron-plate") }))
	assert_eq(parse("[item=coal] Coal [virtual-signal=signal-P][virtual-signal=signal-1]"),
		parts({ icon("item/coal") }, "Coal", { icon("virtual-signal/signal-P"), icon("virtual-signal/signal-1") }))
end)

test("icons inside the text stay in the text as rich text", function()
	assert_eq(parse("[item=coal] Coal to [item=iron-plate] smelter"),
		parts({ icon("item/coal") }, "Coal to [item=iron-plate] smelter"))
	-- Like a leading run, a trailing run needs no space before it.
	assert_eq(parse("A-[item=coal]"), parts({}, "A-", { icon("item/coal") }))
end)

test("lead and tail capped at three with overflow counts", function()
	local name = "[item=a][item=b][item=c][item=d][item=e] Hub [fluid=f][fluid=g][fluid=h][fluid=i]"
	assert_eq(parse(name), parts(
		{ icon("item/a"), icon("item/b"), icon("item/c") }, "Hub",
		{ icon("fluid/g"), icon("fluid/h"), icon("fluid/i") }, 2, 1))
end)

test("icons only: everything is the leading run", function()
	assert_eq(parse("[item=a] [item=b]"), parts({ icon("item/a"), icon("item/b") }, ""))
	assert_eq(parse("[item=a][item=b][item=c][item=d]"), parts({ icon("item/a"), icon("item/b"), icon("item/c") }, "", {}, 1))
end)

test("malformed and unknown tags are text", function()
	assert_eq(parse("[item=] Empty"), parts({}, "[item=] Empty"))
	assert_eq(parse("[item=coal Unclosed"), parts({}, "[item=coal Unclosed"))
	assert_eq(parse("[color=red]Red[/color]"), parts({}, "[color=red]Red[/color]"))
	assert_eq(parse("[img=item/coal] Coal"), parts({}, "[img=item/coal] Coal"))
	assert_eq(parse("[item=coal,foo=bar] Coal"), parts({}, "[item=coal,foo=bar] Coal"))
	assert_eq(parse("[[item=coal]] x"), parts({}, "[[item=coal]] x"))
	-- An unknown tag ends the leading run; the icon after it is inside the text.
	assert_eq(parse("[item=coal][color=red]x[/color]"), parts({ icon("item/coal") }, "[color=red]x[/color]"))
end)

test("unicode text is kept byte for byte", function()
	assert_eq(parse("[item=coal] Kohle → Schmelze ÄÖÜ"), parts({ icon("item/coal") }, "Kohle → Schmelze ÄÖÜ"))
	assert_eq(parse("日本 [fluid=water]"), parts({}, "日本", { icon("fluid/water") }))
end)

test("util.parse_rich_name is the same function", function()
	local util = H.load("scripts.gui.util")
	assert_eq(util.parse_rich_name("[item=coal] C"), parts({ icon("item/coal") }, "C"))
end)
