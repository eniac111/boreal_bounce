extends TestCase


func _scripted_inputs(f: int) -> Dictionary:
	var inp := {}
	if f % 60 < 20:
		inp = {"p1": {"left": true}, "p2": {"right": f % 3 == 0}}
	elif f % 60 < 30:
		inp = {"p1": {"right": true, "fire": f % 60 == 25}, "p2": {"fire": f % 60 == 27}}
	return inp


func test_masks_roundtrip() -> void:
	for m in 16:
		assert_eq(Replay.mask_of(Replay.inputs_of(m)), m)


func test_record_save_load_and_replay_reproduce_the_game() -> void:
	var header := {"mode": "versus", "rules": Rules.versus().to_dict(), "seed": 77, "slots": ["p1", "p2"], "level": 1}
	var sim := Sim.new(Rules.from_dict(header["rules"]), header["seed"])
	sim.add_player("p1", Layouts.POS_2P["p1"])
	sim.add_player("p2", Layouts.POS_2P["p2"])
	sim.start_random_board()
	var rec := Replay.new()
	rec.start(header)
	for f in 700:
		var inp := _scripted_inputs(f)
		rec.record(sim.frame, inp)
		sim.step(inp)
	var final_hash := sim.state_hash()
	assert_eq(rec.frames, 700)
	assert_true(rec.deltas.size() > 10 and rec.deltas.size() < 700, "deltas only on change: %d" % rec.deltas.size())
	var path := "user://test_replay.bbr"
	assert_eq(rec.save(path), OK)
	var loaded := Replay.load_file(path)
	assert_true(loaded != null, "replay loads back")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	if loaded == null:
		return
	assert_eq(loaded.frames, 700)
	var sim2 := Sim.new(Rules.from_dict(loaded.header["rules"]), int(loaded.header["seed"]))
	sim2.add_player("p1", Layouts.POS_2P["p1"])
	sim2.add_player("p2", Layouts.POS_2P["p2"])
	sim2.start_random_board()
	var cursor := Replay.Cursor.new(loaded)
	while not cursor.finished(sim2.frame):
		sim2.step(cursor.inputs_at(sim2.frame))
	assert_eq(sim2.frame, 700)
	assert_eq(sim2.state_hash(), final_hash, "replayed game ends in the same state")


func test_rules_dict_roundtrip() -> void:
	var r := Rules.training()
	r.chain_reaction = true
	r.player_malus = 2
	var back := Rules.from_dict(r.to_dict())
	assert_eq(back.hurry_max, 375)
	assert_true(back.is_training)
	assert_true(back.chain_reaction)
	assert_eq(back.player_malus, 2)
	assert_true(back.validate_colours)
