class_name Playfield
extends RefCounted
## State of one player's board. Pure data plus geometry helpers; all mutation happens in Sim.
## Pixel coordinates are the top-left of a bubble sprite on the 640x480 canvas, as in the
## original (calc_real_pos_given_arraypos, bin/frozen-bubble:620).

enum State { INGAME, WON, LOST }

const EMPTY := LevelSet.EMPTY
const STONE := LevelSet.STONE

var slot := "p1"
var mini := false
var left_limit := 190.0
var right_limit := 446.0
var top_limit := 44.0
var initial_bubble_y := 390.0
var bubble_size := 32.0
var row_size := 28.0

var grid := Grid.new()
var state := State.INGAME
## Ceiling row (rows above it are unreachable after the compressor lowered the ceiling).
var newrootlevel := 0
## Landed shots since the compressor last fired.
var newroot := 0
## 0 = off, 2 = slow white sweep (two shots left), 1 = fast sweep (one shot left).
var newroot_prelight := 0
var newroot_prelight_step := 0
var angle := PI / 2
## Colour waiting in the cannon (-1 while nothing is loaded) and the one shown as "next".
var launcher_colour := -1
var next_colour := -1
## In-flight shot: {x, y, x_old, y_old, dir, colour}. Empty when none.
var flying := {}
## Falling bubbles: {x, y, colour, wait, speed}, plus for chain reaction
## {chain: {cx, cy, x, y}, going_up: bool, vx: float}. Exploding: {x, y, colour, vx, vy}.
var falling: Array[Dictionary] = []
var exploding: Array[Dictionary] = []
var hurry := 0
var hurry_oddness := false
var hurry_shown := false
var fire_flag := false
var fire_prev := false
## Set for one frame when a shot was fired; drives the penguin "action" animation.
var hadfire := false
## Stick flash on the last stuck shot: {cx, cy, step, slowdown}. Empty when none.
var sticking := {}
## Level number (1p), training score, or rounds won (2p).
var score := 0
## Pending malus for this player: frame numbers at which each was queued.
var malus_queue: Array[int] = []
## Malus bubbles in flight: {x, y, cx, stick_y, colour}.
var malus_flying: Array[Dictionary] = []
## Lose sequence: cells still to freeze (bottom-right first) and the ones already frozen.
var lose_pending: Array[Vector2i] = []
var frozen: Dictionary = {}
var lose_done := false


## True when this player disconnected from a network game (board cleared, counts as lost).
var left := false
## Slot all produced malus goes to ("" = spread evenly among living opponents).
var target := ""


func setup(slot_: String, layout: Dictionary, mini_ := false) -> void:
	slot = slot_
	mini = mini_
	left_limit = layout["left_limit"]
	right_limit = layout["right_limit"]
	top_limit = layout["top_limit"]
	initial_bubble_y = layout["initial_bubble_y"]
	bubble_size = Layouts.BUBBLE_SIZE / 2.0 if mini else Layouts.BUBBLE_SIZE
	row_size = Layouts.ROW_SIZE / 2.0 if mini else Layouts.ROW_SIZE


func cell_to_pixel(cx: int, cy: int) -> Vector2:
	var odd := 1 if grid.is_offset_row(cy) else 0
	return Vector2(left_limit + cx * bubble_size + odd * bubble_size / 2.0, top_limit + cy * row_size)


## Nearest cell for a bubble at pixel (x, y); no clamping, like get_array_closest_pos.
func pixel_to_cell(x: float, y: float) -> Vector2i:
	var ny := int((y - top_limit + row_size / 2.0) / row_size)
	var odd := 1 if grid.is_offset_row(ny) else 0
	var nx := int((x - left_limit + bubble_size / 2.0 - odd * bubble_size / 2.0) / bubble_size)
	return Vector2i(nx, ny)


func launch_pos() -> Vector2:
	return Vector2((left_limit + right_limit) / 2.0 - bubble_size / 2.0, initial_bubble_y)


func ceiling_y() -> float:
	return top_limit + newrootlevel * row_size


func colours_on_board() -> Dictionary:
	var seen := {}
	for row in grid.rows:
		for v in row:
			if v >= 0:
				seen[v] = true
	return seen


func is_ingame() -> bool:
	return state == State.INGAME


func chain_pending() -> bool:
	for b in falling:
		if b.has("chain"):
			return true
	return false


## Number of pending malus bubbles, for the banana/tomato stack.
func malus_count() -> int:
	return malus_queue.size()
