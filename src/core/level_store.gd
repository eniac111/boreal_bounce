class_name LevelStore
extends RefCounted
## User levelsets in user://levels/ (the original's ~/.frozen-bubble/levels). Files keep the
## original text format so they are interchangeable with the Perl game. On first use the
## bundled default set is copied in as "default-levelset", like the original did.

const DIR := "user://levels/"
const DEFAULT_NAME := "default-levelset"
const BUNDLED_DEFAULT := "res://assets/levels/default-levelset.lvl"
const MAX_NAME_LENGTH := 20


static func ensure_default() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(DIR))
	if not FileAccess.file_exists(DIR + DEFAULT_NAME):
		var text := FileAccess.get_file_as_string(BUNDLED_DEFAULT)
		var f := FileAccess.open(DIR + DEFAULT_NAME, FileAccess.WRITE)
		if f != null:
			f.store_string(text)


## Sorted levelset names.
static func list() -> PackedStringArray:
	ensure_default()
	var names := PackedStringArray()
	for f in DirAccess.get_files_at(DIR):
		if not f.begins_with("."):
			names.append(f)
	names.sort()
	return names


static func path_of(name: String) -> String:
	return DIR + name


static func exists(name: String) -> bool:
	return FileAccess.file_exists(path_of(name))


static func load_set(name: String) -> LevelSet:
	ensure_default()
	return LevelSet.load_file(path_of(name))


static func save_set(name: String, ls: LevelSet) -> Error:
	ensure_default()
	return ls.save_file(path_of(name))


static func delete(name: String) -> Error:
	return DirAccess.remove_absolute(ProjectSettings.globalize_path(path_of(name)))


## Names are file names: letters, digits, "-" and "_", 1..20 characters.
static func is_ok_name(name: String) -> bool:
	if name.length() < 1 or name.length() > MAX_NAME_LENGTH:
		return false
	for c in name:
		var code := c.unicode_at(0)
		var ok := (code >= 48 and code <= 57) or (code >= 65 and code <= 90) or (code >= 97 and code <= 122) or c == "-" or c == "_"
		if not ok:
			return false
	return true
