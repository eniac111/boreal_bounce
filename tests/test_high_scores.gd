extends TestCase


func test_ordering_and_trimming() -> void:
	var hs := HighScores.new()
	for i in 12:
		hs.add_levels("p%d" % i, i + 1, false, 100.0 - i)
	assert_eq(hs.levels.size(), 10)
	assert_eq(hs.levels[0]["level"], 12, "highest level first")
	assert_eq(hs.levels[9]["level"], 3, "lowest two dropped")
	assert_eq(hs.add_levels("slow", 1, false, 5.0), -1, "level 1 no longer qualifies")
	var rank := hs.add_levels("fast", 12, false, 10.0)
	assert_eq(rank, 0, "same level, faster time ranks first")
	rank = hs.add_levels("winner", 40, true, 9999.0)
	assert_eq(rank, 0, "a won game beats any level")
	assert_eq(hs.levels.size(), 10)


func test_training_tables_are_separate() -> void:
	var hs := HighScores.new()
	assert_eq(hs.add_training("a", 10, false), 0)
	assert_eq(hs.add_training("b", 20, true), 0)
	assert_eq(hs.training.size(), 1)
	assert_eq(hs.training_chain.size(), 1)
	assert_eq(hs.add_training("c", 15, false), 0)
	assert_eq(hs.training[1]["name"], "a")


func test_save_and_load_roundtrip() -> void:
	var path := "user://test_scores.json"
	var hs := HighScores.new()
	hs.add_levels("me", 7, false, 123.456)
	hs.add_training("me", 42, true)
	assert_eq(hs.save_to(path), OK)
	var back := HighScores.load_from(path)
	assert_eq(back.levels.size(), 1)
	assert_eq(back.levels[0]["name"], "me")
	assert_eq(int(back.levels[0]["level"]), 7)
	assert_near(float(back.levels[0]["time"]), 123.46, 0.001)
	assert_eq(back.training_chain[0]["score"], 42)
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
