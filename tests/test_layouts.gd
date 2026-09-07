extends TestCase


func test_playfield_widths_are_eight_bubbles() -> void:
	for layout in [Layouts.POS_1P, Layouts.POS_2P, Layouts.POS_MP]:
		for key in layout:
			var v = layout[key]
			if v is Dictionary and v.has("left_limit"):
				var width: int = v["right_limit"] - v["left_limit"]
				var size: int = 32 if key in ["p1", "p2"] else 16
				assert_eq(width, 8 * size, "%s width" % key)


func test_1p_values() -> void:
	assert_eq(Layouts.POS_1P["p1"]["top_limit"], 44)
	assert_eq(Layouts.POS_1P["p1"]["initial_bubble_y"], 390)
	assert_eq(Layouts.POS_1P["compressor_xpos"], 318)
	assert_eq(Layouts.POS_MP["rp4"]["canon"]["x"], 531)
