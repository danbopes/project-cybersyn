-- GUI sizes the layout math depends on (scripts/gui/constants.lua at 3b5fe31).

local constants = require("scripts.gui.constants")

test("content frame height", function()
	-- PLAN3: §4.3 removes gui_content_frame_height; the window height comes from the screen instead.
	assert_eq(constants.gui_content_frame_height, 784)
end)

test("stations column widths after the override block", function()
	assert_eq(constants.gui.en.stations, {
		name = 184,
		status = 110,
		network_id = 85,
		station_status = 100,
		network = 80,
		provided_requested = 216,
		provided_requested_columns = 6,
		deliveries_count = 40,
		shipments = 144,
		shipments_columns = 4,
		deliveries = 188,
		control_signals = 144,
		control_signals_columns = 4,
		wait = 56,
		last_delivery = 100,
	})
end)

test("trains column widths", function()
	assert_eq(constants.gui.en.trains, {
		train_id = 90, status = 420, layout = 200, depot = 160, shipment = 216, shipment_columns = 6,
	})
end)

test("colors and the station GUI tooltip", function()
	assert_eq(constants.colors.red.tbl, { 255, 69, 69 })
	assert_eq(constants.colors.green.str, "69, 255, 69")
	assert_eq(constants.open_station_gui_tooltip, { "", { "cybersyn-gui.open-station-gui" } })
end)
