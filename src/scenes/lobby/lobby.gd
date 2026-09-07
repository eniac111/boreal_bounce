extends Node2D
## Network lobby. Phases: BROWSE (LAN discovery or the internet servers: the configured public
## server, the last one used, or a typed address), HALL (connected to a dedicated relay: list of
## rooms; create one or join by code) and ROOM (players, ready flags, wins, chat).
## Chat commands: /ready, /start (host), /nick NAME, /me ACTION, /list, /kick NAME (host),
## /leave (back to the hall), /quit.

enum Phase { BROWSE, HALL, ROOM }

const CHAT_LINES := 9
const LEFT_X := 30

var phase := Phase.BROWSE
var servers: Array = []
var selected := 0
var address := ""
var typing := ""
var status := ""
var chat: Array[String] = []
var _labels := {}
var _blink := 0
var _upnp_thread: Thread
var _upnp_mapped := false


func _ready() -> void:
	$Background.texture = Art.tex("res://assets/gfx/back_netgame.png")
	# the plank at the bottom right carried "Network play..." as part of the artwork
	var plank := UiText.funky(tr("Network play") + "...", 15)
	plank.position = Vector2(360, 452)
	plank.size = Vector2(268, 22)
	plank.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	plank.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	plank.clip_text = true
	UiText.fit(plank, 262, 15)
	add_child(plank)
	for key in ["title", "status", "list", "players", "chat", "input", "hint"]:
		var l := UiText.make("", 13)
		l.autowrap_mode = TextServer.AUTOWRAP_OFF
		add_child(l)
		_labels[key] = l
	_labels["title"].position = Vector2(LEFT_X, 12)
	_labels["title"].add_theme_font_size_override("font_size", 16)
	_labels["status"].position = Vector2(LEFT_X, 40)
	_labels["list"].position = Vector2(LEFT_X, 70)
	_labels["players"].position = Vector2(400, 70)
	_labels["chat"].position = Vector2(LEFT_X, 190)
	_labels["chat"].autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_labels["chat"].size = Vector2(590, 200)
	_labels["input"].position = Vector2(LEFT_X, 400)
	_labels["hint"].position = Vector2(LEFT_X, 440)
	_labels["hint"].add_theme_font_size_override("font_size", 11)
	Net.lobby_changed.connect(_on_lobby_changed)
	Net.hall_changed.connect(_on_lobby_changed)
	Net.chat_message.connect(_on_chat)
	Net.game_starting.connect(_on_game_starting)
	Net.disconnected.connect(_on_disconnected)
	Net.servers_found.connect(_on_servers_found)
	Net.game_ended.connect(_on_lobby_changed)
	Audio.play_music("introzik")
	if Net.connected:
		phase = Phase.ROOM if Net.in_room() else Phase.HALL
	else:
		phase = Phase.BROWSE
		address = Settings.last_server
		if Session.net_kind == "lan":
			status = tr("Looking for servers on the local network...")
			Net.discover_lan()
		else:
			_build_internet_list()
	_refresh()


func _exit_tree() -> void:
	if _upnp_thread != null:
		_upnp_thread.wait_to_finish()


func _build_internet_list() -> void:
	servers = []
	if Settings.default_server != "":
		servers.append({"name": tr("Public server"), "address": Settings.default_server})
	if Settings.last_server != "" and Settings.last_server != Settings.default_server:
		servers.append({"name": tr("Last server"), "address": Settings.last_server})
	selected = 0


func _physics_process(_delta: float) -> void:
	_blink = (_blink + 1) % 50
	if _blink == 0 or _blink == 25:
		_refresh_input()


func _refresh_input() -> void:
	var caret := "|" if _blink < 25 else " "
	match phase:
		Phase.BROWSE:
			if Session.net_kind == "net":
				_labels["input"].text = tr("Or type an address (host:port):") + " " + address + caret
			else:
				_labels["input"].text = ""
		Phase.HALL:
			_labels["input"].text = tr("Room code:") + " " + typing + caret
		Phase.ROOM:
			_labels["input"].text = "> " + typing + caret


