extends Node2D
## Key configuration, laid out like the original ask_from dialog (bin/frozen-bubble:3176):
## panel at (149,100), intro line, then one question per 18 px row right-aligned in a 217 px
## column with the current binding shown as "(NAME)" at x=376. Prompts are answered one at a
## time from the top; the next key (or joystick button/axis) pressed becomes the binding.
## Escape cancels the whole dialog without changing anything, like the original.

const PANEL_POS := Vector2(149, 100)
const LINE := 18
const QUESTION_X := 149
const QUESTION_W := 217
const ECHO_X := 376
## action name, prompt (translated), or "" for a half-height spacer row.
const ROWS := [
	["p1_left", "Player 1; turn left?"],
	["p1_right", "Player 1; turn right?"],
	["p1_fire", "Player 1; fire?"],
	["p1_center", "Player 1; center?"],
	["", ""],
	["p2_left", "Player 2; turn left?"],
	["p2_right", "Player 2; turn right?"],
	["p2_fire", "Player 2; fire?"],
	["p2_center", "Player 2; center?"],
	["", ""],
	["fullscreen", "Toggle fullscreen?"],
	["chat", "Chat (net/lan game)?"],
]

var _index := 0
var _answers := {}
var _echo: Array[Label] = []
var _outro: Label
var _done := false


func _ready() -> void:
	$Background.texture = Art.tex("res://assets/gfx/menu/back_start.png")
	$Panel.texture = Art.tex("res://assets/gfx/menu/panel_clean.png")
	$Panel.position = PANEL_POS
	var y := PANEL_POS.y + 12
	var intro := UiText.make(tr("Please enter new keys:"), 13)
	intro.position = Vector2(PANEL_POS.x, y)
	intro.size = Vector2(341, LINE)
	intro.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	add_child(intro)
	y += LINE + 10
	for row in ROWS:
		if row[0] == "":
			y += LINE / 2
			_echo.append(null)
			continue
		var q := UiText.make(tr(row[1]), 13)
		q.position = Vector2(QUESTION_X, y)
		q.size = Vector2(QUESTION_W, LINE)
		q.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		add_child(q)
		var e := UiText.make("", 13)
		e.position = Vector2(ECHO_X, y)
		e.size = Vector2(110, LINE)
		add_child(e)
		_echo.append(e)
		y += LINE
	_outro = UiText.make("", 13)
	_outro.position = Vector2(PANEL_POS.x, PANEL_POS.y + 280 - 35)
	_outro.size = Vector2(341, LINE)
	_outro.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	add_child(_outro)
	_index = _next_prompt(-1)
	_refresh()


func _next_prompt(from: int) -> int:
	var i := from + 1
	while i < ROWS.size() and ROWS[i][0] == "":
		i += 1
	return i


static func key_label(code: int) -> String:
	return OS.get_keycode_string(code).to_upper()


func _refresh() -> void:
	for i in ROWS.size():
		var e := _echo[i]
		if e == null:
			continue
		var action: String = ROWS[i][0]
		if _answers.has(action):
			e.text = _answers[action]["label"]
			e.add_theme_color_override("font_color", Color.WHITE)
		elif i == _index:
			e.text = "(%s)" % key_label(Settings.keys[action][0])
			e.add_theme_color_override("font_color", UiText.HIGHLIGHT)
		else:
			e.text = ""


func _unhandled_input(event: InputEvent) -> void:
	if _done or not event.is_pressed() or event.is_echo():
		return
	var action: String = ROWS[_index][0]
	if event is InputEventKey:
		var key := event as InputEventKey
		if key.keycode == KEY_ESCAPE:
			Audio.play_sfx("cancel")
			Screens.goto(Screens.OPTIONS)
			_done = true
			return
		if key.keycode in [KEY_SHIFT, KEY_CTRL, KEY_ALT, KEY_META]:
			return
		var code := key.physical_keycode if key.physical_keycode != KEY_NONE else key.keycode
		_answers[action] = {"keys": [code], "label": key_label(code)}
	elif event is InputEventJoypadButton:
		var jb := event as InputEventJoypadButton
		_answers[action] = {"joy": jb, "label": "JOY-BUTTON%d" % jb.button_index}
	elif event is InputEventJoypadMotion:
		var jm := event as InputEventJoypadMotion
		if absf(jm.axis_value) < 0.5:
			return
		var dir := ("LEFT" if jm.axis_value < 0 else "RIGHT") if jm.axis % 2 == 0 else ("UP" if jm.axis_value < 0 else "DOWN")
		_answers[action] = {"joy": jm, "label": "JOY-" + dir}
	else:
		return
	Audio.play_sfx("typewriter")
	_index = _next_prompt(_index)
	_refresh()
	if _index >= ROWS.size():
		_finish()


func _finish() -> void:
	_done = true
	for action in _answers:
		var a: Dictionary = _answers[action]
		if a.has("keys"):
			Settings.keys[action] = a["keys"]
		Settings.set_joy(action, a.get("joy"))
	Settings.apply_input_map()
	Settings.save_settings()
	_outro.text = tr("Thanks!")
	Audio.play_sfx("menu_selected")
	await get_tree().create_timer(2.0).timeout
	Screens.goto(Screens.OPTIONS)
