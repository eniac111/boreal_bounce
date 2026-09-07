extends TestCase


func _scripted(slot: String, f: int) -> Dictionary:
	if slot == "a":
		return {"left": f % 40 < 15, "fire": f % 40 == 20}
	return {"right": f % 50 < 10, "fire": f % 50 == 30}


func test_two_peers_stay_in_sync_through_a_relay() -> void:
	var slots: Array[String] = ["a", "b"]
	var server := Lockstep.new(slots, 3)
	var peer_a := Lockstep.new(slots, 3)
	var peer_b := Lockstep.new(slots, 3)
	var sim_a := Sim.new(Rules.versus(), 42)
	var sim_b := Sim.new(Rules.versus(), 42)
	for s in [sim_a, sim_b]:
		s.add_player("a", Layouts.POS_1P["p1"])
		s.add_player("b", Layouts.POS_1P["p1"])
		s.start_random_board()
	var stalls := 0
	for tick in 600:
		# each peer sends its scheduled inputs; peer b's arrive one tick late to the server
		for f in peer_a.frames_to_send():
			var merged := server.collect(f, "a", _scripted("a", f) if f >= 3 else {})
			peer_a.mark_sent(f)
			if not merged.is_empty():
				peer_a.receive_frame(f, merged)
				peer_b.receive_frame(f, merged)
		if tick > 0:
			for f in peer_b.frames_to_send():
				var merged := server.collect(f, "b", _scripted("b", f) if f >= 3 else {})
				peer_b.mark_sent(f)
				if not merged.is_empty():
					peer_a.receive_frame(f, merged)
					peer_b.receive_frame(f, merged)
		if peer_a.can_step():
			sim_a.step(peer_a.take_frame())
		else:
			stalls += 1
		if peer_b.can_step():
			sim_b.step(peer_b.take_frame())
	assert_true(sim_a.frame > 500, "peer a advanced %d frames" % sim_a.frame)
	assert_true(stalls < 10, "few stalls: %d" % stalls)
	# bring the peer that lags to the same frame and compare
	while sim_b.frame < sim_a.frame and peer_b.can_step():
		sim_b.step(peer_b.take_frame())
	while sim_a.frame < sim_b.frame and peer_a.can_step():
		sim_a.step(peer_a.take_frame())
	assert_eq(sim_b.frame, sim_a.frame, "both peers reached the same frame")
	assert_eq(sim_a.state_hash(), sim_b.state_hash(), "identical state after lockstep")


func test_left_player_does_not_block_frames() -> void:
	var slots: Array[String] = ["a", "b", "c"]
	var server := Lockstep.new(slots, 2)
	assert_true(server.collect(0, "a", {}).is_empty())
	assert_true(server.collect(0, "b", {}).is_empty())
	server.player_left("c")
	var done := server.flush_left()
	assert_eq(done.size(), 1)
	assert_eq(done[0][0], 0)
	assert_true(done[0][1].has("c") and done[0][1]["c"].is_empty(), "left player gets empty inputs")
	var merged := server.collect(1, "a", {"fire": true})
	assert_true(merged.is_empty())
	merged = server.collect(1, "b", {})
	assert_eq(merged["a"]["fire"], true)


func test_frames_to_send_respects_delay() -> void:
	var ls := Lockstep.new(["a"] as Array[String], 3)
	assert_eq(ls.frames_to_send(), [0, 1, 2, 3])
	for f in ls.frames_to_send():
		ls.mark_sent(f)
	assert_eq(ls.frames_to_send(), [])
	ls.receive_frame(0, {"a": {}})
	ls.take_frame()
	assert_eq(ls.frames_to_send(), [4])
