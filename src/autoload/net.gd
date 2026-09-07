extends Node
## Network play (autoload "Net"): rooms with join codes, lobby, chat, LAN discovery and the
## lockstep relay, over Godot's ENet high-level multiplayer. The server (peer 1) owns the
## rooms, deals each round's seed and relays input frames; every peer runs the same
## deterministic Sim (see PLAN.md §8). A player hosting from the lobby is a server with a single
## room that joiners enter automatically; the headless dedicated server offers a "hall" where
## players create rooms or join one by code.

signal lobby_changed
signal hall_changed
signal chat_message(nick: String, text: String, kind: String)
signal game_starting(info: Dictionary)
signal game_ended
signal player_left(slot: String)
signal disconnected(reason: String)
signal desync(frame: int)
signal servers_found(list: Array)

const DEFAULT_PORT := 1511
const DISCOVERY_PORT := 1512
const MAX_PLAYERS := 5
const MAX_ROOMS := 50
const PROTOCOL := 2
const INPUT_DELAY := 3
const HASH_EVERY := 100
const PROBE := "BB/1 SERVER PROBE"
const CODE_ALPHABET := "ABCDEFGHJKLMNPQRSTUVWXYZ"

enum Role { NONE, SERVER, CLIENT }

# --- state visible to the UI (mirrors the server for this peer) ---
var role := Role.NONE
var headless := false
var server_name := "Boreal Bounce"
var local_nick := ""
## Code of the room this peer is in ("" = hall of a dedicated server, or not connected).
var room_code := ""
## Players of the current room: peer id -> {"nick", "ready", "wins"}.
var players := {}
## Peer id allowed to start rounds and kick in the current room.
var room_host := 0
## Hall: [{"code", "players", "in_game"}] on a dedicated server.
var rooms: Array = []
var in_game := false
var game_info := {}
var lockstep: Lockstep
var chain_reaction := false
var connected := false
## True when connected to a dedicated relay (hall with rooms) rather than a player's game.
var dedicated := false

# --- server side ---
var _peer: ENetMultiplayerPeer
var _rooms := {}      # code -> Room
var _room_of := {}    # peer id -> code
var _nicks := {}      # peer id -> nick (for peers in the hall too)
var _talk_times := {}
var _discovery: PacketPeerUDP
var _probe: PacketPeerUDP
var _probe_deadline := 0.0
var _found := []


class Room:
	var code := ""
	var players := {}
	var in_game := false
	var relay: Lockstep
	var hashes := {}
	var game_info := {}

	func host_id() -> int:
		var ids := players.keys()
		ids.sort()
		return ids[0] if not ids.is_empty() else 0

	func summary() -> Dictionary:
		return {"code": code, "players": players.size(), "in_game": in_game}


func _ready() -> void:
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	multiplayer.connected_to_server.connect(_on_connected)
	multiplayer.connection_failed.connect(func(): _fail(tr("Connection failed")))
	multiplayer.server_disconnected.connect(func(): _fail(tr("Server closed the connection")))


func _process(_delta: float) -> void:
	_poll_discovery()


# --- connection -----------------------------------------------------------------------------

func is_server() -> bool:
	return role == Role.SERVER


func my_id() -> int:
	return multiplayer.get_unique_id()


func host_id() -> int:
	return room_host


func is_host_player() -> bool:
	return connected and room_code != "" and my_id() == room_host


func in_room() -> bool:
	return connected and room_code != ""


## Hosts a game (peer-hosted: one room, the host inside) or a dedicated hall (headless).
func host(port := DEFAULT_PORT, nick := "", headless_ := false) -> Error:
	leave()
	_peer = ENetMultiplayerPeer.new()
	var err := _peer.create_server(port, (MAX_PLAYERS if not headless_ else MAX_ROOMS * MAX_PLAYERS) + 1)
	if err != OK:
		return err
	multiplayer.multiplayer_peer = _peer
	role = Role.SERVER
	headless = headless_
	connected = true
	_rooms = {}
	_room_of = {}
	_nicks = {}
	if not headless:
		local_nick = _sanitize_nick(nick)
		_nicks[1] = local_nick
		var room := _new_room()
		_put_in_room(1, room)
	_start_discovery_responder()
	lobby_changed.emit()
	return OK


