extends TestCase


func test_default_is_copied_and_listed() -> void:
	LevelStore.ensure_default()
	var names := LevelStore.list()
	assert_true(LevelStore.DEFAULT_NAME in names, "default present: " + str(names))
	var ls := LevelStore.load_set(LevelStore.DEFAULT_NAME)
	assert_eq(ls.size(), 100)


func test_save_load_delete_custom_set() -> void:
	var ls := LevelSet.new()
	ls.levels.append(LevelSet.empty_level())
	ls.levels[0][0][0] = 3
	assert_eq(LevelStore.save_set("test-set_1", ls), OK)
	assert_true(LevelStore.exists("test-set_1"))
	var back := LevelStore.load_set("test-set_1")
	assert_eq(back.size(), 1)
	assert_eq(back.levels[0][0][0], 3)
	assert_eq(LevelStore.delete("test-set_1"), OK)
	assert_false(LevelStore.exists("test-set_1"))


func test_name_rules() -> void:
	assert_true(LevelStore.is_ok_name("my-levels_2"))
	assert_false(LevelStore.is_ok_name(""))
	assert_false(LevelStore.is_ok_name("has space"))
	assert_false(LevelStore.is_ok_name("dots.are.bad"))
	assert_false(LevelStore.is_ok_name("a".repeat(21)))
