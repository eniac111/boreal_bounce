extends TestCase


func test_sfont_conversion_loads_as_font() -> void:
	for name in ["editor", "editor_hi", "editor_alt"]:
		var font = load("res://assets/fonts/bitmap/%s.fnt" % name)
		assert_true(font is Font, name + " loads as a Font")
		if font is Font:
			assert_true(font.has_char("A".unicode_at(0)), name + " has A")
			assert_true(font.has_char("a".unicode_at(0)), name + " aliases lowercase")
			assert_true(font.has_char("!".unicode_at(0)), name + " has !")
			var w: float = font.get_string_size("LEVEL", HORIZONTAL_ALIGNMENT_LEFT, -1, 38).x
			assert_true(w > 40.0 and w < 200.0, "%s width of LEVEL = %s" % [name, w])
