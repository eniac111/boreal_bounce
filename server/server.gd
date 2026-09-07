extends Node2D
## Dedicated server screen: nothing to draw, just a status line. Started with `--server[=port]`
## or automatically in builds exported with the "dedicated_server" feature.


func _ready() -> void:
	var l := UiText.make("", 13)
	l.position = Vector2(20, 20)
	l.size = Vector2(600, 400)
	add_child(l)
	Net.lobby_changed.connect(func(): _refresh(l))
	_refresh(l)
	var timer := Timer.new()
	timer.wait_time = 5.0
	timer.autostart = true
	timer.timeout.connect(func(): _refresh(l))
	add_child(timer)


func _refresh(l: Label) -> void:
	var rooms := PackedStringArray()
	for code in Net._rooms:
		var r = Net._rooms[code]
		rooms.append("%s(%d%s)" % [code, r.players.size(), "*" if r.in_game else ""])
	var text := "Boreal Bounce dedicated server\nconnected: %d\nrooms: %s" % [Net._nicks.size(), ", ".join(rooms)]
	l.text = text
	print(text.replace("\n", " | "))
