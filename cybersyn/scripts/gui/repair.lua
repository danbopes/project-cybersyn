-- Repair actions of PLAN3 §4.14 (phase 10): the manager's first buttons that change dispatcher or train state. Each
-- runs an existing code path for one entity per click, behind the `cybersyn-manager-actions` rule (checked in the
-- click handler, never trusted from a disabled button), a confirm step, and the audit trail of actions.audit.
--   Fail delivery and send home   on_failed_delivery + the depot schedule (train panel)
--   Recount deliveries            one station's delivery counters from the trains bound to it (stop panel, on the
--                                 counter-leak finding only)
--   Refresh allow-lists           update_train_layout per train, chunked by trains and stop visits (console command)
-- The confirm dialog below served the panel's Recalculate / Refresh tools; PLAN4 D13 took those off the panel.

local gui = require("__flib__.gui")

local util = require("scripts.gui.util")
local logic = require("scripts.gui.extras-logic")
local actions = require("scripts.actions")
local lint = require("scripts.lint")
local dev = require("scripts.gui.dev")

--- @class PlayerData
--- @field confirm ConfirmState? the one armed action button of this player
--- @field action_dialog string? "recalc"|"allow" while the dialog is open

--- @class RepairJob
--- @field ids uint[] train ids at the start, in storage order
--- @field i int done so far
--- @field player_index uint 0 = the console
--- @field started uint tick
--- @field refreshed int
--- @field chunk int? trains per chunk; nil = logic.JOB_CHUNK
--- @field budget int? stop visits per chunk; nil = logic.JOB_STOP_VISITS

local repair = {}
repair.handle = {}

local DIALOG = "cybersyn_action_dialog"

--- @param id uint
--- @return Train?
local function train_record(id)
	local train = storage.trains[id]
	if train and train.entity and train.entity.valid then return train end
	return nil
end

--- Whether the Fail delivery button has something to act on: a train on a delivery.
--- @param id uint
--- @return boolean
function repair.can_fail(id)
	local train = train_record(id)
	return train ~= nil and train.manifest ~= nil and STATUS_ON_DELIVERY[train.status] == true
end

--- Whether Recount deliveries has a station to act on. The combinators too: recount writes comb2's output, and an
--- invalid comb1/comb2 still attached is the state in which on_failed_delivery skips its decrement.
--- @param id uint
--- @return boolean
function repair.can_recount(id)
	local station = storage.stations[id]
	if not (station and station.entity_stop and station.entity_stop.valid) then return false end
	local comb1, comb2 = station.entity_comb1, station.entity_comb2
	return comb1 ~= nil and comb1.valid and (comb2 == nil or comb2.valid)
end

--- Whether the last lint pass still has a counter-leak finding on the station. The click checks it again because the
--- button can outlive the finding until the panel's next refresh.
--- @param id uint
--- @return boolean
function repair.has_leak(id)
	for _, f in ipairs(lint.findings()) do
		if f.id == id and f.subject ~= LINT_SUBJECT_TRAIN and logic.is_counter_leak(f) then return true end
	end
	return false
end

-- ---------------------------------------------------------------- the actions

--- Ends the train's delivery (on_failed_delivery: manifests off both stations, wagon filters cleared, the
--- failure logged) and sends it to its depot, as a train coming back from a requester does.
--- @param train_id uint
--- @return boolean done
--- @return LocalisedString? why not
function repair.fail_delivery(train_id)
	local train = train_record(train_id)
	if not (train and repair.can_fail(train_id)) then return false, { "cybersyn-gui.action-no-delivery" } end
	local depot = train.depot_id and storage.depots[train.depot_id]
	local depot_stop = depot and depot.entity_stop
	if not (depot_stop and depot_stop.valid) then return false, { "cybersyn-gui.action-no-depot" } end
	local old_status = train.status
	on_failed_delivery(storage, train_id, train, DIAG_FAIL_MANUAL)
	set_depot_schedule(train.entity, depot_stop.backer_name)
	train.status = STATUS_TO_D
	interface_raise_train_status_changed(train_id, old_status, STATUS_TO_D)
	return true
