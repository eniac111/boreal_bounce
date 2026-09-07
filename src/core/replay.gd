class_name Replay
extends RefCounted
## Recording of a game: the header (mode, rules, seed, level) plus the input changes per frame.
## Because Sim is deterministic, feeding the same inputs to a Sim built from the header
## reproduces the game exactly. Files are gzip-compressed JSON (Godot's compressed container).
##
## Format version 1:
##   {"version": 1, "header": {...}, "frames": N, "deltas": [[frame, slot_index, mask], ...]}
## mask bits: 1 left, 2 right, 4 fire, 8 center.

const VERSION := 1
const DIR := "user://records/"
const EXT := ".bbr"

var header := {}
var frames := 0
var deltas: Array = []
var _last := {}


func start(header_: Dictionary) -> void:
	header = header_
	frames = 0
	deltas = []
	_last = {}


static func mask_of(inp: Dictionary) -> int:
	var m := 0
	if inp.get("left", false):
		m |= 1
	if inp.get("right", false):
		m |= 2
	if inp.get("fire", false):
		m |= 4
	if inp.get("center", false):
		m |= 8
	return m


static func inputs_of(mask: int) -> Dictionary:
	return {"left": mask & 1 != 0, "right": mask & 2 != 0, "fire": mask & 4 != 0, "center": mask & 8 != 0}


## Records the inputs of one frame (call before Sim.step with the same inputs).
func record(frame: int, inputs: Dictionary) -> void:
	var slots: Array = header.get("slots", [])
	for i in slots.size():
		var mask := mask_of(inputs.get(slots[i], {}))
		if mask != _last.get(i, 0):
			deltas.append([frame, i, mask])
			_last[i] = mask
	frames = frame + 1


func to_dict() -> Dictionary:
	return {"version": VERSION, "header": header, "frames": frames, "deltas": deltas}


func from_dict(d: Dictionary) -> bool:
	if int(d.get("version", 0)) != VERSION:
		return false
	header = d.get("header", {})
	frames = int(d.get("frames", 0))
	deltas = d.get("deltas", [])
	return true


func save(path: String) -> Error:
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var f := FileAccess.open_compressed(path, FileAccess.WRITE, FileAccess.COMPRESSION_GZIP)
	if f == null:
		return FileAccess.get_open_error()
	f.store_string(JSON.stringify(to_dict()))
	return OK


static func load_file(path: String) -> Replay:
	var f := FileAccess.open_compressed(path, FileAccess.READ, FileAccess.COMPRESSION_GZIP)
	if f == null:
		return null
	var data = JSON.parse_string(f.get_as_text())
	if not (data is Dictionary):
		return null
	var r := Replay.new()
	return r if r.from_dict(data) else null


static func default_path() -> String:
	return DIR + Time.get_datetime_string_from_system(false, true).replace(":", "-").replace(" ", "_") + EXT


## Plays the recorded inputs back frame by frame.
class Cursor:
	var replay: Replay
	var _index := 0
	var _masks := {}

	func _init(r: Replay) -> void:
		replay = r

	func inputs_at(frame: int) -> Dictionary:
		while _index < replay.deltas.size() and int(replay.deltas[_index][0]) <= frame:
			var d: Array = replay.deltas[_index]
			_masks[int(d[1])] = int(d[2])
			_index += 1
		var out := {}
		var slots: Array = replay.header.get("slots", [])
		for i in slots.size():
			out[slots[i]] = Replay.inputs_of(_masks.get(i, 0))
		return out

	func finished(frame: int) -> bool:
		return frame >= replay.frames
