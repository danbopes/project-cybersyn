-- B1 (PLAN3 §4.6): an entity GUI opened from a link of an unpinned manager must not close it. Closing that GUI hands
-- player.opened back to the manager window at once when nothing else holds it; the manager tick confirms the hand-back
-- and retries it once any GUI that replaced the linked one has closed.
-- B5: a train without a locomotive gets an error instead of a silent no-op.

local H = require("harness")

local function load()
	package.preload["__core__.lualib.mod-gui"] = function() return { get_button_flow = function() end } end
	commands = commands or { add_command = function() end }
	local manager_gui = H.load("scripts.gui.main")
	return manager_gui, require("scripts.gui.manager"), require("scripts.gui.util")
end

--- A player whose opened_gui_type follows `opened` the way the engine reports it; `state.gui_type` stands in for GUIs
--- such as the trains overview, which read as opened == nil.
local function new_player(index)
	local state = { opened = nil, gui_type = nil }
	local player = setmetatable({
		index = index, valid = true, _state = state, gui = { screen = {} }, set_shortcut_toggled = function() end,
		controller_type = defines.controllers.character,
	}, {
		__index = function(_, k)
			if k == "opened" then return state.opened end
			if k == "opened_gui_type" then
				if state.gui_type then return state.gui_type end
				local o = state.opened
				if o == nil then return defines.gui_type.none end
				return rawget(o, "_kids") and defines.gui_type.custom or defines.gui_type.entity
			end
		end,
		__newindex = function(t, k, v)
			if k == "opened" then
				state.opened = v
			else
				rawset(t, k, v)
			end
		end,
	})
	game.players[index] = player
	return player
end

local function setup(pinning)
	local manager_gui, manager, util = load()
	local player = new_player(1)
	local window = H.element({ name = "manager_window" })
	local pd = { is_manager_open = true, pinning = pinning or false, refs = { manager_window = window } }
	storage.manager = { players = { [1] = pd } }
	player.opened = window
	game.tick = 500
	mod_settings.manager_ups = 1
	-- Paused with data shown, the manager tick neither collects nor renders: only the hand-back is under test.
	pd.paused = true
	pd.rendered_snapshot_tick = 1
	pd.surface_count = #game.surfaces
	return manager_gui, manager, util, player, pd, window
end

--- util.open_entity as the engine runs it: taking player.opened closes the unpinned manager in the same tick.
local function link(manager, util, player, pd, entity)
	util.open_entity(player, pd, entity)
	manager.handle.manager_closed_by_game(player, pd, pd.refs)
end

local stop = { valid = true, name = "train-stop", unit_number = 77 }
local comb = { valid = true, name = COMBINATOR_NAME, unit_number = 78 }
local chest = { valid = true, name = "wooden-chest", unit_number = 79 }

test("open_entity: records the target and opens it", function()
	local _, _, util, player, pd = setup()
	util.open_entity(player, pd, stop)
	assert_eq(pd.return_to, { entity = stop, tick = 500, controller = defines.controllers.character })
	assert_same(player.opened, stop)
end)

test("closed_by_game: the manager stays open while its own link takes player.opened", function()
	local _, manager, util, player, pd = setup()
	link(manager, util, player, pd, stop)
	assert_true(pd.is_manager_open)
	assert_eq(pd.restore_opened, { entity = stop, controller = defines.controllers.character })
	assert_nil(pd.return_to)
	assert_same(player.opened, stop)
end)

test("closed_by_game: without a manager tick a link closes the window as before", function()
	local _, manager, util, player, pd = setup()
	mod_settings.manager_ups = 0
	link(manager, util, player, pd, stop)
	assert_false(pd.is_manager_open)
	assert_nil(pd.restore_opened)
end)

test("closed_by_game: a close in a later tick is the player's and closes the window", function()
	local _, manager, util, player, pd = setup()
	util.open_entity(player, pd, stop)
	game.tick = 501
	player.opened = nil
	manager.handle.manager_closed_by_game(player, pd, pd.refs)
	assert_false(pd.is_manager_open)
end)

test("on_gui_closed: closing the linked GUI hands player.opened back at once, so the next Escape closes", function()
	local manager_gui, manager, util, player, pd, window = setup()
	link(manager, util, player, pd, stop)
	game.tick = 900
	player.opened = nil
	manager_gui.on_gui_closed({ name = defines.events.on_gui_closed, player_index = 1, entity = stop })
	assert_same(player.opened, window)
	assert_true(pd.restore_opened ~= nil)
	-- The second Escape, before any manager tick.
	game.tick = 912
	player.opened = nil
	manager_gui.on_gui_closed({ name = defines.events.on_gui_closed, player_index = 1, element = window })
	assert_false(pd.is_manager_open)
	assert_nil(pd.restore_opened)
end)

