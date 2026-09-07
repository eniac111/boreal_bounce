class_name HighScores
extends RefCounted
## High-score tables, stored as JSON in user://scores.json.
##
## "levels": top 10 entries {name, level, time, won}; a finished levelset (won) beats any level
## number, then a higher level beats a lower one, then a shorter time wins
## (ordered_highscores / lvl_cmp in the original, bin/frozen-bubble:5274-5313).
## "training" and "training_chain": top 20 entries {name, score}, higher first.

const PATH := "user://scores.json"
const MAX_LEVELS := 10
const MAX_TRAINING := 20

var levels: Array = []
var training: Array = []
var training_chain: Array = []


static func load_from(path := PATH) -> HighScores:
	var hs := HighScores.new()
	if FileAccess.file_exists(path):
		var data = JSON.parse_string(FileAccess.get_file_as_string(path))
		if data is Dictionary:
			hs.levels = data.get("levels", [])
			hs.training = data.get("training", [])
			hs.training_chain = data.get("training_chain", [])
	hs.sort()
	return hs


func save_to(path := PATH) -> Error:
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return FileAccess.get_open_error()
	f.store_string(JSON.stringify({"levels": levels, "training": training, "training_chain": training_chain}, "\t"))
	return OK


static func compare_levels(a: Dictionary, b: Dictionary) -> bool:
	if a.get("won", false) != b.get("won", false):
		return a.get("won", false)
	if int(a["level"]) != int(b["level"]):
		return int(a["level"]) > int(b["level"])
	return float(a["time"]) < float(b["time"])


func sort() -> void:
	levels.sort_custom(compare_levels)
	training.sort_custom(func(a, b): return int(a["score"]) > int(b["score"]))
	training_chain.sort_custom(func(a, b): return int(a["score"]) > int(b["score"]))


## True when a game that reached [param level] (or won) in [param time] seconds would enter the table.
func qualifies_levels(level: int, won: bool, time: float) -> bool:
	if levels.size() < MAX_LEVELS:
		return true
	var worst: Dictionary = levels[levels.size() - 1]
	return compare_levels({"level": level, "won": won, "time": time}, worst)


## Inserts and trims; returns the rank (0-based) or -1 when it did not qualify.
func add_levels(name: String, level: int, won: bool, time: float) -> int:
	if not qualifies_levels(level, won, time):
		return -1
	var entry := {"name": name, "level": level, "won": won, "time": snappedf(time, 0.01)}
	levels.append(entry)
	sort()
	levels = levels.slice(0, MAX_LEVELS)
	return levels.find(entry)


func qualifies_training(score: int, chain: bool) -> bool:
	var table := training_chain if chain else training
	return table.size() < MAX_TRAINING or score > int(table[table.size() - 1]["score"])


func add_training(name: String, score: int, chain: bool) -> int:
	if not qualifies_training(score, chain):
		return -1
	var entry := {"name": name, "score": score}
	if chain:
		training_chain.append(entry)
		sort()
		training_chain = training_chain.slice(0, MAX_TRAINING)
		return training_chain.find(entry)
	training.append(entry)
	sort()
	training = training.slice(0, MAX_TRAINING)
	return training.find(entry)
