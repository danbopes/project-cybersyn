-- PLAN3 phase 9 (§4.11): the Trains detail pane. A row click selects the train and opens a 324 px pane 12 px right of
-- the table, which loses its Shipment column (and on narrow windows more columns, so the status keeps its minimum);
-- the pane holds one camera per player on the front stock and the train panel of relative.lua, whose sections equal
-- the vanilla-window panel's for the same train. On short windows the camera shrinks or goes so the panel body stays
-- readable. The selection survives renders, filters that hide the row and a closed window; Esc, the pane's × and a
-- second click close it, but a GUI or a controller change that replaces the window closes the window instead; a train
-- that loses its entity clears it. The manager tick refreshes the mounted panel.

local D, pi = lab.D, lab.pi
local CLOSE = "manager_trains_pane_close"

local function pane()
	return remote.call(D, "pane_dump", pi)
end

local function trains_dump()
	return remote.call(D, "dump", pi, "trains")
end

local function line(t)
	return serpent.line(t, { comment = false, sortkeys = true })
end

--- Widths by column of a pane_dump's header cells.
local function widths(p)
	local out = {}
	for _, c in ipairs(p.columns) do out[c[1]] = c[2] end
	return out
end

local function front_unit(id)
	local t = lab.read("trains")[id]
	return t and t.entity and t.entity.valid and t.entity.front_stock.unit_number or nil
end

