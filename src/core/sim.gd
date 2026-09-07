class_name Sim
extends RefCounted
## Deterministic game simulation. Call [method step] once per 20 ms frame with the players'
## inputs; read the Playfield objects for rendering and consume the returned events for sounds
## and one-shot effects. Every random choice goes through [member rng], so a seed plus the
## input stream reproduces a game exactly (replays, lockstep network play).
##
## The rules follow bin/frozen-bubble (see the mechanics notes in PLAN.md). Known deliberate
## deviations from the original are marked with "DEVIATION".

var rules: Rules
var rng: Rng
var players: Array[Playfield] = []
var frame := 0
var single_player := true
var training_over := false
var _events: Array[Dictionary] = []


func _init(rules_: Rules = Rules.single_player(), seed_: int = 0) -> void:
	rules = rules_
	rng = Rng.new(seed_)


func add_player(slot: String, layout: Dictionary, mini := false) -> Playfield:
	var p := Playfield.new()
	p.setup(slot, layout, mini)
	players.append(p)
	single_player = players.size() == 1
	return p


func player(slot: String) -> Playfield:
	for p in players:
		if p.slot == slot:
			return p
	return null


## Loads the same level onto every board and deals the first two colours.
func start_level(level: Array, level_number := 0) -> void:
	frame = 0
	training_over = false
	for p in players:
		_reset_player(p)
		p.grid.load_level(level)
		p.score = level_number
	_deal_initial_colours()


## Random board used by random levels, mp-training and 2p: five full rows.
func start_random_board() -> void:
	frame = 0
	training_over = false
	var level := LevelSet.empty_level()
	for cy in 5:
		for cx in LevelSet.cells_in_row(cy):
			level[cy][cx] = rng.below(LevelSet.COLOURS)
	for p in players:
		_reset_player(p)
		p.grid.load_level(level)
	_deal_initial_colours()


func _reset_player(p: Playfield) -> void:
	p.grid = Grid.new()
	p.state = Playfield.State.INGAME
	p.newrootlevel = 0
	p.newroot = 0
	p.newroot_prelight = 0
	p.newroot_prelight_step = 0
	p.angle = PI / 2
	p.launcher_colour = -1
	p.next_colour = -1
	p.flying = {}
	p.falling = []
	p.exploding = []
	p.hurry = 0
	p.hurry_oddness = false
	p.hurry_shown = false
	p.fire_flag = false
	p.fire_prev = false
	p.hadfire = false
	p.sticking = {}
	p.malus_queue = []
	p.malus_flying = []
	p.lose_pending = []
	p.frozen = {}
	p.lose_done = false
	p.left = false
	p.target = ""


## Living players: still in the game and connected.
func living() -> Array[Playfield]:
	var out: Array[Playfield] = []
	for p in players:
		if p.is_ingame() and not p.left:
			out.append(p)
	return out


## A network player disconnected: the board is cleared and the player counts as lost.
func player_left(slot: String) -> void:
	var p := player(slot)
	if p == null or p.left:
		return
	p.left = true
	if p.is_ingame():
		p.state = Playfield.State.LOST
		p.lose_done = true
		p.grid = Grid.new()
		p.flying = {}
		p.falling = []
		p.exploding = []
		p.malus_flying = []
		_emit("left", p)
	for other in players:
		if other.target == slot:
			other.target = ""
	_check_last_standing()


func _check_last_standing() -> void:
	if players.size() < 2:
		return
	var alive := living()
	if alive.size() == 1 and alive[0].is_ingame():
		var still_playing := 0
		for p in players:
			if p.is_ingame():
				still_playing += 1
		if still_playing == 1:
			alive[0].state = Playfield.State.WON
			alive[0].score += 1
			_emit("win", alive[0])


func _deal_initial_colours() -> void:
	# The original draws two validated colours for the first player and copies them to the
	# others (new_game, bin/frozen-bubble:3430-3459).
	var first := players[0]
	var launcher := _draw_colour(first)
	var next := _draw_colour(first)
	for p in players:
		p.launcher_colour = launcher
		p.next_colour = next


