@tool
class_name SceneSnapshotCache
extends RefCounted

const ROOT := "user://godot-git-plugin/snapshots"

var loaded_count := 0
var _paths: Dictionary = {}

func cache_text(object_id: String, scene_path: String, text: String, mode: String = "scene") -> Dictionary:
	var safe_id := _safe_component(object_id + "_" + mode)
	var safe_path := _safe_component(scene_path).replace("/", "__")
	var directory := ROOT.path_join(safe_id)
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(directory))
	var destination := directory.path_join(safe_path)
	var file := FileAccess.open(destination, FileAccess.WRITE)
	if file == null:
		return {"ok": false, "code": "snapshot_write_failed", "message": "Could not write scene snapshot"}
	file.store_string(text)
	file.close()
	_paths[destination] = true
	return {"ok": true, "path": destination}

func load_scene(object_id: String, scene_path: String, text: String, mode: String = "scene") -> Dictionary:
	var cached := cache_text(object_id, scene_path, text, mode)
	if not bool(cached.get("ok", false)):
		return cached
	var packed := ResourceLoader.load(str(cached.get("path", "")), "PackedScene", ResourceLoader.CACHE_MODE_IGNORE)
	if packed == null or not packed is PackedScene:
		return {"ok": false, "code": "snapshot_load_failed", "message": "Could not load scene snapshot"}
	loaded_count += 1
	return {"ok": true, "path": str(cached.get("path", "")), "scene": packed}

func clear() -> void:
	_paths.clear()
	loaded_count = 0
	_remove_directory(ROOT)

func invalidate(object_id: String, scene_path: String, mode: String = "scene") -> void:
	var key := _safe_component(object_id + "_" + mode)
	var directory := ROOT.path_join(key)
	_remove_directory(directory)
	for path in _paths.keys():
		if str(path).begins_with(directory + "/"):
			_paths.erase(path)

func _safe_component(value: String) -> String:
	var result := value.replace("/", "_").replace("\\", "_").replace(":", "_").replace(" ", "_")
	return result if not result.is_empty() else "unknown"

func _remove_directory(path: String) -> void:
	var absolute := ProjectSettings.globalize_path(path)
	if not DirAccess.dir_exists_absolute(absolute):
		return
	var directory := DirAccess.open(path)
	if directory == null:
		return
	for file_name in directory.get_files():
		directory.remove(file_name)
	for directory_name in directory.get_directories():
		_remove_directory(path.path_join(directory_name))
	DirAccess.remove_absolute(absolute)