func _on_lobby_changed() -> void:
	if Net.connected:
		var new_phase := Phase.ROOM if Net.in_room() else Phase.HALL
		if new_phase != phase:
			chat.clear()
			typing = ""
		phase = new_phase
	_refresh()


func _refresh() -> void:
	var lan := Session.net_kind == "lan"
	match phase:
		Phase.BROWSE:
			_labels["title"].text = tr("LAN game") if lan else tr("Internet game")
			_labels["status"].text = status
			var lines := PackedStringArray()
			for i in servers.size():
				var s: Dictionary = servers[i]
				var prefix := "> " if i == selected else "  "
				if lan:
					lines.append(prefix + "%s  %s:%d  (%d)" % [s["name"], s["host"], s["port"], s["players"]])
				else:
					lines.append(prefix + "%s  %s" % [s["name"], s["address"]])
			if servers.is_empty():
				lines.append(tr("No server found yet.") if lan else tr("No public server configured (see Options)."))
			_labels["list"].text = "\n".join(lines)
			_labels["players"].text = ""
			_labels["chat"].text = ""
			_labels["hint"].text = tr("Return: join   H: host a game   R: search again   Escape: back") if lan else tr("Return: join   H: host a game   Escape: back")
		Phase.HALL:
			_labels["title"].text = Net.server_name
			_labels["status"].text = tr("Rooms on this server:")
			var lines := PackedStringArray()
			for r in Net.rooms:
				lines.append("%s   %d %s%s" % [r["code"], r["players"], tr("players"), "   " + tr("(playing)") if r["in_game"] else ""])
			if Net.rooms.is_empty():
				lines.append(tr("No room yet. Press N to create one."))
			_labels["list"].text = "\n".join(lines)
			_labels["players"].text = ""
			_labels["chat"].text = "\n".join(chat.slice(maxi(chat.size() - 4, 0)))
			_labels["hint"].text = tr("N: new room   type a code + Return: join it   Escape: disconnect")
		Phase.ROOM:
			var host_tag := "  (%s)" % tr("you are the host") if Net.is_host_player() else ""
			_labels["title"].text = "%s   %s %s%s" % [Net.server_name, tr("Room"), Net.room_code, host_tag]
			_labels["status"].text = tr("Friends can join with the code %s") % Net.room_code if Net.headless or Net.rooms.size() > 0 else ""
			_labels["list"].text = ""
			var lines := PackedStringArray([tr("Players:")])
			var ids := Net.players.keys()
			ids.sort()
			for id in ids:
				var p: Dictionary = Net.players[id]
				var mark := "*" if p["ready"] or id == Net.host_id() else " "
				lines.append("%s %s  %s: %d" % [mark, p["nick"], tr("wins"), p["wins"]])
			_labels["players"].text = "\n".join(lines)
			_labels["chat"].text = "\n".join(chat.slice(maxi(chat.size() - CHAT_LINES, 0)))
			_labels["hint"].text = tr("/ready  /start (host)  /nick NAME  /me  /list  /kick NAME (host)  /leave  /quit")
	_refresh_input()


func _on_servers_found(list: Array) -> void:
	servers = list
	selected = 0
	status = tr("%s server(s) found") % str(list.size())
	_refresh()


func _on_chat(nick: String, text: String, kind: String) -> void:
	match kind:
		"me":
			chat.append("* %s %s" % [nick, text])
		"server":
			chat.append("*** " + text)
		_:
			chat.append("<%s> %s" % [nick, text])
	Audio.play_sfx("chatted")
	_refresh()


func _on_disconnected(reason: String) -> void:
	phase = Phase.BROWSE
	status = reason
	chat.clear()
	if Session.net_kind == "net":
		_build_internet_list()
	Audio.play_sfx("cancel")
	_refresh()


