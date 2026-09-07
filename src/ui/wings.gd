class_name Wings
extends CanvasLayer
## Background outside the 640x480 play area on screens that are not 4:3: procedural ice
## tinted from the edges of the current scene's background. Created by Screens.

var _rect: ColorRect
var _material: ShaderMaterial


func _init() -> void:
	layer = -10
	_material = ShaderMaterial.new()
	_material.shader = load("res://src/shaders/wings.gdshader")
	_rect = ColorRect.new()
	_rect.material = _material
	_rect.set_anchors_preset(Control.PRESET_FULL_RECT)
	_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_rect)


func set_geometry(viewport_size: Vector2, content_pos: Vector2, content_size: Vector2) -> void:
	_material.set_shader_parameter("viewport_size", viewport_size)
	_material.set_shader_parameter("content_rect_pos", content_pos)
	_material.set_shader_parameter("content_rect_size", content_size)


## Tints the wings from the outer columns of a background texture.
func tint_from(texture: Texture2D) -> void:
	if texture == null:
		return
	var img := texture.get_image()
	if img == null:
		return
	if img.is_compressed():
		img.decompress()
	var w := img.get_width()
	var h := img.get_height()
	_material.set_shader_parameter("tint_left", _average(img, 0, mini(6, w), h))
	_material.set_shader_parameter("tint_right", _average(img, maxi(w - 6, 0), w, h))


static func _average(img: Image, x0: int, x1: int, h: int) -> Color:
	var sum := Color(0, 0, 0)
	var n := 0
	var step := maxi(1, h / 60)
	for y in range(0, h, step):
		for x in range(x0, x1):
			sum += img.get_pixel(x, y)
			n += 1
	if n == 0:
		return Color(0.8, 0.85, 0.95)
	var c := sum / n
	# lift very dark edges a little so the frost stays readable
	return Color(maxf(c.r, 0.15), maxf(c.g, 0.15), maxf(c.b, 0.2))