test("on_gui_closed: the manager tick confirms a hand-back that held", function()
	local manager_gui, manager, util, player, pd, window = setup()
	link(manager, util, player, pd, stop)
	game.tick = 900
	player.opened = nil
	manager_gui.on_gui_closed({ name = defines.events.on_gui_closed, player_index = 1, entity = stop })
	game.tick = 960
	manager_gui.tick(storage)
	assert_same(player.opened, window)
	assert_nil(pd.restore_opened)
	assert_nil(pd.handed_back_tick)
end)

test("on_gui_closed: the engine closing the window again in the hand-back tick leaves it to the manager tick", function()
	local manager_gui, manager, util, player, pd, window = setup()
	link(manager, util, player, pd, stop)
	game.tick = 900
	player.opened = nil
	manager_gui.on_gui_closed({ name = defines.events.on_gui_closed, player_index = 1, entity = stop })
	assert_same(player.opened, window)
	player.opened = nil
	manager_gui.on_gui_closed({ name = defines.events.on_gui_closed, player_index = 1, element = window })
	assert_true(pd.is_manager_open)
	assert_true(pd.restore_opened ~= nil)
	game.tick = 960
	manager_gui.tick(storage)
	assert_same(player.opened, window)
	assert_nil(pd.restore_opened)
end)

test("on_gui_closed: a hand-back force-closed by a replacing GUI is retried once that GUI closes", function()
	local manager_gui, manager, util, player, pd, window = setup()
	link(manager, util, player, pd, stop)
	player.opened = nil
	manager_gui.on_gui_closed({ name = defines.events.on_gui_closed, player_index = 1, entity = stop })
	-- The chest the player clicked takes player.opened with no event for the manager window.
	player.opened = chest
	game.tick = 560
	manager_gui.tick(storage)
	assert_same(player.opened, chest)
	assert_true(pd.restore_opened ~= nil)
	player.opened = nil
	game.tick = 620
	manager_gui.tick(storage)
	assert_same(player.opened, window)
	assert_nil(pd.restore_opened)
end)

test("on_gui_closed: another entity closing does not hand back", function()
	local manager_gui, manager, util, player, pd = setup()
	link(manager, util, player, pd, stop)
	player.opened = nil
	manager_gui.on_gui_closed({ name = defines.events.on_gui_closed, player_index = 1, entity = chest })
	assert_nil(player.opened)
	assert_true(pd.restore_opened ~= nil)
end)

test("remote view while a hand-back is pending closes the unpinned manager", function()
	local manager_gui, manager, util, player, pd = setup()
	link(manager, util, player, pd, stop)
	player.opened = nil
	player.controller_type = defines.controllers.remote
	game.tick = 560
	manager_gui.tick(storage)
	assert_false(pd.is_manager_open)
	assert_nil(pd.restore_opened)
	assert_nil(player.opened)
end)

test("remote view: the linked GUI closing on the switch leaves the decision to the manager tick", function()
	local manager_gui, manager, util, player, pd = setup()
	link(manager, util, player, pd, stop)
	player.opened = nil
	player.controller_type = defines.controllers.remote
	manager_gui.on_gui_closed({ name = defines.events.on_gui_closed, player_index = 1, entity = stop })
	assert_true(pd.is_manager_open)
	assert_nil(player.opened)
	game.tick = 560
	manager_gui.tick(storage)
	assert_false(pd.is_manager_open)
end)

test("locomotive on another surface: its remote view while the GUI is open does not close the manager", function()
	local manager_gui, manager, util, player, pd, window = setup()
	local loco = { valid = true, name = "locomotive", unit_number = 80 }
	link(manager, util, player, pd, loco)
	player.controller_type = defines.controllers.remote
	game.tick = 560
	manager_gui.tick(storage)
	assert_true(pd.is_manager_open)
	assert_same(player.opened, loco)
	-- Escape: on_gui_closed still in remote view, the controller is back by the next manager tick.
	player.opened = nil
	manager_gui.on_gui_closed({ name = defines.events.on_gui_closed, player_index = 1, entity = loco })
	assert_true(pd.is_manager_open)
	assert_nil(player.opened)
	player.controller_type = defines.controllers.character
	game.tick = 620
	manager_gui.tick(storage)
	assert_same(player.opened, window)
	assert_nil(pd.restore_opened)
end)

