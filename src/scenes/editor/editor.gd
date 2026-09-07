extends Node2D
## Level editor, laid out like the original Games::FrozenBubble::LevelEditor: the level in the
## play field, the bubble palette and navigation planks on the left, levelset/level/help planks
## on the right, SFont bitmap text, and wooden dialogs for open/new/delete/save/jump/help.
## Also hosts the "pick levelset and start level" dialog of the 1-player menu
## (Session.editor_pick), drawn over the menu background.

const LEFT := 190
const TOP := 44
const RIGHT := 446
const ROWS := 10
const BUBBLE := 32
const ROW_H := 28
const PALETTE_X := [18, 58, 98]
const PALETTE_Y := [73, 113, 153]
const HOVER_ALPHA := 68.0 / 255.0
const PREVIEW_ALPHA := 102.0 / 255.0
const OPTIONS := {
	"prev": Rect2(2, 249, 150, 40), "next": Rect2(2, 289, 150, 40),
	"first": Rect2(2, 329, 150, 40), "last": Rect2(2, 369, 150, 40),
	"ls_new": Rect2(488, 70, 150, 40), "ls_open": Rect2(488, 110, 150, 40),
	"ls_save": Rect2(488, 150, 150, 40), "ls_delete": Rect2(488, 190, 150, 40),
	"lvl_insert": Rect2(488, 289, 150, 40), "lvl_append": Rect2(488, 329, 150, 40),
	"lvl_delete": Rect2(488, 369, 150, 40), "help": Rect2(488, 428, 150, 40),
}
## Label text boxes (x, y, width): text is centred in its box next to the penguin of its row.
const LABELS := {
	"prev": [Rect2(60, 253, 90, 34), "Prev"], "next": [Rect2(4, 293, 96, 34), "Next"],
	"first": [Rect2(60, 333, 90, 34), "First"], "last": [Rect2(4, 373, 96, 34), "Last"],
	"ls_new": [Rect2(548, 74, 88, 34), "New"], "ls_open": [Rect2(490, 114, 108, 34), "Open"],
	"ls_save": [Rect2(548, 154, 88, 34), "Save"], "ls_delete": [Rect2(490, 194, 108, 34), "Delete"],
	"lvl_insert": [Rect2(548, 293, 88, 34), "Insert"], "lvl_append": [Rect2(490, 333, 108, 34), "Append"],
	"lvl_delete": [Rect2(548, 373, 88, 34), "Delete"], "help": [Rect2(492, 432, 144, 34), "Help!"],
}
const HEADERS := [[Rect2(4, 34, 146, 34), "Choose bubble"], [Rect2(4, 215, 146, 34), "Navigation"],
	[Rect2(490, 36, 146, 34), "Levelset"], [Rect2(490, 255, 146, 34), "Level"]]
const CURRENT_COLOUR_POS := Vector2(302, 440)

var levelset := LevelSet.new()
var levelset_name := LevelStore.DEFAULT_NAME
var current := 1
var colour := 1
var tool := "add"
var modified := false
var pick_mode := false

var _button_hold := false
var _hover_cell := Vector2i(-1, -1)
var _hovered := ""
var _grid: Node2D
var _preview: Sprite2D
var _highlight: Sprite2D
var _current_sprite: Sprite2D
var _name_label: Label
var _number_label: Label
var _dialog: EditorDialog


func _ready() -> void:
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	pick_mode = Session.editor_pick
	Session.editor_pick = false
	if pick_mode:
		$Background.texture = Art.tex("res://assets/gfx/menu/back_start.png")
		_open_dialog("ls_play_choose_level", {"level": Session.start_level})
		return
	$Background.texture = Art.tex("res://assets/gfx/level_editor.png")
	for h in HEADERS:
		_boxed(tr(h[1]), h[0])
	for key in LABELS:
		_boxed(tr(LABELS[key][1]), LABELS[key][0])
	for i in 8:
		var s := Sprite2D.new()
		s.centered = false
		s.texture = BubbleArt.bubble(i, Settings.colourblind)
		s.position = Vector2(PALETTE_X[i % 3], PALETTE_Y[i / 3])
		add_child(s)
	var erase := Sprite2D.new()
	erase.centered = false
	erase.texture = BubbleArt.stick_effect_frames().get_frame_texture("default", 6)
	erase.position = Vector2(PALETTE_X[2], PALETTE_Y[2])
	add_child(erase)
	_highlight = Sprite2D.new()
	_highlight.centered = false
	_highlight.texture = Art.tex("res://assets/gfx/hover.png")
	_highlight.region_enabled = true
	_highlight.modulate.a = HOVER_ALPHA
	_highlight.visible = false
	add_child(_highlight)
	_grid = Node2D.new()
	add_child(_grid)
	_preview = Sprite2D.new()
	_preview.centered = false
	_preview.modulate.a = PREVIEW_ALPHA
	_preview.visible = false
	add_child(_preview)
	_current_sprite = Sprite2D.new()
	_current_sprite.centered = false
	_current_sprite.position = CURRENT_COLOUR_POS
	add_child(_current_sprite)
	_name_label = UiText.bitmap("")
	_name_label.position = Vector2(0, 7)
	add_child(_name_label)
	_number_label = UiText.bitmap("")
	_number_label.position = Vector2(0, 421)
	add_child(_number_label)
	LevelStore.ensure_default()
	_load_set(levelset_name, clampi(Session.start_level, 1, 9999))
	_change_colour(1)