func join(address: String, port := DEFAULT_PORT, nick := "") -> Error:
	leave()
	_peer = ENetMultiplayerPeer.new()
	var err := _peer.create_client(address, port)
	if err != OK:
		return err
	multiplayer.multiplayer_peer = _peer
	role = Role.CLIENT
	headless = false
	local_nick = _sanitize_nick(nick)
	return OK


func leave() -> void:
	if _discovery != null:
		_discovery.close()
		_discovery = null
	if _peer != null:
		_peer.close()
		_peer = null
	multiplayer.multiplayer_peer = OfflineMultiplayerPeer.new()
	role = Role.NONE
	connected = false
	dedicated = false
	in_game = false
	room_code = ""
	room_host = 0
	players = {}
	rooms = []
	game_info = {}
	lockstep = null
	_rooms = {}
	_room_of = {}
	_nicks = {}


func _fail(reason: String) -> void:
	leave()
	disconnected.emit(reason)


func _on_connected() -> void:
	connected = true
	_register.rpc_id(1, local_nick, PROTOCOL)


func _on_peer_connected(_id: int) -> void:
	pass  # the client registers itself; refusals happen there


func _on_peer_disconnected(id: int) -> void:
	if not is_server():
		return
	var nick: String = _nicks.get(id, "?")
	_nicks.erase(id)
	var room := _room_for(id)
	if room != null:
		_remove_from_room(id, room, "%s left" % nick)
	_send_hall()


static func _sanitize_nick(nick: String) -> String:
	var n := nick.strip_edges()
	if n == "":
		n = OS.get_environment("USER")
	if n == "":
		n = "player"
	return n.left(12)


# --- server: rooms -------------------------------------------------------------------------------

func _new_room() -> Room:
	var room := Room.new()
	var code := ""
	while code == "" or _rooms.has(code):
		code = ""
		for i in 4:
			code += CODE_ALPHABET[randi() % CODE_ALPHABET.length()]
	room.code = code
	_rooms[code] = room
	return room


func _room_for(id: int) -> Room:
	return _rooms.get(_room_of.get(id, ""), null)


func _put_in_room(id: int, room: Room) -> void:
	room.players[id] = {"nick": _nicks.get(id, "?"), "ready": false, "wins": 0}
	_room_of[id] = room.code
	_send_room(room)
	_room_chat(room, "", "%s joined" % _nicks.get(id, "?"), "server")
	_send_hall()


func _remove_from_room(id: int, room: Room, notice: String) -> void:
	room.players.erase(id)
	_room_of.erase(id)
	if notice != "":
		_room_chat(room, "", notice, "server")
	if room.in_game and room.relay != null:
		var slot := slot_of(id)
		room.relay.player_left(slot)
		for member in room.players:
			_player_left_rpc.rpc_id(member, slot)
		for done in room.relay.flush_left():
			for member in room.players:
				_frame.rpc_id(member, done[0], done[1])
	if room.players.is_empty() and headless:
		_rooms.erase(room.code)
	else:
		_send_room(room)
	_send_hall()


func _send_room(room: Room) -> void:
	for member in room.players:
		_room_state.rpc_id(member, room.code, room.players, room.host_id(), server_name)


func _send_hall() -> void:
	if not headless:
		return
	var list := []
	for code in _rooms:
		list.append(_rooms[code].summary())
	for id in _nicks:
		if not _room_of.has(id):
			_hall_state.rpc_id(id, list, server_name)


# --- registration and room commands ---------------------------------------------------------------

