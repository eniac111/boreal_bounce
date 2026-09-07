extends SceneTree
## Headless test runner:  godot --headless --path . -s tests/run_tests.gd
## Loads every tests/test_*.gd (must extend TestCase) and runs its test_* methods.

const TEST_DIR := "res://tests"


func _init() -> void:
	var total := 0
	var failed := 0
	var files := DirAccess.get_files_at(TEST_DIR)
	files.sort()
	for f in files:
		if not (f.begins_with("test_") and f.ends_with(".gd")) or f == "test_case.gd":
			continue
		var script: GDScript = load(TEST_DIR + "/" + f)
		if script == null or not script.can_instantiate():
			total += 1
			failed += 1
			print("  FAIL %s: script does not load (see errors above)" % f)
			continue
		for m in script.get_script_method_list():
			if not m.name.begins_with("test_"):
				continue
			total += 1
			var tc = script.new()
			if tc == null:
				failed += 1
				print("  FAIL %s::%s: cannot instantiate" % [f, m.name])
				continue
			tc.call(m.name)
			if tc.checks == 0 and tc.failures.is_empty():
				tc.failures.append("no assertions ran (script error inside the test?)")
			if tc.failures.is_empty():
				print("  ok   %s::%s (%d checks)" % [f, m.name, tc.checks])
			else:
				failed += 1
				print("  FAIL %s::%s" % [f, m.name])
				for msg in tc.failures:
					print("       " + msg)
	print("\n%d tests, %d failed" % [total, failed])
	quit(1 if failed > 0 else 0)