func _exit_tree() -> void:
	Input.mouse_mode = Input.MOUSE_MODE_HIDDEN


## Display-font text centred in a box, shrunk to fit it.
func _boxed(text: String, box: Rect2) -> Label:
	var l := UiText.bitmap(text)
	l.position = box.position
	l.size = box.size
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	l.clip_text = true
	UiText.fit(l, box.size.x - 4, UiText.EDITOR_SIZE, 10)
	add_child(l)
	return l


func _bitmap(text: String, pos: Vector2, blue := false) -> Label:
	var l := UiText.bitmap(text, blue)
	l.position = pos
	add_child(l)
	return l


static func text_width(text: String) -> float:
	return UiText.editor_width(text)


# --- level data ------------------------------------------------------------------------------

func _load_set(name: String, level := 1) -> void:
	levelset_name = name
	levelset = LevelStore.load_set(name)
	if levelset.size() == 0:
		levelset.levels.append(LevelSet.empty_level())
	current = clampi(level, 1, levelset.size())
	modified = false
	_refresh_level()
	_refresh_name()


func _refresh_name() -> void:
	if _name_label == null:
		return
	var t := levelset_name
	_name_label.text = t
	_name_label.position.x = (640 - text_width(t)) / 2.0


func _refresh_level() -> void:
	if _grid == null:
		return
	for c in _grid.get_children():
		c.queue_free()
	var level: Array = levelset.levels[current - 1]
	for r in ROWS:
		for c in level[r].size():
			if level[r][c] != LevelSet.EMPTY:
				var s := Sprite2D.new()
				s.centered = false
				s.texture = BubbleArt.bubble(level[r][c], Settings.colourblind)
				s.position = cell_pos(c, r)
				_grid.add_child(s)
	var t := "%d/%d" % [current, levelset.size()]
	_number_label.text = t
	_number_label.position.x = 183 - text_width(t) / 2.0


static func cell_pos(c: int, r: int) -> Vector2:
	return Vector2(LEFT + BUBBLE * c + (BUBBLE / 2 if r % 2 == 1 else 0), TOP + ROW_H * r)


static func cell_at(pos: Vector2) -> Vector2i:
	var r := int(floor((pos.y - TOP) / ROW_H))
	var c := -1
	if r % 2 == 0:
		c = int(floor((pos.x - LEFT) / BUBBLE))
	elif LEFT + BUBBLE / 2 <= pos.x and pos.x < RIGHT - BUBBLE / 2:
		c = int(floor((pos.x - (LEFT + BUBBLE / 2)) / BUBBLE))
	return Vector2i(c, r)


func _set_cell(c: int, r: int, v: int) -> void:
	levelset.levels[current - 1][r][c] = v
	modified = true
	_refresh_level()


func _change_colour(id: int) -> void:
	colour = id
	tool = "add"
	_current_sprite.visible = true
	_current_sprite.texture = BubbleArt.bubble(id - 1, Settings.colourblind)


func _choose_erase() -> void:
	tool = "erase"
	_current_sprite.visible = false


func _goto(level: int) -> void:
	current = clampi(level, 1, levelset.size())
	_refresh_level()


func _insert_level() -> void:
	levelset.levels.insert(current - 1, LevelSet.empty_level())
	modified = true
	_refresh_level()


func _append_level() -> void:
	current += 1
	_insert_level()


func _delete_level() -> void:
	levelset.levels.remove_at(current - 1)
	modified = true
	if levelset.size() == 0:
		levelset.levels.append(LevelSet.empty_level())
		current = 1
	elif current > levelset.size():
		current = levelset.size()
	_refresh_level()


func _move_level(delta: int) -> void:
	var other := current + delta
	if other < 1 or other > levelset.size():
		return
	var tmp = levelset.levels[current - 1]
	levelset.levels[current - 1] = levelset.levels[other - 1]
	levelset.levels[other - 1] = tmp
	current = other
	modified = true
	_refresh_level()