func _draw_colour(p: Playfield) -> int:
	var on_board := p.colours_on_board()
	if not rules.validate_colours or on_board.is_empty():
		return rng.below(LevelSet.COLOURS)
	while true:
		var c := rng.below(LevelSet.COLOURS)
		if on_board.has(c):
			return c
	return 0


func _emit(type: String, p: Playfield, extra := {}) -> void:
	var e := {"type": type, "slot": p.slot}
	e.merge(extra)
	_events.append(e)


## Advances one frame. inputs: slot -> {"left", "right", "fire", "center"} booleans.
func step(inputs: Dictionary) -> Array[Dictionary]:
	_events = []
	if rules.is_training and not training_over:
		_training_tick()
	for p in players:
		if p.is_ingame():
			_step_ingame(p, inputs.get(p.slot, {}))
	_verify_if_end()
	for p in players:
		_step_animations(p)
		if p.state == Playfield.State.LOST:
			_step_lost(p)
	frame += 1
	return _events


## Seconds left in a training game.
func training_time_left() -> float:
	return maxf(0.0, Rules.TRAINING_SECONDS - frame * 0.02)


## Training: a random batch of 1..6 malus is queued with probability 1/(difficulty*50) per
## frame while nothing is pending (handle_game_events, bin/frozen-bubble:1558).
func _training_tick() -> void:
	var p := players[0]
	if p.malus_flying.is_empty() and p.malus_queue.is_empty() and p.is_ingame():
		if rng.below(rules.training_difficulty * 50) == 0:
			var n := 1 + rng.below(6)
			for i in n:
				p.malus_queue.append(frame)
	if training_time_left() <= 0.0:
		training_over = true
		_emit("training_over", p, {"score": p.score})


func _step_ingame(p: Playfield, inp: Dictionary) -> void:
	var left: bool = inp.get("left", false)
	var right: bool = inp.get("right", false)
	var center: bool = inp.get("center", false)
	var fire_held: bool = inp.get("fire", false)
	p.hadfire = false
	if inp.has("target"):
		var t: String = inp["target"]
		p.target = t if t != p.slot and player(t) != null else ""

	# Aim (bin/frozen-bubble:2110-2121).
	if left:
		p.angle += Rules.LAUNCHER_SPEED
	if right:
		p.angle -= Rules.LAUNCHER_SPEED
	if center:
		if p.angle >= PI / 2 - Rules.LAUNCHER_SPEED and p.angle <= PI / 2 + Rules.LAUNCHER_SPEED:
			p.angle = PI / 2
		else:
			p.angle += Rules.LAUNCHER_SPEED if p.angle < PI / 2 else -Rules.LAUNCHER_SPEED
	p.angle = clampf(p.angle, Rules.ANGLE_MIN, Rules.ANGLE_MAX)

	# Hurry counter and blinking sign (bin/frozen-bubble:2125-2139).
	var chain_pending := p.chain_pending()
	if not chain_pending:
		p.hurry += 1
	var time_limit := not rules.no_time_limit
	if time_limit and p.hurry > rules.hurry_warn:
		var oddness := (int((p.hurry - rules.hurry_warn) / float(Rules.HURRY_BLINK_FRAMES)) + 1) % 2 == 1
		if p.hurry_oddness != oddness:
			p.hurry_shown = oddness
			_emit("hurry_on" if oddness else "hurry_off", p)
		p.hurry_oddness = oddness

	# Fire flag: set on key press, cleared on release or when the shot leaves (bin/frozen-bubble:1618, 1712, 2153).
	if fire_held and not p.fire_prev:
		p.fire_flag = true
	if not fire_held:
		p.fire_flag = false
	p.fire_prev = fire_held

	var auto_fire := time_limit and p.hurry == rules.hurry_max
	if (p.fire_flag or auto_fire) and p.flying.is_empty() and p.malus_flying.is_empty() \
			and not chain_pending and p.launcher_colour >= 0:
		_launch(p)

	if not p.flying.is_empty():
		_move_shot(p)