func _on_game_starting(_info: Dictionary) -> void:
	Session.mode = Session.Mode.NETWORK
	Session.reset_for_new_game()
	Audio.play_music("frozen-mainzik-2p")
	Screens.goto(Screens.GAME, true)


# --- hosting with UPnP -----------------------------------------------------------------------------

func _host() -> void:
	var err := Net.host(Net.DEFAULT_PORT, Settings.nick)
	if err != OK:
		status = tr("Cannot host: %s") % error_string(err)
		_refresh()
		return
	Net.chain_reaction = Session.chain_reaction
	phase = Phase.ROOM
	chat.append("*** " + tr("Hosting on UDP port %s. Type /start when everyone is ready.") % str(Net.DEFAULT_PORT))
	chat.append("*** " + tr("Asking the router to open the port (UPnP)..."))
	Audio.play_sfx("menu_selected")
	_refresh()
	_upnp_thread = Thread.new()
	_upnp_thread.start(_upnp_setup.bind(Net.DEFAULT_PORT))


## Runs in a thread (no tr() here): maps the game port on the router and reports the result.
func _upnp_setup(port: int) -> void:
	var upnp := UPNP.new()
	var err := upnp.discover()
	var result := {"port": port, "found": false, "mapped": false, "external": "", "error": 0}
	if err == UPNP.UPNP_RESULT_SUCCESS and upnp.get_gateway() != null and upnp.get_gateway().is_valid_gateway():
		result["found"] = true
		result["error"] = upnp.add_port_mapping(port, port, "Boreal Bounce", "UDP")
		result["mapped"] = result["error"] == UPNP.UPNP_RESULT_SUCCESS
		result["external"] = upnp.query_external_address()
	call_deferred("_upnp_report", result)


func _upnp_report(r: Dictionary) -> void:
	var port := str(r["port"])
	if not r["found"]:
		chat.append("*** " + tr("No UPnP router found. Players on the internet need UDP port %s forwarded to this machine.") % port)
	elif r["mapped"]:
		_upnp_mapped = true
		chat.append("*** " + tr("Router port %s opened. Internet players can join %s:%s") % [port, r["external"], port])
	else:
		chat.append("*** " + tr("Router refused the port mapping (%s). Public address: %s") % [str(r["error"]), r["external"]])
	_refresh()


func _remove_upnp() -> void:
	if not _upnp_mapped:
		return
	_upnp_mapped = false
	var t := Thread.new()
	t.start(func():
		var upnp := UPNP.new()
		if upnp.discover() == UPNP.UPNP_RESULT_SUCCESS:
			upnp.delete_port_mapping(Net.DEFAULT_PORT, "UDP"))
	t.wait_to_finish()


func _join(host: String, port: int) -> void:
	status = tr("Connecting to %s...") % host
	_refresh()
	var err := Net.join(host, port, Settings.nick)
	if err != OK:
		status = tr("Cannot connect: %s") % error_string(err)
		_refresh()
		return
	Settings.last_server = "%s:%d" % [host, port]
	Settings.save_settings()
	chat.clear()
	_refresh()


func _join_address(addr: String) -> void:
	var host := addr.get_slice(":", 0).strip_edges()
	var port := int(addr.get_slice(":", 1)) if addr.contains(":") else Net.DEFAULT_PORT
	if host != "":
		_join(host, port)


# --- input -----------------------------------------------------------------------------------------

func _unhandled_input(event: InputEvent) -> void:
	if not (event is InputEventKey) or not event.pressed:
		return
	var key := event as InputEventKey
	match phase:
		Phase.BROWSE:
			_browse_key(key)
		Phase.HALL:
			_hall_key(key)
		Phase.ROOM:
			_room_key(key)


