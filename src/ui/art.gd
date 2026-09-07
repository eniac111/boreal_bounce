class_name Art
extends RefCounted
## Texture loader. Prefers the importer's 2x upscaled copies in assets/gfx_hd (files named
## name.png.hd, kept out of Godot's importer) and reports them at the original logical size, so
## all layout code keeps using 640x480 coordinates while big windows get the extra detail.
## Falls back to the imported 1x texture when no HD copy exists.

const GFX := "res://assets/gfx/"
const HD := "res://assets/gfx_hd/"
const HD_SUFFIX := ".hd"
static var _cache := {}
static var _frames := {}
## Optional style suffix inserted before ".png" when looking for HD files ("" or "smooth").
## Only files that exist in that style are affected (currently the plain bubbles).
static var style := "":
	set(v):
		if v != style:
			style = v
			_cache.clear()
			_frames.clear()
## Set to false to force the 1x textures (e.g. for memory-constrained targets).
## HD files may use any integer upscale factor; the frame metadata of sprite sheets is in 1x
## pixels, so sheets must keep the importer's 2x factor.
static var use_hd := true
## 1x sizes of every gfx image, written by the importer (gfx_hd/manifest.json), so HD files are
## reported at the right size even before Godot has imported the 1x textures.
static var _sizes := {}
static var _sizes_loaded := false


static func tex(path: String) -> Texture2D:
	if _cache.has(path):
		return _cache[path]
	var t: Texture2D = null
	if use_hd and path.begins_with(GFX):
		var hd := HD + path.trim_prefix(GFX) + HD_SUFFIX
		if style != "":
			var styled := HD + path.trim_prefix(GFX).get_basename() + "." + style + ".png" + HD_SUFFIX
			if FileAccess.file_exists(styled):
				hd = styled
		if FileAccess.file_exists(hd):
			var img := Image.new()
			if img.load_png_from_buffer(FileAccess.get_file_as_bytes(hd)) == OK:
				img.generate_mipmaps()
				var it := ImageTexture.create_from_image(img)
				# report the 1x size so layout code is unaffected, whatever the upscale factor
				it.set_size_override(_base_size(path, img))
				t = it
	if t == null:
		t = load(path)
	_cache[path] = t
	return t


static func _base_size(path: String, img: Image) -> Vector2i:
	if not _sizes_loaded:
		_sizes_loaded = true
		var manifest := HD + "manifest.json"
		if FileAccess.file_exists(manifest):
			var parsed = JSON.parse_string(FileAccess.get_file_as_string(manifest))
			if parsed is Dictionary:
				_sizes = parsed
	var rel := path.trim_prefix(GFX)
	if _sizes.has(rel):
		var s: Array = _sizes[rel]
		return Vector2i(int(s[0]), int(s[1]))
	var base: Texture2D = load(path)
	if base != null:
		return Vector2i(base.get_width(), base.get_height())
	return Vector2i(img.get_width() / 2, img.get_height() / 2)


## SpriteFrames for a packed sequence (path of the .tres written by the importer). Built from
## the HD sheet when available so animations get the same treatment as still images.
static func frames(tres_path: String) -> SpriteFrames:
	if _frames.has(tres_path):
		return _frames[tres_path]
	var sheet_png := tres_path.get_basename() + ".png"
	var meta_path := tres_path.get_basename() + ".sheet.json"
	var sf: SpriteFrames = null
	if use_hd and FileAccess.file_exists(meta_path):
		var meta = JSON.parse_string(FileAccess.get_file_as_string(meta_path))
		var atlas := tex(sheet_png)
		if meta is Dictionary and atlas is ImageTexture:
			sf = SpriteFrames.new()
			var fw := int(meta["frame_w"])
			var fh := int(meta["frame_h"])
			var cols := int(meta["columns"])
			var pad := int(meta.get("pad", 0))
			var anim := &"default"
			if not sf.has_animation(anim):
				sf.add_animation(anim)
			sf.set_animation_speed(anim, 50.0)
			sf.set_animation_loop(anim, true)
			for i in int(meta["count"]):
				var at := AtlasTexture.new()
				at.atlas = atlas
				at.region = Rect2((i % cols) * (fw + 2 * pad) + pad, (i / cols) * (fh + 2 * pad) + pad, fw, fh)
				sf.add_frame(anim, at)
	if sf == null:
		sf = load(tres_path)
	_frames[tres_path] = sf
	return sf
