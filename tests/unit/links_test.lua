-- B1 (PLAN3 §4.6): an entity GUI opened from a link of an unpinned manager must not close it, and closing that GUI
-- hands player.opened back to the manager window (at once, or on the next manager tick when something still holds it).
-- B5: a train without a locomotive gets an error instead of a silent no-op.

local H = require("harness")

local function load()
	package.preload["__core__.lualib.mod-gui"] = function() return { get_button_flow = function() end } end
	commands = commands or { add_command = function() end }
	local manager_gui = H.load("scripts.gui.main")
	return manager_gui, require("scripts.gui.manager"), require("scripts.gui.util")
end

--- A player whose `opened` can be made to refuse writes, as the engine may while it is closing a GUI.
local function new_player(index)
	local state = { opened = nil, refuse = false }
	local player = setmetatable({
		index = index, valid = true, _state = state, gui = { screen = {} }, set_shortcut_toggled = function() end,
	}, {
		__index = function(_, k) if k == "opened" then return state.opened end end,
		__newindex = function(t, k, v)
			if k == "opened" then
				if not state.refuse then state.opened = v end
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
	return manager_gui, manager, util, player, pd, window
end

local stop = { valid = true, name = "train-stop", unit_number = 77 }
local comb = { valid = true, name = COMBINATOR_NAME, unit_number = 78 }

test("open_entity: records the target and opens it", function()
	local _, _, util, player, pd = setup()
	util.open_entity(player, pd, stop)
	assert_eq(pd.return_to, { entity = stop, unit_number = 77, tick = 500 })
	assert_same(player.opened, stop)
end)

test("closed_by_game: the manager stays open while its own link takes player.opened", function()
	local _, manager, util, player, pd = setup()
	util.open_entity(player, pd, stop)
	manager.handle.manager_closed_by_game(player, pd, pd.refs)
	assert_true(pd.is_manager_open)
end)

test("on_gui_closed: closing the linked GUI gives player.opened back to the unpinned manager", function()
	local manager_gui, _, util, player, pd, window = setup()
	util.open_entity(player, pd, stop)
	game.tick = 900
	player.opened = nil
	manager_gui.on_gui_closed({ name = defines.events.on_gui_closed, player_index = 1, entity = stop })
	assert_same(player.opened, window)
	assert_nil(pd.return_to)
	assert_nil(pd.restore_opened)
end)

test("on_gui_closed: a refused write is retried by the next manager tick", function()
	local manager_gui, manager, util, player, pd, window = setup()
	util.open_entity(player, pd, stop)
	player._state.refuse = true
	player._state.opened = nil
	manager_gui.on_gui_closed({ name = defines.events.on_gui_closed, player_index = 1, entity = stop })
	assert_nil(player.opened)
	assert_true(pd.restore_opened)
	player._state.refuse = false
	assert_true(manager.restore_opened(player, pd))
	assert_same(player.opened, window)
end)

test("closed_by_game: the engine releasing player.opened again in the restoring tick defers instead of closing", function()
	local manager_gui, manager, util, player, pd, window = setup()
	util.open_entity(player, pd, stop)
	game.tick = 900
	player.opened = nil
	manager_gui.on_gui_closed({ name = defines.events.on_gui_closed, player_index = 1, entity = stop })
	assert_same(player.opened, window)
	-- Measured with the locomotive GUI: closing it hands player.opened back, then the engine clears it in that tick.
	player.opened = nil
	manager.handle.manager_closed_by_game(player, pd, pd.refs)
	assert_true(pd.is_manager_open)
	assert_true(pd.restore_opened)
	game.tick = 960
	-- Paused, the manager tick neither collects nor renders: only the hand-back is under test.
	pd.paused = true
	pd.surface_count = #game.surfaces
	manager_gui.tick(storage)
	assert_same(player.opened, window)
	assert_nil(pd.restore_opened)
	-- A later close is the player's: it closes the window.
	game.tick = 1000
	player.opened = nil
	manager.handle.manager_closed_by_game(player, pd, pd.refs)
	assert_false(pd.is_manager_open)
end)

test("on_gui_closed: another GUI still open waits; the manager comes back when it closes", function()
	local manager_gui, manager, util, player, pd, window = setup()
	util.open_entity(player, pd, comb)
	-- The combinator's own frame replaces its entity GUI: the entity GUI closes while the frame holds player.opened.
	local frame = H.element({ name = COMBINATOR_NAME, tags = { id = 78 } })
	player.opened = frame
	manager_gui.on_gui_closed({ name = defines.events.on_gui_closed, player_index = 1, entity = comb })
	assert_same(player.opened, frame)
	assert_true(pd.restore_opened)
	assert_false(manager.restore_opened(player, pd))
	player.opened = nil
	assert_true(manager.restore_opened(player, pd))
	assert_same(player.opened, window)
end)

test("on_gui_closed: the combinator frame of the linked combinator counts as the linked GUI", function()
	local manager_gui, _, util, player, pd, window = setup()
	util.open_entity(player, pd, comb)
	player.opened = nil
	local frame = H.element({ name = COMBINATOR_NAME, tags = { id = 78 } })
	manager_gui.on_gui_closed({ name = defines.events.on_gui_closed, player_index = 1, element = frame })
	assert_same(player.opened, window)
	assert_nil(pd.return_to)
end)

test("on_gui_closed: unrelated GUIs, pinned or closed managers are left alone", function()
	local manager_gui, _, util, player, pd = setup()
	util.open_entity(player, pd, stop)
	player.opened = nil
	manager_gui.on_gui_closed({ name = defines.events.on_gui_closed, player_index = 1, entity = comb })
	assert_nil(player.opened)
	assert_same(pd.return_to.entity, stop)

	local manager_gui2, _, util2, player2, pd2 = setup(true)
	util2.open_entity(player2, pd2, stop)
	player2.opened = nil
	manager_gui2.on_gui_closed({ name = defines.events.on_gui_closed, player_index = 1, entity = stop })
	assert_nil(player2.opened)

	local manager_gui3, _, util3, player3, pd3 = setup()
	util3.open_entity(player3, pd3, stop)
	pd3.is_manager_open = false
	player3.opened = nil
	manager_gui3.on_gui_closed({ name = defines.events.on_gui_closed, player_index = 1, entity = stop })
	assert_nil(player3.opened)
end)

test("close_manager_window: forgets a pending return", function()
	local _, _, util, player, pd = setup()
	util.open_entity(player, pd, stop)
	pd.restore_opened = true
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
	storage.trains = { [5] = { entity = { valid = true, id = 5 } } }
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
