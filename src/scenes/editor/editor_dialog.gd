class_name EditorDialog
extends Node2D
## The level editor's wooden dialogs (create_dialog_base and friends in LevelEditor.pm):
## panel at (149,100), title at y 105, OK at (209,340) / CANCEL or OK-right at (370|410,340),
## an optional levelset list browser with thumbnail, typed text at y 210, and the START LEVEL
## widget of the "pick levelset" dialog. Reports back through editor.dialog_result().

const PANEL_POS := Vector2(149, 100)
const PANEL_SIZE := Vector2(341, 280)
const LEFT_BUTTON := Rect2(149, 336, 170, 40)
const RIGHT_BUTTON := Rect2(340, 336, 150, 40)
const LIST_POS := Vector2(158, 177)
const ROW_PITCH := 25
const VISIBLE_ROWS := 4
const THUMB_POS := Vector2(394, 178)
const THUMB_REGION := Rect2(150, 0, 336, 470)
const TITLES := {
	"help": "Help: key shortcuts", "jump": "Enter level to jump to",
	"ls_new": "Enter new levelset name", "ls_new_ok_only": "Enter new levelset name",
	"ls_open": "Select levelset to open", "ls_open_ok_only": "Select levelset to open",
	"ls_delete": "Select levelset to delete", "ls_nothing_to_delete": "No levelset to delete",
	"ls_deleted_current": "Deleted current levelset", "ls_save_changes": "Save changes?",
	"ls_play_choose_level": "Select levelset to play",
}
const HELP_LINES := [
	["F1", "Display this dialog"], ["P, H, Left", "Previous level"], ["N, L, Right", "Next level"],
	["]", "Move level right"], ["[", "Move level left"], ["F", "Toggle full screen"],
	["Up", "First level"], ["Down", "Last level"], ["A", "Append level"], ["I", "Insert level"],
	["D", "Delete level"], ["J", "Jump to level"], ["O", "Open levelset"], ["S", "Save levelset"],
	["Q, Escape", "Quit"],
]
const ONE_BUTTON := ["help", "ls_nothing_to_delete", "ls_open_ok_only", "ls_new_ok_only", "ls_play_choose_level"]
const WITH_LIST := ["ls_open", "ls_open_ok_only", "ls_delete", "ls_play_choose_level"]
const BODY := {
	"ls_save_changes": [[Vector2(174, 140), "There are unsaved changes"], [Vector2(171, 175), "Press OK to save"],
		[Vector2(171, 195), "changes and continue"], [Vector2(171, 235), "Press Cancel to continue"], [Vector2(171, 255), "without saving"]],
	"ls_deleted_current": [[Vector2(174, 155), "Press OK to choose"], [Vector2(174, 175), "another levelset to open"],
		[Vector2(174, 220), "Press Cancel to open"], [Vector2(174, 245), "the default levelset"]],
	"ls_nothing_to_delete": [[Vector2(199, 170), "There are no custom"], [Vector2(199, 195), "levelsets to delete."], [Vector2(189, 265), "Press OK to continue"]],
}

var editor: Node
var kind := ""
var opts := {}
var names := PackedStringArray()
var start := 0
var highlight := 0
var start_level := 1
var text := ""
var shift := 0

var _hl: Sprite2D
var _text_label: Label
var _rows: Array[Label] = []
var _frame: Sprite2D
var _thumb: LevelThumb
var _level_label: Label
var _sets := {}


