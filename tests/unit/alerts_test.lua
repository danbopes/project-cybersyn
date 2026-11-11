-- Factorio 2.0 has no LuaForce::add_custom_alert or remove_alert: alerts go to each connected player, the sound to
-- the force in one call, and a removal reaches every player, so a player who was offline when it was sent loses it too.

local function fake_player(calls, name)
	return {
		name = name,
		add_custom_alert = function(entity, icon, message, show_on_map)
			calls.alerts[#calls.alerts + 1] = { player = name, entity = entity, icon = icon, message = message,
				show_on_map = show_on_map }
		end,
		remove_alert = function(filter) calls.removed[#calls.removed + 1] = { player = name, filter = filter } end,
		play_sound = function() error("per-player sound") end,
	}
end

local function fake_force()
	local calls = { alerts = {}, sounds = {}, removed = {} }
	local online, offline = fake_player(calls, "online"), fake_player(calls, "offline")
	local force = {
		players = { online, offline },
		connected_players = { online },
		play_sound = function(spec) calls.sounds[#calls.sounds + 1] = spec end,
	}
	return force, calls
end

local function fake_train(force)
	local loco = { valid = true, force = force }
	return { id = 7, valid = true, front_stock = loco }, loco
end

test("train alert: one alert per connected player on the locomotive plus one force sound", function()
	local force, calls = fake_force()
	local train, loco = fake_train(force)
	local map_data = { total_ticks = 100 }
	send_alert_depot_of_train_broken(map_data, train)
	assert_eq(#calls.alerts, 1)
	assert_eq(calls.alerts[1].player, "online")
	assert_same(calls.alerts[1].entity, loco)
	assert_eq(calls.alerts[1].message, { "cybersyn-messages.depot-broken" })
	assert_eq(calls.alerts[1].show_on_map, true)
	assert_eq(#calls.sounds, 1)
	assert_eq(map_data.active_alerts[7][2], 3)
end)

test("train alert passes extra message parameters through", function()
	local force, calls = fake_force()
	local train = fake_train(force)
	send_alert_train_group_base_schedule_broken({ total_ticks = 0 }, train, "group A")
	assert_eq(calls.alerts[1].message, { "cybersyn-messages.train-group-schedule-broken", "group A" })
end)

test("station alert: one alert per connected player on the stop plus one force sound", function()
	local force, calls = fake_force()
	local stop = { valid = true, force = force, backer_name = "Iron drop" }
	send_alert_station_non_default_priority(stop)
	assert_eq(#calls.alerts, 1)
	assert_same(calls.alerts[1].entity, stop)
	assert_eq(calls.alerts[1].message, { "cybersyn-messages.station-non-default-priority" })
	assert_eq(#calls.sounds, 1)
end)

test("missing-train alert is sent to connected players and removed from every player by its exact message", function()
	local force, calls = fake_force()
	local r_stop = { valid = true, force = force, backer_name = "R" }
	local p_stop = { valid = true, force = force, backer_name = "P" }
	local text = send_alert_about_missing_train(r_stop, p_stop, "cybersyn-messages.missing-train")
	assert_eq(#calls.alerts, 1)
	assert_same(calls.alerts[1].entity, r_stop)
	assert_eq(text, { "cybersyn-messages.missing-train", "R", "P" })
	remove_alert_about_missing_train(r_stop, text)
	assert_eq(#calls.removed, 2)
	for _, r in ipairs(calls.removed) do
		assert_same(r.filter.entity, r_stop)
		assert_same(r.filter.message, text)
	end
end)

test("a train with no stock sends nothing", function()
	send_alert_sounds({ valid = true, carriages = {} })
	send_alert_unexpected_train({ id = 1, valid = true, carriages = {} })
end)
