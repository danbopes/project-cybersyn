-- The manager's tabs in pane order and which of the manager's filters each applies. Data only, so filters.lua can
-- read it without requiring the tabs.

--- @class ManagerTab
--- @field name string
--- @field search true? has the station-name search, and applies it
--- @field station true? applies the station chip (the chip shows on every tab; the others say they ignore it)
--- @field item true? applies the item filter

--- @type ManagerTab[]
local tabs = {
	{ name = "overview_tab", item = true },
	{ name = "inventory_tab", search = true, station = true, item = true },
	{ name = "stations_tab", search = true, station = true, item = true },
	{ name = "trains_tab", search = true, station = true, item = true },
	{ name = "log_tab", station = true, item = true },
	{ name = "utilization_tab" },
	{ name = "delivery_breakdown_tab", item = true },
}

--- @type {[string]: ManagerTab}
tabs.by_name = {}
for _, t in ipairs(tabs) do tabs.by_name[t.name] = t end

return tabs
