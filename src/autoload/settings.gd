extends Node
## Persistent user settings and input bindings (autoload "Settings").
##
## Stored in user://settings.cfg. Key bindings are applied to the InputMap at startup so the
## rest of the game only ever asks Input for action names.

const PATH := "user://settings.cfg"

## Default bindings, matching the original game (p1: arrows, p2: x/v/c/d, misc keys).
const DEFAULT_KEYS := {
	"p1_left": [KEY_LEFT],
	"p1_right": [KEY_RIGHT],
	"p1_fire": [KEY_UP],
	"p1_center": [KEY_DOWN],
	"p2_left": [KEY_X],
	"p2_right": [KEY_V],
	"p2_fire": [KEY_C],
	"p2_center": [KEY_D],
	"fullscreen": [KEY_F],
	"chat": [KEY_ENTER],
	"pause": [KEY_P],
	"back": [KEY_ESCAPE],
	"target_1": [KEY_F1],
	"target_2": [KEY_F2],
	"target_3": [KEY_F3],
	"target_4": [KEY_F4],
	"target_all": [KEY_F10],
	"next_track": [KEY_TAB],
	"toggle_music": [KEY_F11],
	"toggle_sfx": [KEY_F12],
	"volume_up": [KEY_KP_ADD],
	"volume_down": [KEY_KP_SUBTRACT],
	"screenshot": [KEY_PRINT],
}

## Default gamepad bindings (device 0 for player 1, device 1 for player 2): left stick or
## d-pad to aim, the bottom face button fires, the right face button centres.
static var DEFAULT_JOY := {
	"p1_left": func(): return _joy_axis(0, JOY_AXIS_LEFT_X, -1.0),
	"p1_right": func(): return _joy_axis(0, JOY_AXIS_LEFT_X, 1.0),
	"p1_fire": func(): return _joy_button(0, JOY_BUTTON_A),
	"p1_center": func(): return _joy_button(0, JOY_BUTTON_B),
	"p2_left": func(): return _joy_axis(1, JOY_AXIS_LEFT_X, -1.0),
	"p2_right": func(): return _joy_axis(1, JOY_AXIS_LEFT_X, 1.0),
	"p2_fire": func(): return _joy_button(1, JOY_BUTTON_A),
	"p2_center": func(): return _joy_button(1, JOY_BUTTON_B),
}

var fullscreen := false
var integer_scale := false
var music_enabled := true
var sfx_enabled := true
var volume := 1.0
var nick := ""
## Last internet server joined ("host:port").
var last_server := ""
## Public relay server offered first in the internet lobby ("host:port", may be empty).
var default_server := ""
var colourblind := false
## Bubble art: "classic" (the original paintings, upscaled) or "smooth" (procedural, any size).
var bubble_style := "classic"
## Malus bubbles avoid columns that would end the game at once (--no-instant-death).
var no_instant_death := false
## Local 2p handicap (--player-malus): extra malus produced by player 1, fewer by player 2.
var player_malus := 0
var locale := ""
var keys := {}
## Optional joypad event per action (InputEventJoypadButton / InputEventJoypadMotion), set
## from the key configuration screen. Not persisted yet.
var joy := {}


func _ready() -> void:
	load_settings()
	apply_input_map()
	apply_video()
	Input.mouse_mode = Input.MOUSE_MODE_HIDDEN  # like the original; the editor shows it
	if locale != "":
		TranslationServer.set_locale(locale)


func load_settings() -> void:
	keys = DEFAULT_KEYS.duplicate(true)
	var cfg := ConfigFile.new()
	if cfg.load(PATH) != OK:
		return
	fullscreen = cfg.get_value("video", "fullscreen", fullscreen)
	integer_scale = cfg.get_value("video", "integer_scale", integer_scale)
	music_enabled = cfg.get_value("audio", "music", music_enabled)
	sfx_enabled = cfg.get_value("audio", "sfx", sfx_enabled)
	volume = clampf(float(cfg.get_value("audio", "volume", volume)), 0.0, 1.0)
	nick = cfg.get_value("player", "nick", nick)
	last_server = cfg.get_value("player", "last_server", last_server)
	default_server = cfg.get_value("player", "default_server", default_server)
	colourblind = cfg.get_value("player", "colourblind", colourblind)
	bubble_style = cfg.get_value("video", "bubble_style", bubble_style)
	no_instant_death = cfg.get_value("player", "no_instant_death", no_instant_death)
	player_malus = clampi(int(cfg.get_value("player", "player_malus", player_malus)), -3, 3)
	locale = cfg.get_value("ui", "locale", locale)
	for action in DEFAULT_KEYS:
		var stored = cfg.get_value("keys", action, null)
		if stored is Array:
			var codes: Array = []
			for name in stored:
				var code := OS.find_keycode_from_string(str(name))
				if code != KEY_NONE:
					codes.append(code)
			if not codes.is_empty():
				keys[action] = codes


func save_settings() -> void:
	var cfg := ConfigFile.new()
	cfg.set_value("video", "fullscreen", fullscreen)
	cfg.set_value("video", "integer_scale", integer_scale)
	cfg.set_value("audio", "music", music_enabled)
	cfg.set_value("audio", "sfx", sfx_enabled)
	cfg.set_value("audio", "volume", volume)
	cfg.set_value("player", "nick", nick)
	cfg.set_value("player", "last_server", last_server)
	cfg.set_value("player", "default_server", default_server)
	cfg.set_value("player", "colourblind", colourblind)
	cfg.set_value("video", "bubble_style", bubble_style)
	cfg.set_value("player", "no_instant_death", no_instant_death)
	cfg.set_value("player", "player_malus", player_malus)
	cfg.set_value("ui", "locale", locale)
	for action in keys:
		var names: Array = []
		for code in keys[action]:
			names.append(OS.get_keycode_string(code))
		cfg.set_value("keys", action, names)
	cfg.save(PATH)


## (Re)creates every game action in the InputMap from [member keys].
func apply_input_map() -> void:
	for action in keys:
		if InputMap.has_action(action):
			InputMap.erase_action(action)
		InputMap.add_action(action)
		for code in keys[action]:
			var ev := InputEventKey.new()
			ev.physical_keycode = code
			InputMap.action_add_event(action, ev)
		if joy.get(action) != null:
			InputMap.action_add_event(action, joy[action])
		elif DEFAULT_JOY.has(action):
			InputMap.action_add_event(action, DEFAULT_JOY[action].call())


func set_joy(action: String, event: InputEvent) -> void:
	if event == null:
		joy.erase(action)
	else:
		joy[action] = event


func set_key(action: String, keycode: Key) -> void:
	keys[action] = [keycode]
	apply_input_map()


func apply_video() -> void:
	Art.style = "" if bubble_style == "classic" else bubble_style
	var window := get_window()
	window.mode = Window.MODE_FULLSCREEN if fullscreen else Window.MODE_WINDOWED
	window.content_scale_stretch = Window.CONTENT_SCALE_STRETCH_INTEGER if integer_scale else Window.CONTENT_SCALE_STRETCH_FRACTIONAL


func toggle_fullscreen() -> void:
	fullscreen = not fullscreen
	apply_video()
	save_settings()


static func _joy_axis(device: int, axis: JoyAxis, value: float) -> InputEventJoypadMotion:
	var ev := InputEventJoypadMotion.new()
	ev.device = device
	ev.axis = axis
	ev.axis_value = value
	return ev


static func _joy_button(device: int, button: JoyButton) -> InputEventJoypadButton:
	var ev := InputEventJoypadButton.new()
	ev.device = device
	ev.button_index = button
	return ev
