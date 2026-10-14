local gui = require("__flib__.gui")

local overview_tab = {}

function overview_tab.create()
	return {
		tab = {
			name = "manager_overview_tab",
			type = "tab",
			caption = { "cybersyn-gui.overview" },
		},
		content = {
			name = "manager_overview_content_frame",
			type = "frame",
			style = "ltnm_main_content_frame",
			direction = "vertical",
			{
				type = "label",
				name = "overview_placeholder_label",
				style = "ltnm_semibold_label",
				caption = { "cybersyn-gui.overview-placeholder" },
			},
		},
	}
end

--- @param map_data MapData
--- @param player_data PlayerData
function overview_tab.build(map_data, player_data)
end

overview_tab.handle = {}

--- @param e {player_index: uint}
function overview_tab.wrapper(e, handler)
	local player = game.get_player(e.player_index)
	if not player then return end
	local player_data = storage.manager.players[e.player_index]
	handler(player, player_data, player_data.refs, e)
end

gui.add_handlers(overview_tab.handle, overview_tab.wrapper)

return overview_tab
