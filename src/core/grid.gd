class_name Grid
extends RefCounted
## The hexagonal-offset bubble grid of one playfield.
##
## Row [code]cy[/code] holds 8 cells when [code](cy + oddswap) % 2 == 0[/code] and 7 cells,
## drawn shifted half a bubble to the right, otherwise. [member oddswap] flips whenever a new
## root row is pushed in at the top, exactly like [code]$pdata{$player}{oddswap}[/code] in the
## original. Rows are unbounded downwards (a bubble may stick below the last level row; the
## lose rule lives in the simulation), so rows are created on demand.
## Cells hold a colour 0..7, [constant LevelSet.STONE], or [constant LevelSet.EMPTY].

const EMPTY := LevelSet.EMPTY
const STONE := LevelSet.STONE
const WIDE := LevelSet.WIDE

var rows: Array[PackedInt32Array] = []
var oddswap := 0


func _init(level: Array = []) -> void:
	load_level(level)


func load_level(level: Array) -> void:
	rows.clear()
	oddswap = 0
	for r in level:
		rows.append(PackedInt32Array(r))


func is_offset_row(cy: int) -> bool:
	return (cy + oddswap) % 2 == 1


func cells_in_row(cy: int) -> int:
	return WIDE - 1 if is_offset_row(cy) else WIDE


func in_bounds(cx: int, cy: int) -> bool:
	return cy >= 0 and cx >= 0 and cx < cells_in_row(cy)


func _ensure_row(cy: int) -> void:
	while rows.size() <= cy:
		var row := PackedInt32Array()
		row.resize(cells_in_row(rows.size()))
		row.fill(EMPTY)
		rows.append(row)


func get_cell(cx: int, cy: int) -> int:
	if cy < 0 or cy >= rows.size() or cx < 0 or cx >= rows[cy].size():
		return EMPTY
	return rows[cy][cx]


func set_cell(cx: int, cy: int, value: int) -> void:
	_ensure_row(cy)
	rows[cy][cx] = value


func is_empty(cx: int, cy: int) -> bool:
	return get_cell(cx, cy) == EMPTY


func count() -> int:
	var n := 0
	for row in rows:
		for v in row:
			if v != EMPTY:
				n += 1
	return n


## Lowest row index that contains a bubble, or -1 when the grid is empty.
func lowest_row() -> int:
	for cy in range(rows.size() - 1, -1, -1):
		for v in rows[cy]:
			if v != EMPTY:
				return cy
	return -1


## The up-to-six neighbouring cells of (cx, cy), in bounds only.
func neighbours(cx: int, cy: int) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	var d := 1 if is_offset_row(cy) else 0
	var candidates := [
		Vector2i(cx - 1, cy), Vector2i(cx + 1, cy),
		Vector2i(cx - 1 + d, cy - 1), Vector2i(cx + d, cy - 1),
		Vector2i(cx - 1 + d, cy + 1), Vector2i(cx + d, cy + 1),
	]
	for c in candidates:
		if in_bounds(c.x, c.y):
			out.append(c)
	return out


## All cells connected to (cx, cy) through bubbles of the same colour, including itself.
## Stones and empties never join a group.
func group_of(cx: int, cy: int) -> Array[Vector2i]:
	var colour := get_cell(cx, cy)
	var result: Array[Vector2i] = []
	if colour == EMPTY or colour == STONE:
		return result
	var seen := {}
	var stack: Array[Vector2i] = [Vector2i(cx, cy)]
	seen[Vector2i(cx, cy)] = true
	while not stack.is_empty():
		var c: Vector2i = stack.pop_back()
		result.append(c)
		for n in neighbours(c.x, c.y):
			if not seen.has(n) and get_cell(n.x, n.y) == colour:
				seen[n] = true
				stack.append(n)
	return result


## Bubbles (any colour or stone) not connected to the ceiling row [param root_row] through
## other bubbles. In 1p the ceiling row moves down as the compressor advances.
func orphans(root_row := 0) -> Array[Vector2i]:
	var attached := {}
	var stack: Array[Vector2i] = []
	if root_row < rows.size():
		for cx in rows[root_row].size():
			if rows[root_row][cx] != EMPTY:
				var c := Vector2i(cx, root_row)
				attached[c] = true
				stack.append(c)
	while not stack.is_empty():
		var c: Vector2i = stack.pop_back()
		for n in neighbours(c.x, c.y):
			if not attached.has(n) and get_cell(n.x, n.y) != EMPTY:
				attached[n] = true
				stack.append(n)
	var out: Array[Vector2i] = []
	for cy in rows.size():
		for cx in rows[cy].size():
			if rows[cy][cx] != EMPTY and not attached.has(Vector2i(cx, cy)):
				out.append(Vector2i(cx, cy))
	return out


func remove(cells: Array[Vector2i]) -> void:
	for c in cells:
		rows[c.y][c.x] = EMPTY


## Inserts a new top row (a "new root" in the original) and shifts everything down.
## The new row's width follows the flipped parity so existing rows keep their offsets.
func push_root_row(colours: PackedInt32Array) -> void:
	oddswap = 1 - oddswap
	var row := PackedInt32Array()
	row.resize(cells_in_row(0))
	row.fill(EMPTY)
	for i in mini(colours.size(), row.size()):
		row[i] = colours[i]
	rows.insert(0, row)


func duplicate_grid() -> Grid:
	var g := Grid.new()
	g.oddswap = oddswap
	for r in rows:
		g.rows.append(PackedInt32Array(r))
	return g


## Compact text form for debugging and golden tests ("." empty, "#" stone, digit colour).
func to_debug_string() -> String:
	var lines := PackedStringArray()
	for cy in lowest_row() + 1:  # trailing empty rows are not part of the state
		var line := " " if is_offset_row(cy) else ""
		for v in rows[cy]:
			line += (". " if v == EMPTY else ("# " if v == STONE else str(v) + " "))
		lines.append(line.rstrip(" "))
	return "\n".join(lines)