@rpc("any_peer", "reliable")
func _register(nick: String, protocol: int) -> void:
	if not is_server():
		return
	var id := multiplayer.get_remote_sender_id()
	if protocol != PROTOCOL:
		_refused.rpc_id(id, "Incompatible version")
		return
	var n := _sanitize_nick(nick)
	while _nick_taken(n):
		n = n.left(11) + "_"
	_nicks[id] = n
	if headless:
		_send_hall()
		return
	var room: Room = _rooms.values()[0]
	if room.players.size() >= MAX_PLAYERS or room.in_game:
		_refused.rpc_id(id, "Game is full" if not room.in_game else "Game already started")
		return
	_put_in_room(id, room)


@rpc("authority", "reliable")
func _refused(reason: String) -> void:
	_fail(reason)


func _nick_taken(n: String) -> bool:
	for id in _nicks:
		if _nicks[id].to_lower() == n.to_lower():
			return true
	return false


func headless_server() -> bool:
	return dedicated or headless


@rpc("authority", "call_local", "reliable")
func _hall_state(list: Array, name: String) -> void:
	dedicated = true
	rooms = list
	server_name = name
	room_code = ""
	players = {}
	room_host = 0
	hall_changed.emit()
	lobby_changed.emit()


@rpc("authority", "call_local", "reliable")
func _room_state(code: String, players_: Dictionary, host: int, name: String) -> void:
	room_code = code
	players = players_
	room_host = host
	server_name = name
	lobby_changed.emit()


func create_room() -> void:
	_create_room.rpc_id(1)


@rpc("any_peer", "reliable")
func _create_room() -> void:
	if not is_server() or not headless:
		return
	var id := multiplayer.get_remote_sender_id()
	if _room_of.has(id) or _rooms.size() >= MAX_ROOMS:
		return
	_put_in_room(id, _new_room())


func join_room(code: String) -> void:
	_join_room.rpc_id(1, code.strip_edges().to_upper())


@rpc("any_peer", "reliable")
func _join_room(code: String) -> void:
	if not is_server() or not headless:
		return
	var id := multiplayer.get_remote_sender_id()
	if _room_of.has(id):
		return
	var room: Room = _rooms.get(code, null)
	if room == null:
		_notice.rpc_id(id, "No room with code %s" % code)
	elif room.players.size() >= MAX_PLAYERS:
		_notice.rpc_id(id, "Room %s is full" % code)
	elif room.in_game:
		_notice.rpc_id(id, "Room %s is playing; wait for the round to end" % code)
	else:
		_put_in_room(id, room)


func leave_room() -> void:
	_leave_room.rpc_id(1)


@rpc("any_peer", "call_local", "reliable")
func _leave_room() -> void:
	if not is_server() or not headless:
		return
	var id := multiplayer.get_remote_sender_id()
	if id == 0:
		id = 1
	var room := _room_for(id)
	if room != null:
		_remove_from_room(id, room, "%s left" % _nicks.get(id, "?"))
		_send_hall()


@rpc("authority", "reliable")
func _notice(text: String) -> void:
	chat_message.emit("", text, "server")


func nick_of(id: int) -> String:
	return players.get(id, {}).get("nick", "?")


func slot_of(id: int) -> String:
	return "n%d" % id


func id_of_slot(slot: String) -> int:
	return int(slot.trim_prefix("n"))


# --- chat, ready, nick, kick (scoped to the sender's room) -------------------------------------

func _sender() -> int:
	var id := multiplayer.get_remote_sender_id()
	return 1 if id == 0 else id


func send_chat(text: String) -> void:
	if text.begins_with("/me "):
		_chat.rpc_id(1, text.substr(4), "me")
	else:
		_chat.rpc_id(1, text, "chat")


@rpc("any_peer", "call_local", "reliable")
func _chat(text: String, kind: String) -> void:
	if not is_server():
		return
	var id := _sender()
	var room := _room_for(id)
	if room == null:
		return
	var now := Time.get_ticks_msec()
	var recent: Array = _talk_times.get(id, [])
	recent = recent.filter(func(t): return now - t < 3000)
	if recent.size() >= 5:
		return
	recent.append(now)
	_talk_times[id] = recent
	_room_chat(room, _nicks.get(id, "?"), text.left(200), kind)


func _room_chat(room: Room, nick: String, text: String, kind: String) -> void:
	for member in room.players:
		_chat_line.rpc_id(member, nick, text, kind)