func _save() -> void:
	LevelStore.save_set(levelset_name, levelset)
	modified = false


func _new_levelset(name: String) -> void:
	levelset_name = name.to_lower()
	levelset = LevelSet.new()
	levelset.levels.append(LevelSet.empty_level())
	current = 1
	modified = false
	_refresh_level()
	_refresh_name()


# --- hover / highlight -----------------------------------------------------------------------

func _highlight_option(name: String, rect: Rect2) -> void:
	_hovered = name
	_highlight.visible = true
	_highlight.region_rect = Rect2(0, 0, rect.size.x, rect.size.y)
	_highlight.position = rect.position


func _unhighlight() -> void:
	_hovered = ""
	if _highlight != null:
		_highlight.visible = false


func _clear_preview() -> void:
	if _preview != null:
		_preview.visible = false
	_hover_cell = Vector2i(-1, -1)


# --- mouse -----------------------------------------------------------------------------------

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouse:
		event = make_input_local(event)  # viewport pixels -> 640x480 content coordinates
	if _dialog != null:
		if event is InputEventMouseMotion:
			_dialog.hover(event.position)
		elif event is InputEventMouseButton and event.pressed:
			_dialog.click(event.position, event.button_index)
		elif event is InputEventMouseButton and not event.pressed:
			_dialog.release()
		elif event is InputEventKey and event.pressed and not event.echo:
			_dialog.key(event)
		return
	if pick_mode:
		return
	if event is InputEventMouseMotion:
		var mask: int = event.button_mask
		var button := MOUSE_BUTTON_RIGHT if mask & MOUSE_BUTTON_MASK_RIGHT else (MOUSE_BUTTON_LEFT if mask & MOUSE_BUTTON_MASK_LEFT else 0)
		_choose_action(event.position, "motion", button)
	elif event is InputEventMouseButton:
		if event.pressed:
			_button_hold = true
			_choose_action(event.position, "button", event.button_index)
		else:
			_button_hold = false
	elif event is InputEventKey and event.pressed and not event.echo:
		_key(event as InputEventKey)


func _choose_action(pos: Vector2, caller: String, button: int) -> void:
	var x := pos.x
	var y := pos.y
	if LEFT <= x and x < RIGHT and TOP <= y and y < TOP + ROWS * ROW_H:
		if caller == "motion" and not _button_hold:
			_place(pos, true, button)
		else:
			_place(pos, false, button)
		return
	_clear_preview()
	# palette
	if 73 <= y and y <= 193 and 14 < x and x <= 134:
		var col := int(ceil((x - 14) / 40.0))
		var row := int(ceil((y - 69) / 40.0))
		var id := 3 * (row - 1) + col
		if id >= 1 and id <= 8:
			_highlight_option("bubble-%d" % id, Rect2(PALETTE_X[col - 1], PALETTE_Y[row - 1], 32, 32))
			if caller == "button":
				_change_colour(id)
		elif id == 9:
			_highlight_option("erase", Rect2(PALETTE_X[2], PALETTE_Y[2], 32, 32))
			if caller == "button":
				_choose_erase()
		else:
			_unhighlight()
		return
	for key in OPTIONS:
		var name: String = key
		var rect: Rect2 = OPTIONS[name]
		if rect.has_point(pos) or (rect.position.x <= x and x <= rect.end.x and rect.position.y <= y and y <= rect.end.y):
			var disabled: bool = (name in ["prev", "first"] and current == 1) or (name in ["next", "last"] and current == levelset.size())
			if disabled:
				_unhighlight()
				return
			_highlight_option(name, rect)
			if caller == "button":
				_activate(name)
			return
	_unhighlight()


func _activate(name: String) -> void:
	match name:
		"prev":
			_goto(current - 1)
		"next":
			_goto(current + 1)
		"first":
			_goto(1)
		"last":
			_goto(levelset.size())
		"ls_new":
			_with_saved_changes(func(): _open_dialog("ls_new_ok_only"), func(): _open_dialog("ls_new"))
		"ls_open":
			_with_saved_changes(func(): _open_dialog("ls_open_ok_only"), func(): _open_dialog("ls_open"))
		"ls_save":
			_save()
		"ls_delete":
			if LevelStore.list().size() > 1:
				_open_dialog("ls_delete")
			else:
				_open_dialog("ls_nothing_to_delete")
		"lvl_insert":
			_insert_level()
		"lvl_append":
			_append_level()
		"lvl_delete":
			_delete_level()
		"help":
			_open_dialog("help")
	if (_hovered in ["prev", "first"] and current == 1) or (_hovered in ["next", "last"] and current == levelset.size()):
		_unhighlight()


