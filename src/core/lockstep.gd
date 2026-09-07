class_name Lockstep
extends RefCounted
## Input frame buffer for deterministic lockstep play. Every peer runs the same Sim; the
## server collects each player's input for frame f and broadcasts the merged frame; a peer
## only steps frame f once that merged frame has arrived. Local inputs are scheduled
## [member delay] frames ahead so the round trip is hidden.

## Frames of input delay (2-3 frames = 40-60 ms at 50 Hz).
var delay := 3
## Slots in canonical order (identical on every peer).
var slots: Array[String] = []
## frame -> {slot: inputs} as received from the server.
var frames := {}
## Next frame the simulation should step.
var next_frame := 0
## Frames for which the local input has already been sent.
var local_sent := -1
## Server side: frame -> {slot: inputs} collected so far.
var collecting := {}
## Server side: slots that left the game (their inputs are filled with empty).
var left := {}


func _init(slots_: Array[String] = [], delay_ := 3) -> void:
	slots = slots_
	delay = delay_


## Frames the local player should submit inputs for right now: from the last sent one up to
## next_frame + delay. The first frames (0 .. delay-1) are always empty so play can start.
func frames_to_send() -> Array[int]:
	var out: Array[int] = []
	var target := next_frame + delay
	var f := local_sent + 1
	while f <= target:
		out.append(f)
		f += 1
	return out


func mark_sent(frame: int) -> void:
	local_sent = maxi(local_sent, frame)


## Client side: stores the merged inputs of one frame received from the server.
func receive_frame(frame: int, inputs: Dictionary) -> void:
	if frame >= next_frame:
		frames[frame] = inputs


func can_step() -> bool:
	return frames.has(next_frame)


## Returns the merged inputs of the next frame and advances; call only when can_step().
func take_frame() -> Dictionary:
	var inputs: Dictionary = frames[next_frame]
	frames.erase(next_frame)
	next_frame += 1
	return inputs


## How many frames are buffered beyond the next one (for stall diagnostics).
func buffered() -> int:
	return frames.size()


# --- server side ---------------------------------------------------------------------------

## Records one player's input for a frame. Returns the merged frame when complete, else {}.
func collect(frame: int, slot: String, inputs: Dictionary) -> Dictionary:
	if not collecting.has(frame):
		collecting[frame] = {}
	collecting[frame][slot] = inputs
	return _complete(frame)


func player_left(slot: String) -> void:
	left[slot] = true


## Completes every pending frame that only waits for players who left.
func flush_left() -> Array:
	var done := []
	var keys := collecting.keys()
	keys.sort()
	for f in keys:
		var merged := _complete(f)
		if not merged.is_empty():
			done.append([f, merged])
	return done


func _complete(frame: int) -> Dictionary:
	var got: Dictionary = collecting[frame]
	for s in slots:
		if not got.has(s) and not left.has(s):
			return {}
	var merged := {}
	for s in slots:
		merged[s] = got.get(s, {})
	collecting.erase(frame)
	return merged
