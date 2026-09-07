class_name AskDialog
extends Node2D
## The original's ask_from dialog (bin/frozen-bubble:3176): a wooden panel at (149,100) with
## centred intro lines from y=112 (18 px apart), then a question row, an outro line at y=345.
## Two modes: ONE_CHAR (the next key answers; Escape cancels) and TEXT (a single line is typed;
## Enter accepts, Escape cancels). Emits [signal answered] with the keycode / text, or
## [signal cancelled].

signal answered(value)
signal cancelled

enum Mode { ONE_CHAR, TEXT }

const PANEL_POS := Vector2(149, 100)
const PANEL_SIZE := Vector2(341, 280)
const LINE := 18
const ECHO_X := 376
const MAX_TEXT_WIDTH := 100
var max_text_width := MAX_TEXT_WIDTH

var mode := Mode.ONE_CHAR
var text := ""
var outro := ""
var _echo: Label
var _outro_label: Label
var _blink := 51
var _done := false


static func create(intro: Array, question: String, mode_: Mode, outro_ := "") -> AskDialog:
	var d := AskDialog.new()
	d.mode = mode_
	d.outro = outro_
	d._build(intro, question)
	return d


func _build(intro: Array, question: String) -> void:
	var panel := Sprite2D.new()
	panel.centered = false
	panel.texture = Art.tex("res://assets/gfx/menu/panel_clean.png")
	panel.position = PANEL_POS
	add_child(panel)
	var y := PANEL_POS.y + 12
	for line in intro:
		if line != "":
			var l := UiText.make(line, 13)
			l.position = Vector2(PANEL_POS.x, y)
			l.size = Vector2(PANEL_SIZE.x, LINE)
			l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
			add_child(l)
		y += LINE
	y += 10
	var q := UiText.make(question, 13)
	q.position = Vector2(PANEL_POS.x, y)
	q.size = Vector2(PANEL_SIZE.x * 2 / 3 - 10, LINE)
	q.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	add_child(q)
	_echo = UiText.make("", 13)
	_echo.position = Vector2(ECHO_X, y)
	_echo.size = Vector2(110, LINE)
	add_child(_echo)
	_outro_label = UiText.make("", 13)
	_outro_label.position = Vector2(PANEL_POS.x, PANEL_POS.y + PANEL_SIZE.y - 35)
	_outro_label.size = Vector2(PANEL_SIZE.x, LINE)
	_outro_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	add_child(_outro_label)
	_refresh_echo()


func _physics_process(_delta: float) -> void:
	if mode != Mode.TEXT or _done:
		return
	_blink -= 1
	if _blink < 0:
		_blink = 50
	if _blink == 50 or _blink == 25:
		_refresh_echo()


func _refresh_echo() -> void:
	if mode == Mode.TEXT:
		_echo.text = text + ("|" if _blink > 25 else "")


func _unhandled_input(event: InputEvent) -> void:
	if _done or not (event is InputEventKey) or not event.pressed:
		return
	var key := event as InputEventKey
	get_viewport().set_input_as_handled()
	if key.keycode == KEY_ESCAPE:
		_finish(false)
		cancelled.emit()
		return
	if mode == Mode.ONE_CHAR:
		if key.keycode in [KEY_SHIFT, KEY_CTRL, KEY_ALT, KEY_META]:
			return
		Audio.play_sfx("typewriter")
		_echo.text = OS.get_keycode_string(key.keycode).to_upper()
		_finish(true)
		answered.emit(key.keycode)
		return
	# TEXT mode
	if key.keycode == KEY_ENTER or key.keycode == KEY_KP_ENTER:
		_finish(true)
		answered.emit(text)
	elif key.keycode == KEY_BACKSPACE:
		if text.length() > 0:
			text = text.left(text.length() - 1)
			Audio.play_sfx("typewriter")
	elif key.unicode >= 32 and key.unicode != 127:
		var candidate := text + char(key.unicode)
		var font: Font = _echo.get_theme_font("font")
		if font.get_string_size(candidate, HORIZONTAL_ALIGNMENT_LEFT, -1, 13).x > max_text_width:
			Audio.play_sfx("stick")
		else:
			text = candidate
			Audio.play_sfx("typewriter")
	_blink = 75
	_refresh_echo()


func _finish(ok: bool) -> void:
	_done = true
	if ok and outro != "":
		_outro_label.text = outro
		Audio.play_sfx("menu_selected")
	elif not ok:
		Audio.play_sfx("cancel")
