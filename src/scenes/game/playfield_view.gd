class_name PlayfieldView
extends Node2D
## Renders one Playfield at the coordinates of the original game. Call [method sync] after
## every simulation step. Sprites are positioned by their top-left corner like SDL blits, so
## the numbers from the original carry over unchanged.

const BUBBLE_SIZE := Layouts.BUBBLE_SIZE
const ROW_SIZE := Layouts.ROW_SIZE

## Display slot: decides the art (penguin sheets, hurry sign, win panel) and mini size.
var slot := "p1"
## Screen layout (where things are drawn); the simulation may use a different geometry.
var layout: Dictionary
var mini := false
var colourblind := false
var field: Playfield
var rules: Rules
var last_inputs := {}
## Simulation pixels to screen pixels: remote boards of network games are simulated at full
## size and drawn at half size in the corners.
var view_scale := 1.0
var _sprite_scale := Vector2.ONE

var _bubbles: Node2D
var _cell_sprites := {}
var _shooter: Sprite2D
var _penguin: Penguin
var _next: Sprite2D
var _current: Sprite2D
var _flying: Sprite2D
var _stick: Sprite2D
var _moving: Node2D
var _moving_pool: Array[Sprite2D] = []
var _prelight: Node2D
var _prelight_pool: Array[Sprite2D] = []
var _compressor: Node2D
var _dots: Node2D
var _hurry: Sprite2D
var _malus: Node2D
var _malus_pool: Array[Sprite2D] = []
var _grid_signature := ""


func setup(slot_: String, layout_: Dictionary, field_: Playfield, rules_: Rules, colourblind_ := false) -> void:
	slot = slot_
	layout = layout_
	field = field_
	rules = rules_
	mini = slot.begins_with("rp")
	colourblind = colourblind_
	var screen_bubble := (BUBBLE_SIZE / 2.0) if mini else float(BUBBLE_SIZE)
	view_scale = screen_bubble / field.bubble_size
	_sprite_scale = Vector2.ONE * (field.bubble_size * view_scale / screen_bubble)
	_compressor = Node2D.new()
	_compressor.name = "Compressor"
	add_child(_compressor)
	_bubbles = Node2D.new()
	_bubbles.name = "Bubbles"
	add_child(_bubbles)
	_prelight = Node2D.new()
	_prelight.name = "Prelight"
	add_child(_prelight)
	_stick = Sprite2D.new()
	_stick.name = "StickEffect"
	_stick.centered = false
	_stick.scale = _sprite_scale
	_stick.visible = false
	add_child(_stick)
	_shooter = Sprite2D.new()
	_shooter.name = "Shooter"
	_shooter.texture = Art.tex("res://assets/gfx/shooter-mini.png" if mini else "res://assets/gfx/shooter.png")
	var half := _shooter.texture.get_width() / 2.0
	_shooter.position = Vector2(layout["canon"]["x"] + half, layout["canon"]["y"] + half)
	add_child(_shooter)
	_current = _make_sprite("Current")
	_next = _make_sprite("Next")
	_next.position = Vector2(layout["left_limit"] + layout["next_bubble"]["x"], layout["next_bubble"]["y"])
	_flying = _make_sprite("Flying")
	_moving = Node2D.new()
	_moving.name = "Moving"
	add_child(_moving)
	_dots = Node2D.new()
	_dots.name = "Progress"
	add_child(_dots)
	_hurry = Sprite2D.new()
	_hurry.name = "Hurry"
	_hurry.centered = false
	_hurry.texture = Art.tex("res://assets/gfx/hurry_%s.png" % slot)
	_hurry.position = Vector2(layout["left_limit"] + layout["hurry"]["x"], layout["hurry"]["y"])
	_hurry.visible = false
	add_child(_hurry)
	_malus = Node2D.new()
	_malus.name = "Malus"
	add_child(_malus)
	_penguin = Penguin.new()
	_penguin.name = "Penguin"
	_penguin.setup(slot)
	# the original offsets the penguin by the playfield's left edge like the other elements
	# (bin/frozen-bubble:1104), which puts it at the igloo entrance rather than beside it
	_penguin.position = Vector2(layout["left_limit"] + layout["pinguin"]["x"], layout["pinguin"]["y"])
	add_child(_penguin)
	_build_dots()
	sync()