test("tick: waits while the linked GUI is still open", function()
	local manager_gui, manager, util, player, pd = setup()
	link(manager, util, player, pd, stop)
	manager_gui.tick(storage)
	assert_same(player.opened, stop)
	assert_true(pd.restore_opened ~= nil)
end)

test("tick: a GUI that replaced the linked one is waited out", function()
	local manager_gui, manager, util, player, pd, window = setup()
	link(manager, util, player, pd, stop)
	-- Opening a chest from the stop GUI: the stop closes, the chest takes player.opened.
	manager_gui.on_gui_closed({ name = defines.events.on_gui_closed, player_index = 1, entity = stop })
	player.opened = chest
	manager_gui.tick(storage)
	assert_same(player.opened, chest)
	assert_true(pd.restore_opened ~= nil)
	player.opened = nil
	manager_gui.tick(storage)
	assert_same(player.opened, window)
	assert_nil(pd.restore_opened)
end)

test("tick: the combinator's own frame replacing its entity GUI is waited out", function()
	local manager_gui, manager, util, player, pd, window = setup()
	link(manager, util, player, pd, comb)
	local frame = H.element({ name = COMBINATOR_NAME, tags = { id = 78 } })
	manager_gui.on_gui_closed({ name = defines.events.on_gui_closed, player_index = 1, entity = comb })
	player.opened = frame
	manager_gui.tick(storage)
	assert_same(player.opened, frame)
	manager_gui.on_gui_closed({ name = defines.events.on_gui_closed, player_index = 1, element = frame })
	player.opened = nil
	manager_gui.tick(storage)
	assert_same(player.opened, window)
end)

test("restore_opened: a GUI that reads as opened == nil still counts as open", function()
	local _, manager, util, player, pd, window = setup()
	link(manager, util, player, pd, stop)
	player.opened = nil
	player._state.gui_type = defines.gui_type.trains
	assert_false(manager.restore_opened(player, pd))
	assert_nil(player.opened)
	player._state.gui_type = nil
	assert_true(manager.restore_opened(player, pd))
	assert_same(player.opened, window)
end)

test("restore_opened: pinned or closed managers are left alone", function()
	local _, manager, util, player, pd = setup()
	link(manager, util, player, pd, stop)
	player.opened = nil
	pd.pinning = true
	assert_true(manager.restore_opened(player, pd))
	assert_nil(player.opened)
	pd.pinning = false
	pd.is_manager_open = false
	assert_true(manager.restore_opened(player, pd))
	assert_nil(player.opened)
end)

test("close_manager_window: forgets a pending return", function()
	local _, manager, util, player, pd = setup()
	link(manager, util, player, pd, stop)
	pd.refs.manager_window.visible = true
	util.close_manager_window(player, pd, pd.refs, true)
	assert_nil(pd.return_to)
	assert_nil(pd.restore_opened)
end)

local function train_case(locomotive)
	local manager_gui, _, _, player, pd = setup()
	package.loaded["__flib__.train"] = { get_main_locomotive = function() return locomotive end }
	local trains_tab = H.load("scripts.gui.trains")
	local texts = {}
	player.create_local_flying_text = function(spec) texts[#texts + 1] = spec.text end
	player.play_sound = function() end
	storage.trains = { [5] = { entity = { valid = true, id = 5,
		locomotives = { front_movers = { locomotive }, back_movers = {} } } } }
	trains_tab.handle.open_train_gui(player, pd, pd.refs, { element = { tags = { train_id = 5 } } })
	package.loaded["__flib__.train"] = nil
	return player, pd, texts
end

test("open_train_gui: a train without a locomotive says so (B5)", function()
	local player, pd, texts = train_case(nil)
	assert_eq(texts, { { "cybersyn-gui.train-has-no-locomotive" } })
	assert_nil(pd.return_to)
	assert_same(player.opened, pd.refs.manager_window)
end)

test("open_train_gui: the main locomotive opens as a manager link", function()
	local loco = { valid = true, name = "locomotive", unit_number = 9 }
	local player, pd, texts = train_case(loco)
	assert_eq(texts, {})
	assert_same(player.opened, loco)
	assert_same(pd.return_to.entity, loco)
end)
