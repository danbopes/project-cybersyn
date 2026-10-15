-- The aitest smoke suite and the GUI event dispatch table. aitest's "a built station reaches the economy" builds a
-- station on nauvis; it is torn down again afterwards so the later suites see the save's own 30 stations.

lab.suite("10_smoke", {
	function(ctx)
		local surface = game.surfaces[1]
		local area = { { -48, -14 }, { 48, 6 } }
		local before = {}
		for _, e in ipairs(surface.find_entities_filtered({ area = area })) do
			if e.unit_number then before[e.unit_number] = true end
		end

		local ok, raw = pcall(remote.call, "aitest", "run_all")
		if not lab.check("aitest run_all returns", ok, raw) then return end
		local result = helpers.json_to_table(raw)
		if not lab.check("aitest result parses", type(result) == "table", raw) then return end
		lab.check("aitest ran tests", (result.passed or 0) + (result.failed or 0) > 0, raw)
		for _, t in ipairs(result.tests or {}) do
			lab.check("aitest " .. t.name, t.ok, t.error)
		end
		lab.check("aitest failed count is 0", result.failed == 0, result.failed)

		local removed = 0
		for _, e in ipairs(surface.find_entities_filtered({ area = area })) do
			if e.valid and e.unit_number and not before[e.unit_number] and e.type ~= "character" then
				e.destroy({ raise_destroy = true })
				removed = removed + 1
			end
		end
		lab.info("removed " .. removed .. " aitest entities")
		local stations = lab.count(lab.read("stations"))
		lab.check("aitest station torn down (30 stations)", stations == 30, stations)
	end,
	function()
		local d = lab.dev("check_dispatch")
		for _, name in ipairs({ "on_gui_hover", "on_gui_leave", "on_gui_selected_tab_changed", "on_gui_click",
			"on_player_left_game" }) do
			lab.check("check_dispatch " .. name, d[name] == true, d)
		end
		for name, v in pairs(d) do
			if v ~= true then lab.check("check_dispatch " .. name, false, v) end
		end
	end,
})