func setup(kind_: String, opts_: Dictionary) -> void:
	kind = kind_
	opts = opts_
	shift = -25 if kind == "ls_play_choose_level" else 0
	var panel := Sprite2D.new()
	panel.centered = false
	panel.texture = Art.tex("res://assets/gfx/menu/panel_clean.png")
	panel.position = PANEL_POS
	add_child(panel)
	_hl = Sprite2D.new()
	_hl.centered = false
	_hl.texture = Art.tex("res://assets/gfx/hover.png")
	_hl.region_enabled = true
	_hl.modulate.a = 68.0 / 255.0
	_hl.visible = false
	add_child(_hl)
	var title: String = tr(TITLES[kind])
	var tl := _label(title, Vector2(PANEL_POS.x + 10, 103))
	tl.size = Vector2(PANEL_SIZE.x - 20, 26)
	tl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	UiText.fit(tl, PANEL_SIZE.x - 24, UiText.EDITOR_SIZE, 11)
	if kind in ONE_BUTTON:
		_label(tr("OK"), Vector2(410, 340))
	else:
		_label(tr("OK"), Vector2(209, 340))
		_label(tr("Cancel"), Vector2(370, 340))
	for line in BODY.get(kind, []):
		_label(tr(line[1]), line[0])
	if kind == "help":
		var y := 132.0
		for line in HELP_LINES:
			var k := _label(line[0], Vector2(PANEL_POS.x + 22, y))
			k.add_theme_font_size_override("font_size", 12)
			var d := _label(tr(line[1]), Vector2(PANEL_POS.x + 130, y))
			d.add_theme_font_size_override("font_size", 12)
			y += 13.5
	if kind in ["jump", "ls_new", "ls_new_ok_only"]:
		_text_label = _label("", Vector2(0, 210))
	if kind in WITH_LIST:
		_build_list()
	if kind == "ls_play_choose_level":
		start_level = int(opts.get("level", 1))
		_label(tr("Start level:"), Vector2(164, 290))
		var bar := Sprite2D.new()
		bar.centered = false
		bar.texture = Art.tex("res://assets/gfx/select_level_background.png")
		bar.position = Vector2(305, 290)
		add_child(bar)
		for a in [["up", Vector2(437, 280)], ["up_more", Vector2(457, 280)], ["down", Vector2(437, 302)], ["down_more", Vector2(457, 302)]]:
			var s := Sprite2D.new()
			s.centered = false
			s.texture = Art.tex("res://assets/gfx/list_arrow_%s.png" % a[0])
			s.position = a[1]
			add_child(s)
		_level_label = _label("", Vector2(0, 290), true)
		_refresh_level_widget()
	_refresh_text()


func _label(t: String, pos: Vector2, blue := false) -> Label:
	var l := UiText.bitmap(t, blue)
	l.position = pos
	add_child(l)
	return l


static func _width(t: String) -> float:
	return UiText.editor_width(t)


# --- list browser ----------------------------------------------------------------------------

func _build_list() -> void:
	names = LevelStore.list()
	if kind == "ls_delete":
		var filtered := PackedStringArray()
		for n in names:
			if n != LevelStore.DEFAULT_NAME:
				filtered.append(n)
		names = filtered
	var bg := Sprite2D.new()
	bg.centered = false
	bg.texture = Art.tex("res://assets/gfx/file_list_background.png")
	bg.position = LIST_POS + Vector2(0, shift)
	add_child(bg)
	var strip := Sprite2D.new()
	strip.centered = false
	strip.texture = Art.tex("res://assets/gfx/scroll_list_background.png")
	strip.position = Vector2(375, 177 + shift)
	add_child(strip)
	for a in [["up", Vector2(378, 179 + shift)], ["down", Vector2(378, 274 + shift)]]:
		var s := Sprite2D.new()
		s.centered = false
		s.texture = Art.tex("res://assets/gfx/list_arrow_%s.png" % a[0])
		s.position = a[1]
		add_child(s)
	_frame = Sprite2D.new()
	_frame.centered = false
	_frame.texture = Art.tex("res://assets/gfx/purple_hover.png")
	add_child(_frame)
	for i in VISIBLE_ROWS:
		_rows.append(_label("", Vector2(168, 185 + ROW_PITCH * i + shift), true))
	_thumb = LevelThumb.new()
	_thumb.position = THUMB_POS + Vector2(0, shift)
	add_child(_thumb)
	# start on the levelset being edited when it is in the list
	var idx := names.find(editor.levelset_name) if editor != null else -1
	if idx >= 0:
		highlight = idx
		start = clampi(idx - VISIBLE_ROWS + 1, 0, maxi(names.size() - VISIBLE_ROWS, 0)) if idx >= VISIBLE_ROWS else 0
	_refresh_list()


