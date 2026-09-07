extends Node
## Development aid (autoload "Debug"): `godot --path . -- --screenshot=/tmp/shot.png [--frames=N]` runs N
## physics frames (default 30; 50 per second, same as the simulation), saves the viewport to
## the given PNG and quits. Lets the game be checked
## visually from a script or CI without anyone watching the window. Also `--quit-after=N`.
## `--autoplay` presses the player-1 keys on a fixed schedule (aim left/right, fire every
## 45 frames) so screenshots show the game in motion. `--scene=game|menu|intro|options|keys|scores`
## starts on that screen; `--level=N` picks the level; `--seed=S` fixes the RNG;
## `--press=30:Down,45:Enter` presses keys (Godot key names) at those physics frames;
## `--click=30:x:y[:right],...` clicks at logical 640x480 coordinates; `--bubbles=smooth` picks
## the bubble style; `--result=lose|win` pops the end-of-game board; `--locale=xx` forces a language; `--host[=port]` / `--join=host:port` open the lobby connected, `--auto-net`
## readies clients and starts the round from the host, `--room=new|first|CODE` creates or joins
## a room on a dedicated server, `--nick=NAME` sets the nick,
## `--server[=port]` runs a headless dedicated server;
## `--ai=p1,p2` lets the computer play those slots; `--record-demo=PATH` saves the last
## complete level/round as a replay on exit; `--replay=PATH` plays a recording.

var _path := ""
var _result := ""
var _frames := 30
var _quit_after := -1
var _autoplay := false
var _pause_at := -1
var _presses := {}
var _clicks := {}
var _record_path := ""
var _net_host := -1
var _net_join := ""
var _net_auto := false
var _net_done := false
var _room := ""
var _tick := 0


func _ready() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--level="):
			Session.start_level = int(arg.get_slice("=", 1))
		elif arg.begins_with("--screenshot="):
			_path = arg.get_slice("=", 1)
		elif arg.begins_with("--frames="):
			_frames = int(arg.get_slice("=", 1))
		elif arg.begins_with("--quit-after="):
			_quit_after = int(arg.get_slice("=", 1))
		elif arg == "--autoplay":
			_autoplay = true
		elif arg == "--fake-scores":
			Session.fake_scores = true
		elif arg.begins_with("--mode="):
			Session.mode = {"levels": Session.Mode.LEVELS, "random": Session.Mode.RANDOM,
				"training": Session.Mode.TRAINING, "versus": Session.Mode.VERSUS}.get(arg.get_slice("=", 1), Session.Mode.LEVELS)
		elif arg == "--chain":
			Session.chain_reaction = true
		elif arg.begins_with("--result="):
			_result = arg.get_slice("=", 1)
		elif arg == "--no-hd":
			Art.use_hd = false
		elif arg.begins_with("--locale="):
			Settings.locale = arg.get_slice("=", 1)
			TranslationServer.set_locale(Settings.locale)
		elif arg.begins_with("--bubbles="):
			Settings.bubble_style = arg.get_slice("=", 1)
			Art.style = "" if Settings.bubble_style == "classic" else Settings.bubble_style
			Settings.apply_video()
		elif arg.begins_with("--click="):
			for item in arg.get_slice("=", 1).split(","):
				var parts := item.split(":")
				var frame := int(parts[0])
				if not _clicks.has(frame):
					_clicks[frame] = []
				_clicks[frame].append([float(parts[1]), float(parts[2]), parts.size() > 3 and parts[3] == "right"])
		elif arg.begins_with("--replay="):
			Session.replay_path = arg.get_slice("=", 1)
		elif arg.begins_with("--record-demo="):
			_record_path = arg.get_slice("=", 1)
		elif arg.begins_with("--host"):
			_net_host = int(arg.get_slice("=", 1)) if arg.contains("=") else Net.DEFAULT_PORT
		elif arg.begins_with("--join="):
			_net_join = arg.get_slice("=", 1)
		elif arg == "--auto-net":
			_net_auto = true
		elif arg.begins_with("--room="):
			_room = arg.get_slice("=", 1)
		elif arg.begins_with("--nick="):
			Settings.nick = arg.get_slice("=", 1)
		elif arg.begins_with("--server"):
			var port := int(arg.get_slice("=", 1)) if arg.contains("=") else Net.DEFAULT_PORT
			_start_dedicated.call_deferred(port)
		elif arg.begins_with("--pause-at="):
			_pause_at = int(arg.get_slice("=", 1))
		elif arg.begins_with("--press="):
			for item in arg.get_slice("=", 1).split(","):
				var frame := int(item.get_slice(":", 0))
				var key := OS.find_keycode_from_string(item.get_slice(":", 1))
				if not _presses.has(frame):
					_presses[frame] = []
				_presses[frame].append(key)
	if _path != "" or _quit_after > 0:
		_run.call_deferred()
	if _net_host >= 0 or _net_join != "":
		_start_net.call_deferred()
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--scene="):
			var which := arg.get_slice("=", 1)
			var target: String = {"game": Screens.GAME, "menu": Screens.MENU, "intro": Screens.INTRO,
				"options": Screens.OPTIONS, "keys": Screens.KEYS, "scores": Screens.HIGH_SCORES, "editor": Screens.EDITOR, "fonttest": "res://src/debug/font_test.tscn"}.get(which, "")
			if target != "":
				Screens.intro_shown = true
				Screens.goto(target)