@rpc("authority", "call_local", "reliable")
func _chat_line(nick: String, text: String, kind: String) -> void:
	chat_message.emit(nick, text, kind)


func set_ready(ready: bool) -> void:
	_set_ready.rpc_id(1, ready)


@rpc("any_peer", "call_local", "reliable")
func _set_ready(ready: bool) -> void:
	if not is_server():
		return
	var id := _sender()
	var room := _room_for(id)
	if room != null and room.players.has(id):
		room.players[id]["ready"] = ready
		_send_room(room)


func change_nick(nick: String) -> void:
	_change_nick.rpc_id(1, nick)


@rpc("any_peer", "call_local", "reliable")
func _change_nick(nick: String) -> void:
	if not is_server():
		return
	var id := _sender()
	var n := _sanitize_nick(nick)
	if _nick_taken(n) or not _nicks.has(id):
		return
	var old: String = _nicks[id]
	_nicks[id] = n
	var room := _room_for(id)
	if room != null:
		room.players[id]["nick"] = n
		_room_chat(room, "", "%s is now known as %s" % [old, n], "server")
		_send_room(room)


func kick(nick: String) -> void:
	_kick.rpc_id(1, nick)


@rpc("any_peer", "call_local", "reliable")
func _kick(nick: String) -> void:
	if not is_server():
		return
	var sender := _sender()
	var room := _room_for(sender)
	if room == null or sender != room.host_id():
		return
	for id in room.players.keys():
		if room.players[id]["nick"].to_lower() == nick.to_lower() and id != sender:
			_remove_from_room(id, room, "%s was kicked" % room.players[id]["nick"])
			if headless:
				_notice.rpc_id(id, "Kicked by the host")
				_send_hall()
			else:
				_refused.rpc_id(id, "Kicked by the host")
				_peer.disconnect_peer(id)
			return


func all_ready() -> bool:
	for id in players:
		if id != room_host and not players[id]["ready"]:
			return false
	return players.size() >= 2


## Room host: starts a round. Requires at least two players, everyone else ready.
func request_start() -> void:
	_request_start.rpc_id(1)


@rpc("any_peer", "call_local", "reliable")
func _request_start() -> void:
	if not is_server():
		return
	var sender := _sender()
	var room := _room_for(sender)
	if room == null or room.in_game or sender != room.host_id():
		return
	var ids := room.players.keys()
	ids.sort()
	if ids.size() < 2:
		_room_chat(room, "", "At least two players are needed", "server")
		return
	for id in ids:
		if id != room.host_id() and not room.players[id]["ready"]:
			_room_chat(room, "", "Everyone must be ready first (/ready)", "server")
			return
	var slots: Array[String] = []
	var nicks := {}
	for id in ids:
		slots.append(slot_of(id))
		nicks[slot_of(id)] = room.players[id]["nick"]
	var rules := Rules.versus()
	rules.chain_reaction = chain_reaction
	room.game_info = {"seed": Rng.fresh_seed() & 0x7fffffff, "slots": slots, "nicks": nicks, "rules": rules.to_dict()}
	room.relay = Lockstep.new(slots, INPUT_DELAY)
	room.hashes = {}
	room.in_game = true
	for member in room.players:
		_start_game.rpc_id(member, room.game_info)
	_send_hall()


@rpc("authority", "call_local", "reliable")
func _start_game(info: Dictionary) -> void:
	game_info = info
	var slots: Array[String] = []
	for s in info["slots"]:
		slots.append(s)
	lockstep = Lockstep.new(slots, INPUT_DELAY)
	in_game = true
	game_starting.emit(info)


## Any peer reports the (deterministic) outcome; the server ends the round for its room.
func report_round_over(winner_slot: String) -> void:
	_round_over.rpc_id(1, winner_slot)


@rpc("any_peer", "call_local", "reliable")
func _round_over(winner_slot: String) -> void:
	if not is_server():
		return
	var room := _room_for(_sender())
	if room != null and room.in_game:
		_end_room_game(room, winner_slot)


