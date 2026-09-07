extends Node2D
## Game screen for every mode: runs the simulation at 50 Hz and drives one PlayfieldView per
## player. The mode comes from Session (set by the menu). Escape returns to the menu after the
## high-score check.

enum Phase { PLAYING, WON, LOST, OVER }

@onready var background: Sprite2D = $Background
@onready var panel: Sprite2D = $Panel
@onready var pause_overlay: Node2D = $PauseOverlay
@onready var pause_anim: Sprite2D = $PauseOverlay/Anim

var levelset: LevelSet
var level_index := 0
var sim: Sim
var views := {}
var labels := {}
var slots: Array[String] = []
var phase := Phase.PLAYING
var seed_override := -1
var paused := false
var _pause_frame := 0
var _pause_frames: SpriteFrames
var _pause_started_msec := 0
var _ending := false
var _wins := {"p1": 0, "p2": 0}
var _time_box: Sprite2D
var _time_label: Label
var _message: Node2D
var _recorder: Replay
var _finished_record: Replay
var _replay: Replay
var _cursor: Replay.Cursor
var _replay_rules: Rules
var _ai := {}  # slot -> target angle, when the computer plays (demo recording)
## Network play: canonical sim slots ("n<peer>") and how each is displayed on this peer.
var net := false
var local_slot := ""
var display := {}  # sim slot -> display slot ("p1", "p2", "rp1".."rp4")
var _target_slots: Array[String] = []  # display order of the opponents for F1..F4
var _round_reported := false
var _stalled_frames := 0
var _chat_label: Label
var _chat_typing := false
var _chat_text := ""
var _left_overlays := {}


func _ready() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--seed="):
			seed_override = int(arg.get_slice("=", 1))
	_pause_frames = Art.frames("res://assets/gfx/pause.tres")
	pause_overlay.visible = false
	if Session.replay_path != "":
		_replay = Replay.load_file(Session.replay_path)
		if _replay == null:
			push_warning("cannot load replay " + Session.replay_path)
			Session.replay_path = ""
			Session.attract = false
			Screens.goto(Screens.MENU)
			return
		var h: Dictionary = _replay.header
		Session.mode = Session.mode_from_name(str(h.get("mode", "levels")))
		Session.start_level = int(h.get("level", 1))
		_replay_rules = Rules.from_dict(h.get("rules", {}))
		Session.chain_reaction = _replay_rules.chain_reaction
		seed_override = int(h.get("seed", 0))
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--ai="):
			for slot in arg.get_slice("=", 1).split(","):
				_ai[slot] = PI / 2
	if Session.mode == Session.Mode.NETWORK and _ai.has("p1"):
		_ai[Net.slot_of(Net.my_id())] = PI / 2  # the local player has a canonical slot name online
	level_index = Session.start_level - 1
	levelset = LevelSet.load_file(Session.levelset_path)
	net = Session.mode == Session.Mode.NETWORK
	match Session.mode:
		Session.Mode.VERSUS:
			slots = ["p1", "p2"]
			background.texture = Art.tex("res://assets/gfx/backgrnd.png")
		Session.Mode.NETWORK:
			_setup_network_slots()
		_:
			slots = ["p1"]
			background.texture = Art.tex("res://assets/gfx/back_one_player.png")
	for slot in slots:
		var l := UiText.make("", 8 if display.get(slot, slot).begins_with("rp") else 14)
		l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		var layout := _layout(slot)
		l.position = Vector2(layout["scores"]["x"] - 100, layout["scores"]["y"])
		l.size = Vector2(200, 24)
		add_child(l)
		labels[slot] = l
	if net:
		_chat_label = UiText.make("", 10, Color.BLACK)
		var lay := _layout(local_slot)
		_chat_label.position = Vector2(lay["chatting"]["x"], lay["chatting"]["y"] - 2)
		_chat_label.size = Vector2(300, 16)
		add_child(_chat_label)
		Net.player_left.connect(_on_net_player_left)
		Net.disconnected.connect(_on_net_disconnected)
		Net.desync.connect(_on_net_desync)
		Net.game_ended.connect(_on_net_game_ended)
		Net.chat_message.connect(_on_net_chat)
	if Session.mode == Session.Mode.TRAINING:
		_time_box = Sprite2D.new()
		_time_box.centered = false
		_time_box.texture = Art.tex("res://assets/gfx/void_mp_training.png")
		_time_box.position = Vector2(32, 152)
		add_child(_time_box)
		_time_label = UiText.make("", 14)
		_time_label.position = Vector2(32, 177)
		_time_label.size = Vector2(_time_box.texture.get_width(), 24)
		_time_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		add_child(_time_label)
	start_level()
	Audio.play_music("frozen-mainzik-2p" if Session.mode in [Session.Mode.VERSUS, Session.Mode.NETWORK] else "frozen-mainzik-1p")


