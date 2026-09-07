extends TestCase

const IDLE := {}
const FIRE := {"p1": {"fire": true}}


## Builds a 1p sim on an otherwise empty level with the given cells {Vector2i: colour}.
func _sim(cells: Dictionary, rules: Rules = Rules.single_player(), seed_ := 1) -> Sim:
	var sim := Sim.new(rules, seed_)
	sim.add_player("p1", Layouts.POS_1P["p1"])
	var level := LevelSet.empty_level()
	for c in cells:
		level[c.y][c.x] = cells[c]
	sim.start_level(level, 1)
	return sim


func _run(sim: Sim, frames: int, inputs: Dictionary = IDLE) -> Array:
	var all := []
	for i in frames:
		all.append_array(sim.step(inputs))
	return all


func _types(events: Array) -> Array:
	var out := []
	for e in events:
		out.append(e["type"])
	return out


func _fire(sim: Sim) -> Array:
	var ev := sim.step(FIRE)
	ev.append_array(sim.step(IDLE))  # release the key
	return ev


func test_initial_state_and_colour_validation() -> void:
	var sim := _sim({Vector2i(0, 0): 3, Vector2i(1, 0): 5})
	var p := sim.player("p1")
	assert_eq(p.launcher_colour in [3, 5], true, "launcher colour comes from the board")
	assert_eq(p.next_colour in [3, 5], true, "next colour comes from the board")
	assert_near(p.angle, PI / 2)
	assert_eq(p.ceiling_y(), 44.0)
	assert_eq(p.launch_pos(), Vector2(302, 390))


func test_shot_straight_up_sticks_on_ceiling() -> void:
	var sim := _sim({Vector2i(0, 0): 2})
	var p := sim.player("p1")
	p.launcher_colour = 2
	var ev := _fire(sim)
	assert_true("launch" in _types(ev))
	assert_false(p.flying.is_empty(), "shot in flight")
	ev = _run(sim, 40)
	assert_true(p.flying.is_empty(), "shot landed within 40 frames")
	assert_true("stick" in _types(ev))
	assert_eq(p.grid.get_cell(4, 0), 2, "ceiling cell under x=302 is column 4")
	assert_eq(p.newroot, 1)
	assert_false(p.sticking.is_empty(), "stick effect started")


func test_pop_three_clears_and_wins() -> void:
	var sim := _sim({Vector2i(3, 0): 0, Vector2i(4, 0): 0})
	var p := sim.player("p1")
	p.launcher_colour = 0
	_fire(sim)
	var ev := _run(sim, 40)
	var types := _types(ev)
	assert_true("pop" in types, "group of three pops: " + str(types))
	assert_true("win" in types, "board empty -> win")
	assert_eq(p.grid.count(), 0)
	assert_eq(p.exploding.size(), 3, "three exploding bubbles")
	assert_eq(p.state, Playfield.State.WON)


func test_orphans_fall_after_pop() -> void:
	var sim := _sim({Vector2i(3, 0): 0, Vector2i(4, 0): 0, Vector2i(4, 1): 1, Vector2i(7, 0): 1})
	var p := sim.player("p1")
	p.launcher_colour = 0
	_fire(sim)
	var ev := _run(sim, 40)
	var pop := ev.filter(func(e): return e["type"] == "pop")
	assert_eq(pop.size(), 1)
	if pop.size() == 1:
		assert_eq(pop[0]["fallen"].size(), 1, "the bubble hanging under the group falls")
		assert_eq(pop[0]["fallen"][0], Vector2i(4, 1))
	assert_eq(p.grid.get_cell(7, 0), 1, "the far bubble stays")
	assert_eq(p.grid.count(), 1)
	assert_eq(p.falling.size(), 1)
	_run(sim, 200)
	assert_eq(p.falling.size(), 0, "fallen bubble leaves the screen")
	assert_eq(p.state, Playfield.State.INGAME)


func test_wall_bounce() -> void:
	var sim := _sim({Vector2i(0, 0): 2})
	var p := sim.player("p1")
	p.launcher_colour = 2
	p.angle = 0.2
	_fire(sim)
	var ev := _run(sim, 15)
	assert_true("rebound" in _types(ev), "bounced off the right wall")
	assert_true(p.flying["dir"] > PI / 2, "direction mirrored to the left")
	assert_true(p.flying["x"] <= 414.0 and p.flying["x"] >= 190.0)


func test_compressor_lowers_ceiling_after_nine_shots() -> void:
	var sim := _sim({Vector2i(0, 0): Grid.STONE})
	var p := sim.player("p1")
	var newroot_events := 0
	for shot in 9:
		p.launcher_colour = shot % 8
		var ev := _fire(sim)
		ev.append_array(_run(sim, 60))
		assert_true(p.flying.is_empty(), "shot %d landed" % shot)
		for e in ev:
			if e["type"] == "newroot":
				newroot_events += 1
		if shot == 6:
			assert_eq(p.newroot_prelight, 2, "slow prelight two shots before")
		if shot == 7:
			assert_eq(p.newroot_prelight, 1, "fast prelight one shot before")
	assert_eq(newroot_events, 1, "compressor fired once")
	assert_eq(p.newrootlevel, 1)
	assert_eq(p.newroot, 0)
	assert_eq(p.ceiling_y(), 72.0)
	assert_eq(p.grid.get_cell(0, 1), Grid.STONE, "everything moved down one row")
	assert_eq(p.grid.oddswap, 1)
	assert_eq(p.grid.count(), 10)


