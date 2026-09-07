extends Node2D
## Main menu, laid out and animated like the original (bin/frozen-bubble:5485-6020):
## eight entries at (89, 14 + 56 i) with a 40x30 animated icon at (248, y + 8), the selected
## entry's icon animating at 50 fps and the others frozen at half alpha with occasional
## "broken" static; a credits banner scrolling right-to-left through x 304..596 at y 243;
## the two penguins blinking; and the 1-player sub-menu on a wooden panel.
## Down/Right and Up/Left move, Return/Space activate, Escape quits.

enum State { MAIN, SUB1P, DIALOG }

const ENTRY_X := 89
const FIRST_Y := 14
const SPACING := 56
const ICON_X := 248
const ICON_DY := 8
## [entry name, icon sequence, frames to use (0 = all), label (translatable)]
const ENTRIES := [
	["1pgame", "1pgame", 0, "Start 1 player game"],
	["2pgame", "p1p2", 0, "Start 2 players game"],
	["langame", "langame", 70, "Start LAN game"],
	["netgame", "netgame", 0, "Start Internet game"],
	["editor", "editor", 0, "Level editor"],
	["graphics", "gfx-l1", 0, "Options"],
	["keys", "keys", 0, "Change keys"],
	["highscores", "highscore", 0, "High scores"],
]
const PLATE_SIZE := Vector2(202, 46)
const LABEL_WIDTH := 134.0
const TEXT_OFF := Color(0.62, 0.12, 0.5)
const TEXT_OFF_OUTLINE := Color(1.0, 0.85, 0.95, 0.6)
const TEXT_OVER := Color.WHITE
const TEXT_OVER_OUTLINE := Color(0.35, 0.05, 0.3)
const BANNER_MINX := 304
const BANNER_MAXX := 596
const BANNER_Y := 243
const BANNER_START := 1000
const BANNER_SPACING := 80
const BANNER_HEIGHT := 20
const BANNER_TEXT_SIZE := 14
## Scrolling credits, replacing the original's baked banner images so they can be translated
## and stay sharp. Each entry is the role, the people, and the bubble colour of its icon.
const BANNER_CREDITS := [
	{"role": "Artwork", "names": "Alexis Younes (Ayo) and Amaury Amblard Ladurantie", "bubble": 7},
	{"role": "Soundtrack", "names": "Matthias Le Bidan", "bubble": 5},
	{"role": "CPU control", "names": "Guillaume Cottenceau", "bubble": 4},
	{"role": "Level editor", "names": "Kim and David Johan", "bubble": 3},
	{"role": "Godot port", "names": "Blagovest Petrov", "bubble": 8},
]
const EYES := {
	"green": [[Vector2(411, 385), "left-green"], [Vector2(434, 378), "right-green"]],
	"purple": [[Vector2(522, 356), "left-purple"], [Vector2(535, 356), "right-purple"]],
}
const PANEL_POS := Vector2(149, 100)
const SUB_X := 171
const SUB_FIRST_Y := 190
const SUB_SPACING := 41
const SUB_ROWS := ["play_all_levels", "pick_start_level", "play_random_levels", "multiplayer_training"]
const SUB_LABELS := ["Play default levelset", "Pick levelset and start level", "Play random levels", "Multiplayer training"]
## The original's "overlook" highlight (CStuff.xs:overlook_, bin/frozen-bubble:3596): a white
## silhouette of the label magnified out of its own centre while fading, over a 70-frame cycle.
## The C version accumulates into a buffer that decays by 0.9 each frame; GHOST_COPIES labels
## started GHOST_GAP frames apart stand in for that trail.
const OVERLOOK_FRAMES := 70
const GHOST_COPIES := 6
const GHOST_GAP := 4
const GHOST_FADE := 0.9  # the C effect's per-frame decay of the accumulation buffer
const GHOST_ZOOM := Vector2(0.12, 0.34)  # magnification reached at the end of the cycle

## State that survives leaving the menu, like the original's globals.
static var selected := 0
static var banner_pos := 670
static var icon_frame := {}
static var logo_index := 0
const DEMO_DIR := "res://assets/demos/"
const IDLE_FRAMES_BEFORE_DEMO := 1000
var _idle := 0