func _layout(slot: String) -> Dictionary:
	if net:
		var d: String = display[slot]
		return Layouts.POS_2P[d] if slots.size() == 2 else Layouts.POS_MP[d]
	return Layouts.POS_2P[slot] if Session.mode == Session.Mode.VERSUS else Layouts.POS_1P[slot]


## Canonical slots from the server's game info; this peer is "p1", the others "p2" (two
## players) or "rp1".."rp4" (three to five), in canonical order.
func _setup_network_slots() -> void:
	var info: Dictionary = Net.game_info
	slots = []
	for s in info["slots"]:
		slots.append(s)
	local_slot = Net.slot_of(Net.my_id())
	display = {}
	_target_slots = []
	var n := 1
	for s in slots:
		if s == local_slot:
			display[s] = "p1"
		else:
			display[s] = "p2" if slots.size() == 2 else "rp%d" % n
			_target_slots.append(s)
			n += 1
	background.texture = Art.tex("res://assets/gfx/backgrnd.png" if slots.size() == 2 else "res://assets/gfx/back_multiplayer.png")


func _rules() -> Rules:
	var r: Rules
	match Session.mode:
		Session.Mode.NETWORK:
			return Rules.from_dict(Net.game_info.get("rules", {}))
		Session.Mode.VERSUS:
			r = Rules.versus()
		Session.Mode.TRAINING:
			r = Rules.training()
		_:
			r = Rules.single_player()
	r.chain_reaction = Session.chain_reaction and Session.mode != Session.Mode.LEVELS
	r.no_instant_death = Settings.no_instant_death
	r.player_malus = Settings.player_malus
	return r


func start_level() -> void:
	level_index = clampi(level_index, 0, levelset.size() - 1)
	var seed_value := seed_override if seed_override >= 0 else Rng.fresh_seed()
	if net:
		seed_value = int(Net.game_info.get("seed", 0))
	var rules := _replay_rules if _replay != null else _rules()
	sim = Sim.new(rules, seed_value)
	for slot in slots:
		# network games simulate every board at full size; the view scales remote ones down
		sim.add_player(slot, Layouts.POS_1P["p1"] if net else _layout(slot))
	if _replay != null:
		_cursor = Replay.Cursor.new(_replay)
	else:
		if _recorder != null:
			_finished_record = _recorder
		_recorder = Replay.new()
		_recorder.start({"mode": Session.mode_name(Session.mode), "rules": rules.to_dict(), "seed": seed_value,
			"slots": slots.duplicate(), "level": level_index + 1, "levelset": Session.levelset_path.get_file(),
			"date": Time.get_datetime_string_from_system(), "comment": ""})
	if Session.mode == Session.Mode.LEVELS:
		sim.start_level(levelset.get_level(level_index), level_index + 1)
	else:
		sim.start_random_board()
	for slot in slots:
		var field := sim.player(slot)
		if Session.mode == Session.Mode.VERSUS:
			field.score = _wins[slot]
		if views.has(slot):
			views[slot].queue_free()
		var view := PlayfieldView.new()
		view.name = slot.to_upper()
		add_child(view)
		var layout: Dictionary = _layout(slot).duplicate()
		if Session.mode != Session.Mode.VERSUS and not net:
			layout["compressor_xpos_abs"] = Layouts.POS_1P["compressor_xpos"]
		view.setup(display.get(slot, slot), layout, field, sim.rules, Settings.colourblind)
		move_child(view, panel.get_index())
		views[slot] = view
	panel.visible = false
	if _message != null:
		_message.queue_free()
		_message = null
	phase = Phase.PLAYING
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--malus="):  # debug: pre-queue malus for every player
			for slot in slots:
				for i in int(arg.get_slice("=", 1)):
					sim.player(slot).malus_queue.append(-100)
	_refresh_labels()


