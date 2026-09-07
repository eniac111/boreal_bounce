extends TestCase

const T := """0   0   1   -   -   -   -   -
  0   1   -   -   -   -   -
2   -   -   -   -   -   -   -
  -   -   -   -   -   -   -
-   -   -   -   -   -   -   -
  -   -   -   -   -   -   -
-   -   -   -   -   -   -   -
  -   -   -   -   -   -   -
-   -   -   -   -   -   -   -
  -   -   -   -   -   -   -
"""


func _grid() -> Grid:
	var ls := LevelSet.new()
	assert_eq(ls.parse(T), "")
	return Grid.new(ls.get_level(0))


func test_row_widths_and_neighbours() -> void:
	var g := _grid()
	assert_eq(g.cells_in_row(0), 8)
	assert_eq(g.cells_in_row(1), 7)
	# offset row cell (0,1) touches (0,0),(1,0) above and (0,2),(1,2) below, plus (1,1)
	var n := g.neighbours(0, 1)
	assert_eq(n.size(), 5)
	for c in [Vector2i(1, 1), Vector2i(0, 0), Vector2i(1, 0), Vector2i(0, 2), Vector2i(1, 2)]:
		assert_true(c in n, "neighbour %s" % c)
	# wide row cell (0,0): only (1,0) and (0,1) below (nothing above, nothing at -1)
	var n0 := g.neighbours(0, 0)
	assert_eq(n0.size(), 2)
	assert_true(Vector2i(1, 0) in n0 and Vector2i(0, 1) in n0)
	# wide row cell (3,2): above (2,1),(3,1)
	var n3 := g.neighbours(3, 2)
	assert_true(Vector2i(2, 1) in n3 and Vector2i(3, 1) in n3 and Vector2i(2, 3) in n3 and Vector2i(3, 3) in n3)


func test_group_detection() -> void:
	var g := _grid()
	var grp := g.group_of(0, 0)
	assert_eq(grp.size(), 3, "three connected 0-colour bubbles")
	assert_eq(g.group_of(2, 0).size(), 2, "the two 1s touch: (2,0) and (1,1)")
	assert_eq(g.group_of(0, 2).size(), 1)
	assert_eq(g.group_of(5, 5).size(), 0, "empty cell has no group")


func test_orphans_after_removal() -> void:
	var g := _grid()
	assert_eq(g.orphans().size(), 0, "everything hangs from the top row")
	g.remove(g.group_of(0, 0))
	var orphans := g.orphans()
	# (2,0) and (1,1) are colour 1 and still attached via (2,0) in the top row; (0,2) hangs
	# from (0,1) which is gone -> orphan
	assert_eq(orphans.size(), 1)
	assert_eq(orphans[0], Vector2i(0, 2))


func test_push_root_row_flips_parity() -> void:
	var g := _grid()
	g.push_root_row(PackedInt32Array([5, 5, 5, 5, 5, 5, 5]))
	assert_eq(g.oddswap, 1)
	assert_eq(g.cells_in_row(0), 7, "new top row is the offset one")
	assert_eq(g.cells_in_row(1), 8, "old row 0 keeps 8 cells")
	assert_eq(g.get_cell(0, 1), 0, "old content shifted down")
	assert_eq(g.rows[1].size(), 8)
	assert_eq(g.count(), 6 + 7)


func test_rows_grow_on_demand_and_lowest_row() -> void:
	var g := _grid()
	assert_eq(g.lowest_row(), 2)
	g.set_cell(3, 12, 4)
	assert_eq(g.rows.size(), 13)
	assert_eq(g.get_cell(3, 12), 4)
	assert_eq(g.lowest_row(), 12)
	assert_eq(g.cells_in_row(12), 8)
	assert_eq(g.get_cell(7, 11), Grid.EMPTY)
	assert_false(g.in_bounds(7, 11), "offset rows have 7 cells")


func test_stone_is_never_grouped_but_is_attached() -> void:
	var g := _grid()
	g.set_cell(4, 0, Grid.STONE)
	assert_eq(g.group_of(4, 0).size(), 0)
	g.set_cell(4, 1, 3)
	assert_eq(g.orphans().size(), 0, "colour hanging from a stone is attached")
