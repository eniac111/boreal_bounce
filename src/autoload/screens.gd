extends Node
## Screen switching (autoload "Screens"). Every screen is a scene under src/scenes/; this keeps
## the paths in one place and lets the debug helper add arguments.

const INTRO := "res://src/scenes/intro/intro.tscn"
const MENU := "res://src/scenes/menu/menu.tscn"
const GAME := "res://src/scenes/game/game.tscn"
const OPTIONS := "res://src/scenes/options/options.tscn"
const KEYS := "res://src/scenes/options/keys.tscn"
const HIGH_SCORES := "res://src/scenes/high_scores/high_scores.tscn"
const EDITOR := "res://src/scenes/editor/editor.tscn"
const LOBBY := "res://src/scenes/lobby/lobby.tscn"

## True once the intro has been shown this run (the original only plays it "first time").
var intro_shown := false

## Logical size every scene is designed for; centred in wider or taller viewports.
const CONTENT := Vector2(640, 480)
var content_offset := Vector2.ZERO
var _wings: Wings


func _ready() -> void:
	_wings = Wings.new()
	add_child(_wings)
	get_viewport().size_changed.connect(_layout)
	get_tree().node_added.connect(_on_node_added)
	_layout()


## Centres the 640x480 content in the viewport (stretch aspect "expand") and sizes the wings.
func _layout() -> void:
	var vs := get_viewport().get_visible_rect().size
	content_offset = ((vs - CONTENT) / 2.0).floor()
	get_viewport().canvas_transform = Transform2D(0.0, content_offset)
	_wings.set_geometry(vs, content_offset, CONTENT)


## When a scene root arrives, tint the wings from its "Background" sprite once it is set up.
func _on_node_added(node: Node) -> void:
	if node.get_parent() == get_tree().root and node != self:
		_retint.call_deferred(node)


func _retint(scene: Node) -> void:
	if not is_instance_valid(scene):
		return
	var bg := scene.get_node_or_null("Background")
	if bg is Sprite2D and bg.texture != null:
		_wings.tint_from(bg.texture)
	elif bg is ColorRect:
		_wings.set_geometry(get_viewport().get_visible_rect().size, content_offset, CONTENT)


## Switches scene. With [param effect] the current screen is captured first and dissolved
## over the new one with one of the original transitions (the original only does this when a
## game starts; sub-screens simply appear).
func goto(path: String, effect := false, kind := "random") -> void:
	if effect:
		var img := get_viewport().get_texture().get_image()
		_switch.call_deferred(path, img, kind)
	else:
		get_tree().change_scene_to_file.call_deferred(path)


func _switch(path: String, old_image: Image, kind: String) -> void:
	get_tree().change_scene_to_file(path)
	Transition.start(get_tree(), old_image, kind)


func quit_game() -> void:
	Settings.save_settings()
	get_tree().quit()