var state := State.MAIN
var _plates: Array[Sprite2D] = []
var _labels: Array[Label] = []
var _icons: Array[Sprite2D] = []
var _icon_frames: Array[SpriteFrames] = []
var _icon_counts: Array[int] = []
var _broken := {}
var _pixelize: ShaderMaterial
var _banners: Array = []
var _banner_max := 0
var _banner_clip: Control
var _eyes := {}
var _logo: Node2D
var _sub: Node2D
var _sub_plates: Array[Sprite2D] = []
var _sub_labels: Array[Label] = []
var _sub_ghosts: Array[Label] = []
var _overlook_step := 0
var _sub_selected := 0
var _dialog: AskDialog


func _ready() -> void:
	$Background.texture = Art.tex("res://assets/gfx/menu/back_start.png")
	_build_logo()
	_build_entries()
	_build_banner()
	_build_eyes()
	_build_submenu()
	_refresh_entries()
	Audio.play_music("introzik")


# --- building --------------------------------------------------------------------------------

func _build_logo() -> void:
	# the importer renders the tag (tools/import_assets.py: render_logo)
	_logo = Node2D.new()
	_logo.position = Vector2(400 + 95, 15 + 59)
	add_child(_logo)
	var art := Sprite2D.new()
	art.texture = Art.tex("res://assets/gfx/gen/logo.png")
	_logo.add_child(art)


func _build_entries() -> void:
	_pixelize = ShaderMaterial.new()
	_pixelize.shader = load("res://src/shaders/pixelize.gdshader")
	for i in ENTRIES.size():
		var y := FIRST_Y + SPACING * i
		var plate := Sprite2D.new()
		plate.centered = false
		plate.position = Vector2(ENTRY_X, y)
		add_child(plate)
		_plates.append(plate)
		var label := UiText.funky(tr(ENTRIES[i][3]), 17)
		label.clip_text = true  # before size: otherwise the label is clamped to its text width
		label.autowrap_mode = TextServer.AUTOWRAP_OFF
		label.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
		label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		label.position = Vector2(ENTRY_X + 8, y)
		label.size = Vector2(LABEL_WIDTH, PLATE_SIZE.y)  # leaves room for the icon
		add_child(label)
		_labels.append(label)
		var frames: SpriteFrames = Art.frames("res://assets/gfx/menu/anims/%s.tres" % ENTRIES[i][1])
		var count: int = ENTRIES[i][2] if ENTRIES[i][2] > 0 else frames.get_frame_count("default")
		_icon_frames.append(frames)
		_icon_counts.append(count)
		var icon := Sprite2D.new()
		icon.centered = false
		icon.position = Vector2(ICON_X, y + ICON_DY)
		add_child(icon)
		_icons.append(icon)
		if not icon_frame.has(i):
			icon_frame[i] = 0


func _build_banner() -> void:
	_banner_clip = Control.new()
	_banner_clip.name = "Credits"
	_banner_clip.position = Vector2(BANNER_MINX, BANNER_Y)
	_banner_clip.size = Vector2(BANNER_MAXX - BANNER_MINX, BANNER_HEIGHT)
	_banner_clip.clip_contents = true
	_banner_clip.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_banner_clip)
	var x := BANNER_START
	for credit in BANNER_CREDITS:
		var item := Control.new()
		item.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var icon := Sprite2D.new()
		icon.centered = false
		icon.texture = BubbleArt.bubble(int(credit["bubble"]) - 1, false, true)
		icon.position = Vector2(0, 2)
		item.add_child(icon)
		var role: String = credit["role"]
		var names: String = credit["names"]
		var label := UiText.funky("%s: %s" % [tr(role), names], BANNER_TEXT_SIZE)
		label.position = Vector2(21, 0)
		label.size = Vector2(600, BANNER_HEIGHT)
		label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		item.add_child(label)
		var text_width: float = UiText.display_font().get_string_size(
			label.text, HORIZONTAL_ALIGNMENT_LEFT, -1, BANNER_TEXT_SIZE).x
		var width := int(21 + text_width + 6)
		_banner_clip.add_child(item)
		_banners.append([item, x, width])
		x += width + BANNER_SPACING
	# banners_max = last_start - (640 - strip_width) + spacing, as in the original
	_banner_max = _banners[_banners.size() - 1][1] - (640 - (BANNER_MAXX - BANNER_MINX)) + BANNER_SPACING
	_move_banner()


