both_wagon_sprite = {
	type = "sprite",
	name = "cybersyn-both-wagon",
	filename = "__cybersyn-plus__/graphics/icons/both-wagon.png",
	size = 64,
	scale = 0.5,
	flags = { "gui-icon" },
}

-- The Stations tab's inventory-row marker (PLAN8 D8-2): a small muted combinator next to the station name, full colour
-- only on hover, so 2,000 rows do not end in a column of bright red icons. Same mipmapped sheet as the item icon.
combinator_muted_sprite = {
	type = "sprite",
	name = "cybersyn-combinator-muted",
	filename = "__cybersyn-plus__/graphics/icons/cybernetic-combinator-muted.png",
	size = 64,
	mipmap_count = 4,
	flags = { "gui-icon" },
}