end

--- Sets one station's `deliveries_total` and `deliveries` to what the trains bound to it account for (the counter
--- leak of PLAN4 D10: on_failed_delivery skips the decrement while a combinator is invalid), then refreshes what the
--- dispatcher derives from them: the comb2 output and the "deliveries pending" bit of the stop's display.
--- @param station_id uint
--- @return {total: int, deliveries: {[string]: int}}? before nil when the station is gone
--- @return {total: int, deliveries: {[string]: int}, trains: uint[]}? after
function repair.recount(station_id)
	if not repair.can_recount(station_id) then return nil, nil end
	local station = storage.stations[station_id]
	local copy = {}
	for h, n in pairs(station.deliveries or {}) do copy[h] = n end
	local before = { total = station.deliveries_total or 0, deliveries = copy }
	local total, deliveries, ids = logic.recount(storage.trains, station_id, hash_item)
	station.deliveries_total = total
	station.deliveries = deliveries
	set_comb2(storage, station)
	if total == 0 and bit32.band(station.display_state, 1) > 0 then
		station.display_state = station.display_state - 1
		update_display(storage, station)
	elseif total > 0 and bit32.band(station.display_state, 1) == 0 then
		station.display_state = station.display_state + 1
		update_display(storage, station)
	end
	return before, { total = total, deliveries = deliveries, trains = ids }
end

