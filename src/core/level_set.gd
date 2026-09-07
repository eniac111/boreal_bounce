class_name LevelSet
extends RefCounted
## A set of levels in the original Frozen-Bubble text format, which is kept unchanged so
## levelsets are interchangeable with the Perl game and community files.
##
## Format: each level is [constant ROWS] lines; even rows have [constant WIDE] cells, odd rows
## have one fewer and are drawn shifted half a cell to the right. A cell is a colour digit
## 0..7 (index into the bubble images, so "0" is bubble-1.png), "-" for empty, or any other
## token for an unpoppable grey "lose" bubble; cells are separated by whitespace. Levels are
## separated by one or more blank lines. This matches load_levelset() in the original
## bin/frozen-bubble and save_file() in its level editor.

const ROWS := 10
const WIDE := 8
const COLOURS := 8
const EMPTY := -1
const STONE := -2  # the grey bubble_lose bubble: cannot be popped, only dropped
const STONE_TOKEN := "L"

## Array of levels. A level is an Array of ROWS rows; a row is a PackedInt32Array of cells.
var levels: Array = []


static func cells_in_row(row: int) -> int:
	return WIDE if row % 2 == 0 else WIDE - 1


static func cell_to_token(v: int) -> String:
	if v == EMPTY:
		return "-"
	if v == STONE:
		return STONE_TOKEN
	return str(v)


static func empty_level() -> Array:
	var level := []
	for r in ROWS:
		var row := PackedInt32Array()
		row.resize(cells_in_row(r))
		row.fill(EMPTY)
		level.append(row)
	return level


## Parses the text of a levelset file. Returns an error string, or "" on success.
func parse(text: String) -> String:
	levels.clear()
	var block: Array[String] = []
	var errors := PackedStringArray()
	var lines := text.replace("\r\n", "\n").split("\n")
	for line in lines:
		if line.strip_edges() == "":
			if not block.is_empty():
				_add_block(block, errors)
				block = []
		else:
			block.append(line)
	if not block.is_empty():
		_add_block(block, errors)
	return "\n".join(errors)


func _add_block(block: Array[String], errors: PackedStringArray) -> void:
	var index := levels.size()
	var level := empty_level()
	if block.size() != ROWS:
		errors.append("level %d: expected %d rows, got %d" % [index + 1, ROWS, block.size()])
	for r in mini(block.size(), ROWS):
		var tokens := block[r].split(" ", false)
		var expected := cells_in_row(r)
		if tokens.size() != expected:
			errors.append("level %d row %d: expected %d cells, got %d" % [index + 1, r + 1, expected, tokens.size()])
		for c in mini(tokens.size(), expected):
			var t := tokens[c]
			if t == "-":
				level[r][c] = EMPTY
			elif t.is_valid_int():
				if int(t) >= 0 and int(t) < COLOURS:
					level[r][c] = int(t)
				else:
					errors.append("level %d row %d cell %d: bad token '%s'" % [index + 1, r + 1, c + 1, t])
			else:
				level[r][c] = STONE
	levels.append(level)


## Serialises back to the text format (3 spaces between cells, odd rows indented by 2,
## one blank line between levels).
func to_text() -> String:
	var blocks := PackedStringArray()
	for level in levels:
		var rows := PackedStringArray()
		for r in ROWS:
			var row: PackedInt32Array = level[r]
			var cells := PackedStringArray()
			for v in row:
				cells.append(cell_to_token(v))
			rows.append(("  " if r % 2 == 1 else "") + "   ".join(cells))
		blocks.append("\n".join(rows))
	return "\n\n".join(blocks) + "\n"


static func load_file(path: String) -> LevelSet:
	var ls := LevelSet.new()
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		push_error("LevelSet: cannot open " + path)
		return ls
	var err := ls.parse(f.get_as_text())
	if err != "":
		push_warning("LevelSet %s:\n%s" % [path, err])
	return ls


func save_file(path: String) -> Error:
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return FileAccess.get_open_error()
	f.store_string(to_text())
	return OK


## Deep copy of one level (rows are copied so the caller can mutate freely).
func get_level(index: int) -> Array:
	var src: Array = levels[index]
	var copy := []
	for row in src:
		copy.append(PackedInt32Array(row))
	return copy


func size() -> int:
	return levels.size()
