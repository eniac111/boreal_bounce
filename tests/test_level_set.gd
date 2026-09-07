extends TestCase

const SAMPLE := """6   6   4   4   2   2   3   3
  6   6   4   4   2   2   3
2   2   3   3   6   6   4   4
  2   3   3   6   6   4   4
-   -   -   -   -   -   -   -
  -   -   -   -   -   -   -
-   -   -   -   -   -   -   -
  -   -   -   -   -   -   -
-   -   -   -   -   -   -   -
  -   -   -   -   -   -   -

-   7   7   7   7   7   7   -
  -   -   -   -   -   -   -
-   -   -   -   -   -   -   -
  -   -   -   -   -   -   -
-   -   -   -   -   -   -   -
  -   -   -   -   -   -   -
-   -   -   -   -   -   -   -
  -   -   -   -   -   -   -
-   -   -   -   -   -   -   -
  -   -   -   -   -   -   -
"""


func test_parse_sample() -> void:
	var ls := LevelSet.new()
	assert_eq(ls.parse(SAMPLE), "", "no parse errors")
	assert_eq(ls.size(), 2)
	var lvl: Array = ls.get_level(0)
	assert_eq(lvl.size(), 10)
	assert_eq(lvl[0].size(), 8)
	assert_eq(lvl[1].size(), 7)
	assert_eq(lvl[0][0], 6, "digit 6 is colour index 6 (bubble-7.png)")
	assert_eq(lvl[3][0], 2)
	assert_eq(lvl[4][0], LevelSet.EMPTY)
	var lvl2: Array = ls.get_level(1)
	assert_eq(lvl2[0][0], LevelSet.EMPTY)
	assert_eq(lvl2[0][1], 7)


func test_roundtrip() -> void:
	var ls := LevelSet.new()
	ls.parse(SAMPLE)
	var text := ls.to_text()
	var ls2 := LevelSet.new()
	assert_eq(ls2.parse(text), "")
	assert_eq(ls2.levels, ls.levels, "roundtrip preserves levels")
	assert_eq(text, SAMPLE, "writer reproduces the original layout")


func test_errors_reported() -> void:
	var ls := LevelSet.new()
	var err := ls.parse("1 2 3\n")
	assert_true(err.contains("expected 10 rows"), "row count error: " + err)
	assert_true(err.contains("expected 8 cells"), "cell count error: " + err)
	var bad := ls.parse(_level_text("8   -   -   -   -   -   -   -"))
	assert_true(bad.contains("bad token '8'"), bad)
	assert_false(bad.contains("expected 8 cells"), "no cell-count error: " + bad)


func test_stone_token() -> void:
	var ls := LevelSet.new()
	var err := ls.parse(_level_text("L   0   -   -   -   -   -   -"))
	assert_eq(err, "")
	assert_eq(ls.levels[0][0][0], LevelSet.STONE)
	assert_eq(ls.levels[0][0][1], 0)
	assert_true(ls.to_text().begins_with("L   0   -"), ls.to_text())


func test_default_levelset_file() -> void:
	var ls := LevelSet.load_file("res://assets/levels/default-levelset.lvl")
	assert_eq(ls.size(), 100, "the original ships 100 levels")
	for level in ls.levels:
		for r in LevelSet.ROWS:
			assert_eq(level[r].size(), LevelSet.cells_in_row(r))


func test_get_level_is_a_copy() -> void:
	var ls := LevelSet.new()
	ls.parse(SAMPLE)
	var lvl: Array = ls.get_level(0)
	lvl[0][0] = 0
	assert_eq(ls.levels[0][0][0], 6, "mutating the copy does not touch the set")


## Builds a 10-row level text from the given first row, remaining rows empty.
func _level_text(first_row: String) -> String:
	var rows := PackedStringArray([first_row])
	for r in range(1, LevelSet.ROWS):
		var cells := PackedStringArray()
		cells.resize(LevelSet.cells_in_row(r))
		cells.fill("-")
		rows.append(("  " if r % 2 == 1 else "") + "   ".join(cells))
	return "\n".join(rows) + "\n"
