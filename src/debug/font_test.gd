extends Node2D
## Debug scene (`--scene=fonttest`): candidate display fonts across Latin, Cyrillic and Greek.

const SAMPLE := "Start 1P game  Нова игра  Νέο παιχνίδι  Winner!"
const CANDIDATES := [
	["Playpen Sans 800 (display font)", "", 0],
]


func _ready() -> void:
	var bg := ColorRect.new()
	bg.color = Color(0.55, 0.2, 0.45)
	bg.size = Vector2(640, 480)
	add_child(bg)
	var y := 6
	for c in CANDIDATES:
		var name_label := UiText.make(c[0], 11, Color(1, 1, 0.7))
		name_label.position = Vector2(12, y)
		add_child(name_label)
		var l := Label.new()
		l.text = SAMPLE
		var font: Font
		if c[1] == "":
			font = UiText.display_font()
		else:
			var fv := FontVariation.new()
			fv.base_font = load("res://assets/fonts/display/" + c[1])
			if c[2] > 0:
				fv.variation_opentype = {TextServerManager.get_primary_interface().name_to_tag("wght"): c[2]}
			font = fv
		l.add_theme_font_override("font", font)
		l.add_theme_font_size_override("font_size", 24)
		l.add_theme_color_override("font_outline_color", Color(0.25, 0.05, 0.2))
		l.add_theme_constant_override("outline_size", 5)
		l.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.5))
		l.add_theme_constant_override("shadow_offset_x", 2)
		l.add_theme_constant_override("shadow_offset_y", 2)
		l.position = Vector2(12, y + 14)
		add_child(l)
		y += 62
	var jp := UiText.funky("日本語 ひとりで遊ぶ  简体 单人游戏  فارسی بازی  नेपाली खेल", 22)
	jp.position = Vector2(12, y + 4)
	add_child(jp)
