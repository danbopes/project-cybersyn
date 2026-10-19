-- Captions and tooltips of the Overview's Unserved requests table (PLAN3 §4.7, wording from the roundtable's Vera
-- §3). Pure: every function takes plain values and returns strings or LocalisedStrings, so the host unit tests cover
-- them without the engine.

local format = require("__flib__.format")
local logic = require("scripts.gui.tab-logic")

local text = {}

text.NO_VALUE = "–"
text.INHERITED = "≥"

local CHIP_STYLE = { [3] = "cybersyn_chip_red", [2] = "cybersyn_chip_orange", [1] = "cybersyn_chip_grey" }

--- Chip style by the reason's severity: red = nothing changes on its own, orange = waiting on stock or capacity,
--- grey = a setting of the player's.
--- @param reason int REASON_*
--- @return string
function text.chip_style(reason)
	return CHIP_STYLE[REASON_SEVERITY[reason] or 1] or "cybersyn_chip_grey"
end

--- @param reason int
--- @return LocalisedString
function text.chip_caption(reason)
	local key = REASON_KEYS[reason]
	if not key then return { "cybersyn-gui.unserved-unknown-reason" } end
	return { "cybersyn-diag.chip-" .. key }
end

--- Counts in the Overview tiles: exact below 10,000, then "12.3k", so a number is never cut to "…" (round 5 item 7);
--- the tile's tooltip carries the exact figure.
--- @param n number?
--- @return string
function text.count(n)
	if n == nil then return text.NO_VALUE end
	if math.abs(n) < 10000 then return format.number(n) end
	return (string.gsub(format.number(n, true), " ", ""))
end

--- "1.2k / 2.0k" for stock against what is needed; train counts for the train-side reasons.
--- @param reason int
--- @param a int payload (PLAN3 §4.5 B1)
--- @param b int
--- @return LocalisedString
function text.stock_caption(reason, a, b)
	a, b = a or 0, b or 0
	if reason == REASON_P_BELOW_THRESHOLD or reason == REASON_P_RESERVED then
		return format_signal_count(a) .. " / " .. format_signal_count(b)
	elseif reason == REASON_CAPACITY then
		-- What the largest eligible train carries, against what the request needs.
		return format_signal_count(b) .. " / " .. format_signal_count(a)
	elseif reason == REASON_R_AT_LIMIT or reason == REASON_P_AT_LIMIT or reason == REASON_R_DISABLED then
		return { "cybersyn-gui.unserved-stock-trains", tostring(a), tostring(b) }
	elseif reason == REASON_NO_TRAINS_ON_NETWORK then
		return { "cybersyn-gui.unserved-stock-no-trains" }
	elseif reason == REASON_TRAIN_FILTERED then
		return { "cybersyn-gui.unserved-stock-filtered", format.number(a) }
	elseif reason == REASON_R_IS_PROVIDING or reason == REASON_P_IS_REQUESTING then
		return format_signal_count(a)
	end
	return text.NO_VALUE
end

--- A plain-string signature of text.stock_caption's result, for sig guards.
--- @return string
function text.stock_sig(reason, a, b)
	return tostring(reason) .. ":" .. tostring(a) .. ":" .. tostring(b)
end

--- Wait column: two units at most, "≥" when the entry predates this diagnostics state (the save load), so the wait is
--- a lower bound rather than a measurement.
--- @param ticks number
--- @param inherited boolean
--- @return string
function text.wait_caption(ticks, inherited)
	return (inherited and text.INHERITED or "") .. logic.short_duration(ticks)
end

