-- Splits a train stop's rich-text name into leading icons, plain text and trailing icons, so a row can draw the icons
-- as sprites and give the text the width. Pure string work: identical in every Lua state, no prototype lookups.
-- util.parse_rich_name re-exports it; the collector requires this module directly because util requires the collector.

local rich_name = {}

--- Icons kept on each side; the rest is counted in lead_overflow / tail_overflow.
rich_name.MAX_ICONS = 3

--- Rich-text tag types that name a sprite, mapped to their sprite path prefix.
local SPRITE_TYPES = {
	item = "item",
	fluid = "fluid",
	["virtual-signal"] = "virtual-signal",
	entity = "entity",
}

--- @class RichNameIcon
--- @field sprite string sprite path, e.g. "item/iron-plate"
--- @field quality string? quality name of a `[item=x,quality=y]` tag

--- @class RichNameParts
--- @field lead RichNameIcon[] at most MAX_ICONS icons before the text, in name order
--- @field text string the name between the icon runs, trimmed; may still hold tags this parser does not turn into icons
--- @field tail RichNameIcon[] at most MAX_ICONS icons after the text, in name order
--- @field lead_overflow integer leading icons beyond MAX_ICONS
--- @field tail_overflow integer trailing icons beyond MAX_ICONS

--- Parses the tag starting at `pos` (a "["). Returns the icon and the position after the "]", or nil when the tag is
--- not an icon tag this module understands.
--- @param name string
--- @param pos integer
--- @return RichNameIcon?
--- @return integer?
local function icon_at(name, pos)
	local s, e, kind, body = string.find(name, "^%[([%w%-]+)=([^%[%]]*)%]", pos)
	if not s then return nil end
	local prefix = SPRITE_TYPES[kind]
	if not prefix then return nil end
	local id, rest = string.match(body, "^%s*([^,%s]+)%s*(.*)$")
	if not id then return nil end
	local quality
	if rest ~= "" then
		quality = string.match(rest, "^,%s*quality%s*=%s*([^,%s]+)%s*$")
		if not quality then return nil end
	end
	return { sprite = prefix .. "/" .. id, quality = quality }, e + 1
end

--- Every icon tag in `name`, each with its byte span, in order.
--- @param name string
--- @return {icon: RichNameIcon, s: integer, e: integer}[]
local function scan(name)
	local found = {}
	local pos = 1
	while true do
		local s = string.find(name, "[", pos, true)
		if not s then break end
		local icon, after = icon_at(name, s)
		if icon then
			found[#found + 1] = { icon = icon, s = s, e = after - 1 }
			pos = after
		else
			pos = s + 1
		end
	end
	return found
end

local function only_space(name, from, to)
	return from > to or string.find(string.sub(name, from, to), "^%s*$") ~= nil
end

--- @param name string full rich-text name
--- @return RichNameParts
function rich_name.parse(name)
	local parts = { lead = {}, text = "", tail = {}, lead_overflow = 0, tail_overflow = 0 }
	if type(name) ~= "string" or name == "" then return parts end
	local found = scan(name)
	local n = #found
	local max = rich_name.MAX_ICONS

	-- Leading run: icons separated from each other and from the start by whitespace only.
	local lead_n, prev_end = 0, 0
	while lead_n < n and only_space(name, prev_end + 1, found[lead_n + 1].s - 1) do
		lead_n = lead_n + 1
		prev_end = found[lead_n].e
	end
	local text_from = prev_end + 1

	-- Trailing run, never overlapping the leading one.
	local tail_first, next_start = n + 1, #name + 1
	while tail_first - 1 > lead_n and only_space(name, found[tail_first - 1].e + 1, next_start - 1) do
		tail_first = tail_first - 1
		next_start = found[tail_first].s
	end
	local text_to = next_start - 1

	for i = 1, lead_n do
		if i <= max then
			parts.lead[i] = found[i].icon
		else
			parts.lead_overflow = parts.lead_overflow + 1
		end
	end
	local tail_n = n - tail_first + 1
	local skip = math.max(tail_n - max, 0)
	parts.tail_overflow = skip
	for i = tail_first + skip, n do
		parts.tail[#parts.tail + 1] = found[i].icon
	end
	parts.text = string.match(string.sub(name, text_from, text_to), "^%s*(.-)%s*$")
	return parts
end

return rich_name