func _browse_key(key: InputEventKey) -> void:
	var lan := Session.net_kind == "lan"
	if key.keycode == KEY_ESCAPE:
		Audio.play_sfx("cancel")
		Screens.goto(Screens.MENU)
	elif key.keycode == KEY_H and (lan or address == ""):
		_host()
	elif key.keycode == KEY_R and lan:
		status = tr("Looking for servers on the local network...")
		Net.discover_lan()
		_refresh()
	elif key.keycode == KEY_DOWN:
		selected = mini(selected + 1, maxi(servers.size() - 1, 0))
		_refresh()
	elif key.keycode == KEY_UP:
		selected = maxi(selected - 1, 0)
		_refresh()
	elif key.keycode in [KEY_ENTER, KEY_KP_ENTER]:
		if lan:
			if selected < servers.size():
				_join(servers[selected]["host"], servers[selected]["port"])
		elif address != "":
			_join_address(address)
		elif selected < servers.size():
			_join_address(servers[selected]["address"])
	elif not lan:
		if key.keycode == KEY_BACKSPACE:
			address = address.left(address.length() - 1)
		elif key.unicode >= 32 and key.unicode < 127 and address.length() < 60:
			address += char(key.unicode)
		_refresh_input()


func _hall_key(key: InputEventKey) -> void:
	if key.keycode == KEY_ESCAPE:
		_quit_lobby()
	elif key.keycode == KEY_N and typing == "":
		Net.create_room()
	elif key.keycode in [KEY_ENTER, KEY_KP_ENTER]:
		if typing.strip_edges() != "":
			Net.join_room(typing)
			typing = ""
		_refresh_input()
	elif key.keycode == KEY_BACKSPACE:
		typing = typing.left(typing.length() - 1)
		_refresh_input()
	elif key.unicode >= 32 and typing.length() < 8:
		typing += char(key.unicode).to_upper()
		_refresh_input()


func _room_key(key: InputEventKey) -> void:
	if key.keycode == KEY_ESCAPE:
		if Net.headless_server():
			Net.leave_room()
		else:
			_quit_lobby()
	elif key.keycode in [KEY_ENTER, KEY_KP_ENTER]:
		var line := typing.strip_edges()
		typing = ""
		if line != "":
			_command(line)
		_refresh_input()
	elif key.keycode == KEY_BACKSPACE:
		typing = typing.left(typing.length() - 1)
		_refresh_input()
	elif key.unicode >= 32 and typing.length() < 120:
		typing += char(key.unicode)
		Audio.play_sfx("typewriter")
		_refresh_input()


func _command(line: String) -> void:
	if not line.begins_with("/"):
		Net.send_chat(line)
		return
	var cmd := line.get_slice(" ", 0).to_lower()
	var arg := line.substr(cmd.length()).strip_edges()
	match cmd:
		"/ready":
			var me: Dictionary = Net.players.get(Net.my_id(), {"ready": false})
			Net.set_ready(not me["ready"])
		"/start":
			Net.request_start()
		"/nick":
			if arg != "":
				Settings.nick = arg
				Settings.save_settings()
				Net.change_nick(arg)
		"/me":
			Net.send_chat("/me " + arg)
		"/list":
			var names := PackedStringArray()
			for id in Net.players:
				names.append(Net.players[id]["nick"])
			chat.append("*** " + tr("Players: %s") % ", ".join(names))
			_refresh()
		"/kick":
			Net.kick(arg)
		"/leave":
			if Net.headless_server():
				Net.leave_room()
			else:
				_quit_lobby()
		"/quit":
			_quit_lobby()
		_:
			chat.append("*** " + tr("Unknown command %s") % cmd)
			_refresh()


func _quit_lobby() -> void:
	_remove_upnp()
	Net.leave()
	phase = Phase.BROWSE
	chat.clear()
	status = ""
	if Session.net_kind == "net":
		_build_internet_list()
	Audio.play_sfx("cancel")
	_refresh()