func _launch(p: Playfield) -> void:
	var pos := p.launch_pos()
	p.flying = {"x": pos.x, "y": pos.y, "x_old": pos.x, "y_old": pos.y, "dir": p.angle, "colour": p.launcher_colour}
	p.fire_flag = false
	p.hadfire = true
	p.hurry = 0
	# DEVIATION: the original never resets hurry_oddness, which sometimes skips the first blink
	# of the next warning (mechanics notes §5). We reset it so the sign always shows on time.
	p.hurry_oddness = false
	if p.hurry_shown:
		p.hurry_shown = false
		_emit("hurry_off", p)
	# The next colour is validated against the board as it is now, before the shot lands.
	var new_next := _draw_colour(p)
	p.launcher_colour = p.next_colour
	p.next_colour = new_next
	_emit("launch", p)


func _move_shot(p: Playfield) -> void:
	var b := p.flying
	b["x_old"] = b["x"]
	b["y_old"] = b["y"]
	b["x"] += Rules.BUBBLE_SPEED * cos(b["dir"])
	b["y"] -= Rules.BUBBLE_SPEED * sin(b["dir"])
	if b["x"] < p.left_limit:
		b["x"] = 2.0 * p.left_limit - b["x"]
		b["dir"] = PI - b["dir"]
		_emit("rebound", p)
	var right_edge := p.right_limit - p.bubble_size
	if b["x"] > right_edge:
		b["x"] = 2.0 * right_edge - b["x"]
		b["dir"] = PI - b["dir"]
		_emit("rebound", p)

	if b["y"] <= p.ceiling_y():
		var cell := p.pixel_to_cell(b["x"], b["y"])
		p.flying = {}
		_stick_bubble(p, cell.x, cell.y, b["colour"], true, false)
		return
	var threshold := (p.bubble_size * Rules.COLLISION_FACTOR) ** 2
	for cy in p.grid.rows.size():
		var row := p.grid.rows[cy]
		for cx in row.size():
			if row[cx] == Playfield.EMPTY:
				continue
			var pos := p.cell_to_pixel(cx, cy)
			var dx: float = b["x"] - pos.x
			var dy: float = b["y"] - pos.y
			if dx * dx + dy * dy < threshold:
				# Cell from the midpoint of the last step, no occupancy check (original behaviour).
				var cell := p.pixel_to_cell((b["x_old"] + b["x"]) / 2.0, (b["y_old"] + b["y"]) / 2.0)
				p.flying = {}
				_stick_bubble(p, cell.x, cell.y, b["colour"], true, true)
				if p.is_ingame() and not p.chain_pending():
					_release_malus(p)
				return


