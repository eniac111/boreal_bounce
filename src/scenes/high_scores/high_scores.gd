extends Node2D
## High-score screens (display_highscores, bin/frozen-bubble:3045-3163).
## Page 1: ten level previews (the board at 1/4 scale in an 81x100 frame) on a 5x2 grid with
## name / level / time under each. Page 2 (only when a training table has entries): two
## 20-row columns, "Regular" and "Chain-reaction enabled". Escape returns to the menu;
## any other key turns the page.

const COLS_X := [90, 188, 286, 384, 482]
const ROWS_Y := [68, 243]
const BOARD_RECT := Rect2(188, 44, 256, 336)  # playfield area of back_one_player.png
const SCALE := 0.25

var scores: HighScores
var page := 1
var _levelset: LevelSet
var _items: Node2D


func _ready() -> void:
	$Background.texture = Art.tex("res://assets/gfx/back_hiscores.png")
	scores = HighScores.load_from()
	if Session.fake_scores:
		_fill_fake()
	_levelset = LevelSet.load_file(Session.levelset_path)
	_items = Node2D.new()
	add_child(_items)
	if Session.scores_page == 2 and not (scores.training.is_empty() and scores.training_chain.is_empty()):
		_show_training()
	else:
		_show_levels()
	Session.scores_page = 1


func _fill_fake() -> void:
	for i in 10:
		scores.add_levels(["Ana", "Blago", "Chen", "Dee", "Eli"][i % 5], 100 - i * 9, i == 0, 600.0 + i * 37.5)
	for i in 6:
		scores.add_training("player%d" % i, 120 - i * 13, i % 2 == 0)


func _clear() -> void:
	for c in _items.get_children():
		c.queue_free()


func _show_levels() -> void:
	page = 1
	_clear()
	_title(tr("High scores: levels"))
	var board_tex: Texture2D = Art.tex("res://assets/gfx/back_one_player.png")
	for i in mini(scores.levels.size(), 10):
		var entry: Dictionary = scores.levels[i]
		var x: int = COLS_X[i % 5]
		var y: int = ROWS_Y[i / 5]
		var frame := Sprite2D.new()
		frame.centered = false
		frame.texture = Art.tex("res://assets/gfx/hiscore_frame.png")
		frame.position = Vector2(x - 7, y - 6)
		_items.add_child(frame)
		var preview := LevelPreview.new()
		preview.position = Vector2(x, y)
		preview.board = board_tex
		preview.level = _level_for(entry)
		_items.add_child(preview)
		var bold := i == Session.new_entry
		_centered(x - 15, y + 92, str(entry["name"]), bold)
		_centered(x - 15, y + 112, tr("won!") if entry.get("won", false) else tr("level %s") % str(entry["level"]), bold)
		var t := int(entry["time"])
		_centered(x - 15, y + 132, "%d'%02d\"" % [t / 60, t % 60], bold)


func _title(text: String) -> void:
	var l := UiText.funky(text, 22, Color(0.95, 0.95, 1.0), Color(0.25, 0.1, 0.05))
	l.position = Vector2(20, 6)
	l.size = Vector2(600, 32)
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_items.add_child(l)


func _level_for(entry: Dictionary) -> Array:
	var index := _levelset.size() - 1 if entry.get("won", false) else clampi(int(entry["level"]) - 1, 0, _levelset.size() - 1)
	return _levelset.get_level(index) if _levelset.size() > 0 else LevelSet.empty_level()


func _centered(x: float, y: float, text: String, bold := false) -> void:
	var l := UiText.make(text, 12, Color.WHITE, bold)
	l.position = Vector2(x, y)
	l.size = Vector2(93, 16)
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_items.add_child(l)


func _show_training() -> void:
	page = 2
	_clear()
	_title(tr("High scores: multiplayer training"))
	_column(0, tr("Regular"), 80, 120, scores.training)
	_column(320, tr("Chain-reaction enabled"), 420, 460, scores.training_chain)


func _column(x0: float, header: String, rank_x: float, name_x: float, table: Array) -> void:
	var h := UiText.make(header, 13)
	h.position = Vector2(x0, 50)
	h.size = Vector2(320, 18)
	h.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_items.add_child(h)
	var y := 80.0
	var last_score := -1
	for i in mini(table.size(), 20):
		var e: Dictionary = table[i]
		if int(e["score"]) != last_score:
			var r := UiText.make("%d. " % (i + 1), 13)
			r.position = Vector2(rank_x, y)
			r.size = Vector2(40, 18)
			r.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
			_items.add_child(r)
		last_score = int(e["score"])
		var n := UiText.make("%s: %s" % [e["name"], e["score"]], 13)
		n.position = Vector2(name_x, y)
		n.size = Vector2(150, 18)
		_items.add_child(n)
		y += 18


func _unhandled_input(event: InputEvent) -> void:
	if not (event is InputEventKey) or not event.pressed or event.echo:
		return
	var key := (event as InputEventKey).keycode
	if key == KEY_ESCAPE or page == 2 or (scores.training.is_empty() and scores.training_chain.is_empty()):
		Session.new_entry = -1
		Screens.goto(Screens.MENU)
	else:
		_show_training()


## Draws one level at 1/4 scale over the shrunken playfield background.
class LevelPreview extends Node2D:
	var board: Texture2D
	var level: Array = []

	func _draw() -> void:
		draw_texture_rect_region(board, Rect2(Vector2.ZERO, BOARD_RECT.size * SCALE), BOARD_RECT)
		var size: float = Layouts.BUBBLE_SIZE * SCALE
		var row: float = Layouts.ROW_SIZE * SCALE
		for cy in level.size():
			for cx in level[cy].size():
				var v: int = level[cy][cx]
				if v == LevelSet.EMPTY:
					continue
				var tex := BubbleArt.bubble(v, Settings.colourblind, true)
				var x: float = (190.0 - BOARD_RECT.position.x) * SCALE + cx * size + (size / 2.0 if cy % 2 == 1 else 0.0)
				draw_texture_rect(tex, Rect2(x, cy * row, size, size), false)