lab.suite("37_trains_pane", {
	function(ctx)
		ctx.planner = settings.global["cybersyn-enable-planner"].value
		lab.dev("set_setting", "cybersyn-enable-planner", false)
		remote.call(D, "open", pi)
		remote.call(D, "clear_filters", pi)
		lab.big_screen(pi)
		remote.call(D, "set_sort", pi, "trains", "train_id", true)
		remote.call(D, "select_tab", pi, "trains")
		remote.call("cybersyn-manager-dev-trains", "set_grouped", pi, false)
		remote.call("cybersyn-manager-dev-trains", "set_chip", pi, "all")
		remote.call(D, "deselect_train", pi)
		for _ = 1, 3 do remote.call(D, "update", pi, 1) end
		local d = trains_dump()
		ctx.ids = d.ids
		lab.check("six trains listed", #d.ids == 6, d.ids)
		local p0 = pane()
		ctx.p0 = p0
		lab.check("closed: no pane, no selection", p0.visible == false and p0.selected == nil and p0.open == nil, p0)
		local layout = remote.call(D, "rows", pi, "trains")
		ctx.content_width = layout.width - 48
		lab.check("closed: the table takes the content width", p0.table_width == ctx.content_width,
			{ p0.table_width, ctx.content_width })
		lab.check("closed: the columns fit the table", p0.columns_total <= p0.table_width, { p0.columns_total, p0.table_width })

		local id = d.ids[2]
		ctx.id = id
		local p = remote.call(D, "select_train", pi, id)
		ctx.p1 = p
		lab.check("select: pane shown for the train", p.visible == true and p.selected == id and p.open and
			p.open.kind == "train" and p.open.id == id, { p.visible, p.selected, p.open })
		lab.check("select: pane 324 px (300 px panel in 12 px insets), 12 px gap", p.width == 324 and p.gap == 12, { p.width, p.gap })
		lab.check("select: the table is 336 px narrower", p.table_width == p0.table_width - 336, { p0.table_width, p.table_width })
		lab.check("select: the columns fill the narrower table", p.columns_total <= p.table_width and
			p.columns_total >= p.table_width - 8, { p.columns_total, p.table_width })
		local w0, w1 = widths(p0), widths(p)
		lab.check("select: the Shipment column goes (the pane shows the cargo), nothing else", w0.shipment and
			w1.shipment == nil and line(p.dropped) == line({ "shipment" }), { w0.shipment, p.dropped })
		local others = true
		for col, w in pairs(w1) do
			if col ~= "train_status" and w ~= w0[col] then others = false end
		end
		lab.check("select: the other fixed columns keep their width, the status takes the rest", others and
			w1.train_status >= 260, { w0, w1 })
		local rows_ok, styles_ok = #p.rows == #d.ids, true
		for i, r in ipairs(p.rows) do
			if r.height ~= 36 or r.id ~= d.ids[i] then rows_ok = false end
			local want = r.id == id and "cybersyn_train_row_selected" or
				(i % 2 == 0 and "cybersyn_train_row_dark" or "cybersyn_train_row_light")
			if r.style ~= want then styles_ok = false end
			if r.shipment_visible ~= false or r.cells ~= p0.rows[i].cells:gsub(",shipment$", "") then rows_ok = false end
		end
		lab.check("select: rows stay whole, same order, their Shipment cells hidden in place", rows_ok, p.rows)
		lab.check("select: only the selected row has the selected style", styles_ok, p.rows)
		local rows = remote.call(D, "rows", pi, "trains")
		lab.check("select: rows measured with the pane (no -1) == rows listed", rows.rendered == #d.ids, rows)
		lab.check("select: the pane is as tall as the header and the window's rows", p.height == 36 + rows.computed * 36,
			{ p.height, rows.computed })
		lab.check("select: camera 300x180 at zoom 0.5 on the front stock", p.camera and p.camera.width == 300 and
			p.camera.height == 180 and p.camera.zoom == 0.5 and p.camera.entity == front_unit(id), p.camera)
		lab.check("select: camera, panel chrome and body fit the pane", p.body_max and p.body_max >= 120 and
			p.fixed + p.camera_gap + p.camera.height + p.body_max <= p.height, { p.body_max, p.height })
		lab.check("select: the panel's own subheader, banner and Open in manager are hidden in the pane",
			p.panel_subheader == false and p.panel_banner == false and p.open_manager == false,
			{ p.panel_subheader, p.panel_banner, p.open_manager })
		lab.check("select: no full rebuild of the rows", trains_dump().last_result ~= "rebuilt", trains_dump().last_result)
	end,

	-- The mounted panel shows what the vanilla-window panel shows for the same train, rendered in the same tick.
	function(ctx)
		local r = remote.call(D, "relative_open", pi, "train", ctx.id)
		remote.call(D, "pane_refresh_ms", pi, 1)
		local p = pane()
		lab.check("pane sections == relative_dump sections", line(p.panel.sections) == line(r.sections),
			{ pane = p.panel.sections, relative = r.sections })
		lab.check("pane caption == relative_dump caption", line(p.panel.caption) == line(r.caption))
		remote.call(D, "relative_close", pi)
		lab.check("closing the vanilla panel keeps the pane", pane().open ~= nil)
		local a, b = pane(), pane()
		lab.check("pane_dump twice identical", line(a) == line(b))
		local before = a.panel.refreshes
		remote.call(D, "tick", 2)
		lab.check("the manager tick refreshes the mounted panel", pane().panel.refreshes == before + 2,
			{ before, pane().panel.refreshes })
		ctx.t0 = game.tick
		lab.wait(120)
	end,

	function(ctx)
		remote.call(D, "update", pi, 2)
		local p = pane()
		lab.check("selection survives updates 2 s later", p.selected == ctx.id and p.visible and
			line(p.rows) == line(ctx.p1.rows) and p.camera.index == ctx.p1.camera.index, { p.selected, p.rows })
		lab.info({ "", "Trains update(pi, 5) with the pane open: ", remote.call(D, "update", pi, 5) })
		lab.info({ "", "pane refresh x20: ", remote.call(D, "pane_refresh_ms", pi, 20) })
		lab.info({ "", "pane refresh, every section rebuilt, x5: ", remote.call(D, "pane_refresh_ms", pi, 5, true) })

		-- A filter that hides the selected train keeps the pane.
		remote.call(D, "set_filter", pi, { query = "#" .. ctx.ids[1] })
		remote.call(D, "update", pi, 1)
		local d = trains_dump()
		p = pane()
		lab.check("a filter that hides the row keeps the pane", #d.ids == 1 and d.ids[1] ~= ctx.id and p.selected == ctx.id and
			p.visible, { d.ids, p.selected })
		remote.call(D, "clear_filters", pi)
		remote.call(D, "update", pi, 1)

		-- Row clicks through the click path of scripts/main.lua.
		local h = remote.call(D, "row_click", pi, 3, { 2, 1 })
		p = pane()
		lab.check("click on a row's status label selects that train", h == "row" and p.selected == ctx.ids[3] and
			p.open.id == ctx.ids[3] and p.camera.entity == front_unit(ctx.ids[3]), { h, p.selected })
		lab.check("one camera per player: reused for the next train", p.camera.index == ctx.p1.camera.index,
			{ p.camera.index, ctx.p1.camera.index })
		h = remote.call(D, "row_click", pi, 4, { 1 }, { right = true })
		lab.check("a click on the id link is the link's, not a selection", h == "handler" and pane().selected == ctx.ids[3], h)
		h = remote.call(D, "row_click", pi, 3, {})
		p = pane()
		lab.check("a second click on the selected row closes the pane", h == "row" and p.selected == nil and
			not p.visible and p.open == nil, { h, p.selected, p.visible })
		lab.check("deselect: the table width and the columns come back", p.table_width == ctx.p0.table_width and
			line(p.columns) == line(ctx.p0.columns), { p.table_width, p.columns })
		local styles = true
		for i, r in ipairs(p.rows) do
			if r.style ~= (i % 2 == 0 and "cybersyn_train_row_dark" or "cybersyn_train_row_light") or
				r.shipment_width ~= ctx.p0.rows[i].shipment_width or r.slots ~= ctx.p0.rows[i].slots or
				r.cells ~= ctx.p0.rows[i].cells then styles = false end
		end
		lab.check("deselect: the rows' stripes, cells and slot tables come back", styles, p.rows)

		-- The pane's ×, and Esc: the pane closes, the window stays.
		remote.call(D, "select_train", pi, ctx.id)
		remote.call(D, "click", pi, CLOSE)
		p = pane()
		lab.check("× closes the pane", p.selected == nil and not p.visible and p.open == nil, p.selected)
		remote.call(D, "select_train", pi, ctx.id)
		local s = remote.call(D, "escape", pi)
		p = pane()
		lab.check("Esc closes the pane, the window stays open", s.is_open and p.selected == nil and not p.visible, { s.is_open, p.selected })
		lab.check("Esc: the window's player.opened waits for a later tick", p.escape_pending == true)
		local left = remote.call(D, "pane_escapes", pi, true)
		s = remote.call(D, "state", pi)
		lab.check("Esc: settled on a later tick with no other GUI, the window stays open", left == nil and s.is_open, { left, s.is_open })
		s = remote.call(D, "escape", pi)
		lab.check("a second Esc closes the window", s.is_open == false, s.is_open)
		remote.call(D, "open", pi)
		remote.call(D, "select_tab", pi, "trains")

		-- on_gui_closed also comes when another GUI replaces the window: then the window closes, as before the pane.
		remote.call(D, "select_train", pi, ctx.id)
		remote.call(D, "escape", pi)
		local station = next(lab.read("stations"))
		s = remote.call(D, "stop_gui_opened", pi, station)
		lab.check("a stop GUI opened in the same tick closes the window, the train stays selected", s.is_open == false and
			pane().selected == ctx.id and pane().escape_pending == false, { s.is_open, pane().selected })
		remote.call(D, "relative_close", pi)
		remote.call(D, "open", pi)
		remote.call(D, "select_tab", pi, "trains")
		remote.call(D, "update", pi, 1)
		p = pane()
		lab.check("reopened after that: the pane is back", p.selected == ctx.id and p.visible and p.open ~= nil, p.selected)
		remote.call(D, "escape", pi)
		s = remote.call(D, "controller_changed", pi)
		lab.check("a controller change after Esc closes the window too", s.is_open == false and pane().selected == ctx.id,
			{ s.is_open, pane().selected })
		remote.call(D, "open", pi)
		remote.call(D, "select_tab", pi, "trains")
		remote.call(D, "deselect_train", pi)

		-- Closed and reopened with a train selected: the pane comes back with its panel.
		remote.call(D, "select_train", pi, ctx.id)
		remote.call(D, "close", pi)
		remote.call(D, "open", pi)
		remote.call(D, "update", pi, 2)
		p = pane()
		lab.check("reopened: the pane shows the selected train again", p.selected == ctx.id and p.visible and p.open and
			p.panel ~= nil, { p.selected, p.visible })
		-- The window rebuilt (/cybersyn-reset-gui): the pane is mounted again.
		remote.call(D, "reset_gui", pi)
		remote.call(D, "open", pi)
		remote.call(D, "select_tab", pi, "trains")
		remote.call(D, "update", pi, 2)
		p = pane()
		lab.check("rebuilt window: pane, camera and panel mounted again", p.visible and p.camera and
			p.camera.entity == front_unit(ctx.id) and p.panel ~= nil and p.panel.refreshes >= 1, { p.visible, p.camera })

		-- A train whose entity is gone clears the selection (the planner is off, so nothing else reads it meanwhile).
		local train = lab.read("trains")[ctx.id]
		remote.call("cybersyn", "write_global", nil, "trains", ctx.id, "entity")
		remote.call(D, "tick", 1)
		remote.call(D, "update", pi, 1)
		p = pane()
		remote.call("cybersyn", "write_global", train.entity, "trains", ctx.id, "entity")
		lab.check("a train that disappears clears the selection and the pane", p.selected == nil and not p.visible and
			p.open == nil, { p.selected, p.visible })
		local sel = remote.call(D, "select_train", pi, 999999)
		lab.check("selecting an unknown train selects nothing", sel.selected == nil and not sel.visible, sel.selected)
		remote.call(D, "update", pi, 1)
		lab.check("deselected: header and rows at full width again", pane().table_width == ctx.p0.table_width)

		remote.call(D, "close", pi)
	end,

	-- Narrow and short windows, which the 4K shots do not cover: the columns fit the narrower table with the status at
	-- its minimum, camera, panel chrome and body fit the pane, rows stay whole; the same with the filter row shown
	-- (the dispatcher is paused throughout, so the tab's banner shows too); grouped rows keep their depot name.
	function(ctx)
		remote.call(D, "open", pi)
		remote.call(D, "select_tab", pi, "trains")
		remote.call(D, "clear_filters", pi)
		local screens = {
			{ "1080p/2.0", 1920, 1080, 2.0 }, { "1080p/1.75", 1920, 1080, 1.75 }, { "1080p/1.5", 1920, 1080, 1.5 },
			{ "1080p/1.25", 1920, 1080, 1.25 }, { "1440p/2.0", 2560, 1440, 2.0 }, { "1440p/1.5", 2560, 1440, 1.5 },
			{ "768p/1.0", 1366, 768, 1.0 },
		}
		local short = {}
		for _, strips in ipairs({ false, true }) do
			if strips then remote.call(D, "set_filter", pi, { network = "signal-A" }) end
			for _, sc in ipairs(screens) do
				remote.call(D, "set_layout", pi, sc[2], sc[3], sc[4])
				remote.call(D, "select_train", pi, ctx.id)
				remote.call(D, "update", pi, 1)
				local p = pane()
				local w = widths(p)
				local name = sc[1] .. (strips and " with the filter row" or "")
				lab.check(name .. ": the columns fit the table and the status keeps 260 px", p.columns_total <= p.table_width and
					(w.train_status or 0) >= 260, { p.columns_total, p.table_width, p.columns, p.dropped })
				local cam = p.camera and p.camera.visible and (p.camera.height + p.camera_gap) or 0
				lab.check(name .. ": camera, panel chrome and body fit the pane", p.visible and p.body_max and p.body_max >= 0 and
					p.fixed + cam + p.body_max <= p.height and (cam == 0 or p.body_max >= 120),
					{ height = p.height, camera = p.camera, body = p.body_max })
				local rows = remote.call(D, "rows", pi, "trains")
				local listed = #trains_dump().ids
				lab.check(name .. ": rows measured with the pane == rows listed", rows.rendered == math.min(rows.computed, listed),
					{ rows, listed })
				short[#short + 1] = name .. " " .. p.height .. "=" .. (cam > 0 and p.camera.height or 0) .. "+" .. p.body_max
			end
		end
		lab.info("pane height = camera + body: " .. table.concat(short, ", "))
		remote.call(D, "clear_filters", pi)
		remote.call(D, "set_layout", pi, 1920, 1080, 1.5)
		remote.call("cybersyn-manager-dev-trains", "set_grouped", pi, true)
		remote.call(D, "select_train", pi, ctx.id)
		remote.call(D, "update", pi, 2)
		local p = pane()
		lab.check("1080p/1.5 grouped: the depot name keeps 120 px, compositions note dropped", p.group and
			p.group.name >= 120 and p.group.comps == false, p.group)
		remote.call("cybersyn-manager-dev-trains", "set_grouped", pi, false)
		remote.call(D, "deselect_train", pi)
		lab.big_screen(pi)
		lab.dev("set_setting", "cybersyn-enable-planner", ctx.planner)
		remote.call(D, "close", pi)
	end,
})