## A shot (or chain-reaction bubble) arrives at (cx, cy). Mirrors stick_bubble (bin/frozen-bubble:769).
func _stick_bubble(p: Playfield, cx: int, cy: int, colour: int, count_for_root: bool, collided: bool) -> void:
	if not count_for_root:
		# A chain-reaction bubble arriving where its group has meanwhile vanished is dropped
		# (bin/frozen-bubble:776).
		var has_neighbour := false
		for n in p.grid.neighbours(cx, cy):
			if not p.grid.is_empty(n.x, n.y):
				has_neighbour = true
		if not has_neighbour or not p.grid.is_empty(cx, cy):
			return
	# DEVIATION: the original trusts the rounding and can put two bubbles in one cell (which then
	# aborts the game); we fall back to the nearest free neighbouring cell instead.
	if not p.grid.is_empty(cx, cy) or not p.grid.in_bounds(cx, cy):
		var fixed := _nearest_free_cell(p, cx, cy)
		cx = fixed.x
		cy = fixed.y
	p.grid.set_cell(cx, cy, colour)
	var group := p.grid.group_of(cx, cy)
	var popped: Array[Vector2i] = []
	var fallen: Array[Vector2i] = []
	if group.size() < 3:
		p.sticking = {"cx": cx, "cy": cy, "step": 0, "slowdown": 0}
		_emit("stick", p, {"cx": cx, "cy": cy})
	else:
		popped = group
		# Explode the group members first and the new bubble last, like destroy_bubbles.
		var ordered: Array[Vector2i] = []
		for c in group:
			if c != Vector2i(cx, cy):
				ordered.append(c)
		ordered.append(Vector2i(cx, cy))
		p.grid.remove(group)
		for c in ordered:
			var pos := p.cell_to_pixel(c.x, c.y)
			var scale := 2.0 if p.mini else 1.0
			p.exploding.append({"x": pos.x, "y": pos.y, "colour": colour,
				"vx": (rng.float01() * 3.0 - 1.5) / scale, "vy": (-rng.float01() * 4.0 - 2.0) / scale})
		fallen = p.grid.orphans(p.newrootlevel)
		var new_falling := _start_falling(p, fallen)
		p.grid.remove(fallen)
		if rules.chain_reaction and not new_falling.is_empty():
			_plan_chain_reaction(p, new_falling)
		_emit("pop", p, {"cells": popped, "fallen": fallen})

	if count_for_root:
		_count_shot_for_compressor(p)

	if not popped.is_empty():
		var malus_val := popped.size() - 3 + fallen.size()
		if malus_val > 0 and players.size() == 2:
			malus_val += rules.player_malus if p.slot == "p1" else -rules.player_malus
		malus_val = maxi(malus_val, 0)
		if malus_val > 0:
			_malus_change(p, malus_val)


func _nearest_free_cell(p: Playfield, cx: int, cy: int) -> Vector2i:
	var best := Vector2i(cx, cy)
	var best_d := INF
	var target := p.cell_to_pixel(cx, cy)
	for dy in range(-1, 2):
		for dx in range(-1, 2):
			var c := Vector2i(cx + dx, cy + dy)
			if c.y < p.newrootlevel or not p.grid.in_bounds(c.x, c.y) or not p.grid.is_empty(c.x, c.y):
				continue
			var d := p.cell_to_pixel(c.x, c.y).distance_squared_to(target)
			if d < best_d:
				best_d = d
				best = c
	return best


func _start_falling(p: Playfield, cells: Array[Vector2i]) -> Array[Dictionary]:
	var added: Array[Dictionary] = []
	if cells.is_empty():
		return added
	var max_cy := 0
	for c in cells:
		max_cy = maxi(max_cy, c.y)
	var sorted := cells.duplicate()
	sorted.sort_custom(func(a: Vector2i, b: Vector2i) -> bool: return a.y * 8 + a.x > b.y * 8 + b.x)
	var line := max_cy
	var shift := 0
	for c in sorted:
		if line != c.y:
			shift = 0
		line = c.y
		var pos := p.cell_to_pixel(c.x, c.y)
		var entry := {"x": pos.x, "y": pos.y, "colour": p.grid.get_cell(c.x, c.y),
			"wait": (max_cy - c.y) * 5 + shift, "speed": 0.0, "cell": c}
		p.falling.append(entry)
		added.append(entry)
		shift += 1
	return added


func _count_shot_for_compressor(p: Playfield) -> void:
	p.newroot += 1
	if p.newroot == rules.time_appears_new_root - 1:
		p.newroot_prelight = 2
		p.newroot_prelight_step = 0
	if p.newroot == rules.time_appears_new_root:
		p.newroot_prelight = 1
		p.newroot_prelight_step = 0
	if p.newroot > rules.time_appears_new_root:
		p.newroot = 0
		p.newroot_prelight = 0
		for b in p.falling:
			if b.has("chain"):
				b["chain"]["cy"] += 1
				b["chain"]["y"] += p.row_size
		if rules.compressor_lowers_ceiling:
			p.grid.push_root_row(PackedInt32Array())
			p.newrootlevel += 1
		else:
			var colours := PackedInt32Array()
			for i in LevelSet.WIDE:
				colours.append(rng.below(LevelSet.COLOURS))
			p.grid.push_root_row(colours)
		_emit("newroot", p, {"solo": rules.compressor_lowers_ceiling})


