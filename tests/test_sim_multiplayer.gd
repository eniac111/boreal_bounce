extends TestCase

const IDLE := {}


func _cells_level(cells: Dictionary) -> Array:
	var level := LevelSet.empty_level()
	for c in cells:
		level[c.y][c.x] = cells[c]
	return level


func _versus(cells: Dictionary, seed_ := 1) -> Sim:
	var sim := Sim.new(Rules.versus(), seed_)
	sim.add_player("p1", Layouts.POS_2P["p1"])
	sim.add_player("p2", Layouts.POS_2P["p2"])
	sim.start_level(_cells_level(cells))
	return sim


func _run(sim: Sim, frames: int, inputs: Dictionary = IDLE) -> Array:
	var all := []
	for i in frames:
		all.append_array(sim.step(inputs))
	return all


func _fire(sim: Sim, slot: String) -> Array:
	var ev := sim.step({slot: {"fire": true}})
	ev.append_array(sim.step(IDLE))
	return ev


func _count(events: Array, type: String, slot := "") -> int:
	var n := 0
	for e in events:
		if e["type"] == type and (slot == "" or e["slot"] == slot):
			n += 1
	return n


func test_pop_sends_malus_to_opponent_and_shot_delivers_it() -> void:
	# p1 pops four zeros (one extra) and drops one orphan -> 2 malus for p2
	var sim := _versus({Vector2i(3, 0): 0, Vector2i(4, 0): 0, Vector2i(5, 0): 0, Vector2i(5, 1): 1})
	var p1 := sim.player("p1")
	var p2 := sim.player("p2")
	p1.launcher_colour = 0
	var ev := _fire(sim, "p1")
	ev.append_array(_run(sim, 45))
	assert_eq(_count(ev, "pop", "p1"), 1)
	assert_eq(_count(ev, "malus_produced", "p1"), 1)
	assert_eq(p2.malus_queue.size(), 2, "two malus queued for p2")
	assert_eq(p1.malus_queue.size(), 0)
	# p2's own collision shot releases them (queued more than 20 frames ago by now)
	p2.launcher_colour = 6
	ev = _fire(sim, "p2")
	ev.append_array(_run(sim, 45))
	assert_eq(_count(ev, "malus_launched", "p2"), 1, "malus batch launched: " + str(ev.map(func(e): return e["type"])))
	assert_eq(p2.malus_queue.size(), 0)
	assert_eq(_count(ev, "malus_stuck", "p2"), 2, "both malus bubbles stuck")
	assert_true(p2.malus_flying.is_empty())
	# board had 4 level bubbles + 1 shot + 2 malus
	assert_eq(p2.grid.count(), 4 + 1 + 2)


func test_cannot_fire_while_malus_in_flight() -> void:
	var sim := _versus({Vector2i(3, 0): 0, Vector2i(4, 0): 0, Vector2i(5, 0): 0})
	var p1 := sim.player("p1")
	var p2 := sim.player("p2")
	p1.launcher_colour = 0
	_fire(sim, "p1")
	_run(sim, 45)
	assert_eq(p2.malus_queue.size(), 1)
	p2.launcher_colour = 6
	_fire(sim, "p2")
	_run(sim, 34)  # shot lands, malus launched
	assert_false(p2.malus_flying.is_empty(), "malus in flight right after the shot landed")
	var ev := sim.step({"p2": {"fire": true}})
	assert_eq(_count(ev, "launch", "p2"), 0, "no launch while a malus bubble flies")


func test_round_ends_when_a_player_loses() -> void:
	var sim := _versus({Vector2i(3, 0): 4})
	var p1 := sim.player("p1")
	var p2 := sim.player("p2")
	for cy in range(1, 12):
		p1.grid.set_cell(3, cy, 4 if cy % 2 == 0 else 5)
	p1.launcher_colour = 6
	var ev := _fire(sim, "p1")
	ev.append_array(_run(sim, 10))
	assert_eq(_count(ev, "lose", "p1"), 1)
	assert_eq(_count(ev, "win", "p2"), 1)
	assert_eq(p2.state, Playfield.State.WON)
	assert_eq(p2.score, 1, "p2 won a round")
	assert_eq(p1.state, Playfield.State.LOST)


func test_training_queues_random_malus_and_ends_after_two_minutes() -> void:
	var rules := Rules.training()
	rules.training_difficulty = 2  # a batch roughly every 100 frames
	var sim := Sim.new(rules, 11)
	sim.add_player("p1", Layouts.POS_1P["p1"])
	sim.start_random_board()
	var p := sim.player("p1")
	var queued := false
	var over_at := -1
	for f in 6100:
		var ev := sim.step(IDLE)
		if not p.malus_queue.is_empty():
			queued = true
		for e in ev:
			if e["type"] == "training_over":
				over_at = f
	assert_true(queued, "random malus were queued")
	assert_eq(over_at, 6050, "training over once 120.99 s of frames have elapsed")
	assert_true(sim.training_over)


func test_training_score_counts_malus_produced() -> void:
	var sim := Sim.new(Rules.training(), 5)
	sim.add_player("p1", Layouts.POS_1P["p1"])
	sim.start_level(_cells_level({Vector2i(3, 0): 0, Vector2i(4, 0): 0, Vector2i(5, 0): 0, Vector2i(5, 1): 1}))
	var p := sim.player("p1")
	p.launcher_colour = 0
	_fire(sim, "p1")
	_run(sim, 45)
	assert_eq(p.score, 2, "one extra popped bubble plus one fallen")
	assert_eq(p.state, Playfield.State.INGAME, "an empty board does not win in training")


func test_chain_reaction_returns_a_falling_bubble_to_its_pair() -> void:
	var rules := Rules.single_player()
	rules.chain_reaction = true
	var sim := Sim.new(rules, 3)
	sim.add_player("p1", Layouts.POS_1P["p1"])
	# popping the zeros at (3,0),(4,0) drops the 2 at (4,1); the pair of 2s at (0,0),(1,0)
	# has a free cell at (0,1) for it to come back to
	sim.start_level(_cells_level({Vector2i(3, 0): 0, Vector2i(4, 0): 0, Vector2i(4, 1): 2, Vector2i(0, 0): 2, Vector2i(1, 0): 2}))
	var p := sim.player("p1")
	p.launcher_colour = 0
	var ev := _fire(sim, "p1")
	ev.append_array(_run(sim, 40))
	assert_eq(_count(ev, "pop"), 1)
	assert_eq(p.falling.size(), 1)
	if p.falling.size() == 1:
		assert_true(p.falling[0].has("chain"), "the fallen 2 got a chain destination")
		assert_eq(p.falling[0]["chain"]["cx"], 0)
		assert_eq(p.falling[0]["chain"]["cy"], 1)
	assert_true(p.chain_pending())
	var hurry_before := p.hurry
	ev = _run(sim, 400)
	assert_eq(_count(ev, "pop"), 1, "the returning bubble popped the pair")
	assert_eq(p.grid.count(), 0)
	assert_eq(p.state, Playfield.State.WON)
	assert_false(p.chain_pending())
