extends Node
## What the player chose in the menus, read by the game screen (autoload "Session").

enum Mode { LEVELS, RANDOM, TRAINING, VERSUS, NETWORK }

var mode := Mode.LEVELS
var levelset_path := "res://assets/levels/default-levelset.lvl"
## 1-based level to start at in LEVELS mode.
var start_level := 1
var chain_reaction := false
## Wall-clock start of the current 1p game (for the highscore time), in msec.
var game_started_msec := 0
## Frames spent paused, subtracted from the highscore time.
var paused_msec := 0
## Index of the entry just added to the high-score table (bold on the screen), or -1.
var new_entry := -1
## Debug: fill the high-score screen with sample entries.
var fake_scores := false
## Which high-score page to open first (2 = training).
var scores_page := 1
## The editor scene opens the "pick levelset and start level" dialog instead of the editor.
var editor_pick := false
## "lan" or "net": which server browser the lobby shows.
var net_kind := "lan"
## Replay file to play instead of a live game ("" = live). attract: started by the menu's
## idle timer, returns to the menu with the black curtain when done.
var replay_path := ""
var attract := false


func reset_for_new_game() -> void:
	game_started_msec = Time.get_ticks_msec()
	paused_msec = 0


func elapsed_seconds() -> float:
	return (Time.get_ticks_msec() - game_started_msec - paused_msec) / 1000.0


const MODE_NAMES := {Mode.LEVELS: "levels", Mode.RANDOM: "random", Mode.TRAINING: "training", Mode.VERSUS: "versus", Mode.NETWORK: "network"}


static func mode_name(m: int) -> String:
	return MODE_NAMES.get(m, "levels")


static func mode_from_name(name: String) -> int:
	for m in MODE_NAMES:
		if MODE_NAMES[m] == name:
			return m
	return Mode.LEVELS