func _set_of(name: String) -> LevelSet:
	if not _sets.has(name):
		_sets[name] = LevelStore.load_set(name)
	return _sets[name]


func _refresh_list() -> void:
	for i in VISIBLE_ROWS:
		var idx := start + i
		_rows[i].text = names[idx] if idx < names.size() else ""
	var vis := highlight - start
	_frame.visible = vis >= 0 and vis < VISIBLE_ROWS and highlight < names.size()
	_frame.position = Vector2(161, 187 + ROW_PITCH * vis + shift)
	if highlight < names.size():
		var ls := _set_of(names[highlight])
		if kind == "ls_play_choose_level":
			start_level = clampi(start_level, 1, maxi(ls.size(), 1))
			_refresh_level_widget()
		_thumb.level = ls.get_level(clampi((start_level if kind == "ls_play_choose_level" else 1) - 1, 0, ls.size() - 1)) if ls.size() > 0 else LevelSet.empty_level()
		_thumb.queue_redraw()


func _move_highlight(delta: int) -> void:
	var h := clampi(highlight + delta, 0, names.size() - 1)
	if h == highlight:
		return
	highlight = h
	if highlight < start:
		start = highlight
	elif highlight >= start + VISIBLE_ROWS:
		start = highlight - VISIBLE_ROWS + 1
	_refresh_list()


func _scroll(delta: int) -> void:
	var s := clampi(start + delta, 0, maxi(names.size() - 1, 0))
	if s != start:
		start = s
		_refresh_list()


func _levels_in_selected() -> int:
	return maxi(_set_of(names[highlight]).size(), 1) if highlight < names.size() else 1


func _change_level(delta: int) -> void:
	var n := _levels_in_selected()
	var target := start_level + delta
	if absi(delta) == 10:
		target = clampi(target, 1, n)
	elif target < 1 or target > n:
		return
	start_level = target
	_refresh_list()


func _refresh_level_widget() -> void:
	if _level_label == null:
		return
	var t := str(start_level)
	_level_label.text = t
	_level_label.position.x = 427 - _width(t)


# --- typed text ------------------------------------------------------------------------------

func _text_valid() -> bool:
	if kind == "jump":
		return text.length() > 0 and int(text) >= 1 and int(text) <= editor.levelset.size()
	if kind in ["ls_new", "ls_new_ok_only"]:
		if text == "" or not LevelStore.is_ok_name(text):
			return false
		for n in LevelStore.list():
			if n.to_lower() == text.to_lower():
				return false
		return true
	return true


func _refresh_text() -> void:
	if _text_label == null:
		return
	_text_label.text = text
	_text_label.position.x = PANEL_POS.x + PANEL_SIZE.x / 2.0 - _width(text) / 2.0


# --- input -----------------------------------------------------------------------------------

func hover(pos: Vector2) -> void:
	var one := kind in ONE_BUTTON
	if pos.y > 340 and pos.y < 380 and pos.x > 149 and pos.x < 490:
		var right := pos.x > 319.5
		if right:
			_show_hl(RIGHT_BUTTON)
		elif not one and _text_valid():
			_show_hl(LEFT_BUTTON)
		else:
			_hl.visible = false
	else:
		_hl.visible = false


func _show_hl(rect: Rect2) -> void:
	_hl.visible = true
	_hl.position = rect.position
	_hl.region_rect = Rect2(0, 0, rect.size.x, rect.size.y)


func click(pos: Vector2, button: int) -> void:
	if button != MOUSE_BUTTON_LEFT:
		return
	var one := kind in ONE_BUTTON
	if pos.y > 340 and pos.y < 380 and pos.x > 149 and pos.x < 490:
		if pos.x > 319.5:
			if one:
				_ok()
			else:
				_cancel()
		elif not one:
			_ok()
		return
	if kind in WITH_LIST:
		var ly := LIST_POS.y + shift
		if pos.x > 376 and pos.x < 391:
			if pos.y > ly + 2 and pos.y < ly + 23:
				_scroll(-1)
			elif pos.y > ly + 97 and pos.y < ly + 118:
				_scroll(1)
			return
		if pos.x > LIST_POS.x and pos.x < 375 and pos.y > ly and pos.y < ly + 120:
			var row := clampi(int((pos.y - ly - 10) / ROW_PITCH), 0, VISIBLE_ROWS - 1)
			if start + row < names.size():
				highlight = start + row
				_refresh_list()
			return
	if kind == "ls_play_choose_level" and pos.x > 435 and pos.x < 470:
		var step := 10 if pos.x > 452 else 1
		if pos.y > 280 and pos.y < 300:
			_change_level(step)
		elif pos.y > 302 and pos.y < 322:
			_change_level(-step)