func _start_dedicated(port: int) -> void:
	Screens.intro_shown = true
	var err := Net.host(port, "", true)
	print("dedicated server on port %d: %s" % [port, error_string(err)])
	Screens.goto("res://server/server.tscn")


func _start_net() -> void:
	Screens.intro_shown = true
	Session.net_kind = "lan"
	if _net_host >= 0:
		Net.host(_net_host, Settings.nick)
	else:
		Net.join(_net_join.get_slice(":", 0), int(_net_join.get_slice(":", 1)) if _net_join.contains(":") else Net.DEFAULT_PORT, Settings.nick)
	Screens.goto(Screens.LOBBY)


func _run() -> void:
	var n := _frames if _path != "" else _quit_after
	for i in n:
		await get_tree().physics_frame
	if _result != "":
		var scene := get_tree().current_scene
		if scene != null and scene.has_method("_show_result"):
			scene.call("_show_result", tr("Loser!") if _result == "lose" else tr("Winner!"),
				"p1", "loose" if _result == "lose" else "win")
			await get_tree().process_frame
	await RenderingServer.frame_post_draw
	if _path != "":
		var img := get_viewport().get_texture().get_image()
		var err := img.save_png(_path)
		print("screenshot %s -> %s" % [_path, error_string(err)])
	if _record_path != "":
		var scene := get_tree().current_scene
		if scene != null and scene.has_method("save_record"):
			print("record %s -> %s" % [_record_path, error_string(scene.save_record(_record_path))])
	get_tree().quit()


func _physics_process(_delta: float) -> void:
	_tick += 1
	if _tick == _pause_at:
		var ev := InputEventAction.new()
		ev.action = "pause"
		ev.pressed = true
		Input.parse_input_event(ev)
	if _room != "" and Net.connected and Net.dedicated and not Net.in_room() and _tick % 25 == 0:
		if _room == "new":
			Net.create_room()
			_room = ""
		elif _room == "first":
			if not Net.rooms.is_empty():
				Net.join_room(Net.rooms[0]["code"])
				_room = ""
		else:
			Net.join_room(_room)
			_room = ""
	if _net_auto and not _net_done and Net.in_room() and not Net.in_game and _tick % 25 == 0:
		# clients: ready up; host: start once everyone is ready
		if Net.is_host_player():
			if Net.all_ready():
				Net.request_start()
				_net_done = true
		elif Net.players.has(Net.my_id()) and not Net.players[Net.my_id()]["ready"]:
			Net.set_ready(true)
	if _clicks.has(_tick):
		var scale := DisplayServer.window_get_size().y / 480.0
		for c in _clicks[_tick]:
			var pos := (Vector2(c[0], c[1]) + Screens.content_offset) * scale
			var move := InputEventMouseMotion.new()
			move.position = pos
			move.global_position = pos
			Input.parse_input_event(move)
			for pressed in [true, false]:
				var mb := InputEventMouseButton.new()
				mb.position = pos
				mb.global_position = pos
				mb.button_index = MOUSE_BUTTON_RIGHT if c[2] else MOUSE_BUTTON_LEFT
				mb.pressed = pressed
				Input.parse_input_event(mb)
	if _presses.has(_tick):
		for key in _presses[_tick]:
			var down := InputEventKey.new()
			down.keycode = key
			down.physical_keycode = key
			down.unicode = key if key < 128 else 0
			down.pressed = true
			Input.parse_input_event(down)
			var up := InputEventKey.new()
			up.keycode = key
			up.physical_keycode = key
			up.pressed = false
			Input.parse_input_event(up)
	if not _autoplay:
		return
	var phase := _tick % 90
	_press("p1_left", phase >= 5 and phase < 25)
	_press("p1_right", phase >= 50 and phase < 60)
	_press("p1_fire", phase == 30 or phase == 75)


func _press(action: String, pressed: bool) -> void:
	if pressed:
		Input.action_press(action)
	else:
		Input.action_release(action)
