extends Node2D
## Options screen (replaces the original's "graphics level" dialog): video, audio, colour-blind
## bubbles, language, and a link to the key configuration. Keyboard driven like the menus:
## up/down to move, left/right (or Enter) to change, Escape to go back.

const PANEL_POS := Vector2(149, 100)
const ROW_HEIGHT := 20
const FIRST_ROW := 16

var _items: Array[Dictionary] = []
var _selected := 0
var _rows: Array[Dictionary] = []
var _locales: Array = []


func _ready() -> void:
	$Background.texture = Art.tex("res://assets/gfx/menu/back_start.png")
	$Panel.texture = Art.tex("res://assets/gfx/menu/panel_clean.png")
	$Panel.position = PANEL_POS
	_locales = ["", ]
	_locales.append_array(TranslationServer.get_loaded_locales())
	_items = [
		{"label": "Fullscreen", "get": func(): return _onoff(Settings.fullscreen), "change": func(d): Settings.fullscreen = not Settings.fullscreen; Settings.apply_video()},
		{"label": "Integer scaling", "get": func(): return _onoff(Settings.integer_scale), "change": func(d): Settings.integer_scale = not Settings.integer_scale; Settings.apply_video()},
		{"label": "Music", "get": func(): return _onoff(Settings.music_enabled), "change": func(d): Settings.music_enabled = not Settings.music_enabled; Audio.apply_settings()},
		{"label": "Sound effects", "get": func(): return _onoff(Settings.sfx_enabled), "change": func(d): Settings.sfx_enabled = not Settings.sfx_enabled; Audio.apply_settings()},
		{"label": "Volume", "get": func(): return "%d%%" % roundi(Settings.volume * 100), "change": func(d): Settings.volume = clampf(Settings.volume + 0.1 * d, 0.0, 1.0); Audio.apply_settings()},
		{"label": "Colour-blind bubbles", "get": func(): return _onoff(Settings.colourblind), "change": func(d): Settings.colourblind = not Settings.colourblind},
		{"label": "Bubble style", "get": func(): return tr("Smooth") if Settings.bubble_style == "smooth" else tr("Classic"), "change": func(d): Settings.bubble_style = "smooth" if Settings.bubble_style == "classic" else "classic"; Settings.apply_video()},
		{"label": "No instant death", "get": func(): return _onoff(Settings.no_instant_death), "change": func(d): Settings.no_instant_death = not Settings.no_instant_death},
		{"label": "2-player handicap", "get": func(): return ("+%d" % Settings.player_malus) if Settings.player_malus > 0 else str(Settings.player_malus), "change": func(d): Settings.player_malus = clampi(Settings.player_malus + d, -3, 3)},
		{"label": "Language", "get": func(): return _locale_name(Settings.locale), "change": func(d): _cycle_locale(d)},
		{"label": "Public server", "get": func(): return Settings.default_server if Settings.default_server != "" else tr("none"), "activate": func(): _edit_server()},
		{"label": "Change keys", "get": func(): return "", "activate": func(): Screens.goto(Screens.KEYS)},
		{"label": "Back", "get": func(): return "", "activate": func(): _back()},
	]
	var y := PANEL_POS.y + FIRST_ROW
	var title := UiText.make(tr("Options"), 18, UiText.HIGHLIGHT, true)
	title.position = Vector2(PANEL_POS.x, y - 4)
	title.size = Vector2(341, 28)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	add_child(title)
	y += 30
	for item in _items:
		var name_label := UiText.make(tr(item["label"]), 14)
		name_label.position = Vector2(PANEL_POS.x + 30, y)
		name_label.size = Vector2(170, ROW_HEIGHT)
		add_child(name_label)
		var value_label := UiText.make("", 14)
		value_label.position = Vector2(PANEL_POS.x + 200, y)
		value_label.size = Vector2(120, ROW_HEIGHT)
		value_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		add_child(value_label)
		_rows.append({"name": name_label, "value": value_label})
		y += ROW_HEIGHT
	_refresh()


func _onoff(v: bool) -> String:
	return tr("on") if v else tr("off")


func _locale_name(loc: String) -> String:
	if loc == "":
		return tr("System")
	return TranslationServer.get_locale_name(loc)


func _cycle_locale(d: int) -> void:
	var i := _locales.find(Settings.locale)
	i = wrapi(i + d, 0, _locales.size())
	Settings.locale = _locales[i]
	TranslationServer.set_locale(Settings.locale if Settings.locale != "" else OS.get_locale())
	# re-translate the static labels
	for r in _rows.size():
		_rows[r]["name"].text = tr(_items[r]["label"])


func _refresh() -> void:
	for i in _rows.size():
		var selected := i == _selected
		var colour := UiText.HIGHLIGHT if selected else Color.WHITE
		_rows[i]["name"].add_theme_color_override("font_color", colour)
		_rows[i]["value"].add_theme_color_override("font_color", colour)
		_rows[i]["value"].text = _items[i]["get"].call()


var _editing := false


func _edit_server() -> void:
	_editing = true
	var d := AskDialog.create([tr("Public server"), tr("host or host:port; empty to clear"), ""], "", AskDialog.Mode.TEXT, tr("Saved"))
	d.max_text_width = 220
	d.text = Settings.default_server
	add_child(d)
	d.answered.connect(func(v):
		Settings.default_server = str(v).strip_edges()
		Settings.save_settings()
		_refresh()
		await get_tree().create_timer(0.8).timeout
		d.queue_free()
		_editing = false)
	d.cancelled.connect(func():
		d.queue_free()
		_editing = false)


func _back() -> void:
	Settings.save_settings()
	Screens.goto(Screens.MENU)


func _unhandled_input(event: InputEvent) -> void:
	if _editing or not event.is_pressed() or event.is_echo():
		return
	if event.is_action_pressed("back"):
		Audio.play_sfx("cancel")
		_back()
	elif event.is_action_pressed("ui_down") or event.is_action_pressed("p1_center"):
		_selected = wrapi(_selected + 1, 0, _items.size())
		Audio.play_sfx("menu_change")
		_refresh()
	elif event.is_action_pressed("ui_up") or event.is_action_pressed("p1_fire"):
		_selected = wrapi(_selected - 1, 0, _items.size())
		Audio.play_sfx("menu_change")
		_refresh()
	elif event.is_action_pressed("ui_left") or event.is_action_pressed("ui_right") or event.is_action_pressed("ui_accept"):
		var item := _items[_selected]
		var d := -1 if event.is_action_pressed("ui_left") else 1
		if item.has("activate") and not event.is_action_pressed("ui_left"):
			Audio.play_sfx("menu_selected")
			item["activate"].call()
		elif item.has("change"):
			Audio.play_sfx("menu_change")
			item["change"].call(d)
			_refresh()
