class_name BubbleArt
extends RefCounted
## Looks up bubble textures and animations from assets/gfx/balls. Colours are 0..7 and map to
## bubble-1.png .. bubble-8.png exactly as in the original (@bubbles_images indexing).
## Full-size bubbles are 32x32, "mini" ones (remote players in network games) 16x16.

const DIR := "res://assets/gfx/balls/"
static var _cache := {}


static func _res(path: String) -> Resource:
	if path.ends_with(".tres"):
		return Art.frames(path)
	return Art.tex(path)


static func _tex(path: String) -> Texture2D:
	return _res(path) as Texture2D


static func bubble(colour: int, colourblind := false, mini := false) -> Texture2D:
	if colour == LevelSet.STONE:
		return lose(mini)
	var name := "bubble-colourblind-%d" % (colour + 1) if colourblind else "bubble-%d" % (colour + 1)
	return _tex(DIR + name + ("-mini" if mini else "") + ".png")


## The grey bubble shown on a lost game (and used for unpoppable level cells).
static func lose(mini := false) -> Texture2D:
	return _tex(DIR + "bubble_lose" + ("-mini" if mini else "") + ".png")


static func prelight(mini := false) -> Texture2D:
	return _tex(DIR + "bubble_prelight" + ("-mini" if mini else "") + ".png")


## Frames of the "stick" flash played when a bubble attaches (7 frames).
static func stick_effect_frames() -> SpriteFrames:
	return _res(DIR + "stick_effect.tres") as SpriteFrames


static func stick_effect_mini(frame: int) -> Texture2D:
	return _tex(DIR + "stick_effect_%d-mini.png" % frame)


## Penguin animation for a player slot ("p1", "p2", "rp1".."rp4") and state
## ("wait", "anime-shooter", "win", "loose").
static func penguin(slot: String, state: String) -> SpriteFrames:
	return _res("res://assets/gfx/pinguins/%s_%s.tres" % [state, slot]) as SpriteFrames