func test_hurry_warning_and_auto_fire() -> void:
	var sim := _sim({Vector2i(0, 0): 2})
	var p := sim.player("p1")
	var ev := _run(sim, 400)
	assert_false("hurry_on" in _types(ev), "no warning before 400 frames")
	ev = _run(sim, 1)
	assert_true("hurry_on" in _types(ev), "warning at frame 401")
	ev = _run(sim, 25)
	assert_true("hurry_off" in _types(ev), "blinks off 25 frames later")
	ev = _run(sim, 99)
	assert_true("launch" in _types(ev), "auto-fire at hurry == 525")
	assert_eq(p.hurry, 0)
	assert_false(p.flying.is_empty())
	assert_true("hurry_off" in _types(ev))


func test_no_time_limit_disables_hurry() -> void:
	var rules := Rules.single_player()
	rules.no_time_limit = true
	var sim := _sim({Vector2i(0, 0): 2}, rules)
	var ev := _run(sim, 700)
	assert_false("launch" in _types(ev))
	assert_false("hurry_on" in _types(ev))


func test_lose_when_a_bubble_reaches_row_twelve() -> void:
	var sim := _sim({Vector2i(3, 0): 4})
	var p := sim.player("p1")
	for cy in range(1, 12):
		p.grid.set_cell(3, cy, 4 if cy % 2 == 0 else 5)
	p.launcher_colour = 6
	var ev := _fire(sim)
	ev.append_array(_run(sim, 10))
	assert_true("lose" in _types(ev), "shot stuck at row 12: " + str(_types(ev)))
	assert_eq(p.state, Playfield.State.LOST)
	assert_eq(p.grid.lowest_row(), 12)
	ev = _run(sim, 40)
	assert_true("lose_done" in _types(ev), "13 bubbles freeze in 26 frames")
	assert_eq(p.frozen.size(), 13)
	assert_true(p.lose_pending.is_empty())


func test_fire_is_edge_triggered_and_not_buffered() -> void:
	var sim := _sim({Vector2i(0, 0): 2})
	var p := sim.player("p1")
	p.launcher_colour = 2
	_run(sim, 3, FIRE)
	assert_false(p.flying.is_empty(), "fired on press")
	var launches := 0
	for e in _run(sim, 40, FIRE):
		if e["type"] == "launch":
			launches += 1
	assert_eq(launches, 0, "holding fire does not fire again after landing")
	_run(sim, 1, IDLE)
	launches = 0
	for e in _run(sim, 2, FIRE):
		if e["type"] == "launch":
			launches += 1
	assert_eq(launches, 1, "a new press fires again")


func test_random_board_is_shared() -> void:
	var sim := Sim.new(Rules.versus(), 5)
	sim.add_player("p1", Layouts.POS_2P["p1"])
	sim.add_player("p2", Layouts.POS_2P["p2"])
	sim.start_random_board()
	var p1 := sim.player("p1")
	var p2 := sim.player("p2")
	assert_eq(p1.grid.count(), 38, "five full rows: 8+7+8+7+8")
	assert_eq(p1.grid.to_debug_string(), p2.grid.to_debug_string(), "both boards identical")
	assert_eq(p1.launcher_colour, p2.launcher_colour)
	assert_eq(p1.next_colour, p2.next_colour)


func test_versus_compressor_inserts_a_row_after_twelve_shots() -> void:
	var sim := _sim({Vector2i(0, 0): Grid.STONE}, Rules.versus())
	var p := sim.player("p1")
	var newroots := 0
	for shot in 12:
		p.launcher_colour = shot % 8
		var ev := _fire(sim)
		ev.append_array(_run(sim, 60))
		assert_true(p.flying.is_empty(), "shot %d landed" % shot)
		for e in ev:
			if e["type"] == "newroot":
				newroots += 1
				assert_false(e["solo"], "versus compressor is not the solo one")
	assert_eq(newroots, 1)
	assert_eq(p.newrootlevel, 0, "ceiling does not move in versus")
	assert_eq(p.grid.oddswap, 1)
	assert_eq(p.grid.count(), 1 + 12 + 7, "a row of 7 new bubbles was inserted at the top")
	assert_eq(p.grid.get_cell(0, 1), Grid.STONE, "old bubbles shifted down")
	for cx in 7:
		assert_true(p.grid.get_cell(cx, 0) >= 0, "new row cell %d is a colour" % cx)


func test_determinism() -> void:
	var a := _sim({Vector2i(3, 0): 0, Vector2i(4, 0): 1, Vector2i(5, 0): 2, Vector2i(2, 1): 3}, Rules.single_player(), 99)
	var b := _sim({Vector2i(3, 0): 0, Vector2i(4, 0): 1, Vector2i(5, 0): 2, Vector2i(2, 1): 3}, Rules.single_player(), 99)
	for f in 900:
		var inp := {}
		if f % 60 < 20:
			inp = {"p1": {"left": true}}
		elif f % 60 < 30:
			inp = {"p1": {"right": true, "fire": f % 60 == 25}}
		a.step(inp)
		b.step(inp)
		if f % 100 == 99:
			assert_eq(a.state_hash(), b.state_hash(), "frame %d" % f)
	var c := _sim({Vector2i(3, 0): 0, Vector2i(4, 0): 1, Vector2i(5, 0): 2, Vector2i(2, 1): 3}, Rules.single_player(), 100)
	_run(c, 900)
	assert_true(c.state_hash() != a.state_hash(), "different seed/inputs differ")