func _verify_if_end() -> void:
	for p in players:
		if p.is_ingame() and p.grid.lowest_row() > Rules.LAST_ROW:
			_lose(p)
			_check_last_standing()
			break
	if single_player and not rules.is_training:
		var p := players[0]
		if p.is_ingame() and p.grid.count() == 0:
			p.state = Playfield.State.WON
			_emit("win", p)


func _lose(p: Playfield) -> void:
	p.state = Playfield.State.LOST
	p.sticking = {}
	p.hurry_shown = false
	if not p.flying.is_empty():
		var b := p.flying
		p.exploding.append({"x": b["x"], "y": b["y"], "colour": b["colour"],
			"vx": rng.float01() * 3.0 - 1.5, "vy": -rng.float01() * 4.0 - 2.0})
		p.flying = {}
	p.lose_pending = []
	for cy in p.grid.rows.size():
		for cx in p.grid.rows[cy].size():
			if p.grid.rows[cy][cx] != Playfield.EMPTY:
				p.lose_pending.append(Vector2i(cx, cy))
	p.lose_pending.sort_custom(func(a: Vector2i, b: Vector2i) -> bool: return a.x + a.y * 10 > b.x + b.y * 10)
	var keep: Array[Dictionary] = []
	for b in p.falling:
		if not b.has("chain"):
			keep.append(b)
	p.falling = keep
	p.malus_flying = []
	_emit("lose", p)


## Every other frame one more bubble turns into the frozen "lose" bubble (update_lost).
func _step_lost(p: Playfield) -> void:
	if frame % 2 == 1 or p.lose_done:
		return
	if not p.lose_pending.is_empty():
		var c: Vector2i = p.lose_pending.pop_front()
		p.frozen[c] = true
	if p.lose_pending.is_empty() and not p.lose_done:
		p.lose_done = true
		_emit("lose_done", p)


func _step_animations(p: Playfield) -> void:
	_step_malus_flight(p)
	var keep: Array[Dictionary] = []
	var arrived: Array[Dictionary] = []
	var maxy := p.initial_bubble_y - 10.0 if not p.mini else (185.0 if p.slot in ["rp1", "rp2"] else 415.0)
	for b in p.falling:
		if b["wait"] > 0:
			b["wait"] -= 1
			keep.append(b)
			continue
		if b.has("chain") and (b["y"] > maxy or b.get("going_up", false)):
			# Return flight: solve the horizontal speed so the parabola lands on the target
			# (bin/frozen-bubble:2526-2553), acceleration 3x gravity.
			var acc := Rules.FREE_FALL_CONSTANT * 3.0
			if not b.get("going_up", false):
				var speed: float = b["speed"]
				var time_to_zero := speed / acc
				var distance_to_zero := speed * (speed / acc + 1.0) / 2.0
				var dy: float = b["y"] - b["chain"]["y"] + distance_to_zero
				var tobe_sqrted := 1.0 + 8.0 / acc * dy
				b["vx"] = 0.0
				if tobe_sqrted >= 0.0:
					var time_to_destination := (-1.0 + sqrt(tobe_sqrted)) / 2.0
					if time_to_zero + time_to_destination != 0.0:
						b["vx"] = (b["chain"]["x"] - b["x"]) / (time_to_zero + time_to_destination)
				b["going_up"] = true
			b["speed"] -= acc
			b["x"] += b["vx"]
			if absf(b["x"] - b["chain"]["x"]) < absf(b["vx"]):
				b["x"] = b["chain"]["x"]
				b["vx"] = 0.0
			b["y"] += b["speed"]
			if b["y"] < b["chain"]["y"]:
				arrived.append(b)
			else:
				keep.append(b)
			continue
		b["y"] += b["speed"]
		b["speed"] += Rules.FREE_FALL_CONSTANT
		if b["y"] <= Rules.OFFSCREEN_Y or b.has("chain"):
			keep.append(b)
	p.falling = keep
	for b in arrived:
		if p.is_ingame():
			_stick_bubble(p, b["chain"]["cx"], b["chain"]["cy"], b["colour"], false, false)
	keep = []
	for b in p.exploding:
		b["x"] += b["vx"]
		b["y"] += b["vy"]
		b["vy"] += Rules.FREE_FALL_CONSTANT
		if b["y"] <= Rules.OFFSCREEN_Y:
			keep.append(b)
	p.exploding = keep
	if not p.sticking.is_empty():
		if p.sticking["slowdown"] == 1:
			p.sticking["step"] += 1
			p.sticking["slowdown"] = 0
		else:
			p.sticking["slowdown"] = 1
		if p.sticking["step"] >= Rules.STICK_EFFECT_FRAMES:
			p.sticking = {}
	if p.newroot_prelight > 0:
		p.newroot_prelight_step += 1
		if p.newroot_prelight_step > 30 * p.newroot_prelight + 1:
			p.newroot_prelight_step = 0