func release() -> void:
	pass


func key(event: InputEventKey) -> void:
	var k := event.keycode
	match kind:
		"jump", "ls_new", "ls_new_ok_only":
			_text_key(event)
			return
		"help", "ls_nothing_to_delete":
			if k in [KEY_ENTER, KEY_KP_ENTER, KEY_ESCAPE]:
				_ok()
			return
	if k in [KEY_ENTER, KEY_KP_ENTER]:
		_ok()
	elif k == KEY_ESCAPE or (k == KEY_Q and kind == "ls_play_choose_level"):
		if kind == "ls_open_ok_only":
			return
		_cancel()
	elif k == KEY_DOWN and kind in WITH_LIST:
		_move_highlight(1)
	elif k == KEY_UP and kind in WITH_LIST:
		_move_highlight(-1)
	elif k == KEY_LEFT and kind == "ls_play_choose_level":
		_change_level(-1)
	elif k == KEY_RIGHT and kind == "ls_play_choose_level":
		_change_level(1)


func _text_key(event: InputEventKey) -> void:
	var k := event.keycode
	if k == KEY_ESCAPE:
		if kind != "ls_new_ok_only":
			_cancel()
		return
	if k in [KEY_ENTER, KEY_KP_ENTER]:
		if _text_valid():
			_ok()
		return
	if k == KEY_BACKSPACE:
		text = text.left(text.length() - 1)
	elif kind == "jump":
		var digit := _digit(k)
		if digit != "":
			var candidate := text + digit
			if int(candidate) >= 1 and int(candidate) <= editor.levelset.size():
				text = candidate
	else:
		if text.length() >= 14:
			return
		var digit := _digit(k)
		if digit != "":
			text += digit
		elif k == KEY_MINUS or k == KEY_KP_SUBTRACT:
			text += "-"
		elif k >= KEY_A and k <= KEY_Z:
			text += char(k).to_lower()
	_refresh_text()


static func _digit(k: Key) -> String:
	if k >= KEY_0 and k <= KEY_9:
		return char(k)
	if k >= KEY_KP_0 and k <= KEY_KP_9:
		return str(k - KEY_KP_0)
	return ""


func _ok() -> void:
	var data := opts.duplicate()
	if kind in WITH_LIST:
		if highlight >= names.size():
			return
		data["name"] = names[highlight]
		data["level"] = start_level
	elif kind in ["ls_new", "ls_new_ok_only"]:
		if not _text_valid():
			return
		data["name"] = text.to_lower()
	elif kind == "jump":
		if not _text_valid():
			return
		data["value"] = int(text)
	editor.dialog_result(kind, true, data)


func _cancel() -> void:
	editor.dialog_result(kind, false, opts.duplicate())


## 84x117 preview: the editor background region (150,0)-(486,470) at 1/4 scale with the level.
class LevelThumb extends Node2D:
	var level: Array = []

	func _draw() -> void:
		var bg := Art.tex("res://assets/gfx/level_editor.png")
		draw_texture_rect_region(bg, Rect2(Vector2.ZERO, THUMB_REGION.size * 0.25), THUMB_REGION)
		for r in level.size():
			for c in level[r].size():
				var v: int = level[r][c]
				if v == LevelSet.EMPTY:
					continue
				var pos := (Vector2(190 + 32 * c + (16 if r % 2 == 1 else 0), 44 + 28 * r) - THUMB_REGION.position) * 0.25
				draw_texture_rect(BubbleArt.bubble(v, Settings.colourblind, true), Rect2(pos, Vector2(8, 8)), false)
