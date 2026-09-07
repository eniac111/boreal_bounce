class_name Rules
extends RefCounted
## Game constants. Values are per 20 ms frame (the simulation runs at a fixed 50 Hz) and were
## taken from bin/frozen-bubble; see boreal_bounce/PLAN.md §5.2 for the mode table.

const LAUNCHER_SPEED := 0.03          # rad per frame
const BUBBLE_SPEED := 10.0            # px per frame
const MALUS_BUBBLE_SPEED := 30.0      # px per frame, straight up
const FREE_FALL_CONSTANT := 0.5       # px per frame^2
const ANGLE_MIN := 0.1
const ANGLE_MAX := PI - 0.1
const COLLISION_FACTOR := 0.82        # collision when centre distance < BUBBLE_SIZE * 0.82
const LAST_ROW := 11                  # a bubble with cy > LAST_ROW loses the game
const OFFSCREEN_Y := 470.0            # falling / exploding bubbles are dropped below this
const HURRY_BLINK_FRAMES := 25        # half period of the hurry sign (500 ms)
const STICK_EFFECT_FRAMES := 7
const PENGUIN_SLEEP_FRAMES := 200
const MALUS_FREEZE_FRAMES := 20
const MALUS_MAX_PER_SHOT := 7

## Shots before the compressor fires (it fires on shot number time_appears_new_root + 1).
var time_appears_new_root := 8
var hurry_warn := 400
var hurry_max := 525
## 1p modes only accept a new colour that is still present on the board.
var validate_colours := true
## In 1p the compressor lowers the ceiling; otherwise it inserts a row of random bubbles.
var compressor_lowers_ceiling := true
var chain_reaction := false
var no_time_limit := false
var no_instant_death := false
## Multiplayer training: alone against randomly queued malus, scored by malus produced.
var is_training := false
## Mean seconds between random malus batches in training (--mp-training-difficulty).
var training_difficulty := 30
const TRAINING_SECONDS := 120.99
## Local 2p handicap: added to p1's malus output and subtracted from p2's (--player-malus).
var player_malus := 0


static func single_player() -> Rules:
	return Rules.new()


static func versus() -> Rules:
	var r := Rules.new()
	r.time_appears_new_root = 11
	r.hurry_warn = 250
	r.hurry_max = 375
	r.validate_colours = false
	r.compressor_lowers_ceiling = false
	return r


static func training() -> Rules:
	var r := versus()
	r.validate_colours = true
	r.is_training = true
	return r


const _FIELDS := ["time_appears_new_root", "hurry_warn", "hurry_max", "validate_colours",
	"compressor_lowers_ceiling", "chain_reaction", "no_time_limit", "no_instant_death",
	"is_training", "training_difficulty", "player_malus"]


func to_dict() -> Dictionary:
	var d := {}
	for f in _FIELDS:
		d[f] = get(f)
	return d


static func from_dict(d: Dictionary) -> Rules:
	var r := Rules.new()
	for f in _FIELDS:
		if d.has(f):
			r.set(f, d[f])
	return r