## Compact fingerprint of the whole state, for determinism tests and desync detection.
func state_hash() -> String:
	var parts := PackedStringArray([str(frame)])
	for p in players:
		parts.append(p.grid.to_debug_string())
		parts.append("%d %d %.4f %d %d %d" % [p.state, p.newrootlevel, p.angle, p.launcher_colour, p.next_colour, p.hurry])
		if not p.flying.is_empty():
			parts.append("%.3f %.3f %.4f" % [p.flying["x"], p.flying["y"], p.flying["dir"]])
		parts.append(str(p.falling.size()) + " " + str(p.exploding.size()))
	return "\n".join(parts).md5_text()


# --- malus (2p and training) ---------------------------------------------------------------

## Malus produced by a pop goes to the opponent's queue (local 2p) or to the score (training).
func _malus_change(p: Playfield, count: int) -> void:
	if rules.is_training:
		p.score += count
		_emit("malus_produced", p, {"count": count})
		return
	if players.size() < 2:
		return
	if players.size() == 2:
		for other in players:
			if other != p:
				for i in count:
					other.malus_queue.append(frame)
	else:
		# 3+ players: all to the targeted opponent, else split evenly among living opponents
		# (malus_change, bin/frozen-bubble:1200-1226)
		var targets: Array[Playfield] = []
		var t := player(p.target) if p.target != "" else null
		if t != null and t.is_ingame() and not t.left:
			targets.append(t)
			for i in count:
				t.malus_queue.append(frame)
		else:
			for other in living():
				if other != p:
					targets.append(other)
			if targets.size() > 0:
				var each := int(float(count) / targets.size() + 0.99)
				for other in targets:
					for i in each:
						other.malus_queue.append(frame)
	_emit("malus_produced", p, {"count": count})