func _build_eyes() -> void:
	for penguin in EYES:
		var sprites: Array[Sprite2D] = []
		for eye in EYES[penguin]:
			var s := Sprite2D.new()
			s.centered = false
			s.position = eye[0]
			s.texture = Art.tex("res://assets/gfx/menu/backgrnd-closedeye-%s.png" % eye[1])
			s.visible = false
			add_child(s)
			sprites.append(s)
		_eyes[penguin] = {"sprites": sprites, "counter": 0}


func _build_submenu() -> void:
	_sub = Node2D.new()
	_sub.visible = false
	add_child(_sub)
	var panel := Sprite2D.new()
	panel.centered = false
	panel.texture = Art.tex("res://assets/gfx/menu/panel_clean.png")
	panel.position = PANEL_POS
	_sub.add_child(panel)
	var title := UiText.make(tr("Start 1-player game menu"), 13)
	title.position = Vector2(PANEL_POS.x, 116)
	title.size = Vector2(341, 18)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_sub.add_child(title)
	for i in SUB_ROWS.size():
		var y := SUB_FIRST_Y + SUB_SPACING * i
		var plate := Sprite2D.new()
		plate.centered = false
		plate.position = Vector2(SUB_X, y)
		_sub.add_child(plate)
		_sub_plates.append(plate)
		# white "overlook" ghosts behind the text, oldest first so the freshest draws on top
		for k in GHOST_COPIES:
			var ghost := UiText.funky(tr(SUB_LABELS[i]), 16, Color.WHITE, Color(1, 1, 1, 0))
			ghost.clip_text = true
			ghost.position = Vector2(SUB_X + 8, y)
			ghost.size = Vector2(298 - 60, 37)
			ghost.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
			ghost.visible = false
			UiText.fit(ghost, 298 - 64, 16)
			# magnify around the centre of the glyphs, not of the (wider, left-aligned) box;
			# the original picks a pivot per label too (bin/frozen-bubble:3597 %name2pivot)
			var text_width: float = UiText.display_font().get_string_size(
				ghost.text, HORIZONTAL_ALIGNMENT_LEFT, -1, ghost.get_theme_font_size("font_size")).x
			ghost.pivot_offset = Vector2(text_width / 2.0, ghost.size.y / 2.0)
			_sub.add_child(ghost)
			_sub_ghosts.append(ghost)
		var text := UiText.funky(tr(SUB_LABELS[i]), 16, Color.WHITE, Color(0.3, 0.15, 0.05))
		text.clip_text = true
		text.position = Vector2(SUB_X + 8, y)
		text.size = Vector2(298 - 60, 37)
		text.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		UiText.fit(text, 298 - 64, 16)
		_sub.add_child(text)
		_sub_labels.append(text)


# --- per frame -------------------------------------------------------------------------------

func _refresh_entries() -> void:
	for i in ENTRIES.size():
		var over := i == selected
		_plates[i].texture = Art.tex("res://assets/gfx/menu/plate_%s.png" % ("over" if over else "off"))
		_labels[i].add_theme_color_override("font_color", TEXT_OVER if over else TEXT_OFF)
		_labels[i].add_theme_color_override("font_outline_color", TEXT_OVER_OUTLINE if over else TEXT_OFF_OUTLINE)
		UiText.fit(_labels[i], LABEL_WIDTH, 17)
		_icons[i].modulate.a = 1.0 if over else 0.5
		if over:
			_icons[i].material = null
			_broken.erase(i)
		_set_icon_frame(i)


func _set_icon_frame(i: int) -> void:
	_icons[i].texture = _icon_frames[i].get_frame_texture("default", icon_frame[i] % _icon_counts[i])