func _refresh_labels() -> void:
	for slot in slots:
		var field := sim.player(slot)
		var text := ""
		match Session.mode:
			Session.Mode.LEVELS:
				text = tr("Level %s") % str(level_index + 1)
			Session.Mode.RANDOM:
				text = tr("Random level")
			Session.Mode.TRAINING:
				text = tr("Score: %s") % str(field.score)
			Session.Mode.VERSUS:
				text = str(field.score)
			Session.Mode.NETWORK:
				text = str(Net.game_info.get("nicks", {}).get(slot, slot))
		labels[slot].text = text
	if _time_label != null:
		var seconds := sim.training_time_left()
		var m := int(seconds / 60)
		var sec := int(seconds - m * 60)
		_time_label.text = tr("%s'%s\"") % [str(m), "%02d" % sec]


func _physics_process(_delta: float) -> void:
	if _ending or phase == Phase.OVER:
		return
	if paused:
		# pause_0001..0035 once, then loop 0012..0035 (bin/frozen-bubble:1638-1679)
		_pause_frame += 1
		if _pause_frame >= 35:
			_pause_frame = 11
		pause_anim.texture = _pause_frames.get_frame_texture("default", _pause_frame)
		return
	var inputs := {}
	if net:
		_network_tick()
		return
	if _cursor != null:
		if _cursor.finished(sim.frame):
			_end_replay()
			return
		inputs = _cursor.inputs_at(sim.frame)
	else:
		for slot in slots:
			var inp: Dictionary
			if _ai.has(slot):
				inp = _ai_inputs(slot)
			else:
				inp = {
					"left": Input.is_action_pressed(slot + "_left"),
					"right": Input.is_action_pressed(slot + "_right"),
					"fire": Input.is_action_pressed(slot + "_fire"),
					"center": Input.is_action_pressed(slot + "_center"),
				}
			inputs[slot] = inp
		_recorder.record(sim.frame, inputs)
	for slot in slots:
		views[slot].last_inputs = inputs.get(slot, {})
	var events := sim.step(inputs)
	for e in events:
		_handle_event(e)
	for slot in slots:
		views[slot].sync()
	if _time_label != null:
		_refresh_labels()


## Network round: send this peer's inputs for the scheduled frames, then step every frame whose
## merged inputs have arrived (at most three per tick to catch up gently).
func _network_tick() -> void:
	var ls := Net.lockstep
	if ls == null:
		return
	var local := _local_inputs()
	for f in ls.frames_to_send():
		Net.send_input(f, local)
		ls.mark_sent(f)
	var stepped := 0
	while ls.can_step() and stepped < 3:
		if sim.frame % Net.HASH_EVERY == 0 and sim.frame > 0:
			Net.report_hash(sim.frame, sim.state_hash())
		var events := sim.step(ls.take_frame())
		for e in events:
			_handle_event(e)
		stepped += 1
	_stalled_frames = 0 if stepped > 0 else _stalled_frames + 1
	for slot in slots:
		views[slot].last_inputs = {}
		views[slot].sync()
	if _stalled_frames == 100:
		_chat_label.text = tr("Waiting for the other players...")
	_check_round_over()


func _local_inputs() -> Dictionary:
	var inp := {}
	if _ai.has(local_slot):
		inp = _ai_inputs(local_slot)
	elif not _chat_typing:
		inp = {
			"left": Input.is_action_pressed("p1_left"),
			"right": Input.is_action_pressed("p1_right"),
			"fire": Input.is_action_pressed("p1_fire"),
			"center": Input.is_action_pressed("p1_center"),
		}
	var field := sim.player(local_slot)
	var target := field.target
	for i in mini(_target_slots.size(), 4):
		if Input.is_action_just_pressed("target_%d" % (i + 1)):
			target = _target_slots[i]
	if Input.is_action_just_pressed("target_all"):
		target = ""
	inp["target"] = target
	return inp