func _make_sprite(sprite_name: String) -> Sprite2D:
	var s := Sprite2D.new()
	s.name = sprite_name
	s.centered = false
	s.scale = _sprite_scale
	add_child(s)
	return s


## Simulation pixel position (top-left of a bubble) to screen position.
func to_screen(sim_pos: Vector2) -> Vector2:
	return Vector2(layout["left_limit"], layout["top_limit"]) + (sim_pos - Vector2(field.left_limit, field.top_limit)) * view_scale


func cell_screen(cx: int, cy: int) -> Vector2:
	return to_screen(field.cell_to_pixel(cx, cy))


func _tex(colour: int) -> Texture2D:
	return BubbleArt.bubble(colour, colourblind, mini)


## Refreshes every sprite from the field's state.
func sync() -> void:
	var p := field
	_shooter.rotation = PI / 2 - p.angle
	_current.visible = p.launcher_colour >= 0 and p.state != Playfield.State.LOST
	if _current.visible:
		_current.texture = _tex(p.launcher_colour)
		_current.position = to_screen(p.launch_pos())
	_next.visible = p.next_colour >= 0 and p.state != Playfield.State.LOST
	if _next.visible:
		_next.texture = _tex(p.next_colour)
	var was_flying := _flying.visible
	_flying.visible = not p.flying.is_empty()
	if _flying.visible:
		_flying.texture = _tex(p.flying["colour"])
		_flying.position = to_screen(Vector2(p.flying["x"], p.flying["y"]))
		if not was_flying:
			_flying.reset_physics_interpolation()
	_sync_grid()
	_sync_moving()
	_sync_stick()
	_sync_prelight()
	_sync_compressor()
	_sync_dots()
	_hurry.visible = p.hurry_shown
	_sync_malus()
	_penguin.tick(last_inputs.get("left", false), last_inputs.get("right", false), p.hadfire, p.is_ingame())
	if p.state == Playfield.State.WON and _penguin.state != "win":
		_penguin.set_state("win")
	if p.state == Playfield.State.LOST and not _penguin.state.begins_with("lose"):
		_penguin.set_state("lose_to")


func _sync_grid() -> void:
	var sig := field.grid.to_debug_string() + str(field.frozen.size())
	if sig == _grid_signature:
		return
	_grid_signature = sig
	for c in _bubbles.get_children():
		c.queue_free()
	for cy in field.grid.rows.size():
		var row := field.grid.rows[cy]
		for cx in row.size():
			if row[cx] == Playfield.EMPTY:
				continue
			var s := Sprite2D.new()
			s.centered = false
			s.scale = _sprite_scale
			var frozen := field.frozen.has(Vector2i(cx, cy))
			s.texture = BubbleArt.lose(mini) if frozen or row[cx] == Playfield.STONE else _tex(row[cx])
			s.position = cell_screen(cx, cy)
			if frozen or row[cx] == Playfield.STONE:
				s.position -= Vector2.ONE
			_bubbles.add_child(s)


func _sync_moving() -> void:
	var items: Array[Dictionary] = []
	items.append_array(field.falling)
	items.append_array(field.exploding)
	items.append_array(field.malus_flying)
	while _moving_pool.size() < items.size():
		var s := Sprite2D.new()
		s.centered = false
		s.scale = _sprite_scale
		_moving.add_child(s)
		_moving_pool.append(s)
	for i in _moving_pool.size():
		var s := _moving_pool[i]
		if i < items.size():
			s.visible = true
			s.texture = _tex(items[i]["colour"])
			s.position = to_screen(Vector2(items[i]["x"], items[i]["y"]))
			if not s.has_meta("item") or not is_same(s.get_meta("item"), items[i]):
				s.set_meta("item", items[i])
				s.reset_physics_interpolation()
		else:
			s.visible = false