func _end_room_game(room: Room, winner_slot: String) -> void:
	if winner_slot != "":
		var id := id_of_slot(winner_slot)
		if room.players.has(id):
			room.players[id]["wins"] += 1
	room.in_game = false
	room.relay = null
	for id in room.players:
		room.players[id]["ready"] = false
	for member in room.players:
		_end_game.rpc_id(member)
	_send_room(room)
	_send_hall()


@rpc("authority", "call_local", "reliable")
func _end_game() -> void:
	in_game = false
	lockstep = null
	game_ended.emit()


# --- lockstep relay --------------------------------------------------------------------------

func send_input(frame: int, inputs: Dictionary) -> void:
	_input_frame.rpc_id(1, frame, inputs)


@rpc("any_peer", "call_local", "reliable")
func _input_frame(frame: int, inputs: Dictionary) -> void:
	if not is_server():
		return
	var id := _sender()
	var room := _room_for(id)
	if room == null or room.relay == null:
		return
	var merged := room.relay.collect(frame, slot_of(id), inputs)
	if not merged.is_empty():
		for member in room.players:
			_frame.rpc_id(member, frame, merged)


@rpc("authority", "call_local", "reliable")
func _frame(frame: int, inputs: Dictionary) -> void:
	if lockstep != null:
		lockstep.receive_frame(frame, inputs)


func report_hash(frame: int, hash_: String) -> void:
	_hash.rpc_id(1, frame, hash_)


@rpc("any_peer", "call_local", "reliable")
func _hash(frame: int, hash_: String) -> void:
	if not is_server():
		return
	var room := _room_for(_sender())
	if room == null:
		return
	if not room.hashes.has(frame):
		room.hashes[frame] = hash_
	elif room.hashes[frame] != hash_:
		for member in room.players:
			_desync.rpc_id(member, frame)
		await get_tree().create_timer(3.0).timeout
		if room.in_game:
			_end_room_game(room, "")


@rpc("authority", "call_local", "reliable")
func _desync(frame: int) -> void:
	desync.emit(frame)


@rpc("authority", "call_local", "reliable")
func _player_left_rpc(slot: String) -> void:
	player_left.emit(slot)


# --- LAN discovery ----------------------------------------------------------------------------

func _start_discovery_responder() -> void:
	_discovery = PacketPeerUDP.new()
	if _discovery.bind(DISCOVERY_PORT) != OK:
		_discovery = null


## Broadcasts a probe; answers arrive through [signal servers_found] after two seconds.
func discover_lan() -> void:
	_found = []
	_probe = PacketPeerUDP.new()
	_probe.set_broadcast_enabled(true)
	_probe.bind(0)
	_probe.set_dest_address("255.255.255.255", DISCOVERY_PORT)
	_probe.put_packet(PROBE.to_utf8_buffer())
	_probe_deadline = Time.get_ticks_msec() + 2000.0


func _poll_discovery() -> void:
	if _discovery != null:
		while _discovery.get_available_packet_count() > 0:
			var data := _discovery.get_packet().get_string_from_utf8()
			if data == PROBE:
				var reply := "BB/1 SERVER HERE AT PORT %d %s %d" % [_peer.get_local_port() if _peer != null else DEFAULT_PORT, server_name.replace(" ", "_"), _nicks.size()]
				_discovery.set_dest_address(_discovery.get_packet_ip(), _discovery.get_packet_port())
				_discovery.put_packet(reply.to_utf8_buffer())
	if _probe != null:
		while _probe.get_available_packet_count() > 0:
			var data := _probe.get_packet().get_string_from_utf8()
			var parts := data.split(" ")
			if parts.size() >= 7 and parts[0] == "BB/1":
				_found.append({"host": _probe.get_packet_ip(), "port": int(parts[5]), "name": parts[6].replace("_", " "), "players": int(parts[7]) if parts.size() > 7 else 0})
		if Time.get_ticks_msec() > _probe_deadline:
			_probe.close()
			_probe = null
			servers_found.emit(_found)