func _check_round_over() -> void:
	if _round_reported:
		return
	var alive := 0
	var winner := ""
	for slot in slots:
		var f := sim.player(slot)
		if f.is_ingame():
			alive += 1
		elif f.state == Playfield.State.WON:
			winner = slot
	if alive == 0 or winner != "":
		_round_reported = true
		if winner != "":
			var d: String = display[winner]
			_show_result(tr("Winner!") if winner == local_slot else tr("%s wins!") % str(Net.game_info.get("nicks", {}).get(winner, d)), d, "win")
		await get_tree().create_timer(4.0).timeout
		if is_inside_tree():
			Net.report_round_over(winner)


func _on_net_player_left(slot: String) -> void:
	if sim == null or not sim.player(slot):
		return
	sim.player_left(slot)
	Audio.play_sfx("cancel")
	var lay := _layout(slot)
	if lay.has("left") and not _left_overlays.has(slot):
		var s := Sprite2D.new()
		s.centered = false
		var d: String = display[slot]
		s.texture = Art.tex("res://assets/gfx/left-%s-mini.png" % d if d.begins_with("rp") else "res://assets/gfx/left-rp1.png")
		s.position = Vector2(lay["left"]["x"], lay["left"]["y"])
		add_child(s)
		_left_overlays[slot] = s
	views[slot].sync()


func _on_net_disconnected(_reason: String) -> void:
	_ending = true
	Screens.goto(Screens.LOBBY)


func _on_net_desync(frame: int) -> void:
	_chat_label.text = tr("Players went out of sync at frame %s; round cancelled.") % str(frame)
	if Net.is_server():
		await get_tree().create_timer(3.0).timeout
		Net.end_game("")


func _on_net_game_ended() -> void:
	_ending = true
	Screens.goto(Screens.LOBBY)


func _on_net_chat(nick: String, text: String, kind: String) -> void:
	_chat_label.text = ("* %s %s" % [nick, text]) if kind == "me" else (("*** " + text) if kind == "server" else "<%s> %s" % [nick, text])
	Audio.play_sfx("chatted")


func _ai_inputs(slot: String) -> Dictionary:
	var field := sim.player(slot)
	if not field.is_ingame() or field.launcher_colour < 0 or not field.flying.is_empty():
		_ai[slot] = -1.0
		return {}
	if _ai[slot] < 0.0:
		_ai[slot] = Ai.best_angle(field)
	return Ai.inputs_towards(field, _ai[slot])


## Saves the last complete level/round if there is one, else the one in progress.
func save_record(path := "") -> Error:
	var rec := _finished_record if _finished_record != null else _recorder
	if rec == null:
		return ERR_UNAVAILABLE
	var err := rec.save(path if path != "" else Replay.default_path())
	if err == OK:
		Audio.play_sfx("menu_selected")
	return err


func _end_replay() -> void:
	_ending = true
	var attract := Session.attract
	Session.replay_path = ""
	Session.attract = false
	if attract:
		Screens.goto(Screens.MENU, true, "blacken")
	else:
		Screens.goto(Screens.MENU)


## Result panel: wooden board, the winner's/loser's penguin, and the translated word.
## Result board. The original has one baked panel per outcome (`lose_panel.png` for whoever
## loses, `win_panel_<slot>.png` per winner); the fork draws the text and a penguin on a clean
## board so the wording can be translated. The layout follows the originals: the loser's
## penguin sits left of the word, the winner's right of it.
const RESULT_PENGUIN_HEIGHT := 96.0

