-- In-game checks on the dispatch trace dispatch_trace.lua recorded before any suite ran. run.sh compares the JSON
-- it wrote against tests/baseline/dispatch-trace.json and summary.json after this file.

lab.suite("30_dispatch_trace", {
	function()
		local t = lab.trace
		if not lab.check("recorder ran", t ~= nil) then return end
		lab.check("registered before the window", not t.late, { registered = t.registered, start = t.start })
		lab.check("window finished", t.done == true)
		lab.check("summary baseline written", t.summary_error == nil, t.summary_error)
		lab.check("stimulus scaled combinator values", t.scaled > 0, t.scaled)

		local dispatches, deliveries, by_field = 0, 0, {}
		for _, e in ipairs(t.events) do
			local field, value = e[3], e[4]
			by_field[field] = (by_field[field] or 0) + 1
			if e[1] > t.start then
				if field == "status" and value == 1 then dispatches = dispatches + 1 end
				if field == "status" and value == 5 then deliveries = deliveries + 1 end
			end
		end
		lab.check("trains were dispatched in the window", dispatches > 0, dispatches)
		lab.check("deliveries completed in the window", deliveries > 0, deliveries)
		lab.check("operator loaded and unloaded trains", t.loads > 0 and t.unloads > 0,
			{ loads = t.loads, unloads = t.unloads })
		lab.info(string.format("%d events (%s), %d dispatches, %d completed deliveries, %d loads, %d unloads",
			#t.events, serpent.line(by_field, { comment = false }), dispatches, deliveries, t.loads, t.unloads))
	end,
})
