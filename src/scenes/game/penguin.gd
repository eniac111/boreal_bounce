class_name Penguin
extends Sprite2D
## The player's penguin, driven by the same state machine as the original
## (bin/frozen-bubble:2271-2315, 2599-2624): one animation frame per game frame.
## Frame ranges refer to the packed anime-shooter / wait / win / loose sheets.

var slot := "p1"
var state := "normal"
var img := 0
var sleeping := 0
var _shooter: SpriteFrames
var _wait: SpriteFrames
var _win: SpriteFrames
var _lose: SpriteFrames
## state -> [sheet, first index, count, step] (step -1 = reversed)
var _anims := {}


func setup(slot_: String) -> void:
	slot = slot_
	centered = false
	_shooter = BubbleArt.penguin(slot, "anime-shooter")
	_wait = BubbleArt.penguin(slot, "wait")
	_win = BubbleArt.penguin(slot, "win")
	_lose = BubbleArt.penguin(slot, "loose")
	_anims = {
		"normal": [_shooter, 19, 1, 1],
		"action": [_shooter, 20, 30, 1],
		"left_to": [_shooter, 18, 18, -1],
		"left": [_shooter, 0, 1, 1],
		"left_from": [_shooter, 1, 18, 1],
		"right_to": [_shooter, 50, 20, 1],
		"right": [_shooter, 70, 1, 1],
		"right_from": [_shooter, 70, 21, -1],
		"wait_to": [_wait, 0, 74, 1],
		"wait": [_wait, 74, 23, 1],
		"win": [_win, 0, 68, 1],
		"lose_to": [_lose, 0, 64, 1],
		"lose": [_lose, 64, 94, 1],
	}
	_apply_frame()


func _count(s: String) -> int:
	return _anims[s][2]


func set_state(s: String) -> void:
	state = s
	img = 0


## Per game frame. left/right: aiming keys held; hadfire: a shot was fired this frame.
func tick(left: bool, right: bool, hadfire: bool, ingame: bool) -> void:
	if ingame:
		if not left and not right and not hadfire:
			sleeping += 1
		else:
			sleeping = 0
		if sleeping > Rules.PENGUIN_SLEEP_FRAMES and not state.begins_with("wait"):
			set_state("wait_to")
		if sleeping <= Rules.PENGUIN_SLEEP_FRAMES and state.begins_with("wait"):
			state = "normal"
		for direction in ["left", "right"]:
			var held: bool = left if direction == "left" else right
			if state == direction + "_to" and not held:
				state = direction + "_from"
				img = _count(state) - img
			if state == direction and not held:
				set_state(direction + "_from")
			if held:
				if state == direction + "_to" or state == direction:
					pass
				elif state == direction + "_from":
					state = direction
				else:
					set_state(direction + "_to")
		if hadfire:
			set_state("action")
		if img >= _count(state):
			img = 0
	# frame advance (all states)
	if state in ["action", "right_to", "right_from", "left_to", "left_from", "wait_to", "wait", "win", "lose_to", "lose"]:
		img += 1
		if img == _count(state):
			match state:
				"right_to":
					state = "right"
				"left_to":
					state = "left"
				"wait_to":
					state = "wait"
				"wait", "win", "lose":
					pass
				"lose_to":
					state = "lose"
				_:
					state = "normal"
			img = 0
	_apply_frame()


func _apply_frame() -> void:
	var a: Array = _anims[state]
	var sheet: SpriteFrames = a[0]
	var index: int = a[1] + a[3] * mini(img, a[2] - 1)
	texture = sheet.get_frame_texture("default", index)
