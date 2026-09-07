extends TestCase

const IDLE := {}


func _sim(n: int, seed_ := 3) -> Sim:
	var sim := Sim.new(Rules.versus(), seed_)
	for i in n:
		sim.add_player("n%d" % i, Layouts.POS_1P["p1"])
	# popping the zeros with the shot (group of 4) drops the two hanging 1s: 1 + 2 = 3 malus
	sim.start_level(_level({Vector2i(3, 0): 0, Vector2i(4, 0): 0, Vector2i(5, 0): 0, Vector2i(5, 1): 1, Vector2i(6, 1): 1}))
	return sim


func _level(cells: Dictionary) -> Array:
	var level := LevelSet.empty_level()
	for c in cells:
		level[c.y][c.x] = cells[c]
	return level


func _pop(sim: Sim, slot: String, target := "") -> void:
	var p := sim.player(slot)
	p.launcher_colour = 0
	sim.step({slot: {"fire": true, "target": target}})
	sim.step({slot: {"target": target}})
	for i in 45:
		sim.step(IDLE)


func test_all_network_players_share_full_size_geometry() -> void:
	var sim := _sim(4)
	for p in sim.players:
		assert_false(p.mini)
		assert_eq(p.bubble_size, 32.0)


func test_malus_split_evenly_among_living_opponents() -> void:
	var sim := _sim(4)
	_pop(sim, "n0")
	var queued := 0
	for s in ["n1", "n2", "n3"]:
		assert_eq(sim.player(s).malus_queue.size(), 1, "%s gets ceil(3/3)" % s)
		queued += sim.player(s).malus_queue.size()
	assert_eq(sim.player("n0").malus_queue.size(), 0)


func test_malus_all_to_target() -> void:
	var sim := _sim(4)
	_pop(sim, "n0", "n2")
	assert_eq(sim.player("n2").malus_queue.size(), 3)
	assert_eq(sim.player("n1").malus_queue.size(), 0)
	assert_eq(sim.player("n3").malus_queue.size(), 0)


func test_player_left_clears_board_and_last_standing_wins() -> void:
	var sim := _sim(3)
	var ev := []
	sim.player_left("n1")
	assert_true(sim.player("n1").left)
	assert_eq(sim.player("n1").grid.count(), 0)
	assert_eq(sim.player("n1").state, Playfield.State.LOST)
	assert_eq(sim.living().size(), 2)
	sim.player_left("n2")
	assert_eq(sim.player("n0").state, Playfield.State.WON, "last one standing wins")
	assert_eq(sim.player("n0").score, 1)


func test_target_of_left_player_is_dropped() -> void:
	var sim := _sim(3)
	sim.step({"n0": {"target": "n2"}})
	assert_eq(sim.player("n0").target, "n2")
	sim.player_left("n2")
	assert_eq(sim.player("n0").target, "")