func _refresh_submenu() -> void:
	_overlook_step = 0
	for i in SUB_ROWS.size():
		_sub_plates[i].texture = Art.tex("res://assets/gfx/menu/txt_menu_1p_%s.png" % ("over" if i == _sub_selected else "off"))
		for k in GHOST_COPIES:
			_sub_ghosts[i * GHOST_COPIES + k].visible = false


func _physics_process(_delta: float) -> void:
	if state == State.MAIN:
		_idle += 1
		if _idle >= IDLE_FRAMES_BEFORE_DEMO:
			_idle = 0
			_start_demo()
	_animate_icons()
	if _sub.visible:
		_animate_overlook()
	banner_pos += 1
	if banner_pos >= _banner_max:
		banner_pos = 1
	_move_banner()
	_blink_eyes()
	logo_index += 1
	_logo.rotation = sin(logo_index / 40.0) / 20.0


## One step of the "overlook" highlight on the selected sub-menu row.
func _animate_overlook() -> void:
	for k in GHOST_COPIES:
		var g: Label = _sub_ghosts[_sub_selected * GHOST_COPIES + k]
		# wrap into the previous cycle so a trail copy never disappears mid-fade
		var step := posmod(_overlook_step - k * GHOST_GAP, OVERLOOK_FRAMES)
		var t := float(step) / float(OVERLOOK_FRAMES)
		g.visible = true
		g.modulate.a = maxf(0.0, 1.0 - t) * pow(GHOST_FADE, float(k * GHOST_GAP))
		g.scale = Vector2.ONE + GHOST_ZOOM * t
	_overlook_step = (_overlook_step + 1) % OVERLOOK_FRAMES


func _animate_icons() -> void:
	for i in ENTRIES.size():
		if i == selected:
			icon_frame[i] = (icon_frame[i] + 1) % _icon_counts[i]
			_set_icon_frame(i)
		elif _broken.has(i):
			_broken[i] -= 1
			if _broken[i] > 0:
				_pixelize.set_shader_parameter("seed", randf() * 100.0)
				_icons[i].material = _pixelize
			else:
				_broken.erase(i)
				_icons[i].material = null
		elif randf() < 0.001:
			_broken[i] = int(20 + 10 * cos(randf() * TAU))


## Slide the credit labels through the strip; the clipping Control hides what leaves it.
func _move_banner() -> void:
	for b in _banners:
		var item: Control = b[0]
		var xpos: int = b[1] - banner_pos
		if xpos > _banner_max / 2:
			xpos = b[1] - (banner_pos + _banner_max)
		item.position = Vector2(xpos, 0)


func _blink_eyes() -> void:
	for penguin in _eyes:
		var e: Dictionary = _eyes[penguin]
		var c: int = e["counter"]
		if c > 0:
			c -= 1
			if c == 0:
				_set_eyes(e, false)
				if randf() * 3.0 <= 1.0:
					c = -5
		elif c < 0:
			c += 1
			if c == 0:
				c = 3
				_set_eyes(e, true)
		elif randf() * 200.0 <= 1.0:
			c = 3
			_set_eyes(e, true)
		e["counter"] = c


func _set_eyes(e: Dictionary, closed: bool) -> void:
	for s in e["sprites"]:
		s.visible = closed


# --- input -----------------------------------------------------------------------------------

## Attract mode: after 20 s without a key press, replay a bundled demo (bin/frozen-bubble:5980).
func _start_demo() -> void:
	var demos: Array[String] = []
	for f in DirAccess.get_files_at(DEMO_DIR):
		if f.ends_with(Replay.EXT):
			demos.append(f)
	if demos.is_empty():
		return
	Session.replay_path = DEMO_DIR + demos[randi() % demos.size()]
	Session.attract = true
	Screens.goto(Screens.GAME)


func _unhandled_input(event: InputEvent) -> void:
	if not (event is InputEventKey) or not event.pressed or event.echo:
		return
	_idle = 0
	var key := (event as InputEventKey).keycode
	match state:
		State.MAIN:
			_main_input(key)
		State.SUB1P:
			_sub_input(key)
		State.DIALOG:
			pass