func _show_result(text: String, penguin_slot: String, state: String) -> void:
	for c in panel.get_children():
		c.queue_free()
	panel.texture = Art.tex("res://assets/gfx/menu/board_result.png")
	panel.visible = true
	var losing := state == "loose"
	# the original's loser board always shows p1's penguin (bin/frozen-bubble:2021); the remote
	# slots only have quarter-size art, too small to blow up onto the board
	var art_slot: String = "p1" if losing or penguin_slot.begins_with("rp") else penguin_slot
	var frames := BubbleArt.penguin(art_slot, state)
	var count := frames.get_frame_count("default")
	# the fall settles into the lying pose the original's panel shows (the lose loop is frames
	# 65..158, bin/frozen-bubble:2942); the winner's jump peaks around frame 30
	var tex := frames.get_frame_texture("default", (count - 1) if losing else mini(30, count - 1))
	var s := Sprite2D.new()
	s.centered = false
	s.texture = tex
	var scale_factor := RESULT_PENGUIN_HEIGHT / float(tex.get_height())
	s.scale = Vector2(scale_factor, scale_factor)
	var art_width := float(tex.get_width()) * scale_factor
	s.position = Vector2(12.0 if losing else 329.0 - art_width - 12.0, 159.0 - RESULT_PENGUIN_HEIGHT - 20.0)
	panel.add_child(s)
	var text_x: float = (art_width + 20.0) if losing else 14.0
	var text_w: float = (329.0 - art_width - 32.0) if losing else 329.0 - 120.0
	var l := UiText.funky(text, 44, Color(1, 0.98, 0.9), Color(0.3, 0.15, 0.05))
	l.position = Vector2(text_x, 0)
	l.size = Vector2(text_w, 159)
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	UiText.fit(l, text_w - 6.0, 44, 16)
	panel.add_child(l)


func _handle_event(e: Dictionary) -> void:
	match e["type"]:
		"launch":
			Audio.play_sfx("launch")
		"rebound":
			Audio.play_sfx("rebound")
		"stick":
			Audio.play_sfx("stick")
		"pop":
			Audio.play_sfx("destroy_group")
		"newroot":
			Audio.play_sfx("newroot_solo" if e["solo"] else "newroot")
		"hurry_on":
			Audio.play_sfx("hurry")
		"malus_launched":
			Audio.play_sfx("malus")
		"malus_produced":
			_refresh_labels()
		"win":
			if Session.mode == Session.Mode.VERSUS:
				_wins[e["slot"]] += 1
				_refresh_labels()
			else:
				phase = Phase.WON
				_show_result(tr("Winner!"), "p1", "win")
		"lose":
			phase = Phase.LOST
			Audio.play_sfx("lose")
		"lose_done":
			if net:
				# the round-over check shows the winner's panel; a local loss while others
				# still play shows the loser panel until then
				if not _round_reported and e["slot"] == local_slot:
					_show_result(tr("Loser!"), "p1", "loose")
					Audio.play_sfx("noh")
			elif Session.mode == Session.Mode.VERSUS:
				var winner := "p2" if e["slot"] == "p1" else "p1"
				_show_result(tr("Winner!"), winner, "win")
			else:
				_show_result(tr("Loser!"), "p1", "loose")
				Audio.play_sfx("noh")
		"training_over":
			_show_training_result(e["score"])


## "Your score after two minutes" panel (bin/frozen-bubble:1141-1155).
func _show_training_result(score: int) -> void:
	phase = Phase.OVER
	_message = Node2D.new()
	add_child(_message)
	var wood := Sprite2D.new()
	wood.centered = false
	wood.texture = Art.tex("res://assets/gfx/menu/panel_clean.png")
	wood.position = Vector2(149, 100)
	_message.add_child(wood)
	var y := 130
	for line in ["", "", "", "", tr("Your score after two minutes:"), "", str(score), "", tr("Press any key.")]:
		if line != "":
			var l := UiText.make(line, 13)
			l.position = Vector2(149, y)
			l.size = Vector2(341, 16)
			l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
			_message.add_child(l)
		y += 16
	Audio.play_sfx("cancel")


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("fullscreen"):
		Settings.toggle_fullscreen()
	elif event.is_action_pressed("toggle_music"):
		Audio.toggle_music()
	elif event.is_action_pressed("toggle_sfx"):
		Audio.toggle_sfx()
	elif event.is_action_pressed("volume_up"):
		Audio.change_volume(0.1)
	elif event.is_action_pressed("volume_down"):
		Audio.change_volume(-0.1)
	elif paused:
		if event.is_action_pressed("pause") or event.is_action_pressed("back") \
				or event.is_action_pressed("chat") or (event is InputEventKey and event.pressed and event.keycode == KEY_SPACE):
			set_paused(false)
	elif event.is_action_pressed("pause") and phase == Phase.PLAYING and not net:
		set_paused(true)
	elif _ending:
		pass
	elif net:
		_net_input(event)
	elif _cursor != null:
		if event is InputEventKey and event.pressed and not event.echo:
			_end_replay()
	elif event.is_action_pressed("back"):
		_end_game(false)
	elif event.is_action_pressed("screenshot"):
		save_record()
	elif event is InputEventKey and event.pressed and not event.echo:
		match phase:
			Phase.OVER:
				_end_game(false)
			Phase.WON:
				if sim.player("p1").exploding.is_empty():
					if Session.mode == Session.Mode.RANDOM:
						start_level()
					else:
						level_index += 1
						if level_index >= levelset.size():
							_end_game(true)
						else:
							start_level()
			Phase.LOST:
				if _all_lose_done():
					start_level()


