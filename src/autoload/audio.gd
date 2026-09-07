extends Node
## Music and sound-effect playback (autoload "Audio").
##
## Sounds are looked up by their original file name without extension, e.g.
## Audio.play_sfx("launch"). Music loops. Two audio buses, "Music" and "SFX", are created at
## startup so they can be muted independently, as F11/F12 did in the original.

const SND_DIR := "res://assets/snd/"
const SFX_VOICES := 8

var _streams := {}
var _sfx_players: Array[AudioStreamPlayer] = []
var _music_player: AudioStreamPlayer
var _current_music := ""


func _ready() -> void:
	_ensure_bus("Music")
	_ensure_bus("SFX")
	for i in SFX_VOICES:
		var p := AudioStreamPlayer.new()
		p.bus = "SFX"
		add_child(p)
		_sfx_players.append(p)
	_music_player = AudioStreamPlayer.new()
	_music_player.bus = "Music"
	add_child(_music_player)
	apply_settings()


func _ensure_bus(bus_name: String) -> void:
	if AudioServer.get_bus_index(bus_name) == -1:
		AudioServer.add_bus()
		AudioServer.set_bus_name(AudioServer.get_bus_count() - 1, bus_name)


func apply_settings() -> void:
	var db := linear_to_db(Settings.volume) if Settings.volume > 0.0 else -80.0
	AudioServer.set_bus_volume_db(AudioServer.get_bus_index("Master"), db)
	AudioServer.set_bus_mute(AudioServer.get_bus_index("Music"), not Settings.music_enabled)
	AudioServer.set_bus_mute(AudioServer.get_bus_index("SFX"), not Settings.sfx_enabled)


func _stream(sound_name: String) -> AudioStream:
	if not _streams.has(sound_name):
		var path := SND_DIR + sound_name + ".ogg"
		_streams[sound_name] = load(path) if ResourceLoader.exists(path) else null
		if _streams[sound_name] == null:
			push_warning("Audio: missing sound " + path)
	return _streams[sound_name]


func play_sfx(sound_name: String) -> void:
	var stream := _stream(sound_name)
	if stream == null:
		return
	var player: AudioStreamPlayer = _sfx_players[0]
	for p in _sfx_players:
		if not p.playing:
			player = p
			break
	player.stream = stream
	player.play()


func play_music(sound_name: String) -> void:
	if _current_music == sound_name and _music_player.playing:
		return
	var stream := _stream(sound_name)
	if stream == null:
		return
	if stream is AudioStreamOggVorbis:
		stream.loop = true
	_music_player.stream = stream
	_music_player.play()
	_current_music = sound_name


func set_music_paused(paused: bool) -> void:
	_music_player.stream_paused = paused


func stop_music() -> void:
	_music_player.stop()
	_current_music = ""


func toggle_music() -> void:
	Settings.music_enabled = not Settings.music_enabled
	apply_settings()
	Settings.save_settings()


func toggle_sfx() -> void:
	Settings.sfx_enabled = not Settings.sfx_enabled
	apply_settings()
	Settings.save_settings()


func change_volume(delta: float) -> void:
	Settings.volume = clampf(Settings.volume + delta, 0.0, 1.0)
	apply_settings()
	Settings.save_settings()