--- The "why" line's parameters: __1__ = a, __2__ = b, __3__ = network, __4__..__6__ = the train-filter split.
--- @param reason int
--- @param a int
--- @param b int
--- @param network LocalisedString? the requester's network as rich text
--- @param rej int[]? REJ_* counters of the latest evaluation
--- @param surface_name fun(index: int): string? surface name by index, for NO_SURFACE_ROUTE
--- @return LocalisedString
function text.why(reason, a, b, network, rej, surface_name)
	local key = REASON_KEYS[reason]
	if not key then return { "cybersyn-gui.unserved-unknown-reason" } end
	local p1, p2
	if reason == REASON_MASK_MISMATCH then
		p1, p2 = tostring(a or 0), tostring(b or 0)
	elseif reason == REASON_NO_SURFACE_ROUTE then
		p1 = surface_name and surface_name(a) or tostring(a or 0)
		p2 = surface_name and surface_name(b) or tostring(b or 0)
	else
		p1, p2 = format.number(a or 0), format.number(b or 0)
	end
	local mask, manual, surface = "0", "0", "0"
	if rej then
		mask = format.number(rej[REJ_TRAIN_MASK] or 0)
		manual = format.number(rej[REJ_TRAIN_MANUAL] or 0)
		surface = format.number(rej[REJ_TRAIN_SURFACE] or 0)
	end
	return { "cybersyn-diag.why-" .. key, p1, p2, network or "?", mask, manual, surface }
end

--- @param reason int
--- @param network LocalisedString? the requester's network, __1__ in the fix keys that name it
--- @return LocalisedString
function text.fix(reason, network)
	local key = REASON_KEYS[reason]
	if not key then return "" end
	return { "cybersyn-diag.fix-" .. key, network or "?" }
end

--- @class UnservedTipArgs
--- @field item LocalisedString "[img] Item name"
--- @field requested number? amount the requester asks for (positive); nil when the snapshot does not know it
--- @field requester LocalisedString the requester's name
--- @field reason int
--- @field a int
--- @field b int
--- @field network LocalisedString?
--- @field rej int[]?
--- @field wait int ticks since first_tick
--- @field inherited boolean first_tick inside diagnostics' inherited window (diag.inherit_threshold)
--- @field n int failing evaluations
--- @field read_age int? ticks since the requester was last read by the collector
--- @field surface_name (fun(index: int): string)?

--- The four lines of a reason chip: what is asked, why it is not served, what to do, and how long (Vera §3).
--- @param args UnservedTipArgs
--- @param duration fun(ticks: number): string util.format_duration
--- @return LocalisedString
function text.chip_tooltip(args, duration)
	local asked
	if args.requested then
		asked = { "cybersyn-gui.unserved-asked", args.item, format.number(args.requested), args.requester }
	else
		asked = { "cybersyn-gui.unserved-asked-no-amount", args.item, args.requester }
	end
	local since_key = args.inherited and "cybersyn-gui.unserved-since-load" or "cybersyn-gui.unserved-since"
	local since = { since_key, duration(args.wait), tostring(args.n or 0) }
	if args.read_age then
		since = { "", since, " · ", text.read_ago(args.read_age, duration) }
	end
	return {
		"", asked,
		"\n", { "cybersyn-gui.unserved-why", text.why(args.reason, args.a, args.b, args.network, args.rej, args.surface_name) },
		"\n", { "cybersyn-gui.unserved-fix", text.fix(args.reason, args.network) },
		"\n", since,
	}
end

--- Ages shown in tooltips are rounded down to READ_STEP, so a tooltip is rebuilt at most once per step.
text.READ_STEP = 600

--- "read 20s ago", rounded down to text.READ_STEP.
--- @param ticks number
--- @param duration fun(ticks: number): string
--- @return LocalisedString
function text.read_ago(ticks, duration)
	if ticks < text.READ_STEP then return { "cybersyn-gui.read-just-now" } end
	return { "cybersyn-gui.read-ago", duration(ticks - ticks % text.READ_STEP) }
end

--- Rounded age for a sig, matching text.read_ago.
--- @param ticks number?
--- @return int
function text.read_step(ticks)
	if not ticks then return -1 end
	return math.floor(ticks / text.READ_STEP)
end

return text
