class_name Rng
extends RefCounted
## Seeded random source for the simulation. Every random decision the game makes (bubble
## colours, malus placement) must go through one Rng instance seeded at game start, so that a
## replay or a network peer fed the same seed and inputs reproduces the same game.

var _r := RandomNumberGenerator.new()
var seed_value: int


func _init(seed_: int = 0) -> void:
	reseed(seed_)


func reseed(seed_: int) -> void:
	seed_value = seed_
	_r.seed = seed_


## Integer in [0, n).
func below(n: int) -> int:
	return _r.randi_range(0, n - 1)


func range_int(lo: int, hi: int) -> int:
	return _r.randi_range(lo, hi)


func float01() -> float:
	return _r.randf()


static func fresh_seed() -> int:
	return Time.get_ticks_usec() ^ int(Time.get_unix_time_from_system() * 1000.0)