func _all_lose_done() -> bool:
	for slot in slots:
		var f := sim.player(slot)
		if f.state == Playfield.State.LOST and not f.lose_done:
			return false
	return true


func _net_input(event: InputEvent) -> void:
	if not (event is InputEventKey) or not event.pressed or event.echo:
		return
	var key := event as InputEventKey
	if _chat_typing:
		if key.keycode == KEY_ESCAPE:
			_chat_typing = false
			_chat_text = ""
			_chat_label.text = ""
		elif key.keycode in [KEY_ENTER, KEY_KP_ENTER]:
			_chat_typing = false
			if _chat_text.strip_edges() != "":
				Net.send_chat(_chat_text.strip_edges())
			_chat_text = ""
		elif key.keycode == KEY_BACKSPACE:
			_chat_text = _chat_text.left(_chat_text.length() - 1)
			_chat_label.text = "> " + _chat_text
		elif key.unicode >= 32 and _chat_text.length() < 120:
			_chat_text += char(key.unicode)
			_chat_label.text = "> " + _chat_text
		return
	if key.keycode == KEY_ESCAPE:
		_ending = true
		Net.leave()
		Screens.goto(Screens.MENU)
	elif event.is_action_pressed("chat"):
		_chat_typing = true
		_chat_label.text = "> "


## Leaves the game: evaluates the high score first (handle_new_hiscores, bin/frozen-bubble:5280),
## asking for a name over the game screen, then goes to the high-score page or the menu.
func _end_game(won_all: bool) -> void:
	_ending = true
	var scores := HighScores.load_from()
	var qualifies := false
	var level := level_index + 1
	var time := Session.elapsed_seconds()
	var training_score := sim.player("p1").score
	match Session.mode:
		Session.Mode.NETWORK:
			qualifies = false
		Session.Mode.LEVELS:
			qualifies = scores.qualifies_levels(level, won_all, time)
		Session.Mode.TRAINING:
			qualifies = training_score > 0 and scores.qualifies_training(training_score, Session.chain_reaction)
	if not qualifies:
		Screens.goto(Screens.MENU)
		return
	Audio.play_sfx("applause")
	var dialog := AskDialog.create([tr("Congratulations!"), tr("You have a highscore!"), ""], tr("Your name?"), AskDialog.Mode.TEXT, tr("Great game!"))
	add_child(dialog)
	dialog.answered.connect(func(name):
		if str(name) == "":
			Screens.goto(Screens.MENU)
			return
		if Session.mode == Session.Mode.TRAINING:
			Session.new_entry = scores.add_training(str(name), training_score, Session.chain_reaction)
			Session.scores_page = 2
		else:
			Session.new_entry = scores.add_levels(str(name), level, won_all, time)
		scores.save_to()
		await get_tree().create_timer(2.0).timeout
		Screens.goto(Screens.HIGH_SCORES))
	dialog.cancelled.connect(func(): Screens.goto(Screens.MENU))


func set_paused(value: bool) -> void:
	paused = value
	pause_overlay.visible = value
	Audio.set_music_paused(value)
	if value:
		_pause_started_msec = Time.get_ticks_msec()
		_pause_frame = 0
		pause_anim.texture = _pause_frames.get_frame_texture("default", 0)
		Audio.play_sfx("pause")
	else:
		Session.paused_msec += Time.get_ticks_msec() - _pause_started_msec
