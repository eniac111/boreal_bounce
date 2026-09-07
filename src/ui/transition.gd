class_name Transition
extends CanvasLayer
## Plays one of the original screen transitions: the previous screen (captured as an image)
## is drawn over the new scene and dissolved over [member frames] physics frames.
## Kinds: store, bars, squares, circle, plasma, noise, or "random"; "blacken" is the black
## curtain closing from top and bottom over 35 frames that ends the attract-mode demo.

const KINDS := ["store", "bars", "squares", "circle", "plasma", "noise"]
const MASK_DIR := "res://assets/gfx/transitions/"

var frames := 40
var _rect: TextureRect
var _material: ShaderMaterial
var _curtain: Control
var _step := 0


static func start(tree: SceneTree, old_image: Image, kind := "random") -> Transition:
	var t := Transition.new()
	t.layer = 100
	t._build(old_image, kind)
	tree.root.add_child(t)
	return t


func _build(old_image: Image, kind: String) -> void:
	if kind == "blacken":
		_rect = TextureRect.new()
		_rect.texture = ImageTexture.create_from_image(old_image)
		_rect.set_anchors_preset(Control.PRESET_FULL_RECT)
		_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
		add_child(_rect)
		_curtain = Curtain.new()
		_curtain.set_anchors_preset(Control.PRESET_FULL_RECT)
		_curtain.mouse_filter = Control.MOUSE_FILTER_IGNORE
		add_child(_curtain)
		frames = 35
		return
	if kind == "random":
		kind = KINDS[randi() % KINDS.size()]
	_material = ShaderMaterial.new()
	_material.shader = load("res://src/shaders/reveal.gdshader")
	var mask_name := kind
	var reverse := false
	var flip_x := false
	var flip_y := false
	match kind:
		"store":
			mask_name = "store_h" if randi() % 2 == 0 else "store_v"
			frames = 31 if mask_name == "store_h" else 36
		"squares":
			frames = 34
		"circle":
			reverse = randi() % 2 == 0  # centre first or edges first
		"plasma":
			flip_x = randi() % 2 == 0
			flip_y = randi() % 2 == 0
	_material.set_shader_parameter("mask_tex", load(MASK_DIR + mask_name + ".png"))
	_material.set_shader_parameter("reverse", reverse)
	_material.set_shader_parameter("flip_x", flip_x)
	_material.set_shader_parameter("flip_y", flip_y)
	_material.set_shader_parameter("progress", 0.0)
	_rect = TextureRect.new()
	_rect.texture = ImageTexture.create_from_image(old_image)
	_rect.material = _material
	_rect.stretch_mode = TextureRect.STRETCH_SCALE
	_rect.set_anchors_preset(Control.PRESET_FULL_RECT)
	_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_rect)


func _physics_process(_delta: float) -> void:
	_step += 1
	if _curtain != null:
		_curtain.step = _step
		_curtain.queue_redraw()
	else:
		_material.set_shader_parameter("progress", float(_step) / frames)
	if _step > frames:
		queue_free()


## blacken (CStuff.xs 1320-1346): at step k the rows [0, k*480/70) from the top and the mirror
## rows from the bottom turn black, and the next 8 bands on each side are darkened to 3/4.
class Curtain extends Control:
	var step := 0

	func _draw() -> void:
		var band := 480.0 / 70.0
		var k := mini(step, 35)
		var edge := k * band
		draw_rect(Rect2(0, 0, 640, edge), Color.BLACK)
		draw_rect(Rect2(0, 480 - edge, 640, edge), Color.BLACK)
		var dark := Color(0, 0, 0, 0.75)
		draw_rect(Rect2(0, edge, 640, band * 8), dark)
		draw_rect(Rect2(0, 480 - edge - band * 8, 640, band * 8), dark)