## If there are unsaved changes, asks first (SAVE CHANGES?), then runs [param after_dialog];
## otherwise runs [param direct] at once.
func _with_saved_changes(after_dialog: Callable, direct: Callable) -> void:
	if modified:
		_open_dialog("ls_save_changes", {"then": after_dialog})
	else:
		direct.call()


func _place(pos: Vector2, preview: bool, button: int) -> void:
	var cell := cell_at(pos)
	if cell.x < 0 or cell.y < 0 or cell.y >= ROWS:
		_clear_preview()
		return
	var erase := tool == "erase" or button == MOUSE_BUTTON_RIGHT
	var level: Array = levelset.levels[current - 1]
	if preview:
		_hover_cell = cell
		_preview.position = cell_pos(cell.x, cell.y)
		if erase:
			_preview.visible = level[cell.y][cell.x] != LevelSet.EMPTY
			if _preview.visible:
				_preview.texture = BubbleArt.bubble(level[cell.y][cell.x], Settings.colourblind)
		else:
			_preview.visible = true
			_preview.texture = BubbleArt.bubble(colour - 1, Settings.colourblind)
		return
	if erase:
		if level[cell.y][cell.x] != LevelSet.EMPTY:
			_set_cell(cell.x, cell.y, LevelSet.EMPTY)
	elif level[cell.y][cell.x] != colour - 1:
		_set_cell(cell.x, cell.y, colour - 1)
	_preview.visible = false


# --- keyboard --------------------------------------------------------------------------------

func _key(key: InputEventKey) -> void:
	match key.keycode:
		KEY_ESCAPE, KEY_Q:
			_with_saved_changes(func(): _quit(), func(): _quit())
		KEY_LEFT, KEY_H, KEY_P:
			_goto(current - 1)
		KEY_RIGHT, KEY_L, KEY_N:
			_goto(current + 1)
		KEY_UP:
			_goto(1)
		KEY_DOWN:
			_goto(levelset.size())
		KEY_A:
			_append_level()
		KEY_I:
			_insert_level()
		KEY_D:
			_delete_level()
		KEY_BRACKETLEFT:
			_move_level(-1)
		KEY_BRACKETRIGHT:
			_move_level(1)
		KEY_J:
			_open_dialog("jump")
		KEY_O:
			_activate("ls_open")
		KEY_S:
			_save()
		KEY_F:
			Settings.toggle_fullscreen()
		KEY_F1:
			_open_dialog("help")
	if (_hovered in ["prev", "first"] and current == 1) or (_hovered in ["next", "last"] and current == levelset.size()):
		_unhighlight()


func _quit() -> void:
	Screens.goto(Screens.MENU)


# --- dialogs ---------------------------------------------------------------------------------

func _open_dialog(kind: String, opts := {}) -> void:
	_unhighlight()
	_clear_preview()
	if _dialog != null:
		_dialog.queue_free()
	_dialog = EditorDialog.new()
	_dialog.editor = self
	_dialog.setup(kind, opts)
	add_child(_dialog)


func close_dialog() -> void:
	if _dialog != null:
		_dialog.queue_free()
		_dialog = null
	if not pick_mode:
		_refresh_level()


## Called by the dialog with its result.
func dialog_result(kind: String, ok: bool, data := {}) -> void:
	var then: Callable = data.get("then", Callable())
	match kind:
		"ls_new", "ls_new_ok_only":
			if ok:
				_new_levelset(data["name"])
		"jump":
			if ok:
				_goto(int(data["value"]))
		"ls_open", "ls_open_ok_only":
			if ok:
				_load_set(data["name"], 1)
			elif data.get("deleted_current", false):
				close_dialog()
				_open_dialog("ls_deleted_current")
				return
		"ls_delete":
			if ok:
				LevelStore.delete(data["name"])
				if data["name"] == levelset_name:
					close_dialog()
					_open_dialog("ls_deleted_current")
					return
		"ls_deleted_current":
			close_dialog()
			if ok:
				_open_dialog("ls_open_ok_only", {"deleted_current": true})
			else:
				_load_set(LevelStore.DEFAULT_NAME, 1)
			return
		"ls_save_changes":
			if ok:
				_save()
			modified = false
			close_dialog()
			if then.is_valid():
				then.call()
			return
		"ls_play_choose_level":
			close_dialog()
			if ok:
				Session.levelset_path = LevelStore.path_of(data["name"])
				Session.mode = Session.Mode.LEVELS
				Session.start_level = int(data["level"])
				Session.reset_for_new_game()
				Audio.play_music("frozen-mainzik-1p")
				Screens.goto(Screens.GAME, true)
			else:
				Screens.goto(Screens.MENU)
			return
	close_dialog()
