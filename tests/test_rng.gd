extends TestCase


func test_same_seed_same_sequence() -> void:
	var a := Rng.new(12345)
	var b := Rng.new(12345)
	for i in 200:
		assert_eq(a.below(8), b.below(8))
	var c := Rng.new(12346)
	var same := true
	for i in 20:
		if a.below(1000) != c.below(1000):
			same = false
	assert_false(same, "different seeds diverge")


func test_below_range() -> void:
	var r := Rng.new(7)
	var seen := {}
	for i in 1000:
		var v := r.below(8)
		assert_true(v >= 0 and v < 8)
		seen[v] = true
	assert_eq(seen.size(), 8, "all 8 colours appear")
