class_name UiText
extends RefCounted
## Runtime text in the original look: DejaVu Sans (standing in for Pango "sans"), white with a
## one pixel black shadow (print_ in bin/frozen-bubble:1258-1281).

const FONT := "res://assets/fonts/DejaVuSans.ttf"
const FONT_BOLD := "res://assets/fonts/DejaVuSans-Bold.ttf"
const HIGHLIGHT := Color(1.0, 0.9, 0.3)


static func style(label: Label, size := 14, colour := Color.WHITE, bold := false) -> Label:
	label.add_theme_font_override("font", load(FONT_BOLD if bold else FONT))
	label.add_theme_font_size_override("font_size", size)
	label.add_theme_color_override("font_color", colour)
	label.add_theme_color_override("font_shadow_color", Color.BLACK)
	label.add_theme_constant_override("shadow_offset_x", 1)
	label.add_theme_constant_override("shadow_offset_y", 1)
	return label


static func make(text: String, size := 14, colour := Color.WHITE, bold := false) -> Label:
	var l := Label.new()
	l.text = text
	return style(l, size, colour, bold)


const BITMAP_WHITE := "res://assets/fonts/bitmap/editor.fnt"
const BITMAP_BLUE := "res://assets/fonts/bitmap/editor_hi.fnt"
const BITMAP_SIZE := 38


## Level-editor text: the display font in the two colours of the original SFont sheets
## (white, or blue for list entries and the start-level number). The bitmap sheets stay
## available in assets/fonts/bitmap for the classic look.
const EDITOR_SIZE := 18
const EDITOR_BLUE := Color(0.62, 0.62, 0.92)


static func bitmap(text: String, blue := false) -> Label:
	var l := funky(text, EDITOR_SIZE, EDITOR_BLUE if blue else Color.WHITE, Color(0.2, 0.1, 0.05))
	l.add_theme_constant_override("outline_size", 3)
	l.add_theme_constant_override("shadow_offset_x", 1)
	l.add_theme_constant_override("shadow_offset_y", 1)
	return l


static func editor_width(text: String) -> float:
	return display_font().get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, EDITOR_SIZE).x


## --- display ("funky") font -------------------------------------------------------------------
## Playpen Sans (OFL, weight 800) carries the playful hand-lettered look of the original plates
## for Latin, Cyrillic and Greek alike; per-script fallbacks keep the spirit for the other
## alphabets of the 32 locales: Mochiy Pop One (Japanese), ZCOOL KuaiLe (Chinese), Lalezar
## (Persian/Arabic), Baloo 2 (Devanagari); DejaVu Sans Bold and the system fonts catch the rest
## (e.g. traditional Chinese via Noto CJK when installed).

const DISPLAY_DIR := "res://assets/fonts/display/"
static var _display_font: FontVariation


static func display_font() -> Font:
	if _display_font != null:
		return _display_font
	var fv := _weighted(DISPLAY_DIR + "PlaypenSans-Variable.ttf", 800)
	var fallbacks: Array[Font] = []
	fallbacks.append(load(DISPLAY_DIR + "MochiyPopOne-Regular.ttf"))
	fallbacks.append(load(DISPLAY_DIR + "ZCOOLKuaiLe-Regular.ttf"))
	fallbacks.append(load(DISPLAY_DIR + "Lalezar-Regular.ttf"))
	fallbacks.append(_weighted(DISPLAY_DIR + "Baloo2-Variable.ttf", 800))
	fallbacks.append(load(FONT_BOLD))
	var system := SystemFont.new()
	system.font_names = PackedStringArray(["Noto Sans CJK TC", "Noto Sans CJK JP", "Noto Sans CJK SC", "Noto Sans Devanagari", "sans-serif"])
	fallbacks.append(system)
	fv.fallbacks = fallbacks
	_display_font = fv
	return fv


static func _weighted(path: String, weight: int) -> FontVariation:
	var fv := FontVariation.new()
	fv.base_font = load(path)
	fv.variation_opentype = {TextServerManager.get_primary_interface().name_to_tag("wght"): weight}
	return fv


## A label in the display font with a dark outline and shadow, like the original plates.
static func funky(text: String, size := 22, colour := Color.WHITE, outline := Color(0.25, 0.05, 0.2)) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_override("font", display_font())
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", colour)
	l.add_theme_color_override("font_outline_color", outline)
	l.add_theme_constant_override("outline_size", maxi(2, size / 6))
	l.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.5))
	l.add_theme_constant_override("shadow_offset_x", 2)
	l.add_theme_constant_override("shadow_offset_y", 2)
	return l


## Shrinks a display-font label's size until its text fits [param max_width] (down to
## [param min_size]); long translations then stay on their plate.
static func fit(label: Label, max_width: float, max_size: int, min_size := 9) -> void:
	var font := display_font()
	var size := max_size
	while size > min_size and font.get_string_size(label.text, HORIZONTAL_ALIGNMENT_LEFT, -1, size).x > max_width:
		size -= 1
	label.add_theme_font_size_override("font_size", size)
	label.add_theme_constant_override("outline_size", maxi(2, size / 6))