func _main_input(key: Key) -> void:
	if key in [KEY_DOWN, KEY_RIGHT]:
		selected = (selected + 1) % ENTRIES.size()
		Audio.play_sfx("menu_change")
		_refresh_entries()
	elif key in [KEY_UP, KEY_LEFT]:
		selected = (selected - 1 + ENTRIES.size()) % ENTRIES.size()
		Audio.play_sfx("menu_change")
		_refresh_entries()
	elif key in [KEY_ENTER, KEY_KP_ENTER, KEY_SPACE]:
		Audio.play_sfx("menu_selected")
		_activate(ENTRIES[selected][0])
	elif key == KEY_ESCAPE:
		Screens.quit_game()
	elif key == KEY_F:
		Settings.toggle_fullscreen()
	elif key == KEY_F11:
		Audio.toggle_music()
	elif key == KEY_F12:
		Audio.toggle_sfx()


func _activate(entry: String) -> void:
	match entry:
		"1pgame":
			state = State.SUB1P
			_sub.visible = true
			_refresh_submenu()
		"2pgame":
			_ask_chain_reaction(tr("2-player game"), Session.Mode.VERSUS)
		"langame", "netgame":
			Session.net_kind = "lan" if entry == "langame" else "net"
			Screens.goto(Screens.LOBBY)
		"editor":
			Screens.goto(Screens.EDITOR)
		"graphics":
			Screens.goto(Screens.OPTIONS)
		"keys":
			Screens.goto(Screens.KEYS)
		"highscores":
			Screens.goto(Screens.HIGH_SCORES)
		_:
			_show_message([tr("Not available yet"), "", tr("This part of Boreal Bounce is still being built.")])


func _sub_input(key: Key) -> void:
	if key == KEY_DOWN:
		_sub_selected = (_sub_selected + 1) % SUB_ROWS.size()
		Audio.play_sfx("menu_change")
		_refresh_submenu()
	elif key == KEY_UP:
		_sub_selected = (_sub_selected - 1 + SUB_ROWS.size()) % SUB_ROWS.size()
		Audio.play_sfx("menu_change")
		_refresh_submenu()
	elif key == KEY_ESCAPE:
		state = State.MAIN
		_sub.visible = false
	elif key in [KEY_ENTER, KEY_KP_ENTER]:
		match SUB_ROWS[_sub_selected]:
			"play_all_levels":
				_start_game(Session.Mode.LEVELS, 1)
			"pick_start_level":
				Session.editor_pick = true
				Screens.goto(Screens.EDITOR)
			"play_random_levels":
				_ask_chain_reaction(tr("Random level"), Session.Mode.RANDOM)
			"multiplayer_training":
				_ask_chain_reaction(tr("Multiplayer training"), Session.Mode.TRAINING)


func _ask_chain_reaction(title: String, mode: Session.Mode) -> void:
	state = State.DIALOG
	_dialog = AskDialog.create([title, "", "", tr("Enable chain-reaction?"), ""], tr("%s or %s?") % ["Y", "N"], AskDialog.Mode.ONE_CHAR, tr("Enjoy the game!"))
	add_child(_dialog)
	_dialog.answered.connect(func(k):
		Session.chain_reaction = k == KEY_Y
		await get_tree().create_timer(1.0).timeout
		_start_game(mode, 1))
	_dialog.cancelled.connect(func():
		_dialog.queue_free()
		_sub.visible = false
		state = State.MAIN)


func _show_message(lines: Array) -> void:
	state = State.DIALOG
	_dialog = AskDialog.create(lines, tr("Press any key"), AskDialog.Mode.ONE_CHAR)
	add_child(_dialog)
	var back := func(_v = null):
		_dialog.queue_free()
		state = State.SUB1P if _sub.visible else State.MAIN
	_dialog.answered.connect(back)
	_dialog.cancelled.connect(back)


func _start_game(mode: Session.Mode, level: int) -> void:
	Session.mode = mode
	Session.start_level = level
	Session.reset_for_new_game()
	Audio.play_music("frozen-mainzik-2p" if mode == Session.Mode.VERSUS else "frozen-mainzik-1p")
	Screens.goto(Screens.GAME, true)