--- @param player LuaPlayer?
function repair.start_allow_job(player)
	local ids = {}
	for id in pairs(storage.trains) do ids[#ids + 1] = id end
	-- The dev override sits in storage, not in a module upvalue: it decides how much game state a tick changes.
	local m = storage.manager
	m.repair_job = { ids = ids, i = 0, player_index = player and player.index or 0, started = game.tick,
		refreshed = 0, chunk = m.repair_job_chunk, budget = m.repair_job_budget }
end

--- One chunk of the Refresh allow-lists job (manager tick, or its own nth handler while manager updates are off).
function repair.job_tick()
	local m = storage.manager
	local job = m and m.repair_job
	if not job then return end
	local total = #job.ids
	local stops = table_size(storage.stations) + table_size(storage.refuelers)
	local counts = storage.layout_train_count
	local k, n, spent = job.i, 0, 0
	while k < total do
		local train = train_record(job.ids[k + 1])
		local cost = train and logic.job_cost((counts[train.layout_id] or 0) <= 1, stops) or 0
		if not logic.job_continue(n, spent, cost, job.chunk, job.budget) then break end
		k = k + 1
		if train then
			update_train_layout(storage, train)
			job.refreshed = job.refreshed + 1
			n = n + 1
			spent = spent + cost
		end
	end
	local done = k >= total
	job.i = k
	job.chunks = (job.chunks or 0) + 1
	job.last_spent = spent
	if done then
		m.repair_job = nil
		m.repair_job_last = { refreshed = job.refreshed, chunks = job.chunks, ticks = game.tick - job.started }
		local player = job.player_index > 0 and game.get_player(job.player_index) or nil
		local text = { "cybersyn-messages.audit-allow-lists-done", tostring(job.refreshed) }
		log({ "", "Cybersyn: refreshed the allow-lists of ", tostring(job.refreshed), " trains" })
		if player and player.valid then player.force.print(text) else game.print(text) end
	end
end

-- ---------------------------------------------------------------- confirm buttons

--- The button for a one-entity action: "Confirm?" in red while armed, disabled with "Admin only" for a player
--- without the right, disabled when there is nothing to act on.
--- @param player LuaPlayer
--- @param pd PlayerData
--- @param name string element name
--- @param key string confirm key
--- @param caption LocalisedString
--- @param tooltip LocalisedString
--- @param handler function
--- @param applicable boolean
--- @param idle_tooltip LocalisedString? tooltip when not applicable
--- @return flib.GuiElemDef
function repair.confirm_button(player, pd, name, key, caption, tooltip, handler, applicable, idle_tooltip)
	local allowed = actions.may_act(player)
	local armed = allowed and applicable and logic.confirm_armed(pd.confirm, key, game.tick)
	return {
		type = "button",
		name = name,
		style = armed and "red_button" or "button",
		style_mods = { minimal_width = 0, left_padding = 8, right_padding = 8 },
		caption = armed and { "cybersyn-gui.action-confirm" } or caption,
		tooltip = not allowed and { "cybersyn-gui.action-admin-only" } or (not applicable and idle_tooltip)
			or (armed and { "cybersyn-gui.action-confirm-tooltip" }) or tooltip,
		enabled = allowed and applicable,
		tags = { action_key = key },
		handler = { [defines.events.on_gui_click] = handler },
	}
end

--- Second footer row of the train panel: `lead` (the pane's Locate), Send home, then `tools` (read-only, extras.lua).
--- @param player LuaPlayer
--- @param pd PlayerData
--- @param train_id uint
--- @param tools flib.GuiElemDef[]?
--- @param lead flib.GuiElemDef?
--- @return flib.GuiElemDef
function repair.train_row(player, pd, train_id, tools, lead)
	local row = {
		type = "flow",
		name = "actions",
		direction = "horizontal",
		style_mods = { vertical_align = "center", horizontal_spacing = 4 },
		repair.confirm_button(player, pd, "fail_delivery", "fail:" .. train_id, { "cybersyn-gui.action-fail-delivery" },
			{ "cybersyn-gui.action-fail-delivery-tooltip" }, repair.handle.repair_fail_click, repair.can_fail(train_id),
			{ "cybersyn-gui.action-no-delivery" }),
		{ type = "empty-widget", style = "flib_horizontal_pusher" },
	}
	for _, def in ipairs(tools or {}) do row[#row + 1] = def end
	if lead then table.insert(row, 1, lead) end
	return row
end

--- The part of a panel footer's signature these rows depend on.
--- @param player LuaPlayer
--- @param pd PlayerData
--- @param kind string
--- @param id uint
--- @return string
function repair.sig(player, pd, kind, id)
	if kind ~= "train" then return "" end
	local armed = logic.confirm_armed(pd.confirm, "fail:" .. id, game.tick)
	return (actions.may_act(player) and "a" or "n") .. (armed and "c" or "") .. (repair.can_fail(id) and "y" or "")
end

--- The Recount deliveries button of the stop panel's counter-leak finding.
--- @param player LuaPlayer
--- @param pd PlayerData
--- @param station_id uint
--- @return flib.GuiElemDef
function repair.recount_button(player, pd, station_id)
	return repair.confirm_button(player, pd, "recount_deliveries", "recount:" .. station_id,
		{ "cybersyn-gui.action-recount" }, { "cybersyn-gui.action-recount-tooltip" }, repair.handle.repair_recount_click,
		repair.can_recount(station_id))
end

--- The part of the stop panel's Setup signature the Recount button depends on.
--- @param player LuaPlayer
--- @param pd PlayerData
--- @param station_id uint
--- @return string
function repair.recount_sig(player, pd, station_id)
	local armed = logic.confirm_armed(pd.confirm, "recount:" .. station_id, game.tick)
	return (actions.may_act(player) and "a" or "n") .. (armed and "c" or "")
end

--- A click on a confirm button: arms it, or on the second click checks the right again and runs `run`.
--- @return boolean fired
local function confirm_click(player, pd, e, what, run)
	local key = e.element.tags.action_key
	if not key then return false end
	if not actions.check(player, what) then
		pd.confirm = nil
		return false
	end
	local state, fire = logic.confirm_click(pd.confirm, key, game.tick)
	pd.confirm = state
	if state then storage.manager.confirm_any = true end
	if fire then run() end
	if repair.on_change then repair.on_change(player, pd) end
	return fire
end
repair.confirm_click = confirm_click

function repair.handle.repair_fail_click(player, pd, e)
	local kind, id = repair.subject(e.element)
	if kind ~= "train" then return end
	confirm_click(player, pd, e, "fail delivery", function()
		local train = train_record(id)
		local front = train and train.entity.front_stock
		local tag = front and ("[train=" .. front.unit_number .. "]") or ("train " .. id)
		local ok, why = repair.fail_delivery(id)
		if not ok then
			util.error_flying_text(player, why)
			return
		end
		actions.audit(ACTION_FAIL_DELIVERY, id, player, { "cybersyn-gui.action-fail-delivery" },
			{ "cybersyn-messages.audit-fail-delivery", player.name, tag }, id, nil)
	end)
end

--- Text of a station's per-item counters for the force line: "iron-plate 400, coal -50" in hash order, or "–".
local function deliveries_text(deliveries)
	local keys = {}
	for h in pairs(deliveries) do keys[#keys + 1] = h end
	table.sort(keys)
	for i, h in ipairs(keys) do keys[i] = h .. " " .. tostring(deliveries[h]) end
	return #keys > 0 and table.concat(keys, ", ") or "–"
end

function repair.handle.repair_recount_click(player, pd, e)
	local kind, id = repair.subject(e.element)
	if kind ~= "stop" then return end
	if not repair.has_leak(id) then
		pd.confirm = nil
		util.error_flying_text(player, { "cybersyn-gui.action-recount-no-leak" })
		return
	end
	confirm_click(player, pd, e, "recount deliveries", function()
		if not repair.has_leak(id) then
			util.error_flying_text(player, { "cybersyn-gui.action-recount-no-leak" })
			return
		end
		local stop = storage.stations[id] and storage.stations[id].entity_stop
		local before, after = repair.recount(id)
		if not (before and after) then
			util.error_flying_text(player, { "cybersyn-message.error-station-is-invalid" })
			return
		end
		local tag = stop and stop.valid and ("[train-stop=" .. stop.unit_number .. "]") or tostring(id)
		actions.audit(ACTION_RECOUNT_DELIVERIES, id, player, { "cybersyn-gui.action-recount" },
			{ "cybersyn-gui.action-recount-done", player.name, tag, tostring(before.total), tostring(after.total),
				deliveries_text(before.deliveries), deliveries_text(after.deliveries) }, nil, id)
	end)
end

-- ---------------------------------------------------------------- dialog (actions on many entities)

--- Gives player.opened back to what the dialog replaced (the manager window or the train's window).
--- @param player LuaPlayer
--- @param ret {window: true?, entity: LuaEntity?}?
local function hand_back(player, pd, ret)
	if not ret or player.opened_gui_type ~= defines.gui_type.none then return end
	if ret.entity then
		if ret.entity.valid then util.switch_opened(player, function() player.opened = ret.entity end) end
	elseif ret.window then
		local window = pd.refs and pd.refs.manager_window
		if pd.is_manager_open and window and window.valid then player.opened = window end
	end
end

--- @param player LuaPlayer
--- @param pd PlayerData?
--- @param restore boolean? give player.opened back to what the dialog replaced (Back, Confirm)
function repair.close_dialog(player, pd, restore)
	local frame = player.gui.screen[DIALOG]
	local ret = pd and pd.dialog_return
	if pd then
		pd.action_dialog = nil
		pd.dialog_return = nil
	end
	-- Cleared before the frame goes: destroying the opened element must find no dialog in on_gui_closed.
	if frame and frame.valid then frame.destroy() end
	if restore and pd then hand_back(player, pd, ret) end
end

--- on_gui_closed of the dialog: Escape, or another GUI replacing it. The dialog closes and what it replaced takes
--- player.opened back; if another GUI was replacing it, the engine drops that again without an event.
--- @param e EventData.on_gui_closed
function repair.on_gui_closed(e)
	local elem = e.element
	if not (elem and elem.valid and elem.name == DIALOG) then return end
	local manager_data = storage.manager
	local pd = manager_data and manager_data.players[e.player_index]
	local player = game.get_player(e.player_index)
	if not (pd and player and pd.action_dialog) then return end
	repair.close_dialog(player, pd, true)
end

local function train_count()
	local n = 0
	for _, train in pairs(storage.trains) do
		if train.entity and train.entity.valid then n = n + 1 end
	end
	return n
end

--- The style-guide confirmation dialog: title bar, the consequence in plain words, Back on the left and Confirm on
--- the right.
--- @param player LuaPlayer
--- @param pd PlayerData
--- @param which "recalc"|"allow"
function repair.open_dialog(player, pd, which)
	repair.close_dialog(player, pd)
	local n = train_count()
	local running = which == "allow" and storage.manager.repair_job ~= nil
	local _, frame = gui.add(player.gui.screen, {
		type = "frame",
		name = DIALOG,
		direction = "vertical",
		tags = { which = which },
		{
			type = "flow",
			style = "flib_titlebar_flow",
			drag_target = DIALOG,
			{ type = "label", style = "frame_title", caption = { "cybersyn-gui.action-dialog-" .. which .. "-title" },
				ignored_by_interaction = true },
			{ type = "empty-widget", style = "flib_dialog_titlebar_drag_handle", ignored_by_interaction = true },
		},
		{
			type = "frame",
			style = "inside_shallow_frame_with_padding",
			direction = "vertical",
			{
				type = "label",
				name = "message",
				caption = running and { "cybersyn-gui.action-dialog-allow-running" }
					or { "cybersyn-gui.action-dialog-" .. which .. "-text", tostring(n) },
				style_mods = { single_line = false, maximal_width = 400 },
			},
		},
		{
			type = "flow",
			style = "dialog_buttons_horizontal_flow",
			{
				type = "button",
				name = "back",
				style = "back_button",
				caption = { "cybersyn-gui.action-back" },
				handler = { [defines.events.on_gui_click] = repair.handle.repair_dialog_back },
			},
			{ type = "empty-widget", name = "drag", style = "flib_dialog_footer_drag_handle" },
			{
				type = "button",
				name = "confirm",
				style = "confirm_button",
				caption = { "cybersyn-gui.action-confirm-button" },
				enabled = not running,
				handler = { [defines.events.on_gui_click] = repair.handle.repair_dialog_confirm },
			},
		},
	})
	frame.children[1].drag_target = frame
	frame.children[3].drag.drag_target = frame
	frame.force_auto_center()
	pd.action_dialog = which
	-- Modal, as the style guide's dialogs are: player.opened, so Escape closes it; what it replaces gets player.opened
	-- back when it closes.
	local opened = player.opened
	local window = pd.refs and pd.refs.manager_window
	local ret
	if window and window.valid and opened == window then
		ret = { window = true }
	elseif player.opened_gui_type == defines.gui_type.entity and opened and opened.valid then
		ret = { entity = opened }
	end
	pd.dialog_return = ret
	util.switch_opened(player, function() player.opened = frame end)
end

function repair.handle.repair_dialog_back(player, pd)
	repair.close_dialog(player, pd, true)
end

--- Runs the dialog's action; the right is checked again here, in the handler that changes state.
function repair.dialog_confirm(player, pd)
	local which = pd.action_dialog
	repair.close_dialog(player, pd, true)
	if which == "recalc" then
		if not actions.check(player, "recalculate train sizes") then return false end
		retrigger_train_calculation(false)
		actions.audit(ACTION_RECALCULATE_TRAIN_SIZE, nil, player, { "cybersyn-diag.action-recalculate-train-size" },
			{ "cybersyn-messages.audit-recalc", player.name, tostring(train_count()) })
		return true
	elseif which == "allow" then
		if not actions.check(player, "refresh allow-lists") then return false end
		if storage.manager.repair_job then return false end
		repair.start_allow_job(player)
		actions.audit(ACTION_REFRESH_ALLOW_LISTS, nil, player, { "cybersyn-diag.action-refresh-allow-lists" },
			{ "cybersyn-messages.audit-allow-lists", player.name, tostring(#storage.manager.repair_job.ids) })
		return true
	end
	return false
end

function repair.handle.repair_dialog_confirm(player, pd)
	repair.dialog_confirm(player, pd)
end

-- ---------------------------------------------------------------- tick, wiring

--- Manager tick: armed buttons expire (the panels re-render on the same tick), and the allow-list job advances.
--- @param manager_data Manager
function repair.tick(manager_data)
	repair.expire(manager_data)
	repair.job_tick()
end

--- Redraws expired confirm buttons, and drops their state once the click grace (logic.CONFIRM_GRACE) is over too. Also
--- called on the fixed export tick, so a "Confirm?" goes back within a few ticks of its expiry whatever the manager's
--- update rate (with updates at 0 too); free while no player has a button armed.
--- @param manager_data Manager
function repair.expire(manager_data)
	if not manager_data.confirm_any then return end
	local now = game.tick
	local any
	for i, pd in pairs(manager_data.players) do
		local cur = pd.confirm
		if cur then
			if logic.confirm_gone(cur, now) then
				pd.confirm = nil
			else
				any = true
				if not cur.redrawn and logic.confirm_expired(cur, now) then
					cur.redrawn = true
					local player = repair.on_change and game.get_player(i)
					if player then repair.on_change(player, pd) end
				end
			end
		end
	end
	manager_data.confirm_any = any
end

--- The panel subject of a clicked element; set by extras (relative.build's frame tags).
--- @type fun(elem: LuaGuiElement): string?, uint?
repair.subject = function() return nil, nil end

repair.wrapper = util.wrapper_pd

gui.add_handlers(repair.handle, repair.wrapper, "cybersyn_repair")

--- /cybersyn-refresh-allow-lists: the allow-list job the train panel's tool used to start, behind the same right.
--- @param command CustomCommandData
function repair.allow_lists_command(command)
	local player = command.player_index and game.get_player(command.player_index) or nil
	if not actions.check(player, "/" .. command.name) then return end
	if not storage.manager then return end
	if storage.manager.repair_job then
		local text = { "cybersyn-gui.action-dialog-allow-running" }
		if player then player.print(text) else game.print(text) end
		return
	end
	repair.start_allow_job(player)
	local name = player and player.name or "server"
	actions.audit(ACTION_REFRESH_ALLOW_LISTS, nil, player, "/" .. command.name,
		{ "cybersyn-messages.audit-allow-lists", name, tostring(#storage.manager.repair_job.ids) })
end

-- In the console commands' table too (scripts/commands.lua, loaded first in control.lua; the host unit harness loads
-- this module alone), where the dev interface's run_command finds it.
if cybersyn_command_handlers then cybersyn_command_handlers["cybersyn-refresh-allow-lists"] = repair.allow_lists_command end
commands.add_command("cybersyn-refresh-allow-lists", { "cybersyn-gui.action-allow-command-help" },
	repair.allow_lists_command)

-- ---------------------------------------------------------------- dev interface

local function dev_context(pi)
	local player = game.get_player(pi)
	if not player then error("no player " .. tostring(pi)) end
	local pd = storage.manager.players[pi]
	if not pd then error("no manager data for player " .. tostring(pi)) end
	return player, pd
end

--- A click on a confirm button of the relative panel the player has open, through the real handler.
local function click_named(pi, name, force)
	local player, pd = dev_context(pi)
	local open = pd.relative_open
	if not open then return { error = "no panel open" } end
	local mount = open.kind == "train" and player.gui.screen.cybersyn_relative_train or player.gui.relative.cybersyn_relative_stop
	local panel = mount and mount.cybersyn_relative_panel
	if not panel then return { error = "no panel" } end
	local found
	local function walk(elem)
		if found then return end
		if elem.name == name then
			found = elem
			return
		end
		for _, c in ipairs(elem.children) do walk(c) end
	end
	walk(panel)
	if not found then return { error = "no element " .. name } end
	local before = { caption = found.caption, enabled = found.enabled, style = found.style.name, tooltip = found.tooltip }
	-- force: click a disabled button too, as a modified client could; the handler must refuse on its own.
	if found.enabled or force then
		gui.dispatch({ name = defines.events.on_gui_click, element = found, player_index = pi, tick = game.tick,
			button = defines.mouse_button_type.left, shift = false, control = false, alt = false })
	end
	return { before = before, confirm = pd.confirm }
end

dev.extend({
	action_click = click_named,
	--- The state of a named action element in the open panel: caption, style, enabled, tooltip.
	action_button = function(pi, name)
		local player, pd = dev_context(pi)
		local open = pd.relative_open
		if not open then return nil end
		local mount = open.kind == "train" and player.gui.screen.cybersyn_relative_train or player.gui.relative.cybersyn_relative_stop
		local found
		local function walk(elem)
			if found then return end
			if elem.name == name then found = elem return end
			for _, c in ipairs(elem.children) do walk(c) end
		end
		if mount then walk(mount) end
		if not found then return nil end
		return { caption = found.caption, enabled = found.enabled, style = found.style.name, tooltip = found.tooltip }
	end,
	--- The dialog's Back button through its handler.
	action_dialog_back = function(pi)
		local player, pd = dev_context(pi)
		repair.handle.repair_dialog_back(player, pd)
		return pd.action_dialog == nil
	end,
	action_dialog = function(pi, which, confirm)
		local player, pd = dev_context(pi)
		if which then
			if not actions.check(player, which) then return { refused = true } end
			repair.open_dialog(player, pd, which)
		end
		local frame = player.gui.screen[DIALOG]
		local out = { open = frame ~= nil and frame.valid, which = pd.action_dialog }
		if frame and frame.valid then
			out.buttons = { frame.children[3].children[1].name, frame.children[3].children[3].name }
			out.text = frame.children[2].message.caption
		end
		if confirm then out.ran = repair.dialog_confirm(player, pd) end
		return out
	end,
	--- Overrides for the next job: trains and stop visits per chunk (nil = the defaults).
	repair_job_chunk = function(n, budget)
		storage.manager.repair_job_chunk = n
		storage.manager.repair_job_budget = budget
	end,
	repair_job = function(step)
		if step then repair.job_tick() end
		local job = storage.manager.repair_job
		return { running = job ~= nil, i = job and job.i, total = job and #job.ids, last = storage.manager.repair_job_last,
			spent = job and job.last_spent }
	end,
	--- Starts the allow-list job as the console would and runs it to the end with one profiler per chunk. Returns the
	--- chunk times in ms, the trains per chunk and the singleton-layout trains seen at the start.
	repair_job_profile = function()
		if storage.manager.repair_job then return { error = "job running" } end
		local singles = 0
		for _, train in pairs(storage.trains) do
			if (storage.layout_train_count[train.layout_id] or 0) <= 1 then singles = singles + 1 end
		end
		repair.start_allow_job(nil)
		local total = #storage.manager.repair_job.ids
		local out, trains = {}, {}
		while storage.manager.repair_job do
			local before = storage.manager.repair_job.i
			local p = game.create_profiler()
			repair.job_tick()
			p.stop()
			out[#out + 1] = p
			local job = storage.manager.repair_job
			trains[#trains + 1] = (job and job.i or total) - before
		end
		return { profilers = out, trains = trains, singletons = singles, last = storage.manager.repair_job_last }
	end,
	set_admin = function(pi, admin)
		local player = game.get_player(pi)
		player.admin = admin
		return player.admin
	end,
	may_act = function(pi)
		return actions.may_act(game.get_player(pi))
	end,
	--- The last audit line; `clear` forgets it (to see that a later action writes one).
	last_audit = function(clear)
		local line = actions.last_line
		if clear then actions.last_line = nil end
		return line
	end,
})

return repair