## Pending malus drawn as bananas (1 each) and tomatoes (7 each) stacked upwards from the
## layout's malus point (update_malus, bin/frozen-bubble:1161).
func _sync_malus() -> void:
	if not layout.has("malus"):
		return
	var items: Array[Texture2D] = []
	var n := field.malus_count()
	while n > 0:
		if n >= 7:
			items.append(BubbleArt._tex("res://assets/gfx/tomate.png"))
			n -= 7
		else:
			items.append(BubbleArt._tex("res://assets/gfx/banane.png"))
			n -= 1
	while _malus_pool.size() < items.size():
		var s := Sprite2D.new()
		s.centered = false
		_malus.add_child(s)
		_malus_pool.append(s)
	var y_shift := 0.0
	for i in _malus_pool.size():
		var s := _malus_pool[i]
		s.visible = i < items.size()
		if s.visible:
			s.texture = items[i]
			s.position = Vector2(layout["malus"]["x"] - s.texture.get_width() / 2.0, layout["malus"]["y"] - y_shift - s.texture.get_height())
			y_shift += s.texture.get_height() - 1


func _sync_stick() -> void:
	if field.sticking.is_empty():
		_stick.visible = false
		return
	var step: int = field.sticking["step"]
	if step >= Rules.STICK_EFFECT_FRAMES:
		_stick.visible = false
		return
	_stick.visible = true
	if mini:
		_stick.texture = BubbleArt.stick_effect_mini(step)
	else:
		_stick.texture = BubbleArt.stick_effect_frames().get_frame_texture("default", step)
	_stick.position = cell_screen(field.sticking["cx"], field.sticking["cy"])


func _sync_prelight() -> void:
	var cells: Array[Vector2i] = []
	if field.newroot_prelight > 0 and field.newroot_prelight_step <= 8:
		var col: int = field.newroot_prelight_step
		for cy in field.grid.rows.size():
			if col < field.grid.rows[cy].size() and field.grid.rows[cy][col] >= 0:
				cells.append(Vector2i(col, cy))
	while _prelight_pool.size() < cells.size():
		var s := Sprite2D.new()
		s.centered = false
		s.scale = _sprite_scale
		s.texture = BubbleArt.prelight(mini)
		_prelight.add_child(s)
		_prelight_pool.append(s)
	for i in _prelight_pool.size():
		var s := _prelight_pool[i]
		s.visible = i < cells.size()
		if s.visible:
			s.position = cell_screen(cells[i].x, cells[i].y)


## 1p compressor: head with its bottom edge on the ceiling line, shaft tiled upwards
## (print_compressor, bin/frozen-bubble:1238).
func _sync_compressor() -> void:
	if not rules.compressor_lowers_ceiling or not layout.has("compressor_xpos_abs"):
		_compressor.visible = false
		return
	var xpos: float = layout["compressor_xpos_abs"]
	var y := to_screen(Vector2(0, field.ceiling_y())).y
	var key := "%d" % int(y)
	if _compressor.get_meta("key", "") == key:
		return
	_compressor.set_meta("key", key)
	_compressor.visible = true
	for c in _compressor.get_children():
		c.queue_free()
	var main := Sprite2D.new()
	main.centered = false
	main.texture = Art.tex("res://assets/gfx/compressor_main.png")
	main.position = Vector2(xpos - 126, y - 51)
	_compressor.add_child(main)
	var ext_tex: Texture2D = Art.tex("res://assets/gfx/compressor_ext.png")
	var yy := y - 48
	while yy > 0:
		var ext := Sprite2D.new()
		ext.centered = false
		ext.texture = ext_tex
		ext.position = Vector2(xpos - 94, yy - 28)
		_compressor.add_child(ext)
		yy -= 28


func _build_dots() -> void:
	for c in _dots.get_children():
		c.queue_free()
	for i in rules.time_appears_new_root + 1:
		var s := Sprite2D.new()
		s.centered = false
		s.position = Vector2(layout["progress"]["x"], layout["progress"]["y"] + i * 8)
		_dots.add_child(s)


func _sync_dots() -> void:
	var red: Texture2D = BubbleArt._tex("res://assets/gfx/dot_red.png")
	var green: Texture2D = BubbleArt._tex("res://assets/gfx/dot_green.png")
	var i := 0
	for s in _dots.get_children():
		s.texture = red if i == field.newroot else green
		i += 1