## Launches queued malus bubbles onto p's board after p's shot collided with a bubble
## (bin/frozen-bubble:2217-2258): at most 7 per shot, only ones queued more than 20 frames ago.
func _release_malus(p: Playfield) -> void:
	if p.malus_queue.is_empty() or frame <= p.malus_queue[0] + Rules.MALUS_FREEZE_FRAMES:
		return
	var top_of_cx := PackedInt32Array()
	top_of_cx.resize(LevelSet.WIDE)
	top_of_cx.fill(0)
	for cy in p.grid.rows.size():
		for cx in p.grid.rows[cy].size():
			if p.grid.rows[cy][cx] != Playfield.EMPTY and cy > top_of_cx[cx]:
				top_of_cx[cx] = cy
	var released := 0
	while not p.malus_queue.is_empty() and frame > p.malus_queue[0] + Rules.MALUS_FREEZE_FRAMES \
			and p.malus_flying.size() < Rules.MALUS_MAX_PER_SHOT:
		var colour := rng.below(LevelSet.COLOURS)
		var good_cx: Array[int] = []
		for cx in LevelSet.WIDE:
			if top_of_cx[cx] < Rules.LAST_ROW:
				var target_offset := (top_of_cx[cx] + 1 + p.grid.oddswap) % 2 == 1
				if not (target_offset and cx == 7):
					good_cx.append(cx)
		var cx: int
		if rules.no_instant_death and not good_cx.is_empty():
			cx = good_cx[rng.below(good_cx.size())]
		else:
			cx = rng.below(7)
		top_of_cx[cx] += 1
		var start := p.cell_to_pixel(cx, 12)
		p.malus_flying.append({"x": start.x, "y": start.y, "cx": cx, "stick_y": top_of_cx[cx], "colour": colour})
		p.malus_queue.pop_front()
		released += 1
	if released == 0:
		return
	p.malus_flying.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return a["cx"] < b["cx"])
	var shifting := 0
	for b in p.malus_flying:
		shifting += 7
		b["y"] += shifting + rng.below(20)
	_emit("malus_launched", p, {"count": released})


## Malus bubbles rise at 30 px/frame and stick, without popping, when the nearest row is at or
## above their target row (bin/frozen-bubble:2499-2518).
func _step_malus_flight(p: Playfield) -> void:
	if p.malus_flying.is_empty():
		return
	var keep: Array[Dictionary] = []
	for b in p.malus_flying:
		b["y"] -= Rules.MALUS_BUBBLE_SPEED
		var ny := int((b["y"] - p.top_limit + p.row_size / 2.0) / p.row_size)
		if ny <= b["stick_y"]:
			var cx: int = b["cx"]
			var cy: int = b["stick_y"]
			if cx < p.grid.cells_in_row(cy):
				p.grid.set_cell(cx, cy, b["colour"])
			_emit("malus_stuck", p, {"cx": cx, "cy": cy})
		else:
			keep.append(b)
	p.malus_flying = keep


# --- chain reaction ---------------------------------------------------------------------------

## Cells reachable from the ceiling row when [param removed] cells are treated as gone.
func _still_attached(p: Playfield, removed: Dictionary) -> Dictionary:
	var attached := {}
	var stack: Array[Vector2i] = []
	if p.newrootlevel < p.grid.rows.size():
		for cx in p.grid.rows[p.newrootlevel].size():
			var c := Vector2i(cx, p.newrootlevel)
			if not p.grid.is_empty(cx, p.newrootlevel) and not removed.has(c):
				attached[c] = true
				stack.append(c)
	while not stack.is_empty():
		var c: Vector2i = stack.pop_back()
		for n in p.grid.neighbours(c.x, c.y):
			if not attached.has(n) and not removed.has(n) and not p.grid.is_empty(n.x, n.y):
				attached[n] = true
				stack.append(n)
	return attached


## Same-colour group that would form if [param colour] were placed at [param at].
func _group_with(p: Playfield, at: Vector2i, colour: int) -> Array[Vector2i]:
	p.grid.set_cell(at.x, at.y, colour)
	var g := p.grid.group_of(at.x, at.y)
	p.grid.set_cell(at.x, at.y, Playfield.EMPTY)
	return g


## Cells of the board that would fall if the group at [param at] (with colour) popped.
func _would_fall(p: Playfield, at: Vector2i, colour: int) -> Dictionary:
	var removed := {}
	for c in _group_with(p, at, colour):
		removed[c] = true
	removed.erase(at)
	var attached := _still_attached(p, removed)
	var out := {}
	for cy in p.grid.rows.size():
		for cx in p.grid.rows[cy].size():
			var c := Vector2i(cx, cy)
			if not p.grid.is_empty(cx, cy) and not removed.has(c) and not attached.has(c):
				out[c] = true
	return out


