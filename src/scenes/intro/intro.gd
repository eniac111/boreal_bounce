extends Node2D
## Splash: a short black screen, then the menu is revealed with one of the original plasma
## transitions. (The original had no separate intro; its menu simply appeared.)


func _ready() -> void:
	Screens.intro_shown = true
	if OS.has_feature("dedicated_server"):
		Net.host(Net.DEFAULT_PORT, "", true)
		Screens.goto("res://server/server.tscn")
		return
	await get_tree().create_timer(0.6).timeout
	Screens.goto(Screens.MENU, true, "plasma")