## Free cells next to [param c] that a chain bubble may occupy (next_positions).
func _next_positions(p: Playfield, c: Vector2i) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	for n in p.grid.neighbours(c.x, c.y):
		if n.y >= p.newrootlevel and n.y <= Rules.LAST_ROW:
			out.append(n)
	return out


## Gives falling bubbles a destination next to a same-colour pair so they fly back and pop it
## (bin/frozen-bubble:815-895).
func _plan_chain_reaction(p: Playfield, new_falling: Array[Dictionary]) -> void:
	var falling_colours := {}
	for f in new_falling:
		falling_colours[f["colour"]] = true
	# candidates: attached bubbles of a falling colour that already have a same-colour neighbour,
	# ordered by distance from the ceiling row
	var order := {}
	var attached := _still_attached(p, {})
	var queue: Array[Vector2i] = []
	for c in attached:
		if c.y == p.newrootlevel:
			queue.append(c)
	var index := 0
	var seen := {}
	while not queue.is_empty():
		var c: Vector2i = queue.pop_front()
		if seen.has(c):
			continue
		seen[c] = true
		order[c] = index
		index += 1
		for n in p.grid.neighbours(c.x, c.y):
			if attached.has(n) and not seen.has(n):
				queue.append(n)
	var candidates: Array[Vector2i] = []
	for c in attached:
		var colour := p.grid.get_cell(c.x, c.y)
		if colour < 0 or not falling_colours.has(colour):
			continue
		for n in p.grid.neighbours(c.x, c.y):
			if p.grid.get_cell(n.x, n.y) == colour:
				candidates.append(c)
				break
	if candidates.is_empty():
		return
	candidates.sort_custom(func(a: Vector2i, b: Vector2i) -> bool: return order.get(a, 9999) < order.get(b, 9999))
	var occupied := {}
	for cy in p.grid.rows.size():
		for cx in p.grid.rows[cy].size():
			if not p.grid.is_empty(cx, cy):
				occupied[Vector2i(cx, cy)] = true
	for f in p.falling:
		if f.has("chain"):
			occupied[Vector2i(f["chain"]["cx"], f["chain"]["cy"])] = true
	var chained_cells := {}  # falling entry index -> Dictionary of cells that would fall
	for pos in candidates:
		var pos_colour := p.grid.get_cell(pos.x, pos.y)
		for npos in _next_positions(p, pos):
			var doomed := false
			for key in chained_cells:
				if chained_cells[key].has(pos):
					doomed = true
			if doomed or occupied.has(npos):
				continue
			for f in new_falling:
				if f.has("chain") or f["colour"] != pos_colour:
					continue
				var dest := p.cell_to_pixel(npos.x, npos.y)
				f["chain"] = {"cx": npos.x, "cy": npos.y, "x": dest.x, "y": dest.y}
				occupied[npos] = true
				chained_cells[f] = _would_fall(p, npos, pos_colour)
				break
	# validation: a chain must still pop at least two bubbles once every other chain is removed
	var by_row := new_falling.duplicate()
	by_row.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return a["cell"].y > b["cell"].y)
	for f in by_row:
		if not f.has("chain"):
			continue
		var other_removed := {}
		for f2 in new_falling:
			if f2 == f or not f2.has("chain"):
				continue
			for c in _group_with(p, Vector2i(f2["chain"]["cx"], f2["chain"]["cy"]), f2["colour"]):
				other_removed[c] = true
		var still := _still_attached(p, other_removed)
		var group := _group_with(p, Vector2i(f["chain"]["cx"], f["chain"]["cy"]), f["colour"])
		var alive := 0
		for c in group:
			if still.has(c):
				alive += 1
		if alive < 2:
			f.erase("chain")
